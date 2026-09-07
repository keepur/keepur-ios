# KPR-442 — Child B: Connection truth, banner, offline send queue

**Date**: 2026-09-07
**Status**: Draft (mature-ticket lane, draft-spec phase)
**Ticket**: [KPR-442](https://linear.app/keepur/issue/KPR-442) — child B of epic [KPR-441](https://linear.app/keepur/issue/KPR-441) (GitHub mirror keepur/keepur-ios#91)
**Parent spec**: `docs/specs/2026-09-04-cleanup-epic-design.md` § Child B (approved 2026-09-04). This document elaborates that section into an implementation-ready spec; where it adds detail it does not contradict the epic or its decision register.
**Starting point**: epic branch `epic-kpr-441` at `65ac574`, with child A (`BeekeeperSocket`, commit `8f19b0b`) merged.

## TL;DR

Make connection state visible and truthful: both view models forward `socket.$state` into `@Published connectionState`, gain `@Published lastError`, and every view read of `viewModel.socket.*` migrates to those. A new `KeepurConnectionBanner` (the epic's only new UI) shows connecting / reconnecting / not-connected / error above the message list. Sends stop being silently dropped: the Beekeeper queue gains a `.busy`/`.offline` reason per message and flushes after the post-reconnect `session_list`; the Team layer re-sends un-acked and never-sent messages on reconnect. Five small transport fixes carried in from child A's review land here too.

## Key Points

- **Scope is exactly the ticket**: `connectionState`/`lastError` on both VMs and the view migration table; `KeepurConnectionBanner` mounted in `ChatView` and `TeamRootView`; Beekeeper `pendingReasons` offline queue with reconnect flush gated on `syncSessions` (5 s fallback); `syncSessions` absent-id → `session_ended` cleanup; `.error`-with-nil-session routing; Team `offlineMessageIds`/`offlineAttachments` re-send; five carried-in `BeekeeperSocket` fixes. No wire change, no persistence of queues, no other UI.
- **Rule that shapes the code**: never call `socket.send` from inside a `$state` sink. Combine `@Published` emits on `willSet`, so `socket.state` (and therefore `socket.send`'s gate) still reads the *old* value during the emission. Beekeeper flushes on `session_list`; Team re-sends in `onConnected`.
- **Reconnect-flush gate**: on the transition into `.connected` the Beekeeper VM arms `awaitingPostReconnectSync` plus a 5 s fallback; the next `syncSessions` (or the fallback) reclassifies `.offline` → `.busy` and flushes one message per idle session that the sync itself did not already flush. Queue order is preserved.
- **Absent-id cleanup uses the full `session_list`**, not the concierge-filtered list `syncSessions` receives today; otherwise the concierge slot (never in the `Session` table) would be reaped on every list reply. Queued messages for any absent session are dropped; non-idle absent sessions get the full `session_ended` cleanup (C's watchdog relies on this).
- **Team at-least-once**: an un-acked message whose ack was lost to a disconnect is re-sent and may be duplicated server-side. Accepted by the epic ("re-sends rather than staying 'sending' forever"); E's `serverId` reconcile is the dedup story. Attachments live only in memory; a kill before reconnect re-sends the text and loses the attachment (matches the Beekeeper layer today).
- **Carried-in transport fixes**: `scheduleReconnect` bail resets `reconnectAttempts`; `disconnect()` clears `lastChannel` (so `socket.reconnect()` is a no-op after a manual disconnect, matching the old Team manager) and closes with `.normalClosure` (internal teardowns keep `.goingAway`); concierge `waitForSocketConnected` observes `$connectionState` and bails immediately on `.disconnected` without wiping the cached concierge id; `receive()` reads `self.task?.closeCode` to clear the macOS Sendable warning.
- ⚠ **Delegated assumptions** (routine, epic is signed off): (1) the Team banner mounts once in `TeamRootView` where the old banner was, which covers `TeamChatView` and the sidebar-only state, rather than a second mount inside `TeamChatView`; (2) `offlineMessageIds` is an ordered `[String]` not a `Set` because re-send order matters; (3) Beekeeper offline tests ship in this child in the existing `ChatViewModelSocketTests` harness (A built the harness the epic expected C to build), and C re-homes them; (4) banner surface is `bgSunkenDynamic` (dark-mode-safe) rather than the old banner's fixed `honey100`; (5) `WorkspacePickerView`'s Reconnect button stops calling `browse()` itself and the picker re-browses on the transition to `.connected`, closing child A's documented "reconnect-then-browse drop" interim.
- **Risks**: `syncSessions` is the most-edited function in the epic (B, C, D all touch it); keep B's edits to three named insertions so C's diff stays readable. The hive-vanished path is not unit-testable in B (needs a `CapabilityManager.refresh` seam) — covered by the existing manual path and noted for E.

## Problem

Three of the review's critical/high findings are still open after child A:

1. **Sends silently dropped.** `BeekeeperSocket.send` returns `false` when not `.connected`; `ChatViewModel.send`/`sendToServer` and `TeamViewModel.sendWithId` ignore that and the user's bubble looks sent. `ChatViewModel.sendText` persists the row and only queues when the *session* is busy, never when the *socket* is down. A `sendWithId` nil in `TeamViewModel.sendMessage` leaves the row `pending: true` forever.
2. **Stale connection dot.** Views read `viewModel.socket.isConnected` (`SessionListView:95`, `SettingsView:100-103,187-189`, `WorkspacePickerView:40`, `TeamRootView:42`) through a nested `ObservableObject` that the view never observes, so the dot only repaints when something else publishes.
3. **Failures never reach the user.** Beekeeper `.error` with a nil session id is written as a system bubble into whichever session is current; Team `.error` is logged and dropped; slash commands and `openAgentDM` while offline are silent no-ops.

Plus five items child A's review parked on this ticket (listed under *Carried-in fixes*).

## Goals

- Views observe connection state directly and correctly; no view reads `viewModel.socket` after this child (`BeekeeperRootView`'s `viewModel.send(...)` calls are VM calls, not socket reads, and stay until C).
- A user who sends while disconnected sees "not sent", and the message goes out on reconnect without being re-typed — on both layers.
- Server errors and offline actions surface in one place (`lastError` → banner).
- `TeamViewModel.disconnectedBanner`/`retryConnect()`/`handleConnectionLost()` are gone; the Team hive-vanished path reports through `lastError`.
- The five carried-in transport fixes land with tests.

## Non-goals

- Any wire-protocol change; any new frame or field.
- Persisting either offline queue across launches (Beekeeper `pendingMessages` is in-memory today; Team keeps the same limit).
- Dedup of re-sent Team messages against history (child E, `TeamMessage.serverId`).
- Rewriting the concierge coordinator (child C) beyond the `waitForSocketConnected` bail.
- Making `socket` private on the VMs (child C, after `BeekeeperRootView` stops calling `viewModel.send`).
- Any UX-epic item: Dynamic Type, haptics, toast styling, animations beyond a default `.animation(.default, value:)`.
- `CapabilityManager.lastError` (unrelated, pairing-screen string) is untouched.

## Design

### 1. View-model surface (both `ChatViewModel` and `TeamViewModel`)

```swift
@Published private(set) var connectionState: BeekeeperSocket.State = .disconnected
@Published var lastError: UserFacingError?     // banner consumes; auto-clears after 6 s or on tap
```

New file `Models/UserFacingError.swift` (synchronized group, no pbxproj edit):

```swift
struct UserFacingError: Identifiable, Equatable {
    let id = UUID()
    let text: String
    init(_ text: String) { self.text = text }
}
```

**Forwarding.** Subscribe in `init` (not `configure`) so Settings and the list views observe truth before `configure` runs and independently of it:

```swift
socket.$state
    .sink { [weak self] state in self?.handleSocketState(state) }
    .store(in: &subscriptions)

private func handleSocketState(_ state: BeekeeperSocket.State) {
    let previous = connectionState
    connectionState = state
    // transition hooks below; NEVER call socket.send from here (willSet lag)
}
```

`TeamViewModel` already has this sink in `configure` with `.dropFirst()`; move it to `init` (its `capabilityManager` uses are `guard let`-safe before configure). Keep `previousSocketState` semantics by using `previous` above. `frames` subscriptions stay in `configure` (they need `modelContext`).

**`lastError` auto-clear.** A `didSet` on `lastError` cancels `lastErrorTimer` and, when non-nil, arms `Task { try? await Task.sleep(for: .seconds(6)); if self.lastError?.id == id { self.lastError = nil } }`. Setting to nil (banner tap) just cancels. The timer runs regardless of whether a banner is mounted; that is acceptable.

**Where `lastError` is set** (exhaustive for this child):

| Layer | Trigger | Text |
|---|---|---|
| Beekeeper | `.error(message, sessionId: nil)` and no browse pending | server `message` |
| Team | `.error(message)` frame | server `message` (in addition to the existing `pendingAgentDM`/`pendingDMRequestId` reset) |
| Team | hive-vanished after `capabilityManager.refresh()` | "This hive is no longer available." (then `socket.disconnect()`) |
| Team | slash command while `connectionState != .connected` or `sendWithId` returns nil | "Not connected. Try again when reconnected." |
| Team | `openAgentDM` needing a `/dm` while not connected | same text |

### 2. View migration table

Every read of `viewModel.socket` outside the VMs and tests:

| Site | Today | After B |
|---|---|---|
| `Views/SessionListView.swift:95` | `socket.isConnected` dot | `connectionState == .connected` |
| `Views/SettingsView.swift:100-103` | `socket.isConnected` ×3 (dot, label, tint) | `connectionState`; label "Connected" / "Connecting…" / "Reconnecting…" / "Disconnected", tint `success` / `warning` / `warning` / `danger` |
| `Views/SettingsView.swift:187-189` | `socket.isConnected` button title + branch | `connectionState == .connected` |
| `Views/WorkspacePickerView.swift:40` | `!socket.isConnected` → "Disconnected" placeholder; Reconnect calls `reconnect()` then `browse()` (dropped while handshaking — A's documented interim) | `connectionState != .connected`; Reconnect calls `browseError = nil; reconnect()` only; add `.onChange(of: viewModel.connectionState) { if it became .connected { viewModel.browse() } }` on the picker ⚠(5) |
| `Views/Team/TeamRootView.swift:11-30` | `disconnectedBanner` `Button` | `KeepurConnectionBanner(...)` in the same VStack slot ⚠(1) |
| `Views/Team/TeamRootView.swift:42` | `socket.isConnected` dot | `connectionState == .connected` |
| `Views/BeekeeperRootView.swift:184` | `socket.isConnected` polled every 50 ms in `waitForSocketConnected` | `$connectionState` wait (see *Carried-in fix 4*) |
| `Views/ChatView.swift:80` | `pendingMessageIds.contains(id)` → `showWaitingBadge` | `pendingReason: viewModel.pendingReasons[message.id]` |
| `Views/Team/TeamChatView.swift` (bubble call) | — | `isOffline: viewModel.offlineMessageIds.contains(message.id)` |

Tests that read `vm.socket.state` / `vm.socket.isConnected` (`ChatViewModelSocketTests:67,111`, `ConciergeViewModelTests:94`, `TeamViewModelTests:90,104`) switch to `vm.connectionState` so the forwarding is what they prove. `viewModel.reconnect()` / `disconnect()` (from A) and `connectionState` / `lastError` are then the only connection surface views use.

### 3. `KeepurConnectionBanner`

New file `Theme/Components/KeepurConnectionBanner.swift`. **`Theme/Components` is an explicit pbxproj group** (unlike `Views/`, `Models/`, `KeeperTests/`), so the file must be added to the `Keepur` target's Sources phase with the `xcodeproj` Ruby gem, per the precedent in `docs/plans/2026-05-02-kpr-146-foundation-composites.md:128`; verify with `git diff Keepur.xcodeproj/project.pbxproj` (one `PBXBuildFile`, one `PBXFileReference`, one group child, one Sources entry).

```swift
struct KeepurConnectionBanner: View {
    struct Presentation: Equatable {
        enum Tint { case warning, danger }
        let text: String
        let tint: Tint
        let symbol: String                 // "arrow.triangle.2.circlepath" (warning) / "exclamationmark.triangle.fill" (danger)
        let actionTitle: String?           // "Retry now" / "Retry" / nil
        let accessibilityLabel: String
        let dismissesOnTap: Bool           // true iff an error is showing
    }

    let state: BeekeeperSocket.State
    let error: UserFacingError?
    let onRetry: () -> Void
    let onDismissError: () -> Void

    /// Pure mapping; the unit under test. nil → render nothing.
    static func presentation(state: BeekeeperSocket.State, error: UserFacingError?) -> Presentation?
}
```

Mapping (a non-nil `error` replaces the *text* in every state; the state's *action* is kept):

| `state` | `error` | text | action | tint | accessibility label |
|---|---|---|---|---|---|
| `.connected` | nil | hidden (`nil`) | — | — | — |
| `.connected` | e | `e.text` | none | danger | `e.text` |
| `.connecting` | nil | "Connecting…" | none | warning | "Connecting" |
| `.connecting` | e | `e.text` | none | danger | `e.text` |
| `.reconnecting(n)` | nil | "Reconnecting…" | "Retry now" | warning | "Reconnecting, attempt \(n)" |
| `.reconnecting(n)` | e | `e.text` | "Retry now" | danger | "\(e.text). Reconnecting, attempt \(n)" |
| `.disconnected` | nil | "Not connected. Messages will send when reconnected." | "Retry" | danger | same as text |
| `.disconnected` | e | `e.text` | "Retry" | danger | "\(e.text). Not connected." |

Rendering: `HStack` of symbol (tint color), text (`bodySm`, `fgPrimaryDynamic`, `lineLimit(2)`), `Spacer`, optional action `Button` (`bodySm` bold, `honey700`, `.buttonStyle(.plain)`); padding `Spacing.s3`; `frame(maxWidth: .infinity)`; background `bgSunkenDynamic` ⚠(4). When `dismissesOnTap`, the text region gets `.onTapGesture { onDismissError() }` and `.accessibilityAddTraits(.isButton)` with hint "Dismiss". The action button is a separate accessibility element. Not color-only: the symbol and copy carry the state. `.animation(.default, value: presentation)` on the container; no haptics, no `#if os(iOS)`.

**Action wiring**: `onRetry` is `viewModel.reconnect()` on both layers — `ChatViewModel.reconnect()` is `socket.connect(channel: "beekeeper")`, `TeamViewModel.reconnect()` is `connectIfPossible()`. In `.reconnecting` with a backoff sleep pending this cancels the sleep and attempts now, keeping the attempt count (A's semantics); while a retry handshake is already in flight it is a no-op (accepted; the button stays enabled). Nothing in B calls `socket.reconnect()`.

**Mounts**:
- `ChatView`: first child of the outer `VStack(spacing: 0)`, above the `ScrollViewReader`. This covers the Sessions tab and the concierge tab (both render `ChatView`).
- `TeamRootView`: replaces the `disconnectedBanner` `Button` in the same slot above the `NavigationSplitView` ⚠(1). It is outside the navigation stack, so on iPhone it stays visible on the pushed `TeamChatView` and on the sidebar-only state; `TeamChatView` does not mount a second one.

### 4. Beekeeper offline queue (`ChatViewModel`)

**State changes**

```swift
enum PendingReason: Equatable { case busy, offline }
@Published private(set) var pendingReasons: [String: PendingReason] = [:]   // replaces pendingMessageIds: Set<String>

private struct PendingMessage { let text: String; let messageId: String; var sessionId: String; let attachment: AttachmentData? }
private var pendingMessages: [PendingMessage] = []        // same ordered queue as today, struct instead of tuple
private var awaitingPostReconnectSync = false
private var postReconnectFlushFallback: Task<Void, Never>?
```

`enqueue(_ m: PendingMessage, reason:, atFront: Bool = false)` maintains both. `clearPendingMessages(for:)` and `flushNextPendingMessage(for:)` keep their names and update `pendingReasons` instead of the set. `.sessionReplaced`'s queue migration becomes `pendingMessages[i].sessionId = newSessionId`.

**`sendText`** (after the row is inserted and saved, as today):

```
if connectionState != .connected        → enqueue(.offline)
else if statusFor(sessionId) != "idle"  → enqueue(.busy)
else                                     → sendToServer(entry)
```

**`sendToServer(_ entry: PendingMessage) -> Bool`** builds the frames (text if non-empty; then image/file if an attachment) and sends them in order. The first `false` from `send` re-enqueues the entry **at the head** of the queue as `.offline` and returns `false`. Because `socket.send`'s gate is read synchronously on the main actor, a later frame of the same entry cannot fail after an earlier one succeeded, so partial re-sends do not occur. `flushNextPendingMessage` removes the head for the session and calls `sendToServer`; on `false` the entry is back at the head with reason `.offline`.

**Reconnect flush**

- In `handleSocketState`: on transition into `.connected` (previous != `.connected`) set `awaitingPostReconnectSync = true` and arm `postReconnectFlushFallback` (5 s → `flushOfflineQueue(skipping: [])`). On transition out of `.connected`: cancel the fallback, clear the flag. Nothing else; queued entries stay.
- In `syncSessions` (see §5 for its full new shape): if `awaitingPostReconnectSync`, clear it, cancel the fallback, and **before** the status-reconciliation loop reclassify every `.offline` reason to `.busy`. The existing loop's "client non-idle / server idle → idle + flush head" branch records each session id it flushes in a local `flushed: Set<String>`. After the loop: `flushOfflineQueue(skipping: flushed)`.
- `flushOfflineQueue(skipping:)`: reclassify any remaining `.offline` → `.busy` (no-op on the sync path, real work on the fallback path); then for each distinct `sessionId` in `pendingMessages` in first-appearance order, if `statusFor(id) == "idle"` and not in `skipping`, call `flushNextPendingMessage(for: id)` once. The existing one-in-flight rule (`.status("idle")` flushes the next) drains the rest.
- An explicit `.status("idle")` for a session arriving before `session_list` still flushes that session's head via the existing branch, even if the entry is `.offline`. That is correct: an idle status is authoritative and the send succeeds because we are connected.
- Cold start counts as a reconnect: the user can type during `.connecting`; the entry is `.offline` and goes out after the first `session_list`.

**Bubble badge** (`Views/MessageBubble.swift`): `showWaitingBadge: Bool` becomes `pendingReason: ChatViewModel.PendingReason? = nil`; `.busy` renders "waiting", `.offline` renders "not sent"; same capsule, tokens, and pulse; the text is the accessibility label.

**Cancel while offline**: `cancelCurrentOperation` still calls `clearPendingMessages(for:)`, so `.offline` entries are dropped too (the `cancel` frame itself is dropped by the socket). Cancel means "drop what's queued" on both reasons; documented, not changed.

### 5. `syncSessions` new shape

Signature becomes `syncSessions(serverSessions: [ServerSession], allServerIds: Set<String>, context:)`. The `.sessionList` handler passes `sessionsTabOnly` (unchanged) **and** `Set(sessions.map(\.sessionId))` from the full reply. Three insertions, in this order:

1. **Post-reconnect reclassify** (§4) — only when `awaitingPostReconnectSync`.
2. **Absent-id cleanup** — after the local `Session` rows are marked stale and before status reconciliation:
   ```
   for id in Set(sessionStatuses.keys).union(pendingMessages.map(\.sessionId)) where !allServerIds.contains(id) {
       if statusFor(id) != "idle" { endSession(id) }         // full session_ended cleanup
       else { clearPendingMessages(for: id) }               // idle-but-gone: drop its queue only
   }
   ```
   `endSession(_:)` is a new private helper extracted from the `.status("session_ended")` branch (remove streaming id, approval, status, tool name, cancel watchdog, `clearPendingMessages`); that branch calls it. Dropped entries' bubbles lose their badge and stay in history, the same outcome as today's `session_ended`.
3. **Post-loop flush** (§4) — `flushOfflineQueue(skipping: flushed)` when this sync cleared `awaitingPostReconnectSync`.

Everything else in `syncSessions` (stale marking, row insertion, status adoption, watchdog arming, current-session clearing) is untouched; C's changes (full-list reconciliation, busy/busy re-arm) layer on top.

### 6. `.error` routing (`ChatViewModel`)

```swift
case .error(let message, let sessionId):
    if let sessionId {
        insert Message(sessionId: sessionId, text: "Error: \(message)", role: "system")   // unchanged
    } else if isBrowsePending {
        isBrowsePending = false
        browseError = message                                   // picker shows it inline; no banner
    } else {
        lastError = UserFacingError(message)                    // no more bubble in whichever session is current
    }
```

### 7. Team offline queue (`TeamViewModel`)

**State**

```swift
@Published private(set) var offlineMessageIds: [String] = []          // local ids, send order ⚠(2)
private var offlineAttachments: [String: AttachmentData] = [:]         // localId → attachment, in-memory only
private var pendingMessageIds: [String: String] = [:]                  // requestId → localId (unchanged)
```

**`sendMessage`** (row inserted with `pending: true` as today):

```
if connectionState == .connected, let requestId = sendWithId(.teamMessage(...)) {
    pendingMessageIds[requestId] = localId
    send attachment frame(s) as today (untracked)
} else {
    offlineMessageIds.append(localId)
    if let attachment { offlineAttachments[localId] = attachment }
}
```

**Transition out of `.connected`** (`handleSocketState`, previous == `.connected`, new != `.connected`): every `localId` in `pendingMessageIds.values` (sent, un-acked) is appended to `offlineMessageIds` ordered by the row's `createdAt`; `pendingMessageIds` is cleared. `pendingCommandChannels`/`pendingNewCommands` are left alone (their replies simply never arrive). Attachments already sent are not re-sent for these ids (only the text frame is acked).

**Re-send** happens at the end of `onConnected()` (after `fetchChannels`/`agentList`/`commandList`/gap-fill history — bookkeeping frames first), never in the state sink:

```
for localId in offlineMessageIds (snapshot, in order):
    guard let row = fetch TeamMessage(id: localId) else { drop id; continue }   // channel archived/left meanwhile
    guard let requestId = sendWithId(.teamMessage(channelId: row.channelId, text: row.text, threadId: row.threadId)) else { break }  // stop; remaining ids stay queued
    pendingMessageIds[requestId] = localId
    if let attachment = offlineAttachments.removeValue(forKey: localId) { send image/file frame as in sendMessage }
    remove localId from offlineMessageIds
```

The existing `.ack` path flips `pending = false` and refreshes. Known edge: an attachment-only message re-sends the row's `text` (the attachment name) as the message text, because the row is the only persisted copy; rare and non-blocking.

**Bubble** (`Views/Team/TeamMessageBubble.swift`): add `isOffline: Bool = false`; badge text is "not sent" when `isOffline`, else "sending" when `message.pending`, else none. `TeamChatView` passes `viewModel.offlineMessageIds.contains(message.id)`.

**Offline actions**: `sendSlashCommand` and `openAgentDM` check `connectionState == .connected` first and, on either that failing or `sendWithId` returning nil, set `lastError = UserFacingError("Not connected. Try again when reconnected.")` and return without touching `pending*` state. `.error(message)` frames set `lastError = UserFacingError(message)` after the existing resets.

**Deleted**: `disconnectedBanner`, `retryConnect()`, `handleConnectionLost()`. `handleSocketState` keeps the hive-vanished check on the transition into `.reconnecting(attempt: 1)` (A's documented deviation stays: the check is once per loss; the banner is now state-driven so needs no re-set); `refreshCapabilitiesAfterConnectionLost`'s hive-gone branch sets `lastError` and calls `socket.disconnect()`. After the 6 s auto-clear the banner falls back to "Not connected… Retry"; Retry → `connectIfPossible()` → no valid hive → `disconnect()`; accepted (the tab itself re-routes to the hive grid once `CapabilityManager` reconciles `selectedHive`).

### 8. Carried-in fixes (`Managers/BeekeeperSocket.swift` + `Views/BeekeeperRootView.swift`)

1. **`scheduleReconnect` bail resets the counter.** The `guard credentials.isPaired, let channel = lastChannel else { … }` branch also sets `reconnectAttempts = 0`. Without it, an exhausted token-read retry (which reaches this branch because `isPaired` reads the same missing token) leaves the count at its last value, so the next `connect()` skips `.connecting` (`open` only sets it when the count is 0) and the next failure starts backoff one exponent high.
2. **`disconnect()` clears `lastChannel`.** Matches the old `TeamWebSocketManager` (nil'd `currentChannel`); `socket.reconnect()` after a manual disconnect is a no-op. Safe because in `.disconnected` `connect(channel:)` never consults `lastChannel`, and no callback can reach `scheduleReconnect` after the generation bump. The banner never calls `socket.reconnect()` (§3), so the transport helper stays a convenience with old-manager semantics.
3. **Close codes.** `teardown(closeCode: URLSessionWebSocketTask.CloseCode = .goingAway)`; `disconnect()` calls `teardown(closeCode: .normalClosure)` so a user-initiated close is what the server saw before A; failure and channel-switch teardowns keep `.goingAway`. `FakeWebSocketTask` records the code it was cancelled with (`lastCloseCode`) so this is testable.
4. **Offline cold start.** `ConciergeViewModel.waitForSocketConnected` becomes `-> Bool` and consumes `viewModel.$connectionState.values` instead of polling `socket.isConnected`: returns `true` on `.connected`; returns `false` immediately on `.disconnected` (nothing is pending — not paired, or host unconfigured) or when the 5 s timeout elapses while still `.connecting`/`.reconnecting`. On `false`, `runFlow` sets `state = .error("Not connected. Retry when reconnected.")` and returns **without** sending anything and without `store.clear()` — today's flow, if it ever ran while offline, would burn 3 s + 3 s + 5 s of dead timeouts and wipe the cached concierge id. The existing Retry button (`concierge.retry`) re-runs the flow. Waiting through `.reconnecting` rather than bailing on it is deliberate: on a cold start with a flaky link the first backoff is 2 s and often succeeds inside the 5 s budget.
5. **Sendable capture.** In `receive()`, the `.failure` branch reads `self.task?.closeCode.rawValue == 4001` instead of the captured `task` (the `gen == self.generation` guard already proves `self.task` is that task). Verified by the macOS build producing no Sendable warning for that closure.

### 9. Integration points / file map

| File | Change |
|---|---|
| `Managers/BeekeeperSocket.swift` | fixes 1, 2, 3, 5 |
| `Models/UserFacingError.swift` | new |
| `Theme/Components/KeepurConnectionBanner.swift` | new + pbxproj wiring |
| `ViewModels/ChatViewModel.swift` | §1, §4, §5, §6 |
| `ViewModels/TeamViewModel.swift` | §1, §7 |
| `Views/ChatView.swift`, `Views/MessageBubble.swift` | mount banner; `pendingReason` badge |
| `Views/Team/TeamRootView.swift`, `Views/Team/TeamChatView.swift`, `Views/Team/TeamMessageBubble.swift` | banner replaces button; dot; `isOffline` badge |
| `Views/SessionListView.swift`, `Views/SettingsView.swift`, `Views/WorkspacePickerView.swift` | `connectionState` reads; picker re-browse |
| `Views/BeekeeperRootView.swift` | fix 4 |
| `KeeperTests/FakeWebSocketTask.swift` | record cancel close code |
| `KeeperTests/KeepurConnectionBannerTests.swift` | new |
| `KeeperTests/TeamViewModelTests.swift`, `BeekeeperSocketTests.swift`, `ChatViewModelSocketTests.swift`, `ConciergeViewModelTests.swift`, `TeamMessageBubbleTests.swift` | extended / rewritten cases below |

`CLAUDE.md` needs no change (its "Auto-reconnect" bullet is still accurate). macOS target must build (`xcodebuild build -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`).

## Edge cases

- **Typing during cold-start `.connecting`** → `.offline`; sent after the first `session_list`; if the list never arrives, the 5 s fallback flushes through the normal busy gate.
- **"Retry now" while a retry handshake is in flight** → no-op (`connect` same-channel guard); button stays enabled; next state change repaints.
- **`session_list` omits a session with `.offline` entries** → entries dropped, badge gone, bubble stays; if that session was non-idle client-side, full `session_ended` cleanup.
- **Concierge slot** is never in `sessionsTabOnly`; the absent-id check uses the full reply so it is not reaped. Its queued messages flush via `statusFor(conciergeId) == "idle"` (set on `session_info`).
- **`/clear` handoff or `session_replaced` while entries are queued** → existing `clearPendingMessages` / migration paths, now updating `pendingReasons`.
- **Team: ack lost to the disconnect** → re-sent; possible server duplicate (at-least-once; E dedups).
- **Team: channel archived/left while offline entries exist** → row missing on re-send → id dropped.
- **Team/Beekeeper: app killed with queued entries** → in-memory queues lost; rows persist (Beekeeper without badge, Team with `pending: true` shown as "sending" — pre-existing, E's reconcile).
- **`lastError` set while the user is on another tab** → auto-clears in 6 s unseen; acceptable, it is a toast not a log.
- **Hive-vanished** → `lastError` + `.disconnected`; see §7 for the post-6 s fallback.
- **`unpair()` / 4001** → `socket.disconnect()` → `connectionState = .disconnected`; the view tree switches to pairing so the banner is irrelevant. Both VMs are `@StateObject`s on `ContentView` and survive re-pairing, so without a clear the queued entries would flush into the *new* pairing's sessions. ⚠ Delegated (6): `unpair()` also clears `pendingMessages`/`pendingReasons`; `TeamViewModel.handleAuthFailure` clears `offlineMessageIds`/`offlineAttachments`/`pendingMessageIds`. One line each.

## Testing contract

All in `KeeperTests/`, run on the iOS Simulator by CI (`.github/workflows/test.yml`). Existing helpers: `FakeWebSocketTaskFactory`, `FakeWebSocketTask` (`completeHandshake`, `deliver`, `failReceive`), `FakeCredentialStore`, in-memory `ModelContainer`, `settle()`.

**`KeepurConnectionBannerTests` (new, pure mapping + smoke)**
1. `.connected`/nil → `presentation` is nil.
2. `.connecting`/nil → "Connecting…", no action, warning, label "Connecting".
3. `.reconnecting(3)`/nil → "Reconnecting…", action "Retry now", label contains "attempt 3", the visible text does not contain "3".
4. `.disconnected`/nil → "Not connected. Messages will send when reconnected.", action "Retry", danger.
5. Error wins in every state: for each of the four states with `UserFacingError("boom")`, text == "boom", tint danger, `dismissesOnTap == true`, and the action is unchanged from the nil-error row (none / none / "Retry now" / "Retry").
6. Smoke: `_ = KeepurConnectionBanner(state:error:onRetry:onDismissError:).body` for every row.

**`TeamViewModelTests`** (seed `capability._setHivesForTesting(["hive-1"])` as the existing test does)
7. `testOfflineSendIsQueuedAndResentOnReconnect`: before any connect, `sendMessage("hello")` → one row `pending == true`, `offlineMessageIds == [row.id]`, factory made 0 tasks. `connectIfPossible()`, `completeHandshake()`, `settle()` → the fake's `sentTexts` contains a `message` frame with `text == "hello"` after the bookkeeping frames; `offlineMessageIds` empty. Deliver `{"type":"ack","id":<that frame's id>}` → row `pending == false`.
8. `testUnackedMessagesMoveToOfflineOnDisconnect`: connect + handshake; `sendMessage("a")` → frame sent, still pending. `failReceive(closeCode: .abnormalClosure)`, `settle()` → `connectionState == .reconnecting(attempt: 1)`, `offlineMessageIds == [row.id]`. `reconnect()`, handshake on the new task → a second `message` frame with `text == "a"` and a **different** id; ack it → `pending == false`.
9. `testConnectionStateFollowsSocketAndRetryOpensFreshTask` (replaces `testBannerReturnsAfterFailedManualRetry`): handshake failure → `vm.connectionState == .reconnecting(attempt: 1)` and `vm.disconnectedBanner` no longer exists; `vm.reconnect()` → `factory.made.count == 2` immediately; second failure → `.reconnecting(attempt: 2)`.
10. `testSlashCommandWhileOfflineSetsLastError`: `sendMessage("/new x")` with no connection → `lastError?.text == "Not connected. Try again when reconnected."`, no rows inserted, `messageText` cleared.
11. `testErrorFrameSetsLastError`: connected; deliver `{"type":"error","message":"nope"}` → `lastError?.text == "nope"`.

**`ChatViewModelSocketTests`** ⚠(3)
12. `testSendWhileConnectingQueuesOfflineAndFlushesAfterSessionList`: `configure`; set `currentSessionId = "s1"` and `sessionStatuses["s1"] = "idle"`; `messageText = "hi"; sendText()` before the handshake → `pendingReasons[rowId] == .offline`, nothing sent. Handshake, `settle()`, deliver `session_list` with `s1` idle → the fake's `sentTexts` contains a `message` frame `"hi"`, `pendingReasons` empty.
13. `testOfflineEntryReclassifiedBusyWhenServerBusy`: as 12 but the `session_list` reports `s1` `busy` → `pendingReasons[rowId] == .busy`, no `message` frame; deliver `status idle s1` → frame sent, reason cleared.
14. `testErrorWithNilSessionIdSetsLastErrorNotBubble`: connected; deliver `{"type":"error","message":"bad"}` → `lastError?.text == "bad"`, zero `Message` rows with `role == "system"`. With `"sessionId":"s1"` → one system row, `lastError` nil.
15. `testAbsentBusySessionGetsSessionEndedCleanup`: `sessionStatuses["gone"] = "thinking"`, an `.offline` entry queued for `"gone"`; deliver `session_list` without `gone` → `sessionStatuses["gone"] == nil`, `pendingReasons` empty, no frame sent.

**`BeekeeperSocketTests`**
16. `testBailedReconnectResetsAttemptCount`: `maxReconnectDelay = 0.01`, `tokenReadRetryDelay = .milliseconds(1)`, `maxTokenReadRetries = 1`. Connect, fail handshake → `.reconnecting(1)`; set `credentials.token = nil`; sleep 50 ms → `.disconnected`. Restore the token; `connect` → `state == .connecting`; fail the handshake → `.reconnecting(attempt: 1)`, not 2.
17. `testReconnectAfterDisconnectIsNoOp`: connect + handshake; `disconnect()`; `reconnect()` → `factory.made.count == 1`, `lastChannel == nil`, `state == .disconnected`.
18. `testDisconnectClosesNormallyAndFailureClosesGoingAway`: after `disconnect()` the fake's `lastCloseCode == .normalClosure`; after a handshake failure on a fresh socket the cancelled task's `lastCloseCode == .goingAway`.

**`ConciergeViewModelTests`**
19. `testRunFlowBailsWithoutClearingCacheWhenDisconnected`: socket with `tokenReadRetryDelay: .milliseconds(1), maxTokenReadRetries: 1`, `credentials.token = nil`; cache a session; `configure`; sleep 50 ms → `vm.connectionState == .disconnected`. `concierge.start` → within 500 ms `state == .error(...)`, `store.cachedSession` still set, factory made 0 tasks.
20. The existing `testRunFlowWaitsForHandshakeBeforeCacheHitResume` keeps passing unchanged (it drives `.connecting → .connected`).

**`TeamMessageBubbleTests`**: add an `isOffline: true` instantiation to `testUserBubbleInstantiates`. A matching `MessageBubble(pendingReason: .offline)` smoke is welcome if `/create-tests` adds a `MessageBubbleTests` file, but not required.

**Build gate**: iOS test suite green; macOS build green with no new warnings; `grep -rn 'viewModel\.socket\.' Views` returns nothing; `grep -rn 'disconnectedBanner\|retryConnect' .` returns nothing.

## Open assumptions (⚠ delegated, non-blocking)

1. Team banner mounts once in `TeamRootView` (old banner's slot), not additionally in `TeamChatView`.
2. `offlineMessageIds` is an ordered `[String]` (epic wrote `Set<String>` but requires original-order re-send).
3. Beekeeper offline tests ship in B's `ChatViewModelSocketTests` rather than waiting for C; C re-homes them into `ChatViewModelTests`.
4. Banner surface is `bgSunkenDynamic`; the epic's `honey100` alternative is not dark-mode-safe.
5. `WorkspacePickerView` re-browses on the `.connected` transition instead of the button calling `browse()` while still handshaking.
6. `unpair()` / `handleAuthFailure()` clear the in-memory queues so nothing flushes into a different pairing.
7. `lastError` auto-clear applies uniformly (6 s), including the hive-vanished text; the fallback copy after that is "Not connected…".
8. `disconnect()` uses `.normalClosure`; the server is not known to distinguish 1000 from 1001, so this only restores pre-A wire behavior.

No `QUESTIONS_FOR_HUMAN`: every choice above is a routine engineering call inside the approved epic design.

## Out-of-scope findings to carry (for the review phase, not this spec)

- `TeamViewModel.sendMessage` sends an empty-text `message` frame for attachment-only sends (pre-existing); E or a hygiene ticket.
- `ConciergeViewModel` still polls `currentSessionId`/`serverSessions` at 50 ms (C replaces with the decoded-frame stream).
- Hive-vanished path has no unit test (needs a `CapabilityManager.refresh` seam); note on KPR-445 (E).
