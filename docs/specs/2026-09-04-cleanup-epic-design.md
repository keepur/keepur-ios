# Keepur iOS — Cleanup Epic (structural debt + silent failures)

**Date**: 2026-09-04
**Status**: Draft
**Ticket**: TBD (Keepur Linear org, KPR-*; the connected Linear workspace is dodihome, so filing waits on Keepur-org auth)
**Source**: design & code review, 2026-09-03 — https://claude.ai/code/artifact/44153a40-8a5a-49d9-b84b-aa71e406566d

## TL;DR

Fix the structural debt and silent-failure bugs the review found before any screen or feature work. Five serial child tickets: one shared socket transport, visible connection state with an offline send queue, an injectable and unit-tested `ChatViewModel`, typed state plus a single persistence helper, and the Team-layer correctness bugs. No screen layouts change; the only new UI is a connection/error banner and a "not sent" badge state.

## Key Points

- **Order is A → B → C → D → E**, serial. ⚠ This differs from the review's "where to start" list (which led with the connection banner) because the banner and the offline queue both consume the socket's state stream, so building the transport first avoids doing connection-state plumbing twice.
- **A. One transport.** `BeekeeperSocket` replaces `WebSocketManager` and `TeamWebSocketManager`. Raw `Data` frames, multicast via Combine, Task-based ping, Team-style handshake before reporting connected, `os.Logger` with no bodies or URLs in logs. Fixes the token-in-console leak.
- **B. Connection truth.** View models forward socket state into their own `@Published connectionState`; the nested-observable bug goes away. Chat surfaces get a banner. Sends while offline are queued on the existing pending-message path and flushed on reconnect; the bubble reads "not sent" until then. Team errors and Beekeeper errors without a session id surface in the same banner instead of printing or landing in the wrong chat.
- **C. Testable core.** `ChatViewModel` takes its socket, credential store, and speech manager by injection. It republishes decoded `WSIncoming` so the concierge coordinator subscribes instead of polling every 50 ms. `handleIncoming` gets its first unit tests (streaming, status, queue flush, `/clear` handoff, `session_replaced`, session-list sync, watchdog).
- **D. Typed state + persistence.** Enums for session status, message role, session mode, sender type, channel kind, and agent status; raw strings survive only at the codec boundary and the SwiftData attribute. One `persist` helper replaces the 62 `try?` save/fetch sites, logging every failure and surfacing save failures via `lastError`. CLAUDE.md drift fixed here.
- **E. Team correctness.** Stale `deviceId` after re-pair, hive switch no-op while connected, orphaned `TeamMessage` rows, seed/full-page history race, `pendingAgentDM` permanent lock. History merge extracted into a pure `HistoryMerger` with tests.
- **Out of scope**: every screen-level UX item (approval notifications, scroll-follow, stale-session resume, dark mode gaps, Dynamic Type, accessibility labels, empty-state copy), SwiftData message pruning, server-side ownership of concierge `mode`, extracting a `MessageStore` from `ChatViewModel`, and a CI pipeline.
- **Ping is settled.** Both layers already send the app-level `{"type":"ping"}` frame every 30 s (`WSOutgoing.ping`, `TeamWSOutgoing.ping`), and the Team layer already uses the protocol-level `sendPing` as its connect handshake. The unified socket keeps both: protocol ping as the handshake probe, app-level frame as the periodic keep-alive.
- **Message ids, partly settled.** Team `history` frames carry a server id per message (`TeamWSMessage.swift:198`), so E dedups agent and system messages on server id. The wire gives the client no server id for its *own* messages (`ack` carries only the request UUID; `history` rows carry no client id), so own messages keep a sender + text + 30 s window match, and on first match the local row adopts the server id so later reloads match by id. ⚠ A server follow-up to echo the client id in `ack` and `history` would delete that last heuristic; it is out of scope here.
- **Team failure handling changes.** Today a Team handshake or receive failure never reconnects; it shows a "hive is unavailable — tap to retry" banner and refreshes capabilities. After A, both layers reconnect with backoff. The hive-vanished check survives in `TeamViewModel`, triggered by the first `.reconnecting` transition, and the old banner is replaced by B's shared one.
- **Risk**: no CI exists, so each child's PR merges on the manual quality gate only. A one-job GitHub Actions `xcodebuild test` workflow is recommended as an optional ticket zero; it is not part of this epic unless the user opts in (see Open Questions).

