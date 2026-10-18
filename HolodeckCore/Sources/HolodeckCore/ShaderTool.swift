#if os(macOS)
import Foundation
import Metal

public enum ShaderTool {
    public static let version = "1.1.0"

    public static func run(arguments: [String]) throws {
        if arguments == ["--version"] { print("holodeck-shader-tool \(version)"); return }
        guard let command = arguments.first else { throw usage() }
        let args = Array(arguments.dropFirst())
        if command == "library" { try ShaderLibraryTool.run(arguments: args); return }
        if command == "probe" { try RegressionProbe.run(arguments: args); return }
        guard command == "render", args.count >= 2, (args.count - 2) % 2 == 0 else { throw usage() }
        var width = 1280, height = 720
        var time: Float = 3
        for index in stride(from: 2, to: args.count, by: 2) {
            switch args[index] {
            case "--width":
                guard let value = Int(args[index + 1]) else { throw ShaderToolError("Invalid width") }
                width = value
            case "--height":
                guard let value = Int(args[index + 1]) else { throw ShaderToolError("Invalid height") }
                height = value
            case "--time":
                guard let value = Float(args[index + 1]) else { throw ShaderToolError("Invalid time") }
                time = value
            default: throw ShaderToolError("Unknown option: \(args[index])")
            }
        }
        try validateRenderDimensions(width: width, height: height)
        try validateRenderTime(time)
        let context = try MetalContext(sourcePath: args[0])
        let renderer = try OffscreenRenderer(context: context, width: width, height: height, pixelFormat: .bgra8Unorm_srgb)
        let frame = try renderer.render(time: time)
        try ShaderPNG.encode(pixels: frame.pixels, bytesPerRow: frame.bytesPerRow, width: width, height: height)
            .write(to: URL(fileURLWithPath: args[1]), options: .atomic)
    }

    private static func usage() -> ShaderToolError {
        ShaderToolError("Usage: holodeck-shader-tool --version | library info|artifact-info|validate|assemble|render ... [--python ABSOLUTE_PATH] | render SOURCE OUTPUT [--width N --height N --time SECONDS] | probe render|compute SOURCE SAMPLES_JSON RESULT_JSON")
    }
}
#endif
