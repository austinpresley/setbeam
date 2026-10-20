// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Setbeam",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SetbeamCore", targets: ["SetbeamCore"]),
        .executable(name: "Setbeam", targets: ["SetbeamApp"]),
        .executable(name: "SetbeamProbe", targets: ["SetbeamProbe"]),
        .executable(name: "SetbeamSupervisor", targets: ["SetbeamSupervisor"])
    ],
    targets: [
        .target(name: "SetbeamCore"),
        .executableTarget(name: "SetbeamApp", dependencies: ["SetbeamCore"], resources: [.copy("Resources")]),
        .executableTarget(name: "SetbeamProbe", dependencies: ["SetbeamCore"]),
        .executableTarget(name: "SetbeamSupervisor"),
        .testTarget(name: "SetbeamCoreTests", dependencies: ["SetbeamCore"])
    ],
    swiftLanguageModes: [.v5]
)
