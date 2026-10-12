// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EmberApp",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Ember", targets: ["Ember"]),
        .library(name: "EmberAppCore", targets: ["EmberAppCore"]),
    ],
    dependencies: [
        .package(path: "../EmberKit"),
    ],
    targets: [
        .target(
            name: "EmberAppCore",
            dependencies: [.product(name: "EmberKit", package: "EmberKit")]
        ),
        .executableTarget(
            name: "Ember",
            dependencies: ["EmberAppCore"]
        ),
        .testTarget(
            name: "EmberAppCoreTests",
            dependencies: ["EmberAppCore"]
        ),
    ]
)
