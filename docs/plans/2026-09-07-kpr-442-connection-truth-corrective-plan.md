# KPR-442 — Pairing Teardown and Queue FIFO Corrective Implementation Plan

> **For agentic workers:** Use dodi-dev:implement to execute this plan after the dispatcher restores the implementation gate.

**Goal:** Close the two pre-PR contract gaps by synchronously clearing both VMs' retransmission state on pairing teardown and preserving per-session FIFO across reconnect reconciliation and queued-head releases.

**Architecture:** Keep the existing two VMs and BeekeeperSocket transport. ContentView installs an acyclic synchronous callback binding before configure/connect; Chat owns credential clearing and Team exposes an idempotent pairing reset distinct from ordinary disconnect. Chat uses two session-ID sets to hold admission after a queued head and to prevent an early live idle from receiving an extra initial-sync/fallback release.

**Tech Stack:** Swift 5, MainActor, SwiftUI, Combine, SwiftData, XCTest, existing FakeWebSocketTask/Factory and FakeCredentialStore; Keepur scheme, KeeperTests target, iPhone 17 Pro simulator and macOS build.

**Authority and resume:** The approved revised spec is `docs/specs/2026-09-07-kpr-442-connection-truth-design.md` at `f702df20fc9cccd3e5e1d730c32727d40128db61`, §§4–5 and §7, tests 11a/11c–11f/12a–12d/13a–13c. This is a draft for fresh plan review, not self-approval. Pre-PR findings are `pre-pr/1/opus`; the final spec review accepted both behavioral contracts and recommended the session-replacement variant included below.

The implementation baseline is **`1fa9a4efe62b0d17e2d5ca00595cd32c56989c5d` in `/Users/mokie/github/keepur-ios-KPR-442`**, nine implementation commits and 218 existing test methods. The original `docs/plans/2026-09-07-kpr-442-connection-truth-plan.md` has already been executed: **do not rerun its tasks**. This plan contains only the corrective delta. The dispatcher owns merging the latest epic documentation, including the approved spec and reviewed corrective plan, into that preserved child before resuming implementation; do not rebuild a child from the docs-only maturity worktree. Confirm that the preserved implementation remains an ancestor after that merge. If source has changed since this baseline, inspect the delta and reconcile this plan before editing. No reimplementation of banner, observable state, transport, error routing, concierge, or downstream C/D/E work is authorized here.

Paths in task file lists and commands are repository-relative to `/Users/mokie/github/keepur-ios-KPR-442`; this document itself is authored in `/Users/mokie/github/keepur-ios-mature-kpr442-revision`. During planning, write only this document and the notice on the original plan; no implementation, builds, commits, pushes, or tracker writes.

## File Structure

| File | Responsibility in this delta |
|---|---|
| `ViewModels/ChatViewModel.swift` | Callback, queue attachment count, pairing reset ordering, per-session admission/release bookkeeping and cleanup. |
| `ViewModels/TeamViewModel.swift` | Callback, synchronous idempotent reset, read-only retained-attachment/request-map counts. |
| `Views/ContentView.swift` | Single production/test binding, auth observers update UI state only, both flags restored on pairing. |
| `KeeperTests/FakeWebSocketTask.swift` | Capture existing callback closures so tests actually replay stale work after teardown. |
| `KeeperTests/PairingTeardownTests.swift` (new) | Six lifecycle/negative-control tests using real VMs, production binding, shared fake credentials. |
| `KeeperTests/ChatViewModelSocketTests.swift` | Append 14 corrective tests and their focused helper; preserve every existing test and assertion. |

`Views` and `KeeperTests` are synchronized project groups; no pbxproj edit or new production coordinator is needed. Existing SwiftData history, composer drafts, wire encoding, ordinary Team disconnect and both hive-switch routes remain governed by the approved spec.

## Testing Contract

### Required Test Groups

- Unit: **required**.
  - Scope: Chat admission, release, reclassification, cleanup and migration; Team reset state.
  - Reason: The regressions depend on exact main-actor ordering and retained state.
  - Minimum assertions: Same-session A/B/C FIFO; unrelated idle session immediate send; mixed busy/offline FIFO; all A attachment frames before B; attachment-only emits no text; pending release holds when queue is empty; busy status holds; early idle is skipped by initial sync/fallback; repeated idle releases one head; cancel/end/absent/clear clean release-only state; replacement migrates both sets; rejected send retains bytes and head position; disconnect cancels fallback and clears connection bookkeeping.
- Integration: **required**.
  - Scope: Both VMs + real socket state/frame routing + ContentView's production binding + one shared FakeCredentialStore + in-memory SwiftData.
  - Reason: An isolated Team auth test missed the cross-VM pairing leak.
  - Harness: **existing**, extended by the callback-capture fake controls and one focused lifecycle test class below; no network or real Keychain setup.
  - Minimum assertions: Manual Settings call, Chat 4001, CapabilityManager unauthorized callback and Team 4001 each synchronously clear both queues and retained queued bytes, Team request mappings and both auth flags, and disconnect both sockets. Replay captured handshake/ack work and repeat teardown, then reuse VMs with new host/token/device but same session/hive/channel strings; old frames never replay, fresh messages and Team ack work. Unbound Team auth resets locally without clearing shared credentials. Both ordinary hive-switch variants preserve queued attachment bytes and resend on return.
- E2E: **not-required**.
  - Scope: Visual pairing/settings navigation and backend round trips.
  - Reason: This delta changes no view layout or wire contract; the exact production binding is callable from the deterministic integration harness. A new UI/backend harness would not improve coverage of synchronous completion or queue ownership.
  - Harness: **not-applicable**.
  - Minimum assertions: Not applicable; production call sites receive source review and iOS/macOS compilation.

### Critical Flows

- Each pairing-teardown origin completes reset before re-pair is admitted; delayed view observation performs no VM reset.
- Offline A, handshake, then B stays queued until authoritative release; queued-head completion cannot allow C to jump ahead.
- Live idle before initial list/fallback grants one release and is not granted a second release by the requested snapshot; other sessions progress independently.
- Session replacement/cleanup, ordinary disconnect and hive switches maintain their distinct ownership rules.

### Regression Surface

- All 218 existing test methods and assertions, including transport generation/close behavior, concierge bail, existing fallback/late-list/cancellation, Team hive stamps/ack and banner/error tests.
- No new secrets, endpoint URLs, payloads, tokens, or attachment bytes in production logs.
- Child C watchdog/coordinator and test-harness extraction, child D persistence/typed state and child E Team history/dedup stay out of scope.

### Commands

Run from the preserved child, **one xcodebuild at a time**. Keep simulator ad-hoc signing enabled; do not pass `CODE_SIGNING_ALLOWED=NO` to tests. Use unique result paths if rerunning instead of deleting prior evidence.

- Unit + Integration, Task 1: `xcodebuild test -project Keepur.xcodeproj -scheme Keepur -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -parallel-testing-enabled NO -only-testing:KeeperTests/PairingTeardownTests -only-testing:KeeperTests/TeamViewModelTests -resultBundlePath /tmp/kpr442-corrective-pairing-r1.xcresult` — **15 tests**, zero failures.
- Unit + Integration, Task 2: `xcodebuild test -project Keepur.xcodeproj -scheme Keepur -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -parallel-testing-enabled NO -only-testing:KeeperTests/ChatViewModelSocketTests -only-testing:KeeperTests/PairingTeardownTests -resultBundlePath /tmp/kpr442-corrective-queue-r1.xcresult` — **32 tests**, zero failures.
- E2E: not applicable, as above.
- Broader local regression: `xcodebuild test -project Keepur.xcodeproj -scheme Keepur -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -parallel-testing-enabled NO -only-testing:KeeperTests -skip-testing:KeeperTests/CapabilityManagerTests -resultBundlePath /tmp/kpr442-corrective-local-r1.xcresult` — **226 tests**, zero failures.
- Full suite in CI, no skip: existing `.github/workflows/test.yml` uses `xcodebuild test -project Keepur.xcodeproj -scheme Keepur -destination "platform=iOS Simulator,name=${{ steps.sim.outputs.name }}" -only-testing:KeeperTests -resultBundlePath TestResults.xcresult` — **238 tests**, zero failures. CI's runtime chooses the installed iPhone. The exact equivalent on this host would use `name=iPhone 17 Pro`, but do not run the known crashing group locally merely to reproduce it.
- macOS (after iOS has exited): `xcodebuild build -project Keepur.xcodeproj -scheme Keepur -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` — exit 0, no new warnings.

