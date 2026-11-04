import SwiftUI
import LingroveNotebookEngine

/// The complete Progress destination required by the workspace composition seam. SwiftUI owns
/// one model through @StateObject, while the supplied repository remains app-owned. Visibility
/// starts/stops only read work; entering this page never enrolls material or starts cloud sync.
@MainActor
struct NotebookProgressView: View {
    @StateObject private var model: NotebookProgressModel
    private let isActive: Bool

    init(repository: MacNotebookRepository, isActive: Bool) {
        _model = StateObject(wrappedValue: NotebookProgressModel(repository: repository))
        self.isActive = isActive
    }

    var body: some View {
        NotebookProgressDestination(model: model)
            .onAppear { model.setActive(isActive) }
            .onChange(of: isActive) { _, active in model.setActive(active) }
            .onDisappear { model.setActive(false) }
    }
}

/// The destination projects the model's read state into native page chrome and section cards.
/// Its fixed heading matches Review; only the analytical document scrolls. Splitting it from
/// lifecycle lets native tests render real loaded/error/empty states from disposable storage.
struct NotebookProgressDestination: View {
    @ObservedObject var model: NotebookProgressModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(NotebookProgressCopy.text("title"))
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button(action: model.reload) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isLoading)
                    .help(NotebookProgressCopy.text("refresh"))
                    .accessibilityLabel(NotebookProgressCopy.text("refresh"))
                    .accessibilityIdentifier("notebook.progress.refresh")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
            Divider()
            ScrollView {
                LingroveReadableContentLayout(maxWidth: 1040, horizontalPadding: 24) {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        switch model.state {
                        case .inactive, .loading:
                            ProgressView(NotebookProgressCopy.text("loading"))
                                .frame(maxWidth: .infinity, minHeight: 200)
                                .accessibilityIdentifier("notebook.progress.loading")
                        case .failed:
                            ContentUnavailableView {
                                Label(NotebookProgressCopy.text("error.title"), systemImage: "exclamationmark.triangle")
                            } description: {
                                Text(NotebookProgressCopy.text("error.detail"))
                            } actions: {
                                Button(NotebookProgressCopy.text("retry"), action: model.reload).buttonStyle(.bordered)
                            }
                            .frame(maxWidth: .infinity, minHeight: 240)
                            .accessibilityIdentifier("notebook.progress.error")
                        case let .loaded(content):
                            NotebookProgressLoadedSections(content: content)
                        }
                    }
                    .padding(.vertical, 24)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("notebook.progress.destination")
    }

    private var isLoading: Bool {
        switch model.state {
        case .inactive, .loading: true
        case .failed, .loaded: false
        }
    }
}

/// The immutable snapshot keeps totals, calendar, rating distribution and eight schedule
/// buckets in their original order. The summary names senses and exercises separately; native
/// cards adapt their width while chart selections stay local to each visible section.
private struct NotebookProgressLoadedSections: View {
    let content: NotebookProgressContent

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "chart.xyaxis.line")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LingroveBrand.accent)
                Text(NotebookProgressCopy.text("scope.detail"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), alignment: .leading)], alignment: .leading, spacing: 14) {
                metric("metric.reviews", value: content.snapshot.totalReviews, icon: "checkmark.seal.fill", tint: .green)
                metric("metric.active_senses", value: content.snapshot.activeSenses, icon: "book.pages.fill", tint: LingroveBrand.accent)
                metric("metric.exercises", value: content.snapshot.schedule.totalCards, icon: "rectangle.stack.fill", tint: .orange)
            }
        }
        .modifier(NotebookProgressCardModifier())
        .accessibilityIdentifier("notebook.progress.summary")

        if !content.snapshot.hasHistory {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(LingroveBrand.accent.opacity(0.12))
                        .frame(width: 40, height: 40)
                    Image(systemName: "chart.bar")
                        .font(.headline)
                        .foregroundStyle(LingroveBrand.accent)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(NotebookProgressCopy.text("empty.title"))
                        .font(.headline)
                    Text(NotebookProgressCopy.text("empty.detail"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .modifier(NotebookProgressCardModifier())
            .accessibilityIdentifier("notebook.progress.empty")
        }

        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 18) {
                NotebookProgressStreakSection(summary: content.snapshot.summary, weeks: content.streakWeeks,
                    calendar: content.snapshot.calendar)
                    .modifier(NotebookProgressCardModifier())
                    .accessibilityIdentifier("notebook.progress.streak")
                    .frame(minWidth: 420, maxWidth: .infinity)

                NotebookProgressReviewScheduleSection(schedule: content.snapshot.schedule)
                    .modifier(NotebookProgressCardModifier())
                    .accessibilityIdentifier("notebook.progress.schedule")
                    .frame(minWidth: 380, maxWidth: .infinity)
            }

            VStack(alignment: .leading, spacing: 18) {
                NotebookProgressStreakSection(summary: content.snapshot.summary, weeks: content.streakWeeks,
                    calendar: content.snapshot.calendar)
                    .modifier(NotebookProgressCardModifier())
                    .accessibilityIdentifier("notebook.progress.streak")

                NotebookProgressReviewScheduleSection(schedule: content.snapshot.schedule)
                    .modifier(NotebookProgressCardModifier())
                    .accessibilityIdentifier("notebook.progress.schedule")
            }
        }

        NotebookProgressReviewsSection(chartDays: content.chartDays, chartCalendar: content.snapshot.calendar,
            selectionResetKey: content.snapshot.scope.generation + content.snapshot.range.to)
            .modifier(NotebookProgressCardModifier())
            .accessibilityIdentifier("notebook.progress.reviews")
    }

    private func metric(_ title: String, value: Int, icon: String, tint: Color) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(tint.opacity(0.13))
                    .frame(width: 38, height: 38)
                Image(systemName: icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(value.formatted())
                    .font(.title2.weight(.bold))
                    .monospacedDigit()
                Text(NotebookProgressCopy.text(title))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.32))
        }
    }
}
