# MessageBubble Migration Implementation Plan

> **For agentic workers:** Use `dodi-dev:implement` to execute this plan.

**Goal:** Migrate `Views/MessageBubble.swift` to consume `KeepurTheme` tokens. User bubble = honey-500 with asymmetric 6pt tail; assistant/unknown = wax surface; tool = wax sunken card with JetBrains Mono output; waiting badge = amber capsule.

**Architecture:** Single-file rewrite, no foundation changes, no new files.

**Tech Stack:** SwiftUI, MarkdownUI, NSDataDetector. iOS 26.2+ / macOS 15.0+.

**Spec:** [docs/specs/2026-04-30-message-bubble-migration.md](../specs/2026-04-30-message-bubble-migration.md)

**Out of scope:** `MessageInputBar` (DOD-395), `ChatView` chrome (DOD-395), `MarkdownTheme.keepur`, link-detection helpers.

---

## File Map

| File | Change |
|------|--------|
| `Views/MessageBubble.swift` | **Rewrite** — same surface, all values from `KeepurTheme.*` |

---

## Task 1: Preflight verification

- [ ] **Step 1.1:** Confirm worktree state.

```bash
pwd
git rev-parse --abbrev-ref HEAD
git log --oneline -2
```

Expected: `/Users/mayhuang/github/keepur-ios-DOD-394`, branch `DOD-394`, top commit is the spec.

- [ ] **Step 1.2:** Confirm tokens used resolve.

```bash
for sym in honey500 honey200 fgOnHoney bgSunkenDynamic fgPrimaryDynamic fgSecondaryDynamic fgTertiary; do
  printf "Color.%-22s -> %s\n" "$sym" "$(grep -c "let $sym" Theme/KeepurTheme.swift)"
done
for sym in body caption; do
  printf "Font.%-23s -> %s\n" "$sym" "$(grep -c "let $sym" Theme/KeepurTheme.swift)"
done
for sym in s1 s2 s3; do
  printf "Spacing.%-20s -> %s\n" "$sym" "$(grep -c "let $sym:" Theme/KeepurTheme.swift)"
done
for sym in xs sm md lg; do
  printf "Radius.%-21s -> %s\n" "$sym" "$(grep -c "let $sym:" Theme/KeepurTheme.swift)"
done
for sym in mono; do
  printf "FontName.%-19s -> %s\n" "$sym" "$(grep -c "let $sym " Theme/KeepurTheme.swift)"
done
for sym in terminal speaker; do
  printf "Symbol.%-21s -> %s\n" "$sym" "$(grep -c "let $sym " Theme/KeepurTheme.swift)"
done
```

Expected: every count ≥ 1. (`Font.body` = 2 due to `FontName.mono` shadowing in regex.)

- [ ] **Step 1.3:** Confirm no MessageBubble test references.

```bash
grep -rln "MessageBubble" KeeperTests/ 2>/dev/null || echo "(no matches)"
```

Expected: `(no matches)`.

- [ ] **Step 1.4:** No commit.

---

## Task 2: Rewrite `Views/MessageBubble.swift`

**Files:**
- Modify: `Views/MessageBubble.swift` (full rewrite, same surface, same behavior)

- [ ] **Step 2.1:** Replace the entire file with this version.

```swift
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
```

Notes vs current:
- `userBubble`: honey-500 fill, charcoal text via `fgOnHoney`, asymmetric 6pt bottom-trailing tail (was symmetric 18pt). Inner spacing/padding constants kept inline (14/10) per the foundation reference snippet.
- `assistantBubble`: `bgSunkenDynamic` instead of `secondarySystemFill`. Markdown theme unchanged.
- `unknownBubble`: same surface as assistant; explicit `fgPrimaryDynamic` text color.
- `toolBubble`: `bgSunkenDynamic` background, `Symbol.terminal`, JetBrains Mono output, `Radius.md` (14pt) to differentiate from chat bubbles' 18pt. Tool name is `Font.caption` semibold (was caption2 bold).
- `systemBubble`: `fgSecondaryDynamic` (was `.secondary`).
- Speaker button: `Symbol.speaker` constant.
- Timestamp: `Font.caption` + `fgTertiary` (was `caption2` + `.tertiary`). Uniform across all variants.
- Waiting badge: amber capsule (`honey200` background, `fgPrimaryDynamic` text). Pulse animation timing unchanged.
- Attachment chip: `Color.white.opacity(0.2)` background preserved (translucent overlay on honey surface, not a token), radius mapped to `Radius.xs` (6pt).
- Image attachment radius: `Radius.sm` (10pt).
- Link helpers `attributedText` / `wrapBareURLs` unchanged.

