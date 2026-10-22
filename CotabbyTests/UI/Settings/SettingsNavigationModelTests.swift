import XCTest
@testable import Cotabby

/// Pins the Settings window's navigation state machine: search reveals land on the item's own pane
/// with a transient highlight, plain pane navigation cancels that highlight so a stale pulse cannot
/// replay, and Cmd-F routes to Home and leaves a one-shot focus request. The timed auto-clear of the
/// highlight is deliberately not waited on here; only the synchronous transitions are asserted.
@MainActor
final class SettingsNavigationModelTests: XCTestCase {
    func test_learningQuickLinksChooseTheirOwnTabAndClearSearch() {
        let model = makeModel()
        for task in SettingsLearningTask.allCases {
            model.reveal(.speechModel)
            model.openLearningTask(task)
            XCTAssertEqual(model.selection, .languageLearning)
            XCTAssertEqual(model.learningTask, task)
            XCTAssertNil(model.highlightedItem)
            XCTAssertNil(model.modelManagerTask)
        }
    }

    func test_guideDestinationsDismissAndRevealTheirExactPaneAndTab() {
        let model = makeModel()
        let destinations: [(SettingsItem, SettingsLearningTask)] = [
            (.sentencePreview, .translation), (.explanationLanguage, .explanation),
            (.readAloudSpeed, .readAloud), (.dictionarySources, .dictionary), (.ankiReview, .review)
        ]
        for (item, task) in destinations {
            model.showsUsageGuide = true
            model.openUsageGuideDestination(item)
            XCTAssertFalse(model.showsUsageGuide)
            XCTAssertEqual(model.selection, .languageLearning)
            XCTAssertEqual(model.learningTask, task)
            XCTAssertEqual(model.revealedItem, item)
        }
        for item in [SettingsItem.pointerTranslationShortcut, .replacementTranslationShortcut, .translationDetailsShortcut,
                     .saveVocabularyShortcut, .openVocabularyShortcut] {
            model.showsUsageGuide = true
            model.openUsageGuideDestination(item)
            XCTAssertFalse(model.showsUsageGuide)
            XCTAssertEqual(model.selection, .shortcuts)
            XCTAssertEqual(model.revealedItem, item)
        }
    }

    func test_menuDestinationsOverrideTheLastVisitedTaskAndClearSearch() {
        let model = makeModel()
        model.reveal(.explanationLanguage)
        model.openMenuDestination(.model(.speech))
        XCTAssertEqual(model.selection, .engineAndModel)
        XCTAssertEqual(model.engineTask, .speech)
        XCTAssertNil(model.highlightedItem)
        model.openMenuDestination(.learning(.dictionary))
        XCTAssertEqual(model.selection, .languageLearning)
        XCTAssertEqual(model.learningTask, .dictionary)
        model.openMenuDestination(.model(.translation))
        XCTAssertEqual(model.engineTask, .translation)
        model.openMenuDestination(.category(.permissions))
        XCTAssertEqual(model.selection, .permissions)
    }

    func testAnkiSearchOpensReviewAndCardTemplates() {
        let model = makeModel()
        model.reveal(.ankiReview)
        XCTAssertEqual(model.selection, .languageLearning)
        XCTAssertEqual(model.learningTask, .review)
        model.reveal(.ankiReviewFields)
        XCTAssertEqual(model.learningTask, .review)
        XCTAssertTrue(SettingsItem.results(for: "template").contains(.ankiReviewFields))
        XCTAssertTrue(SettingsItem.results(for: "字段映射").contains(.ankiReviewFields))
        XCTAssertEqual(SettingsItem.ankiReviewFields.title, String(localized: "Card templates", table: "Vocabulary"))
    }
    func testExplanationSearchSeparatesModelParametersFromLearningLanguage() {
        let model = makeModel()
        model.reveal(.explanationModel)
        XCTAssertEqual(model.selection, .engineAndModel)
        XCTAssertEqual(model.engineTask, .explanation)
        model.reveal(.explanationParameters)
        XCTAssertTrue(model.advancedBinding(for: .explanation).wrappedValue)
        model.reveal(.explanationLanguage)
        XCTAssertEqual(model.selection, .languageLearning)
        XCTAssertEqual(model.learningTask, .explanation)
        XCTAssertTrue(SettingsItem.results(for: "AI解释").contains(.explanationModel))
    }
    func testDictionarySearchOpensItsOwnLearningTab() {
        let model = SettingsNavigationModel()
        model.reveal(.dictionarySources)
        XCTAssertEqual(model.selection, .languageLearning)
        XCTAssertEqual(model.learningTask, .dictionary)
        XCTAssertTrue(SettingsItem.results(for: "词典").contains(.dictionarySources))
    }
    /// Models live as long as the test case instance rather than dying at the end of each test body:
    /// freeing a `@MainActor` model inside the body crashes the CI test host (macOS 15 runtime) with
    /// "pointer being freed was not allocated", the same reason other suites hold their subjects in
    /// stored properties.
    private var models: [SettingsNavigationModel] = []

