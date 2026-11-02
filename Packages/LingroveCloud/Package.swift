// swift-tools-version: 6.1
import PackageDescription

// Foundation-only account/network ownership. Hosts inject durable stores and explicit endpoints.
let package = Package(
    name: "LingroveCloud",
    platforms: [.macOS(.v14), .iOS(.v18)],
    products: [.library(name: "LingroveCloud", targets: ["LingroveCloud"])],
    dependencies: [.package(path: "../LingroveNotebook")],
    targets: [
        .target(name: "LingroveCloud", dependencies: [
            .product(name: "LingroveNotebook", package: "LingroveNotebook"),
            .product(name: "LingroveNotebookSync", package: "LingroveNotebook")
        ]),
        .testTarget(name: "LingroveCloudTests", dependencies: ["LingroveCloud"], resources: [.copy("Fixtures")])
    ]
)
