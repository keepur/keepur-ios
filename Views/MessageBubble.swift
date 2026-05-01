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
            VStack(alignment: .trailing, spacing: KeepurTheme.Spacing.s1) {
                ZStack(alignment: .bottomTrailing) {
                    VStack(alignment: .trailing, spacing: KeepurTheme.Spacing.s2) {
                        if let data = message.attachmentData, let mimeType = message.attachmentType {
                            if mimeType.hasPrefix("image/"), let img = PlatformImage(data: data) {
                                Image(platformImage: img)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(maxHeight: 200)
                                    .clipShape(RoundedRectangle(cornerRadius: KeepurTheme.Radius.sm))
                            } else {
                                HStack(spacing: KeepurTheme.Spacing.s1) {
                                    Image(systemName: "doc.fill")
                                        .font(KeepurTheme.Font.caption)
                                    Text(message.attachmentName ?? "Attachment")
                                        .font(KeepurTheme.Font.caption)
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.white.opacity(0.2))
                                .clipShape(RoundedRectangle(cornerRadius: KeepurTheme.Radius.xs))
                            }
                        }

                        if !message.text.isEmpty && message.text != message.attachmentName {
                            Text(Self.attributedText(message.text))
                                .font(KeepurTheme.Font.body)
                                .textSelection(.enabled)
                        }
                    }
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

                    if showWaitingBadge {
                        Text("waiting")
                            .font(KeepurTheme.Font.caption)
                            .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
                            .padding(.horizontal, KeepurTheme.Spacing.s2)
                            .padding(.vertical, 2)
                            .background(
                                Capsule()
                                    .fill(KeepurTheme.Color.honey200)
                            )
                            .offset(x: 4, y: 4)
                            .opacity(isPulsing ? 0.6 : 1.0)
                            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: isPulsing)
                            .onAppear { isPulsing = true }
                    }
                }

                Text(message.timestamp, style: .time)
                    .font(KeepurTheme.Font.caption)
                    .foregroundStyle(KeepurTheme.Color.fgTertiary)
            }
        }
    }

    private var assistantBubble: some View {
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

                HStack(spacing: KeepurTheme.Spacing.s3) {
                    Text(message.timestamp, style: .time)
                        .font(KeepurTheme.Font.caption)
                        .foregroundStyle(KeepurTheme.Color.fgTertiary)

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

    private var unknownBubble: some View {
        HStack {
            VStack(alignment: .leading, spacing: KeepurTheme.Spacing.s1) {
                Text("Unsupported message")
                    .font(KeepurTheme.Font.caption)
                    .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)

                Text(message.text)
                    .font(KeepurTheme.Font.body)
                    .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: KeepurTheme.Radius.lg)
                            .fill(KeepurTheme.Color.bgSunkenDynamic)
                    )

                Text(message.timestamp, style: .time)
                    .font(KeepurTheme.Font.caption)
                    .foregroundStyle(KeepurTheme.Color.fgTertiary)
            }
            Spacer(minLength: 60)
        }
    }

    private var systemBubble: some View {
        HStack {
            Spacer()
            Text(message.text)
                .font(KeepurTheme.Font.caption)
                .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                .textSelection(.enabled)
                .padding(.vertical, KeepurTheme.Spacing.s2)
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
            VStack(alignment: .leading, spacing: KeepurTheme.Spacing.s1) {
                VStack(alignment: .leading, spacing: KeepurTheme.Spacing.s2) {
                    HStack(spacing: KeepurTheme.Spacing.s1) {
                        Image(systemName: KeepurTheme.Symbol.terminal)
                            .font(KeepurTheme.Font.caption)
                            .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                        Text(toolName)
                            .font(KeepurTheme.Font.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                    }

                    ScrollView {
                        Text(output)
                            .font(.custom(KeepurTheme.FontName.mono, size: 12))
                            .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .frame(maxHeight: 200)
                }
                .padding(.horizontal, KeepurTheme.Spacing.s3)
                .padding(.vertical, KeepurTheme.Spacing.s2)
                .background(
                    RoundedRectangle(cornerRadius: KeepurTheme.Radius.md)
                        .fill(KeepurTheme.Color.bgSunkenDynamic)
                )

                Text(message.timestamp, style: .time)
                    .font(KeepurTheme.Font.caption)
                    .foregroundStyle(KeepurTheme.Color.fgTertiary)
            }
            Spacer(minLength: 60)
        }
    }

    // MARK: - Link Detection

    private static func attributedText(_ text: String) -> AttributedString {
        let linkified = Self.wrapBareURLs(in: text)
        if let attributed = try? AttributedString(markdown: linkified, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return attributed
        }
        return AttributedString(text)
    }

    /// Wraps bare URLs (e.g. https://example.com) in markdown link syntax
    /// so AttributedString(markdown:) will make them tappable.
    private static func wrapBareURLs(in text: String) -> String {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return text
        }
        let nsText = text as NSString
        let matches = detector.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return text }

        var result = text
        // Process matches in reverse so indices stay valid
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let url = String(result[range])
            // Skip if already inside a markdown link: [...](url) or <url>
            let prefix = result[result.startIndex..<range.lowerBound]
            if prefix.hasSuffix("](") || prefix.hasSuffix("<") { continue }
            result.replaceSubrange(range, with: "[\(url)](\(url))")
        }
        return result
    }
}
