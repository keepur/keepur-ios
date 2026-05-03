# KPR-149 — design v2: Settings card-grouped sections

**Date:** 2026-05-02
**Epic:** [KPR-142 design v2](https://linear.app/keepur/issue/KPR-142)
**Layer:** 3 (per-screen consumption)
**Depends on:** KPR-145 (foundation data display — `KeepurCard`), KPR-147 (TabBar root, optional — `SettingsView` lands as a tab destination but works fine inside its existing sheet host too)

## Problem

`SettingsView` today uses `List` with grouped `Section { ... }` blocks, each with an eyebrow header and rows that paint their own `listRowBackground`. The result reads as a stock iOS Settings clone with our tokens bolted on — the wax surface tone is correct but the grouping mechanic is iOS's, not ours. The design v2 mockups call for our own card vocabulary: an eyebrow header sitting above a freestanding rounded wax card with a 1px border, content padded inside the card. The same mockups also surface three small affordance fixes layered on top: status text colored by semantic ("Connected" in `Color.success`), Saved Workspaces row gets a chevron (becomes a navigation destination shell), and the Voice rows extend their tap target to the full row.

## Solution

Replace `List` + `Section` with `ScrollView` + `LazyVStack` of eyebrow header / `KeepurCard` pairs. Each former section becomes one card; row content moves inside the `KeepurCard`'s `@ViewBuilder` closure as a `VStack` with `Divider`s between rows (using `KeepurTheme.Color.borderDefaultDynamic`). Three small content tweaks land in the same pass: semantic-colored status text on the Connection card, chevron + `NavigationLink` shell on the Saved Workspaces row, and full-row tap target on Voice rows via `Button` with `.contentShape(Rectangle())`.

The `Saved Workspaces` navigation destination itself is a deliberately empty placeholder view (`Text("Coming soon")` inside a `KeepurCard`) — actual detail content is explicitly out of scope per backlog. The destination existing makes the chevron honest.

## Key Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Container | `ScrollView` + `LazyVStack(spacing: s5)` | `List` fights the card grouping (built-in section insets + dividers + own background); a manual stack gives us full control over header/card spacing and frees us from `listRowBackground` clutter |
| Card border | `bordered: true` for every card | Backlog spec is unambiguous: "1px border". `KeepurCard(bordered: true)` is the existing knob |
| Row separators inside cards | `Divider().background(KeepurTheme.Color.borderDefaultDynamic)` | Matches the wax-200 hairline used elsewhere; native `Divider` already inherits `.foregroundStyle` correctly |
| Row internal spacing | `Spacing.s3` (12pt) vertical between rows | Matches existing list row vertical breathing room visually after losing built-in list row insets |
| Card outer horizontal padding | `Spacing.s4` (16pt) on the `LazyVStack` | Mirrors existing `List` form margins; cards still feel inset from page edge |
| Eyebrow header position | Outside the card, leading-aligned, `Spacing.s2` below previous card and `Spacing.s2` above its card | Existing eyebrow style preserved verbatim — same `Font.eyebrow` + `lsEyebrow` + `fgSecondaryDynamic` + `textCase(nil)` |
| Header padding | `Spacing.s4` horizontal so eyebrow aligns with card edge | Visual alignment of caps with card body looks intentional |
| Status text color | `Color.success` when connected, `Color.danger` when disconnected | Backlog spec is explicit: "Connected" in `Color.success`. Mirroring with danger when disconnected is the obvious symmetric move (and matches the existing dot color logic — the dot already uses these tokens) |
| Status dot | Keep as-is | Already uses `Color.success` / `Color.danger`; the change is upgrading the *text* to match the dot |
| Saved Workspaces row → destination | `NavigationLink { SavedWorkspacesView() } label: { … }` | Chevron comes free with `NavigationLink`; needs a `NavigationStack` host (already present in `SettingsView`); destination is intentionally a placeholder per scope |
| Saved Workspaces destination content | `Text("Coming soon").font(.body).foregroundStyle(.fgSecondaryDynamic)` inside a `KeepurCard` | Backlog: "Out of scope: Saved Workspaces detail content." Honest empty state, matches existing convention |
| Saved Workspaces card surface | One row per saved workspace, NavigationLink wraps each row, swipe-to-delete dropped | Swipe-to-delete is a `List`-only affordance; deletion moves to the destination view as a future ticket. Backlog calls "detail content" out of scope, which implicitly defers the delete UI |
| Voice row tap target | `Button { … } label: { HStack { … } }.buttonStyle(.plain).contentShape(Rectangle())` | Existing button only fires on label hit area; `.contentShape(Rectangle())` on the row container makes the whole row width tappable. `.buttonStyle(.plain)` prevents iOS's default tinting from overriding our text colors |
| Voice row check icon | Keep `KeepurTheme.Color.honey500` checkmark | Already correct |
| Footer (Disconnect / Unpair) | Keep as a card — but no eyebrow above it | Last section had no header in original; preserve that. Buttons render as inline `Button`s with their existing roles intact (`.destructive` on Unpair drives standard danger tinting); confirmationDialog wiring unchanged |
| Background | `KeepurTheme.Color.bgPageDynamic` on the outer scroll | Same as today; cards float on the page wax tone, picking up the bordered wax surface contrast |

## Layout Structure

```
NavigationStack
└── ScrollView
    └── LazyVStack(spacing: s5, alignment: .leading)
        ├── eyebrowHeader("DEVICE")            // existing helper, unchanged
        ├── KeepurCard(bordered: true) {
        │     VStack(spacing: 0) {
        │       deviceNameRow
        │       Divider()
        │       deviceIdRow                     // conditional on KeychainManager.deviceId
        │     }
        │   }
        ├── eyebrowHeader("CONNECTION")
        ├── KeepurCard(bordered: true) {
        │     VStack(spacing: 0) {
        │       statusRow                       // text colored by isConnected
        │       Divider()
        │       sessionRow                      // conditional
        │       Divider()                       // gated by sessionRow presence
        │       workspaceRow                    // conditional
        │     }
        │   }
        ├── eyebrowHeader("SAVED WORKSPACES")  // entire group conditional on !savedWorkspaces.isEmpty
        ├── KeepurCard(bordered: true) {
        │     VStack(spacing: 0) {
        │       ForEach(savedWorkspaces) { workspace in
        │         NavigationLink { SavedWorkspacesPlaceholderView() } label: {
        │           workspaceRow(workspace)     // existing label content + chevron from NavigationLink
        │         }
        │         .buttonStyle(.plain)
        │         if workspace != savedWorkspaces.last { Divider() }
        │       }
        │     }
        │   }
        ├── eyebrowHeader("VOICE")
        ├── KeepurCard(bordered: true) {
        │     VStack(spacing: 0) {
        │       ForEach(englishVoices) { voice in
        │         voiceRow(voice)               // full-row tap target
        │         if voice != englishVoices.last { Divider() }
        │       }
        │     }
        │   }
        └── KeepurCard(bordered: true) {        // footer; no eyebrow
              VStack(spacing: 0) {
                disconnectReconnectButton
                Divider()
                unpairButton
              }
            }
```

## Detailed Row Specs

### Status row (Connection card)

```swift
HStack {
    Text("Status").foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
    Spacer()
    HStack(spacing: 6) {
        Circle()
            .fill(viewModel.ws.isConnected ? KeepurTheme.Color.success : KeepurTheme.Color.danger)
            .frame(width: 8, height: 8)
        Text(viewModel.ws.isConnected ? "Connected" : "Disconnected")
            .foregroundStyle(viewModel.ws.isConnected ? KeepurTheme.Color.success : KeepurTheme.Color.danger)
    }
}
.padding(.vertical, KeepurTheme.Spacing.s3)
```

The only change vs. today: text foreground was `fgSecondaryDynamic`; it becomes the matching semantic color. The dot stays the same. Vertical padding compensates for the lost `List` row insets.

### Saved Workspaces row

`NavigationLink` wraps the existing `VStack(displayName, path)` content. SwiftUI inserts the trailing chevron automatically when a `NavigationLink` lives inside a `NavigationStack`. `.buttonStyle(.plain)` prevents the entire row text from going honey-tinted.

Destination view (new in this ticket, deliberately minimal):

```swift
struct SavedWorkspacesPlaceholderView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: KeepurTheme.Spacing.s5) {
                KeepurCard(bordered: true) {
                    Text("Saved workspace details coming soon.")
                        .font(KeepurTheme.Font.body)
                        .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                }
            }
            .padding(KeepurTheme.Spacing.s4)
        }
        .background(KeepurTheme.Color.bgPageDynamic)
        .navigationTitle("Saved Workspaces")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
```

This view lives inside `SettingsView.swift` as a private struct (or sibling type in the same file) — no new file required, no project wiring.

### Voice row (full-row tap target)

```swift
Button {
    viewModel.speechManager.selectedVoiceId = voice.identifier
    viewModel.speechManager.speak("Hello, I'm " + voice.name + ".")
} label: {
    HStack {
        VStack(alignment: .leading, spacing: 2) {
            Text(voice.name).font(.body).foregroundStyle(.fgPrimaryDynamic)
            Text(qualityLabel(voice.quality)).font(.caption).foregroundStyle(.fgSecondaryDynamic)
        }
        Spacer()
        if viewModel.speechManager.selectedVoiceId == voice.identifier {
            Image(systemName: KeepurTheme.Symbol.check).foregroundStyle(KeepurTheme.Color.honey500)
        }
    }
    .padding(.vertical, KeepurTheme.Spacing.s3)
    .contentShape(Rectangle())
}
.buttonStyle(.plain)
```

The `.contentShape(Rectangle())` on the label content + `.buttonStyle(.plain)` is the canonical SwiftUI recipe for "full-row hit target without tinting".

### Footer card (Disconnect / Unpair)

Both buttons stay as today, including the `.destructive` role on Unpair and the `.confirmationDialog` modifier. Each gets `.padding(.vertical, KeepurTheme.Spacing.s3)` and `.frame(maxWidth: .infinity, alignment: .leading)` to behave properly inside the card. Keep `.confirmationDialog` attached to the Unpair button so its presentation anchor stays correct.

## Out of Scope

- Saved Workspaces detail content (placeholder destination only — separate future ticket).
- Restructuring Settings to "global settings" semantics (admin URL, user, device name as primary content) — separate ticket per backlog.
- Swipe-to-delete on Saved Workspaces — moves to the destination view when its own ticket lands. Drop from this surface in this ticket since `LazyVStack` doesn't have native swipe affordances and we don't want to ship a custom one for placeholder content.
- Done button toolbar — kept exactly as today (still required because Settings can be presented as a sheet from the chat surface today; Tab landing in KPR-147 doesn't remove sheet entry points).
- TabBar wiring — done by KPR-147; this ticket's view works in either context (sheet or tab).
- Dark-mode polish — covered by existing `*Dynamic` tokens; no new color decisions needed.

## Smoke Test Scope

Per CLAUDE.md constraint: "Don't smoke-test View bodies depending on @StateObject/Keychain — crashes in test env." `SettingsView` reads from `KeychainManager.deviceName` and `KeychainManager.deviceId` directly in its body and accesses `viewModel.ws.isConnected`. Direct body instantiation is therefore fragile.

Test scope is narrow and intentional:

| Component | Test cases |
|---|---|
| `SavedWorkspacesPlaceholderView` | Instantiate body — pure view with no external deps; verifies the placeholder destination compiles and renders without crash |

`SettingsView` itself is **not** smoke-tested. The visual changes are verified by build success + manual scan of the diff against the spec.

## Files Touched

- `Views/SettingsView.swift` (modified — replace `List` + `Section` with `ScrollView` + `LazyVStack` + `KeepurCard` pattern; add three content tweaks; add `SavedWorkspacesPlaceholderView` private struct in same file)
- `KeeperTests/SavedWorkspacesPlaceholderViewTests.swift` (new — single instantiation smoke test)
- `Keepur.xcodeproj/project.pbxproj` (wire only the new test file; `Views/` is a synchronized folder group)

## Dependencies / Sequencing

- **Blocks:** none directly; this is a leaf per-screen ticket
- **Blocked by:** KPR-145 (`KeepurCard` must exist on the epic branch)
- **Plays nicely with:** KPR-147 (TabBar root) — landing order doesn't matter; `SettingsView` works as both sheet content and tab content unchanged
- Can run in parallel with all other Layer 3 per-screen tickets

## Open Questions

None. Backlog scope is unambiguous, `KeepurCard` API is final, and the three content tweaks (semantic status color, chevron destination, full-row voice tap) each have a single obvious implementation.

## Human Signoff

Pre-approved per durable user delegation (KPR-142 design v2 epic — mockups already approve component intent; user explicit: "as long as it more or less looks like the mockup, I don't care beyond that"). Recorded in epic-orchestrator memory.
