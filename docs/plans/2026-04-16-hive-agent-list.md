# Hive Agent List Implementation Plan

> **For agentic workers:** Use dodi-dev:implement to execute this plan.

**Goal:** Replace the three-section Hive sidebar (DMs, Channels, Agents) with a single flat agent list that shows last-message preview + relative time and opens the conversation on tap.

**Architecture:** `TeamViewModel` exposes a new `@Published sortedAgents: [(agent, dmChannel?)]` pair that merges `agents` and DM channels. `TeamSidebarView` renders one `ForEach` of `Button` rows calling `openAgentDM(agent:)`. `AgentRow` is re-skinned (leading 36x36 status-dot container, name + preview + relative time, no emoji). `TeamRootView` empty state text updates. No server protocol changes; `openAgentDM` path is unchanged.

**Tech Stack:** SwiftUI, SwiftData, Combine. iOS 26.2+ / macOS 15.0+.

**Spec:** `docs/specs/2026-04-16-hive-agent-list-design.md`

**Out of scope for this plan:** Section 4 of the spec (stale session recovery) is deferred pending server error string confirmation — no code in this plan touches `handleIncoming(.error:)` beyond what already exists.

---

## File Map

| File | Change |
|------|--------|
| `Views/Team/AgentRow.swift` | Rewrite: new init signature (`agent`, `dmChannel`, `isActive`), remove emoji, leading status dot in 36x36 container, preview + relative time |
| `ViewModels/TeamViewModel.swift` | Add `@Published sortedAgents`, `recomputeSortedAgents()`, call from three sites |
| `Views/Team/TeamSidebarView.swift` | Replace 3 sections with single `ForEach` over `sortedAgents`; delete `ChannelRow`, `dmChannels`, `groupChannels`; switch to `Button` rows; update overlay |
| `Views/Team/TeamRootView.swift` | Update empty-state `ContentUnavailableView` label and description |
| `KeeperTests/TeamSortedAgentsTests.swift` | Create: unit tests for `recomputeSortedAgents()` sort order and DM lookup |

---

## Task 1: Update AgentRow

**Files:**
- Modify: `Views/Team/AgentRow.swift` (full rewrite)

- [ ] **Step 1.1:** Replace `Views/Team/AgentRow.swift` with the new implementation.

```swift
import SwiftUI

struct AgentRow: View {
    let agent: TeamAgentInfo
    let dmChannel: TeamChannel?
    let isActive: Bool

    private var statusColor: Color {
        switch agent.status {
        case "idle": return .green
        case "processing": return .yellow
        case "error", "stopped": return .red
        default: return .gray
        }
    }

    private var subtitle: String? {
        if let title = agent.title, !title.isEmpty {
            return title
        }
        if !agent.model.isEmpty {
            return agent.model
        }
        return nil
    }

    /// Second-line text: DM preview if a conversation exists, else fall back
    /// to the agent's title/model subtitle.
    private var secondLineText: String? {
        if let preview = dmChannel?.lastMessageText, !preview.isEmpty {
            return preview
        }
        return subtitle
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name)
                    .font(.body)
                    .fontWeight(isActive ? .semibold : .regular)
                    .lineLimit(1)

                if let secondLineText {
                    Text(secondLineText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if let lastAt = dmChannel?.lastMessageAt {
                Text(lastAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}
```

- [ ] **Step 1.2:** Verify the file compiles against the project (cannot fully build until Task 3 wires the new init). For now, check the file parses:

Run: `xcrun swift-frontend -parse Views/Team/AgentRow.swift 2>&1 | head -20`
Expected: no errors (may emit warnings about missing types — that's fine, types come from the project target).

If swift-frontend isn't usable standalone, skip and rely on the full xcodebuild in Task 6.

- [ ] **Step 1.3:** Do NOT commit yet — sidebar won't build without Task 3. Commit happens at end of Task 4.

---

## Task 2: Add sortedAgents state to TeamViewModel

**Files:**
- Modify: `ViewModels/TeamViewModel.swift`

- [ ] **Step 2.1:** Add the new `@Published` property. Insert immediately after the existing `@Published var agents` line at `ViewModels/TeamViewModel.swift:19`.

Find (at line 19):
```swift
    @Published var agents: [TeamAgentInfo] = []
```

Replace with:
```swift
    @Published var agents: [TeamAgentInfo] = []

    /// Agents paired with their DM channel (if any), sorted for sidebar display.
    /// Sort: `dmChannel?.lastMessageAt` descending (nil last), then `agent.name` ascending.
    /// Must be a stored @Published (not computed) — `agents` and `channels` arrive
    /// via separate WS responses in unpredictable order, and a computed derivation
    /// wouldn't reliably trigger SwiftUI updates.
    @Published var sortedAgents: [(agent: TeamAgentInfo, dmChannel: TeamChannel?)] = []
```

- [ ] **Step 2.2:** Add the `recomputeSortedAgents()` method. Insert it at the end of the `// MARK: - Private: Helpers` section, immediately after the closing `}` of `refreshActiveMessages()` (around `ViewModels/TeamViewModel.swift:661`) but before the final closing `}` of the class.

**Note on visibility:** The spec says "Add a private `recomputeSortedAgents()`". The plan intentionally makes it `internal` (no `private` keyword) because the unit tests in Task 5 invoke it directly via `@testable import Keepur`. Do not add `private` to the method — tests will fail to compile. The method is still effectively "private" to the Keepur target; only tests reach it.

Find:
```swift
    func refreshActiveMessages() {
        guard let context = modelContext, let channelId = activeChannelId else {
            activeMessages = []
            return
        }
        let cid = channelId
        let descriptor = FetchDescriptor<TeamMessage>(
            predicate: #Predicate { $0.channelId == cid },
            sortBy: [SortDescriptor(\TeamMessage.createdAt)]
        )
        activeMessages = (try? context.fetch(descriptor)) ?? []
    }
}
```

Replace with:
```swift
    func refreshActiveMessages() {
        guard let context = modelContext, let channelId = activeChannelId else {
            activeMessages = []
            return
        }
        let cid = channelId
        let descriptor = FetchDescriptor<TeamMessage>(
            predicate: #Predicate { $0.channelId == cid },
            sortBy: [SortDescriptor(\TeamMessage.createdAt)]
        )
        activeMessages = (try? context.fetch(descriptor)) ?? []
    }

    /// Rebuild `sortedAgents` from current `agents` and `channels`.
    /// DM predicate (`type == "dm"` + members contains agent.id) intentionally
    /// matches the existing predicate in `openAgentDM(agent:)` and `syncChannels`
    /// so sidebar display and DM navigation stay consistent.
    func recomputeSortedAgents() {
        let paired: [(agent: TeamAgentInfo, dmChannel: TeamChannel?)] = agents.map { agent in
            let dm = channels.first { $0.type == "dm" && $0.members.contains(agent.id) }
            return (agent: agent, dmChannel: dm)
        }
        sortedAgents = paired.sorted { lhs, rhs in
            let lDate = lhs.dmChannel?.lastMessageAt
            let rDate = rhs.dmChannel?.lastMessageAt
            switch (lDate, rDate) {
            case let (l?, r?):
                if l != r { return l > r }
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                break
            }
            return lhs.agent.name.localizedCaseInsensitiveCompare(rhs.agent.name) == .orderedAscending
        }
    }
}
```

- [ ] **Step 2.3:** Wire the three callsites.

**Callsite A — end of `loadChannels(context:)`** at `ViewModels/TeamViewModel.swift:459-464`.

Find:
```swift
    private func loadChannels(context: ModelContext) {
        let descriptor = FetchDescriptor<TeamChannel>(
            sortBy: [SortDescriptor(\TeamChannel.lastMessageAt, order: .reverse)]
        )
        channels = (try? context.fetch(descriptor)) ?? []
    }
```

Replace with:
```swift
    private func loadChannels(context: ModelContext) {
        let descriptor = FetchDescriptor<TeamChannel>(
            sortBy: [SortDescriptor(\TeamChannel.lastMessageAt, order: .reverse)]
        )
        channels = (try? context.fetch(descriptor)) ?? []
        recomputeSortedAgents()
    }
```

**Callsite B — `.agentList` handler** at `ViewModels/TeamViewModel.swift:401-402`.

Find:
```swift
        case .agentList(let agents, _):
            self.agents = agents
```

Replace with:
```swift
        case .agentList(let agents, _):
            self.agents = agents
            recomputeSortedAgents()
```

**Callsite C — end of `updateChannelPreview(...)`** at `ViewModels/TeamViewModel.swift:620-633`. The call must go AFTER the existing `channels.sort` line so that `recomputeSortedAgents` reads from the already-sorted `channels` array.

Find:
```swift
    private func updateChannelPreview(channelId: String, text: String, date: Date = .now, context: ModelContext) {
        let cid = channelId
        let descriptor = FetchDescriptor<TeamChannel>(
            predicate: #Predicate { $0.id == cid }
        )
        if let channel = try? context.fetch(descriptor).first {
            channel.lastMessageText = String(text.prefix(100))
            if channel.lastMessageAt == nil || date > channel.lastMessageAt! {
                channel.lastMessageAt = date
            }
            try? context.save()
            channels.sort { ($0.lastMessageAt ?? .distantPast) > ($1.lastMessageAt ?? .distantPast) }
        }
    }
```

Replace with:
```swift
    private func updateChannelPreview(channelId: String, text: String, date: Date = .now, context: ModelContext) {
        let cid = channelId
        let descriptor = FetchDescriptor<TeamChannel>(
            predicate: #Predicate { $0.id == cid }
        )
        if let channel = try? context.fetch(descriptor).first {
            channel.lastMessageText = String(text.prefix(100))
            if channel.lastMessageAt == nil || date > channel.lastMessageAt! {
                channel.lastMessageAt = date
            }
            try? context.save()
            channels.sort { ($0.lastMessageAt ?? .distantPast) > ($1.lastMessageAt ?? .distantPast) }
            recomputeSortedAgents()
        }
    }
```

- [ ] **Step 2.4:** Do NOT commit yet — AgentRow rewrite (Task 1) and sidebar update (Task 3) must land together for the build to succeed. Commit happens at end of Task 4.

---

## Task 3: Simplify TeamSidebarView

**Files:**
- Modify: `Views/Team/TeamSidebarView.swift` (full rewrite)

- [ ] **Step 3.1:** Replace `Views/Team/TeamSidebarView.swift` with the new single-list implementation.

```swift
import SwiftUI

struct TeamSidebarView: View {
    @ObservedObject var viewModel: TeamViewModel

    var body: some View {
        List {
            ForEach(viewModel.sortedAgents, id: \.agent.id) { entry in
                Button {
                    viewModel.openAgentDM(agent: entry.agent)
                } label: {
                    AgentRow(
                        agent: entry.agent,
                        dmChannel: entry.dmChannel,
                        isActive: entry.dmChannel?.id == viewModel.activeChannelId
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if viewModel.agents.isEmpty {
                ContentUnavailableView {
                    Label("No Agents", systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text("Connecting to Hive...")
                }
            }
        }
    }
}
```

Note: `ChannelRow` struct, `dmChannels` / `groupChannels` computed properties, the `List(selection:)` binding, and the `.tag(channel.id)` / `.onTapGesture` patterns are all intentionally deleted.

- [ ] **Step 3.2:** Do NOT commit yet. Commit at end of Task 4.

---

## Task 4: Update TeamRootView empty state & verify build

**Files:**
- Modify: `Views/Team/TeamRootView.swift:42-46`

- [ ] **Step 4.1:** Update the detail-pane `ContentUnavailableView`.

Find (lines 42-46):
```swift
                } else {
                    ContentUnavailableView {
                        Label("Select a conversation", systemImage: "bubble.left.and.bubble.right")
                    } description: {
                        Text("Choose a channel or DM from the sidebar")
                    }
                }
```

Replace with:
```swift
                } else {
                    ContentUnavailableView {
                        Label("Select an agent", systemImage: "bubble.left.and.bubble.right")
                    } description: {
                        Text("Choose an agent to start a conversation")
                    }
                }
```

- [ ] **Step 4.2:** Full build for iOS Simulator.

Run:
```bash
xcodebuild -project Keepur.xcodeproj -scheme Keepur -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -40
```

Expected: `** BUILD SUCCEEDED **`.

If build fails because of an `iPhone 16` simulator missing, substitute `-destination 'platform=iOS Simulator,name=iPhone 15'` or check available destinations with `xcodebuild -showdestinations -scheme Keepur -project Keepur.xcodeproj`.

- [ ] **Step 4.3:** Commit the UI + view-model changes together.

```bash
git add Views/Team/AgentRow.swift Views/Team/TeamSidebarView.swift Views/Team/TeamRootView.swift ViewModels/TeamViewModel.swift
git commit -m "feat: simplify Hive sidebar to single agent list

Replace 3-section sidebar (DMs/Channels/Agents) with one flat agent list.
AgentRow now renders a leading 36x36 status-dot container, last-message
preview (falling back to title/model), and relative time. Tapping an
agent opens the DM via the existing openAgentDM path.

TeamViewModel.sortedAgents is a new @Published pairing agents with their
DM channels (if any), recomputed on channelList, agentList, and
updateChannelPreview.

Refs #47"
```

---

## Task 5: Unit tests for sortedAgents

**Files:**
- Create: `KeeperTests/TeamSortedAgentsTests.swift`

- [ ] **Step 5.1:** Create the test file.

```swift
import XCTest
import SwiftData
@testable import Keepur

@MainActor
final class TeamSortedAgentsTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var vm: TeamViewModel!
    private var capability: CapabilityManager!

    override func setUp() async throws {
        let schema = Schema([TeamChannel.self, TeamMessage.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [config])
        context = ModelContext(container)
        capability = CapabilityManager()
        vm = TeamViewModel()
        vm.configure(context: context, capabilityManager: capability)
    }

    override func tearDown() async throws {
        vm = nil
        context = nil
        container = nil
        capability = nil
    }

    // MARK: - Fixtures

    private func makeAgent(id: String, name: String, status: String = "idle") -> TeamAgentInfo {
        TeamAgentInfo(
            id: id,
            name: name,
            icon: "",
            title: nil,
            model: "claude-sonnet-4-5",
            status: status,
            tools: [],
            schedule: [],
            channels: [],
            messagesProcessed: 0,
            lastActivity: nil
        )
    }

    private func insertDM(id: String, memberIds: [String], lastAt: Date?, preview: String? = "hi") {
        let ch = TeamChannel(
            id: id,
            type: "dm",
            name: "dm-\(id)",
            members: memberIds,
            lastMessageText: preview,
            lastMessageAt: lastAt
        )
        context.insert(ch)
        try? context.save()
        vm.channels.append(ch)
    }

    // MARK: - Tests

    /// Agents with more-recent DM activity sort above agents with older DM activity.
    func testSortByLastMessageDescending() {
        let a1 = makeAgent(id: "a1", name: "Alpha")
        let a2 = makeAgent(id: "a2", name: "Bravo")
        vm.agents = [a1, a2]

        let older = Date(timeIntervalSince1970: 1_000_000)
        let newer = Date(timeIntervalSince1970: 2_000_000)
        insertDM(id: "dm1", memberIds: ["a1"], lastAt: older)
        insertDM(id: "dm2", memberIds: ["a2"], lastAt: newer)

        vm.recomputeSortedAgents()

        XCTAssertEqual(vm.sortedAgents.map(\.agent.id), ["a2", "a1"])
    }

    /// Agents without a DM (nil lastMessageAt) sort at the bottom.
    func testAgentsWithoutDMSortLast() {
        let a1 = makeAgent(id: "a1", name: "Alpha")
        let a2 = makeAgent(id: "a2", name: "Bravo")
        let a3 = makeAgent(id: "a3", name: "Charlie")
        vm.agents = [a1, a2, a3]

        insertDM(id: "dm1", memberIds: ["a1"], lastAt: Date(timeIntervalSince1970: 1_000_000))

        vm.recomputeSortedAgents()

        XCTAssertEqual(vm.sortedAgents.first?.agent.id, "a1")
        let tail = vm.sortedAgents.dropFirst().map(\.agent.id)
        XCTAssertEqual(Set(tail), Set(["a2", "a3"]))
    }

    /// Alphabetical tiebreaker when neither agent has a DM.
    func testAlphabeticalTiebreakerForNoDM() {
        let a1 = makeAgent(id: "a1", name: "Charlie")
        let a2 = makeAgent(id: "a2", name: "Alpha")
        let a3 = makeAgent(id: "a3", name: "Bravo")
        vm.agents = [a1, a2, a3]

        vm.recomputeSortedAgents()

        XCTAssertEqual(vm.sortedAgents.map(\.agent.name), ["Alpha", "Bravo", "Charlie"])
    }

    /// DM channel is matched to the correct agent via members.contains.
    func testDMChannelPairedByMembers() {
        let a1 = makeAgent(id: "agent-1", name: "Alpha")
        let a2 = makeAgent(id: "agent-2", name: "Bravo")
        vm.agents = [a1, a2]

        insertDM(id: "dm1", memberIds: ["agent-2"], lastAt: Date())

        vm.recomputeSortedAgents()

        let alphaEntry = vm.sortedAgents.first { $0.agent.id == "agent-1" }
        let bravoEntry = vm.sortedAgents.first { $0.agent.id == "agent-2" }
        XCTAssertNil(alphaEntry?.dmChannel)
        XCTAssertEqual(bravoEntry?.dmChannel?.id, "dm1")
    }

    /// Non-DM channels (type != "dm") are ignored when pairing.
    func testNonDMChannelsIgnored() {
        let a1 = makeAgent(id: "a1", name: "Alpha")
        vm.agents = [a1]

        let ch = TeamChannel(
            id: "group1",
            type: "channel",
            name: "general",
            members: ["a1"],
            lastMessageText: "hi",
            lastMessageAt: Date()
        )
        context.insert(ch)
        try? context.save()
        vm.channels.append(ch)

        vm.recomputeSortedAgents()

        XCTAssertNil(vm.sortedAgents.first?.dmChannel)
    }

    /// All agents appear in the sorted list regardless of DM presence.
    func testAllAgentsAlwaysVisible() {
        let agents = (0..<5).map { makeAgent(id: "a\($0)", name: "Agent \($0)") }
        vm.agents = agents

        vm.recomputeSortedAgents()

        XCTAssertEqual(vm.sortedAgents.count, 5)
    }
}
```

- [ ] **Step 5.2:** Register the new test file in the Xcode project.

**Context:** `KeeperTests/` uses explicit file references in pbxproj (not the synchronized-folder pattern that the app target uses for `Views/`, `Models/`, etc.). This means creating the file on disk is not enough — it must also be added to three locations in `Keepur.xcodeproj/project.pbxproj`.

Pattern to mirror (from an existing registered test, e.g. `WorkspaceBrowsingTests.swift`):

1. **PBXBuildFile section** (around line 14): add one line.
2. **PBXFileReference section** (around line 37): add one line.
3. **PBXGroup KeeperTests `children`** (around line 123): add one entry alphabetized.
4. **PBXSourcesBuildPhase** `FA3F17F88ADF48199EFCC81D` `files` (around line 254): add one entry alphabetized.

Generate two fresh 24-char hex UUIDs (e.g. via `python3 -c "import uuid; print(uuid.uuid4().hex[:24].upper()); print(uuid.uuid4().hex[:24].upper())"`). Let BUILD_UUID = the first, FILEREF_UUID = the second.

Apply these exact edits to `Keepur.xcodeproj/project.pbxproj`:

**Edit 1** — PBXBuildFile (alphabetize among the existing test entries):

Find:
```
		CE9D0085AE1C4725914A0857 /* WorkspaceBrowsingTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = CB2BCCE6B8DE4CCF84DB3E65 /* WorkspaceBrowsingTests.swift */; };
```

Replace with:
```
		CE9D0085AE1C4725914A0857 /* WorkspaceBrowsingTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = CB2BCCE6B8DE4CCF84DB3E65 /* WorkspaceBrowsingTests.swift */; };
		<BUILD_UUID> /* TeamSortedAgentsTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = <FILEREF_UUID> /* TeamSortedAgentsTests.swift */; };
```

**Edit 2** — PBXFileReference:

Find:
```
		CB2BCCE6B8DE4CCF84DB3E65 /* WorkspaceBrowsingTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = WorkspaceBrowsingTests.swift; sourceTree = "<group>"; };
```

Replace with:
```
		CB2BCCE6B8DE4CCF84DB3E65 /* WorkspaceBrowsingTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = WorkspaceBrowsingTests.swift; sourceTree = "<group>"; };
		<FILEREF_UUID> /* TeamSortedAgentsTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = TeamSortedAgentsTests.swift; sourceTree = "<group>"; };
```

**Edit 3** — PBXGroup KeeperTests children (insert in alphabetical order, between `SessionReplacedTests` and `WorkspaceBrowsingTests`):

Find:
```
				A3B4C5D6E7F809A1B2C3D402 /* SessionReplacedTests.swift */,
				CB2BCCE6B8DE4CCF84DB3E65 /* WorkspaceBrowsingTests.swift */,
```

Replace with:
```
				A3B4C5D6E7F809A1B2C3D402 /* SessionReplacedTests.swift */,
				<FILEREF_UUID> /* TeamSortedAgentsTests.swift */,
				CB2BCCE6B8DE4CCF84DB3E65 /* WorkspaceBrowsingTests.swift */,
```

**Edit 4** — Sources build phase (insert in alphabetical order, between `SessionReplacedTests` and `WorkspaceBrowsingTests`):

Find:
```
				A3B4C5D6E7F809A1B2C3D401 /* SessionReplacedTests.swift in Sources */,
				CE9D0085AE1C4725914A0857 /* WorkspaceBrowsingTests.swift in Sources */,
```

Replace with:
```
				A3B4C5D6E7F809A1B2C3D401 /* SessionReplacedTests.swift in Sources */,
				<BUILD_UUID> /* TeamSortedAgentsTests.swift in Sources */,
				CE9D0085AE1C4725914A0857 /* WorkspaceBrowsingTests.swift in Sources */,
```

After editing, verify the project still opens cleanly:

```bash
xcodebuild -project Keepur.xcodeproj -list 2>&1 | head -20
```

Expected: lists `Keepur` and `KeeperTests` schemes/targets, no "project is corrupt" errors.

Run the new test:

```bash
xcodebuild test -project Keepur.xcodeproj -scheme Keepur -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:KeeperTests/TeamSortedAgentsTests 2>&1 | tail -30
```

Expected: `Test Suite 'TeamSortedAgentsTests' passed`.

If `TeamViewModel()` can't be initialized without extra setup, or `CapabilityManager()` lacks a parameterless init, inspect an existing registered test (e.g., `ChatResilienceTests.swift`) for the setup pattern and mirror it. Adjust fixtures rather than skipping the test.

- [ ] **Step 5.3:** Commit tests.

```bash
git add KeeperTests/TeamSortedAgentsTests.swift Keepur.xcodeproj/project.pbxproj
git commit -m "test: cover TeamViewModel.sortedAgents ordering and DM pairing

Refs #47"
```

---

## Task 6: Final validation

- [ ] **Step 6.1:** Full test suite.

```bash
xcodebuild test -project Keepur.xcodeproj -scheme Keepur -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -30
```

Expected: `** TEST SUCCEEDED **` with no regressions from existing tests.

- [ ] **Step 6.2:** Manual smoke on simulator — launch the app, connect to a Hive, confirm:
  - Sidebar shows one flat list of agents (no section headers).
  - Agents with prior DMs show last-message preview + relative time and sort first.
  - Agents without DMs show title/model as subtitle and sort alphabetically at the bottom.
  - Tapping an agent opens the DM (existing one or newly created).
  - Active agent's name is bolded while its DM is selected.
  - Empty detail pane reads "Select an agent" / "Choose an agent to start a conversation".
  - Empty sidebar (disconnected) reads "No Agents" / "Connecting to Hive...".

- [ ] **Step 6.3:** Done. Hand off to `/quality-gate` then `dodi-dev:review`.

---

## Notes

- `displayName(for:)` stays in `TeamViewModel` — used by `TeamChatView.swift:28` for the chat nav bar. Do not delete.
- `ChannelRow`, `dmChannels`, `groupChannels` are fully deleted; no other file references them (verified via grep).
- The `openAgentDM(agent:)` path is unchanged. Tap feedback (DM creation race, suppression of `/dm` system reply) already works and is exercised indirectly by the existing flow.
- Section 4 of the spec (stale session recovery) is deferred — do not attempt in this PR.
