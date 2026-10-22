import Foundation

/// Keeps watch work at the existing networking boundary. Tests supply transports, never a host.
@MainActor final class WatchSessionService {
    let hermes: (any BotTransport)?
    let webui: (any WatchWebuiTransport)?
    init(hermes: any BotTransport) { self.hermes = hermes; webui = nil }
    init(webui: any WatchWebuiTransport) { self.webui = webui; hermes = nil }

    func read(preferredProfile: String?) async throws -> (count: Int, profile: String, allProfiles: Bool) {
        if let hermes {
            let live = try await hermes.call(.sessionActiveList)
            let count = try Self.hermesCount(live)
            let current = try await hermes.currentProfile()
            var profile = current
            if let preferredProfile {
                let reply = try await hermes.call(.profilesList(includeSessions: false))
                guard let profiles = reply["profiles"].list else { throw WatchProblem.unsupported }
                if profiles.contains(where: { $0["name"].text == preferredProfile }) { profile = preferredProfile }
            }
            guard !profile.isEmpty else { throw WatchProblem.unsupported }
            return (count, profile, true)
        }
        guard let webui else { throw WatchProblem.unsupported }
        let profile = try await webui.profile()
        let sessions = try await webui.sessions()
        // Webui keeps the stream open while approval/clarify input is pending, exactly the
        // list's attention semantics. No history count and no timestamp-based inference.
        let count = Set(sessions.filter(SessionRowView.isActiveStreaming).compactMap(\.sessionId)).count
        guard try await webui.profile() == profile else { throw WatchProblem.changedTarget }
        return (count, profile, false)
    }

    static func hermesCount(_ reply: BotJSON) throws -> Int {
        guard let items = reply["sessions"].list else { throw WatchProblem.unsupported }
        return SessionRowAttentionState.hermesStates(items).count
    }

    func create(profile: String, text: String, validate: @escaping () throws -> Void) async throws -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 4_000 else { throw WatchProblem.invalidRequest }
        try validate()
        if let hermes {
            // Same session.create and prompt.submit as HermesConversation. The first prompt
            // persists the otherwise lazy row before the host acknowledges "streaming".
            let created = try await hermes.call(.sessionNew(profile: profile, cwd: nil, model: nil), validateDispatch: validate)
            guard let key = created["stored_session_id"].text, !key.isEmpty,
                  let runtime = created["session_id"].text, !runtime.isEmpty else { throw WatchProblem.unknownOutcome }
            try validate()
            let accepted = try await hermes.call(.promptSubmit(sessionID: runtime, text: text), validateDispatch: validate)
            guard accepted["status"].text == "streaming" else { throw WatchProblem.unknownOutcome }
            try validate()
            guard let row = try await hermes.sessionRow(key: key, profile: profile), row["id"].text == key else {
                throw WatchProblem.unknownOutcome
            }
            try validate()
            return key
        }
        guard let webui else { throw WatchProblem.unsupported }
        guard try await webui.profile() == profile else { throw WatchProblem.changedTarget }
        try validate()
        let key = try await webui.create(profile: profile)
        try validate()
        guard try await webui.profile() == profile else { throw WatchProblem.changedTarget }
        try validate()
        try await webui.start(key: key, profile: profile, text: text)
        try validate()
        try await webui.verify(key: key)
        try validate()
        return key
    }
}

@MainActor protocol WatchWebuiTransport {
    func profile() async throws -> String
    func sessions() async throws -> [SessionSummary]
    func create(profile: String) async throws -> String
    func start(key: String, profile: String, text: String) async throws
    func verify(key: String) async throws
}

@MainActor final class WatchWebuiClient: WatchWebuiTransport {
    private let client: APIClient
    init(client: APIClient) { self.client = client }
    func profile() async throws -> String {
        guard let profile = try await client.profiles().active, !profile.isEmpty else { throw WatchProblem.unsupported }
        return profile
    }
    func sessions() async throws -> [SessionSummary] {
        guard let rows = try await client.sessions().sessions else { throw WatchProblem.unsupported }
        return rows
    }
    func create(profile: String) async throws -> String {
        guard let key = try await client.createSession(workspace: nil, model: nil, modelProvider: nil, profile: profile).session?.sessionId,
              !key.isEmpty else { throw WatchProblem.unknownOutcome }
        return key
    }
    func start(key: String, profile: String, text: String) async throws {
        let reply = try await client.startChat(sessionID: key, message: text, workspace: nil, model: nil, profile: profile)
        guard reply.error == nil, reply.streamId?.isEmpty == false, reply.sessionId == key else { throw WatchProblem.unknownOutcome }
    }
    func verify(key: String) async throws {
        guard try await client.session(id: key, includeMessages: false).session?.sessionId == key else { throw WatchProblem.unknownOutcome }
    }
}
