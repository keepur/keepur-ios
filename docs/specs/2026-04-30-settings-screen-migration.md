# Keepur iOS — Settings Screen Migration to Design System

**Date**: 2026-04-30
**Status**: Draft
**Ticket**: [DOD-392](https://linear.app/dodihome/issue/DOD-392/keepur-ios-migrate-settings-screen-to-keepurtheme-tokens)
**Parent epic**: [DOD-390](https://linear.app/dodihome/issue/DOD-390/keepur-ios-per-screen-migration-to-keepur-design-system)

## Problem

`Views/SettingsView.swift` (176 LOC) is a `NavigationStack { List }` with five sections (Device, Connection, Saved Workspaces, Voice, actions). Today it relies entirely on iOS's stock `List` chrome — system gray grouped background, uppercase section titles, blue accent on the voice checkmark, system green/red for the connection dot. None of it reads as Keepur.

This is the second per-screen migration after Pairing ([DOD-391](https://linear.app/dodihome/issue/DOD-391/keepur-ios-migrate-pairing-screen-to-keepurtheme-tokens)). Settings is where users land after pairing — visual consistency between the two surfaces sets the brand expectation for everything else.

## Scope

### In

1. Migrate every `Color.*`, `.font(...)`, and inline numeric value in `Views/SettingsView.swift` to `KeepurTheme.*` tokens.
2. Apply brand surfaces: wax page background, wax-surface row backgrounds, eyebrow-style section headers, JetBrains Mono for identifiers, semantic status dot colors, honey accent on the voice checkmark.
3. Visual diff is reviewable in simulator vs main; the ticket's acceptance criteria pass.

### Out

- Any data-flow change in `ChatViewModel`, `KeychainManager`, `SpeechManager`, or the workspace `@Query`.
- Restructuring sections, adding/removing settings, changing copy.
- Custom button styles for Disconnect/Reconnect/Unpair — those stay inline list buttons (they aren't full-width primary CTAs; they're row affordances). System `.destructive` role keeps Unpair semantically red.
- Unpair confirmation dialog — only the trigger button's visual.
- Dark-mode `NSColor` adapter for macOS `*Dynamic` aliases.

## Design Decisions

### D1. Wax page background and surface rows

iOS `List` defaults to `.systemGroupedBackground` (cool gray) for the page and `.systemBackground` (pure white) for rows. Replace both:

```swift
NavigationStack {
    List { ... }
        .scrollContentBackground(.hidden)
        .background(KeepurTheme.Color.bgPageDynamic)
}
```

For each row that needs a wax surface (everything except plain-text rows where the default `bgSurfaceDynamic` is fine):

```swift
.listRowBackground(KeepurTheme.Color.bgSurfaceDynamic)
```

Apply this to every section's rows so the row surfaces are consistent. The section spacers between are wax page background (visible because `scrollContentBackground` is hidden), giving the brand's softly-banded feel without explicit dividers.

### D2. Eyebrow section headers

Replace `Section("Device")` with explicit headers:

```swift
Section {
    rows
} header: {
    Text("DEVICE")
        .font(KeepurTheme.Font.eyebrow)
        .tracking(KeepurTheme.Font.lsEyebrow)
        .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
        .textCase(nil)
}
```

Notes:
- `textCase(nil)` overrides iOS's default automatic uppercasing — we already wrote the title in caps. Without this, iOS would re-uppercase already-uppercase strings (no-op visually but semantically wrong).
- `Font.eyebrow` is SF 12pt semibold; `lsEyebrow` is the matching `+0.96` (8% of 12pt) tracking value from the foundation.
- Apply to all five sections. Keep the existing copy ("Device", "Connection", "Saved Workspaces", "Voice") but write each in caps.

### D3. Identifier values (Device ID, Session ID, current workspace path)

Currently `font(.system(.caption, design: .monospaced))` — SF Mono. The foundation explicitly bundled JetBrains Mono for "code, file paths, device identifiers, log output." Switch:

```swift
Text(String(deviceId.prefix(8)))
    .font(.custom(KeepurTheme.FontName.mono, size: 12))
    .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
```

`mono` (Regular weight) at 12pt — matches caption's effective size, so vertical row rhythm is preserved while the typeface shifts to JetBrains Mono.

Three sites get this treatment:
- Device ID (8-char prefix) in the Device section.
- Session ID (8-char prefix) in the Connection section.
- Current `viewModel.currentPath` (workspace path) in the Connection section.

### D4. Connection status dot — semantic colors

`Color.green` / `Color.red` → `Color.success` / `Color.danger`. The dot stays 8×8pt, no ring, no shadow.

```swift
Circle()
    .fill(viewModel.ws.isConnected ? KeepurTheme.Color.success : KeepurTheme.Color.danger)
    .frame(width: 8, height: 8)
```

### D5. Voice row checkmark

The current `Image(systemName: "checkmark").foregroundStyle(.blue)` uses iOS's tint. Switch to honey, which is the brand's only accent and makes the selected voice scan immediately:

```swift
Image(systemName: KeepurTheme.Symbol.check)
    .foregroundStyle(KeepurTheme.Color.honey500)
```

`KeepurTheme.Symbol.check = "checkmark"` already exists in the foundation.

### D6. Row text colors and caption-tier text

Replace ad-hoc `.foregroundStyle(.secondary)` with `KeepurTheme.Color.fgSecondaryDynamic`. Replace implicit `.primary` (the default) with explicit `KeepurTheme.Color.fgPrimaryDynamic` on row labels — same color but token-derived.

Sites that take the secondary foreground:
- Status text ("Connected" / "Disconnected") in the Connection section.
- Voice quality label (Premium / Enhanced / Default) in each voice row.
- Saved-workspace path (the secondary line under each workspace's display name).
- Device name when no name is paired (the "Unknown" fallback).

Two `.font(.caption)` sites also flip to `KeepurTheme.Font.caption` for token consistency:
- Saved-workspace path (`workspace.path`) — currently `.font(.caption)`.
- Voice quality label — currently `.font(.caption)`.

`KeepurTheme.Font.caption` is SF 12pt medium — identical visual to the system `.caption` style at default settings; the swap is purely about deriving from tokens.

### D7. Buttons in list rows stay system-styled

Disconnect/Reconnect and Unpair are Button instances inside `Section { ... }`. iOS renders these as left-aligned text rows; the `.destructive` role on Unpair gives it the system red treatment. We don't extract a `KeepurDangerButtonStyle` for two reasons:

1. List row buttons aren't full-width primary CTAs — they're row affordances. Wrapping them in `KeepurPrimaryButtonStyle` (which applies `frame(maxWidth: .infinity)`, honey shadow, and full-width chrome) would distort the section's visual rhythm and conflict with iOS conventions.
2. The system `.destructive` role color is `Color.red` which iOS renders close enough to our `Color.danger` (`#C92A2A`) that the difference is negligible. YAGNI.

The Disconnect/Reconnect button stays default (renders as the list row's primary tint, which we intentionally don't override on this surface — reconnecting is an everyday action, not a CTA).

### D8. Toolbar Done button

`Button("Done") { dismiss() }` in the toolbar stays system-styled. Toolbar buttons follow iOS conventions (system tint); customizing them creates more visual noise than it removes. Honey accent on the toolbar would conflict with D5's voice checkmark — the screen should have at most one honey surface.

## File Layout (after this ticket)

```
Theme/
    KeepurTheme.swift                       (UNCHANGED)
    Components/
        PrimaryButton.swift                 (UNCHANGED)
Views/
    SettingsView.swift                      (REWRITTEN — same surface, new tokens, eyebrow headers, wax bg)
KeeperTests/                                (UNCHANGED — no SettingsView unit tests today)
```

No new files. No `KeepurDangerButtonStyle` — explicitly out of scope per D7.

## Implementation Outline

1. **Preconditions**: confirm `KeepurTheme.Color.success`, `Color.danger`, `Color.bgPageDynamic`, `Color.bgSurfaceDynamic`, `Color.fgSecondaryDynamic`, `Color.honey500`, `Font.eyebrow`, `Font.lsEyebrow`, `FontName.mono`, `Symbol.check` all resolve. Confirm `KeeperTests` doesn't reference SettingsView.

2. **Rewrite `Views/SettingsView.swift`**:
   - Add `.scrollContentBackground(.hidden).background(KeepurTheme.Color.bgPageDynamic)` to the `List`.
   - Replace each `Section("...")` with `Section { rows } header: { eyebrowHeader("...") }`. Extract a small private helper `eyebrowHeader(_ title: String) -> some View` to avoid copy-pasting the 4-line styling on every section.
   - Apply `.listRowBackground(KeepurTheme.Color.bgSurfaceDynamic)` consistently. (SwiftUI's `listRowBackground` modifier applies to the row it's attached to or the whole section if applied to the section's content.)
   - Per-row token swaps for fonts, colors, identifier mono, status dot.
   - Voice checkmark to honey.
   - All paddings (currently no inline numeric paddings beyond the dot's `frame(width: 8, height: 8)`) — leave the dot as-is (8pt is `Spacing.s2` already, but inline 8pt for a frame size is fine and doesn't add clarity from the token).

3. **Build for iOS and macOS**, run unit suite on both. No tests reference SettingsView; `KeepurThemeFontsTests` from foundation must still pass.

4. **Visual diff in simulator**: open Settings (gear icon from chat), verify wax page background, eyebrow headers, JetBrains Mono identifiers, green-honey-amber accents only on the right surfaces.

5. **Commit boundaries**:
   - Single commit: `feat: migrate Settings screen to KeepurTheme tokens (DOD-392)`. The whole rewrite is one logical change; no component extraction in this ticket.

## Risks & Open Questions

- **`scrollContentBackground` deprecation/availability**: this modifier ships in iOS 16+ and macOS 13+. Project min targets are iOS 26.2 / macOS 15. Safe.
- **Section header `textCase(nil)` interaction with system Dynamic Type**: at large accessibility text sizes, `Font.eyebrow` (12pt semibold) may render very small. Acceptable — it's a section title, not body content.
- **Visual contrast on the wax-surface row backgrounds**: `bgSurfaceDynamic` is white on light, charcoal-tinted on dark. Need to verify in simulator that the wax page bg / wax surface row bg / eyebrow header create enough visual separation. If rows blend into the page, fall back to a slightly stronger `bgBanded` on rows or keep system background. The plan's visual-diff step covers this.
- **No `KeepurDangerButtonStyle`**: leaves Unpair to system's `.destructive` red. If a future ticket wants Unpair to look distinctly Keepur-branded, that's a component extraction worth doing — but a list row button doesn't deserve the same chrome as the full-width Pairing CTA. Out of scope here, can be revisited.

## Follow-up

After this lands, the next migration ticket is likely Session List (recurring row pattern; nav chrome design needs settling for downstream Hive/Chat use).
