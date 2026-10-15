#if os(macOS)
import Foundation
import CryptoKit

/// Preserve checker status codes across the native CLI process boundary.
public struct ShaderCheckerExit: Error {
    public let status: Int32
}

private final class ShaderCheckerResourceAnchor {}

public enum ShaderLibraryTool {
    // Avoid Bundle.module's fatalError when a manual CLI install omitted resources.
    private static var resources: Bundle? {
        let candidates = [Bundle.main.resourceURL, Bundle.main.bundleURL,
                          Bundle.main.executableURL?.deletingLastPathComponent(),
                          Bundle(for: ShaderCheckerResourceAnchor.self).resourceURL]
        return candidates.compactMap { $0?.appendingPathComponent("HolodeckCore_HolodeckCore.bundle") }
            .compactMap(Bundle.init(url:)).first
    }

    private struct Lock: Decodable {
        let version: String
        let interfaceVersion: Int
        let sourceCommit: String
        let sha256: String
    }

    /// Only bundled, checksum-pinned checker code is executed. Candidate files are data.
    static func checkedArtifact(artifact: URL?, lock: URL?) throws -> URL {
        guard let artifact, let lock else {
            throw ShaderToolError("Bundled shader checker is missing. Reinstall the CLI with its resource bundle.")
        }
        let pin = try JSONDecoder().decode(Lock.self, from: Data(contentsOf: lock))
        guard pin.interfaceVersion == 1, pin.version == "1.0.1",
              pin.sourceCommit.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil else {
            throw ShaderToolError("Bundled shader checker interface/version is incompatible.")
        }
        let digest = SHA256.hash(data: try Data(contentsOf: artifact)).map { String(format: "%02x", $0) }.joined()
        guard digest == pin.sha256 else { throw ShaderToolError("Bundled shader checker checksum does not match its lock.") }
        return artifact
    }

    public static func run(arguments: [String]) throws {
        do {
            let artifact = try checkedArtifact(
                artifact: resources?.url(forResource: "shader_checker", withExtension: "pyz"),
                lock: resources?.url(forResource: "shader_checker.lock", withExtension: "json"))
            var args = arguments
            var python = "/usr/bin/python3"
            if let index = args.firstIndex(of: "--python") {
                guard index + 1 < args.count else { throw ShaderToolError("--python requires an absolute executable path") }
                python = args[index + 1]
                args.removeSubrange(index...index + 1)
            }
            guard python.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: python) else {
                throw ShaderToolError("--python requires an absolute executable path")
            }
            guard !args.contains("--python"), !args.contains("--shader-tool") else {
                throw ShaderToolError("Duplicate --python or an overridden native GPU backend is unsupported")
            }
            if args.first == "render" || args.contains("--gpu") {
                guard let executable = Bundle.main.executableURL else { throw ShaderToolError("Cannot locate native GPU backend") }
                args += ["--shader-tool", executable.resolvingSymlinksInPath().path]
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: python)
            process.arguments = ["-I", artifact.path] + args
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.standardOutput
            process.standardError = FileHandle.standardError
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                // A signal must not become a successful exit or a candidate repair loop.
                throw ShaderCheckerExit(status: process.terminationReason == .exit ? process.terminationStatus : 2)
            }
        } catch let error as ShaderCheckerExit {
            throw error
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            throw ShaderCheckerExit(status: 2)
        }
    }
}
#endif
