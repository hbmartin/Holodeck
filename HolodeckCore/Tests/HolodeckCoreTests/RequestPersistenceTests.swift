#if os(macOS)
import Foundation
import XCTest
@testable import HolodeckCore

@MainActor final class RequestPersistenceTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    func testCriticalCommitSkipsUnchangedFilesAndSupersedesProgress() async throws {
        let root = try directory(), probe = PersistenceWriteProbe()
        let writer = RequestPersistence(recoveryWriter: { try probe.write($0, $1) }), file = root.appendingPathComponent("recovery.json")
        func snapshot(_ revision: UInt64, _ text: String) -> RequestPersistence.Snapshot { .init(revision: revision, files: [.init(url: file, bytes: Data(text.utf8))]) }
        probe.hold()
        let initial = Task { try await writer.commit(snapshot(1, "first")) }
        defer { probe.release(); initial.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !probe.entered, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(probe.entered)
        for revision in 3...102 { writer.enqueueProgress(snapshot(UInt64(revision), "progress-\(revision)")) { _ in XCTFail("Progress write failed") } }
        probe.release(); try await initial.value
        try await writer.commit(snapshot(103, "confirmed"))
        XCTAssertEqual(try Data(contentsOf: file), Data("confirmed".utf8))
        XCTAssertLessThanOrEqual(probe.count, 3); XCTAssertFalse(probe.wroteOnMain)
        try await writer.commit(snapshot(104, "confirmed")); XCTAssertLessThanOrEqual(probe.count, 3)
    }
    func testFailureStopsQueuedMutationsButCanRetainRecoveryEvidence() async throws {
        let root = try directory(), probe = PersistenceWriteProbe(), file = root.appendingPathComponent("recovery.json")
        let writer = RequestPersistence(recoveryWriter: { try probe.write($0, $1) })
        func snapshot(_ n: UInt64, _ text: String) -> RequestPersistence.Snapshot { .init(revision: n, files: [.init(url: file, bytes: Data(text.utf8))]) }
        probe.failAfterPublication()
        do { try await writer.commit(snapshot(1, "pending intent")); XCTFail("Uncertain write succeeded") } catch {}
        do { try await writer.commit(snapshot(2, "unrelated state")); XCTFail("A failed proposal was silently committed") } catch {}
        XCTAssertEqual(try Data(contentsOf: file), Data("pending intent".utf8))
        try await writer.commit(snapshot(3, "retained recovery"), retainingEvidence: true)
        do { try await writer.commit(snapshot(4, "still blocked")); XCTFail("Evidence write cleared the failure") } catch {}
        try await writer.resumeAfterExplicitRecovery()
        try await writer.commit(snapshot(5, "explicitly recovered"))
        XCTAssertEqual(try Data(contentsOf: file), Data("explicitly recovered".utf8))
    }
    func testSlowDiskDoesNotBlockMainActorAndCriticalAckWaits() async throws {
        let root = try directory(), probe = PersistenceWriteProbe()
        probe.hold()
        let writer = RequestPersistence(recoveryWriter: { try probe.write($0, $1) })
        let writing = Task { try await writer.commit(.init(revision: 1, files: [.init(url: root.appendingPathComponent("recovery.json"), bytes: Data("data".utf8))])) }
        defer { probe.release(); writing.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !probe.entered, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(probe.entered); XCTAssertFalse(probe.wroteOnMain)
        let responsive = expectation(description: "Main actor remains responsive")
        Task { @MainActor in responsive.fulfill() }
        await fulfillment(of: [responsive], timeout: 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("recovery.json").path))
        probe.release(); try await writing.value
    }
    func testRejectedChangeRestoresAllEarlierWritesButRetainsIndependentRecoveryIntent() async throws {
        let root = try directory(), probe = PersistenceWriteProbe(), writer = RequestPersistence(directory: root, recoveryWriter: { try probe.write($0, $1) })
        let preferences = root.appendingPathComponent("preferences.json"), payload = root.appendingPathComponent("request.json"), recovery = root.appendingPathComponent("recovery.json"), id = UUID()
        let accepted = Data("accepted settings".utf8); try accepted.write(to: preferences)
        try await writer.begin(id, operation: "rejected proposal")
        try await writer.write(Data("rejected settings".utf8), to: preferences, transaction: id)
        try await writer.write(Data("rejected payload".utf8), to: payload, transaction: id)
        probe.failAfterPublication()
        do { try await writer.commit(.init(revision: 1, files: [.init(url: recovery, bytes: Data("proposal".utf8))]), transaction: id); XCTFail("Uncertain commit succeeded") } catch {}
        try await writer.commit(.init(revision: 2, files: [.init(url: recovery, bytes: Data("durable Detach intent".utf8))]), retainingEvidence: true)
        try await writer.reject(id)
        XCTAssertEqual(try Data(contentsOf: preferences), accepted)
        XCTAssertFalse(RequestProcessIdentity.evidenceExists(payload))
        XCTAssertEqual(try Data(contentsOf: recovery), Data("durable Detach intent".utf8))
        let fault = await writer.fault(); XCTAssertEqual(fault?.operation, "rejected proposal")
        try await writer.resumeAfterExplicitRecovery()
        XCTAssertEqual(try Data(contentsOf: preferences), accepted)
        XCTAssertEqual(try Data(contentsOf: recovery), Data("durable Detach intent".utf8))
    }
    func testRestartCannotSilentlyAcceptAnUncertainRejectedChange() async throws {
        let root = try directory(), probe = PersistenceWriteProbe(), file = root.appendingPathComponent("recovery.json")
        let writer = RequestPersistence(directory: root, recoveryWriter: { try probe.write($0, $1) })
        try Data("accepted".utf8).write(to: file); probe.failAfterPublication()
        do { try await writer.write(Data("rejected".utf8), to: file); XCTFail("Uncertain replacement succeeded") } catch {}
        let restarted = RequestPersistence(directory: root)
        let fault = try await restarted.loadFault(); XCTAssertNotNil(fault)
        do { try await restarted.resumeAfterExplicitRecovery(); XCTFail("Lost rollback bytes were silently accepted") } catch {}
        XCTAssertEqual(try Data(contentsOf: file), Data("rejected".utf8))
        try Data("accepted".utf8).write(to: file)
        try await restarted.resumeAfterExplicitRecovery()
        XCTAssertFalse(RequestProcessIdentity.evidenceExists(root.appendingPathComponent("storage-recovery.json")))
    }
    func testFailedRestorationStaysBlockedAndNewerFaultCannotBeCleared() async throws {
        let root = try directory(), probe = PersistenceWriteProbe(), file = root.appendingPathComponent("recovery.json")
        let writer = RequestPersistence(directory: root, recoveryWriter: { try probe.write($0, $1) }), id = UUID()
        try Data("accepted".utf8).write(to: file)
        try await writer.begin(id, operation: "first proposal"); probe.failAfterPublication()
        do { try await writer.write(Data("rejected".utf8), to: file, transaction: id) } catch {}
        let first = await writer.fault()
        try FileManager.default.removeItem(at: file); try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        do { try await writer.reject(id); XCTFail("Obstructed rollback succeeded") } catch {}
        let second = await writer.fault(); XCTAssertGreaterThan(second!.generation, first!.generation)
        XCTAssertEqual(second?.operation, first?.operation)
        do { try await writer.finishRecovery(first?.id); XCTFail("Stale recovery cleared a new failure") } catch {}
        do { try await writer.write(Data("unrelated".utf8), to: root.appendingPathComponent("other")); XCTFail("Unrelated work bypassed failed restoration") } catch {}
        try FileManager.default.removeItem(at: file); try Data("accepted".utf8).write(to: file)
        try await writer.resumeAfterExplicitRecovery()
    }
    func testRecoveryDiagnosticsAreBoundedDeduplicatedAndReadable() throws {
        let root = try directory(), key = root.appendingPathComponent("setup").path
        var entry = RequestRecoveryStore.Entry(journal: key, configuration: nil, disposition: .resume, message: String(repeating: "🐟", count: 10000))
        for n in 0..<100 { entry.appendDiagnostic("Failure \(n) " + String(repeating: "é", count: 3000)) }
        let before = entry.secondaryDiagnostics
        entry.appendDiagnostic("Failure 99 " + String(repeating: "é", count: 3000))
        XCTAssertEqual(entry.secondaryDiagnostics, before)
        XCTAssertLessThanOrEqual(entry.primaryDiagnostic?.utf8.count ?? 0, 8192)
        XCTAssertEqual(entry.secondaryDiagnostics?.count, 8)
        XCTAssertTrue(entry.secondaryDiagnostics!.allSatisfy { $0.utf8.count <= 2048 && !$0.contains("�") })
        var store = RequestRecoveryStore(); store.entries[key] = entry
        let bytes = try store.encoded(); XCTAssertLessThanOrEqual(bytes.count, CatalogLimits.manifestBytes)
        XCTAssertNoThrow(try JSONDecoder().decode(RequestRecoveryStore.self, from: bytes))
    }
    func testEssentialRecoveryMetadataCannotExceedReaderCapacity() throws {
        let root = try directory(), file = root.appendingPathComponent("recovery.json")
        let lastGood = Data("last good bytes".utf8); try lastGood.write(to: file)
        var config = ShaderRequestConfiguration(repository: root.path); config.model = String(repeating: "m", count: CatalogLimits.manifestBytes)
        var store = RequestRecoveryStore(); store.entries[root.path] = .init(journal: root.path, configuration: config, disposition: .resume, message: "Essential ownership metadata")
        XCTAssertThrowsError(try store.encoded())
        XCTAssertEqual(try Data(contentsOf: file), lastGood)
    }
    func testDiagnosticAppendRejectsSymlink() throws {
        let root = try directory(), target = root.appendingPathComponent("retained"), log = root.appendingPathComponent("recovery-diagnostic.log")
        let bytes = Data("retained original".utf8); try bytes.write(to: target)
        try FileManager.default.createSymbolicLink(at: log, withDestinationURL: target)
        XCTAssertThrowsError(try RequestJournalWriter.appendDiagnostic("untrusted diagnostic", to: log))
        XCTAssertEqual(try Data(contentsOf: target), bytes)
    }
}

private final class PersistenceWriteProbe: @unchecked Sendable {
    private let lock = NSLock(), gate = DispatchSemaphore(value: 0)
    private var writes = 0, main = false, fail = false, holding = false, waiting = false
    var count: Int { lock.withLock { writes } }
    var wroteOnMain: Bool { lock.withLock { main } }
    var entered: Bool { lock.withLock { waiting } }
    func failAfterPublication() { lock.withLock { fail = true } }
    func hold() { lock.withLock { holding = true } }
    func release() { lock.withLock { holding = false }; gate.signal() }
    func write(_ bytes: Data, _ file: URL) throws {
        let hold = lock.withLock { writes += 1; main = main || Thread.isMainThread; waiting = true; return holding }
        if hold, gate.wait(timeout: .now() + 5) != .success { throw POSIXError(.ETIMEDOUT) }
        try RequestJournalWriter.write(bytes, to: file)
        if lock.withLock({ let value = fail; fail = false; return value }) { throw POSIXError(.EIO) }
    }
}
#endif
