# KPR-144 — Foundation Atoms (KeepurAvatar / KeepurStatusPill / KeepurUnreadBadge)

**Date:** 2026-05-02
**Epic:** [KPR-142 design v2](https://linear.app/keepur/issue/KPR-142)
**Layer:** 1 (foundation primitives)
**Depends on:** none

## Problem

The design v2 mockups introduce three small reusable visual primitives that recur across multiple per-screen tickets (Hive sidebar, Agent detail half-sheet, Sessions row, TeamMessageBubble polish). Without extracting these atoms first, downstream tickets either duplicate ad-hoc layout code or block on each other for shared concerns. Layer 1 lifts them into `Theme/Components/` ahead of any consumer changes.

## Solution

Three additive components in `Theme/Components/`. No view changes anywhere else in the codebase. Each component composes existing `KeepurTheme` tokens — no new color, font, or spacing constants required.

## Key Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Avatar shape | Square with rounded corners (`Radius.sm`) | Mockups show square rounded; matches the "tile" feel of TabBar items |
| Avatar size API | Raw `CGFloat` (default `56`) | Backlog lists 24/40/56/60 as guidance; raw `CGFloat` is more flexible than an enum and the mockups don't bind us to those exact four |
| Avatar content | Enum `Content { letter(String), emoji(String) }` | Two distinct rendering paths (text styling differs); avoids type confusion at call sites |
| Avatar background | Defaults to `wax100`, optional override | Wax surface lifts both letter and emoji evenly; mockups don't strongly signal honey-tinted defaults across all uses |
| Status overlay tint | Reuse `KeepurStatusPill.Tint` enum | Single semantic vocabulary across both atoms |
| StatusPill text styling | `Font.caption` + medium weight | Caption is the smallest UI tier in the type ramp; medium weight reads at small sizes against tinted backgrounds |
| StatusPill tint colors | `tint @ 0.15` background + `tint` foreground | Vivid enough for legibility, soft enough to live alongside body content |
| UnreadBadge overflow | `9+` for `count > 9` | iOS standard; matches Apple Mail / Messages |
| UnreadBadge null state | Returns `EmptyView` for `count == 0` | Caller doesn't need to wrap in conditional |

## Component Designs

### KeepurAvatar

```swift
struct KeepurAvatar: View {
    enum Content {
        case letter(String)   // first character used; uppercased
        case emoji(String)    // rendered as-is (assumed already a single grapheme)
    }

    let size: CGFloat
    let content: Content
    let statusOverlay: KeepurStatusPill.Tint?
    let background: Color

    init(
        size: CGFloat = 56,
        content: Content,
        statusOverlay: KeepurStatusPill.Tint? = nil,
        background: Color = KeepurTheme.Color.wax100
    )

    var body: some View // see Visual Spec below
}
```

#### Visual Spec

- **Frame:** `size × size`, `RoundedRectangle(cornerRadius: KeepurTheme.Radius.sm)`
- **Background:** `background` parameter (default `wax100`)
- **Letter content:**
  - First character of input, uppercased
  - Font: `.system(size: size * 0.45, weight: .semibold, design: .default)` (scales proportionally)
  - Foreground: `KeepurTheme.Color.fgPrimary`
- **Emoji content:**
  - Rendered as `Text` at `.system(size: size * 0.6)`
  - No foreground tint (preserves emoji's native color)
- **Status overlay (when non-nil):**
  - 8pt circle (or `max(8, size * 0.16)` — clamped floor for tiny sizes)
  - Position: bottom-right, inset by `size * 0.05` from container edge
  - Fill: tint resolved via `KeepurStatusPill.Tint.color`
  - 1.5pt white ring around overlay for separation from underlying content
- **Accessibility:** `accessibilityLabel` derived from content (letter spelled, emoji description fallback to "avatar")

#### Edge cases

- Empty letter input → `Text("?")` placeholder
- Multi-character letter input → first character only
- Multi-character emoji input → first character only (typical case: single grapheme already)
- Very small sizes (< 24pt) → status overlay still renders at 8pt minimum

### KeepurStatusPill

```swift
struct KeepurStatusPill: View {
    enum Tint {
        case success   // KeepurTheme.Color.success
        case warning   // KeepurTheme.Color.warning
        case danger    // KeepurTheme.Color.danger
        case honey     // KeepurTheme.Color.honey500
        case muted     // KeepurTheme.Color.fgMuted

        var color: Color { /* maps to token */ }
    }

    let text: String
    let tint: Tint

    init(_ text: String, tint: Tint)

    var body: some View // see Visual Spec
}
```

#### Visual Spec

- **Layout:** `HStack` is unnecessary — single `Text` wrapped in capsule
- **Frame:** intrinsic size (text width + padding)
- **Padding:** `KeepurTheme.Spacing.s2` horizontal, `KeepurTheme.Spacing.s1` vertical (4pt)
- **Background:** `tint.color.opacity(0.15)`
- **Shape:** `Capsule()`
- **Text:** `KeepurTheme.Font.caption`, weight `.medium`, foreground `tint.color`
- **Accessibility:** `accessibilityLabel(text)`, `accessibilityAddTraits(.isStaticText)`

#### Edge cases

- Empty text → renders empty capsule (caller's responsibility to gate)
- Very long text → wraps to multiple lines (intentional — caller controls call-site truncation if needed)

### KeepurUnreadBadge

```swift
struct KeepurUnreadBadge: View {
    let count: Int

    init(count: Int)

    var body: some View // EmptyView if count == 0, else capsule
}
```

#### Visual Spec

- **Null case (`count == 0`):** `EmptyView()`
- **Display text:** `count > 9 ? "9+" : "\(count)"`
- **Frame:** `minWidth: 18`, height auto (allows narrow "1" and wider "9+")
- **Padding:** `KeepurTheme.Spacing.s1` horizontal (4pt), 1pt vertical
- **Background:** `KeepurTheme.Color.honey500`
- **Shape:** `Capsule()`
- **Text:** `KeepurTheme.Font.caption`, weight `.semibold`, foreground `Color.white`
- **Accessibility:** `accessibilityLabel("\(count) unread")` when count > 0

#### Edge cases

- `count < 0` → treated as 0 (returns `EmptyView`)
- `count == 1` → renders "1" centered with intrinsic min width
- `count > 99` → still shows "9+" (no special "99+" tier per backlog)

## Smoke Test Scope

Single test file `KeeperTests/KeepurFoundationAtomsTests.swift` covering all three components. Each test asserts the view can be instantiated and that the public API behaves predictably — visual rendering itself is not asserted (no snapshot library in project; UI tests would over-engineer foundation atoms).

| Component | Test cases |
|---|---|
| `KeepurAvatar` | `size`, `content` (letter + emoji), `statusOverlay` (nil + each tint) all instantiate without crash; letter content uppercases; multi-char letter takes first character |
| `KeepurStatusPill` | All `Tint` cases produce a non-nil view; `text` round-trips through accessibility label |
| `KeepurUnreadBadge` | `count == 0` returns logically-empty view (use `Mirror` or `_VariadicView` introspection or just instantiate and verify `body` doesn't crash); `count == 1`, `count == 9`, `count == 10`, `count == 100` all instantiate; `count == -1` treated as 0 |

Test target wires via existing `KeepurThemeFontsTests.swift` pattern — same `import Keepur` testable, same setup.

## Out of Scope

- View changes to existing screens — happens in layer-3 tickets (KPR-148/150/151/155 all consume these)
- Snapshot tests — no library, not warranted for foundation atoms
- Accessibility audit beyond `accessibilityLabel` — covered when consumed by per-screen tickets
- Dark mode tinting (project is light-only on macOS per existing convention; iOS dark mode handled by SwiftUI defaults via wax/honey tokens)

## Open Questions

None. Backlog spec, mockup intent, and existing token system fully constrain the API surface.

## Files Touched

- `Theme/Components/KeepurAvatar.swift` (new)
- `Theme/Components/KeepurStatusPill.swift` (new)
- `Theme/Components/KeepurUnreadBadge.swift` (new)
- `KeeperTests/KeepurFoundationAtomsTests.swift` (new)
- `Keepur.xcodeproj/project.pbxproj` (wire new files into both iOS and macOS targets)

## Dependencies / Sequencing

- **Blocks:** KPR-148 (Sessions row, needs StatusPill), KPR-150 (Hive sidebar, needs Avatar + UnreadBadge), KPR-151 (Agent detail, needs Avatar), KPR-155 (TeamMessageBubble, needs mini Avatar)
- **Blocked by:** none
- Can run in parallel with KPR-145, KPR-146, KPR-147

## Human Signoff

Pre-approved per durable user delegation (KPR-142 design v2 epic — mockups already approve component intent; user explicit: "as long as it more or less looks like the mockup, I don't care beyond that"). Recorded in epic-orchestrator memory.