### Harness Requirements

- Xcode 26.3 and installed iPhone 17 Pro; retain the scheme's nonparallel test behavior.
- In-memory SwiftData includes Session, Message, Workspace, TeamChannel and TeamMessage for lifecycle tests, and Session/Message/Workspace for corrective queue tests.
- Two socket factories with one shared fake credential instance in the lifecycle fixture; mutable fake host; production `ContentView.bindPairingTeardown` installed before configure/connect. Capability auth test invokes the installed callback, without a real HTTP refresh.
- Save/restore `selectedHive` UserDefaults value. Disconnect fixtures on exit to cancel timers; fallback tests wait on the real five-second fallback, with a bounded seven-second polling deadline. No timer injection/coordinator rewrite in this child.
- Known baseline: all **12 CapabilityManagerTests** locally crash the Xcode 26.3 test host with malloc/pop-up behavior (KPR-446), already present at `1fa9a4e`; the other **206 local tests** and macOS/static checks were reported green. This is an explicit local baseline exclusion, not a claim that the full suite passed. Preserve CI's full suite requirement and report its actual outcome. Existing KPR-447 Team/Keychain ordering remains tracked; these new lifecycle tests create no new network/Keychain dependency.

### Non-Required Rationale

- E2E: Production callback integration plus real socket fake-task execution asserts the boundary directly; no UI/backend behavior changed.

### Verification Rules

- Missing harness is not a skip reason; set it up or report a concrete blocker.
- If a test failure exposes an implementation issue, fix the implementation, not the test.
- If testing exposes a spec or plan mismatch, demote the ticket to the spec lane.
- Preserve all 218 existing test methods/assertions. Add exactly **6 + 14 = 20**, yielding **238 total**, **226 locally runnable with the 12-test baseline exclusion**. Loop variants below are assertions within one XCTest method, not additional test counts.
- Do not use zsh's read-only `status` variable for exit handling. Direct commands are preferred; for piped logging use `set -o pipefail` and a task-specific variable such as `test_exit`.

---

### Task 1: Bind synchronous pairing teardown and prove every origin

**Files:** Modify `ViewModels/ChatViewModel.swift:23,78,264`, `ViewModels/TeamViewModel.swift:17,81,363`, `Views/ContentView.swift:12-66`, `KeeperTests/FakeWebSocketTask.swift:50`; Create `KeeperTests/PairingTeardownTests.swift`.

- [ ] **Step 1: Add the bounded VM surface and reset ordering.**

In ChatViewModel, add these properties next to authentication and queue state respectively (the sets are declared here so this task compiles; Task 2 wires normal queue releases):

```swift
var onUnpair: (() -> Void)?
private var queueReleasePendingIdle: Set<String> = []
private var releasedBeforeReconnectSync: Set<String> = []
var queuedAttachmentCountForTesting: Int {
    pendingMessages.filter { $0.attachment != nil }.count
}
```

Replace `unpair()` completely:

```swift
func unpair() {
    socket.disconnect()
    pendingMessages.removeAll()
    pendingReasons.removeAll()
    postReconnectFlushFallback?.cancel()
    postReconnectFlushFallback = nil
    awaitingPostReconnectSync = false
    queueReleasePendingIdle.removeAll()
    releasedBeforeReconnectSync.removeAll()
    onUnpair?()
    credentials.clearAll()
    isAuthenticated = false
}
```

In TeamViewModel, add the callback next to authentication and counts next to the queue state. Replace its private auth handler and add the public-in-module reset exactly as follows. Update the queue comment to say whole-queue clears happen only on **pairing teardown**, not merely Team auth failure. Ordinary `disconnect()` is unchanged.

```swift
var onAuthFailure: (() -> Void)?
var queuedAttachmentCountForTesting: Int { offlineAttachments.count }
var pendingMessageRequestCountForTesting: Int { pendingMessageIds.count }

func resetForPairingTeardown() {
    disconnect()
    // The synchronous transition-out collection has now finished.
    offlineEntries.removeAll()
    offlineAttachments.removeAll()
    pendingMessageIds.removeAll()
    activeHive = nil
    isAuthenticated = false
}

private func handleAuthFailure() {
    resetForPairingTeardown()
    onAuthFailure?()
}
```

- [ ] **Step 2: Install the exact binding in both production entry paths.**

Add this internal static helper in `ContentView`, before `body`:

```swift
@MainActor
static func bindPairingTeardown(
    chat: ChatViewModel, team: TeamViewModel, capabilities: CapabilityManager
) {
    chat.onUnpair = { [weak team] in team?.resetForPairingTeardown() }
    team.onAuthFailure = { [weak chat] in chat?.unpair() }
    capabilities.onAuthFailure = { [weak chat] in chat?.unpair() }
}
```

Replace the complete `PairingView.onPaired` closure with:

```swift
onPaired: {
    Self.bindPairingTeardown(chat: chatViewModel, team: teamViewModel,
                            capabilities: capabilityManager)
    chatViewModel.isAuthenticated = true
    teamViewModel.isAuthenticated = true
    isPaired = true
    chatViewModel.configure(context: modelContext)
    teamViewModel.speechManager = chatViewModel.speechManager
    teamViewModel.configure(context: modelContext, capabilityManager: capabilityManager)
},
```

Replace the initial `capabilityManager.onAuthFailure = ...` assignment in `.onAppear` with:

```swift
Self.bindPairingTeardown(chat: chatViewModel, team: teamViewModel,
                        capabilities: capabilityManager)
```

Keep the rest of `.onAppear`, scene-phase behavior, and Team configure-once guard unchanged. Replace both auth observers in full:

```swift
.onChange(of: chatViewModel.isAuthenticated) {
    if !chatViewModel.isAuthenticated && isPaired { isPaired = false }
}
.onChange(of: teamViewModel.isAuthenticated) {
    if !teamViewModel.isAuthenticated && isPaired { isPaired = false }
}
```

- [ ] **Step 3: Add captured-callback controls to the existing fake.**

Append inside `FakeWebSocketTask`, without changing existing methods. These copy callbacks while they are live; a later invocation genuinely exercises the socket's generation guard rather than calling an already-consumed fake handler.

```swift
func savedHandshakeCompletion() -> () -> Void {
    let handler = pingHandler
    return { handler?(nil) }
}

func savedDelivery(_ text: String) -> () -> Void {
    let handler = receiveHandler
    return { handler?(.success(.string(text))) }
}
```

- [ ] **Step 4: Create the complete six-test lifecycle file.**

