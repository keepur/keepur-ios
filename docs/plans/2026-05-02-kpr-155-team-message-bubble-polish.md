# KPR-155 — TeamMessageBubble polish (Implementation Plan)

**Date:** 2026-05-02
**Spec:** [docs/specs/2026-05-02-kpr-155-team-message-bubble-polish.md](../specs/2026-05-02-kpr-155-team-message-bubble-polish.md)
**Ticket:** [KPR-155](https://linear.app/keepur/issue/KPR-155)

## Strategy

Single-file view edit + one new test file + one xcodeproj wire. The view change is a localized rewrite of the agent-variant `VStack`: drop the leading sender-name `Text`, append a 24pt `KeepurAvatar` to the existing footer `HStack`. System/user variants are untouched. Implementation order: edit view, write tests, wire tests into project, build both platforms, run tests, commit.

`Views/` is a synchronized folder group (per CLAUDE.md), so the modified view file needs no project-file change. Only the new test file requires xcodeproj wiring.

## Steps

### Step 1: Modify `TeamMessageBubble.agentBubble`

**File:** `Views/Team/TeamMessageBubble.swift`

**Sub-step 1a — Drop sender-name eyebrow.** Remove the leading `Text(message.senderName)...` block (current lines 66–68) inside the agent-variant `VStack`.

**Sub-step 1b — Add mini avatar to footer.** Modify the existing footer `HStack(spacing: KeepurTheme.Spacing.s3)` (current line 80) to:

```swift
HStack(alignment: .center, spacing: KeepurTheme.Spacing.s3) {
    HStack(spacing: KeepurTheme.Spacing.s2) {
        KeepurAvatar(size: 24, content: .letter(message.senderName))
        Text(message.createdAt, style: .time)
            .font(KeepurTheme.Font.caption)
            .foregroundStyle(KeepurTheme.Color.fgTertiary)
    }

    if let onSpeak {
        Button { onSpeak(message.text) } label: {
            Image(systemName: KeepurTheme.Symbol.speaker)
                .font(KeepurTheme.Font.caption)
                .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
        }
    }
}
```

Rationale for the nested `HStack`: tighter `s2` pairing between avatar and timestamp (visually one unit), `s3` separation between that pair and the speaker button. Matches the spec's footer composition.

**Sub-step 1c — Verify routing untouched.** The top-level `body` switch (`if senderId == "system" / else if isOwnMessage / else`) is unchanged. `userBubble` and `systemBubble` are unchanged.

**Verification:** `git diff Views/Team/TeamMessageBubble.swift` shows only changes inside `agentBubble`. No other variants touched.

### Step 2: Create `KeeperTests/TeamMessageBubbleTests.swift`

**File:** `KeeperTests/TeamMessageBubbleTests.swift`

Three smoke tests covering variant routing + agent footer composition. Pattern matches `KeeperTests/KeepurFoundationAtomsTests.swift`.

```swift
import XCTest
import SwiftUI
@testable import Keepur

final class TeamMessageBubbleTests: XCTestCase {
    private func makeMessage(
        senderId: String = "agent-1",
        senderType: String = "agent",
        senderName: String = "claude-bot",
        pending: Bool = false
    ) -> TeamMessage {
        TeamMessage(
            channelId: "c1",
            senderId: senderId,
            senderType: senderType,
            senderName: senderName,
            text: "hello",
            pending: pending
        )
    }

    func testSystemBubbleInstantiates() {
        let msg = makeMessage(senderId: "system", senderType: "system", senderName: "system")
        let bubble = TeamMessageBubble(message: msg, isOwnMessage: false)
        _ = bubble.body
    }

    func testUserBubbleInstantiates() {
        let msg = makeMessage(senderId: "device-self", senderType: "person", senderName: "me")
        _ = TeamMessageBubble(message: msg, isOwnMessage: true).body

        let pending = makeMessage(senderId: "device-self", senderType: "person", senderName: "me", pending: true)
        _ = TeamMessageBubble(message: pending, isOwnMessage: true).body
    }

    func testAgentBubbleInstantiates() {
        // With onSpeak callback
        let msg = makeMessage()
        _ = TeamMessageBubble(message: msg, isOwnMessage: false, onSpeak: { _ in }).body

        // Without onSpeak callback
        _ = TeamMessageBubble(message: msg, isOwnMessage: false).body

        // Empty senderName exercises KeepurAvatar.letter("") placeholder path
        let nameless = makeMessage(senderName: "")
        _ = TeamMessageBubble(message: nameless, isOwnMessage: false).body
    }
}
```

**Verification:** file compiles in test target.

### Step 3: Wire test file into Xcode project

Use the `xcodeproj` Ruby gem (per repo convention from theming epic and KPR-144).

```ruby
require 'xcodeproj'
project = Xcodeproj::Project.open('Keepur.xcodeproj')
group_tests = project.main_group['KeeperTests']

ref = group_tests.new_reference('KeeperTests/TeamMessageBubbleTests.swift')
project.targets.each do |t|
  next unless t.name.include?('Tests')
  t.source_build_phase.add_file_reference(ref)
end

project.save
```

**Verification:** `git diff Keepur.xcodeproj/project.pbxproj` shows the file ref added to the test target's source build phase only (not the main app target).

### Step 4: Build verification (both platforms)

Sequential, not parallel — parallel iOS + macOS collide on SourcePackages (known issue from theming epic):

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

### Step 5: Run new test class

```bash
xcodebuild test -project Keepur.xcodeproj -scheme Keepur \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing KeeperTests/TeamMessageBubbleTests \
  -quiet
```

**Verification:** exit 0; 3 passes.

### Step 6: Run full test suite (regression check)

```bash
xcodebuild test -project Keepur.xcodeproj -scheme Keepur \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -quiet
```

**Verification:** exit 0; total test count = previous + 3.

### Step 7: Commit

```
feat: TeamMessageBubble agent variant uses mini KeepurAvatar (KPR-155)

Drop sender-name eyebrow above the agent bubble. Add 24pt
KeepurAvatar.letter(senderName) to the existing footer alongside
timestamp + speaker button. System / user / agent routing preserved.

Closes KPR-155
```

## Test Groups

| Group | Coverage | File |
|---|---|---|
| **Unit (smoke)** | Three-variant routing + agent footer composition (with/without `onSpeak`, empty senderName) | `KeeperTests/TeamMessageBubbleTests.swift` |
| **Integration** | N/A — bubble is a leaf View; consuming `TeamChatView` is not modified |  |
| **E2E** | N/A — no user flow change beyond visual placement |  |

## Risks / Mitigations

| Risk | Mitigation |
|---|---|
| `TeamMessage` requires `ModelContainer` to instantiate in tests | `@Model` SwiftData classes can be constructed without a container for property access; only `ModelContext.insert` requires one. The smoke tests just construct + read `body`. Pattern is unverified for `TeamMessage` specifically — if it fails at runtime, fall back to instantiating inside an in-memory `ModelContainer` (existing test files like `TeamSortedAgentsTests.swift` already do this — copy pattern). |
| Removing the sender-name eyebrow is a regression for users in multi-agent channels who relied on seeing the name | Spec calls this out as accepted — DM context implies the agent. Multi-agent channels are not yet a Keepur surface (DMs only today per `TeamChatView` flow). If multi-agent channels land later, follow-up ticket can reintroduce the name as a tooltip / accessibility-only label. |
| `KeepurAvatar` letter rendering of "claude-bot" gives "C" — could collide with other agents named "C..." | Acceptable for design v2 — same compromise carried by KPR-150 (Hive sidebar). Held emoji-icon plumbing (per spec open question) resolves long-term. |
| Test target compile fails because `KeepurAvatar` not visible | KPR-144 already shipped to epic branch; `Theme/Components/KeepurAvatar.swift` is wired into both iOS + macOS app targets and visible via `@testable import Keepur`. Verified by existence of `KeepurFoundationAtomsTests.swift` exercising it. |
| Footer `HStack` nesting changes hit-test on the speaker button | Inner `HStack` only contains non-interactive `KeepurAvatar` + `Text`; outer `HStack` retains `Button`. Hit-test surface unchanged. |

## Dependencies Check

- **External (foundation atoms):** `KeepurAvatar` (KPR-144 — already on epic branch, confirmed at `Theme/Components/KeepurAvatar.swift`)
- **External (tokens):** `KeepurTheme.Spacing.{s2, s3}`, `KeepurTheme.Font.caption`, `KeepurTheme.Color.{fgTertiary, fgSecondaryDynamic}`, `KeepurTheme.Symbol.speaker` — all present and used elsewhere in `TeamMessageBubble.swift` already
- **External (data model):** `TeamMessage.senderName` exists and is non-optional (`String`) per `Models/TeamMessage.swift`
- **External (test target):** existing `KeepurFoundationAtomsTests.swift` confirms `@testable import Keepur` pattern works; `TeamSortedAgentsTests.swift` confirms team types are testable
- **Ticket dependencies:** KPR-144 only (already merged to epic branch)

## Human Signoff

Pre-approved per durable user delegation (KPR-142 design v2 epic). No human plan-review checkpoint required.
