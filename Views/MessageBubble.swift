import MarkdownUI
import SwiftUI

struct MessageBubble: View {
    let message: Message
    var showWaitingBadge: Bool = false
    var onSpeak: ((String) -> Void)? = nil
    @State private var isPulsing = false

    var body: some View {
        switch message.role {
        case "user":
            userBubble
        case "tool":
            toolBubble
        case "system":
            systemBubble
        case "unknown":
            unknownBubble
        default:
            assistantBubble
        }
    }

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

                    if showWaitingBadge {
                        Text("waiting")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(
                                Capsule()
                                    .fill(Color.secondary)
                            )
                            .offset(x: 4, y: 4)
                            .opacity(isPulsing ? 0.6 : 1.0)
                            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: isPulsing)
                            .onAppear { isPulsing = true }
                    }
                }

                Text(message.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var assistantBubble: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Markdown(message.text)
                    .markdownTheme(.keepur)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 18)
                            .fill(Color.secondarySystemFill)
                    )

                HStack(spacing: 12) {
                    Text(message.timestamp, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    if let onSpeak {
                        Button { onSpeak(message.text) } label: {
                            Image(systemName: "speaker.wave.2")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Spacer(minLength: 60)
        }
    }

    private var unknownBubble: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Unsupported message")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Text(message.text)
                    .font(.body)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 18)
                            .fill(Color.secondarySystemFill)
                    )

                Text(message.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 60)
        }
    }

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

    private var toolBubble: some View {
        let parts = message.text.split(separator: "\n", maxSplits: 1)
        let raw = parts.first.map(String.init) ?? ""
        let toolName: String = if raw.hasPrefix("[") && raw.hasSuffix("]") {
            String(raw.dropFirst().dropLast())
        } else {
            raw.isEmpty ? "Tool" : raw
        }
        let output = parts.count > 1 ? String(parts[1]) : ""

        return HStack {
            VStack(alignment: .leading, spacing: 4) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        Image(systemName: "terminal.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(toolName)
                            .font(.caption2.bold())
                            .foregroundStyle(.secondary)
                    }

                    ScrollView {
                        Text(output)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .frame(maxHeight: 200)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.tertiarySystemFill)
                )

                Text(message.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 60)
        }
    }
}