    func test_parameterSearchOpensTheMatchingTaskAndAdvancedSection() {
        let model = makeModel()
        model.reveal(.translationStyle)
        XCTAssertEqual(model.selection, .languageLearning)
        XCTAssertEqual(model.learningTask, .translation)
        model.reveal(.translationSampling)
        XCTAssertEqual(model.engineTask, .translation)
        XCTAssertTrue(model.advancedBinding(for: .translation).wrappedValue)
        model.reveal(.speechSampling)
        XCTAssertEqual(model.engineTask, .speech)
        XCTAssertTrue(model.advancedBinding(for: .speech).wrappedValue)
    }

    private func makeModel() -> SettingsNavigationModel {
        let model = SettingsNavigationModel()
        models.append(model)
        return model
    }

    func test_startsOnHomeWithNothingPending() {
        let model = makeModel()

        XCTAssertEqual(model.selection, .home)
        XCTAssertNil(model.highlightedItem)
        XCTAssertFalse(model.pendingSearchFocus)
        XCTAssertEqual(model.engineTask, .completion)
        XCTAssertEqual(model.learningTask, .translation)
    }

    func test_appShortcutLinksRetargetTheSameVisiblePane() {
        let model = makeModel()
        model.openShortcuts(for: "com.apple.mail")
        XCTAssertEqual(model.selection, .shortcuts)
        XCTAssertEqual(model.shortcutAppBundleIdentifier, "com.apple.mail")
        model.openShortcuts(for: "md.obsidian")
        XCTAssertEqual(model.selection, .shortcuts)
        XCTAssertEqual(model.shortcutAppBundleIdentifier, "md.obsidian")
    }

    func test_samePaneRevealStillHighlightsAndManualSelectionClearsIt() {
        let model = makeModel()
        model.open(.appearance)
        model.reveal(.ghostTextSize)
        XCTAssertEqual(model.selection, .appearance)
        XCTAssertEqual(model.highlightedItem, .ghostTextSize)
        model.open(.appearance)
        XCTAssertNil(model.highlightedItem)
    }

    func test_writingLinksOpenEachRoleAndCancelAnOldSearchHighlight() {
        let model = makeModel()
        for role in [LearningModelRole.translation, .explanation] {
            model.reveal(.batteryModel)
            model.openLearningModel(role)
            XCTAssertEqual(model.selection, .engineAndModel)
            XCTAssertEqual(model.engineTask, SettingsEngineTask(role: role))
            XCTAssertNil(model.highlightedItem)
        }
    }

    func test_searchForCompletionReturnsFromALearningTabToItsOwnAnchors() {
        let model = makeModel()
        model.openLearningModel(.explanation)
        model.reveal(.selectedModel)
        XCTAssertEqual(model.selection, .engineAndModel)
        XCTAssertEqual(model.engineTask, .completion)
        XCTAssertEqual(model.highlightedItem, .selectedModel)
    }

    func test_searchRoutesSpeechControlsToTTSAndKeepsExistingEngineSearchOnCompletion() {
        let model = makeModel()
        model.openLearningModel(.explanation)

        for item in [SettingsItem.speechVoice, .speechModel, .speechDecoder, .speechEndpoint, .speechEndpointModel, .speechEndpointVoice] {
            model.reveal(item)
            XCTAssertEqual(model.selection, .engineAndModel)
            XCTAssertEqual(model.engineTask, .speech)
            XCTAssertEqual(model.highlightedItem, item)
        }

        model.reveal(.selectedModel)
        XCTAssertEqual(model.engineTask, .completion,
            "Existing autocomplete engine anchors must continue to reveal in Completion")

        model.reveal(.readAloudSpeed)
        XCTAssertEqual(model.selection, .languageLearning)
        XCTAssertEqual(model.learningTask, .readAloud)
        XCTAssertEqual(model.highlightedItem, .readAloudSpeed)
    }

