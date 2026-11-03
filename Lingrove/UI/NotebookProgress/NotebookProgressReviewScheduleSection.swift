// Adapted from Nibomo (kirill-markin/flashcards-open-source-app), Copyright (c) 2026 Kirill Markin.
// MIT license: Lingrove/Resources/NibomoUI-LICENSE.txt. See docs/MAC_PROGRESS_UI_REUSE.md.
import Charts
import SwiftUI
import LingroveNotebookEngine

// Upstream count fields are numeric rating/bucket totals, not collections with isEmpty.
// swiftlint:disable empty_count

private let progressReviewScheduleChartHeight: CGFloat = 220
private let progressReviewScheduleLegendMarkerSize: CGFloat = 10

/// The destination supplies only currently eligible exercises to this eight-bucket forecast.
/// Donut and native legend buttons share transient selection; adapting the layout never reads
/// or changes scheduling, and every color retains a written category, count and percentage.
struct NotebookProgressReviewScheduleSection: View {
    let schedule: UserReviewSchedule

    @State private var selectedBucketKey: ReviewScheduleBucketKey?
    @State private var selectedAngle: Int?

    private var buckets: [ReviewScheduleBucket] {
        self.schedule.buckets
    }

    private var nonEmptyBuckets: [ReviewScheduleBucket] {
        self.buckets.filter { bucket in
            bucket.count > 0
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(
                String(
                    localized: "progress.screen.review_schedule.section_title",
                    defaultValue: "Review schedule",
                    table: "NotebookProgress",
                    comment: "Progress review schedule section title"
                )
            )
            .font(.headline)

            if self.schedule.totalCards > 0 {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 24) {
                        scheduleChart.frame(width: 220)
                        legend.frame(minWidth: 260)
                    }
                    VStack(spacing: 16) {
                        scheduleChart
                        legend
                    }
                }
            } else {
                Text(
                    String(
                        localized: "progress.screen.review_schedule.empty",
                        defaultValue: "No reviewable exercises yet.",
                        table: "NotebookProgress",
                        comment: "Progress review schedule empty caption"
                    )
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .background(
            // Background tap layer only fires when no foreground view (chart, legend row)
            // claims the tap, so it does not compete with the Charts selection gesture.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    self.selectedBucketKey = nil
                }
        )
        .onChange(of: schedule) { _, _ in
            // A refresh can replace the forecast while this view survives. Selection belongs
            // to the displayed snapshot, so a vanished bucket must not leave every wedge dim.
            selectedBucketKey = nil
            selectedAngle = nil
        }
    }

    private var scheduleChart: some View {
        Chart {
            ForEach(self.nonEmptyBuckets) { bucket in
                SectorMark(
                    angle: .value("Cards", bucket.count),
                    innerRadius: .ratio(0.68),
                    outerRadius: .ratio(self.outerRadiusRatio(for: bucket.key))
                )
                .foregroundStyle(progressReviewScheduleBucketColor(key: bucket.key))
                .opacity(self.segmentOpacity(for: bucket.key))
                .accessibilityLabel(progressReviewScheduleBucketTitle(key: bucket.key))
                .accessibilityValue(progressReviewScheduleBucketAccessibilityValue(bucket: bucket, totalCards: self.schedule.totalCards))
            }
        }
        .chartLegend(.hidden)
        .chartAngleSelection(value: self.$selectedAngle)
        .frame(height: progressReviewScheduleChartHeight)
        .overlay {
            VStack(spacing: 4) {
                Text((selectedBucket?.count ?? schedule.totalCards).formatted())
                    .font(.title2.weight(.semibold)).monospacedDigit()
                Text(selectedBucket.map { progressReviewScheduleBucketTitle(key: $0.key) }
                    ?? NotebookProgressCopy.text("metric.exercises"))
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: 130).allowsHitTesting(false).accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(progressReviewScheduleChartAccessibilityLabel())
        .accessibilityValue(self.chartAccessibilityValue)
        .accessibilityIdentifier("notebook.progress.schedule.chart")
        .onChange(of: self.selectedAngle) { _, newValue in self.handleChartAngleSelection(newValue) }
    }

    private var selectedBucket: ReviewScheduleBucket? {
        buckets.first { $0.key == selectedBucketKey }
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(self.buckets) { bucket in
                ProgressReviewScheduleLegendRow(
                    bucket: bucket,
                    totalCards: self.schedule.totalCards,
                    isSelected: self.selectedBucketKey == bucket.key,
                    isAnySelected: self.selectedBucketKey != nil,
                    onTap: { self.toggleSelection(for: bucket.key) }
                )
            }
        }
    }

