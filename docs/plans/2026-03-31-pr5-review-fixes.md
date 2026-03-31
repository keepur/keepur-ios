# PR #5 Review Fixes Implementation Plan

> **For agentic workers:** Use dodi-dev:implement to execute this plan.

**Goal:** Apply the 6 review fixes from closed PR #5 onto main — multi-session approval safety, per-session status, browse error UX, streaming cleanup, naming consistency, and unit tests.

**Architecture:** All changes are in the existing MVVM layer. ChatViewModel gets dictionary-based state for approvals and statuses. WorkspacePickerView gets three-state error/disconnected/loading UX. `isPaired` renames to `isAuthenticated` for clarity.

**Tech Stack:** SwiftUI, SwiftData, XCTest

---

### Task 1: `pendingApprovals` dict — multi-session approval race fix

**Files:**
- Modify: `ViewModels/ChatViewModel.swift`
- Modify: `Views/ChatView.swift`

- [ ] **Step 1:** In `ChatViewModel.swift`, replace the single `pendingApproval` with a dictionary keyed by sessionId.

Change line 12:
```swift
// OLD
@Published var pendingApproval: ToolApproval?

// NEW
@Published var pendingApprovals: [String: ToolApproval] = [:]
```

- [ ] **Step 2:** Update `approve()` and `deny()` to take `sessionId` and clear from dictionary.

```swift
func approve(toolUseId: String, sessionId: String) {
    ws.send(.approve(toolUseId: toolUseId))
    pendingApprovals[sessionId] = nil
}

func deny(toolUseId: String, sessionId: String) {
    ws.send(.deny(toolUseId: toolUseId))
    pendingApprovals[sessionId] = nil
}
```

- [ ] **Step 3:** Update `handleIncoming` `.toolApproval` case to store by sessionId.

```swift
case .toolApproval(let toolUseId, let tool, let input, let sessionId):
    let effectiveSessionId = sessionId ?? currentSessionId ?? ""
    if let sessionId, sessionId != currentSessionId {
        currentSessionId = sessionId
    }
    pendingApprovals[effectiveSessionId] = ToolApproval(id: toolUseId, tool: tool, input: input, sessionId: sessionId)
```

- [ ] **Step 4:** Update `ChatView.swift` sheet binding to use dictionary access.

```swift
.sheet(item: Binding(
    get: {
        viewModel.pendingApprovals[sessionId]
    },
    set: { viewModel.pendingApprovals[sessionId] = $0 }
)) { approval in
    ToolApprovalView(
        approval: approval,
        onApprove: { viewModel.approve(toolUseId: approval.id, sessionId: sessionId) },
        onDeny: { viewModel.deny(toolUseId: approval.id, sessionId: sessionId) }
    )
    .interactiveDismissDisabled()
}
```

- [ ] **Step 5:** Commit

```bash
git add ViewModels/ChatViewModel.swift Views/ChatView.swift
git commit -m "fix: pendingApprovals dict for multi-session approval safety"
```

---

### Task 2: `sessionStatuses` dict replacing `currentStatus`

**Files:**
- Modify: `ViewModels/ChatViewModel.swift`
- Modify: `Views/ChatView.swift`

- [ ] **Step 1:** In `ChatViewModel.swift`, replace `currentStatus` with a dictionary and helper.

Change line 9:
```swift
// OLD
@Published var currentStatus: String = "idle"

// NEW
@Published var sessionStatuses: [String: String] = [:]

func statusFor(_ sessionId: String) -> String {
    sessionStatuses[sessionId] ?? "idle"
}
```

- [ ] **Step 2:** Update `.status` handler to write to dictionary.

```swift
case .status(let state, let sessionId):
    if let sessionId {
        sessionStatuses[sessionId] = state
    } else if let currentSessionId {
        sessionStatuses[currentSessionId] = state
    }
```