    func test_homeEngineLinkReturnsToCompletionAfterInspectingExplanation() {
        let model = makeModel()
        model.openLearningModel(.explanation)
        model.open(.home)
        model.openEngineTask(.completion)
        XCTAssertEqual(model.selection, .engineAndModel)
        XCTAssertEqual(model.engineTask, .completion)
    }

    func test_sidebarNavigationRetainsTaskSelectionWithinTheSettingsWindow() {
        let model = makeModel()
        model.openLearningModel(.translation)
        model.open(.writing)
        model.open(.engineAndModel)
        XCTAssertEqual(model.engineTask, .translation)
    }

    func test_revealSelectsTheItemsPaneAndHighlightsIt() {
        let model = makeModel()

        model.reveal(.batteryModel)

        XCTAssertEqual(model.selection, .engineAndModel)
        XCTAssertEqual(model.highlightedItem, .batteryModel)
    }

    func test_secondRevealReplacesTheHighlightAndPane() {
        let model = makeModel()
        model.reveal(.batteryModel)

        model.reveal(.ghostTextSize)

        XCTAssertEqual(model.selection, .appearance)
        XCTAssertEqual(model.highlightedItem, .ghostTextSize)
    }

    func test_openingAPaneCancelsAnActiveHighlight() {
        let model = makeModel()
        model.reveal(.batteryModel)

        model.open(.about)

        XCTAssertEqual(model.selection, .about)
        XCTAssertNil(model.highlightedItem, "A manual pane switch must drop the search pulse immediately")
    }

    func test_searchFocusRequestFromAnotherPaneGoesHomeAndClearsHighlight() {
        let model = makeModel()
        model.reveal(.batteryModel)

        model.requestSearchFocus()

        XCTAssertEqual(model.selection, .home)
        XCTAssertNil(model.highlightedItem)
        XCTAssertTrue(model.pendingSearchFocus)
    }

    func test_searchFocusRequestIsOneShot() {
        let model = makeModel()

        model.requestSearchFocus()
        XCTAssertEqual(model.selection, .home)
        XCTAssertTrue(model.pendingSearchFocus)

        model.consumeSearchFocusRequest()
        XCTAssertFalse(model.pendingSearchFocus, "Home clears the request so a later visit does not steal focus")
    }

    func test_modelSearchKeepsRoleAndLanguageBehaviorDestinationsDistinct() {
        let model = makeModel()
        for (item, task) in [(SettingsItem.translationModel, SettingsEngineTask.translation), (.explanationModel, .explanation)] {
            model.reveal(item)
            XCTAssertEqual(model.selection, .engineAndModel)
            XCTAssertEqual(model.engineTask, task)
            XCTAssertNil(model.modelManagerTask)
        }
        for item in [SettingsItem.translationEnabled, .sentencePreview, .translationTargetLanguage,
                     .translationSourceLanguages, .translationReferenceMode] {
            model.reveal(item)
            XCTAssertEqual(model.selection, .languageLearning)
            XCTAssertEqual(model.learningTask, .translation)
            XCTAssertEqual(model.highlightedItem, item)
        }
    }

    func test_resourceSearchOpensCompletionManagerWithoutChangingTheEngine() {
        let model = makeModel()
        model.openEngineTask(.speech)
        for item in [SettingsItem.downloadModels, .huggingFaceBrowser, .modelsFolder, .lmStudio] {
            model.reveal(item)
            XCTAssertEqual(model.selection, .engineAndModel)
            XCTAssertEqual(model.engineTask, .completion)
            XCTAssertEqual(model.modelManagerTask, .completion)
            XCTAssertEqual(model.highlightedItem, item)
        }
        model.openEngineTask(.translation)
        XCTAssertNil(model.modelManagerTask)
        XCTAssertNil(model.revealedItem)
        XCTAssertNil(model.highlightedItem)
    }