---

## Problem

The 2026-09-03 review found that the client's shape is sound (MVVM, SwiftData, a type-safe wire enum, a token-based theme) but that two parallel network stacks and two parallel view models have grown side by side, the central state machine in `ChatViewModel` has no behavioral tests, and several failure modes are invisible to the user. The user's decision is to clear this debt before touching screens or adding features.

The findings this epic addresses, with review severity:

| Severity | Finding | Child |
|---|---|---|
| Critical | JWT and frame bodies printed to console (`TeamWebSocketManager.swift:57`, both managers) | A |
| Critical | Sends silently dropped when disconnected (`WebSocketManager.swift:76`, `ChatViewModel.swift:92`, `TeamViewModel.swift:141`) | B |
| Critical | Failures never reach the user (Team `.error` prints; Beekeeper errors land in whichever session is current) | B |
| High | Two near-identical transports; Beekeeper copy reports connected with no handshake | A |
| High | Nested `ObservableObject` (`viewModel.ws.isConnected`) never invalidates views | B |
| High | `ChatViewModel.handleIncoming` has zero tests; untestable because of Keychain statics and a concrete socket | C |
| High | `currentSessionId` hijacked by tool approvals for other sessions (`ChatViewModel.swift:162`) | C |
| High | Team: stale `deviceId` after unpair/re-pair (`TeamViewModel.swift:53`) | E |
| High | Team: hive switch is a no-op while connected (`TeamWebSocketManager.swift:26`) | A, E |
| High | 62 `try?` on SwiftData save/fetch (34 in `ChatViewModel`, 24 in `TeamViewModel`, 4 in views) | D |
| Medium | Concierge coordinator polls VM state every 50 ms because `onMessage` is single-consumer | C |
| Medium | Ping timers in default run-loop mode stall during scroll | A |
| Medium | Busy watchdog forces idle after 90 s and flushes into a possibly-busy session | C |
| Medium | Stringly-typed status, role, mode, sender, channel, agent status; three disagreeing agent-status switches | D |
| Medium | Team: history dedup loses repeats, duplicates un-acked own messages, seed/full-page race, orphaned rows, `pendingAgentDM` lock | E |
| Low | CLAUDE.md drift (`RootView.swift`, `ws://` endpoint, dead ATS exception) | D |
| Low | Dead code: `CapabilityManager.isLoading`, discarded `.typing`/`.commandList`, hardcoded unread badge | D |

## Scope

### In

Five child tickets, executed serially in the order listed under Design. Each child is its own spec-less ticket (this document is the spec) with its own plan, implementation, quality gate, review, and PR.

### Out

- Any screen-level UX change: tool-approval notifications outside the chat, scroll-follow during streaming, resumable stale sessions in the list, dark-mode token gaps, macOS dark mode, Dynamic Type, accessibility labels, empty/loading-state copy, the Settings "Done" button, ticket numbers in user copy. These are held for a UX epic.
- Pruning message history or replacing the all-messages `@Query` workaround in `ChatView`.
- Moving concierge `mode` ownership to the server. The client fallbacks in `ChatViewModel.sessionInfo` / `.sessionList` and `BeekeeperRootView.cleanupVestigialConciergeRow` stay until a server ticket lands.
- Extracting a `MessageStore` repository out of `ChatViewModel`. Child C makes the VM testable; splitting persistence out is a follow-up.
- CI (see Open Questions).
- Any wire-protocol change. Every frame shape stays as it is.

## Design

### Child A — `BeekeeperSocket`: one transport

**Replaces** `Managers/WebSocketManager.swift` and `Managers/TeamWebSocketManager.swift` with `Managers/BeekeeperSocket.swift`. Both files are deleted in this child.