- [ ] **Step 3:** Update `.sessionInfo` handler — replace `currentStatus = "idle"` with dictionary write.

```swift
sessionStatuses[sessionId] = "idle"
```

- [ ] **Step 4:** Update `ChatView.swift` to use `statusFor()` instead of `currentStatus`.

In the status indicator visibility check (~line 36-38):
```swift
if viewModel.statusFor(sessionId) == "thinking" || viewModel.statusFor(sessionId) == "tool_running" {
    StatusIndicator(status: viewModel.statusFor(sessionId))
        .id("status")
}
```

Remove the `viewModel.currentSessionId == sessionId` guard — `statusFor` is already per-session.

In `onChange(of: viewModel.currentStatus)` (~line 50-56), change to:
```swift
.onChange(of: viewModel.statusFor(sessionId)) {
    if viewModel.statusFor(sessionId) == "thinking" || viewModel.statusFor(sessionId) == "tool_running" {
        withAnimation {
            proxy.scrollTo("status", anchor: .bottom)
        }
    }
}
```

- [ ] **Step 5:** Commit

```bash
git add ViewModels/ChatViewModel.swift Views/ChatView.swift
git commit -m "fix: per-session status via sessionStatuses dict"
```

---

### Task 3: `browseError` state + WorkspacePickerView UX

**Files:**
- Modify: `ViewModels/ChatViewModel.swift`
- Modify: `Views/WorkspacePickerView.swift`

- [ ] **Step 1:** Add `browseError` published property to `ChatViewModel.swift` (after line 14).

```swift
@Published var browseError: String?
```

- [ ] **Step 2:** Update `.error` handler — set `browseError` when sessionId is nil.

```swift
case .error(let message, let sessionId):
    if sessionId == nil {
        browseError = message
    }
    let targetSessionId = sessionId ?? currentSessionId
    if let targetSessionId {
        let msg = Message(sessionId: targetSessionId, text: "Error: \(message)", role: "system")
        context.insert(msg)
        try? context.save()
    }
```

- [ ] **Step 3:** Clear `browseError` at the start of `browse()`.

```swift
func browse(path: String? = nil) {
    browseError = nil
    ws.send(.browse(path: path))
}
```

- [ ] **Step 4:** Replace the loading section in `WorkspacePickerView.swift` with three-state UX.

Replace the `if viewModel.browsePath.isEmpty` block (~lines 37-81) with:

```swift
Section {
    if !viewModel.ws.isConnected {
        ContentUnavailableView {
            Label("Disconnected", systemImage: "wifi.slash")
        } description: {
            Text("Connect to browse directories")
        } actions: {
            Button("Reconnect") { viewModel.ws.connect() }
                .buttonStyle(.borderedProminent)
        }
    } else if let error = viewModel.browseError {
        ContentUnavailableView {
            Label("Error", systemImage: "exclamationmark.triangle")
        } description: {
            Text(error)
        } actions: {
            Button("Retry") { viewModel.browse() }
                .buttonStyle(.borderedProminent)
        }
    } else if viewModel.browsePath.isEmpty {
        ProgressView("Loading…")
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 40)
    } else {
        HStack {
            Image(systemName: "folder.fill")
                .foregroundStyle(.secondary)
            Text(viewModel.browsePath)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .listRowBackground(Color(.systemGray6))

        if !isHome {
            Button {
                let parent = (viewModel.browsePath as NSString).deletingLastPathComponent
                viewModel.browse(path: parent)
            } label: {
                HStack {
                    Image(systemName: "arrow.up.doc")
                        .foregroundStyle(.secondary)
                    Text("..")
                        .foregroundStyle(.primary)
                }
            }
        }

        ForEach(viewModel.browseEntries.filter(\.isDirectory), id: \.name) { entry in
            Button {
                let base = viewModel.browsePath
                let childPath = base == "/" ? "/\(entry.name)"
                    : base.hasSuffix("/") ? "\(base)\(entry.name)"
                    : "\(base)/\(entry.name)"
                viewModel.browse(path: childPath)
            } label: {
                HStack {
                    Image(systemName: "folder")
                        .foregroundStyle(.blue)
                    Text(entry.name)
                        .foregroundStyle(.primary)
                }
            }
        }
    }
} header: {
    Text("Browse")
}
```

