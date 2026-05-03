# KPR-150 — Hive sidebar agent rows (Implementation Plan)

**Date:** 2026-05-02
**Spec:** [docs/specs/2026-05-02-kpr-150-hive-sidebar.md](../specs/2026-05-02-kpr-150-hive-sidebar.md)
**Ticket:** [KPR-150](https://linear.app/keepur/issue/KPR-150)

## Strategy

One existing file modified (`Views/Team/AgentRow.swift`), one new test file added (`KeeperTests/AgentRowTests.swift`), one project wiring step for the test file. `TeamSidebarView.swift` and `TeamRootView.swift` are not modified — title wiring is already correct via `capabilityManager.selectedHive`, and tab-bar visibility wiring is untouched per task constraint.

The `AgentRow` change is a body restructure: leading 36pt status-dot frame → 56pt `KeepurAvatar`; trailing relative-time stack gets a sibling `KeepurUnreadBadge(count: 0)` placeholder. The existing `statusColor: Color` accessor is replaced by a `statusTint: KeepurStatusPill.Tint` extension because `KeepurAvatar.statusOverlay` takes a tint enum, not a raw `Color`.

## Steps

### Step 1: Rewrite `AgentRow.swift` body

**File:** `Views/Team/AgentRow.swift`

Changes in order:

1. Delete the `statusColor: Color` computed property.
2. Add a private extension at the bottom of the file with `statusTint: KeepurStatusPill.Tint` mapping the same four status string cases (`idle → .success`, `processing → .warning`, `error/stopped → .danger`, default → `.muted`).
3. In `body`:
   - Replace the leading `ZStack { Circle()... }.frame(width: 36, height: 36)` with `KeepurAvatar(size: 56, content: .letter(agent.name), statusOverlay: statusTint)`.
   - Wrap the trailing relative-time `Text` and a new `KeepurUnreadBadge(count: 0)` in an `HStack(spacing: KeepurTheme.Spacing.s2)`. Keep the `if let lastAt = ...` gate around the time text only; the unread badge is unconditional (collapses to `EmptyView` when count is 0).
   - Bump `.padding(.vertical, 2)` to `.padding(.vertical, KeepurTheme.Spacing.s2)` to give the taller avatar breathing room.
4. `subtitle` and `secondLineText` accessors stay as-is.
5. `isActive`, `agent`, `dmChannel` props stay as-is.

Resulting body shape (pseudocode):

```swift
HStack(spacing: KeepurTheme.Spacing.s3) {
    KeepurAvatar(size: 56, content: .letter(agent.name), statusOverlay: statusTint)

    VStack(alignment: .leading, spacing: 2) {
        Text(agent.name)
            .font(KeepurTheme.Font.body)
            .fontWeight(isActive ? .semibold : .regular)
            .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
            .lineLimit(1)

        if let secondLineText {
            Text(secondLineText)
                .font(KeepurTheme.Font.caption)
                .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                .lineLimit(1)
        }
    }

    Spacer()

    HStack(spacing: KeepurTheme.Spacing.s2) {
        if let lastAt = dmChannel?.lastMessageAt {
            Text(lastAt, style: .relative)
                .font(KeepurTheme.Font.caption)
                .foregroundStyle(KeepurTheme.Color.fgTertiary)
        }
        KeepurUnreadBadge(count: 0)
    }
}
.padding(.vertical, KeepurTheme.Spacing.s2)
.contentShape(Rectangle())
```

**Verification:** file compiles (build check at Step 4). No call-site changes needed in `TeamSidebarView` since the `AgentRow` init signature is unchanged.

### Step 2: Create `AgentRowTests.swift`

**File:** `KeeperTests/AgentRowTests.swift`

Three smoke tests per spec §"Smoke Test Scope". A small fixture factory builds a `TeamAgentInfo` with overridable status and name; `TeamChannel` is constructed in memory directly (no `ModelContext` required for the value-only init).

```swift
import XCTest
import SwiftUI
@testable import Keepur

final class AgentRowTests: XCTestCase {
    func testRowInstantiatesWithAndWithoutDM() {
        let agent = makeAgent()
        let row1 = AgentRow(agent: agent, dmChannel: nil, isActive: false)
        _ = row1.body

        let channel = TeamChannel(
            id: "c1",
            kind: "dm",
            name: "DM",
            agentIds: [agent.id],
            lastMessageText: "hello",
            lastMessageAt: Date()
        )
        let row2 = AgentRow(agent: agent, dmChannel: channel, isActive: true)
        _ = row2.body
    }

    func testStatusTintMapping() {
        for status in ["idle", "processing", "error", "stopped", "unknown"] {
            let agent = makeAgent(status: status)
            let row = AgentRow(agent: agent, dmChannel: nil, isActive: false)
            _ = row.body
        }
    }

    func testEmptyAgentNameRenders() {
        let agent = makeAgent(name: "")
        let row = AgentRow(agent: agent, dmChannel: nil, isActive: false)
        _ = row.body
    }

    // MARK: - Fixture

    private func makeAgent(name: String = "Test", status: String = "idle") -> TeamAgentInfo {
        TeamAgentInfo(
            id: "a1",
            name: name,
            icon: "",
            title: nil,
            model: "claude-sonnet",
            status: status,
            tools: [],
            schedule: [],
            channels: [],
            messagesProcessed: 0,
            lastActivity: nil
        )
    }
}
```

Note: confirm `TeamChannel`'s init parameter labels by reading the model file before writing the test (per `Models/TeamChannel.swift` — uses positional/labeled values, no context). If labels differ from what's drafted above, adjust to match the actual init signature; the test logic is unchanged.

**Verification:** file compiles inside test target after Step 3.

### Step 3: Wire test file into Xcode project

Use the `xcodeproj` Ruby gem (existing project convention from theming + KPR-144 epic):

```ruby
require 'xcodeproj'
project = Xcodeproj::Project.open('Keepur.xcodeproj')
group_tests = project.main_group['KeeperTests']

ref = group_tests.new_reference("KeeperTests/AgentRowTests.swift")
project.targets.each do |t|
  next unless t.name.include?('Tests')
  t.source_build_phase.add_file_reference(ref)
end

project.save
```

`Views/Team/AgentRow.swift` does **not** need wiring — `Views/` is a synchronized folder group per CLAUDE.md / task constraint.

**Verification:** `git diff Keepur.xcodeproj/project.pbxproj` shows the file ref added under both test build phases (iOS test target + macOS test target if present).

### Step 4: Build verification

Sequential builds (parallel iOS + macOS collide on SourcePackages — known issue):

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

### Step 5: Run new tests + full suite

```bash
xcodebuild test -project Keepur.xcodeproj -scheme Keepur \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing KeeperTests/AgentRowTests \
  -quiet
```

Then full suite to confirm no regression:

```bash
xcodebuild test -project Keepur.xcodeproj -scheme Keepur \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -quiet
```

**Verification:** both exit 0; new test class shows 3 passes; total test count increases by 3 vs. pre-change baseline.

### Step 6: Visual sanity check (manual)

Run the app on simulator, sign in, select a hive with at least one agent, observe sidebar:

- Agent rows show 56pt square avatars with letter content.
- Each row's avatar has a colored circle in the bottom-right corner matching the agent status.
- Sidebar title shows the actual hive name (e.g., `"hive-dodi"`), not the literal word `"Hive"`.
- Trailing slot shows relative time when a DM exists; the unread placeholder is invisible (correct — count is 0).
- Selected agent's row name is semibold.

This is a sanity check, not a gate — the tests cover the build/structure correctness and the visual matches the mockup intent per spec.

### Step 7: Commit

```
feat: hive sidebar agent rows — square avatars + corner status (KPR-150)

Replace 36pt status-dot frame with 56pt KeepurAvatar (letter content +
corner status overlay). Add KeepurUnreadBadge(count: 0) placeholder
slot adjacent to the trailing relative time. statusColor accessor
becomes statusTint to feed KeepurAvatar.statusOverlay.

Closes KPR-150
```

## Test Groups

| Group | Coverage | File |
|---|---|---|
| **Unit (smoke)** | `AgentRow` instantiates with/without DM, across status values, with empty name | `KeeperTests/AgentRowTests.swift` |
| **Integration** | N/A — no integration surface change. `TeamSidebarView` continues to call `AgentRow` with the same init signature |  |
| **E2E** | N/A — no behavioral flow change. Visual sanity check covered manually in Step 6 |  |

## Risks / Mitigations

| Risk | Mitigation |
|---|---|
| `TeamChannel` init signature differs from drafted test fixture | Read `Models/TeamChannel.swift` while writing the test; adjust labels to actual signature |
| 56pt avatar makes sidebar rows too tall on macOS (sidebar density expectations differ from iOS) | Visual sanity check on macOS in Step 6; if too dense, fall back to 48pt (still mockup-faithful) — note in PR if used |
| Status overlay ring (white 1.5pt stroke from `KeepurAvatar`) clashes with sidebar selection highlight | Visual check in Step 6; selection highlight is on the row container, not the avatar — should be fine but verify |
| `KeepurUnreadBadge(count: 0)` collapses to `EmptyView` but might still affect HStack spacing | `EmptyView` produces no layout contribution in SwiftUI; the trailing `HStack` will be just the time text. Verified in Step 6 |
| Project file (`project.pbxproj`) corrupted by `xcodeproj` gem mid-edit | `git diff project.pbxproj` after script; revert and retry if anything looks off |

## Dependencies Check

- **Foundation atoms (KPR-144):** `KeepurAvatar` (size, `Content.letter`, `statusOverlay`), `KeepurUnreadBadge(count:)` — both confirmed present in `Theme/Components/` on the epic branch.
- **`KeepurStatusPill.Tint`:** `.success`, `.warning`, `.danger`, `.muted` — all confirmed present (used by `KeepurAvatar.statusOverlay`).
- **Theme tokens:** `KeepurTheme.Spacing.{s2, s3}`, `KeepurTheme.Font.{body, caption}`, `KeepurTheme.Color.{fgPrimaryDynamic, fgSecondaryDynamic, fgTertiary}` — all confirmed in `Theme/KeepurTheme.swift` (already used by current `AgentRow`).
- **Data model:** `TeamAgentInfo.{name, status}`, `TeamChannel.lastMessageAt` — all confirmed (current `AgentRow` reads them).
- **Test target:** existing `KeeperTests/*Tests.swift` files confirm `@testable import Keepur` pattern works.

## Human Signoff

Pre-approved per durable user delegation (KPR-142 design v2 epic). No human plan-review checkpoint required.
