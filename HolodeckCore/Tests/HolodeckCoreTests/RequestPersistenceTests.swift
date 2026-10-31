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
    func testRejectedTentativeRevisionDoesNotSupersedeIndependentEvidence() async throws {
        let root = try directory(), file = root.appendingPathComponent("recovery.json"), id = UUID()
        let baseline = Data("accepted".utf8), evidence = Data("retained ownership".utf8)
        try baseline.write(to: file)
        let writer = RequestPersistence(directory: root, beforeReplacement: { if $0.lastPathComponent == "fail.json" { throw POSIXError(.EIO) } })
        try await writer.begin(id, operation: "rejected newer proposal")
        do {
            try await writer.commit(.init(revision: 2, files: [.init(url: file, bytes: evidence), .init(url: root.appendingPathComponent("fail.json"), bytes: Data())]), transaction: id)
            XCTFail("Injected replacement succeeded")
        } catch {}
        try await writer.reject(id)
        try await writer.commit(.init(revision: 1, files: [.init(url: file, bytes: evidence)]), retainingEvidence: true)
        XCTAssertEqual(try Data(contentsOf: file), evidence)
    }
    func testSubmissionAdmissionPrecedesAwaitAndReceiptSurvivesEarlyCompletion() async throws {
        let root = try directory(), file = root.appendingPathComponent("journal.json"), writer = RequestPersistence()
        let first = writer.submit(.init(revision: 1, files: [.init(url: file, bytes: Data("one".utf8))]))
        let second = writer.submit(.init(revision: 2, files: [.init(url: file, bytes: Data("two".utf8))]))
        _ = try await second.value()
        _ = try await first.value()
        XCTAssertEqual(try Data(contentsOf: file), Data("two".utf8))
    }
    func testRecoveryAuthorizationNeverPermitsOrdinaryOrStaleWrites() async throws {
        let root = try directory(), file = root.appendingPathComponent("recovery.json"), probe = PersistenceWriteProbe()
        let writer = RequestPersistence(directory: root, recoveryWriter: { try probe.write($0, $1) })
        try Data("accepted".utf8).write(to: file); probe.failAfterPublication()
        do { try await writer.write(Data("rejected".utf8), to: file) } catch {}
        let token = try await writer.restoreForRecovery()
        do { try await writer.write(Data("ordinary".utf8), to: file); XCTFail("Ordinary write entered recovery") } catch {}
        await writer.abortRecovery(token)
        try Data("manual repair".utf8).write(to: file)
        do { try await writer.write(Data("stale".utf8), to: file, recovery: token); XCTFail("Aborted recovery wrote") } catch {}
        XCTAssertEqual(try Data(contentsOf: file), Data("manual repair".utf8))
    }
    func testBlockedWriteAddsNeitherCandidateNorFaultSummaryWrite() async throws {
        let root = try directory(), file = root.appendingPathComponent("recovery.json"), probe = PersistenceWriteProbe()
        let writer = RequestPersistence(directory: root, recoveryWriter: { try probe.write($0, $1) })
        try Data("accepted".utf8).write(to: file); probe.failAfterPublication()
        do { try await writer.write(Data("attempted".utf8), to: file) } catch {}
        let summary = try Data(contentsOf: root.appendingPathComponent("storage-recovery.json"))
        do { try await writer.write(Data("never attempted".utf8), to: file) } catch {}
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("storage-recovery.json")), summary)
        try Data("never attempted".utf8).write(to: file)
        do { _ = try await writer.restoreForRecovery(); XCTFail("Unattempted content accepted as writer-owned") } catch {}
        XCTAssertEqual(try Data(contentsOf: file), Data("never attempted".utf8))
    }
    func testNoFaultRecoveryDoesNotRemoveAnythingAndSupportsRootAlias() async throws {
        let root = try directory(), target = root.appendingPathComponent("real"), alias = root.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        let writer = RequestPersistence(directory: alias, removeFile: { _ in XCTFail("No fault marker should be removed") })
        let token = try await writer.restoreForRecovery(); XCTAssertNil(token)
        _ = try await writer.finishRecovery(token)
        try RequestJournalWriter.remove(alias.appendingPathComponent("absent"))
        let fault = await writer.fault(); XCTAssertNil(fault)
    }
    func testProgressValidationIsNotAnUnrelatedDirectWriteFault() async throws {
        let root = try directory(), writer = RequestPersistence(directory: root), probe = PersistenceWriteProbe()
        probe.hold()
        let held = Task { try await writer.perform { try probe.write(Data(), root.appendingPathComponent("gate")) } }
        while !probe.entered { try await Task.sleep(for: .milliseconds(1)) }
        writer.enqueueProgress(.init(revision: 1, files: [.init(url: root.appendingPathComponent("recovery.json"), encode: { throw RequestPersistence.ValidationError(message: "capacity") })])) { _ in }
        let direct = Task { try await writer.write(Data("unrelated".utf8), to: root.appendingPathComponent("other")) }
        probe.release(); try await held.value
        do { try await direct.value; XCTFail("Invalid pending progress was ignored") } catch { XCTAssertTrue(error is RequestPersistence.ValidationError) }
        let fault = await writer.fault(); XCTAssertNil(fault)
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
        probe.release(); _ = try await initial.value
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
        probe.release(); _ = try await writing.value
    }
    func testRecoveryOnlyBarrierRetainsJournalProgressAndEncodesOnlySurvivors() async throws {
        let root = try directory(), probe = PersistenceWriteProbe(), recovery = root.appendingPathComponent("recovery.json"), journal = root.appendingPathComponent("journal.json")
        let writer = RequestPersistence(recoveryWriter: { try probe.write($0, $1) })
        probe.hold()
        let initial = Task { try await writer.commit(.init(revision: 1, files: [.init(url: recovery, bytes: Data("initial".utf8))])) }
        defer { probe.release(); initial.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !probe.entered, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertTrue(probe.entered)
        for n in 2...101 {
            writer.enqueueProgress(.init(revision: UInt64(n), files: [
                .init(url: recovery, encode: { Data("recovery-\(n)".utf8) }),
                .init(url: journal, encode: { Data("journal-\(n)".utf8) })])) { _ in XCTFail("Progress failed") }
        }
        let critical = Task { try await writer.commit(.init(revision: 102, files: [.init(url: recovery, bytes: Data("critical".utf8))])) }
        await Task.yield(); probe.release(); _ = try await initial.value; _ = try await critical.value
        try await writer.write(Data(), to: root.appendingPathComponent("barrier"))
        XCTAssertEqual(try Data(contentsOf: recovery), Data("critical".utf8))
        XCTAssertEqual(try Data(contentsOf: journal), Data("journal-101".utf8))
        let stats = await writer.statistics()
        XCTAssertLessThanOrEqual(stats["encodings", default: 1000], 4)
        XCTAssertEqual(stats["journal.json"], 1)
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
    func testRollbackRecognizesEarlierOwnWritesAndReleasesPayloadBytes() async throws {
        let root = try directory(), probe = PersistenceWriteProbe(), writer = RequestPersistence(directory: root, recoveryWriter: { try probe.write($0, $1) })
        let file = root.appendingPathComponent("recovery.json"), accepted = Data("accepted".utf8), id = UUID()
        try accepted.write(to: file)
        try await writer.begin(id, operation: "multi-write proposal")
        try await writer.write(Data("intermediate own proposal".utf8), to: file, transaction: id)
        probe.failBeforePublication()
        do { try await writer.write(accepted, to: file, transaction: id); XCTFail("Failed restoration write succeeded") } catch {}
        try await writer.reject(id)
        XCTAssertEqual(try Data(contentsOf: file), accepted)
        try await writer.resumeAfterExplicitRecovery()
        try await writer.commit(.init(revision: 1, files: [.init(url: file, bytes: accepted)]))
        for n in 0..<20 { try await writer.write(Data(repeating: UInt8(n), count: 65536), to: root.appendingPathComponent("payload-\(n)")) }
        let stats = await writer.statistics()
        XCTAssertEqual(stats["retainedBytes"], accepted.count, "Completed payload writes must not retain screenshots or source in the metadata cache")
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
        do { try await writer.finishRecovery(.init(faultID: first!.id, generation: first!.generation, attemptID: UUID(), reloadAccepted: false)); XCTFail("Stale recovery cleared a new failure") } catch {}
        do { try await writer.write(Data("unrelated".utf8), to: root.appendingPathComponent("other")); XCTFail("Unrelated work bypassed failed restoration") } catch {}
        try FileManager.default.removeItem(at: file); try Data("accepted".utf8).write(to: file)
        try await writer.resumeAfterExplicitRecovery()
    }
    func testQueuedCommitCancellationReturnsBeforeTheWriterIsAvailable() async throws {
        let root = try directory(), probe = PersistenceWriteProbe(), writer = RequestPersistence(recoveryWriter: { try probe.write($0, $1) })
        let held = root.appendingPathComponent("recovery.json"), cancelled = root.appendingPathComponent("cancelled")
        probe.hold()
        let first = Task { try await writer.commit(.init(revision: 1, files: [.init(url: held, bytes: Data("first".utf8))])) }
        defer { probe.release(); first.cancel() }
        while !probe.entered { try await Task.sleep(for: .milliseconds(2)) }
        let finished = expectation(description: "Queued cancellation is prompt")
        let second = Task {
            do { try await writer.commit(.init(revision: 2, files: [.init(url: cancelled, bytes: Data("never".utf8))])); XCTFail("Cancelled commit succeeded") }
            catch { XCTAssertTrue(error is CancellationError) }
            finished.fulfill()
        }
        await Task.yield(); second.cancel()
        await fulfillment(of: [finished], timeout: 1)
        XCTAssertFalse(RequestProcessIdentity.evidenceExists(cancelled))
        probe.release(); _ = try await first.value
        let fault = await writer.fault(); XCTAssertNil(fault)
    }
    func testCancellationAfterReplacementStartsReportsAcceptedOutcome() async throws {
        let root = try directory(), probe = PersistenceWriteProbe(), file = root.appendingPathComponent("recovery.json")
        let writer = RequestPersistence(recoveryWriter: { try probe.write($0, $1) })
        probe.hold()
        let commit = Task { try await writer.commit(.init(revision: 1, files: [.init(url: file, bytes: Data("accepted".utf8))])) }
        defer { probe.release(); commit.cancel() }
        while !probe.entered { try await Task.sleep(for: .milliseconds(2)) }
        commit.cancel(); probe.release(); _ = try await commit.value
        XCTAssertEqual(try Data(contentsOf: file), Data("accepted".utf8))
        let fault = await writer.fault(); XCTAssertNil(fault)
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
    private var writes = 0, main = false, fail = false, failBefore = false, holding = false, waiting = false
    var count: Int { lock.withLock { writes } }
    var wroteOnMain: Bool { lock.withLock { main } }
    var entered: Bool { lock.withLock { waiting } }
    func failAfterPublication() { lock.withLock { fail = true } }
    func failBeforePublication() { lock.withLock { failBefore = true } }
    func hold() { lock.withLock { holding = true } }
    func release() { lock.withLock { holding = false }; gate.signal() }
    func write(_ bytes: Data, _ file: URL) throws {
        let hold = lock.withLock { writes += 1; main = main || Thread.isMainThread; waiting = true; return holding }
        if hold, gate.wait(timeout: .now() + 5) != .success { throw POSIXError(.ETIMEDOUT) }
        if lock.withLock({ let value = failBefore; failBefore = false; return value }) { throw POSIXError(.ENOSPC) }
        try RequestJournalWriter.write(bytes, to: file)
        if lock.withLock({ let value = fail; fail = false; return value }) { throw POSIXError(.EIO) }
    }
}
#endif

#if os(macOS)
extension RequestPersistenceTests {
    func testSecondaryFaultRetainsRejectedTransactionRollbackImages() async throws {
        let root = try directory(), probe = PersistenceWriteProbe(), participant = root.appendingPathComponent("participant/recovery.json"), other = root.appendingPathComponent("recovery.json")
        let writer = RequestPersistence(directory: root, recoveryWriter: { try probe.write($0, $1) }), id = UUID()
        try FileManager.default.createDirectory(at: participant.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("accepted participant".utf8).write(to: participant); try Data("accepted other".utf8).write(to: other)
        try await writer.begin(id, operation: "participant proposal")
        try await writer.write(Data("rejected participant".utf8), to: participant, transaction: id)
        probe.failBeforePublication()
        do { try await writer.write(Data("rejected other".utf8), to: other, transaction: nil); XCTFail("Fault succeeded") } catch {}
        probe.failBeforePublication()
        do { try await writer.reject(id); XCTFail("Rollback fault succeeded") } catch {}
        try await writer.resumeAfterExplicitRecovery()
        XCTAssertEqual(try Data(contentsOf: participant), Data("accepted participant".utf8))
        XCTAssertEqual(try Data(contentsOf: other), Data("accepted other".utf8))
    }
    func testRepeatedRecoveryRecognizesItsFailedConvergenceWrite() async throws {
        let root = try directory(), file = root.appendingPathComponent("recovery.json"), probe = PersistenceWriteProbe()
        let writer = RequestPersistence(directory: root, recoveryWriter: { try probe.write($0, $1) })
        try Data("accepted".utf8).write(to: file); probe.failAfterPublication()
        do { try await writer.write(Data("rejected".utf8), to: file) } catch {}
        let first = try await writer.restoreForRecovery(); probe.failAfterPublication()
        do { try await writer.write(Data("converged".utf8), to: file, recovery: first); XCTFail("Convergence fault succeeded") } catch {}
        let second = try await writer.restoreForRecovery()
        XCTAssertGreaterThan(second!.generation, first!.generation)
        try await writer.write(Data("converged".utf8), to: file, recovery: second)
        let receipt = try await writer.finishRecovery(second)
        XCTAssertEqual(receipt.clearedGeneration, second?.generation)
        XCTAssertEqual(try Data(contentsOf: file), Data("converged".utf8))
    }
    func testFailedRecoveryMarkerRemovalKeepsConvergedBaselineAndRejectsStaleToken() async throws {
        let root = try directory(), file = root.appendingPathComponent("recovery.json"), probe = PersistenceWriteProbe(), removal = RecoveryRemovalProbe()
        let writer = RequestPersistence(directory: root, recoveryWriter: { try probe.write($0, $1) }, removeFile: { try removal.remove($0) })
        try Data("accepted".utf8).write(to: file); probe.failAfterPublication()
        do { try await writer.write(Data("rejected".utf8), to: file) } catch {}
        let first = try await writer.restoreForRecovery()
        try await writer.write(Data("converged".utf8), to: file, recovery: first)
        removal.arm()
        do { try await writer.finishRecovery(first); XCTFail("Failed removal succeeded") } catch {}
        do { try await writer.finishRecovery(first); XCTFail("Stale token cleared a new fault") } catch {}
        let second = try await writer.restoreForRecovery()
        XCTAssertEqual(try Data(contentsOf: file), Data("converged".utf8))
        let receipt = try await writer.finishRecovery(second)
        XCTAssertGreaterThan(receipt.clearedGeneration, first!.generation)
        XCTAssertFalse(RequestProcessIdentity.evidenceExists(root.appendingPathComponent("storage-recovery.json")))
    }
}
private final class RecoveryRemovalProbe: @unchecked Sendable {
    private let lock = NSLock(); private var fail = false
    func arm() { lock.withLock { fail = true } }
    func remove(_ file: URL) throws {
        if lock.withLock({ let value = fail; fail = false; return value }) { throw POSIXError(.EIO) }
        try RequestJournalWriter.remove(file)
    }
}
#endif

#if os(macOS)
extension RequestPersistenceTests {
    func testEncodingFailureDoesNotCreateStorageFaultOrReplaceAnyFile() async throws {
        let root = try directory(), file = root.appendingPathComponent("recovery.json"), other = root.appendingPathComponent("journal.json"), writer = RequestPersistence(directory: root)
        try Data("accepted".utf8).write(to: file)
        do {
            try await writer.commit(.init(revision: 1, files: [
                .init(url: other, bytes: Data("unpublished".utf8)),
                .init(url: file, encode: { throw RequestWorkerEvidenceError(cause: "Invalid metadata") })]))
            XCTFail("Invalid encoding succeeded")
        } catch { XCTAssertTrue(error is RequestPersistence.ValidationError) }
        let fault = await writer.fault(); XCTAssertNil(fault)
        XCTAssertEqual(try Data(contentsOf: file), Data("accepted".utf8)); XCTAssertFalse(RequestProcessIdentity.evidenceExists(other))
        try await writer.commit(.init(revision: 2, files: [.init(url: file, bytes: Data("valid".utf8))]))
    }
    func testRecoveryReceiptReturnsCapacityTrimmingAndCapturedGeneration() async throws {
        let root = try directory(), file = root.appendingPathComponent("recovery.json"), writer = RequestPersistence()
        var store = RequestRecoveryStore()
        for n in 0..<96 {
            let key = root.appendingPathComponent("journal-\(n)").path
            var entry = RequestRecoveryStore.Entry(journal: key, disposition: .resume, message: String(repeating: "p", count: 8192))
            for i in 0..<8 { entry.appendDiagnostic("detail \(i) " + String(repeating: "é", count: 1000)) }
            store.entries[key] = entry
        }
        let receipt = try await writer.commit(.init(revision: 1, files: [.init(url: file, recovery: store, generation: 42)]))
        let normalized = try XCTUnwrap(receipt.recovery[file])
        XCTAssertEqual(normalized.generation, 42); XCTAssertEqual(normalized.store.entries.count, 96)
        XCTAssertTrue(normalized.store.entries.values.allSatisfy { $0.secondaryDiagnostics?.isEmpty == true })
        XCTAssertLessThanOrEqual(try Data(contentsOf: file).count, CatalogLimits.manifestBytes)
        XCTAssertTrue(store.entries.values.allSatisfy { $0.secondaryDiagnostics?.count == 8 }, "Snapshot input remains immutable")
    }
    func testEssentialRecoveryCapacityFailureIsValidationNotStickyIOFailure() async throws {
        let root = try directory(), file = root.appendingPathComponent("recovery.json"), writer = RequestPersistence(directory: root)
        let good = Data("accepted".utf8); try good.write(to: file)
        var configuration = ShaderRequestConfiguration(repository: root.path); configuration.model = String(repeating: "m", count: CatalogLimits.manifestBytes)
        var store = RequestRecoveryStore(); store.entries[root.path] = .init(journal: root.path, configuration: configuration, disposition: .resume, message: "Essential metadata")
        do { try await writer.commit(.init(revision: 1, files: [.init(url: file, recovery: store, generation: 1)])); XCTFail("Oversized ownership data succeeded") }
        catch { XCTAssertTrue(error is RequestPersistence.ValidationError) }
        let fault = await writer.fault(); XCTAssertNil(fault); XCTAssertEqual(try Data(contentsOf: file), good)
    }
}
#endif

#if os(macOS)
extension RequestPersistenceTests {
    func testOwnedPreferencesAvoidRepeatedReadsAndUnchangedReplacements() async throws {
        let root = try directory(), file = root.appendingPathComponent("preferences.json"), writer = RequestPersistence()
        try Data("old".utf8).write(to: file)
        try await writer.write(Data("accepted".utf8), to: file)
        let initial = await writer.statistics()
        for _ in 0..<20 { try await writer.write(Data("accepted".utf8), to: file) }
        try await writer.write(Data("new accepted".utf8), to: file)
        let after = await writer.statistics()
        XCTAssertEqual(after["reads"], initial["reads"])
        XCTAssertEqual(after["preferences.json", default: 0] - initial["preferences.json", default: 0], 1)
        for n in 0..<12 { try await writer.write(Data(repeating: UInt8(n), count: 65536), to: root.appendingPathComponent("payload-\(n)")) }
        let bounded = await writer.statistics(); XCTAssertEqual(bounded["retainedBytes"], Data("new accepted".utf8).count)
    }
}
#endif

#if os(macOS)
extension RequestPersistenceTests {
    func testCancelledEncodingAbandonsDraftWithoutWaitingForRollback() async throws {
        let root = try directory(), writer = RequestPersistence(), gate = EncodingPause(), file = root.appendingPathComponent("never-written"), id = UUID()
        try await writer.begin(id, operation: "cancelled draft")
        let finished = expectation(description: "Cancellation does not wait for the encoder")
        let commit = Task {
            do { try await writer.commit(.init(revision: 1, files: [.init(url: file, encode: { gate.pause(); return Data("cancelled".utf8) })]), transaction: id); XCTFail("Cancelled proposal committed") }
            catch { XCTAssertTrue(error is CancellationError); writer.abandon(id) }
            finished.fulfill()
        }
        defer { gate.release(); commit.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !gate.entered, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertTrue(gate.entered); commit.cancel()
        await fulfillment(of: [finished], timeout: 1)
        gate.release(); try await writer.perform {}
        XCTAssertFalse(RequestProcessIdentity.evidenceExists(file)); let fault = await writer.fault(); XCTAssertNil(fault)
    }
    func testCancellationShapedIOFailureAfterMutationStillRequiresRollback() async throws {
        let root = try directory(), first = root.appendingPathComponent("a"), second = root.appendingPathComponent("b"), fault = CancellationReplacementProbe()
        let writer = RequestPersistence(directory: root, beforeReplacement: { try fault.check($0) })
        try Data("accepted-a".utf8).write(to: first); try Data("accepted-b".utf8).write(to: second)
        do { try await writer.commit(.init(revision: 1, files: [.init(url: first, bytes: Data("rejected-a".utf8)), .init(url: second, bytes: Data("rejected-b".utf8))])); XCTFail("Partial mutation succeeded") }
        catch { XCTAssertTrue(error is RequestPersistence.Fault) }
        try await writer.resumeAfterExplicitRecovery()
        XCTAssertEqual(try Data(contentsOf: first), Data("accepted-a".utf8)); XCTAssertEqual(try Data(contentsOf: second), Data("accepted-b".utf8))
    }
}
private final class EncodingPause: @unchecked Sendable {
    private let lock = NSLock(), gate = DispatchSemaphore(value: 0)
    private var waiting = false
    var entered: Bool { lock.withLock { waiting } }
    func pause() { lock.withLock { waiting = true }; _ = gate.wait(timeout: .now() + 5) }
    func release() { gate.signal() }
}
private final class CancellationReplacementProbe: @unchecked Sendable {
    private let lock = NSLock(); private var armed = true
    func check(_ file: URL) throws {
        let fail = lock.withLock {
            guard file.lastPathComponent == "b", armed else { return false }
            armed = false; return true
        }
        if fail { throw CancellationError() }
    }
}
#endif

#if os(macOS)
extension RequestPersistenceTests {
    func testRejectedEncodingDoesNotDiscardCoveredAcceptedProgress() async throws {
        let root = try directory(), file = root.appendingPathComponent("journal.json"), writer = RequestPersistence(), gate = EncodingPause()
        let held = Task { try await writer.perform { gate.pause() } }
        defer { gate.release(); held.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !gate.entered, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertTrue(gate.entered)
        writer.enqueueProgress(.init(revision: 1, files: [.init(url: file, bytes: Data("accepted progress".utf8))])) { _ in XCTFail("Accepted progress failed") }
        let rejected = Task {
            do { try await writer.commit(.init(revision: 2, files: [.init(url: file, encode: { throw RequestPersistence.ValidationError(message: "Invalid proposal") })])); XCTFail("Invalid proposal succeeded") }
            catch { XCTAssertTrue(error is RequestPersistence.ValidationError) }
        }
        await Task.yield(); gate.release(); try await held.value; await rejected.value
        try await writer.write(Data(), to: root.appendingPathComponent("barrier"))
        XCTAssertEqual(try Data(contentsOf: file), Data("accepted progress".utf8))
    }
}
#endif

#if os(macOS)
extension RequestPersistenceTests {
    func testRecoveryRetriesRestorationThatPublishedAcceptedBytesBeforeFailing() async throws {
        let root = try directory(), probe = PersistenceWriteProbe(), file = root.appendingPathComponent("recovery.json"), id = UUID()
        let writer = RequestPersistence(directory: root, recoveryWriter: { try probe.write($0, $1) })
        let accepted = Data("accepted".utf8); try accepted.write(to: file)
        try await writer.begin(id, operation: "rejected proposal")
        try await writer.write(Data("rejected".utf8), to: file, transaction: id)
        probe.failAfterPublication()
        do { try await writer.reject(id); XCTFail("Uncertain restoration succeeded") } catch {}
        XCTAssertEqual(try Data(contentsOf: file), accepted)
        let before = probe.count
        try await writer.resumeAfterExplicitRecovery()
        XCTAssertGreaterThan(probe.count, before, "Matching bytes must still complete an interrupted restoration sync")
        XCTAssertEqual(try Data(contentsOf: file), accepted)
    }
    func testRecoveryRetriesDirectorySyncAfterRejectedFileWasAlreadyRemoved() async throws {
        let root = try directory(), probe = PersistenceWriteProbe(), removal = InterruptedRemovalProbe()
        let writer = RequestPersistence(directory: root, recoveryWriter: { try probe.write($0, $1) }, removeFile: { try removal.remove($0) })
        let payload = root.appendingPathComponent("job/answer.json"), other = root.appendingPathComponent("recovery.json"), id = UUID()
        try await writer.begin(id, operation: "rejected answer")
        try await writer.write(Data("rejected".utf8), to: payload, transaction: id)
        probe.failBeforePublication()
        do { try await writer.write(Data("fail".utf8), to: other, transaction: nil) } catch {}
        removal.arm(payload)
        do { try await writer.reject(id); XCTFail("Interrupted unlink succeeded") } catch {}
        XCTAssertFalse(RequestProcessIdentity.evidenceExists(payload))
        try await writer.resumeAfterExplicitRecovery()
        XCTAssertGreaterThanOrEqual(removal.count, 2, "Verified absence must still finish the interrupted parent fsync")
    }
}
private final class InterruptedRemovalProbe: @unchecked Sendable {
    private let lock = NSLock(); private var target: URL?, calls = 0
    var count: Int { lock.withLock { calls } }
    func arm(_ file: URL) { lock.withLock { target = file } }
    func remove(_ file: URL) throws {
        let interrupt = lock.withLock { () -> Bool in
            if file.lastPathComponent == "answer.json" { calls += 1 }
            guard target == file else { return false }; target = nil; return true
        }
        if interrupt { try FileManager.default.removeItem(at: file); throw POSIXError(.EIO) }
        try RequestJournalWriter.remove(file)
    }
}
#endif
