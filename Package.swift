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
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .target(name: "SetbeamCore"),
        .executableTarget(
            name: "SetbeamApp",
            dependencies: ["SetbeamCore", .product(name: "Sparkle", package: "Sparkle")],
            resources: [.copy("Resources")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .executableTarget(name: "SetbeamProbe", dependencies: ["SetbeamCore"]),
        .executableTarget(name: "SetbeamSupervisor"),
        .testTarget(name: "SetbeamCoreTests", dependencies: ["SetbeamCore"]),
        .testTarget(name: "SetbeamProbeTests", dependencies: ["SetbeamProbe"]),
        .testTarget(name: "SetbeamAppTests", dependencies: ["SetbeamApp"])
    ],
    swiftLanguageModes: [.v5]
)
