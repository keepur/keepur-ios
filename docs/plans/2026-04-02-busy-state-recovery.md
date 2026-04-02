# Fix Busy State Deadlock — Implementation Plan

> **For agentic workers:** Use dodi-dev:implement to execute this plan.

**Ticket:** #14
**Spec:** `../hive/docs/specs/2026-04-02-keepur-busy-state-recovery-design.md`
**Branch:** `14/fix-busy-state-deadlock`

**Goal:** Eliminate the permanent "Server busy..." deadlock by widening the message queue gate, flushing one message at a time, adding a stale-busy watchdog, and reconciling state on reconnect.

**Architecture:** All changes are client-side. ChatViewModel gets smarter queuing logic and a per-session watchdog timer. WebSocketManager gets an `onConnect` callback so the ViewModel can sync state after reconnect.

**Tech Stack:** Swift 5, SwiftUI, Swift Concurrency (@MainActor, Task)

---

## Files Changed

| File | Change |
|------|--------|
| `Managers/WebSocketManager.swift` | Add `onConnect` callback, fire after successful connection |
| `ViewModels/ChatViewModel.swift` | Widen queue gate, one-at-a-time flush, busy watchdog timer, reconnect reconciliation |

No new files. No protocol changes. No server changes.

---

## Task 1: Add `onConnect` callback to WebSocketManager

**Files:**
- Modify: `Managers/WebSocketManager.swift`

- [ ] **Step 1:** Add `onConnect` callback property alongside existing `onMessage` and `onAuthFailure`

At line 10 (after `var onAuthFailure`), add:

```swift
var onConnect: (() -> Void)?
```

- [ ] **Step 2:** Fire `onConnect` in `connect()` after the connection is established

In `connect()`, after `receiveMessage()` (line 55), add:

```swift
onConnect?()
```

- [ ] **Step 3:** Commit

```bash
git add Managers/WebSocketManager.swift
git commit -m "feat: add onConnect callback to WebSocketManager"
```

---

## Task 2: Widen queue gate and replace flush logic in ChatViewModel

**Files:**
- Modify: `ViewModels/ChatViewModel.swift`

- [ ] **Step 1:** Widen the queue gate in `sendText()`

Replace the condition at line 65:

```swift
// OLD:
if statusFor(sessionId) == "busy" {
```

With:

```swift
// NEW:
if statusFor(sessionId) != "idle" {
```

Any non-idle state (thinking, tool_running, tool_starting, busy) means the server cannot accept a message. Queue it locally.

- [ ] **Step 2:** Replace `flushPendingMessages` with `flushNextPendingMessage`

Replace the entire `flushPendingMessages(for:)` method (lines 242-248):

```swift
// OLD:
private func flushPendingMessages(for sessionId: String) {
    let toSend = pendingMessages.filter { $0.sessionId == sessionId }
    clearPendingMessages(for: sessionId)
    for pending in toSend {
        ws.send(.message(text: pending.text, sessionId: pending.sessionId))
    }
}
```

With:

```swift
// NEW:
private func flushNextPendingMessage(for sessionId: String) {
    guard let index = pendingMessages.firstIndex(where: { $0.sessionId == sessionId }) else { return }
    let pending = pendingMessages.remove(at: index)
    pendingMessageIds.remove(pending.messageId)
    ws.send(.message(text: pending.text, sessionId: pending.sessionId))
}
```

Sends only the first pending message, removes it from the queue. The rest drain one per idle cycle.

- [ ] **Step 3:** Update the status handler to flush on idle transition

Replace the flush logic block in the `.status` handler (lines 166-173):

```swift
// OLD:
// Flush pending messages when transitioning away from busy
if previousState == "busy" && state != "busy" {
    if state == "session_ended" {
        clearPendingMessages(for: effectiveId)
    } else {
        flushPendingMessages(for: effectiveId)
    }
}
```

With:

```swift
// NEW:
// Flush next pending message when session becomes idle
if state == "idle" && !pendingMessages.filter({ $0.sessionId == effectiveId }).isEmpty {
    flushNextPendingMessage(for: effectiveId)
}
```

