// Empty-state/queue structure adapted from Nibomo ReviewView and ReviewQueuePreviewScreen (MIT).
// Copyright (c) 2026 Kirill Markin. License: Lingrove/Resources/NibomoUI-LICENSE.txt.
import LingroveNotebook
import LingroveNotebookEngine
import SwiftUI

/// Today is a projection of the frozen queue, never a command to begin practice. Each empty
/// state supplies one real next action; saved corpus, participation and scheduling stay distinct.
struct BuiltInReviewOverviewView: View {
    @ObservedObject var session: BuiltInReviewSession
    let content: NotebookBuiltInReviewSnapshot

    private var state: BuiltInReviewOverviewState { .init(content: content) }

    private var heroTint: Color {
        switch state {
        case .due: LingroveBrand.accent
        case .paused, .unavailable: .orange
        case .scheduled: .green
        case .noCorpus, .noSelection, .withdrawn: .secondary
        }
    }

    var body: some View {
        ScrollView {
            LingroveReadableContentLayout(maxWidth: lingroveReadableContentMaxWidth, horizontalPadding: 24) {
                VStack(alignment: .leading, spacing: 20) {
                    heroCard
                    metricsGrid
                    if !content.queue.isEmpty {
                        upcomingQueueSection
                    }
                }
                .padding(.vertical, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("builtinReview.overview.content")
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(heroTint.opacity(0.14))
                        .frame(width: 52, height: 52)
                    Image(systemName: state.symbol)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(heroTint)
                        .accessibilityHidden(true)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(BuiltInReviewCopy.text(state.titleKey))
                            .font(.title2.weight(.bold))
                            .accessibilityAddTraits(.isHeader)

                        if state == .due {
                            Text(content.queue.count.formatted())
                                .font(.subheadline.weight(.bold))
                                .monospacedDigit()
                                .foregroundStyle(.white)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 2.5)
                                .background(Capsule(style: .continuous).fill(LingroveBrand.accent))
                        }
                    }

                    if state == .due {
                        LabeledContent(BuiltInReviewCopy.text("count.ready"), value: content.queue.count.formatted())
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }

                    if let date = state.nextDue {
                        HStack(spacing: 6) {
                            Image(systemName: "calendar.badge.clock")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            LabeledContent(BuiltInReviewCopy.text("session.nextDue"),
                                value: date.formatted(date: .abbreviated, time: .shortened))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer(minLength: 0)
            }

            Divider().opacity(0.5)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    primaryActionButton
                    secondaryActionButtons
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 10) {
                    primaryActionButton
                    HStack(spacing: 10) {
                        secondaryActionButtons
                    }
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [heroTint.opacity(0.07), .clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(heroTint == .secondary ? Color(nsColor: .separatorColor).opacity(0.45) : heroTint.opacity(0.28), lineWidth: 1)
        )
    }

    private var primaryActionButton: some View {
        Button {
            switch state {
            case .due: session.start()
            case .noCorpus: session.onBrowseCorpus?()
            case .noSelection: session.showAdding()
            case .paused: session.showContent(filter: .paused)
            case .withdrawn: session.showContent(filter: .withdrawn)
            case .unavailable: session.showContent(filter: .attention)
            case .scheduled: session.showContent()
            }
        } label: {
            Label(BuiltInReviewCopy.text(state.actionKey), systemImage: state == .due ? "play.fill" : "arrow.right")
                .padding(.horizontal, 6)
        }
        .lingroveNativeProminentActionButtonStyle()
        .controlSize(.large)
        .accessibilityIdentifier(state == .due ? "builtinReview.start" : "builtinReview.overview.primary")
    }

    @ViewBuilder
    private var secondaryActionButtons: some View {
        if state != .noCorpus && state != .noSelection {
            Button(BuiltInReviewCopy.text("action.addContent"), systemImage: "plus") {
                session.showAdding()
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        if state != .unavailable, content.review.groups.values.contains(where: \.hasUnavailableMaterial) {
            Button(BuiltInReviewCopy.text("action.fixMaterial"), systemImage: "exclamationmark.triangle") {
                session.showContent(filter: .attention)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }

    private var metricsGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 14)], spacing: 14) {
            overviewStatCard(
                title: BuiltInReviewCopy.text("count.ready"),
                value: content.queue.count.formatted(),
                symbol: "bolt.fill",
                tint: content.queue.isEmpty ? .secondary : LingroveBrand.accent
            )
            overviewStatCard(
                title: BuiltInReviewCopy.text("count.exercises"),
                value: content.statistics.exercises.formatted(),
                symbol: "rectangle.stack.fill",
                tint: .blue
            )
            Button {
                session.editNoteType(content.defaultNoteType)
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.purple.opacity(0.12))
                            .frame(width: 36, height: 36)
                        Image(systemName: "paintbrush.pointed.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.purple)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(content.defaultNoteType.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(String(localized: "Card templates", table: "Vocabulary"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "slider.horizontal.3")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.45))
                )
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    private func overviewStatCard(title: String, value: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(tint.opacity(0.12))
                    .frame(width: 36, height: 36)
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.title3.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.45))
        )
    }

    private var upcomingQueueSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(BuiltInReviewCopy.text("queue.title"), systemImage: "list.bullet.rectangle")
                    .font(.headline)
                Spacer()
                Text("\(content.queue.count)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule(style: .continuous).fill(Color.primary.opacity(0.06)))
            }

            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(Array(content.queue.prefix(4).enumerated()), id: \.element.id) { index, card in
                    LingroveReviewQueuePreviewCardRow(card: card, isCurrent: index == 0)
                }
            }
        }
        .padding(.top, 4)
    }
}

