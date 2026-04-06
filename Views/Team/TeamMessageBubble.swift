import MarkdownUI
import SwiftUI

struct TeamMessageBubble: View {
    let message: TeamMessage
    let isOwnMessage: Bool
    @State private var isPulsing = false

    var body: some View {
        if message.senderId == "system" {
            systemBubble
        } else if isOwnMessage {
            userBubble
        } else {
            agentBubble
        }
    }

    // MARK: - User Bubble (right-aligned)

    private var userBubble: some View {
        HStack {
            Spacer(minLength: 60)
            VStack(alignment: .trailing, spacing: 4) {
                ZStack(alignment: .bottomTrailing) {
                    Text(message.text)
                        .font(.body)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 18)
                                .fill(Color.accentColor)
                        )
                        .foregroundStyle(.white)

                    if message.pending {
                        Text("sending")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.secondary))
                            .offset(x: 4, y: 4)
                            .opacity(isPulsing ? 0.6 : 1.0)
                            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: isPulsing)
                            .onAppear { isPulsing = true }
                    }
                }

                Text(message.createdAt, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Agent Bubble (left-aligned, with sender name)

    private var agentBubble: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(message.senderName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Markdown(message.text)
                    .markdownTheme(.keepur)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 18)
                            .fill(Color.secondarySystemFill)
                    )

                Text(message.createdAt, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 60)
        }
    }

    // MARK: - System Bubble (centered)

    private var systemBubble: some View {
        HStack {
            Spacer()
            Text(message.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
            Spacer()
        }
    }
}
