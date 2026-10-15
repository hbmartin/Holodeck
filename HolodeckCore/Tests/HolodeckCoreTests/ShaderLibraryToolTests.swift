#if os(macOS)
import XCTest
import CryptoKit
@testable import HolodeckCore

final class ShaderLibraryToolTests: XCTestCase {
    func testMissingAndModifiedArtifactsFailBeforePythonExecution() throws {
        XCTAssertThrowsError(try ShaderLibraryTool.checkedArtifact(artifact: nil, lock: nil))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let artifact = directory.appendingPathComponent("checker.pyz")
        let lock = directory.appendingPathComponent("checker.lock.json")
        let data = Data("checker fixture".utf8)
        try data.write(to: artifact)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        var pin: [String: Any] = ["version": "1.0.1", "interfaceVersion": 1,
                                  "sourceCommit": String(repeating: "a", count: 40), "sha256": hash]
        try JSONSerialization.data(withJSONObject: pin).write(to: lock)
        XCTAssertEqual(try ShaderLibraryTool.checkedArtifact(artifact: artifact, lock: lock), artifact)
        try Data("modified".utf8).write(to: artifact)
        XCTAssertThrowsError(try ShaderLibraryTool.checkedArtifact(artifact: artifact, lock: lock))
        try data.write(to: artifact)
        pin["interfaceVersion"] = 2
        try JSONSerialization.data(withJSONObject: pin).write(to: lock)
        XCTAssertThrowsError(try ShaderLibraryTool.checkedArtifact(artifact: artifact, lock: lock))
    }

    func testLibraryRejectsInvalidInterpreterAndBackendOverrides() {
        for arguments in [["info", "--python", "relative"], ["info", "--python"],
                          ["info", "--shader-tool", "/untrusted/backend"]] {
            XCTAssertThrowsError(try ShaderLibraryTool.run(arguments: arguments)) {
                XCTAssertEqual(($0 as? ShaderCheckerExit)?.status, 2)
            }
        }
    }
}
#endif
