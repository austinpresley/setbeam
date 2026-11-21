// swift-tools-version: 6.0
import PackageDescription

// Local end-to-end fixture for the native receiver. It links the real SetbeamCore gateway,
// short-address listener, and media runtime from the root package. Build with its own scratch path:
//   swift build --package-path receiver/integration --scratch-path receiver/integration/.build/swift
let package = Package(
    name: "SetbeamReceiverIntegration",
    platforms: [.macOS(.v14)],
    dependencies: [.package(name: "Setbeam", path: "../..")],
    targets: [
        .executableTarget(name: "SetbeamReceiverFixture", dependencies: [.product(name: "SetbeamCore", package: "Setbeam")]),
        .executableTarget(name: "ScreenText")
    ],
    swiftLanguageModes: [.v5]
)
