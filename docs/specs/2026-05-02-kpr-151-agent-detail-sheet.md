# KPR-151 — Agent Detail Half-Sheet (metric grid + chips + status pill)

**Date:** 2026-05-02
**Epic:** [KPR-142 design v2](https://linear.app/keepur/issue/KPR-142)
**Layer:** 3 (per-screen consumption)
**Depends on:** KPR-144 (foundation atoms), KPR-145 (foundation data display)

## Problem

`Views/Team/AgentDetailSheet.swift` today is a stack of ad-hoc `infoRow` and `sectionCard` helpers. It pre-dates the design v2 component vocabulary: a 48pt emoji header, a four-row `Title / Model / Messages / Last Active` info card, comma-joined `Tools` and `Channels` strings, and bespoke section card chrome. The mockups for design v2 reframe this surface around the new foundation primitives — square avatar with status overlay, a 3-column metric grid, wrapping chip clusters with `+N` overflow, and a JetBrains-Mono cron pill paired with a plain task label.

Every primitive needed already landed in `Theme/Components/` via KPR-144 / KPR-145. This ticket consumes them.

## Solution

Rewrite the body of `AgentDetailSheet` around four new visual sections, all built from existing components. The voice navigation row stays — it has its own affordance vocabulary (chevron + eyebrow label) and is not in the mockup's redesigned region.

The sheet's presentation detents (`.medium`, `.large`) are already correctly configured at the **call site** in `Views/Team/TeamChatView.swift:81`. No detent change is required as part of this ticket — the backlog line "Sheet detents: medium first, expandable to large" describes the existing behavior, which we preserve.

## Key Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Header avatar source | `KeepurAvatar` with `.emoji(agent.icon)` content, fallback `.letter(agent.name)` when icon empty | Mirrors the existing `iconText` fallback (`agent.icon.isEmpty ? "🤖" : agent.icon`), but routes the empty case to a letter avatar for consistency with the Hive sidebar treatment in KPR-150 |
| Header avatar size | 60pt (per backlog) | Backlog line is explicit |
| Header status overlay on avatar | **Not used** here | The header already shows status as a `KeepurStatusPill` directly beneath the name; a corner overlay on a 60pt avatar would duplicate that signal. The overlay pattern is reserved for the small-avatar list contexts (Hive sidebar) where there's no room for a pill |
| Header name font tier | `KeepurTheme.Font.h2` ("display tier") | Backlog says "display tier"; `Font.display` is 48pt (oversized for a sheet header, would crowd the avatar). `h2` (28pt semibold) is the largest tier that reads as a "display" style inside a half-sheet without overflowing the medium detent |
| Status text in pill | Title-cased `agent.status` (`Idle`, `Processing`, `Error`, `Stopped`) | Server emits lowercase; pill caption font + medium weight reads better with title case. Unknown statuses pass through as-is |
| Status → tint mapping | `idle → .success`, `processing → .warning`, `error/stopped → .danger`, default → `.muted` | Matches existing `statusColor` mapping in the file today (preserves visual continuity for users) |
| Metric grid contents | Always 3 cells: MODEL / MESSAGES / LAST ACTIVE | Backlog says 3 columns. The existing `Title` row is dropped from the grid (it already lives implicitly in the header context — agents have a name; titles like "Coding Agent" are sometimes empty and inconsistent across the team). If `agent.title` is non-empty, it renders as a small subtitle line beneath the name in the header |
| MODEL value when empty | `"—"` em-dash placeholder | `KeepurMetricGrid` truncates with `.tail`; empty string would render as a blank cell with just an eyebrow label, which looks broken |
| LAST ACTIVE value | Pre-computed relative string (`"2m ago"`, `"Never"`) | `KeepurMetricGrid.Metric.value` is `String`, not a `Date` or `Text`. Computing the relative string at render time using `RelativeDateTimeFormatter` keeps the metric grid component dumb. Trade-off: the value won't auto-tick like `Text(date, style: .relative)` did — acceptable because the sheet is short-lived and "out of scope: real-time agent status updates" |
| Tools / Channels max visible | `maxVisible: 6` for both | Backlog implies overflow is expected ("with `+N` overflow"). 6 chips fits comfortably on a single row at typical chip widths in medium detent on iPhone 17 Pro. Channels prefix is `"#"` per existing renderer; preserved |
| Tools / Channels empty handling | Section omitted entirely (existing behavior) | `KeepurChipCluster` with empty input is technically valid (renders nothing) but leaving the eyebrow section header dangling above empty content looks broken |
| Schedule cron chip styling | `.font(.custom(KeepurTheme.FontName.mono, size: 12))` + horizontal/vertical padding + `wax100` background + `Radius.xs` capsule shape | Matches `KeepurChipCluster.chipView` styling but with mono font instead of caption. Inlined as a private helper in the file rather than introducing a new `KeepurMonoChip` component — only used here |
| Schedule task label | `KeepurTheme.Font.bodySm` + `fgPrimaryDynamic`, no leading em-dash | Existing renderer uses `"— \(task)"`; the new chip-pill cron pulls visual focus, so the em-dash separator is no longer needed |
| Schedule entry layout | `HStack(alignment: .firstTextBaseline)` with `Spacing.s2` between cron pill and task | First-baseline alignment keeps the mono cron pill sitting on the same baseline as the task text even though their fonts differ |
| Voice navigation row | Unchanged structurally; minor refinement: replace `KeepurTheme.Color.bgSurfaceDynamic` background with `KeepurCard` wrapper for consistency with surrounding sections | Backlog says "minor refinement"; using `KeepurCard` replaces the inline `.background(...).clipShape(...)` boilerplate with the canonical container |
| Section ordering | Header → Metric grid → Tools chips → Channels chips → Schedule → Voice | Promotes high-density structured info (metrics, capabilities) above narrative info (schedule, voice). Current order is Header → Info → Tools → Schedule → Channels → Voice; new order groups Tools + Channels together as "what this agent does where" |
| Sheet container | Existing `NavigationStack { ScrollView { VStack } }` retained | Voice section uses `NavigationLink` to push `AgentVoicePickerView`; `NavigationStack` is required for that to work. `ScrollView` accommodates large detent + many channels/tools |
| Helpers removed | `infoRow(label:value:)`, `infoRow(label:date:)`, `sectionCard(title:content:)`, `iconText`, `lastActivityDate`-as-Date, manual `statusColor` Color | All replaced by foundation components or pure-string helpers |

## Visual Spec

### Header

```
┌─────────────────────────────┐
│         [60pt avatar]       │
│                             │
│         Agent Name          │  ← Font.h2 + lsH3 tracking, fgPrimaryDynamic
│         Coding Agent        │  ← Font.bodySm, fgSecondaryDynamic (only if title set)
│        [● Idle pill]        │  ← KeepurStatusPill, tint mapped from status
└─────────────────────────────┘
```

- `VStack(spacing: KeepurTheme.Spacing.s2)`
- Avatar centered horizontally
- Title subtitle line conditional on `agent.title?.isEmpty == false`

### Metric Grid

```
MODEL                MESSAGES             LAST ACTIVE
claude-sonnet-4      1,234                2m ago
```

- `KeepurMetricGrid([model, messages, lastActive])` — always 3 cells, deterministic order
- No surrounding `KeepurCard` (mockup shows the grid floating over the page background)
- `MODEL` value uses `agent.model` or `"—"` if empty
- `MESSAGES` value uses `"\(agent.messagesProcessed)"` (no thousands separator — matches existing renderer)
- `LAST ACTIVE` value uses pre-computed relative string from `lastActivityDate` (or `"Never"` if nil)

### Tools

```
TOOLS
[bash] [edit] [grep] [read] [write] [task] [+3]
```

- Eyebrow header `"TOOLS"` above (uses existing eyebrow style — `Font.eyebrow` + `lsEyebrow` tracking)
- `KeepurChipCluster(agent.tools, maxVisible: 6)` below
- Section omitted when `agent.tools.isEmpty`

### Channels

```
CHANNELS
[#general] [#engineering] [#alerts] [+2]
```

- Same shape as Tools, with `"#"` prefix on each label
- Section omitted when `agent.channels.isEmpty`

### Schedule

```
SCHEDULE
[0 9 * * *]   Daily standup summary
[0 17 * * 5]  Weekly retrospective
```

- Eyebrow header `"SCHEDULE"`
- Each entry: `HStack(alignment: .firstTextBaseline, spacing: Spacing.s2)`
  - Cron in mono pill chip (wax100 background, Radius.xs)
  - Task label in `Font.bodySm` + `fgPrimaryDynamic`
- Section omitted when `agent.schedule.isEmpty`

### Voice

```
┌─────────────────────────────┐
│ VOICE                       │
│ Samantha               >    │
└─────────────────────────────┘
```

- `KeepurCard { ... }` wrapping eyebrow + label + chevron
- `NavigationLink` destination unchanged (`AgentVoicePickerView`)

## Edge Cases

- **Agent with no icon and no name:** avatar falls back to `.letter("?")` via existing `KeepurAvatar` empty-string handling
- **Agent with unknown status string** (e.g. server adds new status): pill renders with `.muted` tint and the raw status string title-cased
- **Agent with one tool, one channel, one schedule entry:** all sections render with single chips/rows, no overflow
- **Agent with 100 tools:** `KeepurChipCluster` truncates to 6 + `+94` chip
- **Schedule entry missing `cron` or `task` key:** entry skipped silently (matches existing behavior)
- **`lastActivity` malformed ISO string:** falls back to `"Never"` (matches existing `lastActivityDate` parsing)
- **Empty model string:** MODEL cell shows `"—"`
- **macOS:** sheet renders the same way; `navigationBarTitleDisplayMode` already gated `#if os(iOS)`. No additional gating needed

## Smoke Test Scope

Single test file `KeeperTests/AgentDetailSheetTests.swift`. Cannot smoke-test `AgentDetailSheet.body` directly because it depends on `SpeechManager` (a `@MainActor ObservableObject` that touches `AVSpeechSynthesizer`, which is not safe to instantiate in unit tests under all CI environments).

Instead, test the **pure helper logic** that the rewrite introduces:

| Helper | Test cases |
|---|---|
| `statusTint(for:)` (status string → `KeepurStatusPill.Tint`) | `"idle" → .success`, `"processing" → .warning`, `"error" → .danger`, `"stopped" → .danger`, `"unknown" → .muted`, `"" → .muted` |
| `statusDisplay(for:)` (status string → title-cased display) | `"idle" → "Idle"`, `"processing" → "Processing"`, `"" → ""` |
| `lastActiveDisplay(from:)` (ISO 8601 string? → display string) | `nil → "Never"`, malformed → `"Never"`, valid recent ISO → non-empty (don't assert exact "2m ago" — depends on `RelativeDateTimeFormatter` locale) |
| `headerAvatarContent(for:)` (`TeamAgentInfo` → `KeepurAvatar.Content`) | non-empty icon → `.emoji`, empty icon + non-empty name → `.letter`, empty icon + empty name → `.letter("?")` (or whatever falls out — sanity check, not a contract) |

Helpers should be `internal` (default access) on the type or `fileprivate` global functions, depending on which compiles cleaner. If `fileprivate`, expose via `@testable` re-export inside the test file (or promote to `internal`).

## Out of Scope

- Real-time agent status updates (existing reactivity stays — sheet re-renders when `TeamAgentInfo` is replaced upstream)
- Sheet detent change (already correctly configured at call site)
- `AgentVoicePickerView` changes (separate view, not mentioned in backlog)
- TabBar / hive sidebar / chat header redesign (separate KPR tickets)
- Mocking `SpeechManager` for full-body smoke tests — would require protocolizing the manager; out of scope for a per-screen migration ticket
- Updating `TeamChatView` call site — call site already passes the correct props and detents

## Open Questions

None blocking. Two non-blocking notes:

- **Icon vs. letter avatar at the call site:** Hive sidebar (KPR-150) appears to favor letter avatars for agents. Agent detail sheet uses the agent's emoji icon when available because the sheet is a focused single-agent context where the icon is intentional brand. If product wants uniformity later, swap `headerAvatarContent` to letter-only.
- **Title-case mapping for status:** Could be data-driven if the server starts emitting more statuses. Current 4-status set is small enough for an inline switch.

## Files Touched

- `Views/Team/AgentDetailSheet.swift` (rewrite body, replace helpers)
- `KeeperTests/AgentDetailSheetTests.swift` (new)
- `Keepur.xcodeproj/project.pbxproj` (wire test file into test target — `Views/` is a synchronized folder group, so the rewritten view needs no project edit)

## Dependencies / Sequencing

- **Blocks:** none (leaf consumer in layer 3)
- **Blocked by:** KPR-144 (provides `KeepurAvatar`, `KeepurStatusPill`), KPR-145 (provides `KeepurMetricGrid`, `KeepurChipCluster`, `KeepurCard`) — both already merged into the epic branch
- Can run in parallel with all other layer-3 tickets (KPR-148, KPR-150, KPR-152, KPR-153, KPR-154, KPR-155, KPR-156)

## Human Signoff

Pre-approved per durable user delegation (KPR-142 design v2 epic — "as long as it more or less looks like the mockup, I don't care beyond that"). Recorded in epic-orchestrator memory.