```swift
@MainActor
final class BeekeeperSocket: ObservableObject {
    enum State: Equatable {
        case disconnected
        case connecting
        case connected
        case reconnecting(attempt: Int)
    }

    struct Config {
        let keepAliveFrame: Data       // the layer's encoded {"type":"ping"}; sent every pingInterval
        var pingInterval: Duration = .seconds(30)
        var maxReconnectDelay: Duration = .seconds(30)

        static let beekeeper = Config(keepAliveFrame: try! WSOutgoing.ping.encode())
        static let hive      = Config(keepAliveFrame: try! TeamWSOutgoing.ping.encode())
    }
    // The channel ("beekeeper" or a hive id) is a connect-time argument, not config,
    // because the Team layer switches it at runtime.

    @Published private(set) var state: State = .disconnected
    var isConnected: Bool { state == .connected }

    /// Multicast raw frames. Each subscriber gets every frame received after it subscribes.
    let frames = PassthroughSubject<Data, Never>()

    var onAuthFailure: (() -> Void)?
    var onConnected: (() -> Void)?

    init(config: Config,
         credentials: CredentialStore = KeychainCredentialStore(),
         endpoint: @escaping () throws -> URL = BeekeeperConfig.wssURL,
         taskFactory: @escaping (URL) -> WebSocketTasking = URLSessionWebSocketTaskAdapter.make)

    func connect(channel: String)   // if connected/connecting on a different channel: tear down, then connect
    func reconnect()                // re-uses the last channel; no-op if never connected
    func disconnect()
    @discardableResult func send(_ frame: Data) -> Bool   // false when state != .connected; caller decides what to queue
}
```

- `WebSocketTasking` is a small protocol (`resume`, `send`, `receive`, `sendPing`, `cancel(with:)`, `closeCode`) so tests can drive the socket with a fake; `URLSessionWebSocketTaskAdapter` wraps the real task.
- `CredentialStore` is a protocol (`token`, `deviceId`, `deviceName`, `isPaired`, `clearAll()`); `KeychainCredentialStore` forwards to the existing `KeychainManager` statics. Child C reuses it.
- **Handshake** (from the Team manager): `resume()` → `sendPing` → on success `state = .connected`, `reconnectAttempts = 0`, send keep-alive once, start the ping loop, start receiving, call `onConnected`. On ping failure → `handleDisconnect`.
- **Ping loop** is a `Task` sleeping `pingInterval`, cancelled on disconnect. Sends `keepAliveFrame` (the app-level ping both servers expect today). The protocol-level `sendPing` is used only as the handshake probe, matching the current Team manager.
- **Reconnect**: unchanged policy (2^N capped at `maxReconnectDelay`, guarded by `credentials.isPaired`), but `state` moves through `.reconnecting(attempt:)` so views can show it.
- **Auth failure**: close code 4001 or `endpoint()` throwing → `state = .disconnected`, `onAuthFailure`, no reconnect.
- **Token read retries**: unchanged (3 × 2 s) then fall through to reconnect backoff.
- **Channel switch**: `connect(channel:)` with a different channel while not `.disconnected` tears down first. Closes the Team hive-switch no-op at the transport level.
- **Failure semantics unify on the Beekeeper policy.** Today's Team manager routes handshake failures (`TeamWebSocketManager.swift:62-65`) and receive failures (`:167-169`) to `onReceiveFailure` and never reconnects; `TeamViewModel.handleReceiveFailure` (`:89-105`) shows a "tap to retry" banner and refreshes capabilities. After A there is no `onReceiveFailure`: every non-auth failure goes to `.reconnecting(attempt:)` with backoff. `TeamViewModel` keeps the hive-vanished check by observing `$state` and, on the transition into `.reconnecting(attempt: 1)`, calling `capabilityManager.refresh()`; if `selectedHive` is no longer in `hives`, it calls `socket.disconnect()`. Until B lands, the existing `disconnectedBanner` string is set on that same transition so the current retry UI keeps working; B replaces it.
- **Logging**: new `Managers/Log.swift`, `enum Log { static let socket, chat, team, persistence: Logger }` under subsystem `io.keepur`. The socket logs state transitions at `.info` and the frame `type` string at `.debug`. It never logs a URL, a token, or a frame body. All existing `print` calls in Managers/ and ViewModels/ are replaced in this child.

**Adoption**: `ChatViewModel` and `TeamViewModel` each own a `BeekeeperSocket`, subscribe to `frames` in `configure`, decode with their existing enums, and dispatch to their existing `handleIncoming`. Behavior is otherwise unchanged in this child; the `ws.isConnected` reads in views keep working (still stale, fixed in B).

