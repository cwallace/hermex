import Foundation

/// Persists only request UUIDs and dates, before any write. After process death a tombstone
/// refuses replay even though the in-memory result has been lost. No session IDs or text stored.
@MainActor final class WatchRequestJournal {
    private(set) var entries: [String: Double]
    private let save: ([String: Double]) -> Void
    init(load: () -> [String: Double], save: @escaping ([String: Double]) -> Void) {
        entries = load(); self.save = save
    }
    convenience init(defaults: UserDefaults = .standard) {
        self.init(load: { defaults.dictionary(forKey: "watch.requestTombstones") as? [String: Double] ?? [:] },
                  save: { defaults.set($0, forKey: "watch.requestTombstones") })
    }
    func contains(_ id: UUID) -> Bool { entries[id.uuidString] != nil }
    func insert(_ request: WatchRequest, now: Date) -> Bool {
        entries = entries.filter { now.timeIntervalSince1970 - $0.value < 3600 }
        guard entries.count < 128 else { return false }
        entries[request.id.uuidString] = now.timeIntervalSince1970
        save(entries)
        return true
    }
}

@MainActor final class WatchRequestDispatcher {
    private let journal: WatchRequestJournal
    private var running: [UUID: Task<WatchReply, Never>] = [:]
    private var results: [UUID: WatchReply] = [:]
    private var order: [UUID] = []
    init(journal: WatchRequestJournal) { self.journal = journal }

    func cancelAll() { running.values.forEach { $0.cancel() } }

    func outcome(_ id: UUID) -> WatchReply {
        results[id] ?? WatchReply(problem: running[id] == nil ? .unknownOutcome : .busy)
    }

    func create(_ request: WatchRequest, now: Date = Date(),
                operation: @escaping @MainActor () async -> WatchReply) async -> WatchReply {
        if let task = running[request.id] { return await task.value }
        if let result = results[request.id] { return result }
        if journal.contains(request.id) { return WatchReply(problem: .unknownOutcome) }
        guard now >= request.date, now.timeIntervalSince(request.date) < 900 else { return WatchReply(problem: .expiredRequest) }
        guard running.isEmpty, journal.insert(request, now: now) else { return WatchReply(problem: .busy) }
        let task = Task { await operation() }
        running[request.id] = task
        let reply = await task.value
        running[request.id] = nil
        results[request.id] = reply
        order.append(request.id)
        if order.count > 128 { results[order.removeFirst()] = nil }
        return reply
    }
}

/// Revoked synchronously by Observation before an auth/lock mutation. The webui API actor
/// checks its captured ticket immediately before URLSession dispatch, without an actor hop.
final class WatchDispatchGate: @unchecked Sendable {
    private let lock = NSLock()
    private var revision = 0
    func ticket() -> Int { lock.lock(); defer { lock.unlock() }; return revision }
    func invalidate() { lock.lock(); defer { lock.unlock() }; revision += 1 }
    func validate(_ ticket: Int) throws {
        try Task.checkCancellation()
        guard self.ticket() == ticket else { throw WatchProblem.changedTarget }
    }
}
