# Keepur iOS — Multi-Session Support

**Date**: 2026-03-31
**Status**: Draft
**Server issue**: bot-dodi/hive#64
**Server spec**: `docs/specs/2026-03-31-beekeeper-multi-session-design.md` (in hive repo)

## Problem

Beekeeper's `SessionManager` is single-session — one `sessionId`, one workspace. The iOS app has multi-session UI (SwiftData `Session` model, `SessionListView`, messages keyed by `sessionId`), but the server can't support concurrent sessions. Hive #64 replaces the single `SessionManager` with a concurrent `Map<sessionId, SessionSlot>` and adds directory browsing so workspaces are no longer hardcoded.

This spec covers the client-side changes needed to match the new server protocol.

## Server Protocol Changes (Reference)

Full protocol defined in the hive repo spec. Summary of what affects the iOS client:

**Client → Server:**

| Type | Fields | Change |
|------|--------|--------|
| `message` | `text`, `sessionId` | `sessionId` now **required** (was optional) |
| `new_session` | `path` | Replaces `workspace` with `path` (absolute path) |
| `clear_session` | `sessionId` | **New** — remove session from server |
| `list_sessions` | (none) | **New** — request active session list |
| `browse` | `path?` | **New** — browse directory (default: `~`) |
| `approve` | `toolUseId` | Unchanged |
| `deny` | `toolUseId` | Unchanged |
| `ping` | (none) | Unchanged |

**Removed**: `switch_workspace`

**Server → Client:**

| Type | Fields | Change |
|------|--------|--------|
| `message` | `text`, `sessionId`, `final` | Unchanged |
| `session_info` | `sessionId`, `path` | Drop `workspace` name and `workspaces` list |
| `session_list` | `sessions: [{ sessionId, path, state }]` | **New** — sent on connect + response to `list_sessions` |
| `session_cleared` | `sessionId` | **New** — confirms session removal |
| `status` | `state`, `sessionId` | Add `sessionId` to scope status per-session |
| `tool_approval` | `toolUseId`, `tool`, `input`, `sessionId` | Add `sessionId` to scope approval per-session |
| `browse_result` | `path`, `entries: [{ name, isDirectory }]` | **New** — directory listing |
| `error` | `message`, `sessionId?` | `sessionId` optional (some errors are global) |
| `pong` | (none) | Unchanged |

**Removed status state**: `session_ended` — replaced by `session_cleared` message.

## Changes

### 1. WSMessage — protocol overhaul

**File**: `Models/WSMessage.swift`

**Outgoing (`WSOutgoing`):**

- `message(text:sessionId:)` — change `sessionId` from `String?` to `String` (required)
- `newSession(workspace:)` → `newSession(path: String)` — `path` is required, encode as `{ type: "new_session", path: "..." }`
- Add `clearSession(sessionId: String)` — `{ type: "clear_session", sessionId: "..." }`
- Add `listSessions` — `{ type: "list_sessions" }`
- Add `browse(path: String?)` — `{ type: "browse", path?: "..." }`

**Incoming (`WSIncoming`):**

- `sessionInfo` — change to `sessionInfo(sessionId: String, path: String)`. Drop `workspace` and `workspaces` fields. Decode `path` from JSON (was `workspace`).
- `status` — change to `status(state: String, sessionId: String?)`. Decode optional `sessionId`.
- `toolApproval` — change to `toolApproval(toolUseId: String, tool: String, input: String, sessionId: String?)`. Decode optional `sessionId`.
- `error` — change to `error(message: String, sessionId: String?)`. Decode optional `sessionId`.
- Add `sessionList(sessions: [ServerSession])` where `ServerSession` is a lightweight struct: `{ sessionId: String, path: String, state: String }`. Decode from `sessions` array in JSON.
- Add `sessionCleared(sessionId: String)` — decode `sessionId` from JSON.
- Add `browseResult(path: String, entries: [BrowseEntry])` where `BrowseEntry` is: `{ name: String, isDirectory: Bool }`. Decode from `path` + `entries` array.

**Supporting types** (defined alongside `WSIncoming`):

```swift
struct ServerSession {
    let sessionId: String
    let path: String
    let state: String
}

struct BrowseEntry {
    let name: String
    let isDirectory: Bool
}
```

### 2. Session model — workspace → path, add isStale

**File**: `Models/Session.swift`

- Rename `workspace: String` → `path: String` (absolute workspace path from server)
- Add `isStale: Bool = false` — set to `true` when session is not in server's `session_list` on reconnect