**Tests** (`KeeperTests/BeekeeperSocketTests.swift`, fake task): handshake success reaches `.connected` and fires `onConnected`; handshake failure schedules reconnect with `.reconnecting(attempt: 1)`; receive failure with close code 4001 fires `onAuthFailure` and does not reconnect; `send` returns false while not connected; two subscribers both receive a frame; `connect(channel:)` on a new channel tears down the old task; ping loop stops after `disconnect()`.

### Child B — Connection truth and offline send queue

**View-model surface** (both `ChatViewModel` and `TeamViewModel`):

```swift
@Published private(set) var connectionState: BeekeeperSocket.State   // socket.$state.assign(to:)
@Published var lastError: UserFacingError?                           // banner consumes; auto-clears after 6 s or on tap

struct UserFacingError: Identifiable, Equatable {
    let id = UUID()
    let text: String     // e.g. "Not connected. Messages will send when reconnected."
}
```

Views stop touching `viewModel.ws`. Every view site migrates in this child:

| Site | Today | After B |
|---|---|---|
| `SessionListView.swift:95` | `ws.isConnected` dot | `connectionState == .connected` |
| `SettingsView.swift:100`, `:187` | `ws.isConnected`, `ws.disconnect()`, `ws.connect()` | `connectionState`, `viewModel.disconnect()`, `viewModel.reconnect()` |
| `WorkspacePickerView.swift:40`, `:48` | `ws.isConnected`, `ws.connect()` | `connectionState`, `viewModel.reconnect()` |
| `ContentView.swift:45` | `chatViewModel.ws.connect()` on scene-active | `chatViewModel.reconnect()` |
| `TeamRootView.swift:11-30`, `:42` | `disconnectedBanner` button, `ws.isConnected` dot | `KeepurConnectionBanner`, `connectionState` |

`ChatViewModel.reconnect()` / `disconnect()` and `TeamViewModel.reconnect()` / `disconnect()` are the only entry points views use. `BeekeeperRootView`'s four `viewModel.ws.send` calls (`:105-128`) stay until C rewrites the concierge coordinator; `ws` therefore becomes `private` in C, not B.

**Team banner replacement**: `TeamViewModel.disconnectedBanner` and `retryConnect()` are deleted. The hive-vanished path from A sets `lastError` ("This hive is no longer available.") and disconnects; ordinary failures show through `connectionState` like the Beekeeper layer.

**Banner**: `Theme/Components/KeepurConnectionBanner.swift`, a thin strip above the message list in `ChatView` and `TeamChatView`, styled with existing tokens (`warning` tint for reconnecting, `danger` for disconnected, `honey100`/`bgSunkenDynamic` surface). States:

| `connectionState` | Copy | Action |
|---|---|---|
| `.connecting` | "Connecting…" | none |
| `.reconnecting(n)` | "Reconnecting…" (attempt count only in the accessibility label) | none |
| `.disconnected` | "Not connected. Messages will send when reconnected." | "Retry" → `reconnect()` |
| `.connected` with `lastError` | the error text | tap to dismiss |
| `.connected`, no error | hidden | |

The banner is the only new UI in the epic. It has an accessibility label and is not color-only.

**Offline queue, Beekeeper**: `sendText` already persists the bubble and either sends or appends to `pendingMessages` when the session is busy. Change:

- `pendingMessageIds: Set<String>` becomes `pendingReasons: [String: PendingReason]`, `enum PendingReason { case busy, offline }`.
- `sendText`: if `connectionState != .connected` → enqueue with `.offline`; else if session busy → `.busy`; else send.
- `sendToServer` checks the `Bool` from `socket.send`; a `false` re-enqueues as `.offline` rather than dropping.
- On `connectionState` transition to `.connected`, after the reconnect `list_sessions` response has reconciled statuses (`syncSessions`), flush every `.offline` entry through the normal gate: idle session → send, busy session → reclassify as `.busy`.
- `MessageBubble` badge text: "waiting" for `.busy`, "not sent" for `.offline`. Same capsule, same tokens.
- `.error` with `sessionId == nil`: set `lastError` instead of inserting a system bubble into `currentSessionId`. With a session id, behavior is unchanged.
- `sessionId == nil` browse errors keep the existing `browseError` path.

