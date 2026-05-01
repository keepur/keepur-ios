# Keepur iOS — ToolApproval Migration to Design System

**Date**: 2026-04-30
**Status**: Draft
**Ticket**: [DOD-397](https://linear.app/dodihome/issue/DOD-397/keepur-ios-migrate-toolapprovalview-to-keepurtheme-tokens)
**Parent epic**: [DOD-390](https://linear.app/dodihome/issue/DOD-390/keepur-ios-per-screen-migration-to-keepur-design-system)

## Problem

`Views/ToolApprovalView.swift` (76 LOC) is a `.medium` sheet that appears when Claude requests permission to run a tool. Today: orange warning icon, system mono'd command on `tertiarySystemFill`, bordered Deny (red tint) + borderedProminent Approve (green tint), 60-second auto-deny countdown.

The chat surface is fully Keepur after DOD-394+395. The approval sheet is the last place where the app reverts to system blue/red/green during an active interaction.

## Scope

### In

1. Wax page background (sheet content), warning icon in `Color.warning`.
2. Eyebrow "TOOL" label above the command card.
3. Command card: JetBrains Mono body on `bgSunkenDynamic` with `Radius.md` (matches the chat tool bubble pattern from DOD-394 D3).
4. Approve button: `KeepurPrimaryButtonStyle` (honey, full-width).
5. Deny button: new `KeepurDestructiveButtonStyle` (sibling component, same shape with `Color.danger` background, `fgOnDark` text).
6. Heading "Approval Required" in `Font.h3`.
7. Countdown text in `Font.caption` + `fgSecondaryDynamic`.

### Out

- Behavior of approve/deny/auto-deny timer.
- `presentationDetents([.medium])` — system-controlled.
- 60-second timeout duration.
- Re-architecting the ChatViewModel.ToolApproval struct.

## Design Decisions

### D1. Warning icon

```swift
Image(systemName: "exclamationmark.shield.fill")
    .font(.system(size: 48))
    .foregroundStyle(KeepurTheme.Color.warning)
```

`Color.warning` (`#E0A200`) is the brand's amber warning tone — slightly more orange than `honey500` to read as "caution" not "primary action."

### D2. Heading

```swift
Text("Approval Required")
    .font(KeepurTheme.Font.h3)
    .tracking(KeepurTheme.Font.lsH3)
    .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
```

`Font.h3` is SF 22pt semibold — close to the original `.title2.bold()` (~22pt). `lsH3` (-0.22) gives the matching tracking.

### D3. Tool name + command card

```swift
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
```

Eyebrow "TOOL" + tool name on the same column as the command card. The command card matches the chat tool-bubble recipe (DOD-394 D3) — `Radius.md` (14pt) + `bgSunkenDynamic` + JetBrains Mono. Visually the user sees "the same kind of card as the chat's tool output" — consistent design language.

Mono size is 14pt — matches `Font.mono` (which is `Font.custom(JetBrainsMono-Regular, size: 14)`) and the chat tool-bubble recipe. Slightly tighter than the original system `.body` mono (17pt) — appropriate because the command sits inside a card with limited horizontal space and we don't want it to wrap unnecessarily.

### D4. Countdown text

```swift
Text("Auto-deny in \(remainingSeconds)s")
    .font(KeepurTheme.Font.caption)
    .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
```

### D5. Buttons

```swift
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
```

Both buttons full-width with brand chrome. `KeepurDestructiveButtonStyle` is added in this ticket (foundation expansion).

### D6. New component — `KeepurDestructiveButtonStyle`

Add to `Theme/Components/PrimaryButton.swift` (same file as primary; both are CTA recipes):

```swift
/// Danger-red destructive call-to-action with the same shape as
/// `KeepurPrimaryButtonStyle` but a red background. Used for irreversible
/// destructive actions where the user must consciously commit (Deny tool
/// approval, etc.). For inline destructive actions in lists, use
/// `Button(role: .destructive)` instead — that surface doesn't deserve the
/// full CTA chrome.
struct KeepurDestructiveButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(KeepurTheme.Font.button)
            .foregroundStyle(KeepurTheme.Color.fgOnDark)
            .frame(maxWidth: .infinity)
            .padding(.vertical, KeepurTheme.Spacing.s3)
            .background(
                KeepurTheme.Color.danger
                    .opacity(configuration.isPressed ? 0.85 : 1.0)
            )
            .clipShape(RoundedRectangle(cornerRadius: KeepurTheme.Radius.md))
            .opacity(isEnabled ? 1.0 : 0.4)
    }
}
```

Notes:
- Same shape parameters as `KeepurPrimaryButtonStyle` (max-width, s3 vertical padding, Radius.md, isPressed/isEnabled opacity logic).
- No shadow — the brand reserves the honey-tinted shadow for the primary CTA. A red shadow would feel aggressive and overstate the action.
- `fgOnDark` (= wax50, near-white with warm tint) for high contrast on the danger red.
- Lives next to `KeepurPrimaryButtonStyle` because they're tightly coupled in shape and intent. If the file grows past two styles, split it.

### D7. Outer layout

The original `VStack(spacing: 24)` with two `Spacer()`s above and below (one explicit, one implied by the shape). Retoken:

```swift
VStack(spacing: KeepurTheme.Spacing.s5) {
    Spacer()
    // icon, heading, tool card, countdown, buttons
    Spacer()
}
.frame(maxWidth: .infinity, maxHeight: .infinity)
.background(KeepurTheme.Color.bgPageDynamic)
```

`Spacing.s5` is 24pt — exact match for the original outer VStack spacing. Wax page background fills the sheet.

## File Layout (after this ticket)

```
Theme/Components/PrimaryButton.swift        (MODIFIED — add KeepurDestructiveButtonStyle)
Views/ToolApprovalView.swift                (REWRITTEN)
```

No new files.

## Implementation Outline

1. **Preconditions**: confirm `Color.warning`, `Color.danger`, `Color.fgPrimaryDynamic`, `Color.fgSecondaryDynamic`, `Color.fgOnDark`, `Color.bgPageDynamic`, `Color.bgSunkenDynamic`, `Font.h3`, `Font.lsH3`, `Font.bodySm`, `Font.caption`, `Font.eyebrow`, `Font.lsEyebrow`, `Font.button`, `FontName.mono`, `Spacing.s2`, `Spacing.s3`, `Spacing.s4`, `Spacing.s5`, `Radius.md`. Confirm `KeepurPrimaryButtonStyle` is in `Theme/Components/PrimaryButton.swift`. Confirm no `ToolApprovalView` test references.

2. **Add `KeepurDestructiveButtonStyle`** to `Theme/Components/PrimaryButton.swift`.

3. **Rewrite `Views/ToolApprovalView.swift`** end-to-end per D1-D7. Same surface, same behavior. Preserve:
   - 60-second countdown via `Timer.publish(every: 1, ...)` + `.onReceive(timer)` decrement
   - Auto-deny when `remainingSeconds == 0`
   - `onApprove` / `onDeny` closure wiring
   - `presentationDetents([.medium])` modifier

4. **Build for iOS and macOS, run unit suite on both**. Existing tests pass.

5. **Visual diff in simulator** — trigger a tool approval (any non-allowlisted command in chat). Verify: warm warning icon, JetBrains Mono command on wax-100 card, honey Approve, danger-red Deny, both full-width.

6. **Single commit**: `feat: migrate ToolApprovalView to KeepurTheme tokens (DOD-397)`. Atomic — the new button style and its first consumer ship together.

## Risks & Open Questions

- **`KeepurDestructiveButtonStyle` is a new foundation primitive**: its API mirrors `KeepurPrimaryButtonStyle` exactly except for the background color. If we later want a tertiary button (`KeepurSecondaryButtonStyle` for "outline" CTAs), the pattern generalizes. Considered extracting a parameterized `KeepurButtonStyle(tint:)` but rejected — the component-per-intent pattern is clearer at call sites.
- **No shadow on the destructive button**: deliberate brand call. If it feels too flat in simulator, a subtle non-honey shadow could be added in a follow-up.
- **Button colors in `HStack`**: both buttons use `frame(maxWidth: .infinity)` — they distribute equally. No layout regression vs the original (which also used `Text("...").frame(maxWidth: .infinity)` inside both labels).

## Follow-up

After this lands: **Hive (Team) views** (`Views/Team/`) — the largest remaining migration. Multiple files. Final ticket of the epic.
