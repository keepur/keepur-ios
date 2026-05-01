# Keepur iOS — WorkspacePicker Migration to Design System

**Date**: 2026-04-30
**Status**: Draft
**Ticket**: [DOD-396](https://linear.app/dodihome/issue/DOD-396/keepur-ios-migrate-workspacepicker-to-keepurtheme-tokens)
**Parent epic**: [DOD-390](https://linear.app/dodihome/issue/DOD-390/keepur-ios-per-screen-migration-to-keepur-design-system)

## Problem

`Views/WorkspacePickerView.swift` (177 LOC) is the modal sheet that opens when starting a new session. NavigationStack + List with three sections (Recent Workspaces, Browse, Session History), `ContentUnavailableView`s for disconnected/error states, `.borderedProminent` Reconnect/Retry CTAs. Today every color is `.secondary`/`.primary`/`Color.green`/`Color.blue`/`.tertiarySystemFill`. Now that Settings (DOD-392) and Session List (DOD-393) have set the wax+eyebrow+JetBrains-Mono+honey-CTA precedent, this picker is the obvious next conformity target.

## Scope

### In

1. Wax page background + eyebrow section headers + wax-surface row backgrounds (matches DOD-392 D1/D2).
2. Folder paths in JetBrains Mono — current browse path (when not loading), workspace paths in Recent (already system caption today).
3. `ContentUnavailableView` Reconnect/Retry CTAs use `KeepurPrimaryButtonStyle` with `.padding(.horizontal, KeepurTheme.Spacing.s7)` (same as DOD-393 D9 empty-state CTA).
4. Folder icons (browse listing) use `Color.honey700` instead of `.blue`.
5. Session History Active bubble icon uses `Color.success`; "Active" capsule pill uses semantic-tinted style identical to `SessionRow.semanticBadge` from DOD-393 D4.
6. Browse current-path row uses `bgSunkenDynamic` (was `tertiarySystemFill`).
7. Ancestor "..", folder-open recents, message-bubble session icons, error/disconnected icons all flip to token-derived foregrounds.

### Out

- Toolbar `Cancel` / `Start Session Here` — system-styled toolbar buttons stay (consistent with Settings D8).
- Behavior of any action (`viewModel.newSession`, `browse`, `resumeSession`, browse state machine).
- Re-architecting the NavigationStack or List structure.
- Dark-mode `NSColor` adapter for macOS.

## Design Decisions

### D1. Page background and section headers

```swift
NavigationStack {
    List { ... }
        .scrollContentBackground(.hidden)
        .background(KeepurTheme.Color.bgPageDynamic)
}
```

Same `eyebrowHeader(_ title: String)` private helper as Settings (DOD-392 D2):

```swift
private func eyebrowHeader(_ title: String) -> some View {
    Text(title)
        .font(KeepurTheme.Font.eyebrow)
        .tracking(KeepurTheme.Font.lsEyebrow)
        .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
        .textCase(nil)
}
```

Replace `Section("Recent Workspaces") { ... }` with `Section { rows } header: { eyebrowHeader("RECENT WORKSPACES") }` for all three sections.

### D2. Recent workspaces rows

Existing structure: `Image(systemName: "clock.arrow.circlepath")` + name + path-as-caption. Retoken:

```swift
Image(systemName: "clock.arrow.circlepath")
    .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
VStack(alignment: .leading) {
    Text(workspace.displayName)
        .font(KeepurTheme.Font.body)
        .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
    Text(workspace.path)
        .font(.custom(KeepurTheme.FontName.mono, size: 12))
        .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
}
```

Path in JetBrains Mono — same recipe as Settings D3 (Device ID, Session ID, workspace path).

`clock.arrow.circlepath` kept inline — it's the iOS-native recents icon, not a brand symbol.

Rows get `.listRowBackground(KeepurTheme.Color.bgSurfaceDynamic)`.

### D3. Browse — connected state

The "current path" row (when browse is loaded):

```swift
HStack {
    Image(systemName: "folder.fill")
        .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
    Text(viewModel.browsePath)
        .font(.custom(KeepurTheme.FontName.mono, size: 12))
        .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
}
.listRowBackground(KeepurTheme.Color.bgSunkenDynamic)
```

Sunken row — visually pushed back to feel like a "you are here" header, not a clickable entry. Changed from `tertiarySystemFill` to `bgSunkenDynamic` (slightly warmer wax-100).

The ".." parent row stays a Button — `arrow.up.doc` icon foreground in `fgSecondaryDynamic`, label text in `fgPrimaryDynamic`:

```swift
Button { /* navigate up */ } label: {
    HStack {
        Image(systemName: "arrow.up.doc")
            .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
        Text("..")
            .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
    }
}
```

Folder entries — the `.blue` folder color flips to honey-700 (warm brown — reads as folder, doesn't compete with the honey-500 accent):

```swift
HStack {
    Image(systemName: "folder")
        .foregroundStyle(KeepurTheme.Color.honey700)
    Text(entry.name)
        .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
}
```

Both rows get `.listRowBackground(KeepurTheme.Color.bgSurfaceDynamic)`.

### D4. Browse — disconnected / error / loading states

`ContentUnavailableView` for disconnected: keep system styling for the `Label`+description, but the action button uses `KeepurPrimaryButtonStyle`:

```swift
Button("Reconnect") {
    viewModel.browseError = nil
    viewModel.ws.connect()
    viewModel.browse()
}
.buttonStyle(KeepurPrimaryButtonStyle())
.padding(.horizontal, KeepurTheme.Spacing.s7)
```

Same pattern for the Retry button in the error state. Same horizontal padding constraint from DOD-393 D9.

`ProgressView("Loading…")` stays default — system spinner is fine, no token replacement makes sense.

### D5. Session History rows

Existing: bubble icon green when active, gray otherwise; preview text (`subheadline`) + relative time (`caption` secondary); inline Active capsule pill with green tint.

Retoken:

```swift
Image(systemName: ws.active ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right")
    .foregroundStyle(ws.active ? KeepurTheme.Color.success : KeepurTheme.Color.fgSecondaryDynamic)

VStack(alignment: .leading, spacing: 2) {
    Text(ws.preview)
        .font(KeepurTheme.Font.bodySm)
        .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
        .lineLimit(2)
    Text(ws.lastActiveAt, style: .relative)
        .font(KeepurTheme.Font.caption)
        .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
}
Spacer()
if ws.active {
    semanticBadge("Active", tint: KeepurTheme.Color.success)
}
```

`semanticBadge(_ text: String, tint: Color)` is the same private helper from `SessionRow` (DOD-393 D4). Inlined into `WorkspacePickerView` as a private func — when a third caller appears (likely Hive), extract to `Theme/Components/`.

Rows get `.listRowBackground(KeepurTheme.Color.bgSurfaceDynamic)`.

### D6. Outer Button .foregroundStyle removal

Today the recent-row and history-row Buttons end with `.foregroundStyle(.primary)` to override SwiftUI's button-tinting of their inner content. With explicit per-Text foregrounds set, that outer modifier is redundant — drop it (consistent with DOD-392's voice row treatment).

## File Layout (after this ticket)

```
Views/WorkspacePickerView.swift             (REWRITTEN)
```

No new files, no foundation expansion.

## Implementation Outline

1. **Preconditions**: confirm tokens used resolve (`Color.honey700`, `Color.success`, `Color.fgPrimaryDynamic`, `Color.fgSecondaryDynamic`, `Color.bgPageDynamic`, `Color.bgSurfaceDynamic`, `Color.bgSunkenDynamic`, `Font.body`, `Font.bodySm`, `Font.caption`, `Font.eyebrow`, `Font.lsEyebrow`, `FontName.mono`, `Spacing.s7`). `KeepurPrimaryButtonStyle` exists in `Theme/Components/`. No WorkspacePicker test references.

2. **Behavior preservation checklist** — these must round-trip from the current view to the rewrite (none are styling; callout reduces regression risk):
   - `recentWorkspaces.prefix(5)` cap on the recents section.
   - Empty-section gates `if !recentWorkspaces.isEmpty` and `if !viewModel.workspaceSessions.isEmpty`.
   - Browse state machine: `!ws.isConnected` → disconnected CTA; `browseError != nil` → error CTA; `browsePath.isEmpty` → loading; otherwise → current-path + `..` (gated by `isHome`) + folder entries filtered to `.isDirectory`.
   - Path-join ternary for `/` / trailing-slash / default cases when navigating into a subfolder.
   - Session-history active branch: `currentSessionId = ws.sessionId` + `currentPath = viewModel.browsePath`. Inactive branch: `resumeSession(sessionId:path:)`. Both `dismiss()` after.
   - Toolbar `Cancel` and `Start Session Here`. `Start Session Here` keeps `.disabled(viewModel.browsePath.isEmpty)`.
   - `.onAppear`: reset `browsePath`, `browseEntries`, `browseError`, `workspaceSessions`, then call `browse()`.
   - iOS-only `.navigationBarTitleDisplayMode(.inline)`.
   - `isHome` computed property unchanged.

3. **Rewrite `Views/WorkspacePickerView.swift`** end-to-end per D1–D6. Same NavigationStack + List + toolbar structure. Same browse state machine (per checklist above). Eyebrow header helper + semanticBadge helper as private funcs.

4. **Build for iOS and macOS, run unit suite on both.** Existing tests pass (no WorkspacePicker tests).

5. **Visual diff in simulator** — tap `+` on Sessions to open the picker. Verify: wax page, eyebrow headers, JetBrains Mono workspace paths, honey folder icons, honey Reconnect/Retry CTAs (force disconnect by airplane mode + Reconnect), semantic Active capsule + green bubble icon on active sessions.

6. **Single commit**: `feat: migrate WorkspacePicker to KeepurTheme tokens (DOD-396)`.

## Risks & Open Questions

- **Folder icons in honey-700 vs blue**: blue is the iOS folder convention. Switching to honey-700 (warm brown) is a deliberate brand call — folders feel "wax/woody" instead of "system blue." If it reads as muddy or low-contrast, fall back to `fgPrimaryDynamic` (charcoal) for plain-folder icons and reserve honey for the recent workspaces' clock icon (which is more distinctly "Keepur memory").
- **Browse current-path uses `bgSunkenDynamic` vs `bgSurfaceDynamic`**: aiming for slight visual recession. If on iPhone the difference is invisible (wax-100 vs white), the row might look identical to surrounding entries — fall back to bolder treatment in a follow-up. Acceptable for this PR.
- **No `Workspace.swift` model changes**: SwiftData query / sorting unchanged.

## Follow-up

After this lands, two migrations remain: Tool approval (small, ~76 LOC) and Hive views (largest — multiple files). Tool approval is the natural next step.
