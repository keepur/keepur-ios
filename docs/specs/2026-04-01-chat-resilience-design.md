# Chat Resilience & Server Interaction

**Date:** 2026-04-01
**Status:** Draft
**Scope:** WebSocket message handling, chat UI, server status states

## Problem

The chat client has gaps in how it handles server states and messages:

1. No "busy" state — if the server is overloaded, there's no feedback to the user
2. No way to interrupt/cancel a running operation
3. Multiple-choice questions from the server aren't rendered — they silently vanish
4. Any unrecognized server message disappears without a trace

## Design Decisions

| Feature | Decision |
|---------|----------|
| Busy state | "waiting" badge on the user's last message bubble + status bubble with clock icon |
| Interrupt/cancel | Small X button on the status indicator bubble |
| Multiple-choice questions | Server sends as plain text message — render as normal assistant bubble |
| Catch-all | Unrecognized messages render as assistant bubble with role `"unknown"` and "Unsupported message" caption |

---

## 1. Busy State

### Server Contract

Server sends the existing status message type with a new state value:

```json
{ "type": "status", "state": "busy" }
```

No new message type needed — `busy` is just another `state` string alongside `thinking`, `tool_running`, and `session_ended`.

### Client Behavior

When `currentStatus` becomes `"busy"`:

- Find the last user message bubble in the current session
- Overlay a small **"waiting"** badge on it — bottom-trailing corner of the bubble
- Badge styling: rounded pill, secondary fill, caption2 font, subtle pulse animation
- The badge disappears when status changes away from `"busy"` (e.g. to `"thinking"` or `"idle"`)
- A `StatusIndicator` bubble also appears below with a **clock icon** + "Server busy..." text and the cancel X button

### StatusIndicator Changes

`StatusIndicator` currently branches on `"thinking"` (bouncing dots) vs everything else (hammer + "Running tool..."). Add an explicit branch for `"busy"`:

- `"thinking"` → bouncing dots (unchanged)
- `"tool_running"` → hammer + "Running tool..." (unchanged)
- `"busy"` → `clock` SF Symbol + "Server busy..." text

### ChatView Changes

Add `"busy"` to the `StatusIndicator` visibility condition:

```swift
if viewModel.currentSessionId == sessionId &&
    (viewModel.currentStatus == "thinking" || viewModel.currentStatus == "tool_running" || viewModel.currentStatus == "busy") {
```

Also update the scroll `onChange` handler to include `"busy"` so the view auto-scrolls to the status indicator.

### MessageBubble Signature Change

`MessageBubble` currently takes only `message: Message`. Update the initializer:

```swift
MessageBubble(message: Message, currentStatus: String = "idle", isLastUserMessage: Bool = false)
```

- `currentStatus` — the current server status string
- `isLastUserMessage` — whether this message is the last user message in the session

The badge renders only when `isLastUserMessage == true && currentStatus == "busy"`. Default values ensure existing call sites don't break.

### Input Bar During Busy

The send button remains enabled during `"busy"` — the user can keep typing and sending. Messages are **queued locally** and sent automatically when the server becomes available.

### Client-Side Message Queue

When status is `"busy"` and the user sends a message:

1. The message is saved to SwiftData as usual (so it appears in the chat immediately)
2. Instead of sending via WebSocket, it's added to a local `pendingMessages` queue in `ChatViewModel`
3. The "waiting" badge appears on **all** queued user messages (not just the last one)
4. When status transitions away from `"busy"` (e.g. to `"idle"` or `"thinking"`), the queue is flushed — messages are sent via WebSocket in order

```swift
// ChatViewModel
private var pendingMessages: [(text: String, sessionId: String)] = []
```

**Flush trigger:** In the `currentStatus` `didSet` or in `handleIncoming(.status)`, when the new state is not `"busy"` and `pendingMessages` is non-empty, iterate and send each via `ws.send(.message(...))`, then clear the queue.

### MessageBubble Badge Update

Since multiple messages can be queued, update the badge logic:

```swift
MessageBubble(message: Message, showWaitingBadge: Bool = false)
```

`showWaitingBadge` is `true` for any user message sent while status was `"busy"`. `ChatView` determines this by checking whether the message's ID is in the pending queue, or by comparing timestamps against when `"busy"` started.

**Simpler approach:** `ChatViewModel` publishes a `Set<String>` of pending message IDs. `ChatView` checks membership when rendering each bubble.

```swift
// ChatViewModel
@Published var pendingMessageIds: Set<String> = []
```

### Files Changed

- **`ChatView.swift`** — add `"busy"` to `StatusIndicator` visibility guard and scroll handler; pass `showWaitingBadge` to `MessageBubble`
- **`MessageBubble.swift`** — update init signature; add "waiting" badge overlay
- **`ChatViewModel.swift`** — add `pendingMessages` queue, `pendingMessageIds` published set, queue-flush logic in status handler, modify `sendText()` to queue when busy

### Edge Cases