**Callers to update when renaming `workspace` → `path`:**
- `ChatViewModel.swift` — `session_info` handler creates `Session(id:workspace:)` → `Session(id:path:)`
- `SessionListView.swift` — `SessionRow` displays `session.workspace` → `session.path`

**SwiftData migration**: This is a schema-breaking rename. Since Keepur is pre-release, we delete the existing store on schema mismatch (already handled by `KeepurApp.init()`'s catch block). No migration plan needed.

### 3. New model — Workspace (remembered paths)

**New file**: `Models/Workspace.swift`

SwiftData model for locally remembered workspace paths:

```swift
@Model
final class Workspace {
    @Attribute(.unique) var path: String
    var displayName: String
    var lastUsed: Date

    init(path: String, lastUsed: Date = .now) {
        self.path = path
        self.displayName = URL(fileURLWithPath: path).lastPathComponent
        self.lastUsed = lastUsed
    }
}
```

`displayName` is the last path component (e.g., `/Users/may/projects/hive` → `hive`). Computed at init from `path`.

### 4. KeepurApp — register Workspace in schema

**File**: `KeepurApp.swift`

Add `Workspace.self` to the `Schema` initializer alongside `Session.self` and `Message.self`.

### 5. ChatViewModel — multi-session routing and browse state

**File**: `ViewModels/ChatViewModel.swift`

**Remove:**
- `@Published var currentWorkspace: String = ""`
- `@Published var availableWorkspaces: [String] = []`

**Add:**
- `@Published var currentPath: String = ""` — workspace path of active session
- `@Published var browseEntries: [BrowseEntry] = []` — current browse results
- `@Published var browsePath: String = ""` — current browsed directory path
- `@Published var serverSessions: [ServerSession] = []` — from `session_list`

**Streaming per-session:**
- Change `streamingMessageId: String?` → `streamingMessageIds: [String: String]` (keyed by sessionId)
- Change `lastCompletedMessageId: String?` → `lastCompletedMessageIds: [String: String]`
- `handleStreamingMessage` uses `streamingMessageIds[sessionId]` instead of single `streamingMessageId`

**Method changes:**

- `newSession(workspace:)` → `newSession(path: String)` — sends `.newSession(path:)`
- Add `clearSession(sessionId: String)` — sends `.clearSession(sessionId:)`, then removes session + messages from SwiftData locally
- Add `listSessions()` — sends `.listSessions`
- Add `browse(path: String? = nil)` — sends `.browse(path:)`

**`handleIncoming` changes:**

- `.sessionInfo(sessionId, path)` — create `Session(id: sessionId, path: path)`, set `currentPath = path`. Save `Workspace` with this path (update `lastUsed` if exists). No longer reads `workspace` or `workspaces`.

- `.status(state, sessionId)` — if `sessionId` matches `currentSessionId` (or `sessionId` is nil), update `currentStatus`. Otherwise ignore (status for a background session). Remove `session_ended` handling entirely.

- `.toolApproval(toolUseId, tool, input, sessionId)` — if `sessionId` matches `currentSessionId` (or is nil), set `pendingApproval`. If `sessionId` doesn't match, still set `pendingApproval` but include `sessionId` so the UI can indicate which session needs attention.

- `.error(message, sessionId)` — if `sessionId` is present, insert error message into that session. If nil, insert into `currentSessionId` (global error).

- `.sessionList(sessions)` — store in `serverSessions`. Sync with local SwiftData:
  1. Fetch all local `Session` objects
  2. For each local session not in server list → set `isStale = true`
  3. For each server session not in local store → create `Session(id: serverSession.sessionId, path: serverSession.path)`
  4. If `currentSessionId` is stale → set `currentSessionId = nil`

- `.sessionCleared(sessionId)` — delete local `Session` + its `Message`s from SwiftData. If `sessionId == currentSessionId`, set `currentSessionId = nil`.

- `.browseResult(path, entries)` — set `browsePath = path`, `browseEntries = entries`.

**ToolApproval struct update:**
- Add `sessionId: String?` field so the UI knows which session the approval belongs to.

### 6. SessionListView — workspace picker trigger, stale indicators

**File**: `Views/SessionListView.swift`

**Session row display:**
- Show last path component as title (e.g., `hive`) instead of `session.workspace`
- Show full `session.path` as subtitle in caption font, secondary color
- If `session.isStale`, dim the row (opacity 0.5) and show "Stale" badge

**Toolbar "New Session" menu** → replace workspace list with single "New Session" button that presents `WorkspacePickerView` as a sheet.

**Swipe-to-delete**: Call `viewModel.clearSession(sessionId:)` which sends `clear_session` to server AND removes locally. Current implementation only deletes locally.

**Empty state**: Update "New Session" button to open workspace picker sheet.

### 7. New view — WorkspacePickerView (directory browser)

**New file**: `Views/WorkspacePickerView.swift`

Presented as a sheet from `SessionListView`.

**Layout:**

- **Top section — Recent Workspaces**: Query `Workspace` model sorted by `lastUsed` descending. Show as horizontal scroll of chips or a short list. Tap → `viewModel.newSession(path:)` → dismiss.

- **Browser section**: 
  - Path breadcrumb at top showing `viewModel.browsePath` (e.g., `~ / projects / hive`)
  - List of `viewModel.browseEntries`, directories only shown with folder icon, sorted directories-first then alphabetical (server already sorts this way)
  - Tap directory → `viewModel.browse(path: currentPath + "/" + entry.name)` to navigate deeper
  - "Back" / parent directory row at top of list (unless at `~`)

- **Bottom — Select button**: "Start Session Here" button → calls `viewModel.newSession(path: viewModel.browsePath)` → dismiss sheet.

**On appear**: Call `viewModel.browse()` (no path = home directory).

### 8. SettingsView — remove hardcoded workspace list

**File**: `Views/SettingsView.swift`

Remove the "Workspace" section (lines 34–53) that iterates `viewModel.availableWorkspaces`. Replace with:

- Show current session path: `viewModel.currentPath` (if non-empty)
- "Saved Workspaces" section: Query `Workspace` model, show each with swipe-to-delete to remove from remembered list

### 9. ChatView — scope status and approvals by sessionId

**File**: `Views/ChatView.swift`

**Navigation title**: Show last path component of the session's path. Currently uses `viewModel.currentWorkspace`. Change to compute from the `Session` model's `path` field (fetch session by `sessionId` prop, take `URL(fileURLWithPath: path).lastPathComponent`). Fallback to "Keepur".

**Status indicator**: Currently checks `viewModel.currentSessionId == sessionId`. This still works — the ViewModel only updates `currentStatus` when `sessionId` matches (see step 5). No change needed.

**Tool approval sheet**: Currently bound to `$viewModel.pendingApproval`. Add a guard: only present the sheet if `viewModel.pendingApproval?.sessionId == nil || viewModel.pendingApproval?.sessionId == sessionId`. This prevents showing an approval for session A while viewing session B's chat.

**Input bar disable**: Remove `viewModel.currentStatus == "session_ended"` check from the send button's disabled state. Sessions are now cleared (removed) rather than "ended" — if the session exists and is current, it's active.

### 10. Reconnect & stale session handling

No separate file — handled in `ChatViewModel.handleIncoming(.sessionList)` (described in step 5).

**Flow on reconnect:**
1. WebSocket reconnects (existing auto-reconnect logic)
2. Server sends `session_list` as first message
3. Client receives and syncs (step 5 logic)
4. Server drains per-session output buffers (messages arrive with `sessionId`)
5. Client routes buffered messages to correct sessions via existing `handleStreamingMessage`

**After beekeeper restart:**
- Server sends empty `session_list`
- All local sessions marked stale
- User can create new sessions (which may resume old SDK sessions on disk — transparent to client)

## File Summary

| File | Action |
|------|--------|
| `Models/WSMessage.swift` | Modify — protocol overhaul (new messages, sessionId scoping, browse types) |
| `Models/Session.swift` | Modify — `workspace` → `path`, add `isStale` |
| `Models/Workspace.swift` | **New** — remembered workspace paths (SwiftData) |
| `KeepurApp.swift` | Modify — add `Workspace` to schema |
| `ViewModels/ChatViewModel.swift` | Modify — multi-session streaming, browse state, session sync, remove workspace fields |
| `Views/SessionListView.swift` | Modify — workspace picker trigger, stale indicators, path display |
| `Views/WorkspacePickerView.swift` | **New** — directory browser + recent workspaces |
| `Views/SettingsView.swift` | Modify — remove workspace section, add saved workspaces |
| `Views/ChatView.swift` | Modify — scope approvals by sessionId, path-based title |

## Out of Scope

- Multi-client simultaneous connections (separate ticket)
- Session persistence across beekeeper restarts (server map is in-memory; client handles stale sessions)
- Max session limits / resource management
- Device pairing (#63 — separate spec)
