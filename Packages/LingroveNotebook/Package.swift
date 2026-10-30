// swift-tools-version: 6.1
import PackageDescription

// The notebook graph has no runtime or UI dependency. The separate UI product
// lets both Apple apps render them without giving persistence a SwiftUI import.
let package = Package(
    name: "LingroveNotebook",
    platforms: [.macOS(.v14), .iOS(.v18)],
    products: [
        .library(name: "LingroveNotebook", targets: ["LingroveNotebook"]),
        .library(name: "LingroveNotebookUI", targets: ["LingroveNotebookUI"])
    ],
    targets: [
        .target(name: "LingroveNotebook"),
        .target(name: "LingroveNotebookUI", dependencies: ["LingroveNotebook"]),
        .testTarget(
            name: "LingroveNotebookTests",
            dependencies: ["LingroveNotebook"],
            resources: [.copy("Fixtures")]
        )
    ]
)
