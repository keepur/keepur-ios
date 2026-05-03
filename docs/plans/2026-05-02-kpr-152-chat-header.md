# KPR-152 — Chat header redesign (Implementation Plan)

**Date:** 2026-05-02
**Spec:** [docs/specs/2026-05-02-kpr-152-chat-header.md](../specs/2026-05-02-kpr-152-chat-header.md)
**Ticket:** [KPR-152](https://linear.app/keepur/issue/KPR-152)

## Strategy

Two view edits + one new test file + xcodeproj wiring for the test file. Implementation order is **TeamChatView first** (smaller, tighter status mapping — fewer status states to map), then **ChatView** (more status states, more conditional toolbar logic), then **mapping tests**, then **xcodeproj wiring**, then build / test verification.

The two view edits are structurally identical: extract `KeepurChatHeader` into a private computed property, swap `.toolbar { ... }` contents to a single principal/automatic `ToolbarItem`, add `.navigationBarBackButtonHidden(true)` on iOS, keep `.navigationTitle(...)` for accessibility. Existing `.sheet`, `.onAppear`, `.onChange` modifiers stay untouched.

Per the spec, no foundation composite changes — `KeepurChatHeader` is consumed as-is.

## Steps

### Step 1: Modify `Views/Team/TeamChatView.swift`

**File:** `Views/Team/TeamChatView.swift`

Replace the existing `.toolbar { ToolbarItem(placement: .automatic) { HStack { ... } } }` block with a `.principal`-on-iOS / `.automatic`-on-macOS principal toolbar item containing `KeepurChatHeader`. Add `.navigationBarBackButtonHidden(true)` (iOS only). Add `@Environment(\.dismiss) private var dismiss`. Add private computed properties for status mapping, status date, active state, back action, trailing actions, and speaker symbol selection.

Concrete edits:

1. Add `@Environment(\.dismiss) private var dismiss` near the top of the struct (after the existing `@State` properties).
2. Add `.navigationBarBackButtonHidden(true)` inside the existing `#if os(iOS)` block after `.navigationBarTitleDisplayMode(.inline)`.
3. Replace the `.toolbar { ... }` block body with a single principal item:

```swift
.toolbar {
    #if os(iOS)
    ToolbarItem(placement: .principal) { chatHeader }
    #else
    ToolbarItem(placement: .automatic) { chatHeader }
    #endif
}
```

4. Add private computed properties at end of struct (before `messageList`):

```swift
private var activeChannel: TeamChannel? {
    guard let id = viewModel.activeChannelId else { return nil }
    return viewModel.channels.first(where: { $0.id == id })
}

private var chatHeader: KeepurChatHeader {
    KeepurChatHeader(
        title: channelTitle,
        statusText: headerStatusText,
        statusDate: headerStatusDate,
        isStatusActive: headerIsStatusActive,
        onBack: backAction,
        trailingActions: headerTrailingActions
    )
}

static func mapAgentStatus(_ status: String?) -> (text: String?, isActive: Bool) {
    switch status {
    case nil, "idle": return (nil, false)
    case "processing": return ("working", true)
    case "error": return ("error", false)
    case "stopped": return ("stopped", false)
    case let other?: return (other, false)
    }
}

private var headerStatusText: String? { Self.mapAgentStatus(activeAgent?.status).text }
private var headerIsStatusActive: Bool { Self.mapAgentStatus(activeAgent?.status).isActive }
private var headerStatusDate: Date? { activeChannel?.lastMessageAt }

private var backAction: (() -> Void)? {
    #if os(iOS)
    return { dismiss() }
    #else
    return nil
    #endif
}

private var headerTrailingActions: [KeepurChatHeader.Action] {
    var actions: [KeepurChatHeader.Action] = []
    if let speech = viewModel.speechManager {
        actions.append(.init(symbol: speakerSymbol(speech)) {
            if speech.isSpeaking { speech.stopSpeaking() } else { autoReadAloud.toggle() }
        })
    }
    if isDMWithAgent {
        actions.append(.init(symbol: "info.circle") { showAgentDetail = true })
    }
    return actions
}

private func speakerSymbol(_ speech: SpeechManager) -> String {
    if speech.isSpeaking { return "stop.circle.fill" }
    return autoReadAloud ? "speaker.wave.2.fill" : "speaker.slash"
}
```

5. Confirm `.navigationTitle(channelTitle)` stays in place above the `#if os(iOS)` block.
6. Confirm `.sheet(isPresented: $showAgentDetail) { ... }`, `.onChange(of: viewModel.activeChannelId)`, `.onAppear`, `.onChange(of: autoReadAloud)` modifiers are all unchanged.

**Verification:** file compiles; no removed modifiers.

### Step 2: Modify `Views/ChatView.swift`

**File:** `Views/ChatView.swift`

Same shape as Step 1, with ChatView-specific status mapping and the iOS-only settings button in the trailing stack.

Concrete edits:

1. Add `@Environment(\.dismiss) private var dismiss` near the top of the struct (after the existing `@State` properties).
2. Add `.navigationBarBackButtonHidden(true)` inside the existing `#if os(iOS)` block after `.navigationBarTitleDisplayMode(.inline)`.
3. Replace the existing `.toolbar { ToolbarItem(placement: .automatic) { HStack { ... } } }` body with the principal-item form (same as Step 1).
4. Add private computed properties at end of struct (before `readOnlyBar`):

```swift
private var chatHeader: KeepurChatHeader {
    KeepurChatHeader(
        title: navigationTitle,
        statusText: headerStatusText,
        statusDate: headerStatusDate,
        isStatusActive: headerIsStatusActive,
        onBack: backAction,
        trailingActions: headerTrailingActions
    )
}

static func mapSessionStatus(_ status: String) -> (text: String?, isActive: Bool) {
    switch status {
    case "idle": return (nil, false)
    case "thinking": return ("thinking", true)
    case "tool_running": return ("running tool", true)
    case "tool_starting": return ("starting tool", true)
    case "busy": return ("server busy", true)
    default: return (status, false)
    }
}

private var headerStatusText: String? { Self.mapSessionStatus(viewModel.statusFor(sessionId)).text }
private var headerIsStatusActive: Bool { Self.mapSessionStatus(viewModel.statusFor(sessionId)).isActive }
private var headerStatusDate: Date? { messages.last?.timestamp }

private var backAction: (() -> Void)? {
    #if os(iOS)
    return { dismiss() }
    #else
    return nil
    #endif
}

private var headerTrailingActions: [KeepurChatHeader.Action] {
    var actions: [KeepurChatHeader.Action] = [
        .init(symbol: speakerSymbol) {
            if viewModel.speechManager.isSpeaking {
                viewModel.speechManager.stopSpeaking()
            } else {
                autoReadAloud.toggle()
            }
        }
    ]
    #if os(iOS)
    actions.append(.init(symbol: KeepurTheme.Symbol.settings) { showSettings = true })
    #endif
    return actions
}

private var speakerSymbol: String {
    if viewModel.speechManager.isSpeaking { return "stop.circle.fill" }
    return autoReadAloud ? "speaker.wave.2.fill" : "speaker.slash"
}
```

5. Confirm `.navigationTitle(navigationTitle)` stays in place.
6. Confirm `.sheet(...)` for `showSettings`, `.sheet(item: ...)` for tool approvals, `.onAppear`, `.onChange(of: autoReadAloud)` modifiers all unchanged.

**Verification:** file compiles; existing behavior on speaker / settings buttons preserved.

### Step 3: Create `KeeperTests/ChatHeaderMappingTests.swift`

**File:** `KeeperTests/ChatHeaderMappingTests.swift`

Pure-function tests for the two `static` mapping helpers added in Steps 1 and 2. No view body instantiation, no view models, no SwiftData containers.

```swift
import XCTest
@testable import Keepur

final class ChatHeaderMappingTests: XCTestCase {
    func testChatViewStatusMapping() {
        XCTAssertEqual(ChatView.mapSessionStatus("idle").text, nil)
        XCTAssertEqual(ChatView.mapSessionStatus("idle").isActive, false)

        XCTAssertEqual(ChatView.mapSessionStatus("thinking").text, "thinking")
        XCTAssertTrue(ChatView.mapSessionStatus("thinking").isActive)

        XCTAssertEqual(ChatView.mapSessionStatus("tool_running").text, "running tool")
        XCTAssertTrue(ChatView.mapSessionStatus("tool_running").isActive)

        XCTAssertEqual(ChatView.mapSessionStatus("tool_starting").text, "starting tool")
        XCTAssertTrue(ChatView.mapSessionStatus("tool_starting").isActive)

        XCTAssertEqual(ChatView.mapSessionStatus("busy").text, "server busy")
        XCTAssertTrue(ChatView.mapSessionStatus("busy").isActive)

        // Unknown raw status falls through
        XCTAssertEqual(ChatView.mapSessionStatus("custom").text, "custom")
        XCTAssertFalse(ChatView.mapSessionStatus("custom").isActive)
    }

    func testTeamChatViewAgentStatusMapping() {
        XCTAssertNil(TeamChatView.mapAgentStatus(nil).text)
        XCTAssertFalse(TeamChatView.mapAgentStatus(nil).isActive)

        XCTAssertNil(TeamChatView.mapAgentStatus("idle").text)
        XCTAssertFalse(TeamChatView.mapAgentStatus("idle").isActive)

        XCTAssertEqual(TeamChatView.mapAgentStatus("processing").text, "working")
        XCTAssertTrue(TeamChatView.mapAgentStatus("processing").isActive)

        XCTAssertEqual(TeamChatView.mapAgentStatus("error").text, "error")
        XCTAssertFalse(TeamChatView.mapAgentStatus("error").isActive)

        XCTAssertEqual(TeamChatView.mapAgentStatus("stopped").text, "stopped")
        XCTAssertFalse(TeamChatView.mapAgentStatus("stopped").isActive)

        // Unknown raw status falls through
        XCTAssertEqual(TeamChatView.mapAgentStatus("custom").text, "custom")
        XCTAssertFalse(TeamChatView.mapAgentStatus("custom").isActive)
    }
}
```

**Verification:** file compiles inside test target.

### Step 4: Wire test file into Xcode project

Use `xcodeproj` Ruby gem (per project convention). The two source view files are in `Views/` and `Views/Team/`, both of which are synchronized folder groups — no xcodeproj wiring needed for those edits.

```ruby
require 'xcodeproj'
project = Xcodeproj::Project.open('Keepur.xcodeproj')
group_tests = project.main_group['KeeperTests']

ref = group_tests.new_reference('KeeperTests/ChatHeaderMappingTests.swift')
project.targets.each do |t|
  next unless t.name.include?('Tests')
  t.source_build_phase.add_file_reference(ref)
end

project.save
```

**Verification:** `git diff Keepur.xcodeproj/project.pbxproj` shows the new file ref added to the test target's source build phase.

### Step 5: Build verification (sequential iOS + macOS)

```bash
xcodebuild -project Keepur.xcodeproj -scheme Keepur \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -quiet build

xcodebuild -project Keepur.xcodeproj -scheme Keepur \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  -quiet build
```

**Verification:** both exit 0. macOS build is the canary for the `.automatic` toolbar placement choice — if macOS rejects or visually misplaces the principal item, fall back to platform-specific placement (likely `.navigation` for the title block on macOS) before continuing.

### Step 6: Run new test file

```bash
xcodebuild test -project Keepur.xcodeproj -scheme Keepur \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing KeeperTests/ChatHeaderMappingTests \
  -quiet
```

**Verification:** exit 0; 2 tests pass.

### Step 7: Run full test suite (regression check)

```bash
xcodebuild test -project Keepur.xcodeproj -scheme Keepur \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -quiet
```

**Verification:** exit 0; total test count = previous + 2; no existing tests regress (especially `BusyStateRecoveryTests`, `ChatResilienceTests`, `SessionReplacedTests`, `ContextClearedTests` — anything touching `viewModel.statusFor` semantics).

### Step 8: Manual smoke (optional but recommended)

If a simulator is available, briefly verify on iPhone:
- Sessions tab → tap a session → header shows circular back chevron + title + speaker + settings; tab bar hides (KPR-147 wiring intact).
- Hive tab → tap an agent DM → header shows back chevron + title + status line ("working · 2m ago" if processing) + speaker + info; tab bar hides.
- Tap back chevron → returns to list; tab bar reappears.
- Tap info → AgentDetailSheet opens.

This is observation, not an automated assertion — sim time isn't strictly required if both builds and the full test suite pass.

### Step 9: Commit

```
feat: chat header redesign — KeepurChatHeader on ChatView + TeamChatView (KPR-152)

Replace navigationTitle + system back chevron + ad-hoc toolbar buttons
with KeepurChatHeader principal toolbar item. iPhone hides system back
button; macOS uses automatic placement and skips the back chevron
(NavigationSplitView detail). Speaker / settings / info actions
relocated into trailing circular action stack — behavior preserved.
Tab-bar visibility wiring from KPR-147 untouched.

Pure-function status mapping helpers tested in ChatHeaderMappingTests.

Closes KPR-152
```

## Test Groups

| Group | Coverage | File |
|---|---|---|
| **Unit (mapping)** | `ChatView.mapSessionStatus` and `TeamChatView.mapAgentStatus` cover the spec's status mapping tables | `KeeperTests/ChatHeaderMappingTests.swift` |
| **Unit (header)** | Already covered for `KeepurChatHeader` itself by `KeeperTests/KeepurFoundationCompositesTests.swift` (KPR-146) | (existing) |
| **Integration** | None added — view-body instantiation requires SwiftData container + WebSocket stub. Build verification on both platforms is the integration signal |  |
| **E2E** | Optional manual smoke in Step 8 |  |

## Risks / Mitigations

| Risk | Mitigation |
|---|---|
| macOS `.automatic` placement looks wrong | Step 5 (macOS build) is the canary. If misplaced, switch to `.navigation` per platform observation before Step 6 |
| iOS principal slot collides with sheet presentation | Sheets are presented at the view body level, not inside the toolbar. No interaction expected; verified by Step 7 full suite |
| Tab-bar hiding regresses (KPR-147 #68) | Chat views do not add `.toolbar(... for: .tabBar)`. Tab-bar control stays with parents (TeamRootView, SessionListView's iOSBody) — no changes to those files |
| `dismiss` does nothing when ChatView is shown not via NavigationStack push | ChatView is always pushed via `navigationDestination` from SessionListView's iOSBody — `dismiss()` resolves to the NavigationStack pop. TeamChatView is the detail of NavigationSplitView — `dismiss` on iOS in compact mode pops the detail back to the sidebar (correct behavior). On macOS we pass `nil` so this never executes |
| Speaker color coding lost (danger / honey / muted → uniform) | Spec'd as acceptable trade-off ("relocated/restyled"); shape changes still convey state |
| Test target can't see internal `static` methods on `ChatView` / `TeamChatView` | `@testable import Keepur` already used by sibling tests (`KeepurFoundationCompositesTests.swift`); internal access is the default and visible to `@testable` consumers |

## Dependencies Check

- **External (composite):** `KeepurChatHeader` from KPR-146 — confirmed present at `Theme/Components/KeepurChatHeader.swift` with the API used here (title, statusText, statusDate, isStatusActive, onBack, trailingActions)
- **External (theme tokens):** `KeepurTheme.Symbol.settings`, `KeepurTheme.Spacing.s2` — confirmed present
- **External (view model APIs):** `ChatViewModel.statusFor(_:)`, `viewModel.speechManager.isSpeaking`, `viewModel.speechManager.stopSpeaking()`, `viewModel.autoReadAloud`, `TeamViewModel.activeChannelId`, `TeamViewModel.channels`, `TeamViewModel.displayName(for:)`, `TeamViewModel.speechManager`, `TeamAgentInfo.status` — all confirmed present
- **External (model fields):** `Session.displayName`, `TeamChannel.lastMessageAt`, `Message.timestamp` — all confirmed present
- **External (parent wiring):** `TeamRootView.isViewingChat` and `SessionListView.iOSBody.toolbar(... for: .tabBar)` — confirmed in place; this ticket does not modify them
- **No additional ticket dependencies** beyond KPR-146 and KPR-147

## Human Signoff

Pre-approved per durable user delegation (KPR-142 design v2 epic). No human plan-review checkpoint required.
