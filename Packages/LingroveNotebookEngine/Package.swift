// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "LingroveNotebookEngine",
    platforms: [.macOS(.v14), .iOS(.v18)],
    products: [.library(name: "LingroveNotebookEngine", targets: ["LingroveNotebookEngine"])],
    dependencies: [.package(path: "../LingroveNotebook")],
    targets: [
        .target(name: "LingroveNotebookEngine", dependencies: [
            .product(name: "LingroveNotebook", package: "LingroveNotebook"),
            .product(name: "LingroveNotebookPersistenceCodec", package: "LingroveNotebook"),
            .product(name: "LingroveNotebookSync", package: "LingroveNotebook"),
            .product(name: "LingroveNotebookStorage", package: "LingroveNotebook"),
            .product(name: "LingroveStudyExport", package: "LingroveNotebook")
        ], linkerSettings: [.linkedLibrary("sqlite3")]),
        .testTarget(name: "LingroveNotebookEngineTests", dependencies: ["LingroveNotebookEngine"], resources: [.copy("Fixtures")])
    ],
    swiftLanguageModes: [.v5]
)
