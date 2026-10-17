import Foundation
import Metal
import XCTest
@testable import HolodeckCore

final class ShaderCompilerTests: XCTestCase {
    func testActualPipelineInterfaceMismatchIsASourceDefect() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        struct VertexOut { float4 position [[position]]; float2 color [[user(color)]]; };
        struct FragmentIn { float4 position [[position]]; float3 color [[user(color)]]; };
        vertex VertexOut vertexShader(uint id [[vertex_id]]) { VertexOut o; o.position=float4(0,0,0,1); o.color=float2(float(id),0); return o; }
        fragment float4 fragmentShader(FragmentIn in [[stage_in]]) { return float4(in.color,1); }
        """
        let library = try device.makeLibrary(source:source,options:nil)
        XCTAssertThrowsError(try makeShaderPipeline(device:device,library:library,pixelFormat:.bgra8Unorm_srgb)) { error in
            guard case ShaderCompilationError.pipelineInterface(let underlying) = error else { return XCTFail("Pipeline mismatch lost source classification: \(error)") }
            XCTAssertTrue(ShaderCompilationError.isSourceDefect(error))
            XCTAssertTrue(underlying.localizedDescription.lowercased().contains("fragment input"))
        }
    }
    func testActualFragmentOutputMismatchIsASourceDefect() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        vertex float4 vertexShader(uint id [[vertex_id]]) { return float4(0,0,0,1); }
        fragment uint4 fragmentShader() { return uint4(1); }
        """
        let library = try device.makeLibrary(source:source,options:nil)
        XCTAssertThrowsError(try makeShaderPipeline(device:device,library:library,pixelFormat:.bgra8Unorm_srgb)) {
            XCTAssertTrue(ShaderCompilationError.isSourceDefect($0));XCTAssertTrue($0.localizedDescription.contains("color attachment"))
        }
    }
    func testPipelineClassifierPreservesDiagnosticsAndDoesNotClassifyVendorCodesAlone() {
        for diagnostic in ["Fragment input(s) `user(color)` mismatching vertex shader output type(s) or not written by vertex shader",
                           "Link failed: fragment input vPos was not found in vertex shader outputs"] {
            let original = NSError(domain:"AGXMetalTest",code:3,userInfo:[NSLocalizedDescriptionKey:diagnostic])
            let classified = ShaderCompilationError.pipelineError(original)
            guard case ShaderCompilationError.pipelineInterface(let underlying) = classified else { return XCTFail("Known interface defect was not wrapped") }
            XCTAssertEqual(underlying,original); XCTAssertEqual(classified.localizedDescription,diagnostic)
        }
        for diagnostic in ["Out of memory", "Internal compiler error", "Unsupported resource", "Unknown renderer failure"] {
            let original = NSError(domain:"AGXMetalTest",code:3,userInfo:[NSLocalizedDescriptionKey:diagnostic])
            let classified = ShaderCompilationError.pipelineError(original)
            XCTAssertFalse(ShaderCompilationError.isSourceDefect(classified)); XCTAssertEqual(classified as NSError,original)
        }
    }
}
