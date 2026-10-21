// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LingroveGraphLayout",
    platforms: [.macOS(.v14)],
    products: [.library(name: "LingroveGraphLayout", targets: ["LingroveGraphLayout"])],
    targets: [
        .target(name: "ForceSimulation"),
        .target(name: "LingroveGraphLayout", dependencies: ["ForceSimulation"])
    ]
)
