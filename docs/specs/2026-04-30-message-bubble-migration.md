# Keepur iOS — MessageBubble Migration to Design System

**Date**: 2026-04-30
**Status**: Draft
**Ticket**: [DOD-394](https://linear.app/dodihome/issue/DOD-394/keepur-ios-migrate-messagebubble-to-keepurtheme-tokens)
**Parent epic**: [DOD-390](https://linear.app/dodihome/issue/DOD-390/keepur-ios-per-screen-migration-to-keepur-design-system)

## Problem

`Views/MessageBubble.swift` (236 LOC, 5 bubble variants: user, assistant, tool, system, unknown) is the brand's single most-visible surface — every conversation paints with it. Today the user bubble is `Color.accentColor` (system blue on iOS), assistant bubble is `Color.secondarySystemFill`, and tool bubble is `Color.tertiarySystemFill`. The honey accent never appears.

This migration is where the brand finally shows up. The user bubble's recipe is even spelled out in the bottom of `Theme/KeepurTheme.swift` as a "Reference snippet" — honey-500 fill, charcoal text, 18pt radius with 6pt tail. Today nothing consumes it.

## Scope

### In

1. Migrate every `Color.*`, `.font(...)`, inline padding, and corner radius across all 5 bubble variants to `KeepurTheme.*` tokens.
2. Apply brand surfaces:
   - User bubble → honey-500 + charcoal text + 18pt radius with 6pt tail (per the reference snippet).
   - Assistant bubble → wax surface, 18pt radius, charcoal text.
   - Tool bubble → wax sunken card with terminal eyebrow and JetBrains Mono output.
   - System / unknown bubbles → token-derived secondary text + bubble surface.
   - Waiting badge → semantic warning capsule.
   - Attachment chip on user bubbles → wax-tinted chip overlaid on the honey surface.
3. Tap-targets, gestures, link detection, and markdown rendering all preserved.

### Out

- `MessageInputBar` and `ChatView` chrome (DOD-395).
- `MarkdownTheme.keepur` — already brand-tuned at foundation time.
- The link-detection helpers (`attributedText`, `wrapBareURLs`) — pure logic.
- Bubble behavior (waiting badge animation timing, speak callback wiring, attachment shape detection).

## Design Decisions

### D1. User bubble — the marquee surface

The reference snippet at the bottom of `KeepurTheme.swift` defines this exactly:

```swift
Text(message)
    .font(KeepurTheme.Font.body)
    .foregroundStyle(KeepurTheme.Color.fgOnHoney)
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(KeepurTheme.Color.honey500)
    .clipShape(.rect(
        topLeadingRadius:     KeepurTheme.Radius.lg,
        bottomLeadingRadius:  KeepurTheme.Radius.lg,
        bottomTrailingRadius: 6,
        topTrailingRadius:    KeepurTheme.Radius.lg
    ))
```

`Radius.lg` is 18pt; the asymmetric 6pt bottom-trailing tail visually points to the user side and matches the kit mock. We adopt this verbatim. The 14pt horizontal padding stays inline (not derived from `Spacing.s4 = 16` because the kit's chip-tighter feel uses 14 — same 14pt the foundation snippet documents).

The vertical 10pt padding maps to `Spacing.s3 - Spacing.s1` if we wanted to derive it, but inline 10pt is clearer and stable. (Keep inline for both 14 and 10.)

### D2. Assistant bubble

```swift
Markdown(message.text)
    .markdownTheme(.keepur)
    .textSelection(.enabled)
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(
        RoundedRectangle(cornerRadius: KeepurTheme.Radius.lg)
            .fill(KeepurTheme.Color.bgSunkenDynamic)
    )
```

`bgSunkenDynamic` is `wax100` light / `#17110C` dark. Slightly darker than the assistant's surrounding page bg (`bgPageDynamic` = `wax0`), so the bubble reads as a distinct soft surface without a hard border. The 18pt radius matches the user bubble's primary corners — symmetric (no tail) since assistants are leading-aligned.

`MarkdownTheme.keepur` is unchanged; its colors/fonts already flow through token-equivalent values per foundation work.

### D3. Tool bubble

The tool bubble shows command output and file paths — JetBrains Mono is the right typeface (foundation explicitly bundled it for this). Recipe:

```swift
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
```

- Card uses `Radius.md` (14pt) — distinguishable from chat bubbles' `Radius.lg` (18pt). Tool output is "code-like," not a message — different shape signals the difference.
- Output uses `JetBrainsMono-Regular` at 12pt; charcoal text on wax-100 ground for max readability.
- Eyebrow row (terminal icon + tool name) uses `Font.caption` semibold + secondary fg.
- `Symbol.terminal = "terminal.fill"` already exists in foundation.

### D4. System bubble (centered text)

```swift
Text(message.text)
    .font(KeepurTheme.Font.caption)
    .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
    .textSelection(.enabled)
    .padding(.vertical, KeepurTheme.Spacing.s2)
```

System messages are inline notices ("Session cleared", etc.) — no bubble shape, just centered secondary text. Already minimal; just retoken.

### D5. Unknown bubble

Currently shows a "Unsupported message" caption above a generic bubble. Same recipe as assistant bubble for the body, with a leading caption above:

```swift
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
```

### D6. Timestamp

Every bubble has a small time stamp below it. Currently `.caption2` + `.foregroundStyle(.tertiary)`. Replace with the foundation token:

```swift
Text(message.timestamp, style: .time)
    .font(KeepurTheme.Font.caption)
    .foregroundStyle(KeepurTheme.Color.fgTertiary)
```

`Font.caption` is 12pt — slightly larger than `caption2` (11pt) but more readable. `fgTertiary` is `wax500` — close to but token-derived from `.tertiary`.

### D7. Speaker button (assistant bubble)

```swift
Button { onSpeak(message.text) } label: {
    Image(systemName: KeepurTheme.Symbol.speaker)
        .font(KeepurTheme.Font.caption)
        .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
}
```

`Symbol.speaker = "speaker.wave.2"` already exists in foundation. Color flows from secondary token.

### D8. Waiting badge (user bubble overlay)

Currently a gray `Color.secondary` capsule with white text saying "waiting". Brand recipe: amber tinted capsule with charcoal text — semantic warning that doesn't compete with the user bubble's honey surface.

```swift
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
```

`honey200` is a slightly darker amber than the bubble's `honey500`-on-charcoal — readable as "still in flight, waiting on response." Charcoal text for contrast. Pulsing animation behavior unchanged.

### D9. Attachment chip on user bubble

When a non-image attachment ships with a user message, a small filename chip appears inside the bubble. Currently `Color.white.opacity(0.2)` background. With honey-500 as the bubble surface, white@20% reads correctly as a translucent highlight; no clean token swap. Keep the opacity-on-white treatment but derive the radius from tokens:

```swift
HStack(spacing: KeepurTheme.Spacing.s1) {
    Image(systemName: "doc.fill")
        .font(KeepurTheme.Font.caption)
    Text(message.attachmentName ?? "Attachment")
        .font(KeepurTheme.Font.caption)
        .lineLimit(1)
}
.padding(.horizontal, KeepurTheme.Spacing.s2 + 2)  // 10pt
.padding(.vertical, 6)
.background(Color.white.opacity(0.2))
.clipShape(RoundedRectangle(cornerRadius: KeepurTheme.Radius.xs))
```

Acceptable inline-color exception: the `Color.white.opacity(0.2)` is intentionally a translucent overlay on the honey surface, not a token-level surface color. Same justification as the digit-cell tap exception in the Pairing migration (DOD-391 D3) — when an inline color encodes a relationship to a parent surface, no token captures it.

### D10. Image attachment radius

Image attachments inside the user bubble use `cornerRadius: 12` today. Map to `KeepurTheme.Radius.sm` (10pt) — close enough to feel similar, derives from tokens. The 200pt max height stays inline (geometric constraint, not a brand value).

## File Layout (after this ticket)

```
Views/MessageBubble.swift                   (REWRITTEN)
```

That's it. No new files, no foundation expansion, no project.pbxproj edits.

## Implementation Outline

1. **Preconditions**: confirm tokens used resolve. Specifically need `Color.honey500`, `Color.honey200`, `Color.fgOnHoney`, `Color.bgSunkenDynamic`, `Color.fgPrimaryDynamic`, `Color.fgSecondaryDynamic`, `Color.fgTertiary`, `Font.body`, `Font.caption`, `FontName.mono`, `Symbol.terminal`, `Symbol.speaker`, `Radius.xs`, `Radius.sm`, `Radius.md`, `Radius.lg`, `Spacing.s1`, `Spacing.s2`, `Spacing.s3`. Confirm no `MessageBubble` references in `KeeperTests`.

2. **Rewrite `Views/MessageBubble.swift`** end-to-end per D1–D10. Same surface, same behavior. Preserve:
   - `attributedText` and `wrapBareURLs` static helpers (unchanged)
   - Markdown rendering via `markdownTheme(.keepur)`
   - Pulse animation on waiting badge
   - `onSpeak` optional callback wiring
   - Attachment shape detection (image vs file)
   - Tool bubble's `parts.split` parsing for `[toolName]\noutput` format
   - All `textSelection(.enabled)` modifiers (long-press to copy)
   - `Spacer(minLength: 60)` constraints on alignment

3. **Build for iOS and macOS, run unit suite on both.** No `MessageBubble` tests exist; `KeepurThemeFontsTests` from foundation must still pass.

4. **Visual diff in simulator** — open a chat, send a user message (should be honey amber), watch a Claude reply (should be wax surface), trigger a tool call (should be JetBrains Mono in a wax-100 card). The user bubble is the most visible change in the entire migration epic so far.

5. **Single commit**: `feat: migrate MessageBubble to KeepurTheme tokens (DOD-394)`.

## Risks & Open Questions

- **`bgSunkenDynamic` for assistant bubble vs page bg**: assistant bubble uses `bgSunkenDynamic` (wax100 = `#F1EADA` light), page bg from DOD-393 inherits `bgPageDynamic` (wax0 = `#FFFDF8` light). Difference is 14 RGB units on red channel — visible as a soft surface vs page contrast on iPhone. Should read OK; if it doesn't, fall back to `bgBanded` (`wax50`).
- **User bubble's asymmetric tail**: SwiftUI's `clipShape(.rect(topLeadingRadius:...))` is iOS 16+ / macOS 13+. Project min targets are iOS 26.2 / macOS 15. Safe.
- **Markdown theme already brand-tuned**: this means the assistant bubble's text colors don't visibly change (they're already charcoal-ish). The brand reads through the *bubble surface*, not the markdown text. Acceptable.
- **Waiting badge color shift**: gray → amber is a deliberate brand decision. If the original was meant to feel "neutral / passive," this reads as "warm / in-flight." Both interpretations are valid; the kit's preview leans warm.

## Follow-up

After this lands, **DOD-395** (MessageInputBar + ChatView chrome) is the next ticket. Together they complete the chat surface.
