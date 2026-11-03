// Adapted from Nibomo (kirill-markin/flashcards-open-source-app), Copyright (c) 2026 Kirill Markin.
// MIT license: Lingrove/Resources/NibomoUI-LICENSE.txt. See docs/MAC_W4_PROGRESS_REUSE_MAP.md.
import Charts
import SwiftUI
import LingroveNotebookEngine

// Upstream count fields are numeric rating/bucket totals, not collections with isEmpty.
// swiftlint:disable empty_count

private let progressReviewScheduleChartHeight: CGFloat = 220
private let progressReviewScheduleLegendMarkerSize: CGFloat = 10

/// Nibomo’s interactive schedule donut and eight-bucket legend. The parent supplies only
/// currently admitted corpus exercises; this view never reads or changes scheduling.
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
                Chart {
                    ForEach(self.nonEmptyBuckets) { bucket in
                        SectorMark(
                            angle: .value("Cards", bucket.count),
                            innerRadius: .ratio(0.62),
                            outerRadius: .ratio(self.outerRadiusRatio(for: bucket.key))
                        )
                        .foregroundStyle(progressReviewScheduleBucketColor(key: bucket.key))
                        .opacity(self.segmentOpacity(for: bucket.key))
                        .accessibilityLabel(progressReviewScheduleBucketTitle(key: bucket.key))
                        .accessibilityValue(
                            progressReviewScheduleBucketAccessibilityValue(
                                bucket: bucket,
                                totalCards: self.schedule.totalCards
                            )
                        )
                    }
                }
                .chartLegend(.hidden)
                .chartAngleSelection(value: self.$selectedAngle)
                .frame(height: progressReviewScheduleChartHeight)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(progressReviewScheduleChartAccessibilityLabel())
                .accessibilityValue(self.chartAccessibilityValue)
                .onChange(of: self.selectedAngle) { _, newValue in
                    self.handleChartAngleSelection(newValue)
                }

                VStack(alignment: .leading, spacing: 10) {
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
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.tint.opacity(self.isSelected ? 0.12 : 0))
                .padding(.horizontal, -8)
                .padding(.vertical, -4)
        )
        .opacity(self.isAnySelected && self.isSelected == false ? 0.35 : 1.0)
        .contentShape(Rectangle())
        .onTapGesture {
            guard self.bucket.count > 0 else {
                return
            }
            self.onTap()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(self.bucket.count > 0 ? .isButton : [])
        .accessibilityLabel(progressReviewScheduleBucketTitle(key: self.bucket.key))
        .accessibilityValue(
            progressReviewScheduleBucketAccessibilityValue(
                bucket: self.bucket,
                totalCards: self.totalCards
            )
        )
    }

    private var detailText: String {
        "\(self.bucket.count.formatted()) · \(progressReviewScheduleBucketPercentage(bucket: self.bucket, totalCards: self.totalCards))"
    }
}

// swiftlint:enable empty_count
