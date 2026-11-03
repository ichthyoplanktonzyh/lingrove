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
            HStack {
                Text(NotebookProgressCopy.text("title"))
                    .font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Spacer()
                Button(action: model.reload) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.bordered)
                    .disabled(isLoading)
                    .help(NotebookProgressCopy.text("refresh"))
                    .accessibilityLabel(NotebookProgressCopy.text("refresh"))
                    .accessibilityIdentifier("notebook.progress.refresh")
            }.padding(.horizontal, 24).padding(.vertical, 16)
            Divider()
            ScrollView {
                LingroveReadableContentLayout(maxWidth: lingroveReadableContentMaxWidth, horizontalPadding: 24) {
                    LazyVStack(alignment: .leading, spacing: 16) {
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
        VStack(alignment: .leading, spacing: 10) {
            Text(NotebookProgressCopy.text("scope.detail"))
                .font(.footnote).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: 16) {
                metric("metric.reviews", value: content.snapshot.totalReviews)
                metric("metric.active_senses", value: content.snapshot.activeSenses)
                metric("metric.exercises", value: content.snapshot.schedule.totalCards)
            }
        }
        .modifier(NotebookProgressCardModifier())
        .accessibilityIdentifier("notebook.progress.summary")

        if !content.snapshot.hasHistory {
            VStack(alignment: .leading, spacing: 6) {
                Label(NotebookProgressCopy.text("empty.title"), systemImage: "chart.bar")
                    .font(.headline)
                Text(NotebookProgressCopy.text("empty.detail")).foregroundStyle(.secondary)
            }
            .modifier(NotebookProgressCardModifier())
            .accessibilityIdentifier("notebook.progress.empty")
        }

        NotebookProgressStreakSection(summary: content.snapshot.summary, weeks: content.streakWeeks,
            calendar: content.snapshot.calendar)
            .modifier(NotebookProgressCardModifier())
            .accessibilityIdentifier("notebook.progress.streak")

        NotebookProgressReviewsSection(chartDays: content.chartDays, chartCalendar: content.snapshot.calendar,
            selectionResetKey: content.snapshot.scope.generation + content.snapshot.range.to)
            .modifier(NotebookProgressCardModifier())
            .accessibilityIdentifier("notebook.progress.reviews")

        NotebookProgressReviewScheduleSection(schedule: content.snapshot.schedule)
            .modifier(NotebookProgressCardModifier())
            .accessibilityIdentifier("notebook.progress.schedule")
    }

    private func metric(_ title: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value.formatted()).font(.title2.weight(.semibold)).monospacedDigit()
            Text(NotebookProgressCopy.text(title)).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
