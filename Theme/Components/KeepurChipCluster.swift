import SwiftUI

/// Wrapping flow-layout cluster of small pill chips. Used for Tools, Channels.
/// When `maxVisible` is set and exceeded, renders a trailing "+N" chip in the
/// same wax styling (overflow is informational, not interactive).
struct KeepurChipCluster: View {
    let labels: [String]
    let maxVisible: Int?

    init(_ labels: [String], maxVisible: Int? = nil) {
        self.labels = labels
        self.maxVisible = maxVisible
    }

    private var visibleLabels: [String] {
        guard let cap = maxVisible, cap < labels.count else { return labels }
        return Array(labels.prefix(cap))
    }

    private var overflowCount: Int {
        guard let cap = maxVisible, cap < labels.count else { return 0 }
        return labels.count - cap
    }

    private var combinedAccessibilityLabel: String {
        if overflowCount > 0 {
            return visibleLabels.joined(separator: ", ") + ", plus \(overflowCount) more"
        }
        return labels.joined(separator: ", ")
    }

    var body: some View {
        WrappingHStack(hSpacing: KeepurTheme.Spacing.s1, vSpacing: KeepurTheme.Spacing.s1) {
            ForEach(Array(visibleLabels.enumerated()), id: \.offset) { _, label in
                chipView(label: label)
            }
            if overflowCount > 0 {
                chipView(label: "+\(overflowCount)")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(combinedAccessibilityLabel)
    }

    private func chipView(label: String) -> some View {
        Text(label)
            .font(KeepurTheme.Font.caption)
            .foregroundStyle(KeepurTheme.Color.fgSecondary)
            .padding(.horizontal, KeepurTheme.Spacing.s2)
            .padding(.vertical, KeepurTheme.Spacing.s1)
            .background(KeepurTheme.Color.wax100)
            .clipShape(RoundedRectangle(cornerRadius: KeepurTheme.Radius.xs))
    }
}

fileprivate struct WrappingHStack: Layout {
    var hSpacing: CGFloat
    var vSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = computeRows(maxWidth: maxWidth, subviews: subviews)
        let totalHeight = rows.reduce(0) { $0 + $1.height } + CGFloat(max(0, rows.count - 1)) * vSpacing
        let usedWidth = rows.map { $0.width }.max() ?? 0
        return CGSize(width: min(usedWidth, maxWidth), height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(maxWidth: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + hSpacing
            }
            y += row.height + vSpacing
        }
    }

    private struct Row { var indices: [Int]; var width: CGFloat; var height: CGFloat }

    private func computeRows(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row(indices: [], width: 0, height: 0)
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let prospective = current.width + (current.indices.isEmpty ? 0 : hSpacing) + size.width
            if prospective > maxWidth, !current.indices.isEmpty {
                rows.append(current)
                current = Row(indices: [index], width: size.width, height: size.height)
            } else {
                if !current.indices.isEmpty { current.width += hSpacing }
                current.indices.append(index)
                current.width += size.width
                current.height = max(current.height, size.height)
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
