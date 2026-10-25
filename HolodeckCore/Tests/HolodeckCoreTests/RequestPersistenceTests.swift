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
        await writer.resumeAfterExplicitRecovery()
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
