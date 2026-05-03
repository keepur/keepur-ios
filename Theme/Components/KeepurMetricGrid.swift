import SwiftUI

/// Three-column horizontal grid of label/value pairs. Each cell shows an
/// uppercase eyebrow label above its value. Used by Agent detail sheet to
/// render MODEL / MESSAGES / LAST ACTIVE. Degrades naturally for fewer than
/// 3 metrics (trailing cells empty) or more than 3 (wraps to next row).
struct KeepurMetricGrid: View {
    struct Metric: Identifiable {
        let id: UUID
        let label: String
        let value: String

        init(label: String, value: String) {
            self.id = UUID()
            self.label = label
            self.value = value
        }
    }

    let metrics: [Metric]

    init(_ metrics: [Metric]) {
        self.metrics = metrics
    }

    var body: some View {
        if metrics.isEmpty {
            EmptyView()
        } else {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3),
                spacing: KeepurTheme.Spacing.s3
            ) {
                ForEach(metrics) { metric in
                    VStack(alignment: .leading, spacing: KeepurTheme.Spacing.s1) {
                        Text(metric.label.uppercased())
                            .font(KeepurTheme.Font.eyebrow)
                            .tracking(KeepurTheme.Font.lsEyebrow)
                            .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                            .textCase(nil)
                        Text(metric.value)
                            .font(KeepurTheme.Font.bodySm)
                            .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(metric.label): \(metric.value)")
                }
            }
        }
    }
}
