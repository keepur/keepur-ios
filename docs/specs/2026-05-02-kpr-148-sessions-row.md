# KPR-148 — Sessions row + list redesign

**Date:** 2026-05-02
**Epic:** [KPR-142 design v2](https://linear.app/keepur/issue/KPR-142)
**Layer:** 3 (per-screen consumption)
**Depends on:** KPR-144 (foundation atoms — `KeepurStatusPill`)

## Problem

Today's `SessionRow` (in `Views/SessionListView.swift` lines 256-327) leads with a 44pt circular avatar (honey-tinted with bubble/bolt SF Symbol), then stacks name + path + preview, with a relative timestamp trailing. The mockups for design v2 strip the avatar entirely — sessions are textual records, not "people," and the leading circle adds visual weight without identity payload. The row also has its own ad-hoc `semanticBadge` helper that pre-dates `KeepurStatusPill` and renders a hand-rolled capsule with `.font(KeepurTheme.Font.caption)` + 2pt vertical padding (subtly different from the foundation pill's `s1`/`s2` padding and lack of `.medium` weight).

The list itself uses `.listStyle(.plain)` already (good), but the row's leading-icon footprint pushes content right and makes the row feel heavier than mockups intend. Mockups call for a flatter, denser, more text-forward row.

## Solution

Surgical edit to `SessionRow` only:

1. **Drop the leading `Circle()` icon entirely.** Row is now text-only.
2. **Replace `semanticBadge(...)` calls with `KeepurStatusPill`** for "Active" and "Stale" inline tags. Delete the obsolete `semanticBadge` helper.
3. **Keep the existing path-in-mono and preview-line affordances** — they already match mockup intent.
4. **Keep the trailing relative timestamp at `KeepurTheme.Color.fgTertiary`** — already correct.
5. **Add a subtle row divider** below each row content so the list reads as a clean stack rather than relying on `List`'s default separator. This is achieved by adding `Divider().background(KeepurTheme.Color.borderSubtle)` at the bottom of the row body and hiding the system separator via `.listRowSeparator(.hidden)`. Row stays inset (default `List` insets); we don't go full-bleed grouped.

No changes to `SessionListView` itself, the toolbar, the warning banner row, or sheet/alert wiring. No model/VM changes. No changes elsewhere in the app.

## Key Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Avatar | Removed entirely | Backlog explicit: "Drop the 44pt circular avatar — sessions row no longer has a leading icon" |
| Status pill source | `KeepurStatusPill` (KPR-144) | Foundation atom exists; consolidates pill styling |
| Active tint | `.success` | Matches existing semantic ("connected/active = green") and the foundation pill maps `.success` to `KeepurTheme.Color.success` (the same color the old badge used) |
| Stale tint | `.warning` | Same — foundation pill `.warning` resolves to the same `KeepurTheme.Color.warning` the old badge used |
| Active + Stale precedence | Render both pills if both true (Active first, then Stale) | Same as today; row already conditionally appends both. Mutually-exclusive collapse is a domain decision out of scope |
| Name weight | `.medium` (unchanged) | Backlog says "body weight" — `KeepurTheme.Font.body` is already body tier; existing `.fontWeight(.medium)` matches the mockup's slightly-heavier-than-regular session name treatment. Reading "body weight" as "regular weight" would actively de-emphasize the name vs the path/preview, contrary to mockup hierarchy |
| Path font | `.custom(KeepurTheme.FontName.mono, size: 12)` (unchanged) | Backlog: "JetBrains Mono caption" — already correct |
| Preview line | Unchanged | Backlog: "if present" — already conditional on `lastMessagePreview` being non-nil |
| Timestamp tone | `KeepurTheme.Color.fgTertiary` (unchanged) | Backlog: "tertiary tone" — already correct |
| Divider style | `Divider()` tinted with `borderSubtle`, system separator hidden | "Cleaner divider" reads as: replace List's default 0.5pt grey separator (which inherits inset behavior we don't fully control) with an explicit subtle border. Keeps insets; doesn't go full-bleed |
| Stale opacity | Keep `.opacity(0.5)` modifier on the row at the call site | Already applied in `SessionListView` line 50; not part of `SessionRow`'s responsibility |
| Tap targets / swipe / context menu | Unchanged | Out of scope; backlog doesn't touch interaction model |
| Active row chevron / lead indicator | None | Backlog dropped the icon entirely; the "Active" status pill is the active affordance |