- [ ] **Step 5:** Commit

```bash
git add ViewModels/ChatViewModel.swift Views/WorkspacePickerView.swift
git commit -m "feat: browseError state with three-state WorkspacePickerView UX"
```

---

### Task 4: `session_ended` streaming cleanup

**Files:**
- Modify: `ViewModels/ChatViewModel.swift`

- [ ] **Step 1:** In the `.status` handler, after setting the status, add streaming cleanup for `session_ended`.

```swift
case .status(let state, let sessionId):
    if let sessionId {
        sessionStatuses[sessionId] = state
        if state == "session_ended" {
            streamingMessageIds.removeValue(forKey: sessionId)
        }
    } else if let currentSessionId {
        sessionStatuses[currentSessionId] = state
        if state == "session_ended" {
            streamingMessageIds.removeValue(forKey: currentSessionId)
        }
    }
```

- [ ] **Step 2:** Commit

```bash
git add ViewModels/ChatViewModel.swift
git commit -m "fix: clean streaming state on session_ended status"
```

---

### Task 5: `isPaired` → `isAuthenticated` rename

**Files:**
- Modify: `ViewModels/ChatViewModel.swift`
- Modify: `Views/RootView.swift`

- [ ] **Step 1:** In `ChatViewModel.swift`, rename the property (line 13).

```swift
// OLD
@Published var isPaired = true

// NEW
@Published var isAuthenticated = true
```

- [ ] **Step 2:** In `unpair()`, update the reference.

```swift
func unpair() {
    ws.disconnect()
    KeychainManager.clearAll()
    isAuthenticated = false
}
```

- [ ] **Step 3:** In `RootView.swift`, update both references to `isPaired`.

Line 10:
```swift
// OLD
if KeychainManager.isPaired && viewModel.isPaired {

// NEW
if KeychainManager.isPaired && viewModel.isAuthenticated {
```

Line 23 (the `onPaired` closure):
```swift
// OLD
viewModel.isPaired = true

// NEW
viewModel.isAuthenticated = true
```

- [ ] **Step 4:** Commit

```bash
git add ViewModels/ChatViewModel.swift Views/RootView.swift
git commit -m "fix: rename isPaired to isAuthenticated for clarity"
```

---

### Task 6: Unit tests

**Files:**
- Create: `KeeperTests/WorkspaceBrowsingTests.swift`
- Modify: `Keepur.xcodeproj/project.pbxproj` (add test target)

- [ ] **Step 1:** Create `KeeperTests/` directory and `WorkspaceBrowsingTests.swift` with tests covering:
  - Workspace model creation and displayName
  - WSOutgoing.browse encoding (with and without path)
  - WSIncoming.browseResult decoding
  - WSIncoming.error decoding (with and without sessionId)
  - WSOutgoing.newSession encoding
  - WSOutgoing.clearSession encoding
  - WSOutgoing.listSessions encoding
  - WSIncoming.sessionInfo decoding
  - WSIncoming.sessionList decoding
  - WSIncoming.sessionCleared decoding
  - Edge cases: empty entries, unknown type returns nil, missing fields return nil

