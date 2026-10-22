import Foundation

/// The only phone-to-Watch data: no address, credentials, message content or transcript.
struct WatchSnapshot: Codable, Equatable {
    var scope: UUID?
    var count: Int?
    var profile: String?
    var allProfiles = false
    var date = Date()
    var problem: WatchProblem?

    static func unavailable(_ problem: WatchProblem) -> Self { Self(problem: problem) }
    func isStale(at now: Date) -> Bool { now < date || now.timeIntervalSince(date) > 300 }
    func canCreate(at now: Date) -> Bool { scope != nil && problem == nil && !isStale(at: now) }
}

enum WatchProblem: String, Codable, Error {
    case unconfigured, signedOut, locked, changedTarget, unavailable, unsupported
    case unknownOutcome, expiredRequest, busy, invalidRequest

    var message: String {
        switch self {
        case .unconfigured: return String(localized: "Configure a server on iPhone.", table: "Watch")
        case .signedOut: return String(localized: "Sign in again on iPhone.", table: "Watch")
        case .locked: return String(localized: "Open and unlock Hermex on iPhone.", table: "Watch")
        case .changedTarget: return String(localized: "The iPhone target changed. Refresh before starting a session.", table: "Watch")
        case .unavailable: return String(localized: "Could not refresh. Check the paired iPhone and server.", table: "Watch")
        case .unsupported: return String(localized: "This server did not return the required session information.", table: "Watch")
        case .unknownOutcome: return String(localized: "Outcome unknown. Check sessions on iPhone before starting another. This request will not be resent.", table: "Watch")
        case .expiredRequest: return String(localized: "This request expired. Check sessions on iPhone.", table: "Watch")
        case .busy: return String(localized: "A session request is still in progress. Check its result first.", table: "Watch")
        case .invalidRequest: return String(localized: "Enter a first message (up to 4,000 characters).", table: "Watch")
        }
    }
}

struct WatchRequest: Codable {
    enum Kind: String, Codable { case refresh, create, outcome }
    var kind: Kind
    var id = UUID()
    var scope: UUID?
    var text: String?
    var date = Date()
}

struct WatchReply: Codable {
    var snapshot: WatchSnapshot?
    /// Returned only to the app, never placed in complication storage or application context.
    var sessionID: String?
    var problem: WatchProblem?
}

enum WatchMessage {
    static func encode<T: Encodable>(_ value: T) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(value) else { return [:] }
        return ["hermexWatchV1": data]
    }
    static func decode<T: Decodable>(_ type: T.Type, from message: [String: Any]) -> T? {
        guard let data = message["hermexWatchV1"] as? Data, data.count <= 32_768 else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

/// Watch app and widget share a container on the Watch. App groups do not sync across devices.
enum WatchSnapshotStore {
    static let kind = "HermexSessions"
    static var defaults: UserDefaults? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "HermexAppGroup") as? String else { return nil }
        return UserDefaults(suiteName: group)
    }
    static func load() -> WatchSnapshot {
        guard let data = defaults?.data(forKey: kind),
              let snapshot = try? JSONDecoder().decode(WatchSnapshot.self, from: data) else { return .unavailable(.unavailable) }
        return snapshot
    }
    static func save(_ snapshot: WatchSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults?.set(data, forKey: kind)
    }
    static var newSessionURL: URL {
        let scheme = Bundle.main.object(forInfoDictionaryKey: "HermexWatchURLScheme") as? String ?? "hermex-watch"
        return URL(string: "\(scheme)://new-session")!
    }
}
