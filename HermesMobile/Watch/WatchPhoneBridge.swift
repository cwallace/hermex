import Foundation
import Observation
import UIKit
import WatchConnectivity

/// Started at app initialization, including a WatchConnectivity background wake. All server
/// work stays on the phone, behind its saved auth, current-server and app-lock policy.
@MainActor final class WatchPhoneBridge: NSObject, WCSessionDelegate {
    static let shared = WatchPhoneBridge()
    private weak var auth: AuthManager?
    private let dispatcher = WatchRequestDispatcher(journal: WatchRequestJournal())
    private var timer: Task<Void, Never>?
    private var refreshTask: Task<WatchSnapshot, Never>?
    private var observers: [NSObjectProtocol] = []
    private var generation = UUID()
    private let dispatchGate = WatchDispatchGate()
    private var target: Target?
    private var snapshot = WatchSnapshot.unavailable(.unavailable)
    private var preferredProfile: String?
    private var protectedDataUnavailable = false

    private struct Target {
        let scope: UUID
        let server: URL
        let kind: ServerKind
        let connectionID: UUID?
        let preference: String?
        let profile: String
    }

    func start(auth: AuthManager) {
        guard self.auth == nil, WCSession.isSupported() else { return }
        self.auth = auth
        preferredProfile = preference()
        observeAccess()
        let center = NotificationCenter.default
        for name in [UIApplication.didBecomeActiveNotification, UIApplication.didEnterBackgroundNotification,
                     UIApplication.protectedDataWillBecomeUnavailableNotification, UIApplication.protectedDataDidBecomeAvailableNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if name == UIApplication.protectedDataWillBecomeUnavailableNotification { self?.protectedDataUnavailable = true }
                    if name == UIApplication.protectedDataDidBecomeAvailableNotification { self?.protectedDataUnavailable = false }
                    self?.sceneChanged()
                }
            })
        }
        observers.append(center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.preference() != self.preferredProfile else { return }
                self.preferredProfile = self.preference()
                self.invalidate()
            }
        })
        WCSession.default.delegate = self
        WCSession.default.activate()
        sceneChanged()
    }

    private func observeAccess() {
        let gate = dispatchGate
        withObservationTracking {
            _ = auth?.state
            _ = auth?.servers
            _ = auth?.isSigningOut
            _ = AppLock.shared.isLocked
            _ = AppLock.shared.isEnabled
        } onChange: { [weak self] in
            gate.invalidate()
            Task { @MainActor in
                self?.invalidate()
                self?.observeAccess()
            }
        }
    }

    private func preference() -> String? {
        guard let server = auth?.state.server else { return nil }
        return UserDefaults.standard.string(forKey: HermesProfilePreference.key(for: server))
    }

    static func allowsAccess(lockEnabled: Bool, isLocked: Bool, phoneActive: Bool, protectedDataAvailable: Bool) -> Bool {
        protectedDataAvailable && !isLocked && (!lockEnabled || phoneActive)
    }

    private func requireAccess() throws -> (AuthManager, URL) {
        // AppLock doesn't relock until foregrounding. A Watch wake must not exploit that
        // grace period: when enabled, remote reads/writes require an active unlocked app.
        guard Self.allowsAccess(lockEnabled: AppLock.shared.isEnabled, isLocked: AppLock.shared.isLocked,
                                phoneActive: UIApplication.shared.applicationState == .active,
                                protectedDataAvailable: !protectedDataUnavailable && UIApplication.shared.isProtectedDataAvailable) else { throw WatchProblem.locked }
        guard let auth else { throw WatchProblem.unconfigured }
        guard !auth.isSigningOut else { throw WatchProblem.signedOut }
        switch auth.state {
        case .unconfigured: throw WatchProblem.unconfigured
        case .loggedOut: throw WatchProblem.signedOut
        case .loggedIn(let server):
            guard auth.activeServer != nil, !auth.removingServerIDs.contains(server.absoluteString) else { throw WatchProblem.unconfigured }
            return (auth, server)
        }
    }

    private func validate(_ target: Target) throws {
        try Task.checkCancellation()
        let (auth, server) = try requireAccess()
        guard server == target.server, auth.kind(of: server) == target.kind, preference() == target.preference,
              self.target?.scope == target.scope else { throw WatchProblem.changedTarget }
        if target.kind == .hermes {
            guard try BotConnectionStore().load(server: server)?.id == target.connectionID else { throw WatchProblem.changedTarget }
        }
    }

    private func invalidate() {
        dispatchGate.invalidate()
        preferredProfile = preference()
        dispatcher.cancelAll()
        generation = UUID()
        target = nil
        refreshTask?.cancel(); refreshTask = nil
        snapshot = .unavailable((try? requireAccess()) == nil ? accessProblem() : .changedTarget)
        publish(snapshot)
        if UIApplication.shared.applicationState == .active { Task { _ = await refresh() } }
    }

    private func accessProblem() -> WatchProblem {
        do { _ = try requireAccess(); return .unavailable } catch { return error as? WatchProblem ?? .unavailable }
    }

    private func sceneChanged() {
        timer?.cancel(); timer = nil
        if (try? requireAccess()) == nil { invalidate() }
        guard UIApplication.shared.applicationState == .active else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                _ = await self?.refresh()
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
    }

    private func service(auth: AuthManager, server: URL) throws -> (WatchSessionService, (any BotTransport)?, UUID?) {
        if auth.kind(of: server) == .hermes {
            guard let saved = try BotConnectionStore().load(server: server) else { throw WatchProblem.signedOut }
            let client = BotClient(saved: saved, server: server)
            return (WatchSessionService(hermes: client), client, saved.id)
        }
        // Freeze the selected server's headers for this operation, so switching cannot send
        // another server's headers to an old URL. Cookies remain in the established phone jar.
        let headers = auth.currentCustomHeaders
        let gate = dispatchGate, ticket = dispatchGate.ticket()
        let client = APIClient(baseURL: server, requestAdmission: { try gate.validate(ticket) }, customHeaderProvider: { headers })
        return (WatchSessionService(webui: WatchWebuiClient(client: client)), nil, nil)
    }

    private func refresh() async -> WatchSnapshot {
        guard WCSession.default.activationState == .activated, WCSession.default.isPaired,
              WCSession.default.isWatchAppInstalled else { return snapshot }
        if let refreshTask { return await refreshTask.value }
        let generation = self.generation
        let task = Task { @MainActor [self] in
            do {
                let (auth, server) = try requireAccess()
                let kind = auth.kind(of: server), preference = preference()
                let (service, wire, connectionID) = try self.service(auth: auth, server: server)
                defer { wire?.close() }
                try await wire?.connect()
                let read = try await service.read(preferredProfile: preference)
                let (_, currentServer) = try requireAccess()
                guard generation == self.generation, currentServer == server, self.preference() == preference,
                      !Task.isCancelled else { return self.snapshot }
                let scope = target.flatMap { $0.server == server && $0.profile == read.profile && $0.connectionID == connectionID ? $0.scope : nil } ?? UUID()
                target = Target(scope: scope, server: server, kind: kind, connectionID: connectionID,
                                preference: preference, profile: read.profile)
                try validate(target!)
                snapshot = WatchSnapshot(scope: scope, count: read.count, profile: read.profile, allProfiles: read.allProfiles)
            } catch {
                guard generation == self.generation, !Task.isCancelled else { return self.snapshot }
                target = nil
                snapshot = .unavailable(Self.problem(error))
                if case APIError.unauthorized = error { auth?.handleAPIError(error) }
            }
            publish(snapshot)
            return snapshot
        }
        refreshTask = task
        let value = await task.value
        if generation == self.generation { refreshTask = nil }
        return value
    }

    private func handle(_ request: WatchRequest) async -> WatchReply {
        if request.kind == .refresh { return WatchReply(snapshot: await refresh()) }
        do {
            guard let target, request.scope == target.scope else { throw WatchProblem.changedTarget }
            try validate(target)
            if request.kind == .outcome { return dispatcher.outcome(request.id) }
            guard snapshot.canCreate(at: Date()), let text = request.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text.count <= 4_000 else { throw WatchProblem.invalidRequest }
            return await dispatcher.create(request) { [self] in
                do {
                    try validate(target)
                    let (auth, server) = try requireAccess()
                    let (service, wire, _) = try self.service(auth: auth, server: server)
                    defer { wire?.close() }
                    try await wire?.connect()
                    let current = try await service.read(preferredProfile: target.preference)
                    guard current.profile == target.profile else { throw WatchProblem.changedTarget }
                    try validate(target)
                    let id = try await service.create(profile: target.profile, text: text, validate: { try self.validate(target) })
                    Task { _ = await self.refresh() }
                    return WatchReply(sessionID: id)
                } catch {
                    // A write may already have reached the host. Never retry, or echo server
                    // errors (which can contain URLs or text) to the Watch.
                    if case APIError.unauthorized = error { auth?.handleAPIError(error) }
                    let problem = (error as? WatchProblem) ?? (Self.problem(error) == .signedOut ? .signedOut : .unknownOutcome)
                    return WatchReply(problem: problem)
                }
            }
        } catch { return WatchReply(problem: error as? WatchProblem ?? .unavailable) }
    }

    private static func problem(_ error: Error) -> WatchProblem {
        if let problem = error as? WatchProblem { return problem }
        if let error = error as? BotFailure {
            if error == .signInExpired || error == .rejected(401) { return .signedOut }
            if error == .rejected(-32601) || error == .unsupported { return .unsupported }
        }
        if case APIError.unauthorized = error { return .signedOut }
        return .unavailable
    }

    private func publish(_ snapshot: WatchSnapshot) {
        guard WCSession.default.activationState == .activated, WCSession.default.isPaired,
              WCSession.default.isWatchAppInstalled else { return }
        try? WCSession.default.updateApplicationContext(WatchMessage.encode(snapshot))
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in _ = await self.refresh() }
    }
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        guard let request = WatchMessage.decode(WatchRequest.self, from: message) else {
            replyHandler(WatchMessage.encode(WatchReply(problem: .invalidRequest))); return
        }
        Task { @MainActor in replyHandler(WatchMessage.encode(await self.handle(request))) }
    }
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.invalidate(); _ = await self.refresh() }
    }
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
}