- [ ] **Step 2.2:** iOS build.

```bash
xcodebuild build -project Keepur.xcodeproj -scheme Keepur \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -quiet 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 2.3:** macOS build.

```bash
xcodebuild build -project Keepur.xcodeproj -scheme Keepur \
  -destination 'platform=macOS' \
  -quiet 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 2.4:** iOS unit tests.

```bash
set -o pipefail
xcodebuild test -project Keepur.xcodeproj -scheme Keepur \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:KeeperTests \
  -quiet > /tmp/dod-394-ios-test.log 2>&1
echo "EXIT=$?"
echo "passed: $(grep -c 'passed on' /tmp/dod-394-ios-test.log)"
echo "failed: $(grep -c 'failed on' /tmp/dod-394-ios-test.log)"
```

Expected: `EXIT=0`, `failed: 0`.

- [ ] **Step 2.5:** macOS unit tests.

```bash
set -o pipefail
xcodebuild test -project Keepur.xcodeproj -scheme Keepur \
  -destination 'platform=macOS' \
  -only-testing:KeeperTests \
  -quiet \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  > /tmp/dod-394-mac-test.log 2>&1
echo "EXIT=$?"
echo "passed: $(grep -c 'passed on' /tmp/dod-394-mac-test.log)"
echo "failed: $(grep -c 'failed on' /tmp/dod-394-mac-test.log)"
```

Expected: `EXIT=0`, `failed: 0`.

- [ ] **Step 2.6:** Commit.

```bash
git add Views/MessageBubble.swift
git commit -m "$(cat <<'EOF'
feat: migrate MessageBubble to KeepurTheme tokens (DOD-394)

The brand's marquee surface — every conversation paints with this.

Visible changes:
- User bubble: honey-500 fill, charcoal text (fgOnHoney), 18pt
  rounded corners with a 6pt bottom-trailing tail (matches the
  reference snippet at the bottom of KeepurTheme.swift)
- Assistant + unknown bubbles: bgSunkenDynamic surface (wax-100
  light, charcoal-tinted dark), 18pt radius, charcoal text
- Tool bubble: bgSunkenDynamic surface with terminal eyebrow,
  JetBrains Mono output at 12pt, 14pt radius — distinct from chat
  bubbles' 18pt to signal "this is code-like, not a message"
- System bubble: fgSecondaryDynamic centered text
- Timestamp: Font.caption (12pt) + fgTertiary, uniform across
  all variants (was caption2 + .tertiary)
- Speaker button on assistant bubble: Symbol.speaker constant
- Waiting badge: amber capsule (honey200 bg + charcoal text)
  instead of gray, semantic "in flight"; pulse animation unchanged
- Attachment chip on user bubble: white@20% overlay preserved
  (translucent on honey surface, not a token), Radius.xs corners
- Image attachment: Radius.sm (10pt) corners

No behavior changes. Tap selection, link detection (NSDataDetector
+ markdown wrapping), MarkdownTheme.keepur, pulse timing, onSpeak
optional callback, attachment shape detection, tool message parsing
all preserved.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Final regression sweep

- [ ] **Step 3.1:** Confirm clean tree and 2 commits ahead of main.

```bash
git status --short
git log --oneline main..HEAD
```

---

## After the plan

1. `/quality-gate`
2. `dodi-dev:review`
3. `dodi-dev:submit` — PR + cleanup, **no auto-merge**
