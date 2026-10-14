import XCTest
import Network
import Clocks
@testable import HolodeckCore

@MainActor
final class LocalClientRecoveryTests: XCTestCase {
    private let mac = LocalMac(id: UUID().uuidString, name: "Test Mac",
        endpoint: .service(name: "Test", type: LocalProtocol.serviceType, domain: "local.", interface: nil),
        interface: nil, version: LocalProtocol.version)

    private func fixture(remembered: LocalMac? = nil, clock: any Clock<Duration> = ContinuousClock(),
                         channel: RecoveryChannel = RecoveryChannel(), secrets: RecoverySecrets = RecoverySecrets(),
                         pin: String = "test-pin") throws -> (LocalCatalogClient, RecoveryChannel, RecoverySecrets) {
        if let remembered {
            try secrets.seedPairing(id: remembered.id, name: remembered.name, pin: "test-pin", token: "old-token")
        }
        var dependencies = LocalClientDependencies()
        dependencies.usesSystemBrowser = false
        dependencies.readSecret = secrets.read
        dependencies.writeSecret = secrets.write
        dependencies.removeSecret = secrets.remove
        dependencies.resolve = { _ in ResolvedMac(address: "192.168.1.2", port: 1234) }
        dependencies.transport = { mac, _, expected, _ in
            channel.serverIdentity.set(mac.id)
            secrets.recordPin(expected)
            return LocalClientTransport(channel: channel, fingerprint: { pin },
                identityChanged: { expected != nil && expected != pin })
        }
        let client = LocalCatalogClient(testingNamespace: "recovery", dependencies: dependencies, clock: clock)
        addTeardownBlock { await client.stop() }
        return (client, channel, secrets)
    }
    private func discover(_ macs: [LocalMac], client: LocalCatalogClient, sequence: UInt64 = 1) async throws {
        let checked1 = await client.currentBrowserID
        let id = try XCTUnwrap(checked1)
        await client.discovered(macs, id: id, sequence: sequence)
    }
    private func wait(_ condition: @escaping @Sendable () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { XCTFail("State transition did not complete"); throw LocalCatalogError.timeout }
            await Task.yield()
        }
    }
    private func connected(_ client: LocalCatalogClient) async throws {
        try await wait { if case .connected = await client.currentState.status { return true }; return false }
    }

    func testDiscoveryLossAndBrowserErrorsPreserveHealthyConnection() async throws {
        let (client, channel, _) = try fixture()
        await client.start(); try await discover([mac], client: client); try await connected(client)
        let before = await client.currentState
        let checked2 = await client.currentBrowserID
        let browserID = try XCTUnwrap(checked2)
        await client.discovered([], id: browserID, sequence: 2)
        await client.browserState(.waiting(.posix(.ENETDOWN)), id: browserID, sequence: 3)
        await client.browserState(.ready, id: browserID, sequence: 4)
        let head = try await client.source.get(.head, 65_536)
        XCTAssertFalse(head.isEmpty)
        let after = await client.currentState
        XCTAssertEqual(after.status, before.status); XCTAssertEqual(after.generation, before.generation)
        XCTAssertEqual(channel.cancellations.value, 0)
    }

    func testOutOfOrderAndCanceledBrowserCallbacksCannotReplaceCurrentResults() async throws {
        let (client, _, _) = try fixture()
        await client.start()
        let checked3 = await client.currentBrowserID
        let old = try XCTUnwrap(checked3)
        await client.discovered([mac], id: old, sequence: 4); try await connected(client)
        await client.discovered([], id: old, sequence: 3)
        let checked4 = await client.currentState.macs.map(\.id)
        XCTAssertEqual(checked4, [mac.id])
        await client.stop(); await client.start()
        let checked5 = await client.currentBrowserID
        let current = try XCTUnwrap(checked5)
        await client.discovered([], id: current, sequence: 1)
        await client.discovered([mac], id: old, sequence: 100)
        let checked6 = await client.currentState.macs.isEmpty
        XCTAssertTrue(checked6)
    }

    func testMissingRememberedMacOffersChooserAfterGraceAndOnlyOncePerEpisode() async throws {
        let clock = TestClock()
        let old = LocalMac(id: UUID().uuidString, name: "Old", endpoint: mac.endpoint, interface: nil, version: LocalProtocol.version)
        let (client, _, _) = try fixture(remembered: old, clock: clock)
        await client.start(); try await discover([mac], client: client)
        await clock.advance(by: .seconds(4))
        let checked7 = await client.currentState.status
        XCTAssertEqual(checked7, .disconnected)
        await clock.advance(by: .seconds(1))
        try await wait { await client.currentState.status == .chooseMac }
        let checked8 = await client.currentState.macChoiceID
        let choice = try XCTUnwrap(checked8)
        try await discover([mac], client: client, sequence: 2)
        await clock.advance(by: .seconds(20))
        let checked9 = await client.currentState.macChoiceID
        XCTAssertEqual(checked9, choice)
        try await discover([old, mac], client: client, sequence: 3)
        try await connected(client)
        let checked10 = await client.currentState.macChoiceID
        XCTAssertNil(checked10)
    }

    func testRememberedMacReturningDuringGraceCancelsChooser() async throws {
        let clock = TestClock()
        let (client, _, _) = try fixture(remembered: mac, clock: clock)
        let other = LocalMac(id: UUID().uuidString, name: "Other", endpoint: mac.endpoint, interface: nil, version: LocalProtocol.version)
        await client.start(); try await discover([other], client: client)
        await clock.advance(by: .seconds(4))
        try await discover([mac, other], client: client, sequence: 2); try await connected(client)
        await clock.advance(by: .seconds(10))
        let checked11 = await client.currentState.macChoiceID
        XCTAssertNil(checked11)
    }

    func testInFlightPairingSurvivesDiscoveryLossAndReturnsApprovalRequired() async throws {
        let channel = RecoveryChannel(); await channel.setPending(true)
        let (client, _, _) = try fixture(channel: channel)
        await client.start(); try await discover([mac], client: client)
        try await wait { if case .awaitingApproval = await client.currentState.status { return true }; return false }
        let status = await client.currentState.status
        try await discover([], client: client, sequence: 2)
        let checked12 = await client.currentState.status
        XCTAssertEqual(checked12, status)
        do { _ = try await client.source.get(.head, 100); XCTFail("Unapproved asset returned") }
        catch LocalCatalogError.approvalRequired {}
        XCTAssertEqual(channel.cancellations.value, 0)
    }

    func testMissingAssetDoesNotDisconnectOrChangeConnectionGeneration() async throws {
        let (client, channel, _) = try fixture()
        await client.start(); try await discover([mac], client: client); try await connected(client)
        let before = await client.currentState
        for revision in [String(repeating: "a", count: 40), String(repeating: "b", count: 64)] {
            do { _ = try await client.source.get(.asset(revision: revision, path: "previews/missing.png"), 100); XCTFail() }
            catch CatalogError.invalidResponse {}
            _ = try await client.source.get(.head, 65_536)
        }
        let after = await client.currentState
        XCTAssertEqual(after.status, before.status); XCTAssertEqual(after.generation, before.generation)
        XCTAssertEqual(channel.cancellations.value, 0)
    }

    func testResponseExceedingRequestLimitPreservesConnection() async throws {
        let (client, channel, _) = try fixture(clock: TestClock())
        await client.start(); try await discover([mac], client: client); try await connected(client)
        let before = await client.currentState
        do { _ = try await client.source.get(.head, 1); XCTFail("Request limit ignored") }
        catch CatalogError.oversizedResponse {}
        let after = await client.currentState
        XCTAssertEqual(after.status, before.status); XCTAssertEqual(after.generation, before.generation)
        XCTAssertEqual(channel.cancellations.value, 0)
        let head = try await client.source.get(.head, 65_536)
        XCTAssertFalse(head.isEmpty)
        let recovered = await client.currentState
        XCTAssertEqual(recovered.status, before.status); XCTAssertEqual(recovered.generation, before.generation)
        XCTAssertEqual(channel.cancellations.value, 0)
    }

    func testOversizedExchangeFailureDisconnects() async throws {
        let (client, channel, _) = try fixture(clock: TestClock())
        await client.start(); try await discover([mac], client: client); try await connected(client)
        let before = await client.currentState.generation
        await channel.setOversizedFrameFailure(true)
        do { _ = try await client.source.get(.head, 65_536); XCTFail("Oversized frame accepted") }
        catch CatalogError.oversizedResponse {}
        let after = await client.currentState
        XCTAssertEqual(after.status, .disconnected); XCTAssertEqual(after.generation, before)
        XCTAssertEqual(channel.cancellations.value, 1)
    }

    func testSetupWaiterCancellationDoesNotCancelSharedConnection() async throws {
        for _ in 0..<20 {
            let gate = RecoveryGate()
            let channel = RecoveryChannel(startGate: gate)
            let (client, _, _) = try fixture(remembered: mac, channel: channel)
            await client.start(); try await discover([mac], client: client)
            try await wait { await gate.hasEntered }
            let canceled = Task { try await client.source.get(.head, 65_536) }
            let survivor = Task { try await client.source.get(.head, 65_536) }
            try await wait { await client.observerCount >= 2 }
            canceled.cancel()
            do { _ = try await canceled.value; XCTFail() } catch is CancellationError {}
            XCTAssertEqual(channel.cancellations.value, 0)
            await gate.release()
            let checked13 = try await survivor.value.isEmpty
            XCTAssertFalse(checked13)
            try await connected(client)
            try await wait { await client.observerCount == 0 }
            await client.stop()
        }
    }

    func testSetupTimeoutDoesNotCancelPairingAttempt() async throws {
        let clock = TestClock(); let gate = RecoveryGate()
        let channel = RecoveryChannel(startGate: gate)
        let (client, _, _) = try fixture(clock: clock, channel: channel)
        await client.start(); try await discover([mac], client: client)
        let request = Task { try await client.source.get(.head, 65_536) }
        try await wait { await client.observerCount == 1 }
        await clock.advance(by: .seconds(30))
        do { _ = try await request.value; XCTFail() } catch LocalCatalogError.timeout {}
        XCTAssertEqual(channel.cancellations.value, 0)
        await gate.release(); try await connected(client)
    }

    func testRevokedLegacyCredentialIsRemovedPersistentlyAndRelaunchPairsWithKnownPin() async throws {
        let secrets = RecoverySecrets(); let rejected = RecoveryChannel(); await rejected.setRevoked(true)
        let (client, _, _) = try fixture(remembered: mac, channel: rejected, secrets: secrets)
        await client.start(); try await discover([mac], client: client)
        try await wait { await client.currentState.status == .rejected }
        let stored = try XCTUnwrap(secrets.read("recovery-pairing"))
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: stored) as? [String: Any])
        XCTAssertNil(record["token"]); XCTAssertEqual(record["id"] as? String, mac.id)
        XCTAssertEqual(record["pin"] as? String, "test-pin")
        await client.stop()
        let (relaunched, channel, _) = try fixture(secrets: secrets)
        await relaunched.start(); try await discover([mac], client: relaunched); try await connected(relaunched)
        let operations = await channel.operations
        XCTAssertTrue(operations.contains("pair")); XCTAssertFalse(operations.contains("authenticate"))
        XCTAssertEqual(secrets.pins.compactMap { $0 }, ["test-pin", "test-pin"])
    }

    func testChangedPinRequiresExplicitRepair() async throws {
        let channel = RecoveryChannel(); await channel.setStartFailure(true)
        let (client, _, secrets) = try fixture(remembered: mac, channel: channel, pin: "new-pin")
        await client.start(); try await discover([mac], client: client)
        try await wait { await client.currentState.status == .identityChanged }
        try await discover([mac], client: client, sequence: 2)
        let checked14 = await client.currentState.status
        XCTAssertEqual(checked14, .identityChanged)
        await channel.setStartFailure(false); await client.choose(mac.id); try await connected(client)
        XCTAssertEqual(secrets.pins.count, 2); XCTAssertNil(secrets.pins.last!)
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(secrets.read("recovery-pairing"))) as? [String: Any])
        XCTAssertEqual(record["pin"] as? String, "new-pin")
    }

    func testTransportFailureReconnectsAndWakesAvailabilityWaitersWithoutDiscoveryChange() async throws {
        let clock = TestClock()
        let (client, channel, _) = try fixture(clock: clock)
        await client.start(); try await discover([mac], client: client); try await connected(client)
        let before = await client.currentState.generation
        await channel.setAssetTransportFailure(true)
        do { _ = try await client.source.get(.head, 65_536); XCTFail() } catch LocalCatalogError.disconnected {}
        let waiting = Task { try await client.source.waitForAvailability?() }
        try await wait { await client.observerCount == 1 }
        await channel.setAssetTransportFailure(false)
        await clock.advance(by: .seconds(1))
        try await connected(client); _ = try await waiting.value
        let after = await client.currentState.generation
        XCTAssertEqual(after, before + 1)
        XCTAssertEqual(channel.cancellations.value, 1)
        _ = try await client.source.get(.head, 65_536)
    }

    func testReconnectBackoffIsBoundedAndStopCancelsThePendingRetry() async throws {
        let clock = TestClock(); let channel = RecoveryChannel()
        await channel.setStartFailure(true)
        let (client, _, secrets) = try fixture(clock: clock, channel: channel)
        await client.start(); try await discover([mac], client: client)
        try await wait { await client.currentState.status == .disconnected }
        XCTAssertEqual(secrets.pins.count, 1)
        for (index, delay) in [1, 2, 4, 8, 16, 30, 30].enumerated() {
            await clock.advance(by: .seconds(delay))
            try await wait { secrets.pins.count == index + 2 }
        }
        await client.stop()
        let attempts = secrets.pins.count
        await clock.advance(by: .seconds(60))
        XCTAssertEqual(secrets.pins.count, attempts)
        let browser = await client.currentBrowserID
        XCTAssertNil(browser)
    }

    func testManualChooserRetainsWorkingConnectionAndCancelRestoresStatus() async throws {
        let (client, channel, _) = try fixture()
        await client.start(); try await discover([mac], client: client); try await connected(client)
        let before = await client.currentState
        await client.changeMac()
        let choosing = await client.currentState
        XCTAssertEqual(choosing.status, .chooseMac)
        _ = try await client.source.get(.head, 65_536)
        XCTAssertEqual(channel.cancellations.value, 0)
        await client.cancelMacChoice()
        let restored = await client.currentState
        XCTAssertEqual(restored.status, before.status)
        XCTAssertEqual(restored.generation, before.generation)
        XCTAssertNil(restored.macChoiceID)
    }

    func testCanceledQueuedForegroundEventCannotStopClient() async throws {
        let (client, _, _) = try fixture()
        await client.start(); try await discover([mac], client: client); try await connected(client)
        let obsolete = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await client.setForeground(false)
        }
        await obsolete.value
        let checked15 = await client.currentBrowserID
        XCTAssertNotNil(checked15)
        if case .connected = await client.currentState.status {} else { XCTFail("Canceled event stopped connection") }
        await client.setForeground(false)
        let checked16 = await client.currentBrowserID
        XCTAssertNil(checked16)
    }
}