```swift
import XCTest
import SwiftData
@testable import Keepur

@MainActor
final class PairingTeardownTests: XCTestCase {
    private var savedHive: String?
    override func setUp() async throws {
        savedHive = UserDefaults.standard.string(forKey: "selectedHive")
        UserDefaults.standard.removeObject(forKey: "selectedHive")
    }
    override func tearDown() async throws {
        if let savedHive { UserDefaults.standard.set(savedHive, forKey: "selectedHive") }
        else { UserDefaults.standard.removeObject(forKey: "selectedHive") }
    }

    @MainActor
    private final class Fixture {
        final class Endpoint { var host = "old.unit.test" }
        let endpoint: Endpoint
        let credentials: FakeCredentialStore
        let chatFactory: FakeWebSocketTaskFactory
        let teamFactory: FakeWebSocketTaskFactory
        let capabilities: CapabilityManager
        let container: ModelContainer
        let context: ModelContext
        let chat: ChatViewModel
        let team: TeamViewModel
        init(bound: Bool = true) throws {
            let endpoint = Endpoint()
            let credentials = FakeCredentialStore(deviceId: "old-device")
            let chatFactory = FakeWebSocketTaskFactory(), teamFactory = FakeWebSocketTaskFactory()
            let capabilities = CapabilityManager()
            let schema = Schema([Session.self, Message.self, Workspace.self,
                                 TeamChannel.self, TeamMessage.self])
            let container = try ModelContainer(for: schema, configurations: [
                ModelConfiguration(isStoredInMemoryOnly: true)
            ])
            let context = ModelContext(container)
            let chat = ChatViewModel(socket: BeekeeperSocket(credentials: credentials,
                endpoint: { URL(string: "wss://\(endpoint.host)")! },
                taskFactory: { chatFactory.make(url: $0) }), credentials: credentials)
            let team = TeamViewModel(socket: BeekeeperSocket(credentials: credentials,
                endpoint: { URL(string: "wss://\(endpoint.host)")! },
                taskFactory: { teamFactory.make(url: $0) }), credentials: credentials)
            self.endpoint = endpoint
            self.credentials = credentials
            self.chatFactory = chatFactory
            self.teamFactory = teamFactory
            self.capabilities = capabilities
            self.container = container
            self.context = context
            self.chat = chat
            self.team = team
            if bound {
                ContentView.bindPairingTeardown(chat: chat, team: team,
                                               capabilities: capabilities)
            }
            capabilities._setHivesForTesting(["hive-1", "hive-2"])
            chat.configure(context: context)
            team.configure(context: context, capabilityManager: capabilities)
            chat.currentSessionId = "s1"
            chat.sessionStatuses["s1"] = "idle"
            team.activeChannelId = "channel-1"
        }
        func close() { chat.disconnect(); team.disconnect() }
    }
    private let bytes = Data([1, 7, 42])
    private func settle() async { for _ in 0..<8 { await Task.yield() } }
    private func frames(_ task: FakeWebSocketTask) throws -> [[String: Any]] {
        try task.sentTexts.map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }
    private func payloads(_ task: FakeWebSocketTask) throws -> [[String: Any]] {
        try frames(task).filter { ["message", "image", "file"].contains($0["type"] as? String ?? "") }
    }
    private func rows(_ f: Fixture) throws -> [TeamMessage] {
        try f.context.fetch(FetchDescriptor<TeamMessage>())
    }
    private func syncChat(_ task: FakeWebSocketTask) async {
        task.deliver(#"{"type":"session_list","sessions":[{"sessionId":"s1","path":"/tmp/p","state":"idle","mode":"sessions"}]}"#)
        await settle()
    }
    private func populate(_ f: Fixture) async throws
        -> (chat: FakeWebSocketTask, team: FakeWebSocketTask,
            oldHandshake: () -> Void, oldAck: () -> Void) {
        f.chat.messageText = "old-chat"
        f.chat.pendingAttachment = AttachmentData(data: bytes, name: "old-chat.png", mimeType: "image/png")
        f.chat.sendText()
        let chatTask = try XCTUnwrap(f.chatFactory.latest)
        let savedHandshake = chatTask.savedHandshakeCompletion()
        chatTask.completeHandshake()
        await settle() // Do not send the list: the Chat attachment remains queued.
        f.capabilities.selectedHive = "hive-1"
        f.team.connectIfPossible()
        f.team.pendingAttachment = AttachmentData(data: bytes, name: "old-team.bin", mimeType: "application/octet-stream")
        f.team.sendMessage(text: "old-team-queued")
        // Keep hive-1's never-sent attachment queued while hive-2 has a live request map.
        f.capabilities.selectedHive = "hive-2"
        f.team.connectIfPossible()
        let teamTask = try XCTUnwrap(f.teamFactory.latest)
        teamTask.completeHandshake()
        await settle()
        f.team.sendMessage(text: "old-team-unacked")
        let request = try XCTUnwrap(try payloads(teamTask).first?["id"] as? String)
        let savedAck = teamTask.savedDelivery(#"{"type":"ack","id":"\#(request)"}"#)
        XCTAssertEqual(f.chat.pendingReasons.count, 1)
        XCTAssertEqual(f.chat.queuedAttachmentCountForTesting, 1)
        XCTAssertEqual(f.team.offlineMessageIds.count, 1)
        XCTAssertEqual(f.team.queuedAttachmentCountForTesting, 1)
        XCTAssertEqual(f.team.pendingMessageRequestCountForTesting, 1)
        return (chatTask, teamTask, savedHandshake, savedAck)
    }
    private func assertReset(_ f: Fixture) {
        XCTAssertEqual(f.chat.connectionState, .disconnected)
        XCTAssertEqual(f.team.connectionState, .disconnected)
        XCTAssertFalse(f.chat.isAuthenticated)
        XCTAssertFalse(f.team.isAuthenticated)
        XCTAssertFalse(f.credentials.isPaired)
        XCTAssertNil(f.credentials.deviceId)
        XCTAssertNil(f.credentials.deviceName)
        XCTAssertTrue(f.chat.pendingReasons.isEmpty)
        XCTAssertEqual(f.chat.queuedAttachmentCountForTesting, 0)
        XCTAssertTrue(f.team.offlineEntries.isEmpty)
        XCTAssertEqual(f.team.queuedAttachmentCountForTesting, 0)
        XCTAssertEqual(f.team.pendingMessageRequestCountForTesting, 0)
    }
    private func lifecycle(_ origin: String) async throws {
        let f = try Fixture()
        defer { f.close() }
        let old = try await populate(f)
        let oldRows = try rows(f)
        switch origin {
        case "manual": f.chat.unpair()
        case "capability": try XCTUnwrap(f.capabilities.onAuthFailure)()
        case "chat":
            old.chat.failReceive(closeCode: URLSessionWebSocketTask.CloseCode(rawValue: 4001)!)
            await settle()
        default:
            old.team.failReceive(closeCode: URLSessionWebSocketTask.CloseCode(rawValue: 4001)!)
            await settle()
        }
        // Manual/capability routes reach these assertions without a yield/view observer.
        assertReset(f)
        XCTAssertEqual(f.credentials.clearAllCalls, 1)
        old.oldHandshake(); old.oldAck()
        await settle()
        assertReset(f)
        XCTAssertTrue(oldRows.allSatisfy(\.pending), "stale ack must not mutate persisted rows")
        f.chat.unpair()
        f.team.resetForPairingTeardown()
        assertReset(f)
        XCTAssertEqual(f.credentials.clearAllCalls, 2, "Team reset must not notify recursively")

        f.credentials.token = "new-test-token"
        f.credentials.deviceId = "new-device"
        f.credentials.deviceName = "New Device"
        f.endpoint.host = "new.unit.test"
        ContentView.bindPairingTeardown(chat: f.chat, team: f.team, capabilities: f.capabilities)
        f.chat.isAuthenticated = true
        f.team.isAuthenticated = true
        f.chat.configure(context: f.context)
        f.team.configure(context: f.context, capabilityManager: f.capabilities)
        f.chat.currentSessionId = "s1"
        f.capabilities.selectedHive = "hive-2"
        f.team.connectIfPossible()
        let chatTask = try XCTUnwrap(f.chatFactory.latest)
        let teamTask = try XCTUnwrap(f.teamFactory.latest)
        for task in [chatTask, teamTask] {
            XCTAssertEqual(task.url.host, "new.unit.test")
            let query = URLComponents(url: task.url, resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(query?.first(where: { $0.name == "token" })?.value, "new-test-token")
            task.completeHandshake()
        }
        await settle()
        old.oldHandshake(); old.oldAck()
        await settle()
        await syncChat(chatTask)
        XCTAssertTrue(try payloads(chatTask).isEmpty)
        XCTAssertTrue(try payloads(teamTask).isEmpty)
        XCTAssertTrue(f.chat.isAuthenticated)
        XCTAssertTrue(f.team.isAuthenticated)
        XCTAssertEqual(f.credentials.clearAllCalls, 2)
        // Return to the same hive string that owned the old retained attachment too.
        f.capabilities.selectedHive = "hive-1"
        f.team.connectIfPossible()
        let returnedTeamTask = try XCTUnwrap(f.teamFactory.latest)
        returnedTeamTask.completeHandshake()
        await settle()
        XCTAssertTrue(try payloads(returnedTeamTask).isEmpty)
        f.chat.messageText = "fresh-chat"
        f.chat.sendText()
        f.team.sendMessage(text: "fresh-team")
        XCTAssertEqual(try payloads(chatTask).compactMap { $0["text"] as? String }, ["fresh-chat"])
        let fresh = try XCTUnwrap(try payloads(returnedTeamTask).first)
        XCTAssertEqual(fresh["text"] as? String, "fresh-team")
        XCTAssertEqual(try rows(f).first(where: { $0.text == "fresh-team" })?.senderId, "new-device")
        let freshId = try XCTUnwrap(fresh["id"] as? String)
        returnedTeamTask.deliver(#"{"type":"ack","id":"\#(freshId)"}"#)
        await settle()
        XCTAssertEqual(try rows(f).first(where: { $0.text == "fresh-team" })?.pending, false)
        XCTAssertEqual(f.team.pendingMessageRequestCountForTesting, 0)
        XCTAssertEqual(try rows(f).count, oldRows.count + 1, "history is retained")
    }
    func testManualUnpairClearsBothVMsBeforeReturning() async throws { try await lifecycle("manual") }
    func testChat4001ClearsBothVMs() async throws { try await lifecycle("chat") }
    func testCapabilityUnauthorizedClearsBothVMsBeforeReturning() async throws { try await lifecycle("capability") }
    func testTeam4001ClearsBothVMsWithoutCallbackCycle() async throws { try await lifecycle("team") }

    func testUnboundTeam4001ReleasesAttachmentsAndMappingsIdempotently() async throws {
        let f = try Fixture(bound: false)
        defer { f.close() }
        let old = try await populate(f)
        old.team.failReceive(closeCode: URLSessionWebSocketTask.CloseCode(rawValue: 4001)!)
        await settle()
        XCTAssertEqual(f.team.connectionState, .disconnected)
        XCTAssertFalse(f.team.isAuthenticated)
        XCTAssertTrue(f.team.offlineEntries.isEmpty)
        XCTAssertEqual(f.team.queuedAttachmentCountForTesting, 0)
        XCTAssertEqual(f.team.pendingMessageRequestCountForTesting, 0)
        f.team.resetForPairingTeardown()
        XCTAssertEqual(f.credentials.clearAllCalls, 0)
        f.team.isAuthenticated = true
        for hive in ["hive-2", "hive-1"] {
            f.capabilities.selectedHive = hive
            f.team.connectIfPossible()
            let task = try XCTUnwrap(f.teamFactory.latest)
            task.completeHandshake()
            await settle()
            XCTAssertTrue(try payloads(task).isEmpty)
        }
    }
    func testOrdinaryAndDirectHiveSwitchPreserveQueuedAttachment() async throws {
        for explicitDisconnect in [true, false] {
            let f = try Fixture()
            defer { f.close() }
            f.capabilities.selectedHive = "hive-1"
            f.team.connectIfPossible()
            f.team.pendingAttachment = AttachmentData(data: bytes, name: "keep.bin", mimeType: "application/octet-stream")
            f.team.sendMessage(text: "keep")
            let original = f.team.offlineEntries
            XCTAssertEqual(original.count, 1)
            if explicitDisconnect { f.team.disconnect() }
            f.capabilities.selectedHive = "hive-2"
            f.team.connectIfPossible()
            let other = try XCTUnwrap(f.teamFactory.latest)
            other.completeHandshake()
            await settle()
            XCTAssertEqual(f.team.offlineEntries, original)
            XCTAssertEqual(f.team.queuedAttachmentCountForTesting, 1)
            XCTAssertTrue(try payloads(other).isEmpty)
            f.capabilities.selectedHive = "hive-1"
            f.team.connectIfPossible()
            let returned = try XCTUnwrap(f.teamFactory.latest)
            returned.completeHandshake()
            await settle()
            let sent = try payloads(returned)
            XCTAssertEqual(sent.compactMap { $0["type"] as? String }, ["message", "file"])
            XCTAssertEqual(sent.last?["filename"] as? String, "keep.bin")
            XCTAssertEqual(sent.last?["data"] as? String, bytes.base64EncodedString())
            XCTAssertTrue(f.team.offlineEntries.isEmpty)
            XCTAssertEqual(f.team.queuedAttachmentCountForTesting, 0)
            XCTAssertEqual(f.credentials.clearAllCalls, 0)
            XCTAssertTrue(f.chat.isAuthenticated)
            XCTAssertTrue(f.team.isAuthenticated)
        }
    }
}
```

