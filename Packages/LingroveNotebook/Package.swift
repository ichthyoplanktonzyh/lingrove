// swift-tools-version: 6.1
import PackageDescription

// The notebook graph has no runtime or UI dependency. The separate UI product
// lets both Apple apps render them without giving persistence a SwiftUI import.
let package = Package(
    name: "LingroveNotebook",
    defaultLocalization: "en",
    platforms: [.macOS(.v14), .iOS(.v18)],
    products: [
        .library(name: "LingroveStudyExport", targets: ["LingroveStudyExport"]),
        .library(name: "LingroveTextRules", targets: ["LingroveTextRules"]),
        .library(name: "LingroveNotebook", targets: ["LingroveNotebook"]),
        .library(name: "LingroveNotebookUI", targets: ["LingroveNotebookUI"]),
        .library(name: "LingroveNotebookPersistenceCodec", targets: ["LingroveNotebookPersistenceCodec"]),
        .library(name: "LingroveNotebookSync", targets: ["LingroveNotebookSync"]),
        .library(name: "LingroveNotebookStorage", targets: ["LingroveNotebookStorage"])
    ],
    targets: [
        .target(name: "LingroveStudyExport", dependencies: ["LingroveNotebook"], resources: [.process("Resources")], linkerSettings: [.linkedLibrary("z")]),
        .target(name: "LingroveTextRules"),
        .target(name: "LingroveNotebook", dependencies: ["LingroveTextRules"]),
        .target(name: "LingroveNotebookUI", dependencies: ["LingroveNotebook"]),
        .target(name: "LingroveNotebookPersistenceCodec", dependencies: ["LingroveNotebook"]),
        .target(name: "LingroveNotebookSync", dependencies: ["LingroveNotebook"]),
        .target(
            name: "LingroveNotebookStorage",
            dependencies: ["LingroveNotebook", "LingroveNotebookPersistenceCodec"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(name: "LingroveStudyExportTests", dependencies: ["LingroveStudyExport", "LingroveNotebook"]),
        .testTarget(
            name: "LingroveNotebookTests",
            dependencies: ["LingroveNotebook", "LingroveTextRules"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "LingroveNotebookStorageTests",
            dependencies: ["LingroveNotebookStorage", "LingroveNotebookPersistenceCodec"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "LingroveNotebookSyncTests",
            dependencies: ["LingroveNotebook", "LingroveNotebookSync"]
        )
    ]
)
