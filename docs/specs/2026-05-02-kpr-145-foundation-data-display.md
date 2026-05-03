# KPR-145 — Foundation Data Display (KeepurChipCluster / KeepurMetricGrid / KeepurCard)

**Date:** 2026-05-02
**Epic:** [KPR-142 design v2](https://linear.app/keepur/issue/KPR-142)
**Layer:** 1 (foundation primitives)
**Depends on:** none

## Problem

The design v2 mockups introduce three reusable data-display containers that recur across multiple per-screen tickets (Agent detail half-sheet, Settings card-grouped sections, Saved Workspaces rows). Today these patterns exist as ad-hoc helpers inside individual views — `AgentDetailSheet.sectionCard`, `AgentDetailSheet.infoRow`, and `Tools/Channels` rendered as `.joined(separator: ", ")` strings. Layer 1 lifts them into `Theme/Components/` ahead of any consumer changes so the per-screen tickets (KPR-149, KPR-151, others) consume a single canonical implementation.

## Solution

Three additive components in `Theme/Components/`. No view changes anywhere else in the codebase. Each component composes existing `KeepurTheme` tokens — no new color, font, spacing, or radius constants required.

## Key Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Chip cluster layout primitive | SwiftUI `Layout` protocol (iOS 16+ / macOS 13+) | Both targets meet the minimum; native `Layout` avoids hand-rolled `GeometryReader` width-measurement loops; no UIKit fallback needed |
| Chip data API | `[String]` of labels (no per-chip styling) | Backlog use cases (Tools, Channels) are flat string lists. Per-chip color/icon would over-engineer the foundation — callers can wrap in their own component later |
| Chip overflow behavior | `+N` chip rendered when `maxVisible` exceeded; default `nil` (no cap) | Mockups show `+N` only in dense contexts; defaulting to no cap keeps simple call sites simple |
| Chip overflow tint | Same wax styling as regular chip (not honey) | Overflow is informational, not a CTA; honey would imply tap affordance we aren't shipping |
| Chip styling | `wax100` background + `fgSecondary` text + `Radius.xs` | Matches the "small chip" radius token comment in `KeepurTheme.swift`; wax surfaces sit comfortably inside `KeepurCard` (also wax) without competing |
| Metric grid column count | Fixed at 3 columns | Backlog text explicitly says "3-column horizontal grid"; mockup layouts (MODEL / MESSAGES / LAST ACTIVE) confirm. A `columns` parameter would invite drift from the mockup |
| Metric grid data API | `[Metric]` where `Metric` is `(label: String, value: String)` | Matches the eyebrow-over-value visual; values are pre-formatted strings (caller owns date formatting, pluralization, etc.) |
| Metric grid handling of < 3 entries | Trailing cells render as empty spacers | Preserves 3-column visual rhythm; consumers can pad with no-op metrics if they want explicit blanks |
| Metric grid handling of > 3 entries | Wraps to additional rows of 3 | Same `LazyVGrid` 3-column layout; degrades naturally |
| Card border | Optional, default off | Backlog says "optional 1px border"; default off keeps the simplest wax-surface case clean |
| Card padding | `Spacing.s4` (16pt) all sides | Matches existing `sectionCard` and `voiceSection` in `AgentDetailSheet` so visual mass is preserved when those sites migrate |
| Card corner radius | `Radius.sm` (10pt) | Matches existing `sectionCard` / `voiceSection`; stays inside the "small card" tier per `KeepurTheme.swift` Radius comment |
| Card background | `bgSurfaceDynamic` | Same as existing `sectionCard`; light/dark adaptive. Wax tint comes from the surface vs. page contrast, not from the card itself |
| Cross-platform imports | None needed | All three components are pure SwiftUI; no `#if canImport(UIKit)` guards |

## Component Designs

### KeepurChipCluster

```swift
struct KeepurChipCluster: View {
    let labels: [String]
    let maxVisible: Int?     // nil = show all; otherwise cap with "+N" overflow

    init(_ labels: [String], maxVisible: Int? = nil)

    var body: some View // see Visual Spec below
}
```

#### Visual Spec

- **Outer layout:** custom `WrappingHStack` (a `Layout`-protocol struct, file-private) that wraps children to multiple lines on width overflow. Horizontal spacing `KeepurTheme.Spacing.s1` (4pt), vertical spacing `KeepurTheme.Spacing.s1`.
- **Children:** one `chipView(label:)` per visible label, plus optional overflow chip.
- **Visible computation:**
  - If `maxVisible == nil` or `labels.count <= maxVisible` → render all labels, no overflow chip.
  - Otherwise → render `labels.prefix(maxVisible)` plus a single trailing chip with text `"+\(labels.count - maxVisible)"`.
- **Chip styling (per chip):**
  - Padding: `KeepurTheme.Spacing.s2` horizontal (8pt), `KeepurTheme.Spacing.s1` vertical (4pt)
  - Background: `KeepurTheme.Color.wax100`
  - Shape: `RoundedRectangle(cornerRadius: KeepurTheme.Radius.xs)` (6pt)
  - Text font: `KeepurTheme.Font.caption`
  - Text foreground: `KeepurTheme.Color.fgSecondary`
- **Overflow chip styling:** identical to regular chip (no special tint).
- **Empty state:** `labels.isEmpty` → renders nothing (zero-size container). Caller is responsible for gating "no items" copy.
- **Accessibility:**
  - `accessibilityElement(children: .combine)` so VoiceOver reads the cluster as a single element.
  - `accessibilityLabel(labels.joined(separator: ", "))` plus overflow suffix when truncated (e.g., `"swift, ruby, python, plus 4 more"`).

#### Edge cases

- `labels == []` → empty container, no crash, takes zero height.
- `labels.count == 1` → single chip, no wrapping.
- `maxVisible == 0` with non-empty labels → renders only the `+N` overflow chip.
- `maxVisible >= labels.count` → behaves as `nil` (no overflow chip).
- Very long single label → chip grows to fit (intrinsic width); next chip wraps to a new line.
- Container width too narrow for a single chip → chip clips; this is a caller responsibility (the foundation does not truncate text).

### KeepurMetricGrid

```swift
struct KeepurMetricGrid: View {
    struct Metric: Identifiable {
        let id = UUID()
        let label: String   // eyebrow text (e.g., "MODEL")
        let value: String   // pre-formatted display value (e.g., "claude-sonnet-4")
    }

    let metrics: [Metric]

    init(_ metrics: [Metric])

    var body: some View // see Visual Spec
}
```

#### Visual Spec

- **Outer layout:** `LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), spacing: KeepurTheme.Spacing.s3)`.
- **Per-cell layout:** `VStack(alignment: .leading, spacing: KeepurTheme.Spacing.s1)`.
- **Eyebrow label:**
  - Text uppercased at render time (`label.uppercased()`).
  - Font: `KeepurTheme.Font.eyebrow`
  - Tracking: `KeepurTheme.Font.lsEyebrow`
  - Foreground: `KeepurTheme.Color.fgSecondaryDynamic`
  - `textCase(nil)` to preserve the explicit uppercase (matches `AgentDetailSheet.sectionCard`).
- **Value:**
  - Font: `KeepurTheme.Font.bodySm`
  - Foreground: `KeepurTheme.Color.fgPrimaryDynamic`
  - `lineLimit(1)` + `truncationMode(.tail)` to keep cells visually balanced.
- **Empty state:** `metrics.isEmpty` → `EmptyView()`.
- **Accessibility:** each cell `accessibilityElement(children: .combine)` with label `"\(label): \(value)"`.

#### Edge cases

- `metrics.count == 1` → single cell in column 1; columns 2 and 3 stay empty (LazyVGrid still sizes flex columns).
- `metrics.count == 2` → cells in columns 1 and 2; column 3 empty.
- `metrics.count == 4` → row 1 has 3 cells, row 2 has 1 cell.
- Very long value → truncates to single line with tail ellipsis.
- Empty `value` string → renders empty value space (caller's responsibility to gate or supply placeholder like "—").

### KeepurCard

```swift
struct KeepurCard<Content: View>: View {
    let bordered: Bool
    let content: Content

    init(bordered: Bool = false, @ViewBuilder content: () -> Content)

    var body: some View // see Visual Spec
}
```

#### Visual Spec

- **Padding:** `KeepurTheme.Spacing.s4` (16pt) all sides.
- **Background:** `KeepurTheme.Color.bgSurfaceDynamic`.
- **Shape:** `RoundedRectangle(cornerRadius: KeepurTheme.Radius.sm)`.
- **Border (when `bordered == true`):** 1pt `KeepurTheme.Color.borderDefaultDynamic` via existing `.keepurBorder(...)` modifier (already supports `radius:` and `width:` parameters).
- **Frame:** `frame(maxWidth: .infinity, alignment: .leading)` so the card always spans its container — matches existing `sectionCard` behavior so migrating call sites doesn't shift layout.
- **Accessibility:** none added at the container level — content is responsible for its own a11y.

#### Edge cases

- Empty content (`KeepurCard {}`) → renders an empty padded surface (intentional; caller's choice).
- Very tall content → card grows; no internal scroll (caller wraps in `ScrollView` if needed).
- Nested `KeepurCard` → visually stacks two padded surfaces (intentional — caller gets what they ask for; foundation does not deduplicate).

## Smoke Test Scope

Single test file `KeeperTests/KeepurFoundationDataDisplayTests.swift` covering all three components. Each test asserts the view can be instantiated with a representative parameter sweep and that overflow / column-count logic is correct. No render assertion (no snapshot library in project; UI tests would over-engineer foundation primitives). Follows the `KeepurThemeFontsTests.swift` import/setup pattern.

| Component | Test cases |
|---|---|
| `KeepurChipCluster` | empty `labels`, single label, many labels (no cap), `maxVisible` cap engaged, `maxVisible` cap not engaged (`maxVisible >= labels.count`), `maxVisible == 0`; verify body construction does not crash for each |
| `KeepurMetricGrid` | empty metrics, 1 metric, 2 metrics, 3 metrics, 4 metrics (wrap), long-value metric; verify body construction does not crash; verify `Metric` struct round-trips label+value |
| `KeepurCard` | bordered + non-bordered with `Text` content, with empty content, with nested `KeepurCard`; verify body construction does not crash |

## Out of Scope

- View changes to existing screens — happens in layer-3 tickets (KPR-149 Settings cards, KPR-151 Agent detail consume these).
- Snapshot tests — no library, not warranted for foundation primitives.
- Per-chip color/icon variants — not present in mockups; deferred until a real use case appears.
- Configurable column count for `KeepurMetricGrid` — backlog explicitly fixes 3 columns.
- Dark mode tinting beyond what the existing `*Dynamic` color tokens already provide.
- Accessibility audit beyond `accessibilityElement` + `accessibilityLabel` — covered when consumed by per-screen tickets.

## Open Questions

None. Backlog spec, mockup intent, existing `AgentDetailSheet` patterns, and the existing token system fully constrain the API surface.

## Files Touched

- `Theme/Components/KeepurChipCluster.swift` (new)
- `Theme/Components/KeepurMetricGrid.swift` (new)
- `Theme/Components/KeepurCard.swift` (new)
- `KeeperTests/KeepurFoundationDataDisplayTests.swift` (new)
- `Keepur.xcodeproj/project.pbxproj` (wire new files into both iOS and macOS targets; test file into test target)

## Dependencies / Sequencing

- **Blocks:** KPR-149 (Settings card-grouped sections, needs `KeepurCard`), KPR-151 (Agent detail half-sheet, needs all three)
- **Blocked by:** none
- Can run in parallel with KPR-144, KPR-146, KPR-147

## Human Signoff

Pre-approved per durable user delegation (KPR-142 design v2 epic — mockups already approve component intent; user explicit: "as long as it more or less looks like the mockup, I don't care beyond that"). Recorded in epic-orchestrator memory.