- [ ] **Step 5: Verify and commit this corrective slice.** Run the Task 1 command from the Testing Contract. Expect 15 tests, zero failures. Run `git diff --check`; inspect ContentView to confirm both binding sites precede configure/connect and observers contain no VM calls. Confirm no test invokes CapabilityManager.refresh or clears Keychain. Then:

```bash
git add ViewModels/ChatViewModel.swift ViewModels/TeamViewModel.swift Views/ContentView.swift KeeperTests/FakeWebSocketTask.swift KeeperTests/PairingTeardownTests.swift
git commit -m "fix: clear both message queues synchronously on pairing teardown"
```

### Task 2: Preserve per-session FIFO and idle-release ownership

**Files:** Modify `ViewModels/ChatViewModel.swift:146-171,204-213,293-340,544-546,623-654,714-824`; Test `KeeperTests/ChatViewModelSocketTests.swift` (append; retain original body).

- [ ] **Step 1: Change admission, connection bookkeeping and queue helpers.**

The two sets were declared in Task 1. Replace the admission conditional inside `sendText` with this complete block; row construction, trimmed text, attachments, and composer reset stay unchanged:

```swift
if connectionState != .connected {
    enqueue(entry, reason: .offline)
} else if pendingMessages.contains(where: { $0.sessionId == sessionId })
            || queueReleasePendingIdle.contains(sessionId) {
    let hasOffline = pendingMessages.contains {
        $0.sessionId == sessionId && pendingReasons[$0.messageId] == .offline
    }
    enqueue(entry, reason: hasOffline ? .offline : .busy)
} else if statusFor(sessionId) != "idle" {
    enqueue(entry, reason: .busy)
} else {
    sendToServer(entry)
}
```

Replace `handleSocketState` in full. The state sink still performs no synchronous send:

```swift
private func handleSocketState(_ state: BeekeeperSocket.State) {
    let previous = connectionState
    connectionState = state
    if state == .connected, previous != .connected {
        queueReleasePendingIdle.removeAll()
        releasedBeforeReconnectSync.removeAll()
        awaitingPostReconnectSync = true
        postReconnectFlushFallback?.cancel()
        postReconnectFlushFallback = Task { [weak self] in
            try? await Task.sleep(for: Self.postReconnectFlushTimeout)
            guard !Task.isCancelled, let self else { return }
            let alreadyReleased = self.releasedBeforeReconnectSync
            self.awaitingPostReconnectSync = false
            self.postReconnectFlushFallback = nil
            self.releasedBeforeReconnectSync.removeAll()
            self.flushOfflineQueue(skipping: alreadyReleased)
        }
    } else if state != .connected, previous == .connected {
        postReconnectFlushFallback?.cancel()
        postReconnectFlushFallback = nil
        awaitingPostReconnectSync = false
        queueReleasePendingIdle.removeAll()
        releasedBeforeReconnectSync.removeAll()
        // Unsent entries survive; already submitted Chat messages are not requeued.
    }
}
```

Replace `flushNextPendingMessage` and `clearPendingMessages` in full, then add these two helpers. Keep `enqueue`, `sendToServer`, global `reclassifyOfflineAsBusy()` and `flushOfflineQueue(skipping:)` unchanged. The return value records an actual successful release, not an attempted or empty flush.

```swift
@discardableResult
private func flushNextPendingMessage(for sessionId: String) -> Bool {
    guard connectionState == .connected, statusFor(sessionId) == "idle",
          !queueReleasePendingIdle.contains(sessionId),
          let index = pendingMessages.firstIndex(where: { $0.sessionId == sessionId }) else {
        return false
    }
    let entry = pendingMessages.remove(at: index)
    pendingReasons.removeValue(forKey: entry.messageId)
    guard sendToServer(entry) else { return false }
    queueReleasePendingIdle.insert(sessionId)
    if awaitingPostReconnectSync { releasedBeforeReconnectSync.insert(sessionId) }
    return true
}

private func clearPendingMessages(for sessionId: String) {
    queueReleasePendingIdle.remove(sessionId)
    releasedBeforeReconnectSync.remove(sessionId)
    let removed = pendingMessages.filter { $0.sessionId == sessionId }
    pendingMessages.removeAll { $0.sessionId == sessionId }
    for entry in removed { pendingReasons.removeValue(forKey: entry.messageId) }
}

private func reclassifyOfflineAsBusy(for sessionId: String) {
    guard connectionState == .connected else { return }
    for entry in pendingMessages where entry.sessionId == sessionId {
        if pendingReasons[entry.messageId] == .offline { pendingReasons[entry.messageId] = .busy }
    }
}

@discardableResult
private func releaseQueuedHead(for sessionId: String) -> Bool {
    queueReleasePendingIdle.remove(sessionId)
    reclassifyOfflineAsBusy(for: sessionId)
    return flushNextPendingMessage(for: sessionId)
}
```

