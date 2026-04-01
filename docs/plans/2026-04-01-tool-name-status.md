# Implementation Plan: Tool Name in Status Messages

**Ticket:** #12
**Spec:** `docs/specs/2026-04-01-tool-name-status.md`
**Branch:** `12-tool-name-status`

## Overview

Display the tool name (e.g., "Running Read...") in the status indicator when the server sends a `toolName` field in status messages. Falls back to "Running tool..." when absent.

## Tasks

### 1. Protocol Layer (`Models/WSMessage.swift`)

- Add `toolName: String?` parameter to `WSIncoming.status` case
- Update the `"status"` decode branch to extract `toolName` from JSON

### 2. ViewModel Layer (`ViewModels/ChatViewModel.swift`)

- Add `@Published var sessionToolNames: [String: String] = [:]` dictionary
- Add `func toolNameFor(_ sessionId: String) -> String?` helper
- In `.status` handler:
  - Store `toolName` when `state == "tool_running"` and toolName is non-nil
  - Clear tool name when state transitions away from `tool_running`
  - Clear tool name on `session_ended`

### 3. UI Layer (`Views/ChatView.swift`)

- Add `toolName: String?` parameter to `StatusIndicator`
- Update the `tool_running` branch to display `"Running \(toolName)..."` when present, `"Running tool..."` when nil
- Update `StatusIndicator` call site to pass `viewModel.toolNameFor(sessionId)`

## Files Modified

| File | Change |
|------|--------|
| `Models/WSMessage.swift` | Add `toolName` to `.status` case + decode |
| `ViewModels/ChatViewModel.swift` | Add `sessionToolNames`, update handler |
| `Views/ChatView.swift` | Pass + display `toolName` in `StatusIndicator` |

## Risks

- None significant — `toolName` is optional, backwards compatible
- No new dependencies
