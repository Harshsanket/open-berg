// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "open-berg",
    platforms: [
        // Target OS floor: macOS 27.
        .macOS("27.0")
    ],
    products: [
        .executable(name: "OpenBerg", targets: ["OpenBerg"])
    ],
    targets: [
        // No third-party dependencies: only Foundation, SwiftUI, AppKit and the
        // Security framework that ship with the OS.
        .executableTarget(
            name: "OpenBerg",
            path: "Sources/OpenBerg"
        )
    ]
)
