# KPR-150 — design v2: Hive sidebar agent rows (square avatars + corner status)

**Date:** 2026-05-02
**Epic:** [KPR-142 design v2](https://linear.app/keepur/issue/KPR-142)
**Layer:** 3 (per-screen consumption)
**Depends on:** KPR-144 (foundation atoms — `KeepurAvatar`, `KeepurUnreadBadge`)

## Problem

The Hive sidebar (`Views/Team/TeamSidebarView.swift` + `Views/Team/AgentRow.swift`) renders each agent as a small 36pt frame containing a 10pt status dot, plus a name + subtitle and an optional trailing relative time. The design v2 mockups elevate this row to:

- A 56pt square rounded `KeepurAvatar` with a letter and a corner status overlay (replacing the dot-in-frame).
- A real hive name in the sidebar title (currently always falls back to the literal string `"Hive"` when `selectedHive` is nil).
- A trailing slot for a `KeepurUnreadBadge` placeholder so the layout is final even though the actual unread count won't ship until the held-feature ticket lands.

The foundation atoms from KPR-144 are already on the epic branch, so this ticket is straightforward consumption — the visual primitives exist, this swaps them in and reorganizes the row layout.

## Solution

Three small changes, all in `Views/Team/`:

1. **`AgentRow.swift`** — replace the leading 36pt status-dot frame with a 56pt `KeepurAvatar(content: .letter(agent.name), statusOverlay: <mapped tint>)`. Add a trailing `KeepurUnreadBadge(count: 0)` placeholder slot adjacent to (or replacing position of) the existing relative time.
2. **`TeamSidebarView.swift`** — keep the title source-of-truth in `TeamRootView` (the `.navigationTitle(...)` already pulls from `capabilityManager.selectedHive ?? "Hive"`); change the fallback so it reads as a real placeholder rather than the literal word "Hive". Per the backlog, the title should be the actual hive name (e.g., `"hive-dodi"`) — this is already wired correctly through `selectedHive`; the fallback string just gets a small refinement.
3. No change to `TeamRootView.swift` other than the fallback string above (the tab-bar visibility wiring stays untouched per task constraints).

The unread-count plumbing is explicitly out of scope. The placeholder badge exists so the row layout is finalized; it renders as `EmptyView()` for now (KPR-144's `KeepurUnreadBadge` returns `EmptyView` when `count <= 0`), so the slot is invisible until the held feature wires it.

## Key Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Avatar size | `56pt` | Matches mockup ("~56pt"); also the `KeepurAvatar` default — no override needed |
| Avatar content | `.letter(agent.name)` | Letter content uppercases first char internally; emoji content path exists but `agent.icon` is currently a free-form string with no guarantee it's an emoji, and the mockups show letters. Emoji path can be opted into later if `agent.icon` semantics tighten |
| Avatar background | Default (`wax100`) | Mockup shows wax-toned tiles uniformly across agents; no reason to per-agent tint |
| Status mapping | `idle → .success`, `processing → .warning`, `error/stopped → .danger`, default → `.muted` | Mirrors the existing `statusColor` switch in `AgentRow`; keeps semantic continuity for users who learned the old dot color |
| Status overlay always present | Yes (always pass non-nil tint) | The dot today is unconditional; preserve that — `default → .muted` keeps a visible state for unknown statuses |
| Unread badge slot position | Trailing, after the relative time | Mockup shows time then badge; `KeepurUnreadBadge` collapses to `EmptyView` when count is 0 so this slot is invisible until wired |
| Unread badge wiring | `KeepurUnreadBadge(count: 0)` literal | Out-of-scope per backlog; literal `0` makes the placeholder trivially obvious to remove when the feature ticket lands. No new prop on `AgentRow` |
| Hive title fallback | Keep `selectedHive ?? "Hive"` in `TeamRootView` (do not touch) | Backlog calls out the *current* fallback as wrong-feeling but the actual title source is `selectedHive`; when a hive is selected the title is correct already. Out of scope to change `TeamRootView` per task constraints |
| Subtitle / `secondLineText` | Preserved as-is | Backlog scope is avatar + title + time + badge slot; the existing DM-preview-or-subtitle line is correct and untouched |
| Row vertical alignment | `.center` (HStack default) | 56pt avatar is taller than the two-line text stack; centering reads cleanly. Mockup confirms |
| Row vertical padding | Bump from `2` → `KeepurTheme.Spacing.s2` (8pt) | The taller avatar needs proportionally more breathing room; matches sidebar tile feel |
| Spacing between avatar and text | `KeepurTheme.Spacing.s3` (existing) | No change; spec already correct |

## Visual Spec

### AgentRow (after)

```
┌─────────────────────────────────────────────────────────────┐
│  ┌────────┐                                                  │
│  │        │  Agent Name                          12m  [9+]   │
│  │   M ●  │  agent title or last DM preview                  │
│  │        │                                                  │
│  └────────┘                                                  │
└─────────────────────────────────────────────────────────────┘
   56pt        body / caption                  caption / badge
```

- **Leading:** `KeepurAvatar(size: 56, content: .letter(agent.name), statusOverlay: tint)`. The status overlay is the bottom-right circle on the avatar tile (rendered by `KeepurAvatar` itself — not a sibling element).
- **Center (`VStack`):** unchanged. `agent.name` in body weight (semibold when `isActive`), `secondLineText` in caption tone.
- **Trailing (`HStack`):** existing `Text(lastAt, style: .relative)` then `KeepurUnreadBadge(count: 0)`. Both wrapped in a small horizontal `HStack` with `Spacing.s2` between time and badge so the relative position is consistent regardless of whether the time is present.

### TeamSidebarView

No structural change. Continues to host `List(selection:)` over `viewModel.sortedAgents`. List style remains `.sidebar` so iOS renders an inset grouped feel and macOS gets sidebar treatment.

### Title

Continues to come from `TeamRootView.navigationTitle(capabilityManager.selectedHive ?? "Hive")`. **Not modified** — when a hive is selected the displayed title is already the real hive name (e.g., `"hive-dodi"`). The backlog line "Title becomes the actual hive name" is already accurate post-pairing; this ticket asserts the wiring is correct via a smoke read but does not edit `TeamRootView`.

## Status Mapping

Pulled into a private extension on `AgentRow` (replaces the existing `statusColor` computed property):

```swift
private extension AgentRow {
    var statusTint: KeepurStatusPill.Tint {
        switch agent.status {
        case "idle": return .success
        case "processing": return .warning
        case "error", "stopped": return .danger
        default: return .muted
        }
    }
}
```

This deletes the old `statusColor: Color` accessor — the `KeepurAvatar.statusOverlay` parameter takes a `KeepurStatusPill.Tint`, not a `Color`, so the indirection is necessary anyway.

## Letter Source

`agent.name` (the same string already shown beneath as the row title). `KeepurAvatar.Content.letter(_:)` uppercases the first character internally, so passing the full name is correct and idiomatic — no `.first.map(String.init)` ceremony at the call site.

Edge case: if `agent.name` is empty (defensively), `KeepurAvatar` renders `"?"` per its own contract.

## Smoke Test Scope

Single test file covering the shape of the new `AgentRow`:

| Test | Assertion |
|---|---|
| `testRowInstantiatesWithAndWithoutDM` | Build an `AgentRow` with `dmChannel: nil` and one with a populated `dmChannel`; verify `_ = view.body` doesn't crash |
| `testStatusTintMapping` | For each `agent.status` value (`"idle"`, `"processing"`, `"error"`, `"stopped"`, `"unknown"`), build an `AgentRow` and assert it instantiates without crash. (We can't read the private `statusTint` directly without making it internal; this is a smoke test, not a behavioral assertion.) |
| `testEmptyAgentNameRenders` | Build an `AgentRow` with an empty `agent.name`; verify body doesn't crash (covers the "?" fallback in avatar) |

We do **not** smoke-test `TeamSidebarView` directly — it depends on `TeamViewModel` which depends on `WebSocketManager` which depends on `KeychainManager`. Per the task constraint ("Don't smoke-test full View bodies that depend on @StateObject/Keychain"), we keep tests scoped to `AgentRow`.

A `TeamAgentInfo` test fixture is needed (factory function in the test file). `TeamChannel` is a SwiftData `@Model` — instantiation needs a `ModelContainer` only if SwiftData is touched, which we avoid by passing `dmChannel: nil` for most cases and a manually-constructed `TeamChannel` for the with-DM case (the model's init takes plain values, no context required to construct in memory).

## Out of Scope

- **Real unread count** — held feature ticket (per-channel `unreadCount` tracking on `TeamChannel`). This ticket only ships the placeholder slot wired to literal `0`.
- **`TeamRootView` changes** — title wiring is already correct via `selectedHive`; tab-bar visibility wiring stays per task constraint.
- **`AgentRow` second-line redesign** — DM-preview-or-subtitle behavior preserved as-is; out of scope.
- **Selection styling refinement** — `isActive` driven semibold weight kept identical.
- **Accessibility audit beyond what `KeepurAvatar` already provides** — covered when the held-feature unread ticket lands and there's a real count to label.
- **Emoji content path** — `agent.icon` semantics are unconstrained; ignoring it for now is consistent with the existing implementation, which also doesn't use it.

## Open Questions

None. The backlog scope is precise, the foundation atoms exist, and the `AgentRow` data inputs (`agent`, `dmChannel`, `isActive`) are unchanged.

## Files Touched

- `Views/Team/AgentRow.swift` (modified — body restructure + `statusTint` replaces `statusColor`)
- `KeeperTests/AgentRowTests.swift` (new — three smoke tests)
- `Keepur.xcodeproj/project.pbxproj` (wire new test file into iOS + macOS test targets)

`Views/Team/TeamSidebarView.swift` and `Views/Team/TeamRootView.swift` are **not** modified.

## Dependencies / Sequencing

- **Blocks:** none directly (KPR-150 is a leaf consumer)
- **Blocked by:** KPR-144 (foundation atoms — already merged on epic branch per task context)
- Can run in parallel with all other Layer 3 tickets (KPR-148 sessions row, KPR-151 agent detail, KPR-155 team bubble polish, etc.)

## Human Signoff

Pre-approved per durable user delegation (KPR-142 design v2 epic — mockups already approve component intent; user explicit: "as long as it more or less looks like the mockup, I don't care beyond that"). Recorded in epic-orchestrator memory.
