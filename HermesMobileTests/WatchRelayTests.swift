import XCTest
@testable import HermesMobile

@MainActor
final class WatchRelayTests: XCTestCase {
    func testBackgroundWakeCannotUseAppLockGracePeriod() {
        XCTAssertFalse(WatchPhoneBridge.allowsAccess(lockEnabled: true, isLocked: false, phoneActive: false, protectedDataAvailable: true))
        XCTAssertFalse(WatchPhoneBridge.allowsAccess(lockEnabled: true, isLocked: true, phoneActive: true, protectedDataAvailable: true))
        XCTAssertFalse(WatchPhoneBridge.allowsAccess(lockEnabled: false, isLocked: false, phoneActive: true, protectedDataAvailable: false))
        XCTAssertTrue(WatchPhoneBridge.allowsAccess(lockEnabled: true, isLocked: false, phoneActive: true, protectedDataAvailable: true))
        XCTAssertTrue(WatchPhoneBridge.allowsAccess(lockEnabled: false, isLocked: false, phoneActive: false, protectedDataAvailable: true))
    }

    func testRevokedHTTPDispatchNeverReachesTransport() async throws {
        let gate = WatchDispatchGate(), ticket = gate.ticket()
        try gate.validate(ticket)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WatchNoNetworkProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = APIClient(baseURL: URL(string: "https://example.invalid")!, session: session,
                               requestAdmission: { try gate.validate(ticket) })
        gate.invalidate()
        do {
            _ = try await client.createSession(workspace: nil, model: nil, modelProvider: nil, profile: "default")
            XCTFail("revoked dispatch succeeded")
        } catch { XCTAssertEqual(error as? WatchProblem, .changedTarget) }
    }

    func testMessageEnvelopeRoundTripAndMalformedPayload() throws {
        let request = WatchRequest(kind: .create, scope: UUID(), text: "A short prompt")
        let received = try XCTUnwrap(WatchMessage.decode(WatchRequest.self, from: WatchMessage.encode(request)))
        XCTAssertEqual(received.kind, .create)
        XCTAssertEqual(received.id, request.id)
        XCTAssertEqual(received.scope, request.scope)
        XCTAssertEqual(received.text, request.text)
        XCTAssertNil(WatchMessage.decode(WatchRequest.self, from: ["hermexWatchV1": Data("bad JSON".utf8)]))
    }

    func testWebuiCountsStreamingRowsAndVerifiesNewSession() async throws {
        let wire = WatchWebuiFake()
        let service = WatchSessionService(webui: wire)
        let read = try await service.read(preferredProfile: nil)
        XCTAssertEqual(read.count, 2)
        XCTAssertEqual(read.profile, "default")
        XCTAssertFalse(read.allProfiles)
        let key = try await service.create(profile: read.profile, text: "Hello", validate: {})
        XCTAssertEqual(key, "new")
        XCTAssertEqual(wire.operations, ["create:default", "start:new:default:Hello", "verify:new"])
        wire.failsRead = true
        do { _ = try await service.read(preferredProfile: nil); XCTFail("read failure became zero") } catch { }
    }

    func testWebuiProfileMismatchPreventsCreation() async {
        let wire = WatchWebuiFake()
        do {
            _ = try await WatchSessionService(webui: wire).create(profile: "previous", text: "Hello", validate: {})
            XCTFail("wrong Profile received a session")
        } catch { XCTAssertEqual(error as? WatchProblem, .changedTarget) }
        XCTAssertTrue(wire.operations.isEmpty)
    }

    func testTargetChangeBetweenCreateAndPromptStopsFurtherWrites() async {
        let wire = WatchBotFake()
        var valid = true
        wire.afterCreate = { valid = false }
        do {
            _ = try await WatchSessionService(hermes: wire).create(profile: "default", text: "Hello", validate: {
                if !valid { throw WatchProblem.changedTarget }
            })
            XCTFail("stale target succeeded")
        } catch { XCTAssertEqual(error as? WatchProblem, .changedTarget) }
        XCTAssertEqual(wire.calls.map(\.method), ["session.create"])
    }

    func testSnapshotRoundTripAndFreshnessNeverTreatErrorsAsZero() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let snapshot = WatchSnapshot(scope: UUID(), count: 3, profile: "default", allProfiles: true, date: now)
        let decoded = try JSONDecoder().decode(WatchSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(decoded, snapshot)
        XCTAssertFalse(decoded.isStale(at: now))
        XCTAssertTrue(decoded.isStale(at: now.addingTimeInterval(301)))
        XCTAssertTrue(decoded.isStale(at: now.addingTimeInterval(-1)))
        XCTAssertNil(WatchSnapshot.unavailable(.locked).count)
        XCTAssertFalse(WatchSnapshot.unavailable(.locked).canCreate(at: now))
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        XCTAssertTrue(Set(keys.keys).isSubset(of: ["scope", "count", "profile", "allProfiles", "date", "problem"]))
    }

    func testHermesCountUsesAttentionStatesAndDeduplicatesStoredKeys() throws {
        let rows: [BotJSON] = [
            .object(["session_key": .string("one"), "status": .string("working")]),
            .object(["session_key": .string("one"), "status": .string("waiting")]),
            .object(["session_key": .string("two"), "status": .string("starting")]),
            .object(["session_key": .string("three"), "status": .string("streaming")]),
            .object(["session_key": .string("idle"), "status": .string("idle"), "is_active": .bool(true)]),
            .object(["session_key": .string("resuming"), "status": .string("resuming")])
        ]
        XCTAssertEqual(try WatchSessionService.hermesCount(.object(["sessions": .array(rows)])), 3)
        XCTAssertThrowsError(try WatchSessionService.hermesCount(.object([:])))
    }