## Visual Spec

### Row layout (top-to-bottom inside the row)

```
┌───────────────────────────────────────────────────────────┐
│  HStack(spacing: s3, alignment: .top)                     │
│  ┌─────────────────────────────────────────┐  ┌────────┐  │
│  │ VStack(alignment: .leading, spacing: s1)│  │ time   │  │
│  │   HStack(spacing: s2)                   │  │ caption│  │
│  │     "Session name" body / .medium       │  │ tert.  │  │
│  │     [Active pill] [Stale pill]          │  └────────┘  │
│  │   "/path/to/workspace" mono 12 secondary             │  │
│  │   "Last message preview..." bodySm secondary         │  │
│  └─────────────────────────────────────────┘             │
│  Divider (borderSubtle)                                  │
└───────────────────────────────────────────────────────────┘
```

- **Outer HStack:** `spacing: KeepurTheme.Spacing.s3`, `alignment: .top` (so timestamp aligns with the first text line, not the vertical center which would drift down on rows with both path + preview)
- **Inner VStack:** `alignment: .leading`, `spacing: KeepurTheme.Spacing.s1`
- **Title row HStack:** `spacing: KeepurTheme.Spacing.s2` between name and pills, between pills
- **Vertical row padding:** `KeepurTheme.Spacing.s1` (unchanged from today)
- **Divider:** placed inside the row's outermost `VStack` wrapper (added below the existing `HStack`), `Divider().background(KeepurTheme.Color.borderSubtle)`
- **List separator:** suppressed via `.listRowSeparator(.hidden)` applied at the call site in `SessionListView`'s `ForEach`
- **List style:** unchanged — `.listStyle(.plain)` with `scrollContentBackground(.hidden)` and `bgPageDynamic` background

### Component usage

```swift
if isActive {
    KeepurStatusPill("Active", tint: .success)
}
if session.isStale {
    KeepurStatusPill("Stale", tint: .warning)
}
```

Replaces today's:

```swift
if isActive {
    semanticBadge("Active", tint: KeepurTheme.Color.success)
}
if session.isStale {
    semanticBadge("Stale", tint: KeepurTheme.Color.warning)
}
```

Then **delete the `private func semanticBadge(...)` helper** (lines 307-315 in the current file).

### Token map

| Element | Token |
|---|---|
| Row outer HStack spacing | `KeepurTheme.Spacing.s3` (12pt) |
| Row vertical padding | `KeepurTheme.Spacing.s1` (4pt) |
| Inner VStack spacing | `KeepurTheme.Spacing.s1` (4pt) |
| Title HStack spacing | `KeepurTheme.Spacing.s2` (8pt) |
| Name font / weight | `KeepurTheme.Font.body` / `.medium` |
| Name color | `KeepurTheme.Color.fgPrimaryDynamic` |
| Path font | `.custom(KeepurTheme.FontName.mono, size: 12)` |
| Path color | `KeepurTheme.Color.fgSecondaryDynamic` |
| Preview font | `KeepurTheme.Font.bodySm` |
| Preview color | `KeepurTheme.Color.fgSecondaryDynamic` |
| Timestamp font | `KeepurTheme.Font.caption` |
| Timestamp color | `KeepurTheme.Color.fgTertiary` |
| Divider color | `KeepurTheme.Color.borderSubtle` |
| Active pill | `KeepurStatusPill("Active", tint: .success)` |
| Stale pill | `KeepurStatusPill("Stale", tint: .warning)` |

