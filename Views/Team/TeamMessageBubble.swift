import MarkdownUI
import SwiftUI

struct TeamMessageBubble: View {
    let message: TeamMessage
    let isOwnMessage: Bool
    var onSpeak: ((String) -> Void)? = nil
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
            VStack(alignment: .trailing, spacing: KeepurTheme.Spacing.s1) {
                ZStack(alignment: .bottomTrailing) {
                    Text(message.text)
                        .font(KeepurTheme.Font.body)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(KeepurTheme.Color.honey500)
                        .clipShape(.rect(
                            topLeadingRadius:     KeepurTheme.Radius.lg,
                            bottomLeadingRadius:  KeepurTheme.Radius.lg,
                            bottomTrailingRadius: 6,
                            topTrailingRadius:    KeepurTheme.Radius.lg
                        ))
                        .foregroundStyle(KeepurTheme.Color.fgOnHoney)

                    if message.pending {
                        Text("sending")
                            .font(KeepurTheme.Font.caption)
                            .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
                            .padding(.horizontal, KeepurTheme.Spacing.s2)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(KeepurTheme.Color.honey200))
                            .offset(x: 4, y: 4)
                            .opacity(isPulsing ? 0.6 : 1.0)
                            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: isPulsing)
                            .onAppear { isPulsing = true }
                    }
                }

                Text(message.createdAt, style: .time)
                    .font(KeepurTheme.Font.caption)
                    .foregroundStyle(KeepurTheme.Color.fgTertiary)
            }
        }
    }

    // MARK: - Agent Bubble (left-aligned, with sender name)

    private var agentBubble: some View {
        HStack {
            VStack(alignment: .leading, spacing: KeepurTheme.Spacing.s1) {
                Markdown(message.text)
                    .markdownTheme(.keepur)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: KeepurTheme.Radius.lg)
                            .fill(KeepurTheme.Color.bgSunkenDynamic)
                    )

                HStack(alignment: .center, spacing: KeepurTheme.Spacing.s3) {
                    HStack(spacing: KeepurTheme.Spacing.s2) {
                        KeepurAvatar(size: 24, content: .letter(message.senderName))
                        Text(message.createdAt, style: .time)
                            .font(KeepurTheme.Font.caption)
                            .foregroundStyle(KeepurTheme.Color.fgTertiary)
                    }

                    if let onSpeak {
                        Button { onSpeak(message.text) } label: {
                            Image(systemName: KeepurTheme.Symbol.speaker)
                                .font(KeepurTheme.Font.caption)
                                .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                        }
                    }
                }
            }
            Spacer(minLength: 60)
        }
    }

    // MARK: - System Bubble (centered)

    private var systemBubble: some View {
        HStack {
            Spacer()
            Text(message.text)
                .font(KeepurTheme.Font.caption)
                .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                .padding(.vertical, KeepurTheme.Spacing.s2)
            Spacer()
        }
    }
}