    func test_learningTabsKeepTheirSelectionAcrossModelLinksAndSidebarNavigation() {
        let model = makeModel()
        model.openLearningTask(.explanation)
        XCTAssertEqual(model.selection, .languageLearning)
        model.openLearningModel(.explanation)
        XCTAssertEqual(model.selection, .engineAndModel)
        XCTAssertEqual(model.engineTask, .explanation)
        model.open(.languageLearning)
        XCTAssertEqual(model.learningTask, .explanation)
        model.openLearningTask(.readAloud)
        model.openEngineTask(.speech)
        model.open(.languageLearning)
        XCTAssertEqual(model.learningTask, .readAloud)
    }

    func test_searchChoosesTheLearningTabAndManualTabChangesClearItsPulse() {
        let model = makeModel()
        for item in [SettingsItem.translationEnabled, .sentencePreview, .translationTargetLanguage,
                     .translationSourceLanguages, .translationReferenceMode] {
            model.openLearningTask(.readAloud)
            model.reveal(item)
            XCTAssertEqual(model.learningTask, .translation)
            XCTAssertEqual(model.highlightedItem, item)
        }
        model.reveal(.explanationLanguage)
        XCTAssertEqual(model.learningTask, .explanation)
        model.reveal(.readAloudSpeed)
        XCTAssertEqual(model.learningTask, .readAloud)
        model.openLearningTask(.translation)
        XCTAssertEqual(model.selection, .languageLearning)
        XCTAssertNil(model.highlightedItem)
        XCTAssertNil(model.revealedItem)
    }

    func test_advancedSearchExpandsBeforeRevealAndExpansionIsPerTask() {
        let model = makeModel()
        model.reveal(.batteryModel)
        XCTAssertTrue(model.advancedBinding(for: .completion).wrappedValue)
        XCTAssertFalse(model.advancedBinding(for: .translation).wrappedValue)
        model.advancedBinding(for: .translation).wrappedValue = true
        model.advancedBinding(for: .completion).wrappedValue = false
        model.openEngineTask(.translation)
        XCTAssertTrue(model.advancedBinding(for: .translation).wrappedValue)
        XCTAssertFalse(model.advancedBinding(for: .completion).wrappedValue)
        model.reveal(.endpointAPIMode)
        XCTAssertEqual(model.engineTask, .completion)
        XCTAssertTrue(model.advancedBinding(for: .completion).wrappedValue)
    }

    func test_dormantEngineInspectionIsWindowStateAndResetsOnNavigation() {
        let model = makeModel()
        model.reveal(.endpointBaseURL)
        model.inspectedCompletionEngine = .openAICompatible
        let arrival = model.revealSequence
        model.refreshReveal()
        XCTAssertGreaterThan(model.revealSequence, arrival)
        XCTAssertEqual(model.revealedItem, .endpointBaseURL)
        XCTAssertEqual(model.highlightedItem, .endpointBaseURL)
        XCTAssertEqual(model.inspectedCompletionEngine, .openAICompatible)
        model.openEngineTask(.translation)
        XCTAssertNil(model.inspectedCompletionEngine)
        model.reveal(.speechDecoder)
        XCTAssertEqual(model.engineTask, .speech)
        XCTAssertTrue(model.advancedBinding(for: .speech).wrappedValue)
    }

    func test_dismissingAnOldTaskSheetCannotCloseANewTaskSheet() {
        let model = makeModel()
        model.openModelManager(.speech)
        let oldSheet = model.modelManagerBinding(for: .speech)
        model.openModelManager(.translation)
        oldSheet.wrappedValue = false
        XCTAssertEqual(model.modelManagerTask, .translation)
        XCTAssertEqual(model.engineTask, .translation)
        model.modelManagerBinding(for: .translation).wrappedValue = false
        XCTAssertNil(model.modelManagerTask)
    }

    func test_searchDestinationRemainsUsableAfterItsArrivalPulseFades() async throws {
        let model = makeModel()
        model.reveal(.endpointBaseURL)
        try await Task.sleep(for: .milliseconds(2_600))
        XCTAssertNil(model.highlightedItem)
        XCTAssertEqual(model.revealedItem, .endpointBaseURL,
            "The backend configuration action must not disappear with its decorative pulse")
        model.open(.writing)
        XCTAssertNil(model.revealedItem)
    }
}