```swift
import XCTest
@testable import Keepur

final class WorkspaceBrowsingTests: XCTestCase {

    // MARK: - Workspace Model

    func testWorkspaceDisplayName() {
        let ws = Workspace(path: "/Users/dev/my-project")
        XCTAssertEqual(ws.displayName, "my-project")
        XCTAssertEqual(ws.path, "/Users/dev/my-project")
    }

    func testWorkspaceRootPath() {
        let ws = Workspace(path: "/")
        XCTAssertEqual(ws.displayName, "/")
    }

    // MARK: - Browse Encoding

    func testBrowseEncodingWithoutPath() throws {
        let data = try WSOutgoing.browse().encode()
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["type"] as? String, "browse")
        XCTAssertNil(json["path"])
    }

    func testBrowseEncodingWithPath() throws {
        let data = try WSOutgoing.browse(path: "/home/user").encode()
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["type"] as? String, "browse")
        XCTAssertEqual(json["path"] as? String, "/home/user")
    }

    // MARK: - Browse Result Decoding

    func testBrowseResultDecoding() {
        let json: [String: Any] = [
            "type": "browse_result",
            "path": "/home",
            "entries": [
                ["name": "Documents", "isDirectory": true],
                ["name": "file.txt", "isDirectory": false]
            ]
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        guard case .browseResult(let path, let entries) = WSIncoming.decode(from: data) else {
            XCTFail("Expected browseResult"); return
        }
        XCTAssertEqual(path, "/home")
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].name, "Documents")
        XCTAssertTrue(entries[0].isDirectory)
        XCTAssertEqual(entries[1].name, "file.txt")
        XCTAssertFalse(entries[1].isDirectory)
    }

    func testBrowseResultEmptyEntries() {
        let json: [String: Any] = [
            "type": "browse_result",
            "path": "/empty",
            "entries": [] as [[String: Any]]
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        guard case .browseResult(let path, let entries) = WSIncoming.decode(from: data) else {
            XCTFail("Expected browseResult"); return
        }
        XCTAssertEqual(path, "/empty")
        XCTAssertTrue(entries.isEmpty)
    }

    // MARK: - Error Decoding

    func testErrorDecodingWithSessionId() {
        let json: [String: Any] = [
            "type": "error",
            "message": "Session not found",
            "sessionId": "sess-123"
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        guard case .error(let message, let sessionId) = WSIncoming.decode(from: data) else {
            XCTFail("Expected error"); return
        }
        XCTAssertEqual(message, "Session not found")
        XCTAssertEqual(sessionId, "sess-123")
    }

    func testErrorDecodingWithoutSessionId() {
        let json: [String: Any] = [
            "type": "error",
            "message": "Browse failed"
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        guard case .error(let message, let sessionId) = WSIncoming.decode(from: data) else {
            XCTFail("Expected error"); return
        }
        XCTAssertEqual(message, "Browse failed")
        XCTAssertNil(sessionId)
    }

    // MARK: - Session Encoding

    func testNewSessionEncoding() throws {
        let data = try WSOutgoing.newSession(path: "/projects/app").encode()
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["type"] as? String, "new_session")
        XCTAssertEqual(json["path"] as? String, "/projects/app")
    }

    func testClearSessionEncoding() throws {
        let data = try WSOutgoing.clearSession(sessionId: "sess-456").encode()
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["type"] as? String, "clear_session")
        XCTAssertEqual(json["sessionId"] as? String, "sess-456")
    }

    func testListSessionsEncoding() throws {
        let data = try WSOutgoing.listSessions.encode()
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["type"] as? String, "list_sessions")
    }

    // MARK: - Session Decoding

    func testSessionInfoDecoding() {
        let json: [String: Any] = [
            "type": "session_info",
            "sessionId": "sess-789",
            "path": "/workspace/project"
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        guard case .sessionInfo(let sessionId, let path) = WSIncoming.decode(from: data) else {
            XCTFail("Expected sessionInfo"); return
        }
        XCTAssertEqual(sessionId, "sess-789")
        XCTAssertEqual(path, "/workspace/project")
    }

    func testSessionListDecoding() {
        let json: [String: Any] = [
            "type": "session_list",
            "sessions": [
                ["sessionId": "s1", "path": "/a", "state": "idle"],
                ["sessionId": "s2", "path": "/b", "state": "busy"]
            ]
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        guard case .sessionList(let sessions) = WSIncoming.decode(from: data) else {
            XCTFail("Expected sessionList"); return
        }
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[0].sessionId, "s1")
        XCTAssertEqual(sessions[0].path, "/a")
        XCTAssertEqual(sessions[0].state, "idle")
        XCTAssertEqual(sessions[1].sessionId, "s2")
    }

    func testSessionListEmptySessions() {
        let json: [String: Any] = [
            "type": "session_list",
            "sessions": [] as [[String: Any]]
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        guard case .sessionList(let sessions) = WSIncoming.decode(from: data) else {
            XCTFail("Expected sessionList"); return
        }
        XCTAssertTrue(sessions.isEmpty)
    }

    func testSessionClearedDecoding() {
        let json: [String: Any] = [
            "type": "session_cleared",
            "sessionId": "sess-cleared"
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        guard case .sessionCleared(let sessionId) = WSIncoming.decode(from: data) else {
            XCTFail("Expected sessionCleared"); return
        }
        XCTAssertEqual(sessionId, "sess-cleared")
    }

    // MARK: - Edge Cases

    func testUnknownTypeReturnsNil() {
        let json: [String: Any] = ["type": "unknown_event"]
        let data = try! JSONSerialization.data(withJSONObject: json)
        XCTAssertNil(WSIncoming.decode(from: data))
    }

    func testMissingTypeReturnsNil() {
        let json: [String: Any] = ["message": "no type"]
        let data = try! JSONSerialization.data(withJSONObject: json)
        XCTAssertNil(WSIncoming.decode(from: data))
    }

    func testInvalidJsonReturnsNil() {
        let data = "not json".data(using: .utf8)!
        XCTAssertNil(WSIncoming.decode(from: data))
    }

    func testSessionInfoMissingPathReturnsNil() {
        let json: [String: Any] = [
            "type": "session_info",
            "sessionId": "sess-789"
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        XCTAssertNil(WSIncoming.decode(from: data))
    }

    func testBrowseResultMissingEntriesReturnsNil() {
        let json: [String: Any] = [
            "type": "browse_result",
            "path": "/home"
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        XCTAssertNil(WSIncoming.decode(from: data))
    }

    func testSessionListMalformedSessionSkipped() {
        let json: [String: Any] = [
            "type": "session_list",
            "sessions": [
                ["sessionId": "s1", "path": "/a", "state": "idle"],
                ["sessionId": "s2"],  // missing path and state
                ["bad": "entry"]       // completely malformed
            ]
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        guard case .sessionList(let sessions) = WSIncoming.decode(from: data) else {
            XCTFail("Expected sessionList"); return
        }
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].sessionId, "s1")
    }

    // MARK: - Message & Approval Encoding

    func testMessageEncoding() throws {
        let data = try WSOutgoing.message(text: "Hello", sessionId: "s1").encode()
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["type"] as? String, "message")
        XCTAssertEqual(json["text"] as? String, "Hello")
        XCTAssertEqual(json["sessionId"] as? String, "s1")
    }

    func testApproveEncoding() throws {
        let data = try WSOutgoing.approve(toolUseId: "tool-1").encode()
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["type"] as? String, "approve")
        XCTAssertEqual(json["toolUseId"] as? String, "tool-1")
    }

    func testDenyEncoding() throws {
        let data = try WSOutgoing.deny(toolUseId: "tool-2").encode()
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["type"] as? String, "deny")
        XCTAssertEqual(json["toolUseId"] as? String, "tool-2")
    }
}
```

- [ ] **Step 2:** Add the test target to the Xcode project. This requires modifying `project.pbxproj` — use `xcodebuild` to verify.

- [ ] **Step 3:** Commit

```bash
git add KeeperTests/ Keepur.xcodeproj/project.pbxproj
git commit -m "test: add WorkspaceBrowsingTests (25 tests)"
```
