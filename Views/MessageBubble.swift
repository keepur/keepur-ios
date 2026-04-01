import SwiftUI
import UIKit

struct MessageBubble: View {
    let message: Message
    var showWaitingBadge: Bool = false

    var body: some View {
        switch message.role {
        case "user":
            userBubble
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
                Text(LocalizedStringKey(message.text))
                    .font(.body)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 18)
                            .fill(Color(.systemGray5))
                    )

                Text(message.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
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
                            .fill(Color(.systemGray5))
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
}