- [ ] **Step 2: Connect existing status/watchdog events and migration/clear paths.**

In the `.status` case, replace its existing conditional idle flush with this complete block. It runs after the existing state/tool/watchdog updates, before `session_ended` cleanup:

```swift
if state == "idle" {
    releaseQueuedHead(for: effectiveId)
} else {
    reclassifyOfflineAsBusy(for: effectiveId)
}
```

In **both** existing watchdog closures, change only the final flush call to `releaseQueuedHead`. The complete final statements are respectively:

```swift
self?.sessionStatuses[effectiveId] = "idle"
self?.releaseQueuedHead(for: effectiveId)
```

```swift
self?.sessionStatuses[server.sessionId] = "idle"
self?.releaseQueuedHead(for: server.sessionId)
```

Immediately after `.sessionReplaced` migrates `pendingMessages[i].sessionId`, append:

```swift
if queueReleasePendingIdle.remove(oldSessionId) != nil {
    queueReleasePendingIdle.insert(newSessionId)
}
if releasedBeforeReconnectSync.remove(oldSessionId) != nil {
    releasedBeforeReconnectSync.insert(newSessionId)
}
```

At the very start of `deleteLocalSession(sessionId:)`, **before** its context guard, add:

```swift
clearPendingMessages(for: sessionId)
```

This covers both user `/clear` and `session_cleared`; `context_cleared`, cancellation and `endSession` already call the clearing helper. Removing the old helper's early return is essential: release-only state can exist after the last queue entry has gone. No timer duration or watchdog architecture changes.

- [ ] **Step 3: Replace `syncSessions` with the following complete method.**

Its existing local-row reconciliation, persistence and stale-session behavior stay intact. Changes are limited to capturing the initial skip set, including release-only IDs in cleanup, clearing a release only for an eligible busy→idle event, and the watchdog helper call.

```swift
    private func syncSessions(serverSessions: [ServerSession], allServerIds: Set<String>, context: ModelContext) {
        let serverIds = Set(serverSessions.map(\.sessionId))

        let descriptor = FetchDescriptor<Session>()
        guard let localSessions = try? context.fetch(descriptor) else { return }

        // B insertion 1 of 3 — post-reconnect reclassify (§4). Exactly one pass per
        // reconnect: whichever of this sync and the 5 s fallback fires first clears the flag.
        // Below the fetch guard on purpose: a failed fetch returns early and leaves the flag
        // armed, so the fallback still gets its single flush pass instead of consuming it here.
        let isPostReconnectSync = awaitingPostReconnectSync
        let alreadyReleased = isPostReconnectSync ? releasedBeforeReconnectSync : Set<String>()
        if isPostReconnectSync {
            awaitingPostReconnectSync = false
            releasedBeforeReconnectSync.removeAll()
            postReconnectFlushFallback?.cancel()
            postReconnectFlushFallback = nil
            reclassifyOfflineAsBusy()
        }

        for local in localSessions {
            let wasStale = local.isStale
            local.isStale = !serverIds.contains(local.id)
            if local.isStale && !wasStale {
                streamingMessageIds[local.id] = nil
                lastCompletedMessageIds[local.id] = nil
                sessionToolNames.removeValue(forKey: local.id)
                busyTimers[local.id]?.cancel()
                busyTimers.removeValue(forKey: local.id)
            }
        }

        // B insertion 2 of 3 — absent-id cleanup (§5), against the FULL reply so the
        // concierge slot is never reaped. Queued messages for any absent session are
        // dropped; a non-idle absent session gets the full session_ended cleanup.
        let knownIds = Set(sessionStatuses.keys).union(pendingMessages.map(\.sessionId))
            .union(queueReleasePendingIdle).union(releasedBeforeReconnectSync)
        for id in knownIds where !allServerIds.contains(id) {
            if statusFor(id) != "idle" {
                endSession(id)
            } else {
                clearPendingMessages(for: id)
            }
        }

        let localIds = Set(localSessions.map(\.id))
        for server in serverSessions where !localIds.contains(server.sessionId) {
            let session = Session(id: server.sessionId, path: server.path)
            context.insert(session)
        }

        // Reconcile session statuses from server state
        var flushed = alreadyReleased
        for server in serverSessions {
            let serverState = server.state  // "idle" or "busy"
            let clientState = sessionStatuses[server.sessionId]
            if clientState != nil && clientState != "idle" && serverState == "idle" {
                sessionStatuses[server.sessionId] = "idle"
                busyTimers[server.sessionId]?.cancel()
                busyTimers.removeValue(forKey: server.sessionId)
                if !flushed.contains(server.sessionId), releaseQueuedHead(for: server.sessionId) {
                    flushed.insert(server.sessionId)
                }
            } else if clientState == nil || clientState == "idle" {
                sessionStatuses[server.sessionId] = serverState
                // Start watchdog if adopting a non-idle state from the server
                if serverState != "idle" {
                    busyTimers[server.sessionId]?.cancel()
                    busyTimers[server.sessionId] = Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .seconds(Self.staleBusyTimeout))
                        guard !Task.isCancelled else { return }
                        self?.sessionStatuses[server.sessionId] = "idle"
                        self?.releaseQueuedHead(for: server.sessionId)
                    }
                }
            }
        }

        try? context.save()

        if let currentSessionId, localSessions.first(where: { $0.id == currentSessionId })?.isStale == true {
            self.currentSessionId = nil
        }

        // B insertion 3 of 3 — post-loop flush (§4), only on the sync that cleared the flag.
        if isPostReconnectSync {
            flushOfflineQueue(skipping: flushed)
        }
    }
```

- [ ] **Step 4: Append these complete queue tests and helper to `KeeperTests/ChatViewModelSocketTests.swift`.**

Add `import Combine` to the file. Append after the existing class's closing brace. Existing tests and assertions stay byte-identical. The helper provides independent fixture construction to give each loop variant an independent VM/context; it uses the same real transport and existing fakes, and makes no production timing/harness changes.

