# Hive Agent List — Design Spec

**Date**: 2026-04-16
**Status**: Draft

## Problem

The Hive landing screen has three sidebar sections (Direct Messages, Channels, Agents) that create redundant navigation. Tapping an agent under "Agents" finds/creates a DM — the same destination as tapping a DM row. Users see the same agent in two places. The Channels section is unused.

## Solution

Replace the three-section sidebar with a single flat list of agents. Tapping an agent opens the conversation. If the server reports a stale session, silently start a new one.

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Sidebar sections | Single flat agent list | DMs and Agents sections are redundant destinations |
| Channels section | Removed | Not needed for current usage |
| Agent emoji icon | Removed | Renders as broken characters, not images |
| Agent row content | Name + status dot + last message preview + time | Merge useful info from ChannelRow into AgentRow |
| Sort order | Last message time desc, then agent name A-Z | Recent conversations float up; tiebreaker is alphabetical |
| Agents with no conversation | Shown at bottom | All agents always visible for discoverability |
| Stale session handling | Catch server error → create new session → retry send | No UI disruption; user never notices |

## Changes

### 1. TeamSidebarView — Single Agent List

Remove the `Section("Direct Messages")`, `Section("Channels")`, and `Section("Agents")` structure. Replace with a single `ForEach` over `viewModel.sortedAgents`.

Remove `ChannelRow` entirely — it's no longer needed. Remove `dmChannels` and `groupChannels` computed properties.

Remove the `List(selection:)` binding pattern entirely. Instead, use a plain `List` with `Button` rows. Each row is a `Button` that calls `viewModel.openAgentDM(agent:)` on tap. The active/selected state is driven by comparing `agent`'s DM channel ID to `viewModel.activeChannelId` — passed as the `isActive` parameter to `AgentRow`.

Rationale: The old `List(selection:)` + `.tag()` pattern doesn't work cleanly for agents with no DM (no channel ID to tag), and `.onTapGesture` on untagged rows inside a selection-bound `List` is unreliable on macOS. A `Button`-based approach avoids both issues and keeps tap handling consistent across all rows regardless of DM existence.

Update the empty-state overlay condition from `viewModel.channels.isEmpty && viewModel.agents.isEmpty` to just `viewModel.agents.isEmpty`. Change the label from "No Channels" / "Connecting to Team..." to "No Agents" / "Connecting to Hive...".

### 2. AgentRow — Enriched, No Emoji

Remove the emoji `iconText` display and the inline status dot from the name `HStack`. Replace both with a single leading status-colored circle (reuse existing `statusColor` logic). The dot moves from inline-after-name to the leading container position — there is only one dot.

Add two new optional fields from the agent's DM channel:
- `lastMessage: String?` — preview text (100 chars, from `TeamChannel.lastMessageText`)
- `lastMessageAt: Date?` — relative time stamp

The leading status dot uses a 36x36 container (matching the old ChannelRow icon area) with a centered 10pt filled circle, colored by `statusColor`. The dot is intentionally sized larger than the existing 8pt inline dot because it occupies a prominent leading position rather than sitting next to the name.

Layout becomes:
```
[  (dot)  ]  Agent Name
             Last message preview...        2m ago
  36x36
```

New initializer signature:
```swift
AgentRow(agent: TeamAgentInfo, dmChannel: TeamChannel?, isActive: Bool)
```

`AgentRow` reads `dmChannel?.lastMessageText` and `dmChannel?.lastMessageAt` directly. The `subtitle` computed property (title/model) is reused unchanged; only the `body` render logic changes to pick `lastMessage ?? subtitle` for the second line. The `isActive` bolding behavior on the name label (`fontWeight(isActive ? .semibold : .regular)`) is preserved as-is.

The relative time stamp uses `Text(lastAt, style: .relative)`, mirroring the existing `ChannelRow` at `TeamSidebarView.swift:104`.

