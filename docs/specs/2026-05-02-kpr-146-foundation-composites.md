# KPR-146 — Foundation Composites (KeepurActionSheet / KeepurChatHeader)

**Date:** 2026-05-02
**Epic:** [KPR-142 design v2](https://linear.app/keepur/issue/KPR-142)
**Layer:** 1 (foundation primitives)
**Depends on:** none

## Problem

The design v2 mockups introduce two larger composite components that recur across multiple per-screen tickets but operate at a higher granularity than the atoms in KPR-144 or the data-display primitives in KPR-145. Both encode meaningful chrome decisions (a branded bottom-sheet pattern, a custom toolbar header) that downstream tickets (KPR-152 chat header redesign, KPR-154 attach action sheet) need to consume verbatim. Without extracting them into `Theme/Components/` first, those downstream tickets either invent diverging variants or block on each other for shared chrome.

## Solution

Two additive components in `Theme/Components/`. No view changes anywhere else in the codebase. Both compose existing `KeepurTheme` tokens — no new color, font, spacing, or radius constants required. The status-line pulsing animation is the only new motion behavior; it is driven by `KeepurTheme.Motion.easeHoney` in repeat-forever mode.

## Key Decisions

| Decision | Choice | Rationale |
|---|---|---|
| `KeepurChatHeader` shape | Reusable `View` composed inside a custom `ToolbarItem` (option a) | Existing call sites in `Views/ChatView.swift` and `Views/Team/TeamChatView.swift` already use bespoke `.toolbar { ToolbarItem(placement: .automatic) { ... } }` blocks with HStacks of buttons. A `ViewModifier` (option b) would force callers to abandon their existing toolbar wiring entirely and would have to reach into the navigation back-button slot, which differs between iOS (`navigationBarBackButtonHidden` + custom leading item) and macOS (no built-in back button at all in `NavigationStack` toolbars). A View we drop into a `ToolbarItem(placement: .principal)` (iOS) / `ToolbarItem(placement: .automatic)` (macOS) keeps the integration contract small and platform-conditional in one place at the call site. Option (b) is reconsidered if all four call sites duplicate identical wiring after KPR-152 lands. |
| `KeepurActionSheet` shape | Reusable `View` embedded inside a `.sheet { }` presentation, not a presentation API wrapper | Caller controls `@State isPresented` and presentation detents — matches the existing pattern in `TeamChatView.swift` (`.sheet(isPresented:) { AgentDetailSheet(...).presentationDetents([.medium, .large]) }`) and `ChatView.swift` (`ToolApprovalView` inside `.sheet`). No surprise: behaves like every other sheet body in the codebase. |
| Action row API | `struct Action { let symbol: String; let title: String; let subtitle: String?; let action: () -> Void }` (top-level type nested under `KeepurActionSheet`) | Backlog spec calls out icon container + title + subtitle + chevron. Subtitle optional because not every consumer will have one. Symbol is an SF Symbol name (string), matching existing `KeepurTheme.Symbol.*` convention. |
| Trailing actions on header | `[Action]` array taking `struct Action { let symbol: String; let action: () -> Void }` | Matches the backlog spec's "1-3 typical" guidance. Variable count without overloads. Nested under `KeepurChatHeader` to scope the type. |
| Status line dot color | Honey-500 when `status` is non-nil with `isActive: true`; `fgMuted` otherwise | Matches the mockup's "● working" treatment. Honey is the only accent in the brand recipe; muted reads as resting/idle. |
| Status line pulse | 0.6s ease-in-out auto-reverse, scale 1.0 ↔ 1.4 | Matches the existing `StatusIndicator` thinking-dot tempo (`easeInOut(duration: 0.6).repeatForever(autoreverses: true)` in `ChatView.swift` line 238). Single source of brand-tempo. |
| Status line time string | `Text(date, style: .relative)` | Existing convention: see `Views/Team/AgentRow.swift`, `Views/WorkspacePickerView.swift`, `Views/SessionListView.swift`, `Views/Team/AgentDetailSheet.swift`. Auto-updates without timer wiring. |
| Back button rendering | 36pt circle, `wax100` fill, `chevronBack` symbol in `fgPrimary` | Honey-tinted background reserved for primary CTAs (per brand recipe); wax surface keeps chrome quiet. 36pt matches typical toolbar tap target. |
| Trailing button rendering | Identical 36pt circle treatment | Visual consistency with back button; no honey accent unless a future variant explicitly opts in. |
| Action sheet detents | Caller's responsibility (apply `.presentationDetents([.medium])` at the `.sheet { }` site) | Same convention as existing sheets. Avoids baking a detent decision into the component. |
| Action sheet handle | Rely on system-provided sheet handle (`presentationDragIndicator(.visible)` is caller's call) | Component does not draw a handle; matches existing sheet bodies in the codebase. |
| Action sheet title typography | `KeepurTheme.Font.h3` with `lsH3` tracking | Matches the eyebrow-then-h3 hierarchy already used in `AgentDetailSheet.swift`. |
| Action sheet subtitle typography | `KeepurTheme.Font.bodySm` in `fgSecondaryDynamic` | Mirrors existing secondary text treatment across sheets. |
| Action row icon container | 40pt square, `Radius.sm`, `accentTint` (honey-100) fill, symbol in `honey700` | Backlog spec verbatim: "leading icon container (~40pt square rounded honey-100 with honey-700 icon)". |

## Component Designs

### KeepurChatHeader

```swift
struct KeepurChatHeader: View {
    struct Action: Identifiable {
        let id = UUID()
        let symbol: String
        let action: () -> Void
    }

    let title: String
    let statusText: String?            // e.g. "working"
    let statusDate: Date?              // drives "· 2m ago" suffix
    let isStatusActive: Bool           // honey + pulse vs muted + static
    let onBack: (() -> Void)?          // nil → no back button
    let trailingActions: [Action]

    init(
        title: String,
        statusText: String? = nil,
        statusDate: Date? = nil,
        isStatusActive: Bool = false,
        onBack: (() -> Void)? = nil,
        trailingActions: [Action] = []
    )

    var body: some View // see Visual Spec
}
```

#### Visual Spec

- **Container layout:** `HStack(spacing: KeepurTheme.Spacing.s3)` with leading back button (optional), centered title block (expands), trailing action stack (optional)
- **Back button (when `onBack != nil`):**
  - 36pt circle, `KeepurTheme.Color.wax100` fill
  - `Image(systemName: KeepurTheme.Symbol.chevronBack)` in `KeepurTheme.Color.fgPrimary` at `.system(size: 16, weight: .semibold)`
  - `Button { onBack?() }` wrapping the circle; `buttonStyle(.plain)`
- **Title block (centered VStack, `spacing: 2`):**
  - `Text(title)` at `KeepurTheme.Font.h4` (18pt semibold), `fgPrimaryDynamic`, `lineLimit(1)`, `truncationMode(.tail)`
  - Status line `HStack(spacing: KeepurTheme.Spacing.s1)` (only rendered if `statusText != nil` OR `statusDate != nil`):
    - Pulsing dot: `Circle().fill(dotColor).frame(width: 6, height: 6)`. `dotColor = isStatusActive ? KeepurTheme.Color.honey500 : KeepurTheme.Color.fgMuted`
    - Status text: `Text(statusText ?? "")` at `KeepurTheme.Font.caption`, `fgSecondaryDynamic`
    - Separator dot " · " (literal middle-dot character) at `KeepurTheme.Font.caption`, `fgMuted` (only if both `statusText` and `statusDate` are present)
    - Relative date: `Text(statusDate, style: .relative)` at `KeepurTheme.Font.caption`, `fgSecondaryDynamic` (when non-nil)
- **Trailing action stack (`HStack(spacing: KeepurTheme.Spacing.s2)`):**
  - For each `Action`: 36pt circle, `wax100` fill, `Image(systemName: action.symbol)` in `fgPrimary` at `.system(size: 15, weight: .medium)`, wrapped in `Button { action.action() }.buttonStyle(.plain)`
  - Renders in declaration order, leading-to-trailing
- **Pulse animation (only when `isStatusActive == true`):**
  - `@State private var pulse = false` toggled in `.onAppear { withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { pulse = true } }`
  - Apply `.scaleEffect(pulse ? 1.4 : 1.0)` and `.opacity(pulse ? 0.6 : 1.0)` to the dot
  - When `isStatusActive` flips to false at runtime, animation halts (state retained but no longer drives a transform — implementation uses a conditional modifier)
- **Frame:** `frame(maxWidth: .infinity)` on the centered title block so trailing stack hugs the edge
- **Accessibility:**
  - Back button: `accessibilityLabel("Back")`
  - Title: `accessibilityLabel(title)`, `accessibilityAddTraits(.isHeader)`
  - Status line: `accessibilityLabel("\(statusText ?? "") \(statusDate.map { "updated \(RelativeDateTimeFormatter.shared.localizedString(for: $0, relativeTo: .now))" } ?? "")")` (use a static formatter helper local to file)
  - Each trailing action: caller provides symbol; default `accessibilityLabel` derived from symbol name (e.g., `"speaker.wave.2"` → `"Speaker"`) — adequate for smoke; per-screen tickets pass explicit labels via a future overload if needed (out of scope for KPR-146)

#### Integration pattern (documented inline at top of file as a `///` comment block)

```swift
.toolbar {
    ToolbarItem(placement: .principal) {
        KeepurChatHeader(
            title: "hive-dodi",
            statusText: "working",
            statusDate: lastActivityDate,
            isStatusActive: true,
            onBack: { dismiss() },
            trailingActions: [
                .init(symbol: "speaker.wave.2") { /* mute */ },
                .init(symbol: "info.circle") { /* show info */ }
            ]
        )
    }
}
.navigationBarBackButtonHidden(true)  // iOS only — caller's responsibility
```

#### Edge cases

- `onBack == nil` → no back button slot, title block leads from container start
- `trailingActions` empty → no trailing stack, title block extends to container trailing edge
- Both `statusText` and `statusDate` nil → status line not rendered; title sits visually centered without subline (height collapses)
- `statusDate` provided but stale (> 24h) → `Text(_, style: .relative)` handles formatting; no special "long ago" treatment
- Long title that overflows → `lineLimit(1)` + `truncationMode(.tail)`; status line still renders below truncated title
- Pulse animation never starts on macOS if `isStatusActive == false` from the start — no animation lifecycle to clean up

### KeepurActionSheet

```swift
struct KeepurActionSheet: View {
    struct Action: Identifiable {
        let id = UUID()
        let symbol: String
        let title: String
        let subtitle: String?
        let action: () -> Void

        init(symbol: String, title: String, subtitle: String? = nil, action: @escaping () -> Void)
    }

    let title: String
    let subtitle: String?
    let actions: [Action]

    init(title: String, subtitle: String? = nil, actions: [Action])

    var body: some View // see Visual Spec
}
```

#### Visual Spec

- **Outer container:** `VStack(alignment: .leading, spacing: KeepurTheme.Spacing.s4)` inside a `ScrollView` (so the sheet body doesn't truncate if a caller eventually exceeds the medium detent)
- **Header VStack(alignment: .leading, spacing: KeepurTheme.Spacing.s1):**
  - `Text(title)` at `KeepurTheme.Font.h3` (22pt semibold) with `tracking(KeepurTheme.Font.lsH3)`, `fgPrimaryDynamic`
  - `Text(subtitle ?? "")` at `KeepurTheme.Font.bodySm`, `fgSecondaryDynamic` — only rendered if `subtitle != nil`
- **Action rows VStack(spacing: KeepurTheme.Spacing.s2):** one row per `Action`
  - Row HStack(spacing: KeepurTheme.Spacing.s3):
    - **Icon container:** 40pt × 40pt, `RoundedRectangle(cornerRadius: KeepurTheme.Radius.sm)` filled with `KeepurTheme.Color.accentTint` (honey-100). `Image(systemName: action.symbol)` centered, `foregroundStyle(KeepurTheme.Color.honey700)`, `.system(size: 18, weight: .medium)`
    - **Text VStack(alignment: .leading, spacing: 2):**
      - `Text(action.title)` at `KeepurTheme.Font.body`, weight `.medium`, `fgPrimaryDynamic`
      - `Text(action.subtitle ?? "")` at `KeepurTheme.Font.caption`, `fgSecondaryDynamic` — only rendered when `subtitle != nil`
    - `Spacer()`
    - `Image(systemName: "chevron.right")` at `KeepurTheme.Font.bodySm`, `fgTertiary`
  - Row tap target: full HStack wrapped in `Button { action.action() }.buttonStyle(.plain)`
  - Row vertical padding: `KeepurTheme.Spacing.s2`
  - Row horizontal padding: `KeepurTheme.Spacing.s3`
  - Row background: `KeepurTheme.Color.bgSurfaceDynamic`, clipped to `RoundedRectangle(cornerRadius: KeepurTheme.Radius.sm)`
- **Outer padding:** `padding(.horizontal, KeepurTheme.Spacing.s4)`, `padding(.top, KeepurTheme.Spacing.s5)`, `padding(.bottom, KeepurTheme.Spacing.s4)`
- **Background:** `KeepurTheme.Color.bgPageDynamic`
- **Accessibility:**
  - Title: `accessibilityAddTraits(.isHeader)`
  - Each row: `accessibilityLabel("\(action.title), \(action.subtitle ?? "")")`, `accessibilityHint("Double tap to select")`

#### Integration pattern (documented inline at top of file as a `///` comment block)

```swift
@State private var showAttach = false

// ...
.sheet(isPresented: $showAttach) {
    KeepurActionSheet(
        title: "Attach",
        subtitle: "Add a file or photo to the message.",
        actions: [
            .init(symbol: "doc",      title: "Choose file",   subtitle: "Browse documents on this device") { /* ... */ },
            .init(symbol: "photo",    title: "Photo library", subtitle: "Pick from your photos")          { /* ... */ },
            .init(symbol: "camera",   title: "Take photo",    subtitle: "Use the camera now")              { /* ... */ },
        ]
    )
    .presentationDetents([.medium])
    .presentationDragIndicator(.visible)
}
```

#### Edge cases

- `subtitle == nil` (sheet header) → subtitle text not rendered; title sits flush against first row
- `actions` empty → renders header only with a small empty-state padding (caller's responsibility — component renders gracefully but doesn't add a placeholder)
- Action with `subtitle == nil` → row collapses vertically to a single text line; chevron and icon stay vertically centered
- Very long action title → `lineLimit(2)` + `.truncationMode(.tail)` on the title text
- Tapping a row does NOT auto-dismiss the sheet — caller's action closure is responsible for setting `showAttach = false` if desired (matches existing `MessageInputBar` popover pattern)

## Smoke Test Scope

Single test file `KeeperTests/KeepurFoundationCompositesTests.swift` covering both components. Each test asserts the view can be instantiated across a parameter sweep and that `_ = view.body` doesn't crash. No render assertion (no snapshot library; UI tests over-engineer foundation chrome).

| Component | Test cases |
|---|---|
| `KeepurChatHeader` | Minimal init (title only); with `onBack`; with `statusText` only; with `statusDate` only; with both status fields and `isStatusActive: true`; with 0/1/2/3 trailing actions; long title (truncation path) |
| `KeepurActionSheet` | Empty actions array; one action with no subtitle; three actions all with subtitles; long title; long subtitle |

Test target wires via existing `KeepurThemeFontsTests.swift` pattern — same `@testable import Keepur`, same setup.

## Out of Scope

- View changes to existing `Views/ChatView.swift` / `Views/Team/TeamChatView.swift` — happens in KPR-152 (chat header redesign)
- View changes to `Views/MessageInputBar.swift` to consume `KeepurActionSheet` — happens in KPR-154 (attach action sheet)
- Camera capture row wiring — held feature ticket (sibling epic); KPR-154 will pass a placeholder action that triggers an alert
- Snapshot tests — no library, not warranted for foundation composites
- Accessibility audit beyond `accessibilityLabel` / `.isHeader` — covered when consumed by per-screen tickets
- Per-action accessibility label override on `KeepurChatHeader.Action` — the symbol-derived default is acceptable for smoke; KPR-152 may add an explicit `accessibilityLabel` field if real consumers need it
- Configurable button shape (square vs circle) on the chat header — circle only for KPR-146; future variants are a separate ticket
- Honey-tinted variants of the chat header back/trailing buttons — wax-only baseline; downstream tickets can introduce variants if mockups demand
- Dark mode tinting — relies on `bgPageDynamic` / `bgSurfaceDynamic` / `fgPrimaryDynamic` already shipping by token

## Open Questions

- None blocking implementation. The accessibility-label-from-symbol heuristic for `KeepurChatHeader.Action` is intentionally a baseline; if KPR-152 review surfaces a need, an explicit per-action label parameter is a backwards-compatible addition.

## Files Touched

- `Theme/Components/KeepurActionSheet.swift` (new)
- `Theme/Components/KeepurChatHeader.swift` (new)
- `KeeperTests/KeepurFoundationCompositesTests.swift` (new)
- `Keepur.xcodeproj/project.pbxproj` (wire new files into both iOS and macOS targets)

## Dependencies / Sequencing

- **Blocks:** KPR-152 (Chat header redesign, needs `KeepurChatHeader`), KPR-154 (Attach action sheet, needs `KeepurActionSheet`)
- **Blocked by:** none
- Can run in parallel with KPR-144, KPR-145, KPR-147

## Human Signoff

Pre-approved per durable user delegation (KPR-142 design v2 epic — mockups already approve component intent; user explicit: "as long as it more or less looks like the mockup, I don't care beyond that"). Recorded in epic-orchestrator memory.
