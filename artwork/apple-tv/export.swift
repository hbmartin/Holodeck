#!/usr/bin/env swift
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Run from the repository root: swift artwork/apple-tv/export.swift
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let artwork = root.appendingPathComponent("artwork/apple-tv")
let catalog = root.appendingPathComponent("Holodeck/Assets.xcassets/App Icon & Top Shelf Image.brandassets")
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

func load(_ url: URL) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw NSError(domain: "Artwork", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot read \(url.path)"])
    }
    return image
}

func context(width: Int, height: Int, transparent: Bool) -> CGContext {
    let alpha = transparent ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast
    let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | alpha.rawValue
    let result = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                           bytesPerRow: width * 4, space: colorSpace, bitmapInfo: bitmapInfo)!
    result.interpolationQuality = .high
    return result
}

func render(_ image: CGImage, width: Int, height: Int, transparent: Bool) -> CGImage {
    let result = context(width: width, height: height, transparent: transparent)
    // Centered aspect fill: maintain perspective and never stretch the artwork.
    let scale = max(CGFloat(width) / CGFloat(image.width), CGFloat(height) / CGFloat(image.height))
    let w = CGFloat(image.width) * scale
    let h = CGFloat(image.height) * scale
    result.draw(image, in: CGRect(x: (CGFloat(width) - w) / 2, y: (CGFloat(height) - h) / 2,
                                 width: w, height: h))
    return result.makeImage()!
}

func save(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "Artwork", code: 2)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "Artwork", code: 3) }
}

func updateImages(at folder: URL, images: [[String: String]]) throws {
    let url = folder.appendingPathComponent("Contents.json")
    var contents = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    contents["images"] = images
    var data = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    data.append(0x0A)
    try data.write(to: url)
}

let layerNames = ["Back", "Middle", "Front"]
var layers: [CGImage] = []
for name in layerNames {
    let url = artwork.appendingPathComponent("\(name.lowercased()).png")
    let original = try load(url)
    let normalized = render(original, width: 1600, height: 960, transparent: name != "Back")
    try save(normalized, to: url)
    layers.append(normalized)
}
precondition(Set(layers.map { "\($0.width)x\($0.height)" }).count == 1, "Layer canvases must align")

for (index, name) in layerNames.enumerated() {
    let small = catalog.appendingPathComponent("App Icon.imagestack/\(name).imagestacklayer/Content.imageset")
    var smallImages: [[String: String]] = []
    for (scale, width, height) in [("1x", 400, 240), ("2x", 800, 480)] {
        let filename = "\(name.lowercased())-\(scale).png"
        try save(render(layers[index], width: width, height: height, transparent: name != "Back"),
                 to: small.appendingPathComponent(filename))
        smallImages.append(["filename": filename, "idiom": "tv", "scale": scale])
    }
    try updateImages(at: small, images: smallImages)
    let large = catalog.appendingPathComponent("App Icon - App Store.imagestack/\(name).imagestacklayer/Content.imageset")
    let filename = "\(name.lowercased())-1280x768.png"
    try save(render(layers[index], width: 1280, height: 768, transparent: name != "Back"),
             to: large.appendingPathComponent(filename))
    try updateImages(at: large, images: [["filename": filename, "idiom": "tv"]])
}

let wideSourceURL = artwork.appendingPathComponent("top-shelf-wide.png")
let wideOriginal = try load(wideSourceURL)
try save(render(wideOriginal, width: wideOriginal.width, height: wideOriginal.height, transparent: false), to: wideSourceURL)
let wide2x = render(wideOriginal, width: 4640, height: 1440, transparent: false)
for (folderName, basename, width) in [("Top Shelf Image Wide.imageset", "top-shelf-wide", 2320),
                                     ("Top Shelf Image.imageset", "top-shelf", 1920)] {
    let folder = catalog.appendingPathComponent(folderName)
    let two = folderName.contains("Wide") ? wide2x : wide2x.cropping(to: CGRect(x: 400, y: 0, width: 3840, height: 1440))!
    let one = render(two, width: width, height: 720, transparent: false)
    try save(one, to: folder.appendingPathComponent("\(basename)-1x.png"))
    try save(two, to: folder.appendingPathComponent("\(basename)-2x.png"))
    try updateImages(at: folder, images: [
        ["filename": "\(basename)-1x.png", "idiom": "tv", "scale": "1x"],
        ["filename": "\(basename)-2x.png", "idiom": "tv", "scale": "2x"]
    ])
}

for (width, height) in [(400, 240), (1280, 768)] {
    let preview = context(width: width, height: height, transparent: false)
    for layer in layers {
        let sized = render(layer, width: width, height: height, transparent: true)
        preview.draw(sized, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    try save(preview.makeImage()!, to: artwork.appendingPathComponent("icon-preview-\(width)x\(height).png"))
}

// Check the actual rendered PNGs, including their embedded sRGB profiles and alpha.
var assetCount = 0
for (folderName, width, height) in [("App Icon.imagestack", 400, 240),
                                    ("App Icon - App Store.imagestack", 1280, 768)] {
    for name in layerNames {
        let folder = catalog.appendingPathComponent("\(folderName)/\(name).imagestacklayer/Content.imageset")
        let contents = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("Contents.json"))) as! [String: Any]
        for entry in contents["images"] as! [[String: String]] {
            let scale = entry["scale"] == "2x" ? 2 : 1
            let image = try load(folder.appendingPathComponent(entry["filename"]!))
            precondition(image.width == width * scale && image.height == height * scale)
            precondition(image.colorSpace?.name == CGColorSpace.sRGB)
            if name == "Back" { precondition(image.alphaInfo == .none || image.alphaInfo == .noneSkipLast) }
            else {
                let check = context(width: image.width, height: image.height, transparent: true)
                check.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                let bytes = check.data!.assumingMemoryBound(to: UInt8.self)
                var clear = 0
                var visible = 0
                for pixel in 0..<(image.width * image.height) {
                    let alpha = bytes[pixel * 4 + 3]
                    if alpha == 0 { clear += 1 }
                    if alpha > 127 { visible += 1 }
                }
                precondition(clear > image.width * image.height / 2 && visible > 0, "Upper layer must contain isolated artwork on alpha")
            }
            assetCount += 1
        }
    }
}
for (folderName, width) in [("Top Shelf Image Wide.imageset", 2320), ("Top Shelf Image.imageset", 1920)] {
    let folder = catalog.appendingPathComponent(folderName)
    let contents = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("Contents.json"))) as! [String: Any]
    for entry in contents["images"] as! [[String: String]] {
        let scale = entry["scale"] == "2x" ? 2 : 1
        let image = try load(folder.appendingPathComponent(entry["filename"]!))
        precondition(image.width == width * scale && image.height == 720 * scale)
        precondition(image.colorSpace?.name == CGColorSpace.sRGB)
        precondition(image.alphaInfo == .none || image.alphaInfo == .noneSkipLast)
        assetCount += 1
    }
}
precondition(assetCount == 13)
print("Exported and validated \(assetCount) sRGB PNG assets; layer transparency, dimensions, and catalog filenames passed.")
