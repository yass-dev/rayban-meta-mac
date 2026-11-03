// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "visor-mac",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "visor-mac", targets: ["visor-mac"]),
        .executable(name: "visor-web", targets: ["visor-web"]),
        .library(name: "VisorKit", targets: ["VisorKit"]),
    ],
    targets: [
        .target(
            name: "VisorKit",
            linkerSettings: [
                .linkedFramework("IOBluetooth"),
                .linkedFramework("CoreBluetooth"),
            ]
        ),
        .executableTarget(name: "visor-mac", dependencies: ["VisorKit"]),
        .executableTarget(
            name: "visor-web",
            dependencies: ["VisorKit"],
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("AVFoundation")]
        ),
        .testTarget(name: "VisorKitTests", dependencies: ["VisorKit"]),
    ]
)