```swift
@MainActor
private final class QueueReleaseHarness {
    let credentials: FakeCredentialStore
    let factory: FakeWebSocketTaskFactory
    let container: ModelContainer
    let context: ModelContext
    let vm: ChatViewModel
    var task: FakeWebSocketTask
    let bytes = Data([9, 4, 2])
    init() throws {
        let credentials = FakeCredentialStore(), factory = FakeWebSocketTaskFactory()
        let container = try ModelContainer(for: Session.self, Message.self, Workspace.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let vm = ChatViewModel(socket: BeekeeperSocket(credentials: credentials,
            endpoint: { URL(string: "wss://queue.unit.test")! },
            taskFactory: { factory.make(url: $0) }), credentials: credentials)
        vm.configure(context: context)
        self.credentials = credentials
        self.factory = factory
        self.container = container
        self.context = context
        self.vm = vm
        task = try XCTUnwrap(factory.latest)
        vm.currentSessionId = "s1"
        vm.sessionStatuses["s1"] = "idle"
    }
    func settle() async { for _ in 0..<8 { await Task.yield() } }
    func handshake() async { task.completeHandshake(); await settle() }
    func reconnectHandshake() async throws {
        vm.reconnect()
        task = try XCTUnwrap(factory.latest)
        await handshake()
    }
    func deliver(_ object: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        task.deliver(String(decoding: data, as: UTF8.self))
        await settle()
    }
    func list(_ sessions: [(String, String)] = [("s1", "idle")]) async throws {
        try await deliver(["type": "session_list", "sessions": sessions.map {
            ["sessionId": $0.0, "path": "/tmp/\($0.0)", "state": $0.1, "mode": "sessions"]
        }])
    }
    func status(_ state: String, _ id: String = "s1") async throws {
        try await deliver(["type": "status", "state": state, "sessionId": id])
    }
    @discardableResult
    func send(_ text: String, _ id: String = "s1", attachment: AttachmentData? = nil) throws -> String {
        vm.currentSessionId = id
        vm.messageText = text
        vm.pendingAttachment = attachment
        vm.sendText()
        let display = text.isEmpty ? (attachment?.name ?? "") : text
        let rows = try context.fetch(FetchDescriptor<Message>())
        return try XCTUnwrap(rows.first { $0.sessionId == id && $0.text == display }?.id)
    }
    func attachment(_ mime: String = "application/octet-stream") -> AttachmentData {
        AttachmentData(data: bytes, name: mime.hasPrefix("image/") ? "a.png" : "a.bin", mimeType: mime)
    }
    func payloads(_ id: String? = nil) throws -> [[String: Any]] {
        try task.sentTexts.map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }.filter {
            ["message", "image", "file"].contains($0["type"] as? String ?? "")
                && (id == nil || $0["sessionId"] as? String == id)
        }
    }
    func messages(_ id: String = "s1") throws -> [String] {
        try payloads(id).filter { $0["type"] as? String == "message" }.compactMap { $0["text"] as? String }
    }
    func waitForFallback(messageCount: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(7))
        while try payloads().filter({ $0["type"] as? String == "message" }).count < messageCount,
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(try payloads().filter { $0["type"] as? String == "message" }.count, messageCount)
    }
}

extension ChatViewModelSocketTests {
    func testSendAfterReconnectHandshakeJoinsEarlierOfflineEntries() async throws {
        for mixedBusy in [false, true] {
            let h = try QueueReleaseHarness()
            defer { h.vm.disconnect() }
            await h.handshake()
            try await h.list()
            var expected: [String] = []
            if mixedBusy {
                try await h.status("thinking")
                let older = try h.send("older-busy")
                XCTAssertEqual(h.vm.pendingReasons[older], .busy)
                expected.append("older-busy")
            }
            h.vm.disconnect()
            let a = try h.send("A")
            try await h.reconnectHandshake()
            let b = try h.send("B")
            XCTAssertTrue(try h.payloads().isEmpty)
            XCTAssertEqual(h.vm.pendingReasons[a], .offline)
            XCTAssertEqual(h.vm.pendingReasons[b], .offline)
            expected += ["A", "B", "C"]
            try await h.list()
            XCTAssertEqual(try h.messages(), Array(expected.prefix(1)))
            XCTAssertEqual(h.vm.pendingReasons[b], .busy)
            let c = try h.send("C")
            XCTAssertEqual(h.vm.pendingReasons[c], .busy)
            for count in 2...expected.count {
                try await h.status("idle")
                XCTAssertEqual(try h.messages(), Array(expected.prefix(count)))
            }
            XCTAssertTrue(h.vm.pendingReasons.isEmpty)
        }
    }

    func testReconnectBacklogDoesNotBlockUnrelatedSession() async throws {
        let h = try QueueReleaseHarness()
        defer { h.vm.disconnect() }
        let a = try h.send("A")
        await h.handshake()
        let b = try h.send("B")
        try h.send("X", "s2")
        XCTAssertEqual(try h.messages("s2"), ["X"])
        XCTAssertEqual(try h.messages(), [])
        XCTAssertEqual(h.vm.pendingReasons, [a: .offline, b: .offline])
        try await h.list([("s1", "idle"), ("s2", "idle")])
        XCTAssertEqual(try h.messages(), ["A"])
        XCTAssertEqual(try h.messages("s2"), ["X"])
    }

    func testAttachmentEntryCannotBeOvertakenDuringReconnect() async throws {
        for mime in ["image/png", "application/octet-stream"] {
            for text in ["", "A"] {
                let h = try QueueReleaseHarness()
                defer { h.vm.disconnect() }
                let attachment = h.attachment(mime)
                let a = try h.send(text, attachment: attachment)
                await h.handshake()
                let b = try h.send("B")
                XCTAssertEqual(h.vm.pendingReasons, [a: .offline, b: .offline])
                XCTAssertTrue(try h.payloads().isEmpty)
                try await h.list()
                let types = (text.isEmpty ? [] : ["message"]) + [mime.hasPrefix("image/") ? "image" : "file"]
                let sent = try h.payloads()
                XCTAssertEqual(sent.compactMap { $0["type"] as? String }, types)
                XCTAssertEqual(sent.last?["data"] as? String, h.bytes.base64EncodedString())
                XCTAssertEqual(sent.last?["filename"] as? String, attachment.name)
                XCTAssertEqual(try h.messages(), text.isEmpty ? [] : ["A"])
                XCTAssertEqual(h.vm.pendingReasons, [b: .busy])
                try await h.status("idle")
                XCTAssertEqual(try h.payloads().compactMap { $0["type"] as? String }, types + ["message"])
                XCTAssertEqual(try h.messages(), text.isEmpty ? ["B"] : ["A", "B"])
                XCTAssertTrue(h.vm.pendingReasons.isEmpty)
            }
        }
    }

    func testNewSendWaitsForIdleAfterQueueHeadEmptiesQueue() async throws {
        let h = try QueueReleaseHarness()
        defer { h.vm.disconnect() }
        try h.send("A")
        await h.handshake()
        try await h.list()
        XCTAssertTrue(h.vm.pendingReasons.isEmpty)
        let b = try h.send("B")
        XCTAssertEqual(h.vm.pendingReasons[b], .busy)
        XCTAssertEqual(try h.messages(), ["A"])
        try await h.status("thinking")
        let c = try h.send("C")
        XCTAssertEqual(h.vm.pendingReasons, [b: .busy, c: .busy])
        XCTAssertEqual(try h.messages(), ["A"])
        try await h.status("idle")
        XCTAssertEqual(try h.messages(), ["A", "B"])
        try await h.status("idle")
        XCTAssertEqual(try h.messages(), ["A", "B", "C"])
    }

    func testBusyReconnectListHoldsBothNewAndEarlierEntries() async throws {
        let h = try QueueReleaseHarness()
        defer { h.vm.disconnect() }
        let a = try h.send("A")
        await h.handshake()
        let b = try h.send("B")
        try await h.list([("s1", "busy")])
        XCTAssertEqual(h.vm.pendingReasons, [a: .busy, b: .busy])
        XCTAssertTrue(try h.payloads().isEmpty)
        try await h.status("idle")
        XCTAssertEqual(try h.messages(), ["A"])
        try await h.status("idle")
        XCTAssertEqual(try h.messages(), ["A", "B"])
    }

    func testLiveBusyBeforeListReclassifiesOnlyItsSession() async throws {
        let h = try QueueReleaseHarness()
        defer { h.vm.disconnect() }
        let a = try h.send("A")
        let x = try h.send("X", "s2")
        await h.handshake()
        try await h.status("thinking")
        let b = try h.send("B")
        XCTAssertEqual(h.vm.pendingReasons, [a: .busy, b: .busy, x: .offline])
        XCTAssertTrue(try h.payloads().isEmpty)
        try await h.list([("s1", "busy"), ("s2", "idle")])
        XCTAssertEqual(try h.messages(), [])
        XCTAssertEqual(try h.messages("s2"), ["X"])
        try await h.status("idle")
        XCTAssertEqual(try h.messages(), ["A"])
        try await h.status("idle")
        XCTAssertEqual(try h.messages(), ["A", "B"])
    }

    func testEarlyIdleReleaseIsNotRepeatedByInitialSync() async throws {
        for busyBeforeList in [false, true] {
            let h = try QueueReleaseHarness()
            defer { h.vm.disconnect() }
            try h.send("A")
            let b = try h.send("B")
            try h.send("X", "s2")
            await h.handshake()
            try await h.status("idle")
            XCTAssertEqual(try h.messages(), ["A"])
            XCTAssertEqual(h.vm.pendingReasons[b], .busy)
            let c = try h.send("C")
            if busyBeforeList { try await h.status("thinking") }
            try await h.list([("s1", "idle"), ("s2", "idle")])
            XCTAssertEqual(try h.messages(), ["A"], "initial busy-to-idle reconciliation cannot grant a second release")
            XCTAssertEqual(try h.messages("s2"), ["X"])
            XCTAssertEqual(h.vm.pendingReasons, [b: .busy, c: .busy])
            try await h.status("idle")
            XCTAssertEqual(try h.messages(), ["A", "B"])
            try await h.status("idle")
            XCTAssertEqual(try h.messages(), ["A", "B", "C"])
        }
    }

    func testEarlyIdleReleaseIsNotRepeatedByFallback() async throws {
        let h = try QueueReleaseHarness()
        defer { h.vm.disconnect() }
        try h.send("A")
        let b = try h.send("B")
        try h.send("X", "s2")
        await h.handshake()
        try await h.status("idle")
        let c = try h.send("C")
        XCTAssertEqual(try h.messages(), ["A"])
        try await h.waitForFallback(messageCount: 2) // A already sent; fallback must send only s2's X.
        XCTAssertEqual(try h.messages(), ["A"])
        XCTAssertEqual(try h.messages("s2"), ["X"])
        XCTAssertEqual(h.vm.pendingReasons, [b: .busy, c: .busy])
        try await h.list([("s1", "idle"), ("s2", "idle")])
        XCTAssertEqual(try h.messages(), ["A"])
        try await h.status("idle")
        XCTAssertEqual(try h.messages(), ["A", "B"])
        try await h.status("idle")
        XCTAssertEqual(try h.messages(), ["A", "B", "C"])
    }

    func testSendAfterHandshakeWaitsForFallbackAndLateListDoesNotDoubleFlush() async throws {
        let h = try QueueReleaseHarness()
        defer { h.vm.disconnect() }
        let a = try h.send("A")
        await h.handshake()
        let b = try h.send("B")
        XCTAssertEqual(h.vm.pendingReasons, [a: .offline, b: .offline])
        XCTAssertTrue(try h.payloads().isEmpty)
        try await h.waitForFallback(messageCount: 1)
        XCTAssertEqual(try h.messages(), ["A"])
        XCTAssertEqual(h.vm.pendingReasons, [b: .busy])
        try await h.list()
        XCTAssertEqual(try h.messages(), ["A"])
        try await h.status("idle")
        XCTAssertEqual(try h.messages(), ["A", "B"])
    }

    func testSessionReplacementMigratesReleaseAndInitialSyncSkip() async throws {
        for queuedBeforeReplacement in [false, true] {
            let h = try QueueReleaseHarness()
            defer { h.vm.disconnect() }
            try h.send("A")
            var b: String?
            if queuedBeforeReplacement { b = try h.send("B") }
            await h.handshake()
            try await h.status("idle")
            try await h.deliver(["type": "session_replaced", "oldSessionId": "s1",
                                 "newSessionId": "s-new", "path": "/tmp/s1"])
            XCTAssertEqual(h.vm.currentSessionId, "s-new")
            if !queuedBeforeReplacement { b = try h.send("B", "s-new") }
            let bID = try XCTUnwrap(b)
            let c = try h.send("C", "s-new")
            XCTAssertEqual(try h.messages("s-new"), [], "even an emptied queue must retain its migrated release gate")
            XCTAssertEqual(h.vm.pendingReasons, [bID: .busy, c: .busy])
            try await h.status("thinking", "s-new")
            try await h.list([("s-new", "idle")])
            XCTAssertEqual(try h.messages("s-new"), [], "migrated skip survives the initial busy-to-idle list")
            try await h.status("idle", "s-new")
            XCTAssertEqual(try h.messages("s-new"), ["B"])
            try await h.status("idle", "s-new")
            XCTAssertEqual(try h.messages("s-new"), ["B", "C"])
            XCTAssertEqual(try h.messages("s1"), ["A"])
            XCTAssertTrue(h.vm.pendingReasons.isEmpty)
        }
    }

    func testSessionCleanupRemovesReleaseOnlyAndQueuedBookkeeping() async throws {
        for cleanup in ["cancel", "ended", "absent", "clear", "server-clear", "context-clear"] {
            for queuedTail in [false, true] {
                let h = try QueueReleaseHarness()
                defer { h.vm.disconnect() }
                try h.send("A")
                await h.handshake()
                try await h.status("idle") // Last queue head sent before initial sync.
                if queuedTail { try h.send("B", attachment: h.attachment()) }
                switch cleanup {
                case "cancel": h.vm.cancelCurrentOperation(for: "s1")
                case "ended": try await h.status("session_ended")
                case "absent": try await h.list([])
                case "clear": h.vm.clearSession(sessionId: "s1")
                case "server-clear": try await h.deliver(["type": "session_cleared", "sessionId": "s1"])
                default:
                    try await h.deliver(["type": "context_cleared", "oldSessionId": "s1", "sessionId": "s1"])
                }
                XCTAssertTrue(h.vm.pendingReasons.isEmpty)
                XCTAssertEqual(h.vm.queuedAttachmentCountForTesting, 0)
                h.vm.sessionStatuses["s1"] = "idle"
                try h.send("fresh")
                XCTAssertEqual(try h.messages(), ["A", "fresh"], "release-only admission gate must be cleared")
                // For cleanup paths that did not consume initial sync, prove the old skip ID is gone too.
                if cleanup != "absent" {
                    h.vm.sessionStatuses["s1"] = "busy"
                    let next = try h.send("new-queued")
                    XCTAssertEqual(h.vm.pendingReasons[next], .busy)
                    h.vm.sessionStatuses["s1"] = "idle"
                    try await h.list()
                    XCTAssertEqual(try h.messages(), ["A", "fresh", "new-queued"])
                }
            }
        }
    }

    func testDisconnectClearsReleaseGateAndCancelsEarlierFallback() async throws {
        let h = try QueueReleaseHarness()
        defer { h.vm.disconnect() }
        try h.send("A")
        let b = try h.send("B")
        await h.handshake()
        try await h.status("idle")
        XCTAssertEqual(try h.messages(), ["A"])
        let old = h.task
        h.vm.disconnect()
        let c = try h.send("C", attachment: h.attachment())
        h.vm.reconnect()
        h.task = try XCTUnwrap(h.factory.latest)
        let reasons: [String: ChatViewModel.PendingReason] = [b: .busy, c: .offline]
        XCTAssertEqual(h.vm.pendingReasons, reasons)
        try await Task.sleep(for: .milliseconds(5200))
        XCTAssertEqual(h.vm.pendingReasons, reasons, "cancelled fallback must not reclassify C")
        XCTAssertTrue(h.task.sentTexts.isEmpty)
        await h.handshake()
        try await h.list()
        XCTAssertEqual(try h.messages(), ["B"], "old submitted A is not resent; stale release cannot block B")
        XCTAssertEqual(h.vm.pendingReasons, [c: .busy])
        try await h.status("idle")
        XCTAssertEqual(try h.messages(), ["B", "C"])
        XCTAssertEqual(try h.payloads().last?["data"] as? String, h.bytes.base64EncodedString())
        let oldMessages = try old.sentTexts.map {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }.compactMap { $0?["text"] as? String }
        XCTAssertEqual(oldMessages, ["A"])
    }

    func testRejectedDirectSendKeepsAttachmentAheadOfLaterSubmission() async throws {
        let h = try QueueReleaseHarness()
        // State forwarding is deliberately frozen below, so unpair also cancels
        // the VM's fallback directly rather than relying on its state subscriber.
        defer { h.vm.unpair() }
        await h.handshake()
        XCTAssertEqual(h.vm.connectionState, .connected)
        XCTAssertEqual(h.vm.socket.state, .connected)
        // Test-only fault injection: detach the existing state subscription, then
        // disconnect the real socket. Reflection avoids a production test seam;
        // unwrap both the reflected optional and its value so renames fail loudly.
        // This does not depend on Combine subscriber order or willSet timing.
        let stateSubscription = try XCTUnwrap(
            Mirror(reflecting: h.vm).descendant("stateSubscription") as? Optional<AnyCancellable>
        )
        try XCTUnwrap(stateSubscription).cancel()
        h.vm.socket.disconnect()
        XCTAssertTrue(h.vm.pendingReasons.isEmpty)
        XCTAssertEqual(h.vm.statusFor("s1"), "idle")
        XCTAssertEqual(h.vm.connectionState, .connected)
        XCTAssertEqual(h.vm.socket.state, .disconnected)
        let aID = try h.send("A", attachment: h.attachment())
        let bID = try h.send("B")
        XCTAssertEqual(h.vm.pendingReasons, [aID: .offline, bID: .offline])
        XCTAssertEqual(h.vm.queuedAttachmentCountForTesting, 1)
        XCTAssertTrue(try h.payloads().isEmpty)
        // The first handshake's initial-sync flag is still armed in the frozen VM.
        // Reconnect the transport before delivering that sync to release rejected A.
        try await h.reconnectHandshake()
        try await h.list()
        XCTAssertEqual(try h.payloads().compactMap { $0["type"] as? String }, ["message", "file"])
        XCTAssertEqual(try h.payloads().last?["data"] as? String, h.bytes.base64EncodedString())
        XCTAssertEqual(h.vm.pendingReasons, [bID: .busy])
        try await h.status("idle")
        XCTAssertEqual(try h.messages(), ["A", "B"])
    }

    func testOrdinaryBusyToIdleSyncReleasesHeldQueueHead() async throws {
        let h = try QueueReleaseHarness()
        defer { h.vm.disconnect() }
        try h.send("A")
        await h.handshake()
        try await h.list()
        let b = try h.send("B")
        try await h.status("thinking")
        XCTAssertEqual(h.vm.pendingReasons[b], .busy)
        try await h.list() // Ordinary sync after initial sync has already completed.
        XCTAssertEqual(try h.messages(), ["A", "B"])
        let c = try h.send("C")
        XCTAssertEqual(h.vm.pendingReasons[c], .busy)
        XCTAssertEqual(try h.messages(), ["A", "B"])
        try await h.status("idle")
        XCTAssertEqual(try h.messages(), ["A", "B", "C"])
    }
}
```