When no conversation exists yet:
```
[  (dot)  ]  Agent Name
             claude-sonnet-4-5
  36x36
```

### 3. TeamViewModel — Sorted Agent List + DM Lookup

Add a `@Published` property that merges agent info with DM channel data and sorts:

```swift
@Published var sortedAgents: [(agent: TeamAgentInfo, dmChannel: TeamChannel?)] = []
```

**Sort**: `dmChannel?.lastMessageAt` descending (nil sorts last), then `agent.name` ascending.

**DM lookup**: For each agent, find `channels.first { $0.type == "dm" && $0.members.contains(agent.id) }`. This predicate intentionally matches the existing predicate in `openAgentDM(agent:)` (`TeamViewModel.swift:277`) and the existing DM-creation path (`TeamViewModel.swift:445`) — sidebar display and DM navigation stay consistent by using the same lookup rule.

**Important**: This must be a `@Published` stored property, not a computed property. `agents` and `channels` are populated independently by separate WS responses (`agent_list` and `channel_list`) that arrive in unpredictable order. A computed property derived from both wouldn't trigger SwiftUI updates correctly.

Add a private `recomputeSortedAgents()` method, called from:
- End of `loadChannels(context:)` (after `channels` updates)
- End of the `.agentList` handler (after `self.agents` is set)
- End of `updateChannelPreview(...)` — must be called **after** the existing `channels.sort` line so that `recomputeSortedAgents()` reads from the already-updated and sorted `channels` array

The existing `openAgentDM(agent:)` method is unchanged — it already handles both "DM exists" and "DM needs creation" cases.

### 4. Stale Session Recovery

When the server returns an error indicating a session/thread cannot be found:

In `handleIncoming(.error(let message))`:
1. Check if the error message indicates a stale/missing session (exact server error string TBD — must be confirmed from server source or manual testing before implementation)
2. If stale and there's an `activeChannelId`:
   - Send a `/new` command to the active channel to start a fresh session
   - Keep existing messages on screen (no clear)
   - Find any pending messages (local messages with `pending: true`) for the active channel. After the `/new` command succeeds (correlated via `pendingNewCommands` + `systemMessage` reply), automatically resend them so the user's message isn't silently lost
   - Guard against retry loops: only attempt stale recovery once per channel per error. If the resend also triggers an error, log it and stop — don't loop
3. If not a stale-session error, keep current behavior (log and clear pending state)

**Prerequisite**: The exact server error string for stale sessions must be confirmed before this feature can be implemented. If the server doesn't yet distinguish stale-session errors from other errors, this section is deferred.

This is intentionally simple — we only react to server errors, no client-side timers or thresholds.

### 5. TeamRootView — Update Empty State

Update the detail pane `ContentUnavailableView`:
- Label: "Select a conversation" → "Select an agent"
- Description: "Choose a channel or DM from the sidebar" → "Choose an agent to start a conversation"
- System image: keep `bubble.left.and.bubble.right` (still appropriate)

### 6. Cleanup

- Remove `ChannelRow` struct from `TeamSidebarView.swift`
- Remove `dmChannels` and `groupChannels` computed properties from `TeamSidebarView`
- Keep `displayName(for:)` in TeamViewModel — it's still used by `TeamChatView.swift:28` for the nav bar title. The other two callsites (`TeamSidebarView.swift:26,39`) disappear with `ChannelRow` removal.

## Files Changed

| File | Change |
|------|--------|
| `Views/Team/TeamSidebarView.swift` | Replace 3 sections with single agent list; delete `ChannelRow` |
| `Views/Team/AgentRow.swift` | Remove emoji, add last message preview + time |
| `ViewModels/TeamViewModel.swift` | Add sorted agent+DM list; stale session recovery in error handler |
| `Views/Team/TeamRootView.swift` | Update empty state text |

## Out of Scope

- Group channels UI (removed for now, can be re-added later)
- Typing indicators
- Unread message counts/badges
- Agent profile photos/avatars (no server support yet)
