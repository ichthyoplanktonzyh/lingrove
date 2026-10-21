// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MDictReader",
    platforms: [.macOS(.v14)],
    products: [.library(name: "MDictReader", targets: ["MDictReader"])],
    targets: [.target(name: "MDictReader"), .testTarget(name: "MDictReaderTests", dependencies: ["MDictReader"])],
    swiftLanguageModes: [.v5]
)
