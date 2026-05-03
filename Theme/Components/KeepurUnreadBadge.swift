import SwiftUI

/// Honey-tinted capsule with a white digit indicating an unread count.
/// Renders as `EmptyView` when the count is zero or negative; clamps display
/// to "9+" when the count exceeds 9.
struct KeepurUnreadBadge: View {
    let count: Int

    init(count: Int) {
        self.count = count
    }

    var body: some View {
        if count <= 0 {
            EmptyView()
        } else {
            Text(displayText)
                .font(KeepurTheme.Font.caption)
                .fontWeight(.semibold)
                .foregroundStyle(Color.white)
                .padding(.horizontal, KeepurTheme.Spacing.s1)
                .padding(.vertical, 1)
                .frame(minWidth: 18)
                .background(KeepurTheme.Color.honey500)
                .clipShape(Capsule())
                .accessibilityLabel("\(count) unread")
        }
    }

    private var displayText: String {
        count > 9 ? "9+" : "\(count)"
    }
}
