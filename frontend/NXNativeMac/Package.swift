// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NXNativeMac",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "NXNativeMac", targets: ["NXNativeMac"]),
    ],
    targets: [
        // Todo lo que entiende los formatos de nxnative, sin UI: se prueba solo.
        .target(name: "NXCore"),
        .executableTarget(name: "NXNativeMac", dependencies: ["NXCore"]),
        .testTarget(name: "NXCoreTests", dependencies: ["NXCore"], resources: [.copy("Fixtures")]),
    ]
)
