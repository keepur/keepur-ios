import SwiftUI
import Combine

struct ToolApprovalView: View {
    let approval: ChatViewModel.ToolApproval
    let onApprove: () -> Void
    let onDeny: () -> Void

    @State private var remainingSeconds = 60

    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: KeepurTheme.Spacing.s5) {
            Spacer()

            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 48))
                .foregroundStyle(KeepurTheme.Color.warning)

            Text("Approval Required")
                .font(KeepurTheme.Font.h3)
                .tracking(KeepurTheme.Font.lsH3)
                .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)

            VStack(spacing: KeepurTheme.Spacing.s2) {
                Text("TOOL")
                    .font(KeepurTheme.Font.eyebrow)
                    .tracking(KeepurTheme.Font.lsEyebrow)
                    .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(approval.tool)
                    .font(KeepurTheme.Font.bodySm)
                    .fontWeight(.medium)
                    .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(approval.input)
                    .font(.custom(KeepurTheme.FontName.mono, size: 14))
                    .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
                    .padding(KeepurTheme.Spacing.s3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: KeepurTheme.Radius.md)
                            .fill(KeepurTheme.Color.bgSunkenDynamic)
                    )
            }
            .padding(.horizontal, KeepurTheme.Spacing.s5)

            Text("Auto-deny in \(remainingSeconds)s")
                .font(KeepurTheme.Font.caption)
                .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)

            HStack(spacing: KeepurTheme.Spacing.s4) {
                Button { onDeny() } label: {
                    Text("Deny")
                }
                .buttonStyle(KeepurDestructiveButtonStyle())

                Button { onApprove() } label: {
                    Text("Approve")
                }
                .buttonStyle(KeepurPrimaryButtonStyle())
            }
            .padding(.horizontal, KeepurTheme.Spacing.s5)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(KeepurTheme.Color.bgPageDynamic)
        .onReceive(timer) { _ in
            if remainingSeconds > 0 {
                remainingSeconds -= 1
            } else {
                onDeny()
            }
        }
        .presentationDetents([.medium])
    }
}