    private var chartAccessibilityValue: String {
        let summary = progressReviewScheduleAccessibilitySummary(schedule: self.schedule)
        guard let selected = self.selectedBucketKey else {
            return summary
        }
        let selectedTitle = progressReviewScheduleBucketTitle(key: selected)
        return "\(selectedTitle), \(summary)"
    }

    private func isDimmed(_ key: ReviewScheduleBucketKey) -> Bool {
        guard let selected = self.selectedBucketKey else {
            return false
        }
        return selected != key
    }

    private func segmentOpacity(for key: ReviewScheduleBucketKey) -> Double {
        self.isDimmed(key) ? 0.35 : 1.0
    }

    // The selected wedge pops out instead of taking an accent stroke, the native emphasis for a `SectorMark`.
    private func outerRadiusRatio(for key: ReviewScheduleBucketKey) -> Double {
        self.isDimmed(key) ? 0.94 : 1.0
    }

    private func toggleSelection(for key: ReviewScheduleBucketKey) {
        if self.selectedBucketKey == key {
            self.selectedBucketKey = nil
        } else {
            self.selectedBucketKey = key
        }
    }

    private func handleChartAngleSelection(_ angleValue: Int?) {
        guard let angleValue else {
            return
        }
        let totalCards = self.schedule.totalCards
        guard totalCards > 0 else {
            return
        }
        let tappedKey = bucketKeyForChartAngle(
            angleValue: angleValue,
            buckets: self.nonEmptyBuckets
        )
        guard let tappedKey else {
            return
        }
        self.toggleSelection(for: tappedKey)
        // Reset so a tap on the same segment fires another onChange (toggle-off).
        self.selectedAngle = nil
    }
}

// Boundary policy: an exact tap on a wedge boundary maps to the earlier wedge.
// Pure mapping from a Swift Charts angle-selection value (running cards count)
// to the bucket whose wedge it falls inside.
private func bucketKeyForChartAngle(
    angleValue: Int,
    buckets: [ReviewScheduleBucket]
) -> ReviewScheduleBucketKey? {
    guard buckets.isEmpty == false else {
        return nil
    }
    var runningTotal: Int = 0
    for bucket in buckets {
        runningTotal += bucket.count
        if angleValue <= runningTotal {
            return bucket.key
        }
    }
    assertionFailure("bucketKeyForChartAngle: angleValue \(angleValue) exceeded running total \(runningTotal)")
    return buckets.last?.key
}

private struct ProgressReviewScheduleLegendRow: View {
    let bucket: ReviewScheduleBucket
    let totalCards: Int
    let isSelected: Bool
    let isAnySelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Circle()
                    .fill(progressReviewScheduleBucketColor(key: self.bucket.key))
                    .overlay(
                        Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                    )
                    .frame(
                        width: progressReviewScheduleLegendMarkerSize,
                        height: progressReviewScheduleLegendMarkerSize
                    )
                    .accessibilityHidden(true)

                Text(progressReviewScheduleBucketTitle(key: self.bucket.key))
                    .font(.subheadline)
                    .foregroundStyle(.primary)

                Spacer(minLength: 12)

                Text(self.detailText)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.tint.opacity(self.isSelected ? 0.12 : 0))
            )
            .opacity(self.isAnySelected && self.isSelected == false ? 0.5 : 1.0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(self.bucket.count == 0)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityLabel(progressReviewScheduleBucketTitle(key: self.bucket.key))
        .accessibilityValue(
            progressReviewScheduleBucketAccessibilityValue(
                bucket: self.bucket,
                totalCards: self.totalCards
            )
        )
        .help(progressReviewScheduleBucketTitle(key: bucket.key) + ": " + detailText)
        .accessibilityIdentifier("notebook.progress.bucket." + bucket.key.rawValue)
    }

    private var detailText: String {
        "\(self.bucket.count.formatted()) · \(progressReviewScheduleBucketPercentage(bucket: self.bucket, totalCards: self.totalCards))"
    }
}

// swiftlint:enable empty_count
