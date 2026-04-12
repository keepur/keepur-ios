# Team Agents UI Implementation Plan

> **For agentic workers:** Use dodi-dev:implement to execute this plan.

**Goal:** Let users discover agents and chat with them from the Team tab — agents section in sidebar, tap-to-DM, and agent detail card.

**Architecture:** Expose the existing `agent_list` WebSocket data via a new `@Published var agents` on `TeamViewModel`. Add `openAgentDM()` that finds or creates a DM channel using the existing `/dm` server command. New `AgentRow` view in a third sidebar section. New `AgentDetailSheet` presented from an info button in the DM chat nav bar.

**Tech Stack:** SwiftUI, SwiftData (existing TeamChannel/TeamMessage models), WebSocket (existing TeamWSManager)

---

### Task 1: TeamViewModel — Publish Agents + openAgentDM

**Files:**
- Modify: `ViewModels/TeamViewModel.swift`

- [ ] **Step 1:** Add `@Published var agents` property.

After line 11 (`@Published var lastLiveMessageId: String?`), add:

```swift
@Published var agents: [TeamAgentInfo] = []
```

- [ ] **Step 2:** Publish agents in `handleIncoming(.agentList)`.

Replace the existing `.agentList` case (lines 309-311):

```swift
case .agentList(let agents, _):
    agentNames = agents.map(\.name)
    rebuildWhisperPrompt()
```

With:

```swift
case .agentList(let agents, _):
    self.agents = agents
    agentNames = agents.map(\.name)
    rebuildWhisperPrompt()
```

- [ ] **Step 3:** Add private tracking vars for DM auto-creation.

After line 36 (`private var pendingNewCommands: Set<String> = []`), add:

```swift
private var pendingAgentDM: String?       // agent ID to auto-select after channel refresh
private var pendingDMRequestId: String?   // request UUID of the /dm command
```

- [ ] **Step 4:** Add `openAgentDM(agent:)` method.

Add after `sendSlashCommand` (after line 214):

```swift
func openAgentDM(agent: TeamAgentInfo) {
    // 1. Search for existing DM with this agent
    if let dm = channels.first(where: { $0.type == "dm" && $0.members.contains(agent.id) }) {
        selectChannel(dm.id)
        return
    }

    // 2. Not found — create via /dm command
    let command = TeamWSOutgoing.command(channelId: "", name: "dm", args: [agent.name])
    guard let requestId = ws.sendWithId(command) else { return }  // offline — no-op

    pendingNewCommands.insert(requestId)
    pendingAgentDM = agent.id
    pendingDMRequestId = requestId
}
```

- [ ] **Step 5:** Auto-select new DM channel after creation in `syncChannels`.

In `syncChannels(_:context:)` (around line 352, at the end of the method, after `loadChannels(context:)`), add:

```swift
// Auto-select DM after /dm creation
if let agentId = pendingAgentDM,
   let dm = channels.first(where: { $0.type == "dm" && $0.members.contains(agentId) }) {
    pendingAgentDM = nil
    pendingDMRequestId = nil
    selectChannel(dm.id)
}
```

- [ ] **Step 6:** Suppress `/dm` system response in `handleIncoming(.systemMessage)`.

In the `.systemMessage` case (lines 239-265), the existing handler already processes `replyTo` in order: first `pendingCommandChannels`, then `pendingNewCommands`. The new `pendingDMRequestId` check must be inserted as a **third** step, after both existing checks and before the code that creates a `TeamMessage`.

The three-step ordering in the `systemMessage` handler must be:

1. **Check `pendingCommandChannels`** (existing code) — will NOT match for `/dm` from `openAgentDM` because we intentionally don't track there.
2. **Check `pendingNewCommands`** (existing code) — WILL match, removes the request ID and calls `fetchChannels()`. This triggers the channel refresh that leads to auto-select in `syncChannels`. **Critical:** the existing `pendingNewCommands` handler uses `if/remove` without an early return — it falls through to subsequent checks. This is what allows step 3 to also run.
3. **Check `pendingDMRequestId`** (new code, inserted here) — if matched, clears pending state and returns early to suppress the system message.

