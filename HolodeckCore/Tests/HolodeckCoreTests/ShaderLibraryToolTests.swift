#if os(macOS)
import XCTest
import CryptoKit
@testable import HolodeckCore

final class ShaderLibraryToolTests: XCTestCase {
    private var nativeTool: URL {
        let executableDirectory = Bundle(for: ShaderLibraryToolTests.self).bundleURL.deletingLastPathComponent()
        let candidates = [executableDirectory.appendingPathComponent("holodeck-shader-tool"),
            executableDirectory.deletingLastPathComponent().appendingPathComponent("holodeck-shader-tool")]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) } ?? candidates[0]
    }

    func testNativeWrapperPreservesInterpreterSignalAndProcessIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let interpreter = directory.appendingPathComponent("python"), pid = directory.appendingPathComponent("pid")
        try "#!/usr/bin/python3\nimport os,signal\nfrom pathlib import Path\nPath(\"\(pid.path)\").write_text(str(os.getpid()))\nos.kill(os.getpid(),signal.SIGTERM)\n".write(to: interpreter, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: interpreter.path)
        let process = Process(); process.executableURL = nativeTool
        process.arguments = ["library", "info", "--python", interpreter.path]
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationReason, .uncaughtSignal); XCTAssertEqual(process.terminationStatus, SIGTERM)
        XCTAssertEqual(try String(contentsOf: pid, encoding: .utf8), String(process.processIdentifier))
    }

    func testActualIsolatedCheckerNeverImportsCheckoutPythonOrIgnoredBytecode() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for folder in ["shaders/example", "shared", "snippets", "references"] {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        let json: [String: [String: Any]] = [
            "index.json": ["defaultShaderID": "example", "shaders": ["example"]],
            "shaders/example/metadata.json": ["id": "example", "name": "Example", "category": "PROCEDURAL", "description": "Fixture", "colors": [[0,0,0],[1,1,1]], "shared": ["common", "fragment"]],
            "authoring.json": ["schemaVersion": 1, "sourceRequirements": ["shared/common.metal": [], "shared/fragment.metal": [], "shaders/example/body.metal": []], "upstreamRequirements": [:], "regressionProfiles": []]
        ]
        for (name, value) in json { try JSONSerialization.data(withJSONObject: value).write(to: directory.appendingPathComponent(name)) }
        for (name, source) in ["shared/common.metal": "// fixture\n", "shared/fragment.metal": "return float4(clamp(color, 0.0, 1.0), 1.0);\n", "shaders/example/body.metal": "float3 shade(float2 p,float t,float2 pixel){return float3(0.5);}\n"] {
            try Data(source.utf8).write(to: directory.appendingPathComponent(name))
        }
        let marker = directory.appendingPathComponent("executed")
        let canary = "from pathlib import Path\nPath(\"\(marker.path)\").touch()\n"
        try canary.write(to: directory.appendingPathComponent("sitecustomize.py"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("tools/__pycache__"), withIntermediateDirectories: true)
        try canary.write(to: directory.appendingPathComponent("tools/library.py"), atomically: true, encoding: .utf8)
        let compile = Process(); compile.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        compile.arguments = ["-I", "-c", "import py_compile,sys;py_compile.compile(sys.argv[1],doraise=True)", directory.appendingPathComponent("tools/library.py").path]
        try compile.run(); compile.waitUntilExit(); XCTAssertEqual(compile.terminationStatus, 0)
        let process = Process(); process.executableURL = nativeTool
        process.currentDirectoryURL = directory
        process.arguments = ["library", "validate", directory.path, "--json"]
        process.standardOutput = Pipe(); process.standardError = Pipe()
        var environment = ProcessInfo.processInfo.environment; environment["PYTHONPATH"] = directory.path
        process.environment = environment
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testActualNativeWrapperTimeoutTerminatesInterpreterAndDescendant() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let interpreter = directory.appendingPathComponent("python"), pid = directory.appendingPathComponent("pid")
        try """
        #!/usr/bin/python3
        import subprocess,sys,time
        from pathlib import Path
        child=subprocess.Popen([sys.executable,'-c','import time;time.sleep(60)'])
        Path("\(pid.path)").write_text(str(child.pid))
        time.sleep(60)
        """.write(to: interpreter, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: interpreter.path)
        let worker = try XCTUnwrap(RequestWorkerProcess.bundledScript), process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-I", "-c", """
        import importlib.util,os,subprocess,sys
        from pathlib import Path
        spec=importlib.util.spec_from_file_location('worker',sys.argv[1]);worker=importlib.util.module_from_spec(spec);spec.loader.exec_module(worker)
        env=dict(os.environ,HOLODECK_REQUEST_DIRECTORY=sys.argv[4])
        try:worker.run([sys.argv[2],'library','info','--python',sys.argv[3]],sys.argv[4],env,timeout=.5)
        except subprocess.TimeoutExpired:pass
        else:raise AssertionError('Native CLI did not time out')
        assert worker.process_identity(int(Path(sys.argv[5]).read_text())) is None,'Descendant survived timeout'
        assert not (Path(sys.argv[4])/'children.json').exists(),'Teardown did not release registry'
        """, worker.path, nativeTool.path, interpreter.path, directory.path, pid.path]
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
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
        var pin: [String: Any] = ["version": "1.1.0", "interfaceVersion": 1,
                                  "sourceCommit": String(repeating: "a", count: 40), "sha256": hash]
        try JSONSerialization.data(withJSONObject: pin).write(to: lock)
        XCTAssertEqual(try ShaderLibraryTool.checkedArtifact(artifact: artifact, lock: lock), artifact)
        try Data("modified".utf8).write(to: artifact)
        XCTAssertThrowsError(try ShaderLibraryTool.checkedArtifact(artifact: artifact, lock: lock))
        try data.write(to: artifact)
        pin["interfaceVersion"] = 1; pin["version"] = "1.99.2"
        try JSONSerialization.data(withJSONObject: pin).write(to: lock)
        XCTAssertEqual(try ShaderLibraryTool.checkedArtifact(artifact: artifact, lock: lock), artifact)
        pin["version"] = "2.0.0"
        try JSONSerialization.data(withJSONObject: pin).write(to: lock)
        XCTAssertThrowsError(try ShaderLibraryTool.checkedArtifact(artifact: artifact, lock: lock))
        pin["version"] = "1.99.2"; pin["interfaceVersion"] = 2
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