- If the user sends multiple messages while busy, all get queued and all show the "waiting" badge
- When the queue flushes, messages are sent in chronological order
- If status jumps from `busy` straight to `session_ended`, clear the queue without sending — the session is over
- If the user cancels (X button) while messages are queued, the queue is also cleared (cancelled messages don't get sent)

---

## 2. Interrupt / Cancel

### Server Contract

New outgoing message type:

```json
{ "type": "cancel", "sessionId": "..." }
```

Server should abort the current operation for that session and transition status to `"idle"` (or send back whatever status is appropriate).

### Client Behavior

The existing `StatusIndicator` bubble (shown during `thinking`, `tool_running`, and `busy`) gets a small **X button** on its trailing edge.

- Tapping X calls `viewModel.cancelCurrentOperation()`
- ViewModel guards on `currentSessionId != nil` before sending — if nil, no-op (the X button is only visible when a status indicator is showing, which implies an active session)
- ViewModel sends `WSOutgoing.cancel(sessionId:)` via WebSocket
- Status indicator remains visible until the server responds with a new status

### UI Details

- X button: `xmark.circle.fill`, caption size, secondary color
- Positioned trailing within the status bubble's `HStack`
- No confirmation dialog — immediate send (same as Esc key in CLI)

### Files Changed

- **`WSMessage.swift`** — add `case cancel(sessionId: String)` to `WSOutgoing` with `encode()` support
- **`ChatViewModel.swift`** — add `cancelCurrentOperation()` method with `currentSessionId` nil guard
- **`ChatView.swift`** — add X button to `StatusIndicator`, wire to viewModel via a cancel closure

---

## 3A. Multiple-Choice Questions

### Server Contract

No special message type needed. The server formats the question as plain text and sends it as a regular message:

```json
{ "type": "message", "text": "What's the primary pain...?\n\n1. Agent management UI\n2. System monitoring\n3. Full control panel\n4. Beekeeper frontend", "sessionId": "...", "final": true }
```

The user reads the options and replies with their answer as a normal text message.

### Client Behavior

Nothing to change. The existing `message` handling already renders this correctly as an assistant bubble with the text content.

### Server-Side Note

If the server currently sends questions as a distinct type (e.g. `type: "question"`), it should be changed to send them as `type: "message"` instead. Alternatively, the catch-all (section 3B) will handle it.

---

## 3B. Catch-All for Unrecognized Messages

### Problem

Messages can vanish at two levels:

1. **Unknown type** — `WSIncoming.decode()` hits the `default` branch and returns `nil`
2. **Unparseable JSON** — the top-level guard fails (missing `type` field, malformed JSON) and `decode()` returns `nil`

In both cases, `WebSocketManager` gets `nil` back and silently drops the message.

### Client Behavior

When the client receives a WebSocket message that cannot be parsed into a known type:

1. Extract whatever text content is available from the raw JSON (check `text`, `message`, `content` fields, fall back to the raw JSON string)
2. Create a new `WSIncoming.unknown(raw: String)` case with the extracted content
3. `ChatViewModel` handles `.unknown` by inserting a message with role `"unknown"` into the chat
4. `MessageBubble` renders role `"unknown"` as an assistant-style bubble with a small **"Unsupported message"** caption above the content, styled in caption2/secondary

### Using `role` Instead of Text Prefix

Following the codebase pattern where `MessageBubble` switches on `message.role` (`"user"`, `"assistant"`, `"system"`), unsupported messages use role `"unknown"` — not a text prefix. This keeps detection clean and avoids false matches.

### Decode Changes

Two changes to ensure zero message loss:

**A) `WSIncoming.decode()` — default branch:**

```swift
default:
    let raw = WSIncoming.extractText(from: json) ?? String(data: data, encoding: .utf8) ?? ""
    return .unknown(raw: raw)
```

**B) `WebSocketManager.receiveMessage()` — nil fallback:**

When `WSIncoming.decode()` returns `nil` (top-level parse failure), construct `.unknown` from the raw string directly:

```swift
if let data = text.data(using: .utf8) {
    let incoming = WSIncoming.decode(from: data)
        ?? .unknown(raw: text)
    self.onMessage?(incoming)
}
```

This ensures messages that fail before reaching the type `switch` are still surfaced.

### `extractText` Placement

`private static func extractText(from json: [String: Any]) -> String?` on `WSIncoming` — checks common fields in priority order:

1. `json["text"]` as String
2. `json["message"]` as String
3. `json["content"]` as String

Returns `nil` if none found (caller falls back to raw string).

### Files Changed

- **`WSMessage.swift`** — add `case unknown(raw: String)` to `WSIncoming`, add `extractText` as private static method, update `decode()` default branch
- **`WebSocketManager.swift`** — update `receiveMessage()` to use nil-coalescing with `.unknown(raw:)` instead of `if let`
- **`ChatViewModel.swift`** — handle `.unknown` in `handleIncoming()`, insert message with role `"unknown"`
- **`MessageBubble.swift`** — add `"unknown"` case in role switch: assistant-style bubble with "Unsupported message" caption

---

## Status State Summary (After Changes)

| State | Visual Treatment | Cancel Button |
|-------|-----------------|---------------|
| `idle` | Nothing | No |
| `thinking` | Bouncing dots bubble | Yes (X) |
| `tool_running` | Hammer + "Running tool..." bubble | Yes (X) |
| `busy` | "waiting" badge on last user bubble + clock icon status bubble | Yes (X) |
| `session_ended` | System message + read-only input bar | No |

---

## Files NOT Changed

- **`Session.swift`** — no model changes needed
- **`SettingsView.swift`** — no settings changes
- **`WorkspacePickerView.swift`** — no impact
- **`ToolApprovalView.swift`** — no impact

---

## Non-Goals

- Custom multi-select UI for questions — plain text is sufficient
- Retry logic for cancelled operations — server handles that
- Detailed tool information in status bubbles (e.g. tool name) — future enhancement
- Persisting the message queue across app restarts — if the app is killed while busy, queued messages are lost
