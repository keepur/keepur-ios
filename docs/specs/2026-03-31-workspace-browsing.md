# Keepur iOS — Workspace Browsing & Dynamic Directory Selection

**Date**: 2026-03-31
**Status**: Draft
**Server issue**: bot-dodi/hive#65
**Server spec**: `docs/specs/2026-03-31-beekeeper-multi-session-design.md` (in hive repo — same spec as #64)

## Problem

Workspaces are hardcoded in `beekeeper.yaml`. The server sends a static `workspaces` list in `session_info`, and the iOS app renders it as a menu in `SessionListView` and `SettingsView`. Users can't pick arbitrary directories — they're limited to whatever an admin preconfigured.

Hive #65 adds a `browse` message so the client can explore the filesystem and pick any directory under `~` as a workspace. The server removes `workspaces` and `default_workspace` from its config entirely. Workspace memory becomes a client-side concern.

This spec covers the iOS client changes needed to support dynamic workspace selection via directory browsing, and the client-side `Workspace` model that remembers user selections across sessions.

## Relationship to Multi-Session Spec

The multi-session spec (`2026-03-31-multi-session.md`) covers the full protocol overhaul — this is the same body of work. That spec is the canonical reference for all changes. This document focuses specifically on the **workspace browsing UX and client-side memory** aspects, which are the core of hive #65:

- Directory browser view (new)
- `Workspace` SwiftData model (new)
- Removal of hardcoded workspace list from all views
- `browse`/`browse_result` message handling

All protocol, model, and view model changes documented in the multi-session spec apply here. This spec does not repeat them — it elaborates on the browsing-specific UX and data flow.

## Browse Protocol (Reference)

**Client → Server:**

| Type | Fields | Notes |
|------|--------|-------|
| `browse` | `path?: String` | Omit `path` to browse `~`. Server rejects paths outside `~`. |

**Server → Client:**

| Type | Fields | Notes |
|------|--------|-------|
| `browse_result` | `path: String`, `entries: [{ name, isDirectory }]` | Dirs first, alpha sorted, hidden entries filtered. |
| `error` | `message: String`, `sessionId?: nil` | If path invalid/outside home. `sessionId` is nil (browse is not session-scoped). |

Server guarantees:
- Only serves paths under `~` (resolved via `realpathSync` after symlink resolution)
- Filters hidden entries (dotfiles/dotdirs)
- Sorts directories first, then alphabetical
- Returns error if path is a file or escapes home

## Changes

### 1. Workspace Model — client-side path memory

**New file**: `Models/Workspace.swift`

```swift
@Model
final class Workspace {
    @Attribute(.unique) var path: String
    var lastUsed: Date

    init(path: String, lastUsed: Date = .now) {
        self.path = path
        self.lastUsed = lastUsed
    }

    var displayName: String {
        (path as NSString).lastPathComponent
    }
}
```

- `path` is the unique key — same path used twice updates `lastUsed`, doesn't create a duplicate
- `displayName` is computed from last path component (e.g., `/Users/may/projects/hive` → `hive`)
- Saved when `session_info` arrives with a new path (see ViewModel changes in multi-session spec)
- Deleted via swipe-to-delete in SettingsView

**Schema registration**: Add `Workspace.self` to `Schema([...])` in `KeepurApp.swift`.

### 2. ChatViewModel — browse state

**File**: `ViewModels/ChatViewModel.swift`

Add published state for the directory browser:

```swift
@Published var browseEntries: [BrowseEntry] = []
@Published var browsePath: String = ""
```

Add method:

```swift
func browse(path: String? = nil) {
    ws.send(.browse(path: path))
}
```

Handle incoming `browseResult`:

```swift
case .browseResult(let path, let entries):
    browsePath = path
    browseEntries = entries
```

Handle browse errors (server sends `error` with nil `sessionId` for browse failures) — already covered by the existing error handler in the multi-session spec.

**Workspace save on session creation**: When `session_info` arrives, upsert a `Workspace` record:

```swift
case .sessionInfo(let sessionId, let path):
    // ... session creation ...

    // Remember workspace
    let descriptor = FetchDescriptor<Workspace>(
        predicate: #Predicate { $0.path == path }
    )
    if let existing = try? context.fetch(descriptor).first {
        existing.lastUsed = .now
    } else {
        context.insert(Workspace(path: path))
    }
    try? context.save()
```

### 3. WorkspacePickerView — directory browser

**New file**: `Views/WorkspacePickerView.swift`

Presented as a sheet from `SessionListView` when tapping the "New Session" toolbar button.

**Structure:**

```
┌─────────────────────────────────┐
│ Cancel    Choose Workspace    Start Here │
├─────────────────────────────────┤
│ [hive] [keepur-ios] [dotfiles]          │  ← Recent workspaces (horizontal scroll)
├─────────────────────────────────┤
│ ~ / Users / may / projects              │  ← Breadcrumb
├─────────────────────────────────┤
│ 📁 ..                                   │  ← Parent directory (if not at ~)
│ 📁 hive                          ›      │
│ 📁 keepur-ios                    ›      │
│ 📁 dotfiles                      ›      │
│ 📄 README.md                            │  ← Files shown but disabled
│ 📄 notes.txt                            │
└─────────────────────────────────┘
```

**Sections:**

1. **Recent Workspaces** (top, horizontal scroll):
   - `@Query(sort: \Workspace.lastUsed, order: .reverse)` 
   - Rendered as capsule chips with folder icon + `displayName`
   - Tap → `viewModel.newSession(path:)` → dismiss sheet
   - Hidden if no saved workspaces

2. **Breadcrumb** (below recent):
   - Splits `viewModel.browsePath` by `/`, renders each component as a tappable button
   - First component shown as `~`
   - Tap any component → `viewModel.browse(path:)` to navigate to that ancestor

3. **Directory listing** (main area, `List`):
   - Parent directory row (`..`) at top, navigates to parent via `NSString.deletingLastPathComponent`
   - Hidden when at root level (only 1 breadcrumb component)
   - Each `BrowseEntry` rendered with folder/doc icon
   - Directories: tappable, navigates deeper via `viewModel.browse(path: currentPath + "/" + entry.name)`
   - Files: shown but disabled (gray text, no chevron) — gives context about what's in the directory

4. **Toolbar**:
   - Leading: "Cancel" button → dismiss
   - Trailing: "Start Here" button → `viewModel.newSession(path: viewModel.browsePath)` → dismiss
   - "Start Here" disabled while `browsePath` is empty (loading)

**Lifecycle**: `onAppear` calls `viewModel.browse()` with no path (defaults to `~` on server).

### 4. SessionListView — replace workspace menu

**File**: `Views/SessionListView.swift`

**Remove**: The toolbar `Menu` that iterates `viewModel.availableWorkspaces` (lines 43–62).

**Replace with**: A single toolbar button that opens `WorkspacePickerView` as a sheet:

```swift
ToolbarItem(placement: .topBarTrailing) {
    Button {
        showWorkspacePicker = true
    } label: {
        Image(systemName: "square.and.pencil")
            .font(.title3)
    }
}
```

Add `@State private var showWorkspacePicker = false` and `.sheet(isPresented:)` modifier.

**Empty state**: Update the "New Session" button action to `showWorkspacePicker = true` instead of `viewModel.newSession()`.

### 5. SettingsView — saved workspaces

**File**: `Views/SettingsView.swift`

**Remove**: The "Workspace" section (lines 34–53) that iterates `viewModel.availableWorkspaces`.

**Replace with** "Saved Workspaces" section:

```swift
@Query(sort: \Workspace.lastUsed, order: .reverse) private var savedWorkspaces: [Workspace]

// In body:
if !savedWorkspaces.isEmpty {
    Section("Saved Workspaces") {
        ForEach(savedWorkspaces, id: \.path) { workspace in
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(workspace.displayName)
                    Text(workspace.path)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Text(workspace.lastUsed, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .onDelete { offsets in
            for index in offsets {
                modelContext.delete(savedWorkspaces[index])
            }
            try? modelContext.save()
        }
    }
}
```

Add `@Environment(\.modelContext) private var modelContext` to support deletion.

## User Flows

### First launch (no saved workspaces)

1. User taps "New Session" (toolbar or empty state)
2. `WorkspacePickerView` opens, calls `viewModel.browse()`
3. Server returns home directory listing
4. User navigates to desired project directory
5. User taps "Start Here"
6. Client sends `new_session { path: "/Users/may/projects/hive" }`
7. Server responds with `session_info { sessionId, path }`
8. Client creates `Session` + `Workspace` records, opens `ChatView`

### Returning user (has saved workspaces)

1. User taps "New Session"
2. `WorkspacePickerView` shows recent chips: `[hive] [keepur-ios]`
3. User taps `hive` chip
4. Client sends `new_session { path: "/Users/may/projects/hive" }`
5. `Workspace.lastUsed` updated, session created as above

### Browse error (path outside home)

1. This shouldn't happen in normal use (breadcrumb prevents navigating above `~`)
2. If it does, server sends `error { message: "Path must be a directory under home" }`
3. Client shows error in current session context (or ignores if no session)

## File Summary

| File | Action | What changes |
|------|--------|-------------|
| `Models/Workspace.swift` | **New** | SwiftData model for remembered paths |
| `KeepurApp.swift` | Modify | Add `Workspace` to schema |
| `ViewModels/ChatViewModel.swift` | Modify | Browse state (`browseEntries`, `browsePath`), `browse()` method, workspace upsert on `session_info` |
| `Views/WorkspacePickerView.swift` | **New** | Directory browser + recent workspaces |
| `Views/SessionListView.swift` | Modify | Replace workspace menu with picker sheet trigger |
| `Views/SettingsView.swift` | Modify | Replace hardcoded workspace section with saved workspaces query |

## Out of Scope

- Server-side workspace persistence (client remembers selections)
- Workspace search/filter within the browser (browse + scroll is sufficient for now)
- Favoriting/pinning workspaces (lastUsed sorting handles recency; can add later)
- Showing workspace-scoped session counts in the picker