- [ ] **Step 5: Verify and commit the queue correction.** Run Task 2's exact command from the Testing Contract. Expect **26 ChatViewModelSocketTests + 6 PairingTeardownTests = 32**, zero failures. The three real-time fallback/cancellation cases add roughly 15–21 seconds; the preserved original fallback cases remain unchanged. If a simulator is slow, inspect result-bundle assertions before changing any wait; do not remove ordering assertions or silently increase production timeouts. Run `git diff --check`, then:

```bash
git add ViewModels/ChatViewModel.swift KeeperTests/ChatViewModelSocketTests.swift
git commit -m "fix: preserve per-session queue order through reconnect sync"
```

### Task 3: Verify the complete corrective delta and hand back for review

**Files:** Read all Task 1/2 files and `docs/specs/2026-09-07-kpr-442-connection-truth-design.md`; no additional source changes unless a preceding check exposes a defect in this delta.

- [ ] **Step 1: Run the broader local suite once, then macOS, serially.** Use the exact broader-local command above; expect **226 tests, zero failures**, explicitly excluding the known **12** CapabilityManagerTests. Inspect `xcrun xcresulttool get test-results summary --path /tmp/kpr442-corrective-local-r1.xcresult`; do not infer success from exit alone. After that process exits, run the macOS build command above and inspect warnings against the known clean baseline. Keep no token/URL/body dumps in build annotations or production logging. Do not run iOS and macOS builds concurrently.

