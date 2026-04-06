# Team Layer iOS — Design Spec

**Date:** 2026-04-06
**Depends on:** [Hive Team Layer](../../../hive/docs/specs/2026-04-06-team-layer-design.md) (server, merged as PR #100)

## Problem

Hive shipped a native Team messaging platform — channels, DMs, slash commands, @mentions — served over WebSocket. Keepur iOS has zero awareness of it. The app only speaks Beekeeper protocol (code sessions, tool approvals, streaming). We need to build a complete Team client as a second product within the same app shell.

## Solution

Add a **Team tab** to Keepur iOS — a Slack-style messaging interface backed by the Hive Team layer. Beekeeper and Team are treated as two separate products sharing an app shell with a tab bar. They have separate WebSocket connections (different hosts/ports), separate ViewModels, and separate SwiftData models.

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Navigation | Tab bar (Team + Beekeeper) | Clean separation, familiar iOS pattern |
| WebSocket | Two separate connections | Different hosts/ports, independent lifecycles |
| ViewModel | Separate `TeamViewModel` | Zero shared state with Beekeeper; different interaction model |
| Data models | New `TeamChannel` + `TeamMessage` | Different shapes from `Session`/`Message`; no pollution |
| Landing screen | Slack-style sidebar — DMs + Channels sections | Familiar UX, proven pattern |
| Slash commands | Raw text, no autocomplete (v1) | Server handles parsing; autocomplete is a future enhancement |
| Philosophy | Two separate products, one app | Stops us from over-coupling things that don't belong together |

## Data Model

### SwiftData Models

**`TeamChannel`**

```swift
@Model final class TeamChannel {
    @Attribute(.unique) var id: String       // "general", "dm:<sorted>:<sorted>"
    var type: String                          // "channel" or "dm"
    var name: String                          // "#general" or agent/person name
    var members: [String]                     // agent IDs + device IDs
    var lastMessageText: String?              // Preview text for sidebar (updated on incoming messages)
    var lastMessageAt: Date?                  // Sort sidebar by recency (updated on incoming messages)
    var lastServerMessageId: String?          // Most recent server ObjectId for history cursor / dedup
    var updatedAt: Date
}
```

**`TeamMessage`**

```swift
@Model final class TeamMessage {
    @Attribute(.unique) var id: String       // Server ObjectId or local UUID
    var channelId: String                     // FK to TeamChannel
    var threadId: String?                     // Reply threading
    var senderId: String                      // Agent ID or device ID
    var senderType: String                    // "agent" or "person"
    var senderName: String
    var text: String
    var createdAt: Date
    var pending: Bool                         // True until server acks
}
```

No file attachment model for v1 — file sending uses base64 over WS, file display is text-only (`[File: name.pdf]`). Rich file previews deferred.

**Note:** Server filters archived channels from `channel_list` responses. The iOS model omits `archived` and `createdBy` fields intentionally — they are not in the wire payload.

## WS Protocol (iOS Side)

### New Outgoing Messages

```swift
// Team-specific outgoing messages
// IMPORTANT: Wire encoding uses the server's type strings, not the Swift case names.
// e.g. teamMessage encodes to { "type": "message", "channelId": "...", ... }
// The channelId field is what distinguishes Team messages from legacy Beekeeper messages.
case teamMessage(channelId: String, text: String, threadId: String?)  // wire: "message" + channelId
case teamImage(channelId: String, data: String, filename: String)      // wire: "image" + channelId
case teamFile(channelId: String, data: String, filename: String, mimetype: String)  // wire: "file"
case join(channelId: String)           // wire: "join"
case leave(channelId: String)          // wire: "leave"
case command(channelId: String, name: String, args: [String])          // wire: "command"
case commandList                       // wire: "command_list"
case channelList                       // wire: "channel_list"
case history(channelId: String, before: String?, limit: Int?)          // wire: "history"
```

Each gets an `id` (UUID) for request/response correlation. The server echoes this `id` in responses.

### New Incoming Messages

```swift
// All response types carry an `id` field that echoes the request id for correlation.
case teamMessage(text: String, channelId: String, agentId: String, agentName: String, replyTo: String?)
case systemMessage(text: String, agentId: String, agentName: String, replyTo: String?)
case channelList(channels: [TeamChannelInfo], id: String)
case commandList(commands: [TeamCommandInfo], id: String)
case history(channelId: String, messages: [TeamHistoryMessage], hasMore: Bool, id: String)
case channelEvent(channelId: String, event: String, memberId: String?, id: String)
// Note: `memberId` is extracted from the wire payload's `detail` object during decoding.
// Wire format: { "detail": { "memberId": "device123" } } → decoder reads detail["memberId"] and
// surfaces it as the `memberId` associated value. The raw `detail` dict is not preserved.
case ack(id: String)
case typing(agentId: String)
case error(message: String)
```

**Routing note:** Since Team runs on a separate WS connection, all messages arriving on the Team socket are Team messages. No need to discriminate by `channelId` presence — that's only relevant if both protocols shared a connection.

**Command responses without channelId:** The server's `handleCommand()` sends results as `{ type: "message", text, agentId: "system", agentName: "system", replyTo }` — **without `channelId`**. This arrives on the Team socket but looks like a legacy message. The decoder must handle `type: "message"` without `channelId` as a valid Team message — treat it as a system/command response. Add a fallback incoming case: `case systemMessage(text: String, agentId: String, agentName: String, replyTo: String?)` for messages without `channelId`.

**Routing system messages by `replyTo`:** To display a command response in the correct channel, `TeamViewModel` must maintain a `private var pendingCommandChannels: [String: String] = [:]` mapping request UUID → channelId. Populate it when sending a `command(...)` outgoing message. On `systemMessage(replyTo:)` receipt, look up the channelId from this map, create a `TeamMessage` in that channel with `senderId: "system"`, and remove the entry. If `replyTo` is nil or not found in the map (edge case), display nothing — the command result was already saved server-side and will appear in history on next fetch.

**Dedup for system messages:** System/command messages received in real-time are stored locally with the request UUID as `id`. The server also persists the same result to `team_messages` with a MongoDB ObjectId. On history fetch, the server copy will have a different `id` than the local copy. To prevent duplicates: when storing a system message locally, set `senderId: "system"`. During history dedup (step 5 in the dedup flow), extend the skip logic to also cover `senderId == "system"` messages: skip any history message where a local message with matching `(channelId, senderId == "system", text)` already exists. This mirrors the device-message dedup logic.

**Streaming note:** Team messages are **not streamed**. Unlike Beekeeper (which sends chunks with `final: true/false` and the client assembles them), Team agent responses arrive as single complete messages. There is no `final` field on Team messages. The `teamMessage` incoming case represents a complete message — display it immediately on receipt.

**Field mapping when storing to SwiftData:** When storing a real-time `teamMessage` as a `TeamMessage` record:
- `agentId` → `senderId` (so history dedup step 3 can match on `senderId`)
- `agentName` → `senderName`
- `senderType` = `"agent"` (all real-time `teamMessage` responses are from agents)
- For `systemMessage`: `senderId` = `"system"`, `senderType` = `"agent"` (matches server's storage in `team_messages`)
- **Display name note:** The server currently sets `agentName = agentId` (e.g. `"production-support"`, not a human-friendly name). `senderName` in SwiftData will contain the agent identifier string. For v1, render as-is — a display-name lookup table or server-side fix is a future improvement.

**Triage double-bubble:** For channel messages (not DMs), the server's triage system may send a short acknowledgment ("On it!", "Sure...") as a separate `teamMessage` before the full agent response. This means a single user message in a channel can produce **two** agent bubbles — first the triage ack, then the real response. This is expected server behavior and v1 treats both as normal messages. Both are persisted server-side and will appear in history. Future improvement: the server could suppress triage acks for Team channels, or the client could detect and collapse them.

### Protocol File

New file: `Models/TeamWSMessage.swift` — completely separate from `WSMessage.swift`. No shared types. Each product owns its own protocol definition.

## WebSocket Connection

New `TeamWebSocketManager` — same patterns as existing `WebSocketManager` but connecting to the Hive Team endpoint:

- Separate host/port from Beekeeper
- Same auth pattern (JWT token in query string)
- Same reconnect logic (exponential backoff, max 30s)
- Same 30s ping interval
- Team WS URL hardcoded as compile-time constant (same pattern as Beekeeper)

### Connection Config

The Team WS endpoint is the **same host and port as the device/pairing API** — the Hive WS adapter serves both REST (pairing, device CRUD) and WebSocket upgrades on the same port. The iOS app already knows this host from pairing.

For v1: **hardcode the Team WS URL** as a compile-time constant, same as Beekeeper. The current app hardcodes `ws://beekeeper.dodihome.com` in `WebSocketManager` and `http://beekeeper.dodihome.com` in `APIManager`. Team will hardcode its own URL in `TeamWebSocketManager` — e.g. `ws://hive.dodihome.com:3100`. Both Beekeeper and Team endpoints are known at build time for this deployment. Making the URL configurable (via pairing response, settings, or Keychain) is a future improvement when multi-instance support matters.

## TeamViewModel

`@MainActor class TeamViewModel: ObservableObject`

### Published State

```swift
@Published var channels: [TeamChannel] = []         // From SwiftData query
@Published var activeChannelId: String?              // Currently viewing
@Published var activeMessages: [TeamMessage] = []    // Messages for active channel (fetched via FetchDescriptor)
@Published var isLoadingHistory: Bool = false         // Pagination in progress
@Published var hasMoreHistory: Bool = true            // Can scroll up for more
private var pendingCommandChannels: [String: String] = [:]  // requestId → channelId for command routing
private var deviceId: String = ""                     // Set from KeychainManager.deviceId at init; used in history dedup
```

### Key Methods

- `connect()` / `disconnect()` — manage Team WS lifecycle
- `fetchChannels()` — send `channel_list`, update SwiftData on response
- `fetchHistory(channelId:)` — paginated history, cursor-based (`before` param)
- `sendMessage(text:channelId:)` — optimistic local insert + WS send
- `sendCommand(name:args:channelId:)` — send slash command, track in `pendingCommandChannels`, auto-refresh channels after `/new` commands
- `joinChannel(channelId:)` / `leaveChannel(channelId:)` — only send `join` for channels NOT already in local SwiftData. The server returns an error (not a `channel_event`) if the device is already a member (`$addToSet` returns `modifiedCount == 0`) OR if the channel doesn't exist. If a `join` error arrives for a channel already in the local store, silently ignore it (likely "already a member"). If a `join` error arrives for a channel NOT in the local store, it means the channel was archived/deleted — no action needed. Known v1 gap: if a channel is archived server-side while still in the local SwiftData store, the local copy persists until the next `fetchChannels()` refresh.
- `handleIncoming(_ message:)` — route server messages to state updates

### Message Flow

1. User types and sends → create `TeamMessage` in SwiftData with local UUID as `id`, `pending: true`
2. Send via WS with the same UUID as the request `id`
3. On ack (server echoes the UUID) → set `pending: false`
4. Server agent response arrives as `teamMessage` → create new `TeamMessage` in SwiftData
5. On reconnect → `fetchHistory(channelId:, before: nil)` to fill gaps (best-effort — fetches the most recent page only, default ~50 messages. The server's history API has no `after` parameter, so there is no way to request "messages newer than X". If more than 50 messages arrived during a long disconnection, older messages in the gap are silently missed. Known v1 limitation — acceptable for the expected message volume.)

**Dedup on history fetch:** Two ID namespaces exist — messages received in real-time (user messages, agent messages, system messages) use local UUIDs, while server history uses MongoDB ObjectIds. They will never collide on `id`, which means a naive "skip if id exists" check will miss ALL duplicates. The dedup strategy must use content matching:

1. User sends a message → local UUID inserted, `pending: true`.
2. Server acks (echoes the UUID) → set `pending: false`. The local record is now **definitive**.
3. Agent response arrives in real-time → stored with a local UUID as `id` (server's `ServerTextMessage` has no `_id` field).
4. On reconnect, client calls `fetchHistory(channelId:, before: nil)` to get the latest page.
5. For each history message, apply dedup in order:
   - **ID match:** If a `TeamMessage` with this server ObjectId already exists in SwiftData → skip. (Covers messages previously imported from history.)
   - **User message match:** If `senderId == self.deviceId` AND a local message with matching `(channelId, text)` exists with `pending == false` AND `abs(localMessage.createdAt - historyMessage.createdAt) < 30s` → skip. (Local copy is authoritative after ack. The 30s window prevents false positives when the user sends the same text twice — e.g. "ok" — each message will only match its own time window.)
   - **Agent message match:** If `senderType == "agent"` AND a local message with matching `(channelId, senderId, text)` exists → skip. (Real-time copy stored with local UUID is the same message.)
   - **System message match:** If `senderId == "system"` AND a local message with matching `(channelId, senderId, text)` exists → skip. (Command result stored with local UUID.)
   - **Otherwise:** Insert as new `TeamMessage` with the server ObjectId as `id`.

**Why content matching?** Real-time messages (agent responses, system messages) arrive without a server `_id`. They are stored locally with UUIDs. History returns the same messages with MongoDB ObjectIds. There is no way to correlate the two by ID alone. Content matching by `(channelId, senderId, text)` is the only reliable approach. In the rare case of identical consecutive messages from the same sender, a duplicate may appear — this is preferable to dropping messages.

Each `TeamChannel` tracks `lastServerMessageId` — the most recent server ObjectId seen. **This is only updated from history responses**, not from real-time incoming messages — because the server's `ServerTextMessage` (real-time agent responses) does not include a message `_id` field. Only the `history` response carries per-message `id` values (MongoDB ObjectIds). The sidebar seeding fetch (`history(limit: 1)` per channel) establishes the initial cursor. Subsequent history fetches (scroll-up pagination, reconnect gap fill) advance it. Used as the `before` param for cursor-based pagination.

## View Hierarchy

```
KeepurApp
└── ContentView (TabView)
    ├── Tab: Team
    │   └── TeamRootView (NavigationSplitView)
    │       ├── Sidebar: TeamSidebarView
    │       │   ├── Section: "Direct Messages"
    │       │   │   └── DMRow (agent name, last message preview)
    │       │   └── Section: "Channels"
    │       │       └── ChannelRow (#name, last message preview)
    │       └── Detail: TeamChatView
    │           ├── Message list (LazyVStack, scroll up for history)
    │           ├── MessageBubble (reuse styling, different data source)
    │           └── Input bar (text field + send button)
    └── Tab: Beekeeper
        └── RootView (existing, unchanged)
```

### TeamSidebarView

- Sections for DMs and Channels, each sorted by `lastMessageAt` descending
- Each row shows: name, last message preview, optional unread indicator (future)
- Tap → sets `activeChannelId`, shows `TeamChatView` in detail pane
- Uses `NavigationSplitView` for iPad split-view support
- **Preview data:** `lastMessageText` and `lastMessageAt` are NOT in the `channel_list` wire response. They are populated locally: (1) on every incoming `teamMessage`, update the channel's `lastMessageText`/`lastMessageAt` in SwiftData, (2) after initial `channel_list` fetch, request `history(channelId:, before: nil, limit: 1)` per channel to seed previews. If a channel has zero messages, the server returns `{ messages: [], hasMore: false }` — this is a no-op, the channel's preview fields stay nil and the sidebar row shows just the channel name with no preview text. On a fresh install, previews will be empty until the seeding fetches complete.

### TeamChatView

- **Does NOT use `@Query`** — SwiftData's `@Query` macro does not support dynamic runtime predicates in SwiftUI. Instead, `TeamChatView` reads from `teamViewModel.activeMessages`, which is a `@Published` array. When `activeChannelId` changes, `TeamViewModel` runs a `FetchDescriptor<TeamMessage>` filtered by `channelId` and sorted by `createdAt` against `modelContext`, and publishes the result to `activeMessages`. On incoming messages: persist to SwiftData first, then **re-run the FetchDescriptor** to rebuild `activeMessages` (do NOT append directly — this avoids race conditions between fetches and live message arrivals, and guarantees correct sort order and dedup). This is the same pattern as a SwiftUI `@Query` refresh but driven manually.
- Scroll to bottom on new messages
- Scroll up triggers `fetchHistory()` when near top (pagination)
- Input bar: text field + send button (voice button reuse if applicable)
- Pending messages show subtle "sending..." indicator
- Agent messages styled like existing assistant bubbles (MarkdownUI)
- User messages styled like existing user bubbles

### Reusable Components

- `MessageBubble` styling can be shared, but the data source is different (`TeamMessage` vs `Message`). Extract bubble styling into a shared component or duplicate with minimal code.
- Voice input (`VoiceButton`) can be reused as-is — it just produces text.
- `SpeechManager` for read-aloud can be reused.

## App Entry Changes

### KeepurApp.swift

- Add `TeamChannel` and `TeamMessage` to the SwiftData schema
- Wrap root view in `TabView` instead of directly showing `RootView`

### Auth Gate

Currently, `RootView` owns `isAuthenticated` via `ChatViewModel`. With two tabs and two ViewModels, auth state needs to be shared. Lift the "is paired" check to the `ContentView` level:

- `ContentView` checks `KeychainManager.isPaired` — if false, shows `PairingView` (no tabs)
- If paired, shows `TabView` with both tabs
- Each tab's ViewModel manages its own WS connection independently
- `ChatViewModel.isAuthenticated` remains for Beekeeper-specific validation (token check on connect)
- `TeamViewModel` does its own token validation on Team WS connect

### RootView Changes

- Existing `RootView` becomes the Beekeeper tab content — auth gate logic moves up to `ContentView`
- New `TeamRootView` is the Team tab content

## What We're NOT Building (v1)

- **Slash command autocomplete** — just send raw text
- **File previews / document picker** — server supports it, but we defer rich file UI
- **@mention autocomplete** — type `@name` as raw text, server parses
- **Channel creation UI** — use DMs to existing agents; channel CRUD via slash commands (`/new`). After sending a `/new` command, `sendCommand()` automatically calls `fetchChannels()` to refresh the sidebar so the new channel/DM appears.
- **Unread counts / badges** — deferred, needs server-side read tracking
- **Push notifications** — existing WS reconnect + pending drain pattern works
- **Threads** — flat message list per channel for v1; threading UI deferred
- **Typing indicators in Team** — server sends them, but we can defer showing them
- **Rich agent presence** — agents are always online
- **Message search** — deferred
- **Real-time channel discovery** — the server does NOT push `channel_event { event: "created" }` when channels are created externally. If another device or agent creates a channel, this client won't see it until the next `channel_list` refresh (triggered by `/new`, reconnect, or app foreground). Known v1 limitation. Future: server should push `"created"` events on `TeamStore.createChannel()`.

## Channel Event Handling

When `channelEvent` arrives, `TeamViewModel` should:
- `event: "joined"` — if `memberId` is self, call `fetchChannels()` to refresh sidebar. Otherwise, update local member list.
- `event: "left"` — if `memberId` is self, remove channel from local SwiftData. Otherwise, update local member list.
- `event: "created"` — call `fetchChannels()` to refresh sidebar. (Note: server does not currently emit this, but handle it for forward compatibility.)
- `event: "archived"` — remove channel from local SwiftData sidebar.

## File Map

| Area | File | What |
|------|------|------|
| App entry | `KeepurApp.swift` | Add Team models to schema |
| Navigation | `Views/ContentView.swift` (new) | TabView with Team + Beekeeper tabs |
| Team protocol | `Models/TeamWSMessage.swift` (new) | Team WS outgoing/incoming enums |
| Team models | `Models/TeamChannel.swift` (new) | SwiftData channel model |
| Team models | `Models/TeamMessage.swift` (new) | SwiftData message model |
| Team WS | `Managers/TeamWebSocketManager.swift` (new) | Team WS connection manager |
| Team VM | `ViewModels/TeamViewModel.swift` (new) | Team state management |
| Team views | `Views/Team/TeamRootView.swift` (new) | NavigationSplitView container |
| Team views | `Views/Team/TeamSidebarView.swift` (new) | Channel/DM list sidebar |
| Team views | `Views/Team/TeamChatView.swift` (new) | Channel message view |
| Team views | `Views/Team/TeamMessageBubble.swift` (new) | Message bubble for team messages |
| Existing | `Views/RootView.swift` | Minor: becomes Beekeeper tab content |
| Existing | `Managers/KeychainManager.swift` | No changes — Team WS URL is hardcoded, auth uses existing device JWT |

## SwiftData Migration

Adding `TeamChannel` and `TeamMessage` to the schema is an **additive-only** change — SwiftData handles this via automatic lightweight migration (new tables added to existing store). No manual migration needed.

**Caution:** The existing `KeepurApp.swift` has a crash-and-wipe recovery pattern — if `ModelContainer` init fails, it deletes the entire store and recreates from scratch. This means:
- Only additive schema changes are safe alongside this pattern
- Do NOT modify existing models (`Session`, `Message`, `Workspace`) in the same commit that adds Team models
- If automatic migration fails for any reason, all Beekeeper history is wiped

## NavigationSplitView Behavior

`TeamRootView` uses `NavigationSplitView`:
- **iPhone (compact):** Collapses to a stack automatically — sidebar shows as a list, tapping a channel pushes `TeamChatView`. Standard iOS behavior, no special handling needed.
- **iPad (regular):** Shows sidebar + detail side-by-side. Use `NavigationSplitView(columnVisibility:)` with a binding. When no channel is selected, show a placeholder view ("Select a conversation") in the detail pane.
- Style: `.navigationSplitViewStyle(.balanced)` on iPad, `.automatic` (default stack) on iPhone.

## Auth Failure Policy

Each WS connection handles auth failures independently:
- **Beekeeper 401:** Existing behavior — calls `unpair()`, clears Keychain token, returns to `PairingView`
- **Team 401:** Same behavior — if the device JWT is rejected, the device is no longer authorized. Call `unpair()` to clear the token and return to `PairingView`. Both connections share the same device JWT, so if one is rejected, the other will be too.
- **Team disconnect (non-auth):** Independent reconnect with exponential backoff. Does not affect Beekeeper tab. Copy the same retry pattern from `WebSocketManager`.
- **Token retry:** Copy the existing `tokenReadRetries` pattern (3 retries, 2s delay) from `WebSocketManager`.

## Build Sequence

Phases 1 and 2 are built together as a single deliverable — Phase 1 code (models, protocol, WS manager, ViewModel) cannot be meaningfully tested without UI since the project has no test targets. The phase split is for implementation ordering, not separate PRs.

### Phase 1+2 — Core + UI Shell
1. SwiftData models (`TeamChannel`, `TeamMessage`)
2. Team WS protocol (`TeamWSMessage.swift`)
3. `TeamWebSocketManager`
4. `TeamViewModel` — connect, fetch channels, send/receive messages
5. `ContentView` with TabView (Team + Beekeeper)
6. `TeamRootView` + `TeamSidebarView` — channel list
7. `TeamChatView` — message display + input
8. Wire `RootView` as Beekeeper tab

### Phase 3 — Polish
9. Message history pagination (scroll-up loading)
10. Channel events (join/leave notifications in chat)
11. Slash commands (send as raw text, display results)
12. Reconnect + history gap fill

## Sidebar Preview Seeding

On initial `channel_list` fetch, the client fires `history(channelId:, limit: 1)` per channel to seed `lastMessageText` / `lastMessageAt` for sidebar previews. This is O(N) requests where N = number of channels. **Known limitation for v1** — acceptable with a small team (< 20 channels). If this becomes a performance concern, limit to the 10 most recently updated channels or accept empty previews until the user opens a channel.