/// This browser borrows session-owned search and filters. Adding is an explicit destination;
/// a detail round trip does not recreate local state or silently switch the visible list.
struct BuiltInReviewContentView: View {
    let content: NotebookBuiltInReviewSnapshot
    let index: BuiltInReviewContentState
    let selections: [VocabularySelection]
    @Binding var browsing: BuiltInReviewBrowsing
    var adding = false
    var selectedSenseID: UUID?
    var onAdd: (() -> Void)?
    var onEnroll: (([VocabularySelection]) -> Void)?
    let onSelect: (VocabularySelection) -> Void

    private var search: Binding<String> { adding ? $browsing.addingSearch : $browsing.search }
    private var emptyTitle: String {
        if !adding { return BuiltInReviewCopy.text("state.noMatches") }
        return BuiltInReviewCopy.text(index.hasCorpus ? "state.allAdded" : "state.noCorpus")
    }

    var body: some View {
        VStack(spacing: 0) {
            filterHeaderBar(selected: adding && onEnroll != nil ? index.selectedForEnrollment(browsing.selectedSenseIDs) : [])
            Divider().opacity(0.5)
            List(selections, id: \.senseID) { selection in
                let isSelected = !adding && selectedSenseID == selection.senseID
                HStack(spacing: 10) {
                    if adding, onEnroll != nil {
                        Toggle(BuiltInReviewCopy.text("action.enroll"), isOn: Binding(
                            get: { browsing.selectedSenseIDs.contains(selection.senseID) },
                            set: { isChecked in
                                if isChecked {
                                    browsing.selectedSenseIDs.insert(selection.senseID)
                                } else {
                                    browsing.selectedSenseIDs.remove(selection.senseID)
                                }
                            }))
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                            .accessibilityLabel(index.source(for: selection)?.expression ?? "")
                    }
                    Button { onSelect(selection) } label: {
                        row(selection, isSelected: isSelected)
                    }
                    .buttonStyle(.plain)
                }
                .listRowInsets(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
                .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .searchable(text: search, prompt: BuiltInReviewCopy.text("field.search"))
            .overlay {
                if selections.isEmpty {
                    if !search.wrappedValue.isEmpty {
                        ContentUnavailableView.search(text: search.wrappedValue)
                    } else {
                        ContentUnavailableView(emptyTitle, systemImage: "tray")
                    }
                }
            }
        }
        .accessibilityIdentifier("builtinReview.content")
    }

    private func filterHeaderBar(selected: [VocabularySelection]) -> some View {
        HStack(spacing: 10) {
            if !adding {
                Picker(BuiltInReviewCopy.text("nav.content"), selection: $browsing.filter) {
                    ForEach(BuiltInReviewContentFilter.allCases, id: \.self) { filter in
                        Text(BuiltInReviewCopy.text(filter.titleKey)).tag(filter)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 180)
                .accessibilityIdentifier("builtinReview.content.filter")

                Text("\(selections.count)")
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule(style: .continuous).fill(Color.primary.opacity(0.06)))

                Spacer(minLength: 4)

                Button {
                    onAdd?()
                } label: {
                    Label(BuiltInReviewCopy.text("action.addContent"), systemImage: "plus")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityIdentifier("builtinReview.content.add")
            } else if let onEnroll {
                HStack(spacing: 6) {
                    Text(BuiltInReviewCopy.text("nav.selected"))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(selected.count.formatted())
                        .font(.caption.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule(style: .continuous).fill(LingroveBrand.accent))
                }
                Spacer()
                Button(BuiltInReviewCopy.text("action.enroll")) { onEnroll(selected) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(selected.isEmpty)
                    .accessibilityIdentifier("builtinReview.content.enrollSelected")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func statusTint(_ status: LingroveNotebookReviewStatus) -> Color {
        switch status {
        case .active: .green
        case .paused: .orange
        case .withdrawn: .secondary
        }
    }

    private func row(_ selection: VocabularySelection, isSelected: Bool) -> some View {
        let source = index.source(for: selection)
        let group = content.review.groups[selection.senseID]
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(source?.expression ?? BuiltInReviewCopy.text("state.missingSource"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if let group {
                        let tint = statusTint(group.status)
                        Text(BuiltInReviewCopy.status(group.status))
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(tint)
                            .padding(.horizontal, 6.5)
                            .padding(.vertical, 1.5)
                            .background(Capsule(style: .continuous).fill(tint.opacity(0.12)))
                    }
                }

                Text(source?.meaning ?? BuiltInReviewCopy.text("material.retained"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                if let group, group.hasUnavailableMaterial {
                    Label(BuiltInReviewCopy.text("material.unavailable"), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 4)
            if let group, !group.cards.isEmpty {
                Text("\(group.cards.count)")
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule(style: .continuous).fill(Color.primary.opacity(0.06)))
            }
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? LingroveBrand.accent.opacity(0.11) : Color(nsColor: .controlBackgroundColor).opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isSelected ? LingroveBrand.accent.opacity(0.35) : Color.primary.opacity(0.06),
                    lineWidth: isSelected ? 1 : 0.5
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// A standalone chooser owns only temporary browsing state; it shares the same list projection.
struct BuiltInReviewSenseChooser: View {
    let content: NotebookBuiltInReviewSnapshot
    let onSelect: (VocabularySelection) -> Void
    @State private var browsing = BuiltInReviewBrowsing()
    @Environment(\.dismiss) private var dismiss
    private let index: BuiltInReviewContentState

    init(content: NotebookBuiltInReviewSnapshot, onSelect: @escaping (VocabularySelection) -> Void) {
        self.content = content
        self.onSelect = onSelect
        index = BuiltInReviewContentState(content)
    }

    var body: some View {
        NavigationStack {
            BuiltInReviewContentView(content: content, index: index,
                selections: index.selections(adding: true, filter: browsing.filter, search: browsing.addingSearch),
                browsing: $browsing, adding: true, onSelect: onSelect)
                .navigationTitle(BuiltInReviewCopy.text("action.addContent"))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(BuiltInReviewCopy.text("action.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                            .accessibilityIdentifier("builtinReview.senseChooser.cancel")
                    }
                }
        }.frame(minWidth: 540, idealWidth: 620, minHeight: 460, idealHeight: 560)
            .accessibilityIdentifier("builtinReview.senseChooser")
    }
}

/// The preview uses Nibomo’s extracted rows and active/later separator. The frozen snapshot
/// already bounds its contents, so no second paginated store or background network loader exists.
struct BuiltInReviewQueuePreviewView: View {
    let content: NotebookBuiltInReviewSnapshot
    let currentCardID: String?
    @Environment(\.dismiss) private var dismiss

    private var later: [Card] {
        let ready = Set(content.queue.map(\.cardId))
        return content.review.groups.values.filter { $0.status == .active && !$0.hasUnavailableMaterial }
            .flatMap(\.cards).filter { !ready.contains($0.cardId) }
            .sorted { ($0.dueAt ?? "") < ($1.dueAt ?? "") }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LingroveReadableContentLayout(maxWidth: lingroveReadableContentMaxWidth, horizontalPadding: 20) {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(content.queue) { card in
                            LingroveReviewQueuePreviewCardRow(card: card, isCurrent: card.cardId == currentCardID)
                        }
                        if !later.isEmpty {
                            LingroveReviewQueueSectionSeparator()
                            ForEach(later) { card in LingroveReviewQueuePreviewCardRow(card: card, isCurrent: false) }
                        }
                        if content.queue.isEmpty && later.isEmpty {
                            ContentUnavailableView(String(localized: "Nothing Due", table: "ReviewCards"), systemImage: "tray")
                        }
                    }.padding(.vertical, 20)
                }
            }
                .background(Color(nsColor: .windowBackgroundColor))
                .navigationTitle(BuiltInReviewCopy.text("queue.title"))
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "Close", table: "ReviewCards")) { dismiss() }.keyboardShortcut(.cancelAction)
                            .accessibilityIdentifier("builtinReview.queuePreview.close")
                    }
                }
        }
        .frame(minWidth: 540, idealWidth: 720, minHeight: 460, idealHeight: 580)
        .accessibilityIdentifier("builtinReview.queuePreview")
    }
}
