import Foundation
import Testing
@testable import Lingrove

struct LocalModelTaskPolicyTests {
    @Test(arguments: LocalModelCatalog.entries)
    func catalogEntriesStayInTheirTask(_ entry: LocalModelDescriptor) {
        for task in LocalModelTask.allCases {
            #expect(LocalModelTaskPolicy.isCandidate(entry.filename, task: task, assignedTasks: Set(LocalModelTask.allCases))
                == (entry.task == task && !entry.isResource))
        }
        #expect(LocalModelCatalog.descriptor(for: entry.filename.uppercased()) == entry)
    }

    @Test func unknownFilesNeedAnExplicitTaskAndKnownFamiliesCannotCrossTasks() {
        #expect(!LocalModelTaskPolicy.isCandidate("custom.gguf", task: .translation, assignedTasks: []))
        #expect(LocalModelTaskPolicy.isCandidate("custom.gguf", task: .translation, assignedTasks: [.translation]))
        #expect(!LocalModelTaskPolicy.isCandidate("custom.gguf", task: .explanation, assignedTasks: [.translation]))
        #expect(!LocalModelTaskPolicy.supports("Qwen-Base-Q8.gguf", task: .translation))
        #expect(!LocalModelTaskPolicy.supports("TranslateGemma-custom.gguf", task: .explanation))
        #expect(!LocalModelTaskPolicy.supports("mmproj-custom.gguf", task: .speech))
        for template in LearningChatTemplate.available(for: .translation) {
            #expect(LocalModelTaskPolicy.permitsTemplate(template, task: .translation))
        }
        #expect(!LocalModelTaskPolicy.permitsTemplate(.hyMT, task: .explanation))
    }

    @Test @MainActor func aliasesMatchBeforeAndAfterInstallationWithoutChangingTransferIDs() {
        let models = RuntimeModelCatalog.downloadableModels + LearningRuntimeCatalog.translationModels
            + LearningRuntimeCatalog.explanationModels + [SpeechModelCatalog.model, SpeechModelCatalog.decoder]
        for model in models {
            let option = RuntimeModelOption(filename: model.filename, url: URL(fileURLWithPath: "/models/" + model.filename))
            #expect(option.displayName == model.displayName)
            #expect(model.id == model.downloadURL.absoluteString && option.id == model.filename)
            #expect(LocalModelCatalog.downloadMetadata(for: model.filename)?.sha256 == model.sha256)
        }
        #expect(LocalModelCatalog.displayName(for: "custom.gguf") == "custom.gguf")
    }
}

@MainActor
struct LocalModelTaskAssignmentTests {
    @Test func legacyCompletionPowerChoicesRegisterBeforeDiscovery() throws {
        let name = "lingrove.test.legacyPowerTasks.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let previous = SuggestionSettingsModel(configuration: .standard, userDefaults: defaults)
        previous.setBatteryProfile(.llama(filename: "custom-battery.gguf"))
        previous.setPluggedInProfile(.llama(filename: "custom-ac.gguf"))
        let reopened = SuggestionSettingsModel(configuration: .standard, userDefaults: defaults)
        let assignments = LocalModelTaskAssignments(defaults: defaults)
        for filename in [reopened.batteryModelFilename, reopened.pluggedInModelFilename] {
            #expect(LocalModelTaskPolicy.isCandidate(filename, task: .completion, assignedTasks: assignments.tasks(for: filename)))
        }
        #expect(reopened.batteryProfile == .llama(filename: "custom-battery.gguf"))
        #expect(reopened.pluggedInProfile == .llama(filename: "custom-ac.gguf"))
    }

    @Test func installedCustomFilesCanBeAssignedWithoutAnotherTransfer() throws {
        let name = "lingrove.test.existingModelAssignment.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("custom.gguf")
        let bytes = Data("unchanged model fixture".utf8)
        try bytes.write(to: file)
        let assignments = LocalModelTaskAssignments(defaults: defaults)
        let manager = ModelDownloadManager(runtimeDirectoryURL: folder, taskAssignments: assignments)
        #expect(manager.unassignedModels(for: .translation).contains { $0.filename == "custom.gguf" })
        manager.assignModel("custom.gguf", for: .translation)
        #expect(!manager.needsAssignment("custom.gguf", for: .translation))
        #expect(manager.needsAssignment("custom.gguf", for: .explanation))
        #expect(try Data(contentsOf: file) == bytes)
        let custom = DownloadableRuntimeModel(filename: "custom.gguf", displayName: "Custom",
            downloadURL: try #require(URL(string: "https://example.com/original.gguf")), approximateSizeInGigabytes: 1)
        assignments.recordSource(custom)
        #expect(manager.sourceURL(for: "custom.gguf") == custom.downloadURL)
        manager.deleteModel(filename: "custom.gguf")
        #expect(manager.sourceURL(for: "custom.gguf") == nil)
        assignments.recordSource(LearningRuntimeCatalog.translationModels[0])
        #expect(assignments.source(for: LearningRuntimeCatalog.translationModels[0].filename)
            == LearningRuntimeCatalog.translationModels[0].downloadURL)
    }

    @Test func explicitAssignmentsPersistAndDoNotLeakToOtherTasks() throws {
        let name = "lingrove.test.modelTaskAssignments.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let assignments = LocalModelTaskAssignments(defaults: defaults)
        #expect(assignments.record("CUSTOM.gguf", for: .translation))
        #expect(LocalModelTaskAssignments(defaults: defaults).tasks(for: "custom.gguf") == [.translation])
        #expect(!assignments.record("gemma-4-E2B.i1-Q6_K.gguf", for: .translation))
        #expect(assignments.tasks(for: "gemma-4-E2B.i1-Q6_K.gguf").isEmpty)
        #expect(assignments.record(SpeechModelCatalog.decoder.filename, for: .speech))
        #expect(!LocalModelTaskPolicy.isCandidate(SpeechModelCatalog.decoder.filename, task: .speech, assignedTasks: [.speech]))
    }
}