    func testConcurrentCreateAndOutcomeChecksDispatchOnlyOnce() async {
        let journal = WatchRequestJournal(load: { [:] }, save: { _ in })
        let dispatcher = WatchRequestDispatcher(journal: journal)
        let request = WatchRequest(kind: .create, scope: UUID(), text: "Hello")
        var calls = 0
        let gate = expectation(description: "write entered")
        var release: CheckedContinuation<Void, Never>?
        let first = Task {
            await dispatcher.create(request) {
                calls += 1
                gate.fulfill()
                await withCheckedContinuation { release = $0 }
                return WatchReply(sessionID: "created")
            }
        }
        await fulfillment(of: [gate])
        let duplicate = Task { await dispatcher.create(request) { XCTFail("duplicate write"); return .init(problem: .unknownOutcome) } }
        release?.resume()
        let firstResult = await first.value
        XCTAssertEqual(firstResult.sessionID, "created")
        let result = await duplicate.value
        XCTAssertEqual(result.sessionID, "created")
        XCTAssertEqual(dispatcher.outcome(request.id).sessionID, "created")
        XCTAssertEqual(calls, 1)
    }

    func testRestartTombstoneAndExpiredRequestNeverWrite() async {
        let request = WatchRequest(kind: .create, scope: UUID(), text: "Hello")
        let journal = WatchRequestJournal(load: { [request.id.uuidString: request.date.timeIntervalSince1970] }, save: { _ in })
        let dispatcher = WatchRequestDispatcher(journal: journal)
        let result = await dispatcher.create(request) { XCTFail("ambiguous request replayed"); return .init() }
        XCTAssertEqual(result.problem, .unknownOutcome)
        let expired = WatchRequest(kind: .create, scope: UUID(), text: "Hello", date: .distantPast)
        let refusal = await dispatcher.create(expired) { XCTFail("expired write"); return .init() }
        XCTAssertEqual(refusal.problem, .expiredRequest)
    }

    func testHermesCreationUsesNormalCallsAndVerifiesPersistence() async throws {
        let wire = WatchBotFake()
        let service = WatchSessionService(hermes: wire)
        let result = try await service.create(profile: "default", text: "Hello", validate: {})
        XCTAssertEqual(result, "stored")
        XCTAssertEqual(wire.calls.map(\.method), ["session.create", "prompt.submit"])
        XCTAssertEqual(try wire.calls[0].params()["profile"], .string("default"))
        XCTAssertEqual(try wire.calls[1].params()["text"], .string("Hello"))
        XCTAssertEqual(wire.verifiedKey, "stored")
    }

    func testLockOrTargetChangeBeforeDispatchPreventsWrite() async {
        let wire = WatchBotFake()
        let service = WatchSessionService(hermes: wire)
        do {
            _ = try await service.create(profile: "default", text: "Hello", validate: { throw WatchProblem.locked })
            XCTFail("locked creation succeeded")
        } catch { XCTAssertEqual(error as? WatchProblem, .locked) }
        XCTAssertTrue(wire.calls.isEmpty)
    }

    func testMissingAcknowledgementOrRowDoesNotClaimSuccessOrRetry() async {
        for failure in [true, false] {
            let wire = WatchBotFake()
            wire.acknowledges = !failure
            wire.hasRow = failure
            let service = WatchSessionService(hermes: wire)
            do {
                _ = try await service.create(profile: "default", text: "Hello", validate: {})
                XCTFail("unverified creation succeeded")
            } catch { }
            XCTAssertEqual(wire.calls.filter { $0.method == "session.create" }.count, 1)
            XCTAssertEqual(wire.calls.filter { $0.method == "prompt.submit" }.count, 1)
        }
    }
}

@MainActor private final class WatchBotFake: BotTransport {
    var onEvent: ((BotJSON) -> Void)?
    var onDisconnect: ((Error) -> Void)?
    var replayEpoch: String? { nil }
    var calls: [HermesCall] = []
    var verifiedKey: String?
    var afterCreate: (() -> Void)?
    var acknowledges = true
    var hasRow = true
    func connect() async throws {}
    func close() {}
    func call(_ call: HermesCall, validateDispatch: (() throws -> Void)?) async throws -> BotJSON {
        try validateDispatch?()
        calls.append(call)
        switch call {
        case .sessionNew:
            afterCreate?()
            return .object(["stored_session_id": .string("stored"), "session_id": .string("runtime")])
        case .promptSubmit: return .object(["status": acknowledges ? .string("streaming") : .null])
        default: throw BotFailure.unsupported
        }
    }
    func sessionRow(key: String, profile: String) async throws -> BotJSON? {
        verifiedKey = key
        return hasRow ? .object(["id": .string(key)]) : nil
    }
}

@MainActor private final class WatchWebuiFake: WatchWebuiTransport {
    var operations: [String] = []
    var failsRead = false
    func profile() async throws -> String { "default" }
    func sessions() async throws -> [SessionSummary] {
        if failsRead { throw WatchProblem.unavailable }
        return [.init(sessionId: "idle", messageCount: 50), .init(sessionId: "stream", isStreaming: true),
                .init(sessionId: "stream", activeStreamId: "s1"), .init(sessionId: "waiting", activeStreamId: "s2")]
    }
    func create(profile: String) async throws -> String { operations.append("create:\(profile)"); return "new" }
    func start(key: String, profile: String, text: String) async throws { operations.append("start:\(key):\(profile):\(text)") }
    func verify(key: String) async throws { operations.append("verify:\(key)") }
}

private final class WatchNoNetworkProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTFail("Revoked request reached HTTP transport")
        client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
    }
    override func stopLoading() {}
}
