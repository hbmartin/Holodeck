#if os(macOS)
import Foundation
import XCTest
@testable import HolodeckCore

@MainActor final class TrustedRetirementIsolationTests: XCTestCase {
    func testInjectedConflictDoesNotPreventHealthyRetirementAndRetainsExactEvidence() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/pr55-retirement-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        func service() -> ShaderRequestService {
            ShaderRequestService(catalog: DirectoryCatalog(directory: root.appendingPathComponent("catalog")), directory: root,
                workerScript: root.appendingPathComponent("unused.py"), reconcileWorker: { _ in })
        }
        let seed = service(); await seed.suspend()
        try await seed.initialize(configuration: .init(repository: root.path, enabled: true))
        let file = Bundle.module.url(forResource: "CatalogFixture", withExtension: "json", subdirectory: "TestSupport")!
        let shader = try JSONDecoder().decode(CatalogSnapshot.self, from: Data(contentsOf: file)).validated().initialShader
        let context = ShaderRequestContext(shader: shader, screenshot: try RequestScreenshot.encode(pixels: Data([128,64,32,255]), width: 1, height: 1, bytesPerRow: 4), animationTime: 1, width: 1, height: 1)
        var ids: [UUID] = []
        for device in ["A", "B"] {
            let request = ShaderRequest(prompt: "Retirement isolation", context: context); ids.append(request.id)
            _ = try await seed.control(operation: "requestSubmit", payload: .init(request: request), deviceID: device)
        }
        ids.sort { $0.uuidString < $1.uuidString }
        let journal = root.appendingPathComponent("journal.json"), marker = root.appendingPathComponent("active.json")
        var rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as? [[String: Any]])
        let conflicting = UUID(), newer = UUID(), healthy = UUID()
        for index in rows.indices {
            let status = try XCTUnwrap(rows[index]["status"] as? [String: Any])
            let id = try XCTUnwrap(status["id"] as? String)
            let first = id.uppercased() == ids[0].uuidString
            rows[index]["executionID"] = (first ? newer : healthy).uuidString
            rows[index]["dispatch"] = ["executionID": (first ? conflicting : healthy).uuidString, "priorStage": "queued", "launched": false, "retirementPending": true]
        }
        // Deliberately construct mismatched persisted identities. This asserts the
        // isolation invariant, not a demonstrated producer in ordinary execution.
        try JSONSerialization.data(withJSONObject: rows).write(to: journal)
        try JSONEncoder().encode(ids[1]).write(to: marker)
        let recovering = service(); await recovering.suspend()
        addTeardownBlock { await recovering.suspend() }
        try await recovering.initialize(configuration: .init(repository: root.path, enabled: true))
        func saved(_ id: UUID) throws -> [String: Any] {
            let all = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as? [[String: Any]])
            return try XCTUnwrap(all.first { (($0["status"] as? [String: Any])?["id"] as? String)?.uppercased() == id.uuidString })
        }
        XCTAssertNil(try saved(ids[1])["dispatch"])
        XCTAssertFalse(RequestProcessIdentity.evidenceExists(marker))
        let retained = try saved(ids[0]), dispatch = try XCTUnwrap(retained["dispatch"] as? [String: Any])
        XCTAssertEqual(retained["executionID"] as? String, newer.uuidString)
        XCTAssertEqual(dispatch["executionID"] as? String, conflicting.uuidString)
        let statuses = await recovering.recoveryStatuses()
        XCTAssertEqual(statuses.filter { $0.message.contains("conflicts with a newer execution") }.count, 1)
        XCTAssertFalse(statuses.contains { $0.message.contains("Request startup finalization failed") })
        do { try await recovering.retryReconciliation(); XCTFail("Unresolved identity conflict was discarded") }
        catch { XCTAssertTrue(error.localizedDescription.contains("conflicts with a newer execution")) }
        XCTAssertNil(try saved(ids[1])["dispatch"])
        let after = try XCTUnwrap(try saved(ids[0])["dispatch"] as? [String: Any])
        XCTAssertEqual(after["executionID"] as? String, conflicting.uuidString)
    }
}
#endif
