import SwiftUI

/// Rounded wax-surface container with optional 1px border. Used for Settings
/// sections, Agent Info chunks, and Saved Workspaces rows. Caller controls
/// content via a `@ViewBuilder` closure; the container provides padding,
/// background, corner clipping, and the optional border.
struct KeepurCard<Content: View>: View {
    let bordered: Bool
    let content: Content

    init(bordered: Bool = false, @ViewBuilder content: () -> Content) {
        self.bordered = bordered
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(KeepurTheme.Spacing.s4)
            .background(KeepurTheme.Color.bgSurfaceDynamic)
            .clipShape(RoundedRectangle(cornerRadius: KeepurTheme.Radius.sm))
            .modifier(OptionalBorder(visible: bordered))
    }
}

private struct OptionalBorder: ViewModifier {
    let visible: Bool

    func body(content: Content) -> some View {
        if visible {
            content.keepurBorder(
                KeepurTheme.Color.borderDefaultDynamic,
                radius: KeepurTheme.Radius.sm,
                width: 1
            )
        } else {
            content
        }
    }
}
