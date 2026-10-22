import SwiftUI

/// One navigation vocabulary for read-only product introductions. It never selects a backend or
/// changes a feature; each guide/showcase owns its own short-lived selection.
enum ProductFeatureArea: String, CaseIterable, Identifiable {
    case completion, learning
    var id: String { rawValue }
    var label: String {
        switch self {
        case .completion: String(localized: "Autocomplete")
        case .learning: String(localized: "Language Learning", table: "Learning")
        }
    }
}

/// Home and onboarding share the same two feature areas. The completion demo remains the original
/// component; learning adds a bounded local illustration. Unmounting an area cancels its animation.
struct ProductFeatureShowcase: View {
    var autoplay = true
    var showsMacroReference = false
    /// Home has an interactive walkthrough; Help and first-run setup keep their own content
    /// until their separate information-architecture review is complete.
    var usesHomeLearningScenes = false
    var readingSettings: LanguageLearningSettings?
    @State private var area = ProductFeatureArea.completion

    var body: some View {
        VStack(spacing: 16) {
            Picker(String(localized: "Quick controls", table: "Learning"), selection: $area) {
                ForEach(ProductFeatureArea.allCases) { Text($0.label).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().accessibilityIdentifier("productShowcaseArea")
            switch area {
            case .completion: OnboardingFeatureShowcase(autoplay: autoplay, showsMacroReference: showsMacroReference)
            case .learning:
                if usesHomeLearningScenes {
                    HomeLearningShowcase(readingSettings: readingSettings)
                } else { LearningFeatureShowcase(autoplay: autoplay) }
            }
        }
    }
}

/// Fixed example data, deliberately independent of the live preview, dictionary, speech and
/// notebook controllers. Opening a guide cannot send text, load weights, play sound or save data.
enum LearningShowcaseExample {
    static let source = "请随时告诉我项目的最新进展。"
    static let translation = "Please keep me posted on the project's progress."
    static let expression = "keep someone posted"
    static let cloze = "Please ___ me ___ on the project's progress."
}

/// Separate, feature-specific demonstrations share the original completion demo's chrome. Each
/// card owns a hover-scoped timeline: reading Home or Help cannot start five background loops.
/// The content represents real UI actions, but has no dependency on their service controllers.
struct LearningFeatureShowcase: View {
    var autoplay = false

    var body: some View {
        VStack(spacing: 12) {
            LearningDemoCard(caption: String(localized: "Translation", table: "Learning"),
                contentHeight: 138, autoplay: autoplay, restingPhase: 1) { phase in
                translation(phase)
            }
            LearningDemoCard(caption: String(localized: "AI explanation", table: "Learning"),
                contentHeight: 154, autoplay: autoplay) { phase in explanation(phase) }
            LearningDemoCard(caption: String(localized: "Read Aloud", table: "Learning"),
                contentHeight: 96, autoplay: autoplay) { phase in speech(phase) }
            LearningDemoCard(caption: String(localized: "Vocabulary", table: "Vocabulary"),
                contentHeight: 154, autoplay: autoplay) { phase in favorite(phase) }
            LearningDemoCard(caption: String(localized: "Anki review", table: "Vocabulary"),
                contentHeight: 122, autoplay: autoplay) { phase in review(phase) }
        }
        // Stable, actionable descriptions live in the guide below these decorative timelines.
        .accessibilityHidden(true)
        .accessibilityIdentifier("learningWorkflowExample")
    }

    private func translation(_ phase: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(String(localized: "Writing")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "text.cursor").foregroundStyle(.secondary)
            }
            Text(verbatim: phase >= 3 ? LearningShowcaseExample.translation : LearningShowcaseExample.source)
                .font(.system(size: 15)).frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                .padding(8)
                .background(phase >= 3 ? CotabbyBrand.accent.opacity(0.08) : Color.primary.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 6))
            HStack(alignment: .top, spacing: 10) {
                Text(verbatim: LearningShowcaseExample.translation).font(.subheadline)
                Spacer(minLength: 0)
                Image(systemName: "arrow.left.arrow.right").foregroundStyle(CotabbyBrand.accent)
                    .padding(5).background(CotabbyBrand.accent.opacity(phase == 2 ? 0.2 : 0), in: Circle())
            }.opacity(phase >= 1 ? 1 : 0)
        }
    }

    private func explanation(_ phase: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(highlightedExample).font(.subheadline)
            HStack(spacing: 8) {
                if phase == 1 { ProgressView().controlSize(.mini) } else {
                    Image(systemName: "sparkles").foregroundStyle(CotabbyBrand.accent)
                }
                Text(verbatim: "keep me posted").font(.subheadline.weight(.medium))
            }
            Text(String(localized: "Keep someone informed about new developments.", table: "Learning"))
                .font(.subheadline.weight(.semibold)).opacity(phase >= 2 ? 1 : 0)
            VStack(alignment: .leading, spacing: 5) {
                Label(String(localized: "Details", table: "Learning"),
                    systemImage: phase >= 3 ? "chevron.down" : "chevron.right")
                    .font(.caption).foregroundStyle(.secondary)
                Text(verbatim: "keep + someone + posted").font(.subheadline.monospaced())
                    .opacity(phase >= 3 ? 1 : 0)
            }.opacity(phase >= 2 ? 1 : 0)
        }
    }

    private func speech(_ phase: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(spokenExpression(phase)).font(.system(size: 17, weight: .medium))
                Spacer()
                Image(systemName: (1...3).contains(phase) ? "stop.fill" : "speaker.wave.2")
                    .foregroundStyle(CotabbyBrand.accent).frame(width: 24)
            }
            HStack(alignment: .center, spacing: 4) {
                ForEach(0..<18) { index in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(CotabbyBrand.accent.opacity((1...3).contains(phase) ? 0.65 : 0.2))
                        .frame(width: 4, height: (1...3).contains(phase) ? CGFloat(8 + ((index + phase * 3) * 7 % 24)) : 6)
                }
                Spacer()
            }.frame(height: 32)
            ProgressView(value: Double(phase), total: 4).tint(CotabbyBrand.accent)
        }
    }

    private func favorite(_ phase: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(verbatim: LearningShowcaseExample.expression).font(.subheadline.weight(.medium))
                Spacer()
                VocabularyFavoriteIcon(isSaved: phase >= 2).frame(width: 21, height: 21)
                    .padding(4).background(CotabbyBrand.accent.opacity(phase == 1 ? 0.15 : 0), in: Circle())
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(String(localized: "Vocabulary", table: "Vocabulary")).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Label(String(localized: "Saved", table: "Vocabulary"), systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                }
                Text(String(localized: "Keep someone informed about new developments.", table: "Learning"))
                    .font(.subheadline.weight(.medium))
                Text(highlightedExample).font(.caption).foregroundStyle(.secondary)
            }.opacity(phase >= 2 ? 1 : 0)
        }
    }

    private func review(_ phase: Int) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                Text(String(localized: "Front", table: "Vocabulary")).font(.caption).foregroundStyle(.secondary)
                Text(verbatim: LearningShowcaseExample.cloze).font(.subheadline)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Image(systemName: "arrow.right").foregroundStyle(CotabbyBrand.accent)
            VStack(alignment: .leading, spacing: 10) {
                Text(String(localized: "Back", table: "Vocabulary")).font(.caption).foregroundStyle(.secondary)
                Text(verbatim: LearningShowcaseExample.expression).font(.subheadline.weight(.semibold))
                Text(String(localized: "Keep someone informed about new developments.", table: "Learning"))
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .opacity(phase >= 2 ? 1 : 0)
        }
    }

    private var highlightedExample: AttributedString {
        var text = AttributedString(LearningShowcaseExample.translation)
        if let range = text.range(of: "keep me posted") { text[range].foregroundColor = CotabbyBrand.accent }
        return text
    }

    private func spokenExpression(_ phase: Int) -> AttributedString {
        var text = AttributedString(LearningShowcaseExample.expression)
        let words = LearningShowcaseExample.expression.split(separator: " ")
        if (1...words.count).contains(phase), let range = text.range(of: String(words[phase - 1])) {
            text[range].foregroundColor = CotabbyBrand.accent
        }
        return text
    }
}

/// Presentation-only state lives with each demo and is discarded on tab/window removal. Idle and
/// Reduce Motion use a useful resting frame; hover plays five bounded phases and cancels on exit.
private struct LearningDemoCard<Content: View>: View {
    let caption: String
    let contentHeight: CGFloat
    let autoplay: Bool
    var restingPhase = 4
    @ViewBuilder let content: (Int) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false
    @State private var phase = 0
    private var animating: Bool { (autoplay || isHovering) && !reduceMotion }

    var body: some View {
        OnboardingDemoCard(caption: caption, contentHeight: contentHeight) {
            content(animating ? phase : restingPhase)
        }
        .onHover { isHovering = $0 }
        .task(id: animating) {
            guard animating else { return }
            phase = 0
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(950)) } catch { return }
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.2)) { phase = (phase + 1) % 5 }
            }
        }
    }
}
