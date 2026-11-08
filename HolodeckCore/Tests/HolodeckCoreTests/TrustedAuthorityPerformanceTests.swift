#if os(macOS)
import Foundation
import XCTest
@testable import HolodeckCore

private final class ProfileTrustedStore: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Data
    private var readCount = 0, writeCount = 0
    init(_ bytes: Data) { self.bytes = bytes }
    func read() -> Data { lock.withLock { readCount += 1; return bytes } }
    func write(_ bytes: Data) { lock.withLock { self.bytes = bytes; writeCount += 1 } }
    var counts: (reads: Int, writes: Int) { lock.withLock { (readCount, writeCount) } }
}
@MainActor final class TrustedAuthorityPerformanceTests: XCTestCase {
    func testTrustedReplayStructuralWork() async throws {
        let profiling = ProcessInfo.processInfo.environment["HOLODECK_TRUSTED_PROFILE"] == "1"
        let count = profiling ? 200 : 4
        let parent = ProcessInfo.processInfo.environment["HOLODECK_PROFILE_DIRECTORY"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
        let root = parent.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ShaderRequestService(catalog: DirectoryCatalog(directory: root.appendingPathComponent("catalog")), directory: root)
        await service.suspend(); try await service.initialize(configuration: .init(repository: root.path, enabled: true))
        let store = ProfileTrustedStore(try TrustedTVApprovals(approvals: (0..<count).map { ApprovedTV(id: "TV-\($0)", name: "TV", tokenHash: "token-\($0)") }).encoded())
        let authority = TrustedApprovalsCoordinator(read: { store.read() }, write: { store.write($0) })
        let start = ProcessInfo.processInfo.systemUptime
        let ticket = try await authority.register(.init(serverID: UUID(), service: service, changed: { _, _ in }, retired: {}, beforeReplay: { _ in }))
        guard case .accepted(let binding) = try await ticket.value() else { return XCTFail("Profile registration superseded") }
        try await authority.replay()
        for index in 0..<count { try await authority.revoke("TV-\(index)", permit: binding.permit) { _ in } }
        let elapsed = ProcessInfo.processInfo.systemUptime - start, work = await authority.observation
        let actual = store.counts
        let reservations = await service.trustedReservationCount
        XCTAssertEqual(reservations, 0); XCTAssertEqual(work.obligations, 0); XCTAssertEqual(work.departures, 0)
        XCTAssertEqual(work.targets, 1); XCTAssertEqual(work.inspections, 1)
        XCTAssertEqual(work.queuedRevocations, 0); XCTAssertEqual(work.recoverySubscriptions, 1)
        XCTAssertEqual(actual.writes, count * 2); XCTAssertEqual(work.writes, count * 2); XCTAssertEqual(work.encodings, count * 2)
        // The same opt-in workload is run against the merged predecessor without timing assertions.
        if !profiling { XCTAssertEqual(actual.reads, 1) }
        print("TRUSTED_PROFILE commands=\(count) reads=\(actual.reads) writes=\(actual.writes) encodings=\(work.encodings) elapsed=\(elapsed)")
    }
}
#endif