All tokens above are confirmed present in `Theme/KeepurTheme.swift` (verified by direct read).

### Edge cases

- **Both Active and Stale true:** both pills render side by side in the title HStack. Order: Active before Stale (matches conditional order in code).
- **Long session name + both pills:** name has no `lineLimit` today; if the title HStack overflows, SwiftUI's default truncation behavior applies. Acceptable — preserving today's behavior.
- **No preview available (`lastMessagePreview == nil`):** preview line absent. Row collapses to name + path. Already correct.
- **Path is very long:** `.lineLimit(1)` on path text — already correct.
- **Session is being renamed (stale `name` mid-edit):** N/A; rename happens in alert sheet, not inline.

## Files Touched

- `Views/SessionListView.swift` — modify `SessionRow` body, delete `semanticBadge` helper, add `.listRowSeparator(.hidden)` at the call site
- `KeeperTests/SessionRowTests.swift` (new) — smoke tests for the helper-free row construction
- `Keepur.xcodeproj/project.pbxproj` — wire the new test file into the test target

## Smoke Test Scope

Single new test file `KeeperTests/SessionRowTests.swift`. The row depends on a `Session` SwiftData model and a `ModelContext` for the preview lookup, so tests construct an in-memory `ModelContainer` (the same pattern used in existing `KeeperTests` — see `WorkspaceTests.swift` if present, otherwise mirror the standard `ModelContainer(for:configurations:)` setup with `isStoredInMemoryOnly: true`).

| Case | Assertion |
|---|---|
| Active + not stale | Row body constructs without crash; only "Active" pill expected (visual not asserted) |
| Stale + not active | Row body constructs; only "Stale" pill expected |
| Both active and stale | Row body constructs; both pills expected |
| Neither | Row body constructs; no pills |
| Long path | Row body constructs (truncation not asserted, just no crash) |
| Session with no preview message | Row body constructs (preview path returns nil) |

Each test follows the foundation-atoms pattern: `_ = row.body` to validate view tree construction. We **do not** snapshot or assert visual output (no snapshot lib in repo), and we **do not** instantiate the surrounding `SessionListView` (depends on `ChatViewModel` → Keychain → crashes in test env per epic constraints).

## Out of Scope

- **Unread badge** — held feature ticket per backlog explicit out-of-scope
- **Tap target / swipe / context menu changes** — not in backlog scope
- **List background / page background** — already on `bgPageDynamic`, no change required
- **Warning banner row at top of list** — unchanged
- **Empty state (`ContentUnavailableView`)** — unchanged
- **`SessionListView`'s macOS split / iOS nav stack wiring** — unchanged
- **Active session highlight** — the row used to bias the leading icon to honey when active; with the icon gone, the "Active" pill is the only active affordance. No additional row-level highlight requested by mockup.
- **Session selection visual on macOS sidebar** — `List(selection:)` continues to provide the system selection background; not overridden

## Open Questions

None. Backlog scope is unambiguous (drop avatar, swap badge → pill, cleaner divider, no unread badge). All required tokens and `KeepurStatusPill` API are confirmed present.

## Dependencies / Sequencing

- **Blocked by:** KPR-144 (`KeepurStatusPill` must exist in `Theme/Components/`). Already shipped on epic branch — confirmed by direct file read of `Theme/Components/KeepurStatusPill.swift`.
- **Soft dependency on:** KPR-147 (TabBar root architecture — Sessions tab landing). Not a hard block; the row redesign is independent of where the list is mounted. Either order is fine.
- **Blocks:** none.

## Human Signoff

Pre-approved per durable user delegation (KPR-142 design v2 epic — mockups already approve component intent; user explicit: "as long as it more or less looks like the mockup, I don't care beyond that"). Recorded in epic-orchestrator memory.