On a `/dm` failure, step 2 still fires `fetchChannels()` (harmless — refreshes the existing list), and step 3 still clears `pendingAgentDM` + `pendingDMRequestId`, so pending state is cleaned up either way.

Insert the following after the existing `pendingNewCommands` check and **before** the code that creates a `TeamMessage`:

```swift
// Suppress /dm system response when initiated from openAgentDM
if let replyTo, replyTo == pendingDMRequestId {
    pendingAgentDM = nil
    pendingDMRequestId = nil
    return  // Navigation is the feedback; don't insert message
}
```

- [ ] **Step 7:** Clear pending state on reconnect and error.

In `onConnected()` (line 166), add at the top:

```swift
pendingAgentDM = nil
pendingDMRequestId = nil
```

In `handleIncoming(.error)` (the `.error` case), add:

```swift
pendingAgentDM = nil
pendingDMRequestId = nil
```

- [ ] **Step 8:** Verify build.

Run: `cd /Users/mokie/github/keepur-ios && xcodebuild -scheme Keepur -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 9:** Commit.

```bash
git add ViewModels/TeamViewModel.swift
git commit -m "feat(team): publish agents list and add openAgentDM with auto-select"
```

---

### Task 2: AgentRow — Sidebar Row Component

**Files:**
- Create: `Views/Team/AgentRow.swift`

- [ ] **Step 1:** Create `AgentRow.swift`.

```swift
import SwiftUI

struct AgentRow: View {
    let agent: TeamAgentInfo
    let isActive: Bool

    private var statusColor: Color {
        switch agent.status {
        case "idle": return .green
        case "processing": return .yellow
        case "error", "stopped": return .red
        default: return .gray
        }
    }

    private var iconText: String {
        agent.icon.isEmpty ? "🤖" : agent.icon
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

    var body: some View {
        HStack(spacing: 10) {
            Text(iconText)
                .font(.title2)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(agent.name)
                        .font(.body)
                        .fontWeight(isActive ? .semibold : .regular)
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                }

                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()
        }
        .contentShape(Rectangle())
    }
}
```

- [ ] **Step 2:** Add the file to the Xcode project.

The project uses automatic file discovery (no manual pbxproj entries for Swift sources) — placing the file in `Views/Team/` is sufficient.

- [ ] **Step 3:** Verify build.

Run: `cd /Users/mokie/github/keepur-ios && xcodebuild -scheme Keepur -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4:** Commit.

```bash
git add Views/Team/AgentRow.swift
git commit -m "feat(team): add AgentRow sidebar component"
```

---

### Task 3: TeamSidebarView — Add Agents Section

**Files:**
- Modify: `Views/Team/TeamSidebarView.swift`

- [ ] **Step 1:** Add the Agents section below the Channels section.

After the existing `if !groupChannels.isEmpty { Section("Channels") { ... } }` block (around line 38), add:

```swift
if !viewModel.agents.isEmpty {
    Section("Agents") {
        ForEach(viewModel.agents, id: \.id) { agent in
            AgentRow(agent: agent, isActive: false)
                .onTapGesture { viewModel.openAgentDM(agent: agent) }
        }
    }
}
```

Note: `isActive` is always `false` here because the sidebar selection tracks `activeChannelId`, not agent IDs. The active state is on the DM row, not the agent row.

- [ ] **Step 2:** Verify build.

Run: `cd /Users/mokie/github/keepur-ios && xcodebuild -scheme Keepur -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3:** Commit.

```bash
git add Views/Team/TeamSidebarView.swift
git commit -m "feat(team): add Agents section to sidebar"
```

---

### Task 4: AgentDetailSheet — Read-Only Info Card

**Files:**
- Create: `Views/Team/AgentDetailSheet.swift`

- [ ] **Step 1:** Create `AgentDetailSheet.swift`.

```swift
import SwiftUI

struct AgentDetailSheet: View {
    let agent: TeamAgentInfo

    private var statusColor: Color {
        switch agent.status {
        case "idle": return .green
        case "processing": return .yellow
        case "error", "stopped": return .red
        default: return .gray
        }
    }

    private var iconText: String {
        agent.icon.isEmpty ? "🤖" : agent.icon
    }

