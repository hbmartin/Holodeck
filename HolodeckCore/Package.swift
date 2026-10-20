// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "HolodeckCore",
    platforms: [.macOS(.v15), .tvOS(.v26)],
    products: [.library(name: "HolodeckCore", targets: ["HolodeckCore"]),
               .executable(name: "holodeck-shader-tool", targets: ["HolodeckShaderTool"])],
    dependencies: [
        .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.17.1"),
        .package(url: "https://github.com/pointfreeco/swift-clocks", from: "1.1.1"),
        .package(url: "https://github.com/pointfreeco/swift-issue-reporting", from: "2.1.1"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.0.0")
    ],
    targets: [
        .target(name: "HolodeckCore", dependencies: [
            .product(name: "Dependencies", package: "swift-dependencies"),
            .product(name: "Clocks", package: "swift-clocks"),
            .product(name: "IssueReporting", package: "swift-issue-reporting"),
            .product(name: "X509", package: "swift-certificates", condition: .when(platforms: [.macOS]))
        ], resources: [.copy("Resources/shader_requests.py"), .copy("Resources/shader_processes.py"), .copy("Resources/shader_checker.pyz"), .copy("Resources/shader_checker.lock.json")]),
        .executableTarget(name: "HolodeckShaderTool", dependencies: ["HolodeckCore"]),
        .testTarget(name: "HolodeckCoreTests", dependencies: ["HolodeckCore"],
                    resources: [.copy("TestSupport")])
    ]
)
