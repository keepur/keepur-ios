# Keepur iOS — Chat Chrome Migration to Design System

**Date**: 2026-04-30
**Status**: Draft
**Ticket**: [DOD-395](https://linear.app/dodihome/issue/DOD-395/keepur-ios-migrate-chatview-messageinputbar-voicebutton-to-keepurtheme)
**Parent epic**: [DOD-390](https://linear.app/dodihome/issue/DOD-390/keepur-ios-per-screen-migration-to-keepur-design-system)

## Problem

[DOD-394](https://linear.app/dodihome/issue/DOD-394/keepur-ios-migrate-messagebubble-to-keepurtheme-tokens) migrated `MessageBubble` — every conversation now paints with honey user bubbles and wax assistant surfaces. But the surrounding chrome (toolbar buttons, status indicator, message input bar, voice button) is still default iOS blue and gray. The chat surface mid-flight reads as half-branded: honey bubbles inside a stock iOS chrome.

This ticket completes the chat surface by retoken'ing all three remaining files: `ChatView.swift` (toolbar + read-only bar + StatusIndicator), `MessageInputBar.swift` (send + attachment + input field), and `VoiceButton.swift` (mic).

## Scope

### In

1. Migrate every `Color.*`, `.font(...)`, and inline numeric in the three files to `KeepurTheme.*` tokens.
2. Apply brand surfaces:
   - Send button → honey (enabled) / muted gray (disabled)
   - Voice button idle → honey
   - Voice button recording → danger red
   - Status indicator card → wax sunken surface
   - Toolbar speaker button → semantic colors per state
   - Read-only bar → token caption text
   - Input field → pill radius, retokened paddings
   - Attachment chip preview → wax surface
3. All behaviors preserved verbatim.

### Out

- `ultraThinMaterial` background on the input bar — keeps iOS-native blur, no token replacement makes sense.
- `ToolApprovalView` — its own ticket.
- Any state machine, recording, attachment, send, sheet, or alert behavior.
- `Markdown` / link helpers (`MessageBubble`'s territory).

## Design Decisions

### D1. Send button (MessageInputBar)

Currently `Image(systemName: "arrow.up.circle.fill")` at 32pt, tinted via `sendButtonColor` computed prop returning `Color.accentColor` / `Color.gray.opacity(0.3)`.

```swift
Button { onSend() } label: {
    Image(systemName: KeepurTheme.Symbol.send)
        .font(.system(size: 32))
        .foregroundStyle(canSend ? KeepurTheme.Color.honey500 : KeepurTheme.Color.fgMuted)
}
.disabled(!canSend)
```

`Symbol.send = "arrow.up.circle.fill"` already exists in foundation. `Color.fgMuted` = `wax400`, the right tone for a disabled affordance against a wax/material surface.

Inline `Color sendButtonColor` computed prop is dropped — its single use site moves inline since the ternary is now small.

### D2. Attachment + button (MessageInputBar)

Currently `Image(systemName: "plus.circle.fill")` 26pt, `.secondary`.

```swift
Button { showAttachmentOptions = true } label: {
    Image(systemName: KeepurTheme.Symbol.plus)
        .font(.system(size: 26))
        .foregroundStyle(KeepurTheme.Color.fgMuted)
}
```

`Symbol.plus = "plus.circle.fill"` already exists. `fgMuted` (`wax400`) is closer to system `.secondary`'s perceived weight than `fgSecondaryDynamic` (`wax700`), and matches D1's disabled-send treatment for consistency on the input bar's chrome.

### D3. Input field

Currently:

```swift
TextField("Message...", text: $messageText, axis: .vertical)
    .textFieldStyle(.plain)
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(
        RoundedRectangle(cornerRadius: 20)
            .fill(.ultraThinMaterial)
    )
```

Retoken paddings and radius. Use `KeepurTheme.Radius.pill` (999) for a true capsule shape — visually distinct from the bubble's 18pt and matches the kit's input mock from the iOS UI kit:

```swift
TextField("Message...", text: $messageText, axis: .vertical)
    .textFieldStyle(.plain)
    .font(KeepurTheme.Font.body)
    .padding(.horizontal, KeepurTheme.Spacing.s3)
    .padding(.vertical, KeepurTheme.Spacing.s2)
    .background(
        RoundedRectangle(cornerRadius: KeepurTheme.Radius.pill)
            .fill(.ultraThinMaterial)
    )
    .lineLimit(1...6)
    .onSubmit { onSend() }
```

`ultraThinMaterial` retained — it's the iOS-native input-bar treatment. Replacing it with a flat wax color would break the floating-over-content feel.

### D4. Attachment preview (MessageInputBar)

Currently `Color.secondarySystemFill` background, 12pt radius. Retoken to wax surface + token radius:

```swift
HStack {
    // ... image / doc icon ...
    Text(name)
        .font(KeepurTheme.Font.caption)
        .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
        .lineLimit(1)
    Spacer()
    Button { pendingAttachment = nil } label: {
        Image(systemName: "xmark.circle.fill")
            .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
    }
}
.padding(.horizontal, KeepurTheme.Spacing.s3)
.padding(.vertical, KeepurTheme.Spacing.s1 + 2)  // 6pt
.background(RoundedRectangle(cornerRadius: KeepurTheme.Radius.sm).fill(KeepurTheme.Color.bgSunkenDynamic))
.padding(.horizontal, KeepurTheme.Spacing.s1)
```

`Symbol.xmark = "xmark"` exists in foundation but the previous code used `xmark.circle.fill` (a different glyph: filled circle with X). We keep the filled circle inline as the standard "remove" affordance — promoting it to a foundation symbol isn't worth it for one use site, and consistency with `StatusIndicator`'s cancel button (D8, also `xmark.circle.fill` inline) matters more than token purity.

The 6pt vertical padding as `Spacing.s1 + 2` is acceptable — `s1` (4pt) is too tight, `s2` (8pt) is too loose; 6pt lands between. Same documentation pattern as MessageBubble D9 attachment chip.

### D5. Popover menu (attachment options)

The popover contains "Choose File" / "Photo Library" labels with system Label styles. Keep system Label (icon + text); retoken the wrapper paddings:

```swift
.padding(.horizontal, KeepurTheme.Spacing.s4)
.padding(.vertical, KeepurTheme.Spacing.s2 + 2)  // 10pt
```

Inside the popover we don't override text colors — system Label inherits the popover's tint, which is appropriate for menu items.

### D6. Voice button (VoiceButton.swift)

Currently 44pt circle, recording state = `Color.red` filled with white stop icon, idle = `Color.accentColor` mic when modelReady, gray otherwise.

```swift
ZStack {
    if speechManager.isRecording {
        Circle()
            .fill(KeepurTheme.Color.danger)
            .frame(width: 44, height: 44)
        Image(systemName: "stop.fill")
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(KeepurTheme.Color.fgOnDark)
    } else {
        Image(systemName: KeepurTheme.Symbol.mic)
            .font(.title2)
            .foregroundStyle(speechManager.modelReady ? KeepurTheme.Color.honey500 : KeepurTheme.Color.fgMuted)
            .frame(width: 44, height: 44)
    }
}
```

`Symbol.mic = "mic.fill"` exists. `fgOnDark = wax50` — high-contrast text on the danger circle background. `Color.fgMuted = wax400` for the not-ready state.

`stop.fill` is a small icon literal not worth promoting to a foundation symbol — only used in this one recording state.

### D7. Status indicator card (ChatView's StatusIndicator)

Currently:

```swift
.padding(.horizontal, 16)
.padding(.vertical, 12)
.background(
    RoundedRectangle(cornerRadius: 18)
        .fill(Color.secondarySystemFill)
)
```

Retoken to match the assistant bubble's surface (DOD-394 D2):

```swift
.padding(.horizontal, KeepurTheme.Spacing.s4)
.padding(.vertical, KeepurTheme.Spacing.s3)
.background(
    RoundedRectangle(cornerRadius: KeepurTheme.Radius.lg)
        .fill(KeepurTheme.Color.bgSunkenDynamic)
)
```

Same surface and radius as assistant message bubbles — visually grouping the indicator as "Claude is doing something" content.

### D8. Status indicator content

Three states: thinking (animated dots), busy (clock icon), tool running (hammer icon).

```swift
// Thinking dots
Circle()
    .fill(KeepurTheme.Color.fgSecondaryDynamic)
    .frame(width: 8, height: 8)

// Busy / tool icons + labels
Image(systemName: "clock")  // or "hammer.fill"
    .font(KeepurTheme.Font.caption)
    .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
Text("Server busy...")  // or "Running \(toolName ?? "tool")..."
    .font(KeepurTheme.Font.caption)
    .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)

// Cancel button
Image(systemName: "xmark.circle.fill")
    .font(KeepurTheme.Font.caption)
    .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
```

`clock`, `hammer.fill`, `xmark.circle.fill` are all kept as inline strings — they're status-specific icons, not brand-level surfaces. The animation timing (0.6s easeInOut repeatForever, phase = π) is unchanged.

### D9. Toolbar speaker button (ChatView)

Three states with different colors today: `.red` when speaking, `Color.accentColor` when auto-read on, `Color.secondary` when off.

```swift
Button {
    if viewModel.speechManager.isSpeaking {
        viewModel.speechManager.stopSpeaking()
    } else {
        autoReadAloud.toggle()
    }
} label: {
    Image(systemName: viewModel.speechManager.isSpeaking ? "stop.circle.fill"
          : autoReadAloud ? "speaker.wave.2.fill" : "speaker.slash")
        .font(KeepurTheme.Font.bodySm)
}
.foregroundStyle(
    viewModel.speechManager.isSpeaking ? KeepurTheme.Color.danger
    : autoReadAloud ? KeepurTheme.Color.honey500
    : KeepurTheme.Color.fgSecondaryDynamic
)
```

The icon variants (`stop.circle.fill`, `speaker.wave.2.fill`, `speaker.slash`) are status-specific — kept inline. The `.font(.subheadline)` was approximately 15pt — `Font.bodySm` is 14pt; close enough.

Toolbar gear icon stays `Symbol.settings`.

### D10. Read-only bar (ChatView)

```swift
private var readOnlyBar: some View {
    HStack {
        Spacer()
        Text("Session ended — read only")
            .font(KeepurTheme.Font.caption)
            .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
        Spacer()
    }
    .padding(.vertical, KeepurTheme.Spacing.s3)
    .background(.ultraThinMaterial)
}
```

`ultraThinMaterial` retained for the same reason as the input bar.

### D11. ChatView LazyVStack and outer padding

```swift
LazyVStack(spacing: KeepurTheme.Spacing.s3) {
    // ...
}
.padding(.horizontal, KeepurTheme.Spacing.s4)
.padding(.vertical, KeepurTheme.Spacing.s3)
```

Inline 12 / 16 / 12 → `Spacing.s3 / s4 / s3` (12 / 16 / 12). Token-derived; same numerics.

## File Layout (after this ticket)

```
Views/ChatView.swift            (REWRITTEN — toolbar, read-only bar, StatusIndicator)
Views/MessageInputBar.swift     (REWRITTEN)
Views/VoiceButton.swift         (REWRITTEN)
```

No new files, no foundation expansion, no project.pbxproj edits.

## Implementation Outline

1. **Preconditions**: confirm tokens used resolve. Specifically need `Color.honey500`, `Color.fgMuted`, `Color.fgSecondaryDynamic`, `Color.fgOnDark`, `Color.danger`, `Color.bgSunkenDynamic`, `Font.body`, `Font.bodySm`, `Font.caption`, `Spacing.s1`, `Spacing.s2`, `Spacing.s3`, `Spacing.s4`, `Radius.sm`, `Radius.lg`, `Radius.pill`, `Symbol.send`, `Symbol.plus`, `Symbol.mic`. Confirm no ChatView/InputBar/VoiceButton tests reference layout.

2. **Rewrite all three files** end-to-end per D1–D11. Same surface, same behavior.

3. **Build for iOS and macOS, run unit suite on both**. Existing tests must pass.

4. **Visual diff in simulator** — open a chat, type a message (send button is honey when text is present, muted when empty), tap mic (recording state = danger red circle), trigger thinking/tool/busy state (status card uses wax surface, same as assistant bubbles), navigate to a stale session (read-only bar uses caption + wax-700 text).

5. **Single commit**: `feat: migrate ChatView, MessageInputBar, VoiceButton to KeepurTheme tokens (DOD-395)`. The three files together complete the chat-screen surface; their changes are visually tightly coupled.

## Risks & Open Questions

- **`Radius.pill` (999) on the input field** — the current 20pt is mid-rounded but not a full capsule. The kit's input mock uses pill radius. Visual change is real; mitigation is the simulator visual diff.
- **Voice button recording uses `Color.danger`** — the kit doesn't explicitly cover recording state. `danger` is the brand semantic for "stop / harmful action," appropriate for recording state given it auto-completes / sends voice on stop.
- **Send button at 32pt may look outsized against the new pill input** — geometric ratio unchanged, but the contrast (honey-on-blur vs honey-on-flat) might affect perceived size. If too dominant, reduce to 28pt in a follow-up.
- **`fgOnDark` for the recording stop icon** — `wax50 = #FAF6EC`. White-ish but slightly warm. Should read as "stop" against the danger red circle.

## Follow-up

After this lands, the chat surface is fully Keepur. Remaining migrations: Workspace picker, Tool approval, Hive (Team) views.
