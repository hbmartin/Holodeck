#if os(macOS)
import Foundation
import XCTest
@testable import HolodeckCore

final class ShaderToolTests: XCTestCase {
    func testDimensionsAndTimeValidateBeforeGPUSetup() throws {
        for (width, height) in [(1, 1), (8192, 1), (1, 8192), (4096, 4096), (8192, 2048)] {
            try validateRenderDimensions(width: width, height: height)
        }
        for (width, height) in [(0, 1), (-1, 1), (8193, 1), (Int.max, 1), (Int.min, 1),
                                (1, 0), (1, -1), (1, 8193), (1, Int.max), (1, Int.min), (4097, 4096)] {
            XCTAssertThrowsError(try validateRenderDimensions(width: width, height: height))
        }
        for time: Float in [-1, .nan, .infinity, -.infinity] { XCTAssertThrowsError(try validateRenderTime(time)) }
        try validateRenderTime(0); try validateRenderTime(3.25); try ShaderUniforms.validateLayout()
        let options = [("--width", "0", "Invalid width"), ("--width", "8193", "Invalid width"),
                       ("--width", "text", "Invalid width"), ("--height", "0", "Invalid height")]
            + ["-1", "nan", "inf", "-inf", "true", "1e39"].map { ("--time", $0, "Invalid time") }
        for (option, value, diagnostic) in options {
            XCTAssertThrowsError(try ShaderTool.run(arguments: ["render", "/missing.metal", "/missing.png", option, value])) {
                XCTAssertEqual($0.localizedDescription, diagnostic)
            }
        }
    }
    func testProbeRejectsMalformedSamplesAndPreservesSignedUnderflow() throws {
        for payload in ["{}", "null", "[-1]", "[true]", "[false]", "[\"3\"]", "[null]", "[[0]]", "[1e39]"] {
            XCTAssertThrowsError(try RegressionProbe.renderSamples(JSONSerialization.jsonObject(with: Data(payload.utf8), options: [.fragmentsAllowed])), payload)
        }
        for payload in ["{}", "null", "[]", "[null]", "[[0]]", "[[0,1,2]]", "[[true,1]]", "[[0,\"1\"]]", "[[1e39,0]]"] {
            XCTAssertThrowsError(try RegressionProbe.computeSamples(JSONSerialization.jsonObject(with: Data(payload.utf8), options: [.fragmentsAllowed])), payload)
        }
        let input = try JSONSerialization.jsonObject(with: Data("[-0.0,-1e-100,1e-100,3.25]".utf8))
        let times = try RegressionProbe.renderSamples(input)
        XCTAssertEqual(times.map(\.bitPattern), [0x80000000, 0x80000000, 0, Float(3.25).bitPattern])
        XCTAssertEqual(try RegressionProbe.renderSamples([]), [])
    }
}
#endif
