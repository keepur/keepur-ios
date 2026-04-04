import SwiftUI
import Combine

struct ToolApprovalView: View {
    let approval: ChatViewModel.ToolApproval
    let onApprove: () -> Void
    let onDeny: () -> Void

    @State private var remainingSeconds = 60

    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)

            Text("Approval Required")
                .font(.title2.bold())

            VStack(spacing: 8) {
                Text("Tool: \(approval.tool)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text(approval.input)
                    .font(.system(.body, design: .monospaced))
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(.systemGray6))
                    )
            }
            .padding(.horizontal, 24)

            Text("Auto-deny in \(remainingSeconds)s")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                Button {
                    onDeny()
                } label: {
                    Text("Deny")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.red)

                Button {
                    onApprove()
                } label: {
                    Text("Approve")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }
            .padding(.horizontal, 24)

            Spacer()
        }
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
