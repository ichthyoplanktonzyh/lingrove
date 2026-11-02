// swift-tools-version: 6.1
import PackageDescription

// Integration belongs here: storage does not import networking and transports do not import SQL.
let package = Package(
    name: "LingroveNotebookCloud",
    platforms: [.macOS(.v14), .iOS(.v18)],
    products: [.library(name: "LingroveNotebookCloud", targets: ["LingroveNotebookCloud"])],
    dependencies: [.package(path: "../LingroveNotebookEngine"), .package(path: "../LingroveCloud"),
                   .package(path: "../LingroveNotebook")],
    targets: [
        .target(name: "LingroveNotebookCloud", dependencies: ["LingroveNotebookEngine", "LingroveCloud",
            .product(name: "LingroveNotebook", package: "LingroveNotebook"),
            .product(name: "LingroveNotebookSync", package: "LingroveNotebook")]),
        .testTarget(name: "LingroveNotebookCloudTests", dependencies: ["LingroveNotebookCloud"])
    ],
    swiftLanguageModes: [.v5]
)