**Offline queue, Team**: `sendMessage` inserts `TeamMessage(pending: true)` under a local UUID and calls `sendWithId`, which returns a request UUID that `pendingMessageIds[requestId] = localId` maps back to the row when the `ack` arrives. Change: when `socket.send` returns false, record the local id in `offlineMessageIds: Set<String>`; on `.connected`, re-send each row's text and register `pendingMessageIds[newRequestId] = localId` so the existing ack path clears `pending`. The bubble's existing "sending" state reads "not sent" while the id is in `offlineMessageIds`. Slash commands while offline set `lastError` ("Not connected. Try again when reconnected.") instead of clearing the input silently. `.error` frames set `lastError` in addition to the existing `pendingAgentDM` reset.

**Tests**: `ChatViewModel` tests for this land with Child C's harness (see C). Child B ships with `KeepurConnectionBannerTests` (state → copy mapping) and a `TeamViewModel` offline re-send test using the fake socket from A.

### Child C — Injectable, tested `ChatViewModel`

**Injection**:

```swift
init(socket: BeekeeperSocket = BeekeeperSocket(config: .beekeeper),
     credentials: CredentialStore = KeychainCredentialStore(),
     speech: SpeechManager? = nil)   // nil → created lazily on first access
```

`configure(context:)` calls `socket.connect(channel: "beekeeper")`. `unpair()` uses `credentials.clearAll()`. `KeychainManager` static reads in `ContentView.isPaired` are untouched (view-level, not under test).

**Decoded-frame multicast**: `let incoming = PassthroughSubject<WSIncoming, Never>()`, sent *after* `handleIncoming` has updated VM state, so subscribers observe a consistent VM. `ConciergeViewModel` replaces both 50 ms polling loops with `for await` over `incoming.values` filtered for `.sessionInfo` / `.sessionList`, with the same 3 s / 3 s / 5 s timeouts via `withTimeout`. Its four `viewModel.ws.send` calls become `viewModel.resumeSession(sessionId:path:)`, `viewModel.listSessions()`, and a new `viewModel.newConciergeSession()`. With those gone, `ws` becomes `private` on `ChatViewModel` (and on `TeamViewModel`, which has no external senders after B). `BeekeeperRootView`'s view body is otherwise unchanged.

**Approval hijack** (`ChatViewModel.swift:162`): stop assigning `currentSessionId` when a `tool_approval` arrives for another session. `pendingApprovals` is already keyed by session; the sheet already binds per `ChatView`. The user sees the approval when they open that session. (Surfacing it elsewhere is UX-epic work.)

**Watchdog** (`ChatViewModel.swift:192`): when the 90 s timer fires, send `list_sessions` instead of forcing idle. `syncSessions` already flips to idle and flushes when the server reports idle. `syncSessions` today only arms a watchdog when the client state is nil or idle (`:569-580`); it gains an explicit branch: client busy and server busy → re-arm the watchdog for that session. Removes the misfire without ever leaving a busy session unwatched.

**Test harness**: `KeeperTests/ChatViewModelTests.swift` with an in-memory `ModelContainer` (`isStoredInMemoryOnly: true`), the fake `WebSocketTasking` from A driving a real `BeekeeperSocket`, a `FakeCredentialStore`, and `speech: nil`. Helper `receive(_ json: [String: Any])` pushes a frame. Cases:

1. Streaming: three non-final chunks then a final append produce one assistant `Message` with concatenated text; a lone final produces one message; a `thinking` status between rounds starts a new bubble.
2. Status: `tool_running` with a name sets `sessionToolNames`; `idle` clears it; `session_ended` clears all per-session state.
3. Queue: send while busy → `.busy`; `idle` status flushes exactly one; `cancel` clears the queue for that session only.
4. Offline (from B): send while disconnected → `.offline`; reconnect + `session_list` idle → sent; reconnect + `session_list` busy → reclassified `.busy`.
5. `/clear` handoff: `context_cleared` then `session_info` for the same path swaps the row, keeps the name, deletes the old row, keeps `currentSessionId` pointing at the new id.
6. `session_replaced`: messages migrate, old row deleted, transient state migrated.
7. `session_list`: missing local rows inserted, absent server rows marked stale, concierge rows excluded from the `Session` table, current session cleared if stale.
8. `error` with nil session id → `lastError`; with a session id → system bubble.
9. Approval for another session leaves `currentSessionId` alone.
10. Watchdog: with `staleBusyTimeout` injected as 50 ms, firing sends `list_sessions` and does not flip status by itself.

