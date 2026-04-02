# Tool Output Display

**Date:** 2026-04-02
**Status:** Draft

## Problem

When the beekeeper server executes tools (Bash, Read, Write, Grep, etc.) via the Claude Agent SDK, the raw tool output is consumed internally and fed back to Claude — but never forwarded to the iOS client. The user only sees Claude's commentary about the result, not the actual output. This makes it hard to follow what's happening, especially for Bash commands and file reads.

## Server-Side Context

The server-side changes are already implemented in the `hive` repo. Beekeeper now:

1. Tracks `tool_use_id -> tool_name` from `content_block_start` and `tool_progress` SDK events
2. Intercepts `SDKUserMessage` (type `"user"`) in the `runQuery()` loop
3. Extracts `tool_result` content blocks (handles both string and array-of-blocks content formats)
4. Skips replayed and synthetic messages
5. Truncates output at 10,000 characters
6. Sends a new `tool_output` WebSocket message:

```json
{
  "type": "tool_output",
  "toolName": "Bash",
  "output": "total 48\ndrwxr-xr-x  12 user staff ...",
  "toolUseId": "toolu_abc123",
  "sessionId": "sess-xyz"
}
```

## Client-Side Changes Required

### 1. WSMessage.swift — Decode the new message type

Add a `.toolOutput` case to `WSIncoming`:

```swift
case toolOutput(toolName: String, output: String, toolUseId: String, sessionId: String)
```

Decode in the existing switch on `type`:

```swift
case "tool_output":
    guard let toolName = json["toolName"] as? String,
          let output = json["output"] as? String,
          let toolUseId = json["toolUseId"] as? String,
          let sessionId = json["sessionId"] as? String else { return nil }
    return .toolOutput(toolName: toolName, output: output, toolUseId: toolUseId, sessionId: sessionId)
```

### 2. ChatViewModel.swift — Handle and persist

Add a case in `handleIncoming()`:

```swift
case .toolOutput(let toolName, let output, _, let sessionId):
    let msg = Message(sessionId: sessionId, text: "[\(toolName)]\n\(output)", role: "tool")
    context.insert(msg)
    try? context.save()
```

Key decisions:
- **role = `"tool"`** — new role value, distinct from user/assistant/system. The `Message` model's `role` is a plain `String`, so no schema migration needed.
- **Text format**: `[ToolName]\n{output}` — the bracketed header is parseable by the bubble view for styled rendering.
- **No streaming finalization** — tool output arrives as a discrete event between assistant turns, not mid-stream. The streaming state should remain intact.

### 3. MessageBubble.swift — Distinct tool bubble

Add a `"tool"` case to the `body` switch and a `toolBubble` computed property:

**Visual design:**
- Left-aligned (server-originated, like assistant messages)
- Header row: terminal icon (`terminal.fill`) + tool name in caption bold
- Body: monospaced font, text-selectable
- Background: `systemGray6` (lighter than assistant's `systemGray5`) to distinguish
- Scroll-capped at 200pt for long output
- Timestamp below

**Rough layout:**
```
 [terminal icon] [Bash]
 ┌──────────────────────────┐
 │ total 48                 │
 │ drwxr-xr-x  12 user ... │  ← monospaced, scrollable
 │ -rw-r--r--   1 user ... │
 └──────────────────────────┘
 12:34 PM
```

## Files to Modify

| File | Change |
|------|--------|
| `Models/WSMessage.swift` | Add `.toolOutput` case + decode branch |
| `ViewModels/ChatViewModel.swift` | Handle `.toolOutput` in `handleIncoming()` |
| `Views/MessageBubble.swift` | Add `"tool"` case + `toolBubble` view |

## Edge Cases

- **Empty output**: Some tools (Write, Edit) may produce empty results. The server skips empty content (`if (!output) continue`), so the client won't receive these.
- **Very long output**: Truncated at 10K chars server-side with `"… (truncated)"` suffix. The 200pt scroll cap on the client handles the visual overflow.
- **Session resume**: Server skips `isReplay` messages, so old tool outputs won't re-appear as duplicates.
- **Synthetic messages**: Server skips `isSynthetic`, so internal SDK bookkeeping messages are filtered out.
- **Unknown message fallback**: If the client receives `tool_output` before this code ships, the existing `default` branch in `WSIncoming.decode` will produce `.unknown(raw:)`, which renders harmlessly as an unknown bubble.

## Non-Goals

- Collapsible/accordion UI (can add later)
- Image content from tool results (e.g., screenshots) — text-only for now
- Filtering/hiding specific tool outputs by name
