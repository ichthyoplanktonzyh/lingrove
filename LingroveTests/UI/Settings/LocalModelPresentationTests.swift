import AppKit
import SwiftUI
import Testing
@testable import Lingrove

/// Offscreen snapshots verify the metadata disclosure at real AppKit sizes without activating
/// another app or changing the user's model preferences. Artifacts stay in the repo's build folder.
@MainActor
@Suite(.serialized)
struct LocalModelPresentationTests {
    @Test(arguments: [false, true])
    func modelDetailsFitAndRemainOptional(expanded: Bool) async throws {
        let model = LearningRuntimeCatalog.translationModels[0]
        let content = VStack(alignment: .leading, spacing: 10) {
            Text(model.displayName).font(.headline)
            Text(model.recommendation ?? "").font(.caption)
            LocalModelDetailsView(filename: model.filename, source: model.downloadURL, initiallyExpanded: expanded)
            Divider()
            Text(LocalModelSelectionLabel.unavailable("gemma-4-E2B.i1-Q6_K.gguf", task: .translation))
                .font(.caption)
        }.padding(20).frame(width: 620, alignment: .leading)
        try await paint(content, name: expanded ? "details-expanded" : "details-collapsed", height: expanded ? 300 : 180)
    }

    @Test(arguments: LocalModelTask.allCases)
    func taskCatalogUsesSharedProductRows(task: LocalModelTask) async throws {
        let suite = "LocalModelPresentationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder) }
        let catalog: [DownloadableRuntimeModel]
        switch task {
        case .completion: catalog = RuntimeModelCatalog.downloadableModels
        case .translation: catalog = LearningRuntimeCatalog.translationModels
        case .explanation: catalog = LearningRuntimeCatalog.explanationModels
        case .speech: catalog = [SpeechModelCatalog.model, SpeechModelCatalog.decoder]
        }
        let manager = ModelDownloadManager(runtimeDirectoryURL: folder, assetCatalog: catalog,
            taskAssignments: .init(defaults: defaults))
        let content = DownloadableModelCatalogView(modelDownloadManager: manager, onRefreshModels: {},
            catalog: catalog, task: task).padding(20).frame(width: 620)
        try await paint(content, name: "catalog-\(task.rawValue)", height: 620)
    }

    private func paint<Content: View>(_ content: Content, name: String, height: CGFloat) async throws {
        let host = NSHostingView(rootView: content.environment(\.colorScheme, .light).background(Color.white))
        let rect = NSRect(x: -3000, y: -3000, width: 620, height: height)
        let window = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        defer { window.close() }
        for _ in 0..<8 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(15))
        }
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { root.deleteLastPathComponent() }
        let folder = root.appendingPathComponent("build/model-task-ux/renders")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appendingPathComponent("\(name).png"))
        #expect(host.fittingSize.width <= 620)
    }

    @Test func retainedSelectionsDistinguishMissingFilesFromWrongTasks() {
        #expect(LocalModelSelectionLabel.unavailable("missing-custom.gguf", task: .translation)
            == String(localized: "\("missing-custom.gguf") (file unavailable)", table: "Learning"))
        let name = LocalModelCatalog.displayName(for: "gemma-4-E2B.i1-Q6_K.gguf")
        #expect(LocalModelSelectionLabel.unavailable("gemma-4-E2B.i1-Q6_K.gguf", task: .translation)
            == String(localized: "\(name) · not compatible with this task", table: "Learning"))
    }
}