### Child D — Typed state and persistence hygiene

**Enums** (`Models/SessionStatus.swift`, `Models/MessageRole.swift`, `Models/SessionMode.swift`, and in `Models/TeamWSMessage.swift` for Team types):

```swift
enum SessionStatus: Equatable {
    case idle, thinking, toolStarting, toolRunning, busy, sessionEnded
    case unknown(String)
    init(wire: String)
    var isActive: Bool          // thinking, toolStarting, toolRunning, busy
    var headerText: String?     // the mapping now in ChatView.mapSessionStatus
}
enum MessageRole: String { case user, assistant, system, tool, unknown }
enum SessionMode: String { case sessions, concierge }
enum SenderType: String { case person, agent, system }
enum ChannelKind: String { case channel, dm }
enum AgentStatus { /* single source for label + tint, replacing the three switches */ }
```

Rules: `WSIncoming` / `TeamWSIncoming` decode straight into these; `sessionStatuses` becomes `[String: SessionStatus]`; `Message.role` and `TeamMessage.senderType` stay `String` attributes in SwiftData (no migration) with a computed typed accessor; views switch on the enum. The duplicated literal arrays in `ChatView.swift:88` and `:113` collapse to `status.isActive`. The three agent-status switches in `AgentDetailSheet`, `AgentRow`, and `TeamChatView` become one `AgentStatus.presentation`.

**Persistence helper** (`Managers/Persistence.swift`):

```swift
extension ModelContext {
    /// Fetch; on failure log via Log.persistence and return [].
    func fetchOrEmpty<T: PersistentModel>(_ descriptor: FetchDescriptor<T>, _ what: StaticString) -> [T]
    /// Save; on failure log and return the error so the caller can surface it.
    @discardableResult func saveReporting(_ what: StaticString) -> Error?
}
```

Every `try? …fetch(` becomes `fetchOrEmpty`; every `try? …save()` becomes `saveReporting`, and inside view models a non-nil result sets `lastError` ("Couldn't save. Your last change may not be kept."). Views that save directly (`SessionListView` rename, `BeekeeperRootView` cleanup) use `saveReporting` and log only. Where a fetch failure previously fell through a `guard` and skipped work, `fetchOrEmpty` returning `[]` must produce the same skip; the plan lists each such site. Target: zero `try?` on save or fetch, verified by grep in the quality gate.

**Also in D**: wire `CapabilityManager.isLoading` so `HivesGridView` distinguishes loading from empty (a state fix, not a layout change); delete the discarded `.typing` / `.commandList` decoding or keep them as documented no-op cases; remove the hardcoded `KeepurUnreadBadge(count: 0)` from `AgentRow.swift:58` (unread counts are a held feature; an always-zero badge is dead code); CLAUDE.md rewritten to match the tree (`ContentView` as the auth gate, `BeekeeperSocket`, configurable TLS host, the ATS exception removed from `Info.plist` along with the `hive.dodihome.com` entry).

**Tests**: enum decode round-trips for every wire value plus the unknown case; `AgentStatus.presentation` covers every status; a `saveReporting` test with a deliberately invalid model change returns an error and does not throw.

### Child E — Team-layer correctness

- **Stale `deviceId`**: `TeamViewModel.deviceId` becomes a computed read of `credentials.deviceId` at each use. The `configure` idempotency guard stays.
- **Hive switch**: `TeamViewModel.connectIfPossible` calls `socket.connect(channel: selectedHive)`; the socket (A) tears down when the channel differs. `disconnect()` before switching is no longer required.
- **Orphaned rows**: new file `Models/TeamStore.swift`, a thin SwiftData helper, with `deleteChannel(_:)` that deletes the channel's messages first. `syncChannels` and both `handleChannelEvent` delete sites use it. On disconnect, `pendingCommandChannels`, `pendingMessageIds`, `pendingNewCommands` are cleared.
- **`pendingAgentDM` lock**: a 10 s `Task` clears `pendingAgentDM` / `pendingDMRequestId` and sets `lastError` ("Couldn't open a direct message. Try again.") if no channel arrives.
- **History merge**: extracted to `Models/HistoryMerger.swift`, a pure function `merge(existing: [TeamMessageSnapshot], incoming: [TeamWSMessage], ownDeviceId: String) -> MergeResult` with no SwiftData dependency. Rules, given what the wire provides (history rows carry a server id but no client id; `ack` carries only the request UUID; own rows are stored under a local UUID):
  1. Agent and system messages dedup on server id only. The content-key dedup for them is deleted, so legitimate repeats survive.
  2. Own messages (`senderId == ownDeviceId`) match a history row by sender, exact text, and `createdAt` within the existing 30 s window, whether or not the local row is still `pending`. On match the local row adopts the server id (`TeamMessage.id` is unique but mutable; the merger checks the id is not already present) and `pending` is cleared. Subsequent reloads then match by id and the heuristic never runs again for that message.
  3. An own history row with no local match is inserted as a normal message (sent from another device).
  ⚠ Follow-up server ticket, out of scope: echo the client's request UUID in `ack` and `history` so rule 2 becomes an id match. `processHistory` correlates each response with the request id already carried by `.history(…, id:)`, and only the response for the *current* full-page request updates `hasMoreHistory`, `isLoadingHistory`, and `lastServerMessageId`; seed responses update the channel preview only.
