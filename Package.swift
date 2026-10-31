// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "regulus",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RegulusCore", targets: ["RegulusCore"]),
    ],
    targets: [
        .target(name: "RegulusCore"),
        .testTarget(name: "RegulusCoreTests", dependencies: ["RegulusCore"], path: "Tests", resources: [.copy("Fixtures")]),
    ]
)
