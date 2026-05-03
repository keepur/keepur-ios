# KPR-153 — Chat Error Message Bubble Variant (Implementation Plan)

**Date:** 2026-05-02
**Spec:** [docs/specs/2026-05-02-kpr-153-chat-error-bubble.md](../specs/2026-05-02-kpr-153-chat-error-bubble.md)
**Ticket:** [KPR-153](https://linear.app/keepur/issue/KPR-153)

## Strategy

Three production files change + one new test file + one xcodeproj edit (test wiring only). Implementation order is bottom-up: model field first (so the rest of the pipeline has somewhere to write to), then ViewModel handler + retry method, then `MessageBubble` view variant, then `ChatView` callback wiring, then tests.

`Views/` and `Models/` are synchronized folder groups (per CLAUDE.md) — only the test file requires xcodeproj wiring with bare filename. SwiftData lightweight migration handles the new optional column automatically (no `VersionedSchema` ceremony needed because the project doesn't pin a schema version).

## Steps

### Step 1: Add `failedUserMessageId` to `Message`

**File:** `Models/Message.swift`

- Extend the `role` doc comment to add `"error"`: `// "user", "assistant", "system", "tool", "error"`.
- Add `var failedUserMessageId: String?` after `attachmentData`.
- Add `failedUserMessageId: String? = nil` to `init` parameter list and assign it.

**Verification:** `xcodebuild -project Keepur.xcodeproj -scheme Keepur -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -quiet build` exits 0. SwiftData lightweight migration runs on next launch (asserted indirectly by tests in Step 5).

### Step 2: Rewrite `.error` handling + add `retry(errorMessage:)` in `ChatViewModel`

**File:** `ViewModels/ChatViewModel.swift`

Two edits:

**Edit A — `.error` case in `handleIncoming`** (currently lines ~393–403). Replace with:

```swift
case .error(let message, let sessionId):
    if sessionId == nil && isBrowsePending {
        isBrowsePending = false
        browseError = message
    }
    let targetSessionId = sessionId ?? currentSessionId
    if let targetSessionId {
        var descriptor = FetchDescriptor<Message>(
            predicate: #Predicate { $0.sessionId == targetSessionId && $0.role == "user" },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        let trigger = try? context.fetch(descriptor).first

        let errorRow = Message(
            sessionId: targetSessionId,
            text: message,
            role: "error",
            failedUserMessageId: trigger?.id
        )
        context.insert(errorRow)
        try? context.save()
    }
```

The `"Error: "` prefix is dropped; the eyebrow now carries that signal. The `browseError` side-effect (for `WorkspacePickerView`) is preserved verbatim.

**Edit B — new `retry(errorMessage:)` method** added before `// MARK: - Private`:

```swift
func retry(errorMessage: Message) {
    guard let context = modelContext,
          let triggerId = errorMessage.failedUserMessageId else { return }

    let descriptor = FetchDescriptor<Message>(
        predicate: #Predicate { $0.id == triggerId }
    )
    guard let trigger = try? context.fetch(descriptor).first else {
        context.delete(errorMessage)
        try? context.save()
        return
    }

    let attachment: AttachmentData? = {
        guard let data = trigger.attachmentData,
              let name = trigger.attachmentName,
              let mime = trigger.attachmentType else { return nil }
        return AttachmentData(name: name, mimeType: mime, data: data)
    }()

    sendToServer(text: trigger.text, attachment: attachment, sessionId: trigger.sessionId)
    context.delete(errorMessage)
    try? context.save()
}
```

`sendToServer` is private but accessible since `retry` is on the same type. `AttachmentData` is the existing struct used by `pendingAttachment` (verify init signature when implementing — adjust if it's labeled differently).

**Verification:** build exits 0 on iOS + macOS.

### Step 3: Add `errorBubble` variant + `onRetry` callback to `MessageBubble`

**File:** `Views/MessageBubble.swift`

Three edits:

**Edit A** — Add `var onRetry: ((Message) -> Void)? = nil` to the property block (after `onSpeak`).

**Edit B** — Add `case "error": errorBubble` to the switch in `body` (above `case "unknown"`).

**Edit C** — Add the `errorBubble` private computed property per spec §"`MessageBubble` — new `errorBubble` variant". Place before the `// MARK: - Link Detection` section.

**Verification:** build exits 0 on iOS + macOS.

### Step 4: Wire `onRetry` in `ChatView`

**File:** `Views/ChatView.swift`

Locate the `MessageBubble(message: ...)` construction (single call site expected per spec inspection — confirm during implementation). Add `onRetry: { viewModel.retry(errorMessage: $0) }` to the parameter list. The `viewModel` reference is the existing `@StateObject` / `@EnvironmentObject` already in scope.

If multiple `MessageBubble` call sites exist, wire all of them. If there's a `MessageBubble` invocation inside another file (e.g. a thread view), search via `grep -rn 'MessageBubble(' --include='*.swift' Views` and wire each.

**Verification:** build exits 0 on iOS + macOS.

### Step 5: Create test file

**File:** `KeeperTests/MessageBubbleErrorVariantTests.swift`

```swift
import XCTest
import SwiftData
@testable import Keepur

@MainActor
final class MessageBubbleErrorVariantTests: XCTestCase {

    private func inMemoryContext() throws -> ModelContext {
        let schema = Schema([Message.self, Session.self, Workspace.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        return ModelContext(container)
    }

    func testErrorRoleRoundTripsThroughSwiftData() throws {
        let context = try inMemoryContext()
        let row = Message(
            sessionId: "s1",
            text: "boom",
            role: "error",
            failedUserMessageId: "u1"
        )
        context.insert(row)
        try context.save()

        let descriptor = FetchDescriptor<Message>(
            predicate: #Predicate { $0.role == "error" }
        )
        let fetched = try context.fetch(descriptor)
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.text, "boom")
        XCTAssertEqual(fetched.first?.failedUserMessageId, "u1")
    }

    func testErrorWSFrameAttributesToMostRecentUserMessage() throws {
        let context = try inMemoryContext()
        let user = Message(sessionId: "s1", text: "hi", role: "user")
        context.insert(user)
        try context.save()

        let vm = ChatViewModel()
        vm.configure(context: context)            // wires modelContext; WS connect is fine in tests — no auth = no-op
        vm.currentSessionId = "s1"

        // Drive the error path directly via the WS callback.
        vm.ws.onMessage?(.error(message: "server boom", sessionId: "s1"))

        let descriptor = FetchDescriptor<Message>(
            predicate: #Predicate { $0.role == "error" }
        )
        let errors = try context.fetch(descriptor)
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(errors.first?.text, "server boom")
        XCTAssertEqual(errors.first?.failedUserMessageId, user.id)
    }

    func testErrorWSFrameWithNoPriorUserMessageHasNilTrigger() throws {
        let context = try inMemoryContext()
        let vm = ChatViewModel()
        vm.configure(context: context)
        vm.currentSessionId = "s1"

        vm.ws.onMessage?(.error(message: "early boom", sessionId: "s1"))

        let descriptor = FetchDescriptor<Message>(
            predicate: #Predicate { $0.role == "error" }
        )
        let errors = try context.fetch(descriptor)
        XCTAssertEqual(errors.count, 1)
        XCTAssertNil(errors.first?.failedUserMessageId)
    }

    func testRetryWithStaleTriggerDeletesErrorRow() throws {
        let context = try inMemoryContext()
        let err = Message(
            sessionId: "s1",
            text: "boom",
            role: "error",
            failedUserMessageId: "ghost-id"
        )
        context.insert(err)
        try context.save()

        let vm = ChatViewModel()
        vm.configure(context: context)
        vm.retry(errorMessage: err)

        let descriptor = FetchDescriptor<Message>(
            predicate: #Predicate { $0.role == "error" }
        )
        let remaining = try context.fetch(descriptor)
        XCTAssertEqual(remaining.count, 0, "Error row should be deleted when its trigger is gone")
    }

    func testRetryWithLiveTriggerRemovesErrorAndPreservesTrigger() throws {
        let context = try inMemoryContext()
        let user = Message(sessionId: "s1", text: "hi", role: "user")
        let err = Message(
            sessionId: "s1",
            text: "boom",
            role: "error",
            failedUserMessageId: user.id
        )
        context.insert(user)
        context.insert(err)
        try context.save()

        let vm = ChatViewModel()
        vm.configure(context: context)
        vm.retry(errorMessage: err)

        let userDescriptor = FetchDescriptor<Message>(
            predicate: #Predicate { $0.role == "user" }
        )
        let errDescriptor = FetchDescriptor<Message>(
            predicate: #Predicate { $0.role == "error" }
        )
        XCTAssertEqual(try context.fetch(userDescriptor).count, 1, "Trigger user message preserved")
        XCTAssertEqual(try context.fetch(errDescriptor).count, 0, "Error row removed")
    }
}
```

**Notes:**
- Tests instantiate `ChatViewModel` directly. Per CLAUDE.md ("Don't smoke-test full View bodies depending on @StateObject/Keychain") we avoid View instantiation. The VM itself touches Keychain via `ws.connect()` indirectly through `configure`; if `configure` fails in CI without a token, downgrade to a stub that bypasses `ws.connect` (worst case: refactor `configure` to take an `autoConnect: Bool = true` flag and pass `false` from tests — flag this in implementation review if needed).
- `vm.ws.onMessage?(.error(...))` directly invokes the registered closure, simulating an inbound WS frame without a real socket.

**Verification:** file compiles inside test target.

### Step 6: Wire test file into Xcode project

`KeeperTests/` is **not** a synchronized folder group per CLAUDE.md ("Tests need xcodeproj wiring with bare filename"). Use the `xcodeproj` Ruby gem pattern from KPR-144:

```ruby
require 'xcodeproj'
project = Xcodeproj::Project.open('Keepur.xcodeproj')
group_tests = project.main_group['KeeperTests']
ref = group_tests.new_reference('MessageBubbleErrorVariantTests.swift')
project.targets.each do |t|
  next unless t.name.include?('Tests')
  t.source_build_phase.add_file_reference(ref)
end
project.save
```

Bare filename (`'MessageBubbleErrorVariantTests.swift'`) — the group's path prefix handles the rest.

**Verification:** `git diff Keepur.xcodeproj/project.pbxproj` shows the new file ref added to test build phase only (not the main app target).

### Step 7: Build verification

Sequential builds (parallel iOS + macOS collide on SourcePackages — known issue from theming epic):

```bash
xcodebuild -project Keepur.xcodeproj -scheme Keepur \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -quiet build

xcodebuild -project Keepur.xcodeproj -scheme Keepur \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  -quiet build
```

**Verification:** both exit 0.

### Step 8: Run test suite

```bash
xcodebuild test -project Keepur.xcodeproj -scheme Keepur \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing KeeperTests/MessageBubbleErrorVariantTests \
  -quiet
```

Then full suite to confirm no regression (the `.error` handler change touches existing behavior — old tests covering error insertion may need updating if they assert on `role: "system"` text):

```bash
xcodebuild test -project Keepur.xcodeproj -scheme Keepur \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -quiet
```

**Verification:** both exit 0; new test class shows 5 passes; total test count = previous + 5 (modulo any pre-existing tests that needed updating for the `system → error` role change — flag and fix during implementation if any surface).

### Step 9: Visual diff in simulator

Manual smoke (not automated):
1. Boot iOS simulator with a paired session.
2. Force an error (easiest path: send a message while WebSocket is in a forced bad state, or temporarily mutate a message handler to inject an `.error` WS frame).
3. Confirm the bubble shows the red border, light red tint, "ERROR" eyebrow in red, mono error text, timestamp, and Retry button.
4. Tap Retry — confirm the original user message is re-sent and the error row disappears.
5. Tap Retry on a stale error (after `/clear`) — confirm the row vanishes without crashing.

If a forced-error injection isn't trivial during dev, the unit tests in Step 5 cover the data flow; visual verification can rely on a debug-only `Message(sessionId:..., text: "fake error", role: "error", failedUserMessageId: someUserId)` insert via a temporary debug menu, then revert.

### Step 10: Commit

```
feat: chat error message bubble variant (KPR-153)

Add `role: "error"` Message variant with red-bordered card, JetBrains
Mono error text, ERROR eyebrow, and inline Retry button. Update
ChatViewModel to insert role="error" rows (was role="system" with
"Error:" prefix), capturing the trigger user message id for retry.

Closes KPR-153
```

## Test Groups

| Group | Coverage | File |
|---|---|---|
| **Unit (data model)** | `Message` with `role: "error"` and `failedUserMessageId` round-trips through SwiftData | `KeeperTests/MessageBubbleErrorVariantTests.swift` |
| **Unit (ViewModel)** | `.error` WS frame attributes to most recent user message; nil-trigger edge case; retry deletes stale-trigger error rows; retry re-sends + removes error on live trigger | same file |
| **Visual (manual)** | Card styling, eyebrow, mono text, Retry button render correctly on iOS + macOS | manual simulator (Step 9) |
| **E2E** | N/A — no end-to-end harness in repo |  |

## Risks / Mitigations

| Risk | Mitigation |
|---|---|
| SwiftData lightweight migration fails on existing installs (new optional field) | Optional fields with default `nil` are the safest possible additive schema change; SwiftData handles them automatically. If it fails, the failure is at app launch and we'll see it in build verification before merging |
| `ChatViewModel.configure` triggers `ws.connect()` which may misbehave in test environment | If tests hang or fail on connect, refactor `configure` to take `autoConnect: Bool = true` and pass `false` from tests. Plan-level escape hatch; not blocking |
| `AttachmentData` init signature differs from spec assumption | Verify the actual struct in `Models/` (likely `Models/AttachmentData.swift` or co-located) during Step 2; adjust the closure |
| Retry button styling differs visually on macOS vs iOS | Both renderings read as "destructive bordered button"; document the difference if jarring, no fix |
| Existing tests depending on `role: "system"` for error rows now fail | Update them to assert on `role: "error"` and absence of `"Error: "` prefix; if no such tests exist, no action |
| `MessageBubble` instantiated in multiple files | `grep -rn 'MessageBubble(' --include='*.swift' Views` during Step 4 to find all sites; wire each |
| `Views/ChatView.swift` line numbers shift between read and edit | Use `Edit` tool with sufficient context lines to avoid ambiguity |

## Dependencies Check

- **Tokens used:** `Color.danger`, `Color.fgPrimaryDynamic`, `Color.fgTertiary`, `Font.eyebrow`, `Font.lsEyebrow`, `Font.caption`, `FontName.mono`, `Radius.md`, `Spacing.s2`, `Spacing.s3` — all present in `Theme/KeepurTheme.swift`
- **APIs used:** `FetchDescriptor`, `#Predicate`, `SortDescriptor` (SwiftData); `.bordered` button style, `.tint(_:)`, `.controlSize(.small)` (SwiftUI iOS 15+ / macOS 12+) — all within project min targets (iOS 26.2, macOS 15)
- **No ticket dependencies** — leaf consumer; no foundation atom or composite required

## Human Signoff

Pre-approved per durable user delegation (KPR-142 design v2 epic). The data-flow additions (new model field, new VM method) go beyond pure styling, but they're justified in the spec as load-bearing for the variant being usable. No checkpoint required.
