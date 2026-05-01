# Keepur iOS — Session List Migration to Design System

**Date**: 2026-04-30
**Status**: Draft
**Ticket**: [DOD-393](https://linear.app/dodihome/issue/DOD-393/keepur-ios-migrate-session-list-to-keepurtheme-tokens)
**Parent epic**: [DOD-390](https://linear.app/dodihome/issue/DOD-390/keepur-ios-per-screen-migration-to-keepur-design-system)

## Problem

`Views/SessionListView.swift` (342 LOC) is the app's home screen on iOS — `NavigationStack { sessionList }` with toolbar and an empty-state CTA. macOS uses `NavigationSplitView` with the same sidebar list. The inline `SessionRow` struct renders avatar + name + path + last-message preview + relative time + status badges; today every color is `Color.green` / `Color.orange` / `Color.accentColor` and every font is `.body` / `.caption`. The expiry warning banner uses `Color.orange.opacity(0.1)`.

This is the third per-screen migration. Patterns established here propagate directly to **Hive (Team) views** (which use the same row design language) and partially to **Chat session pickers**. Getting the row recipe right matters for the rest of the epic.

## Scope

### In

1. Migrate every `Color.*`, `.font(...)`, and inline numeric in `SessionListView.swift` (including the inline `SessionRow`) to `KeepurTheme.*` tokens.
2. Apply brand surfaces: wax page bg, redesigned avatar, semantic badges, JetBrains Mono session paths, honey-tinted expiry banner, honey CTA on empty state.
3. **Foundation expansion**: add `KeepurTheme.Symbol.compose = "square.and.pencil"` to `Theme/KeepurTheme.swift` so the new-session toolbar icon doesn't ship a call-site string. Per-screen migrations are the natural driver of foundation token additions; this is expected and intentional.

### Out

- Data-flow / state-machine changes in `ChatViewModel`, `Session` SwiftData model, or session navigation.
- macOS `NavigationSplitView` chrome customization beyond the sidebar list itself.
- Re-architecting `SessionRow` to live in its own file (deferred until Hive views need to share it).
- Dark-mode `NSColor` adapter.
- `Session.isStale` opacity treatment (already at `0.5`; semantic, fine).

## Design Decisions

### D1. List style and page background

Keep `.listStyle(.plain)`. Add `.scrollContentBackground(.hidden).background(KeepurTheme.Color.bgPageDynamic)` to the `List` so the wax page bg shows through between rows. No `.listRowBackground` per-row — `.plain` style already renders rows directly on the page bg, which is what we want here (Settings used `.listRowBackground` because grouped style needs explicit row tone).

### D2. Expiry warning banner

Currently `.foregroundStyle(.orange)` icon + `.subheadline.weight(.medium)` text + `Color.orange.opacity(0.1)` row background. Replace:

```swift
Button {
    showSettings = true
} label: {
    HStack(spacing: KeepurTheme.Spacing.s2) {
        Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(KeepurTheme.Color.warning)
        Text(daysRemaining == 0
            ? "Device pairing expires today"
            : daysRemaining == 1
                ? "Device pairing expires in 1 day"
                : "Device pairing expires in \(daysRemaining) days")
            .font(KeepurTheme.Font.bodySm)
            .fontWeight(.medium)
            .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, KeepurTheme.Spacing.s1)
}
.listRowBackground(KeepurTheme.Color.honey100)
```

`Color.honey100` is the brand's tinted-warning surface (a light amber wash, distinct from system orange). The icon stays `Color.warning` for the hard semantic ("this is a warning"). Text stays primary foreground for readability against the tinted bg.

### D3. SessionRow avatar

Today: 44pt circle, green when active (`isActive`), accent at 15% opacity otherwise; with `bolt.fill` (active) or `bubble.left.fill` (inactive) icon.

The current "active = green, inactive = blue tint" pattern reads as a status indicator, but it conflates two ideas (selection state and connection state). The brand recipe is: **honey is the accent for selected/active surfaces** and **wax is the surface for everything else**.

```swift
Circle()
    .fill(isActive ? KeepurTheme.Color.honey500 : KeepurTheme.Color.honey100)
    .frame(width: 44, height: 44)
    .overlay {
        Image(systemName: isActive ? KeepurTheme.Symbol.bolt : "bubble.left.fill")
            .foregroundStyle(isActive ? KeepurTheme.Color.fgOnHoney : KeepurTheme.Color.honey700)
    }
```

- Active: honey-500 fill, charcoal bolt — reads as "this is the live one."
- Inactive: honey-100 fill, honey-700 chat bubble — clearly grouped as "session row" without competing with the active state.
- Icon for the inactive state stays `bubble.left.fill` literal; foundation's `Symbol.chat = "bubble.left.and.bubble.right"` is a different, fuller icon shape and we don't want to change the avatar geometry. Acceptable inline-string exception (the icon is intrinsic to row layout, not a brand-level icon).

### D4. Active and Stale badges

Capsule pills next to the session name, today using `Color.green.opacity(0.2)` / `Color.orange.opacity(0.2)` background with green/orange text. Migrate to semantic colors:

```swift
private func semanticBadge(_ text: String, tint: Color) -> some View {
    Text(text)
        .font(KeepurTheme.Font.caption)
        .padding(.horizontal, KeepurTheme.Spacing.s2)
        .padding(.vertical, 2)
        .background(tint.opacity(0.15))
        .clipShape(Capsule())
        .foregroundStyle(tint)
}

// Active badge:
semanticBadge("Active", tint: KeepurTheme.Color.success)
// Stale badge:
semanticBadge("Stale", tint: KeepurTheme.Color.warning)
```

Note: `Font.caption` is 12pt medium per the foundation. The original used `caption2` (11pt) — bumping to 12pt for legibility; the badges are small and need to scan. If 12pt feels too large at iPhone width during visual diff, fall back to `.font(.caption2)` (system font, since foundation has no `caption2` token).

The opacity changes from 0.2 to 0.15 to soften the pills slightly — semantic colors at 0.15 read as "tinted" rather than "filled." Visual judgement, may need adjustment in simulator.

### D5. Session path uses JetBrains Mono

`Text(session.path)` shows the workspace path (e.g. `~/code/keepur/hive`). Today it's `.font(.caption)` SF. The foundation explicitly bundled JetBrains Mono for "file paths" — switch:

```swift
Text(session.path)
    .font(.custom(KeepurTheme.FontName.mono, size: 12))
    .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
    .lineLimit(1)
```

Same pattern as Settings' Device ID / Session ID / Workspace path treatment (DOD-392 D3).

### D6. Other text rows

- `session.displayName` — `KeepurTheme.Font.body` + `.fontWeight(.medium)` + `KeepurTheme.Color.fgPrimaryDynamic`.
- Last message preview — `KeepurTheme.Font.bodySm` + `KeepurTheme.Color.fgSecondaryDynamic`. (Was `.subheadline` ≈ 15pt; `bodySm` is 14pt — close enough, derives from token vocabulary.)
- Relative time — `KeepurTheme.Font.caption` + `KeepurTheme.Color.fgTertiary`. (Was `.foregroundStyle(.tertiary)`; `Color.fgTertiary` is the wax-500 token equivalent — slightly different shade but token-derived.)

### D7. Toolbar status dot

`Color.green` / `Color.red` → `KeepurTheme.Color.success` / `KeepurTheme.Color.danger`. Same as Settings D4. The dot stays 8×8pt.

### D8. Toolbar buttons (gear, new-session)

```swift
ToolbarItem(placement: .automatic) {
    Button { showSettings = true } label: {
        Image(systemName: KeepurTheme.Symbol.settings)
            .font(.title3)
    }
}
ToolbarItem(placement: .primaryAction) {
    Button { showWorkspacePicker = true } label: {
        Image(systemName: KeepurTheme.Symbol.compose)
            .font(.title3)
    }
}
```

`Symbol.settings = "gearshape"` already exists. **`Symbol.compose = "square.and.pencil"` is new — added to `Theme/KeepurTheme.swift` as part of this ticket.** Toolbar buttons stay system-tinted (we don't override accent on toolbar items — that's an iOS convention; `Color.tintColor` defaults to the system tint).

### D9. Empty state CTA

```swift
ContentUnavailableView {
    Label("No Sessions", systemImage: "bubble.left.and.bubble.right")
} description: {
    Text("Start a new session to chat with Claude Code")
} actions: {
    Button("New Session") { showWorkspacePicker = true }
        .buttonStyle(KeepurPrimaryButtonStyle())
        .padding(.horizontal, KeepurTheme.Spacing.s7)
}
```

The empty-state CTA is the first reuse of `KeepurPrimaryButtonStyle` outside Pairing — the component-extraction call from DOD-391 D2 pays off here. The horizontal padding constrains the full-width style to a sensible width inside `ContentUnavailableView`'s actions slot.

### D10. Foundation expansion

Add to `Theme/KeepurTheme.swift`:

```swift
public static let compose     = "square.and.pencil"
```

inside `KeepurTheme.Symbol`, alphabetically after `chat` and before `chevronBack`. One-line addition; preserves the foundation's "audit-able icon set" property.

## File Layout (after this ticket)

```
Theme/
    KeepurTheme.swift                       (MODIFIED — add Symbol.compose)
    Components/
        PrimaryButton.swift                 (UNCHANGED)
Views/
    SessionListView.swift                   (REWRITTEN)
KeeperTests/                                (UNCHANGED)
```

No new files, no `project.pbxproj` edits.

## Implementation Outline

1. **Preconditions**: confirm tokens used resolve in `Theme/KeepurTheme.swift`. The new `Symbol.compose` is added, not preconditioned. Verify no `SessionListView` test references.

2. **Add `Symbol.compose`** to `Theme/KeepurTheme.swift` (one line).

3. **Rewrite `Views/SessionListView.swift`** end-to-end per D1-D9. Same surface, same behavior. Both `iOSBody` and `macOSBody` get the wax page bg. Same `SessionRow` struct (now retokened).

4. **Build for iOS and macOS, run unit suite on both.** Existing tests must pass (no `SessionListView` tests on `main`; `KeepurThemeFontsTests` from foundation must still pass).

5. **Visual diff in simulator** — open the app post-pairing, look at the home screen. Tick:
   - Wax page bg behind list rows
   - Redesigned avatar reads correctly (honey-500 for active, honey-100 for inactive)
   - Active/Stale badges in semantic colors
   - Session path in JetBrains Mono
   - Connection dot uses success/danger
   - Empty state CTA is full-width honey button (test by clearing all sessions)
   - Expiry banner (only triggers within 7 days of token expiry — not testable in normal dev unless you mock `tokenExpiryDate`)

6. **Commit boundaries**:
   - C1: `feat: add Symbol.compose to KeepurTheme (DOD-393)` — one-line foundation addition
   - C2: `feat: migrate Session List to KeepurTheme tokens (DOD-393)` — main rewrite

## Risks & Open Questions

- **Avatar redesign is a visible change beyond pure retoken**: the active-color shift from green to honey, and the icon-color rationalization, are deliberate brand decisions but the user may expect a more "literal" port. Mitigation: simulator visual diff + PR description calls this out explicitly.
- **Badge sizing**: `Font.caption` (12pt medium) vs old `caption2` (11pt). May feel large; spec D4 has a fallback to inline `.font(.caption2)`.
- **Expiry banner is hard to visually verify**: only triggers near token expiry. The PR will need to call this out as "code review only" for that surface.
- **`SessionRow` extraction deferred**: when Hive views land their own row design, we'll likely want to extract a shared `KeepurAvatarRow` component. Not in scope here. The token names chosen here (honey-500 active / honey-100 inactive) generalize cleanly.

## Follow-up

Once this lands, **Chat** is the natural next migration (`MessageBubble` + `MessageInputBar` together). Chat's avatar treatment will reuse this ticket's recipe.
