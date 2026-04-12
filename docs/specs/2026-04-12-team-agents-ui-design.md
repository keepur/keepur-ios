# Team Agents UI — Design Spec

**Date:** 2026-04-12
**Depends on:** [Team Layer iOS](2026-04-06-team-layer-ios-design.md) (implemented), Hive `agent_list` (server, #122)

## Problem

The Team tab has a working channel/DM sidebar and chat view, but no way to discover agents or initiate conversations with them. Users must know agent names and type `/dm agent-name` manually. The `agent_list` WebSocket response already delivers rich agent metadata (status, model, tools, schedule, channels) but it's only used for Whisper vocabulary — the UI ignores it entirely.

## Solution

Three additions to the Team tab:

1. **Agents section in the sidebar** — lists all agents below the existing DMs and Channels sections. Tap an agent to open (or create) a DM with them.
2. **DM auto-creation** — tapping an agent checks for an existing DM channel locally; if none, sends `/dm agent-name` under the hood and navigates once the channel appears.
3. **Agent detail card** — a half-screen sheet accessible from an info button in the DM chat nav bar. Read-only: shows agent status, model, tools, schedule, channels, message count, last activity.

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Agent list location | Third sidebar section below DMs + Channels | Discovery without disrupting active conversations |
| Tap agent behavior | Open existing DM or create via `/dm` | Reuses existing server command, no new protocol |
| Agent detail | Read-only sheet | Server has no agent config API; YAGNI |
| Detail trigger | Info button in DM nav bar | Accessible in context, doesn't clutter sidebar rows |
| Sheet style | Half-screen `.presentationDetents([.medium, .large])` | Quick glance, swipe to dismiss, expand if needed |

## Data Flow

### Published State Changes (TeamViewModel)

```swift
// NEW — expose agents to the UI
@Published var agents: [TeamAgentInfo] = []
```

The existing `handleIncoming(.agentList)` case already receives `[TeamAgentInfo]`. Change it to also publish:

```swift
case .agentList(let agents, _):
    self.agents = agents              // NEW: publish for UI
    agentNames = agents.map(\.name)   // existing: Whisper vocab
    rebuildWhisperPrompt()
```

No new SwiftData model. `TeamAgentInfo` is a transient struct refreshed on every connect — no persistence needed.

### DM Lookup + Creation (TeamViewModel)

New method:

```swift
func openAgentDM(agent: TeamAgentInfo)
```

**ID matching note:** The parent spec (line 120) states `agentName = agentId` — the server uses the same string for both. `TeamAgentInfo.id` (e.g. `"production-support"`) is the same string that appears in `TeamChannel.members`. DM channel IDs follow the format `"dm:<sorted>:<sorted>"` where the sorted values are agent/device IDs from `members`. So `members.contains(agent.id)` is a reliable lookup.

Flow:
1. Search `channels` for an existing DM where `type == "dm"` and `members.contains(agent.id)`.
2. **Found** → `selectChannel(dm.id)`. Done.
3. **Not found** → send the `/dm` command directly via `ws.sendWithId(.command(...))` — do NOT route through `sendSlashCommand`, which requires a `channelId` parameter that comes from `activeChannelId` (and `activeChannelId` may be nil when the user hasn't selected any channel yet). Build the outgoing command inline: `.command(channelId: "", name: "dm", args: [agent.name])`. The server's `/dm` handler creates a new channel and ignores the source `channelId`. Track the request ID in `pendingNewCommands` only (for auto-refreshing channels via `fetchChannels()`). Do NOT track in `pendingCommandChannels` — the system response to `/dm` is a confirmation message (e.g. "DM created") that doesn't need to be displayed when initiated from `openAgentDM`. If tracked in `pendingCommandChannels` with `channelId: ""`, the system response handler would try to create a `TeamMessage` with an empty `channelId`, polluting the data store. Also store the request ID in a new `private var pendingDMRequestId: String?` so the `systemMessage` handler can detect `/dm` failures (see error handling below). If `ws.sendWithId` returns `nil` (WS disconnected), do nothing — the agent row tap is a no-op while offline. Consider showing a brief toast or disabling agent rows when `ws.isConnected == false`.
4. After channel refresh, find the new DM by agent ID in members and `selectChannel(dm.id)`.

**Auto-select after creation:** The tricky part is step 4 — the new channel appears asynchronously after the `channelList` response. Add two private tracking vars:
- `private var pendingAgentDM: String?` — agent ID to auto-select after channel refresh
- `private var pendingDMRequestId: String?` — request UUID of the `/dm` command, used to detect and suppress the system response

When `pendingAgentDM` is set, `syncChannels()` checks for a DM containing that agent and auto-selects it, then clears both `pendingAgentDM` and `pendingDMRequestId`.

**Error handling:** The `/dm` command can fail in two ways: (a) a `systemMessage` whose `replyTo` matches `pendingDMRequestId` — this is a command error response (e.g. "agent not found", "DM already exists"); (b) a WS `error` message. For WS `error`, clear both `pendingAgentDM` and `pendingDMRequestId` unconditionally. If a reconnect occurs while `pendingAgentDM` is set, clear both in `onConnected()` to prevent stale auto-navigation. No timeout needed — the server responds quickly.

**Ordering in `systemMessage` handler:** When a `systemMessage` arrives with a `replyTo`, the existing handler already checks `pendingNewCommands` and `pendingCommandChannels`. For the `/dm`-from-`openAgentDM` flow, the handler must process in this order:
1. Check `pendingCommandChannels` (will NOT match — we intentionally don't track there).
2. Check `pendingNewCommands` — if `replyTo` matches, remove it and call `fetchChannels()`. This MUST happen to trigger the channel refresh that leads to auto-select.
3. Check `pendingDMRequestId` — if `replyTo` matches, clear both `pendingAgentDM` and `pendingDMRequestId`, then **skip** inserting a `TeamMessage` (return early). The navigation itself is the user feedback; no need to display "DM created".

The key constraint: step 2 (triggering `fetchChannels`) must happen BEFORE step 3 (dropping the message). If the `/dm` failed, `fetchChannels()` still fires (harmless — it just refreshes the existing list) and `syncChannels()` won't find a matching DM so `pendingAgentDM` stays set — but step 3 clears it, so the pending state is cleaned up either way.

**Empty channelId for `/dm` command:** The outgoing wire format includes `channelId: ""`. The server's command handler uses `channelId` only for channel-scoped commands (like `/rename`). For `/dm`, the server creates a new channel and does not reference the source `channelId`. Sending an empty string is safe.

## View Changes

### TeamSidebarView — New Agents Section

Add a third section below Channels:

```
Section: "Direct Messages"
  └── DMRow (existing)
Section: "Channels"
  └── ChannelRow (existing)
Section: "Agents"                    ← NEW
  └── AgentRow (icon, name, status dot)
```

**AgentRow** shows:
- Agent icon (emoji from `TeamAgentInfo.icon`; if empty string or missing, fallback to `🤖`)
- Agent name
- Status indicator dot (green = idle, yellow = processing, red = error/stopped)
- Subtitle: agent title if non-nil and non-empty, otherwise model name; hide subtitle line entirely if both are empty/nil

Tapping an `AgentRow` calls `viewModel.openAgentDM(agent:)`.

**Empty state:** Hide the Agents section entirely when `viewModel.agents` is empty (same pattern as the existing DMs/Channels sections). On first connect, there's a brief window before `agent_list` arrives — this is fine, the section appears once data arrives.

### TeamChatView — Info Button

Add a toolbar button to the nav bar when the active channel is a DM with an agent:

```swift
.toolbar {
    ToolbarItem(placement: .topBarTrailing) {
        if isDMWithAgent {
            Button { showAgentDetail = true } label: {
                Image(systemName: "info.circle")
            }
        }
    }
}
.sheet(isPresented: $showAgentDetail) {
    AgentDetailSheet(agent: activeAgent)
        .presentationDetents([.medium, .large])
}
```

**Detecting DM-with-agent:** Add two computed properties to `TeamChatView`:

```swift
private var activeAgent: TeamAgentInfo? {
    guard let channelId = viewModel.activeChannelId,
          let channel = viewModel.channels.first(where: { $0.id == channelId }),
          channel.type == "dm" else { return nil }
    return viewModel.agents.first { channel.members.contains($0.id) }
}

private var isDMWithAgent: Bool { activeAgent != nil }
```

Match the active channel's members against `viewModel.agents` by checking if any agent's `id` is in the channel's `members` list. Uses the same `agent.id == members` string matching as the DM lookup (see ID matching note above). If `viewModel.agents` is transiently empty (e.g. during reconnect before `agent_list` arrives), the info button simply doesn't appear — it will reappear once agents are loaded. This is acceptable; no loading state needed.

### AgentDetailSheet — New View

Read-only card showing agent metadata. Layout:

```
┌─────────────────────────────┐
│  🤖  production-support     │
│  ● idle                     │
│                             │
│  Title    Prod Support Lead │
│  Model    claude-sonnet-4-20250514     │
│  Messages 142               │
│  Last Active  2h ago        │
│                             │
│  ─── Tools ───              │
│  read_file, grep, bash      │
│                             │
│  ─── Schedule ───           │
│  daily 9am — triage inbox   │
│                             │
│  ─── Channels ───           │
│  #general, #ops             │
└─────────────────────────────┘
```

Sections:
- **Header:** Icon (large, emoji or `🤖` fallback), name, status with colored dot
- **Info grid:** Title, model, message count, last activity (parse `lastActivity` ISO 8601 string → `Date` using `ISO8601DateFormatter` with `.withInternetDateTime, .withFractionalSeconds` — same format options used in `TeamWSIncoming.decode`; display with `Text(date, style: .relative)`; if `lastActivity` is nil or parsing fails, show "Never")
- **Tools:** Horizontal flow or comma list
- **Schedule:** Each cron entry as a row (cron expression + task description); hide section if empty
- **Channels:** List of channel names the agent is in (values from `TeamAgentInfo.channels` are IDs like `"general"` — prepend `#` for display); hide section if empty

## File Map

| Area | File | Change |
|------|------|--------|
| ViewModel | `ViewModels/TeamViewModel.swift` | Add `@Published var agents`, `openAgentDM()`, `pendingAgentDM` + `pendingDMRequestId` auto-select, suppress `/dm` system response |
| Sidebar | `Views/Team/TeamSidebarView.swift` | Add Agents section with `AgentRow` |
| Chat | `Views/Team/TeamChatView.swift` | Add info button in toolbar, sheet binding |
| New view | `Views/Team/AgentRow.swift` | Agent sidebar row component |
| New view | `Views/Team/AgentDetailSheet.swift` | Read-only agent info sheet |

## What We're NOT Building

- **Agent editing/config** — server has no write API for agents
- **Agent creation** — handled in Beekeeper/CLI
- **Online/offline presence** — agents are always "on"; status from `agent_list` is sufficient
- **Agent search/filter** — not needed at current team sizes (< 20 agents)
- **Agent avatars** — use emoji icon from `agent_list`, no image uploads

## Build Sequence

Single phase — small scope, all pieces depend on each other:

1. `TeamViewModel` — publish `agents`, add `openAgentDM()` with `pendingAgentDM` auto-select
2. `AgentRow` — sidebar row component
3. `TeamSidebarView` — add Agents section
4. `AgentDetailSheet` — read-only info card
5. `TeamChatView` — add info button + sheet presentation
