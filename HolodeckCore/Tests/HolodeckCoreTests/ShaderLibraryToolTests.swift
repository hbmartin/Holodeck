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
        var pin: [String: Any] = ["version": "1.0.3", "interfaceVersion": 1,
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

    func testReleasedCheckerReportsLockedVersionAndInterface() throws {
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/HolodeckCore/Resources")
        let lock = resources.appendingPathComponent("shader_checker.lock.json")
        let artifact = try ShaderLibraryTool.checkedArtifact(
            artifact: resources.appendingPathComponent("shader_checker.pyz"), lock: lock)
        let pin = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: lock)) as? [String: Any])
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-I", artifact.path, "info", "--json"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let info = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(info["checkerVersion"] as? String, pin["version"] as? String)
        XCTAssertEqual(info["interfaceVersion"] as? Int, pin["interfaceVersion"] as? Int)
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
