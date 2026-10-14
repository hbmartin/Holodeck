#if os(macOS)
import Foundation
import XCTest
@testable import HolodeckCore

final class ShaderToolGPURegressionTests: XCTestCase {
    private var directory: URL!
    private let pixelCount = 160 * 90

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["HOLODECK_GPU_TESTS"] == "1" else {
            throw XCTSkip("Set HOLODECK_GPU_TESTS=1 to run actual Metal probe regressions.")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        directory = root
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        // With opt-in enabled, ShaderTool.run must report unavailable Metal as a failure.
    }

    private func probe(_ label: String, mode: String, source: String, samples: String) throws -> [String: Any] {
        let sourceURL = directory.appendingPathComponent(label + ".metal")
        let samplesURL = directory.appendingPathComponent(label + ".json")
        let resultURL = directory.appendingPathComponent(label + ".result.json")
        try Data(source.utf8).write(to: sourceURL)
        try Data(samples.utf8).write(to: samplesURL)
        try ShaderTool.run(arguments: ["probe", mode, sourceURL.path, samplesURL.path, resultURL.path])
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: resultURL)) as? [String: Any])
    }

    private func fragment(_ expression: String, clamped: Bool = false) -> String {
        """
        #include <metal_stdlib>
        using namespace metal;
        struct ShaderUniforms { float2 resolution; float time; float padding; };
        struct RasterData { float4 position [[position]]; };
        vertex RasterData vertexShader(uint id [[vertex_id]]) {
            const float2 positions[3] = {float2(-1, -1), float2(3, -1), float2(-1, 3)};
            RasterData out;
            out.position = float4(positions[id], 0, 1);
            return out;
        }
        fragment float4 fragmentShader(RasterData in [[stage_in]],
                                       constant ShaderUniforms &u [[buffer(0)]]) {
            float3 color = \(expression);
            return float4(\(clamped ? "clamp(color, 0.0, 1.0)" : "color"), 1.0);
        }
        """
    }

    private func pixels(_ frame: [String: Any]) throws -> Data {
        let path = try XCTUnwrap(frame["path"] as? String)
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    private func expectedPixels(_ rgba: [Float]) -> Data {
        let pixel = rgba.withUnsafeBytes { Data($0) }
        var result = Data(capacity: pixel.count * pixelCount)
        for _ in 0..<pixelCount { result.append(pixel) }
        return result
    }

    func testRenderProbePreservesNumericUniformBits() throws {
        // Encode words as normal floats before the render target can flush subnormals.
        let source = fragment("float3(float(as_type<uint>(u.time) & 0xffffu), float(as_type<uint>(u.time) >> 16), 0.0)")
        let result = try probe("numeric-inputs", mode: "render", source: source,
            samples: "[0,-0.0,3.25,1e-50,1e-400,-1e-50,-1e-400,3.4028235e38,1e-45]")
        let expected: [UInt32] = [0, 0x80000000, 0x40500000, 0, 0, 0x80000000, 0x80000000, 0x7f7fffff, 1]
        let frames = try XCTUnwrap(result["frames"] as? [[String: Any]])
        XCTAssertEqual(frames.count, expected.count)
        for (frame, bits) in zip(frames, expected) {
            // JSON can encode negative zero as integer zero; pixel bytes check its sign.
            XCTAssertEqual(try XCTUnwrap(frame["time"] as? NSNumber).floatValue, Float(bitPattern: bits))
            XCTAssertEqual(try XCTUnwrap(frame["nonfinite"] as? NSNumber).intValue, 0)
            XCTAssertEqual(try pixels(frame), expectedPixels([Float(bits & 0xffff), Float(bits >> 16), 0, 1]))
        }
    }

    func testComputeProbePreservesEachNumericSampleComponent() throws {
        let samples = "[[1e-50,-2],[1e-400,1],[-1e-50,-1e-400],[-1e-50,0],[0,-1e-400],"
            + "[3.4028235e38,-3.4028235e38],[1e-45,0],[-1e-45,1e-45],[-0.0,0],[0,-0.0]]"
        let rows: [(UInt32, UInt32)] = [(0, 0xc0000000), (0, 0x3f800000),
            (0x80000000, 0x80000000), (0x80000000, 0), (0, 0x80000000),
            (0x7f7fffff, 0xff7fffff), (1, 0), (0x80000001, 1), (0x80000000, 0), (0, 0x80000000)]
        for component in ["x", "y"] {
            let source = """
            #include <metal_stdlib>
            using namespace metal;
            kernel void regressionProbe(device const float2 *samples [[buffer(0)]],
                                        device uint *seeds [[buffer(1)]],
                                        uint i [[thread_position_in_grid]]) {
                seeds[i] = as_type<uint>(samples[i].\(component));
            }
            """
            let result = try probe("numeric-compute-" + component, mode: "compute", source: source, samples: samples)
            let seeds = try XCTUnwrap(result["seeds"] as? [NSNumber]).map(\.uint32Value)
            XCTAssertEqual(seeds, rows.map { component == "x" ? $0.0 : $0.1 }, component)
        }
    }

    func testUniformsDeliverResolutionAndTime() throws {
        let result = try probe("uniforms", mode: "render", source: fragment("float3(u.resolution, u.time)"), samples: "[0,3.25]")
        let frames = try XCTUnwrap(result["frames"] as? [[String: Any]])
        XCTAssertEqual(frames.count, 2)
        for (frame, time) in zip(frames, [Float(0), Float(3.25)]) {
            XCTAssertEqual(try pixels(frame), expectedPixels([160, 90, time, 1]))
        }
    }

    func testNonfiniteDiagnosticBeforeAndAfterFragmentClamp() throws {
        let expression = "float3(as_type<float>(0x7fc00000u))"
        for clamped in [false, true] {
            let result = try probe(clamped ? "nan-clamped" : "nan-raw", mode: "render",
                source: fragment(expression, clamped: clamped), samples: "[0]")
            let frames = try XCTUnwrap(result["frames"] as? [[String: Any]])
            XCTAssertEqual(frames.count, 1)
            let frame = try XCTUnwrap(frames.first)
            XCTAssertEqual(try XCTUnwrap(frame["nonfinite"] as? NSNumber).intValue, clamped ? 0 : pixelCount * 3)
        }
    }
}
#endif
