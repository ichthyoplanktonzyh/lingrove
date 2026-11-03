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

/// Presentation is split from lifecycle so native integration tests can render the exact real
/// loaded/error/empty screen while controlling its disposable repository and read timing.
struct NotebookProgressDestination: View {
    @ObservedObject var model: NotebookProgressModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(NotebookProgressCopy.text("title")).font(.largeTitle.bold())
                    Spacer()
                    Button(action: model.reload) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help(NotebookProgressCopy.text("refresh"))
                    .accessibilityLabel(NotebookProgressCopy.text("refresh"))
                }
                switch model.state {
                case .inactive, .loading:
                    ProgressView(NotebookProgressCopy.text("loading"))
                        .frame(maxWidth: .infinity, minHeight: 200)
                case .failed:
                    VStack(alignment: .leading, spacing: 12) {
                        Label(NotebookProgressCopy.text("error.title"), systemImage: "exclamationmark.triangle")
                            .font(.headline)
                        Text(NotebookProgressCopy.text("error.detail")).foregroundStyle(.secondary)
                        Button(NotebookProgressCopy.text("retry"), action: model.reload)
                    }
                    .modifier(NotebookProgressCardModifier())
                    .accessibilityIdentifier("notebook.progress.error")
                case let .loaded(content):
                    NotebookProgressLoadedSections(content: content)
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(notebookProgressAccent)
        .accessibilityIdentifier("notebook.progress.destination")
    }
}

/// These are Nibomo's personal Progress cards in their original order. The notebook-specific
/// summary names senses and exercises separately; calendar/chart/donut interaction stays local.
private struct NotebookProgressLoadedSections: View {
    let content: NotebookProgressContent

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(NotebookProgressCopy.text("scope.detail"))
                .font(.footnote).foregroundStyle(.secondary)
            HStack(spacing: 24) {
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
            Text(value.formatted()).font(.title2.bold()).monospacedDigit()
            Text(NotebookProgressCopy.text(title)).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