    private var lastActivityDate: Date? {
        guard let str = agent.lastActivity else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: str)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Header
                    VStack(spacing: 8) {
                        Text(iconText)
                            .font(.system(size: 48))
                        Text(agent.name)
                            .font(.title2.bold())
                        HStack(spacing: 6) {
                            Circle()
                                .fill(statusColor)
                                .frame(width: 10, height: 10)
                            Text(agent.status)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top)

                    // Info grid
                    VStack(spacing: 0) {
                        if let title = agent.title, !title.isEmpty {
                            infoRow(label: "Title", value: title)
                        }
                        if !agent.model.isEmpty {
                            infoRow(label: "Model", value: agent.model)
                        }
                        infoRow(label: "Messages", value: "\(agent.messagesProcessed)")
                        infoRow(label: "Last Active", date: lastActivityDate)
                    }
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                    // Tools
                    if !agent.tools.isEmpty {
                        sectionCard(title: "Tools") {
                            Text(agent.tools.joined(separator: ", "))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Schedule
                    if !agent.schedule.isEmpty {
                        sectionCard(title: "Schedule") {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(agent.schedule.enumerated()), id: \.offset) { _, entry in
                                    if let cron = entry["cron"], let task = entry["task"] {
                                        HStack(alignment: .top, spacing: 8) {
                                            Text(cron)
                                                .font(.caption.monospaced())
                                                .foregroundStyle(.secondary)
                                            Text("— \(task)")
                                                .font(.subheadline)
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // Channels
                    if !agent.channels.isEmpty {
                        sectionCard(title: "Channels") {
                            Text(agent.channels.map { "#\($0)" }.joined(separator: ", "))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Agent Info")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - Subviews

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
        .font(.subheadline)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func infoRow(label: String, date: Date?) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            if let date {
                Text(date, style: .relative)
            } else {
                Text("Never")
            }
        }
        .font(.subheadline)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func sectionCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
```

- [ ] **Step 2:** Verify build.

Run: `cd /Users/mokie/github/keepur-ios && xcodebuild -scheme Keepur -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3:** Commit.

```bash
git add Views/Team/AgentDetailSheet.swift
git commit -m "feat(team): add AgentDetailSheet read-only info card"
```

---

### Task 5: TeamChatView — Info Button + Sheet

**Files:**
- Modify: `Views/Team/TeamChatView.swift`

- [ ] **Step 1:** Add state and computed properties for agent detection.

At the top of `TeamChatView` (after existing properties), add:

```swift
@State private var showAgentDetail = false

private var activeAgent: TeamAgentInfo? {
    guard let channelId = viewModel.activeChannelId,
          let channel = viewModel.channels.first(where: { $0.id == channelId }),
          channel.type == "dm" else { return nil }
    return viewModel.agents.first { channel.members.contains($0.id) }
}

private var isDMWithAgent: Bool { activeAgent != nil }
```

- [ ] **Step 2:** Add toolbar info button.

Add a `.toolbar` modifier to the main view (after the existing `.navigationBarTitleDisplayMode(.inline)`):

```swift
.toolbar {
    ToolbarItem(placement: .topBarTrailing) {
        if isDMWithAgent {
            Button { showAgentDetail = true } label: {
                Image(systemName: "info.circle")
            }
        }
    }
}
.sheet(isPresented: $showAgentDetail) {
    if let agent = activeAgent {
        AgentDetailSheet(agent: agent)
            .presentationDetents([.medium, .large])
    }
}
```

Note: The sheet content uses `if let agent = activeAgent` to unwrap the optional, since `AgentDetailSheet` takes a non-optional `TeamAgentInfo`. The spec's `AgentDetailSheet(agent: activeAgent)` is illustrative — in practice, SwiftUI's `.sheet(isPresented:)` captures the binding at presentation time, so if `activeAgent` becomes nil during reconnect the `if let` safely shows nothing (the sheet is already dismissing). This is the correct Swift pattern.

- [ ] **Step 3:** Verify build.

Run: `cd /Users/mokie/github/keepur-ios && xcodebuild -scheme Keepur -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4:** Commit.

```bash
git add Views/Team/TeamChatView.swift
git commit -m "feat(team): add agent info button and detail sheet to chat view"
```
