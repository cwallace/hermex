import Foundation
import Observation
import WatchConnectivity
import WidgetKit

@MainActor @Observable final class WatchConnection: NSObject, WCSessionDelegate {
    private(set) var snapshot = WatchSnapshotStore.load()
    private(set) var busy = false
    private(set) var status: String?
    private(set) var sessionID: String?
    private(set) var pending: WatchRequest?
    @ObservationIgnored private var activated = false

    override init() {
        super.init()
        // Only an opaque request identity is retained. The prompt and session result are not.
        if let data = UserDefaults.standard.data(forKey: "watch.pendingRequest") {
            pending = try? JSONDecoder().decode(WatchRequest.self, from: data)
        }
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    func refresh() async {
        guard !busy else { return }
        guard activated else { status = String(localized: "Connecting to iPhone…", table: "Watch"); return }
        busy = true
        defer { busy = false }
        let reply = await send(WatchRequest(kind: .refresh))
        if let snapshot = reply.snapshot { apply(snapshot) }
        status = reply.problem?.message
    }

    func create(text: String) async {
        guard !busy, pending == nil, snapshot.canCreate(at: Date()), activated else { return }
        let request = WatchRequest(kind: .create, scope: snapshot.scope, text: text)
        // Retain identity before attempting delivery, including delivery failures. Retrying a
        // send after a WC timeout could create a duplicate on a phone still doing the work.
        var identity = request
        identity.text = nil
        pending = identity
        storePending()
        busy = true
        defer { busy = false }
        accept(await send(request))
    }

    func checkOutcome() async {
        guard !busy, activated, var request = pending else { return }
        request.kind = .outcome
        busy = true
        defer { busy = false }
        accept(await send(request))
    }

    /// Explicitly confirmed by the user after checking iPhone. Never called on a timeout.
    func startAnother() {
        guard !busy else { return }
        pending = nil; sessionID = nil; status = nil
        storePending()
    }

    private func accept(_ reply: WatchReply) {
        if let snapshot = reply.snapshot { apply(snapshot) }
        if let id = reply.sessionID {
            sessionID = id
            status = String(localized: "Session started. Continue on iPhone.", table: "Watch")
            pending = nil
            storePending()
        } else {
            status = (reply.problem ?? .unknownOutcome).message
        }
    }

    private func storePending() {
        if let pending, let data = try? JSONEncoder().encode(pending) {
            UserDefaults.standard.set(data, forKey: "watch.pendingRequest")
        } else { UserDefaults.standard.removeObject(forKey: "watch.pendingRequest") }
    }

    func receiveContext() {
        if let value = WatchMessage.decode(WatchSnapshot.self, from: WCSession.default.receivedApplicationContext) { apply(value) }
    }

    private func apply(_ value: WatchSnapshot) {
        guard value.date >= snapshot.date else { return }
        snapshot = value
        WatchSnapshotStore.save(value)
        WidgetCenter.shared.reloadTimelines(ofKind: WatchSnapshotStore.kind)
    }

    /// Activation is mandatory; isReachable is deliberately not an admission check. An
    /// active Watch app's sendMessage can wake the paired iPhone in the background.
    private func send(_ request: WatchRequest) async -> WatchReply {
        guard activated, WCSession.default.activationState == .activated else { return WatchReply(problem: .unavailable) }
        return await withCheckedContinuation { continuation in
            let delivery = WatchDelivery(continuation: continuation)
            delivery.timeout = Task {
                do { try await Task.sleep(for: .seconds(55)) } catch { return }
                delivery.finish(WatchReply(problem: request.kind == .refresh ? .unavailable : .unknownOutcome))
            }
            WCSession.default.sendMessage(WatchMessage.encode(request), replyHandler: { message in
                let reply = WatchMessage.decode(WatchReply.self, from: message) ?? WatchReply(problem: .unsupported)
                Task { @MainActor in delivery.finish(reply) }
            }, errorHandler: { _ in
                Task { @MainActor in delivery.finish(WatchReply(problem: request.kind == .refresh ? .unavailable : .unknownOutcome)) }
            })
        }
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let context = session.receivedApplicationContext
        Task { @MainActor in
            self.activated = activationState == .activated
            if let value = WatchMessage.decode(WatchSnapshot.self, from: context) { self.apply(value) }
            if self.activated {
                await self.refresh()
            } else { self.status = WatchProblem.unavailable.message }
        }
    }
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let value = WatchMessage.decode(WatchSnapshot.self, from: applicationContext) else { return }
        Task { @MainActor in self.apply(value) }
    }
}

@MainActor private final class WatchDelivery {
    var continuation: CheckedContinuation<WatchReply, Never>?
    var timeout: Task<Void, Never>?
    init(continuation: CheckedContinuation<WatchReply, Never>) { self.continuation = continuation }
    func finish(_ reply: WatchReply) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel(); timeout = nil
        continuation.resume(returning: reply)
    }
}
