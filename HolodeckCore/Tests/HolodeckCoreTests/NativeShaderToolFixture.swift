#if os(macOS)
import Foundation
@testable import HolodeckCore

private final class NativeShaderToolFixtureAnchor {}
enum NativeShaderToolFixture {
    static var executable: URL {
        let directory = Bundle(for: NativeShaderToolFixtureAnchor.self).bundleURL.deletingLastPathComponent()
        let candidates = [directory.appendingPathComponent("holodeck-shader-tool"),
                          directory.deletingLastPathComponent().appendingPathComponent("holodeck-shader-tool")]
        return candidates.first { FileManager.default.isExecutableFile(atPath:$0.path) } ?? candidates[0]
    }
    static var lock: URL? {
        RequestWorkerProcess.bundledScript?.deletingLastPathComponent().appendingPathComponent("shader_checker.lock.json")
    }
}
#endif
