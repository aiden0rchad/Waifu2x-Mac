// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Waifu2xMac",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "UpscaleCore", resources: [.copy("Models")]),
        .executableTarget(name: "Waifu2xMac", dependencies: ["UpscaleCore"]),
        .testTarget(name: "UpscaleCoreTests", dependencies: ["UpscaleCore"])
    ],
    swiftLanguageModes: [.v5]
)
