# Tool Name in Status Messages

**Date:** 2026-04-01
**Status:** Draft
**Scope:** WebSocket protocol, status indicator UI

## Problem

The status indicator shows a generic "Running tool..." for all tool executions. The server now sends richer status information — including the tool name and more accurate thinking transitions — but the iOS client ignores the new `toolName` field.

## Server Changes (already deployed)

The `status` message type gained an optional `toolName` field:

```json
{ "type": "status", "state": "tool_running", "sessionId": "...", "toolName": "Read" }
{ "type": "status", "state": "tool_running", "sessionId": "...", "toolName": "Bash" }
{ "type": "status", "state": "thinking", "sessionId": "..." }
```

Three new emission points in `session-manager.ts`:
1. `content_block_start` with `type: "thinking"` → sends `status: thinking`
2. `content_block_start` with `type: "tool_use"` → sends `status: tool_running` + `toolName`
3. `tool_progress` → sends `status: tool_running` + `toolName` (was already sent, now includes name)

The `toolName` field is optional — older servers or edge cases may omit it.

## Design

| Aspect | Decision |
|--------|----------|
| Protocol | Add optional `toolName: String?` to `WSIncoming.status` case |
| ViewModel | Store `toolName` alongside session status |
| UI | Display tool name in `StatusIndicator` when present (e.g., "Running Read..." instead of "Running tool...") |
| Backwards compat | `toolName` is optional — fall back to "Running tool..." when nil |

---

## 1. Protocol Layer (`WSMessage.swift`)

### Current
```swift
case status(state: String, sessionId: String?)
```

### After
```swift
case status(state: String, sessionId: String?, toolName: String?)
```

Decode `toolName` from JSON when present:
```swift
case "status":
    guard let state = json["state"] as? String else { return nil }
    let sessionId = json["sessionId"] as? String
    let toolName = json["toolName"] as? String
    return .status(state: state, sessionId: sessionId, toolName: toolName)
```

---

## 2. ViewModel Layer (`ChatViewModel.swift`)

Add a per-session tool name store alongside `sessionStatuses`:

```swift
@Published var sessionToolNames: [String: String] = [:]

func toolNameFor(_ sessionId: String) -> String? {
    sessionToolNames[sessionId]
}
```

In the `.status` handler:
- When `state == "tool_running"` and `toolName` is non-nil, store it
- When state transitions away from `tool_running`, clear it

---

## 3. UI Layer (`ChatView.swift` — `StatusIndicator`)

### Current
```swift
Text("Running tool...")
```

### After
Pass optional `toolName` into `StatusIndicator`. Display:
- `"Running Read..."` when toolName is present
- `"Running tool..."` when nil (fallback)

The hammer icon stays. Only the label text changes.

---

## Files to Modify

| File | Change |
|------|--------|
| `Models/WSMessage.swift` | Add `toolName` to `.status` case + decode |
| `ViewModels/ChatViewModel.swift` | Add `sessionToolNames` dict, update status handler |
| `Views/ChatView.swift` | Pass `toolName` to `StatusIndicator`, update label |

## Out of Scope

- Tool-specific icons (e.g., terminal icon for Bash) — future enhancement
- Tool progress percentage — server doesn't send this yet
- Thinking sub-states (e.g., "extended thinking") — no visual distinction needed now
