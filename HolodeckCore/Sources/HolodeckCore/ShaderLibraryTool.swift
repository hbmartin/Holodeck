#if os(macOS)
import Foundation
import Darwin

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

    private struct Lock: Codable {
        let repository: String
        let version: String
        let interfaceVersion: Int
        let sourceCommit: String
        let sha256: String
    }

    /// Only bundled, checksum-pinned checker code is executed. Candidate files are data.
    static func checkedArtifact(artifact: URL?, lock: URL?) throws -> URL {
        _ = try checkedIdentity(artifact: artifact, lock: lock)
        return artifact!
    }
    private static func checkedIdentity(artifact: URL?, lock: URL?) throws -> Lock {
        guard let artifact, let lock else {
            throw ShaderToolError("Bundled shader checker is missing. Reinstall the CLI with its resource bundle.")
        }
        let pin = try JSONDecoder().decode(Lock.self, from: Data(contentsOf: lock))
        guard pin.repository == "hbmartin/HolodeckShaderCheck", pin.interfaceVersion == 1,
              pin.version.range(of: "^1\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$", options: .regularExpression) != nil,
              CatalogHash.isSHA(pin.sourceCommit, length: 40), CatalogHash.isSHA(pin.sha256) else {
            throw ShaderToolError("Bundled shader checker interface/version is incompatible.")
        }
        let digest = CatalogHash.sha256(try Data(contentsOf: artifact))
        guard digest == pin.sha256 else { throw ShaderToolError("Bundled shader checker checksum does not match its lock.") }
        return pin
    }

    public static func run(arguments: [String]) throws {
        do {
            let bundle = resources
            let artifact = bundle?.url(forResource: "shader_checker", withExtension: "pyz")
            let pin = try checkedIdentity(artifact: artifact, lock: bundle?.url(forResource: "shader_checker.lock", withExtension: "json"))
            guard let artifact else { throw ShaderToolError("Bundled shader checker is missing") }
            if arguments.first == "artifact-info" {
                guard arguments == ["artifact-info", "--json"] else { throw ShaderToolError("Usage: library artifact-info --json") }
                var data = try JSONEncoder().encode(pin); data.append(10)
                FileHandle.standardOutput.write(data)
                return
            }
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
            if args.first == "render" || args.contains("--gpu") || args.contains("--gpu-only") {
                guard let executable = Bundle.main.executableURL else { throw ShaderToolError("Cannot locate native GPU backend") }
                args += ["--shader-tool", executable.resolvingSymlinksInPath().path]
            }
            let nullInput = open("/dev/null", O_RDONLY)
            guard nullInput >= 0 else { throw POSIXError(.EIO) }
            defer { close(nullInput) }
            guard dup2(nullInput, STDIN_FILENO) >= 0 else { throw POSIXError(.EIO) }
            let argv = ([python, "-I", artifact.path] + args).map { strdup($0) } + [nil]
            defer { argv.forEach { free($0) } }
            argv.withUnsafeBufferPointer { _ = execv(python, $0.baseAddress!) }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            throw ShaderCheckerExit(status: 2)
        }
    }
}
#endif