- [ ] **Step 2: Run static and preservation checks.**

```bash
git diff --check 1fa9a4efe62b0d17e2d5ca00595cd32c56989c5d
rg -n 'viewModel\.socket\.' Views
rg -n 'disconnectedBanner|retryConnect|handleConnectionLost|previousSocketState' Views ViewModels KeeperTests Managers Models
rg -n 'queueReleasePendingIdle|releasedBeforeReconnectSync|releaseQueuedHead|bindPairingTeardown|resetForPairingTeardown' ViewModels Views KeeperTests
```

Expected: diff check exits 0; first two searches exit 1/no matches; the final search shows both binding calls, all four callback paths, both watchdog release sites, migration and cleanup. Review the actual diff: no sends occur inside the production state sink; ContentView's auth observers contain only `isPaired` assignment; Team's reset never invokes its callback or clears credentials; disconnect happens before queue clearing; all production logging remains unchanged.

Run this preservation check from the child. It checks exact existing test-method bodies against the original implementation rather than merely counting method names:

```bash
python3 - <<'PY'
from pathlib import Path
import re, subprocess
base = '1fa9a4efe62b0d17e2d5ca00595cd32c56989c5d'
pattern = re.compile(r'^    func (test\w+)\([^\n]*', re.M)
def bodies(text):
    result = {}
    for match in pattern.finditer(text):
        start = match.start()
        opening = text.index('{', match.start())
        depth = 1
        i = opening + 1
        while depth:
            depth += (text[i] == '{') - (text[i] == '}')
            i += 1
        result[match.group(1)] = text[start:i]
    return result
old_count = 0
new_count = 0
for path in sorted(Path('KeeperTests').glob('*.swift')):
    current = bodies(path.read_text())
    new_count += len(current)
    old = subprocess.run(['git', 'show', f'{base}:{path}'], text=True,
                         capture_output=True)
    if old.returncode != 0:
        assert path.name == 'PairingTeardownTests.swift', path
        continue
    original = bodies(old.stdout)
    old_count += len(original)
    for name, body in original.items():
        assert current.get(name) == body, f'Existing test changed: {path}:{name}'
assert old_count == 218, old_count
assert new_count == 238, new_count
assert len(bodies(Path('KeeperTests/PairingTeardownTests.swift').read_text())) == 6
assert len(bodies(Path('KeeperTests/ChatViewModelSocketTests.swift').read_text())) == 26
print('218 original test bodies preserved; 20 added; 238 total, 226 outside known local exclusion')
PY
```

Expected: exit 0 and the stated counts. This brace scanner is intentionally limited to these unchanged source bodies (their JSON/raw-string braces are balanced). If unrelated source adds test methods after the dispatcher merges docs, reconcile counts with the actual baseline and review the reason; never delete assertions to meet a count.

- [ ] **Step 3: Hand back for fresh implementation review and the normal child PR workflow.** Report exact commits, local xcresult counts and the 12-test known local exclusion, macOS warnings, static results, and any new failures. The dispatcher owns pre-PR review, gates/labels, submission and the requirement that the **full 238-test CI suite** pass without a CapabilityManager skip. Do not claim full verification or ready-to-merge while CI has not run. Do not copy the original plan's completed commits/tasks into this resume.

## Acceptance and coverage map

| Revised spec requirement | Concrete evidence |
|---|---|
| 11c–11f: four synchronous origins, shared credentials, real app binding | Four named `PairingTeardownTests` lifecycle methods; assertions before any yield for manual/capability. |
| Queued retained bytes + request map, idempotence, stale callbacks, re-pair/fresh sends | `populate`, `assertReset`, captured handshake/ack, same-instance lifecycle helper; separate unbound Team 4001 method. |
| Ordinary disconnect/direct switch preserve attachments | Sixth lifecycle method, both switch variants; all nine original Team tests retained. |
| 12a/12b: pre-list admission, mixed reasons, independent session | First two appended Chat tests; A/B/C exact wire order and .offline/.busy reasons. |
| 12c: attachments, attachment-only, whole-entry order | Four MIME/text variants in `testAttachmentEntryCannotBeOvertakenDuringReconnect`. |
| 12d: empty queue still holds next send; busy status | `testNewSendWaitsForIdleAfterQueueHeadEmptiesQueue`; cleanup test includes empty and queued-tail variants. |
| 13a: busy list and live per-session busy | Two separate busy tests, including an independent offline session. |
| 13b: early idle list/fallback, busy→idle skip, other sessions | Two early-idle methods; initial-sync test runs both cached-idle and client-busy variants. |
| 13c: post-handshake admission through fallback, late list, cancellation, rejected send | Three named fallback/admission, disconnect/cancellation and rejection methods; original fallback cases unchanged. |
| Session replacement advisory | `testSessionReplacementMigratesReleaseAndInitialSyncSkip` covers both a migrated queued B and a queue emptied by A before replacement; new-ID B/C wait, initial busy→idle list skips, live idles drain B/C. |
| All clear paths, even release-only | Cleanup method covers cancel, end, absent, user `/clear`, `session_cleared`, `context_cleared`, each with empty queue and queued attachment tail; fresh sends prove no stale gate. |
| Existing idle-release events, including watchdog | Ordinary sync test plus source verification that both existing watchdog transitions call the shared release helper; no 90-second timer seam added in this child. |

**Assumptions:** The dispatcher merges only the approved latest epic documentation into the preserved child before implementation; the implementation source remains based on `1fa9a4e`. The two approved corrections need no additional product/architecture decision. Existing fake callback capture and read-only queue counts are sufficient; no network, keychain, transport protocol, or new coordinator seam is introduced. The known local CapabilityManager host crash remains outside KPR-442, while a complete CI pass remains required.