private actor RecoveryChannel: LocalRequestConnection {
    nonisolated let cancellations = RecoveryCounter()
    nonisolated let serverIdentity = RecoveryIdentity()
    let startGate: RecoveryGate?
    private var pending = false
    private var revoked = false
    private var startFailure = false
    private var assetTransportFailure = false
    private var oversizedFrameFailure = false
    private(set) var operations: [String] = []
    init(startGate: RecoveryGate? = nil) { self.startGate = startGate }
    func setPending(_ value: Bool) { pending = value }
    func setRevoked(_ value: Bool) { revoked = value }
    func setStartFailure(_ value: Bool) { startFailure = value }
    func setAssetTransportFailure(_ value: Bool) { assetTransportFailure = value }
    func setOversizedFrameFailure(_ value: Bool) { oversizedFrameFailure = value }
    func start() async throws {
        if startFailure { throw LocalCatalogError.disconnected }
        try await startGate?.wait()
    }
    func pairingCode() -> String { "123456" }
    nonisolated func cancel() { cancellations.increment() }
    func exchange(_ packet: LocalPacket) throws -> LocalPacket {
        operations.append(packet.message.operation)
        var message = LocalMessage(operation: "ok")
        switch packet.message.operation {
        case "hello": message.serverID = serverIdentity.value
        case "authenticate": if revoked { message.error = "revoked" }
        case "pair", "pairStatus":
            if pending { message.operation = "pending" } else { message.token = "new-token" }
        case "asset":
            if assetTransportFailure { throw LocalCatalogError.disconnected }
            if oversizedFrameFailure { throw CatalogError.oversizedResponse }
            if packet.message.request?.isHead == true {
                return LocalPacket(message: message, payload: Data("{\"revision\":\"\(String(repeating: "c", count: 64))\"}".utf8))
            }
            message.error = "invalidAsset"
        default: break
        }
        return LocalPacket(message: message)
    }
}

private nonisolated final class RecoveryCounter: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
private nonisolated final class RecoverySecrets: @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: Data] = [:]
    private var expectedPins: [String?] = []
    var pins: [String?] { lock.withLock { expectedPins } }
    func recordPin(_ pin: String?) { lock.withLock { expectedPins.append(pin) } }
    func read(_ key: String) throws -> Data? { lock.withLock { files[key] } }
    func write(_ data: Data, _ key: String) throws { lock.withLock { files[key] = data } }
    func remove(_ key: String) throws { _ = lock.withLock { files.removeValue(forKey: key) } }
    func seedPairing(id: String, name: String, pin: String, token: String) throws {
        try write(JSONSerialization.data(withJSONObject: ["id": id, "name": name, "pin": pin, "token": token]), "recovery-pairing")
    }
}

private nonisolated final class RecoveryIdentity: @unchecked Sendable {
    private let lock = NSLock(); private var id = ""
    var value: String { lock.withLock { id } }
    func set(_ value: String) { lock.withLock { id = value } }
}