- **Dead code**: `TeamChannel.displayName` is removed; the VM's `displayName(for:)` survives because DM names need the agent lookup the model cannot do.

**Tests**: `HistoryMergerTests` (agent dedup by id, repeated identical agent text is kept, own pending and own acked rows adopt the server id, own text outside the 30 s window is a new row, id-collision guard, ordering); `TeamViewModelTests` for hive switch triggering `connect(channel:)`, `deleteChannel` removing messages, DM timeout clearing the lock, and the seed-vs-full-page race using two in-flight request ids.

## Sequencing and dependencies

```
A (socket) ──► B (banner + offline queue) ──► C (injection + tests) ──► D (enums + persist) ──► E (Team fixes)
```

Serial on purpose: B, C, and D all edit `ChatViewModel` and `TeamViewModel`, and E depends on A's channel-switch and on B's `lastError`. Each child ends with a green quality gate and a merged PR before the next starts. macOS target must build at every step; nothing here is iOS-only except the banner's `#if os(iOS)` haptics, which it does not use.

## Testing contract

- Every child adds tests in `KeeperTests/` as listed and passes `/quality-gate` (swift compliance → create tests → full suite) before review.
- After C, `ChatViewModelTests` becomes the regression harness that B, D, and E must keep green.
- After D, `grep -rnE 'try\? .*\.(save|fetch)\(' --include='*.swift' .` outside `KeeperTests/` returns nothing (62 sites today), and `grep -rn 'print(' Managers ViewModels` returns nothing.
- After E, `TeamWebSocketManager.swift` and `WebSocketManager.swift` no longer exist (deleted in A), and no view reads `viewModel.ws`.

## Risks

- **Handshake probe on the Beekeeper channel.** The Beekeeper manager never sent a protocol-level ping; the Team manager does and the same server accepts it. If the Beekeeper channel ever rejects it, A falls back to sending `keepAliveFrame` and treating the first received frame as the handshake.
- **Reconnect flush ordering**. Flushing offline messages before the post-reconnect `session_list` arrives could send into a busy session. B gates the flush on `syncSessions` having run once after the transition; if `session_list` never arrives within 5 s, flush anyway through the normal busy gate.
- **SwiftData attribute types**. Keeping `role` / `senderType` as `String` avoids a schema migration. The app already wipes the store on container failure (`KeepurApp.swift`), so a migration would be survivable, but not worth it here.
- **Behavior change in C's approval handling**. Users who relied on the app jumping to a session with a pending approval will no longer be jumped. Acceptable; the jump was also what broke the current chat.
- **Scope creep from D**. Replacing 92 call sites touches most files. The plan for D must be mechanical (one helper, one pattern) and reviewed for accidental behavior changes, especially where a fetch failure previously fell through a `guard`.

## Open Questions

1. **CI ticket zero?** A minimal GitHub Actions workflow running `xcodebuild test -scheme Keepur -destination 'platform=iOS Simulator,...'` on PRs would make the quality gate enforceable. Not in this epic unless the user says yes.
2. **Ticket filing.** The connected Linear workspace is dodihome (DOD-*). The epic and five children belong in the Keepur org (KPR-*). File once Keepur-org auth is wired, or file on GitHub Issues as CLAUDE.md still says.
