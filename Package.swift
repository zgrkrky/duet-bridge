// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DuetBridge",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "duet-bridge", targets: ["DuetBridge"])
    ],
    targets: [
        .executableTarget(
            name: "DuetBridge",
            path: "Sources/DuetBridge"
        )
    ],
    swiftLanguageModes: [.v5]
)
