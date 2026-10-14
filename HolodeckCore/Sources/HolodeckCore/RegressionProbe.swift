#if os(macOS)
import Foundation
import CoreFoundation
import Metal

enum RegressionProbe {

    static func sampleNumber(_ value: Any, at location: String) throws -> Float {
        guard let number = value as? NSNumber else {
            throw ShaderToolError("Invalid \(location): expected a number, got \(value)")
        }
        guard CFGetTypeID(number) != CFBooleanGetTypeID() else {
            throw ShaderToolError("Invalid \(location): expected a number, got \(number.boolValue)")
        }
        // Foundation preserves numeric underflow to signed zero, including values
        // smaller than Double. Check the converted Float to reject GPU overflow.
        let sample = number.floatValue
        guard sample.isFinite else {
            throw ShaderToolError("Invalid \(location): \(number) is not finite as Float")
        }
        return sample
    }

    static func renderSamples(_ input: Any) throws -> [Float] {
        guard let values = input as? [Any] else { throw ShaderToolError("Invalid render samples: expected an array") }
        return try values.enumerated().map { index, value in
            let time = try sampleNumber(value, at: "render samples[\(index)]")
            guard time >= 0 else {
                throw ShaderToolError("Invalid render samples[\(index)]: \(value) must be nonnegative")
            }
            return time
        }
    }

    static func computeSamples(_ input: Any) throws -> [SIMD2<Float>] {
        guard let rows = input as? [Any], !rows.isEmpty else {
            throw ShaderToolError("Invalid compute samples: expected a nonempty array of two-number rows")
        }
        return try rows.enumerated().map { index, value in
            guard let row = value as? [Any], row.count == 2 else {
                throw ShaderToolError("Invalid compute samples[\(index)]: expected two numbers, got \(value)")
            }
            return try SIMD2<Float>(sampleNumber(row[0], at: "compute samples[\(index)][0]"),
                                    sampleNumber(row[1], at: "compute samples[\(index)][1]"))
        }
    }

    static func run(arguments args: [String]) throws {
        guard args.count == 4, ["compute", "render"].contains(args[0]) else {
            throw ShaderToolError("Usage: holodeck-shader-tool probe compute|render source.metal samples.json result.json")
        }
        let inputData = try Data(contentsOf: URL(fileURLWithPath: args[2]))
        let input: Any
        do { input = try JSONSerialization.jsonObject(with: inputData) }
        catch { throw ShaderToolError("Invalid \(args[0]) samples: \(error)") }
        var times: [Float] = []
        var samples: [SIMD2<Float>] = []
        if args[0] == "render" {
            times = try renderSamples(input)
        } else {
            samples = try computeSamples(input)
        }
        let context = try MetalContext(sourcePath: args[1])
        var result: [String: Any] = ["device": context.device.name]
        if args[0] == "compute" {
            guard let function = context.library.makeFunction(name: "regressionProbe") else {
                throw ShaderToolError("Missing compute function")
            }
            let pipeline = try context.device.makeComputePipelineState(function: function)
            let inputBuffer = samples.withUnsafeMutableBytes {
                context.device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
            }
            guard let inputBuffer,
                  let outputBuffer = context.device.makeBuffer(length: samples.count * MemoryLayout<UInt32>.stride, options: .storageModeShared),
                  let command = context.queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else {
                throw ShaderToolError("Unable to allocate compute buffers or encoder")
            }
            encoder.setComputePipelineState(pipeline)
            encoder.setBuffer(inputBuffer, offset: 0, index: 0)
            encoder.setBuffer(outputBuffer, offset: 0, index: 1)
            encoder.dispatchThreads(MTLSize(width: samples.count, height: 1, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: pipeline.threadExecutionWidth, height: 1, depth: 1))
            encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
            guard command.status == .completed else { throw ShaderToolError(command.error?.localizedDescription ?? "Compute failed") }
            let pointer = outputBuffer.contents().bindMemory(to: UInt32.self, capacity: samples.count)
            result["seeds"] = Array(UnsafeBufferPointer(start: pointer, count: samples.count))
        } else {
            let renderer = try OffscreenRenderer(context: context, width: 160, height: 90, pixelFormat: .rgba32Float)
            var frames: [[String: Any]] = []
            for (index, time) in times.enumerated() {
                let frame = try renderer.render(time: time)
                let file = URL(fileURLWithPath: args[3]).deletingPathExtension().appendingPathExtension("\(index).rgba32")
                try frame.pixels.write(to: file)
                let nonfinite = frame.pixels.withUnsafeBytes { bytes in
                    stride(from: 0, to: bytes.count, by: MemoryLayout<Float>.stride).reduce(0) {
                        $0 + (bytes.loadUnaligned(fromByteOffset: $1, as: Float.self).isFinite ? 0 : 1)
                    }
                }
                frames.append(["time": time, "path": file.path,
                               "nonfinite": nonfinite, "gpuMilliseconds": frame.gpuMilliseconds])
            }
            result["frames"] = frames
        }
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: args[3]))
    }
}
#endif
