// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NXNativeMac",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "NXNativeMac", targets: ["NXNativeMac"]),
        .library(name: "NXCore", targets: ["NXCore"]),
        .library(name: "NXRuntime", targets: ["NXRuntime"]),
    ],
    targets: [
        // Todo lo que entiende los formatos de nxnative, sin UI: se prueba solo.
        .target(name: "NXCore"),
        // Integración con macOS, procesos, toolchain y ciclo de vida de juegos.
        // No contiene SwiftUI: la interfaz solo consume esta API.
        .target(name: "NXRuntime", dependencies: ["NXCore"]),
        .executableTarget(name: "NXNativeMac", dependencies: ["NXCore", "NXRuntime"]),
        .testTarget(name: "NXCoreTests", dependencies: ["NXCore"], resources: [.copy("Fixtures")]),
        .testTarget(name: "NXRuntimeTests", dependencies: ["NXRuntime", "NXCore"]),
    ]
)