No need to track previous state. Whenever we receive `idle` and have pending messages, flush one.

- [ ] **Step 4:** Add `clearPendingMessages` to the `session_ended` block

The old flush logic (lines 166-173) had a `session_ended` → `clearPendingMessages` branch. We removed that block. Add the call into the existing `session_ended` cleanup block (line 175), after the other cleanup lines:

```swift
if state == "session_ended" {
    streamingMessageIds.removeValue(forKey: effectiveId)
    pendingApprovals.removeValue(forKey: effectiveId)
    sessionStatuses.removeValue(forKey: effectiveId)
    sessionToolNames.removeValue(forKey: effectiveId)
    clearPendingMessages(for: effectiveId)  // was in the old flush block
}
```

- [ ] **Step 5:** Remove the now-unused `previousState` variable

The `let previousState = sessionStatuses[effectiveId]` at line 152 is no longer referenced. Remove it.

- [ ] **Step 6:** Commit

```bash
git add ViewModels/ChatViewModel.swift
git commit -m "fix: widen queue gate and flush one message per idle cycle"
```

---

## Task 3: Add stale-busy watchdog timer

**Files:**
- Modify: `ViewModels/ChatViewModel.swift`

- [ ] **Step 1:** Add timer properties

After the `pendingMessages` declaration (line 37), add:

```swift
private static let staleBusyTimeout: TimeInterval = 90
private var busyTimers: [String: Task<Void, Never>] = [:]
```

- [ ] **Step 2:** Start/reset timer on non-idle status, cancel on idle

In the `.status` handler, after updating `sessionStatuses[effectiveId] = state` and after the tool name logic, add timer management:

```swift
// Stale-busy watchdog
if state != "idle" && state != "session_ended" {
    busyTimers[effectiveId]?.cancel()
    busyTimers[effectiveId] = Task { @MainActor [weak self] in
        try? await Task.sleep(for: .seconds(Self.staleBusyTimeout))
        guard !Task.isCancelled else { return }
        self?.sessionStatuses[effectiveId] = "idle"
        self?.flushNextPendingMessage(for: effectiveId)
    }
} else {
    busyTimers[effectiveId]?.cancel()
    busyTimers.removeValue(forKey: effectiveId)
}
```

- [ ] **Step 3:** Clean up timer on session end

In the `session_ended` block (around line 175), add timer cleanup:

```swift
busyTimers[effectiveId]?.cancel()
busyTimers.removeValue(forKey: effectiveId)
```

- [ ] **Step 4:** Commit

```bash
git add ViewModels/ChatViewModel.swift
git commit -m "feat: add 90s stale-busy watchdog timer per session"
```

---

## Task 4: Reconcile state on reconnect

**Files:**
- Modify: `ViewModels/ChatViewModel.swift`

- [ ] **Step 1:** Wire `onConnect` in `configure()`

In `configure(context:)`, after the `ws.onAuthFailure` block (line 53), add:

```swift
ws.onConnect = { [weak self] in
    self?.listSessions()
}
```

- [ ] **Step 2:** Add status reconciliation to `syncSessions()`

In `syncSessions(serverSessions:context:)`, after the loop that inserts missing server sessions and before `try? context.save()`, add:

```swift
// Reconcile session statuses from server state
for server in serverSessions {
    let serverState = server.state  // "idle" or "busy"
    let clientState = sessionStatuses[server.sessionId]
    if clientState != nil && clientState != "idle" && serverState == "idle" {
        sessionStatuses[server.sessionId] = "idle"
        busyTimers[server.sessionId]?.cancel()
        busyTimers.removeValue(forKey: server.sessionId)
        flushNextPendingMessage(for: server.sessionId)
    } else if clientState == nil || clientState == "idle" {
        sessionStatuses[server.sessionId] = serverState
    }
}
```

If the client thinks a session is busy but the server says idle, transition to idle and flush. If the client has no opinion, accept the server's state.

- [ ] **Step 3:** Commit

```bash
git add ViewModels/ChatViewModel.swift Managers/WebSocketManager.swift
git commit -m "feat: reconcile session state on WebSocket reconnect"
```
