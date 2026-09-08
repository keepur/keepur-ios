# KPR-443 — Injectable ChatViewModel Implementation Plan

> **For agentic workers:** Use dodi-dev:implement to execute this plan.

**Goal:** Make Chat's decoded state machine and concierge orchestration testable without speech construction, isolate approvals by session, and replace force-idle recovery with server reconciliation while retaining B's delivery contracts.

**Architecture:** Chat owns a private injected socket, lazy optional speech storage, and one post-handler decoded subject. The concierge coordinator owns one cancellable run whose request-local buffered relay is subscribed synchronously before each named request; the run holds its coordinator weakly across waits. Generation-checked watchdogs query the server, and full-list status reconciliation shares B's existing queue/release helpers while only Session-table work is filtered.

**Tech Stack:** Swift 5 with MainActor default isolation, SwiftUI, SwiftData, Combine, Swift structured concurrency, XCTest, Xcode 26.3; iOS 26.2+ and macOS 15+.

**Authority:** Approved [C spec](../specs/2026-09-07-kpr-443-injectable-chat-view-model-design.md), [spec gate](https://linear.app/keepur/issue/KPR-443#comment-94fbcd56), and KPR-441 canon through B / PR #105. Baseline is `e3b9e7dd486f413c12805d54e7e8794f433a349a`, containing B's merge `af6a9ed15f0607cf22abae83be414c956d7f5803`. B's Linear In Review status is the Gate 2 convention; its implementation dependency is satisfied. No B redo, D/E work, schema/wire changes, UI changes, new protocol, shared request broker, or KPR-446/447/448 fixes belong here.

**Review chunks:** Chunk A is the contract plus Tasks 1–3; Chunk B is Task 4; Chunk C is Tasks 5–7. Review the complete plan and cross-chunk interfaces; each chunk is below 1,000 lines. Code blocks define the algorithms to implement, with surrounding unchanged code retained at the specified anchors. Test matrices below are additional mandatory assertions, not optional suggestions.

## Testing Contract

### Required Test Groups

- Unit: **required**.
  - Scope: `withTimeout`, named request encoding/admission, lazy speech storage, coordinator matching/lifetime.
  - Reason: timeout/cancellation and synchronous delivery races are not established by a successful end state alone.
  - Minimum assertions: winning value and immediate nil; nonpositive/already-canceled entry does not invoke body; timeout and parent cancellation finish the losing body; installed-before-send latch accepts a synchronous matching event; first-result-only behavior; weak coordinator/latch/subscription release and completion of its captured flow task; false sends do not advance fallbacks; headless operations leave speech storage nil.
- Integration: **required**.
  - Scope: fake WebSocket task → real BeekeeperSocket → real decoder → Chat handler → SwiftData/published state/decoded observers; concierge requests against the same VM; ContentView's production pairing callback binding and Team hive delivery.
  - Reason: C changes handler ordering, full-list reconciliation, cleanup, socket visibility and asynchronous ownership at B's delivery boundary.
  - Harness: **existing, extended**; use `FakeWebSocketTask`, `FakeWebSocketTaskFactory`, `FakeCredentialStore`, in-memory SwiftData and isolated UserDefaults. Add the exact helpers in Task 1.
  - Minimum assertions: all ten approved core groups, both concierge identity variants, every B test listed in Task 7, obsolete watchdog cancellation, busy/busy and no-reply re-arm, fresh list matching, normal/concierge persistence separation, reconfigure/re-pair multicast and generation behavior.
- E2E: **not-required**.
  - Scope: no new UI flow or live backend protocol is introduced.
  - Reason: existing screens remain unchanged; the business behavior is verified through production decoding, persistence and app-bound pairing callbacks in integration tests.
  - Harness: **not-applicable**; no UI test target or real server/account is needed.
  - Minimum assertions: not applicable; compile all existing UI call sites for both supported platforms.

### Critical Flows

- Streaming creates stable, scoped assistant rows; round boundaries/termination start a new row.
- Busy and offline FIFO releases one permitted head, preserving bytes, attachment-only wire text and empty-queue release gates.
- `/clear` and replacement retain names, selection, migration and queue bookkeeping without an observable missing replacement row.
- A B-owned approval cannot move A's selection/path or erase A's approval.
- Concierge resumes/discovers/spawns using new decoded replies, preserves offline cache, and cannot act after retry, auth loss or destruction.
- A watchdog queries while busy without changing status or queue eligibility; a complete server list authoritatively reconciles normal and concierge sessions.
- Every production unpair/auth origin clears both queues synchronously; ordinary hive switching retains original-hive delivery.

### Regression Surface

- All 26 `ChatViewModelSocketTests` methods, all six `PairingTeardownTests` methods, all three existing `ConciergeViewModelTests` methods, the entire `TeamViewModelTests` class, transport generation/handshake tests, busy-state/decoder/browse tests.
- Successful-fetch guard before consuming reconnect state; initial list/fallback/live-idle skip sets; failed-send head retention; migration of both release sets; queue non-rehydration.
- Optional default socket uses the injected credentials; speech sharing through `ContentView` retains instance identity; both sockets and generic Chat send are private.

### Commands

Run from the **C implementation worktree root**, not the epic worktree. The authoring worktree is `/Users/mokie/github/keepur-ios-mature-kpr443`; the delivery lane chooses its own worktree before implementing. Use new result-bundle paths for retries because Xcode refuses an existing bundle.

```bash
# Discovery already performed during drafting: Xcode 26.3 / 17C529.
xcodebuild -showdestinations -project Keepur.xcodeproj -scheme Keepur
# Available local destination: iPhone 17, iOS 26.3.1, arm64.
# UDID: ABAF19FA-8DE4-4EE1-B57E-DAA88C935FDE.
xcodebuild -resolvePackageDependencies -project Keepur.xcodeproj -scheme Keepur

# Unit + C integration + directly affected B regression, normal ad-hoc host signing.
xcodebuild test -project Keepur.xcodeproj -scheme Keepur \
  -destination 'platform=iOS Simulator,id=ABAF19FA-8DE4-4EE1-B57E-DAA88C935FDE' \
  -only-testing:KeeperTests/AsyncTimeoutTests \
  -only-testing:KeeperTests/ChatViewModelTests \
  -only-testing:KeeperTests/ConciergeViewModelTests \
  -only-testing:KeeperTests/ChatViewModelSocketTests \
  -only-testing:KeeperTests/PairingTeardownTests \
  -only-testing:KeeperTests/TeamViewModelTests \
  -only-testing:KeeperTests/BeekeeperSocketTests \
  -resultBundlePath build/kpr443-focused.xcresult

# Broad local regression: explicitly omits the 12 known KPR-446 host crashes.
xcodebuild test -project Keepur.xcodeproj -scheme Keepur \
  -destination 'platform=iOS Simulator,id=ABAF19FA-8DE4-4EE1-B57E-DAA88C935FDE' \
  -only-testing:KeeperTests -skip-testing:KeeperTests/CapabilityManagerTests \
  -resultBundlePath build/kpr443-local-regression.xcresult

# Gate 1 macOS compilation; disabling signing is allowed for this BUILD only.
xcodebuild build -project Keepur.xcodeproj -scheme Keepur \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO

# Authoritative full-suite command: GitHub's existing test.yml runner, NO skip.
# Execute on the CI runner, not this known-crashing local host.
KPR443_CI_SIM_NAME="$(xcrun simctl list devices available -j | jq -r '[.devices[][] | select(.isAvailable and (.name | startswith("iPhone")))][0].name')"
test -n "$KPR443_CI_SIM_NAME" && test "$KPR443_CI_SIM_NAME" != null
xcodebuild test -project Keepur.xcodeproj -scheme Keepur \
  -destination "platform=iOS Simulator,name=${KPR443_CI_SIM_NAME}" \
  -only-testing:KeeperTests -resultBundlePath TestResults.xcresult
```

The runner-only block spells out the existing workflow's simulator selection; leave `.github/workflows/test.yml` and its `${{ steps.sim.outputs.name }}` expression intact. Do not run the full suite locally to reproduce KPR-446. The authoritative gate is the **entire GitHub suite at C's reviewed PR head** with no `CapabilityManagerTests` exclusion, no skipped groups and normal host signing. The 238 passing CI tests / 226 local tests recorded for B are predecessor evidence, not C evidence or C's eventual expected count.

- Unit/integration expected: `** TEST SUCCEEDED **`, all selected test methods discovered, zero failures, no unexpected skips; validate the actual count from the xcresult.
- E2E command: not applicable for the reason above.
- macOS expected: `** BUILD SUCCEEDED **` and the new helper compiled into Keepur.
- Broader regression expected: successful local suite with the documented 12-test omission **and** green full GitHub suite at the reviewed C SHA. Neither can be reported as the other.

### Harness Requirements

- Real socket with fake endpoint/task and the same fake credential instance passed to VM and socket. No Keychain/audio/network dependency for new tests.
- `ModelContainer` includes `Session`, `Message`, `Workspace`; its lifetime exceeds the context/VM. Every test uses an isolated store and disconnects/unpairs at teardown.
- Unique UserDefaults suite, removed afterward; never set `.standard` concierge keys to make a test pass. VM identity registration in Tasks 2/4 handles the isolated store.
- `receive(_:)` waits for the fake receive callback to be armed, then waits for an actual decoded event. Expected frames must arrive; timeout helpers throw after recording an XCTest failure.
- Test timing uses bounded condition waits and XCTest fulfillment; yields only settle known hops. Watchdog negative assertions observe a full interval with exactly one watched session and start counting after handshake/onConnected.
- `Managers` and `KeeperTests` are already synchronized PBX groups. No project-file edit is needed: verify both Debug/Release platform configurations include `AsyncTimeout.swift`, and both platforms build its callers.

### Non-Required Rationale

- E2E: unchanged view body, no new service contract; real decoder/state/persistence and production pairing callbacks give the relevant integration evidence. Unit/integration are required.

### Verification Rules

- Missing harness is not a skip reason; set it up or report a concrete blocker.
- If a test exposes an implementation issue, fix the implementation, not the assertion.
- If testing exposes a spec/plan mismatch, return the ticket to the spec lane.
- Do not weaken signing, delete baseline tests, accept an empty selection, or hide timeouts behind non-asserting waits. Distinguish KPR-446's known local host crash from product failures. Record KPR-447/448 if observed; no unexplained failure is a clean gate.
- Record exact SHA, commands, destination, test count, failures/skips, xcresult paths and full-CI URL in delivery evidence. This draft runs no source build or test suite and makes no implementation success claim.

## Chunk A — harness, VM boundary, watchdog and reconciliation

### File map

| File | Change / sole responsibility |
|---|---|
| `Managers/AsyncTimeout.swift` | New cooperative two-child optional-result timeout helper. |
| `ViewModels/ChatViewModel.swift` | Lazy speech injection, named request methods/private transport, post-handler stream, ephemeral concierge identity, approval isolation, watchdog and full-list sync. Existing queue algorithms stay in this file. |
| `ViewModels/TeamViewModel.swift` | Change only `socket` visibility to private. |
| `Views/BeekeeperRootView.swift` | Replace the coordinator class below the unchanged view with run ownership and buffered waits. |
| `KeeperTests/FakeWebSocketTask.swift` | Optional synchronous send hook and read-only receive readiness. |
| `KeeperTests/ChatTestHarness.swift` | New reusable real-decoder/in-memory fixture and bounded test helpers. |
| `KeeperTests/AsyncTimeoutTests.swift` | New timeout/cancellation tests. |
| `KeeperTests/ChatViewModelTests.swift` | New ten-group core, ordering and watchdog tests. |
| `KeeperTests/ConciergeViewModelTests.swift` | Retain three baseline methods; add reply/matching/lifetime cases using the new harness. |
| `KeeperTests/ChatViewModelSocketTests.swift` | Keep all 26 methods; replace generic-send assertions, retain the injected socket in its existing harness. |
| `KeeperTests/PairingTeardownTests.swift`, `KeeperTests/TeamViewModelTests.swift` | Retain behavior and run unchanged tests; only fixture cleanup changes if needed to cancel work deterministically. |

### Task 1: establish deterministic transport and timeout harness

**Files:** Create `Managers/AsyncTimeout.swift`, `KeeperTests/AsyncTimeoutTests.swift`, `KeeperTests/ChatTestHarness.swift`; modify `KeeperTests/FakeWebSocketTask.swift:18-38`; verify synchronized membership in `Keepur.xcodeproj/project.pbxproj:63-103,208-236`.

- [ ] **Step 1:** Add the timeout helper exactly as follows. It is independent of networking/persistence. `group.next()` returning a body's nil is a completed result, not a reason to wait for the sleeper. A canceled group still waits for the body to finish, so callers must be cooperative. This follows the [structured task-group contract](https://developer.apple.com/documentation/swift/taskgroup); test the Combine iterator's cancellation as well as a sleep body.

```swift
import Foundation

@MainActor
func withTimeout<T: Sendable>(
    _ duration: Duration,
    _ body: @escaping @MainActor @Sendable () async -> T?
) async -> T? {
    guard duration > .zero, !Task.isCancelled else { return nil }
    let result: T? = await withTaskGroup(of: T?.self) { group in
        defer { group.cancelAll() }
        group.addTask { @MainActor in
            guard !Task.isCancelled else { return nil }
            return await body()
        }
        group.addTask {
            do { try await Task.sleep(for: duration) }
            catch { return nil }
            return nil
        }
        return await group.next() ?? nil
    }
    return Task.isCancelled ? nil : result
}
```

- [ ] **Step 2:** Add `var onSend: ((String) -> Void)?` and `var receiveRequested: Bool { receiveHandler != nil }` to `FakeWebSocketTask`. Replace only its send method body with the following. Do not change handshake, generation or delivery semantics.

```swift
if case .string(let text) = message {
    sentTexts.append(text)
    onSend?(text)
}
completionHandler(nil)
```

- [ ] **Step 3:** Add this harness. Each receive proves the real handler ran; a callback is armed before each subsequent delivery. Timeout failure must throw to stop later assertions from passing vacuously.

```swift
import XCTest
import SwiftData
import Combine
@testable import Keepur

@MainActor
func eventually(_ label: String, timeout: Duration = .seconds(1),
                file: StaticString = #filePath, line: UInt = #line,
                _ condition: () throws -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !(try condition()) {
        guard ContinuousClock.now < deadline else {
            XCTFail("Timed out: \(label)", file: file, line: line)
            throw NSError(domain: "ChatTestHarness.Timeout", code: 1)
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor
final class ChatTestHarness {
    let credentials: FakeCredentialStore
    let factory: FakeWebSocketTaskFactory
    let container: ModelContainer
    let context: ModelContext
    let socket: BeekeeperSocket
    let vm: ChatViewModel
    let suiteName: String
    let defaults: UserDefaults
    let store: ConciergeSessionStore
    var task: FakeWebSocketTask { factory.latest! }
    private(set) var received = 0
    private var observer: AnyCancellable?

    init(watchdog: Duration = .seconds(90), configure: Bool = true) throws {
        let credentials = FakeCredentialStore(), factory = FakeWebSocketTaskFactory()
        let suiteName = "ChatTestHarness.\(UUID().uuidString)"
        let container = try ModelContainer(for: Session.self, Message.self, Workspace.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let socket = BeekeeperSocket(credentials: credentials,
            endpoint: { URL(string: "wss://unit.test")! },
            taskFactory: { factory.make(url: $0) })
        let vm = ChatViewModel(socket: socket, credentials: credentials,
                              speech: nil, staleBusyTimeout: watchdog)
        self.credentials = credentials
        self.factory = factory
        self.suiteName = suiteName
        self.container = container
        self.context = context
        self.defaults = defaults
        self.store = ConciergeSessionStore(defaults: defaults)
        self.socket = socket
        self.vm = vm
        observer = vm.incoming.sink { [weak self] _ in self?.received += 1 }
        if configure { vm.configure(context: context) }
    }
    func close() {
        taskIfPresent?.onSend = nil
        vm.unpair()
        observer?.cancel()
        defaults.removePersistentDomain(forName: suiteName)
    }
    private var taskIfPresent: FakeWebSocketTask? { factory.latest }
    func connect() async throws {
        if factory.latest == nil { vm.configure(context: context) }
        try await eventually("handshake requested") { self.task.handshakeRequested }
        task.completeHandshake()
        try await eventually("connected and receive armed") {
            self.vm.connectionState == .connected && self.task.receiveRequested
        }
    }
    func receive(_ object: [String: Any]) async throws {
        try await eventually("receive callback armed") { self.task.receiveRequested }
        let before = received
        let data = try JSONSerialization.data(withJSONObject: object)
        task.deliver(String(decoding: data, as: UTF8.self))
        try await eventually("decoded frame delivered") { self.received == before + 1 }
    }
    func status(_ state: String, id: String = "a", tool: String? = nil) async throws {
        var frame: [String: Any] = ["type": "status", "state": state, "sessionId": id]
        if let tool { frame["toolName"] = tool }
        try await receive(frame)
    }
    func list(_ rows: [(String, String, String)]) async throws {
        try await receive(["type": "session_list", "sessions": rows.map {
            ["sessionId": $0.0, "path": "/\($0.0)", "state": $0.1, "mode": $0.2]
        }])
    }
    func chunk(_ text: String, id: String = "a", final: Bool = false) async throws {
        try await receive(["type": "message", "text": text, "sessionId": id, "final": final])
    }
    func approval(_ use: String, id: String? = "a") async throws {
        var frame: [String: Any] = ["type": "tool_approval", "toolUseId": use,
                                    "tool": "shell", "input": "{}"]
        if let id { frame["sessionId"] = id }
        try await receive(frame)
    }
    func messages(_ id: String? = nil, role: String? = nil) throws -> [Message] {
        try context.fetch(FetchDescriptor<Message>()).filter {
            (id == nil || $0.sessionId == id) && (role == nil || $0.role == role)
        }
    }
    func sessions() throws -> [Session] { try context.fetch(FetchDescriptor<Session>()) }
    func workspaces() throws -> [Workspace] { try context.fetch(FetchDescriptor<Workspace>()) }
    func frames(_ type: String? = nil) throws -> [[String: Any]] {
        try task.sentTexts.map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }.filter { type == nil || $0["type"] as? String == type }
    }
    @discardableResult
    func send(_ text: String, id: String = "a", attachment: AttachmentData? = nil) throws -> String {
        let old = Set(try messages().map(\.id))
        vm.currentSessionId = id
        vm.messageText = text
        vm.pendingAttachment = attachment
        vm.sendText()
        return try XCTUnwrap(messages().first { !old.contains($0.id) }?.id)
    }
}
```

Tasks 1–3 form the first compiling production increment: the harness needs Task 2's initializer/stream, and changing the watchdog timeout type requires Task 3's timer replacement. Add Task 5's associated tests, then verify and commit this increment together. Never add a mutable production transport hook.

### Task 2: inject speech, publish decoded frames, hide sockets and isolate approvals

**Files:** Modify `ViewModels/ChatViewModel.swift:58-64,109-119,178-193,227,245-256,277-312,354-371,416-444`; `ViewModels/TeamViewModel.swift:73`; `KeeperTests/ChatViewModelSocketTests.swift:121-133,377-401,747-767`.

- [ ] **Step 1:** Make both socket properties `private let socket: BeekeeperSocket`. Keep Chat's generic `send(_:)` body unchanged; defer its `private` modifier until Task 4 Step 2 migrates the existing coordinator's four callers, so the first increment compiles. Replace eager speech with the following members and initializer additions, preserving credentials and B's error timeout.

```swift
let incoming = PassthroughSubject<WSIncoming, Never>()
private var storedSpeech: SpeechManager?
private let staleBusyTimeout: Duration
private var knownConciergeSessionId: String?

var speechManager: SpeechManager {
    if let storedSpeech { return storedSpeech }
    let created = SpeechManager()
    storedSpeech = created
    return created
}

// Add these between credentials and lastErrorAutoClear in init:
// speech: SpeechManager? = nil,
// staleBusyTimeout: Duration = .seconds(90),
// Add these assignments before installing the state subscription:
// self.storedSpeech = speech
// self.staleBusyTimeout = staleBusyTimeout

@discardableResult
func listSessions() -> Bool { send(.listSessions) }
@discardableResult
func resumeSession(sessionId: String, path: String) -> Bool {
    send(.resumeSession(sessionId: sessionId, path: path))
}
@discardableResult
func newConciergeSession() -> Bool { send(.newSessionConcierge) }

/// Supplies already-known identity before a legacy resume reply is handled.
/// It is metadata, not a request, cache write, or raw transport entry point.
func registerConciergeSession(_ sessionId: String?) {
    knownConciergeSessionId = sessionId
}

private func handleFrame(_ data: Data) {
    let decoded = WSIncoming.decode(from: data)
        ?? .unknown(raw: String(decoding: data, as: UTF8.self))
    handleIncoming(decoded)
    incoming.send(decoded)
}
```

The complete initializer becomes `init(socket: BeekeeperSocket? = nil, credentials: CredentialStore = KeychainCredentialStore(), speech: SpeechManager? = nil, staleBusyTimeout: Duration = .seconds(90), lastErrorAutoClear: Duration = .seconds(6))`. Remove the old static TimeInterval watchdog constant. Keep the optional default socket constructed from the passed credentials.

- [ ] **Step 2:** Change only `speechManager.liveText = ""` in `sendText()` to `storedSpeech?.liveText = ""`. The existing `if autoReadAloud` branch may call `speechManager.speak`; all other headless paths must leave storage nil. `ContentView` and speech UI retain their explicit accessor/instance-sharing behavior.
- [ ] **Step 3:** In `.toolApproval`, delete the conditional selection assignment. Keep effective-ID resolution, unscoped deny and addressed dictionary insertion unchanged. Do not change `currentPath`. Publication from `handleFrame` still occurs after an unscoped early return.
- [ ] **Step 4:** In `.sessionInfo`, concierge detection is `mode == "concierge" || sessionId == knownConciergeSessionId || sessionId == ConciergeSessionStore.cachedSessionId`. On a concierge match, update selection/path/status, cancel that ID's watchdog, then break without Session/Workspace writes. Do **not** overwrite the registered identity just because an unrelated wire-concierge reply arrived: an active exact-ID resume must remain recognizable after a delayed old-run reply. The coordinator registers cached/discovered identity before send and authoritative identity on ready. Also cancel the watchdog after the normal branch sets status idle. Preserve the entire normal `/clear` handoff algorithm.
- [ ] **Step 5:** Before discovered **or cached** resume, Task 4 registers the already-known ID. This is necessary even with an isolated `ConciergeSessionStore`: writing that store is not visible to the static standard-defaults lookup. Do not persist a speculative discovered ID merely to classify its response. Reset the in-memory ID synchronously on unpair; clear it with a connected failed-cache timeout, not with an offline bail. Full-list wire-concierge IDs are classified directly in Task 3.
- [ ] **Step 6:** Keep all baseline methods. In `testSendIsGatedOnConnectionAndForwardsEncodedFrame`, replace its two false generic sends with `vm.listSessions()`; after handshake assert `vm.listSessions()` true and an exact `list_sessions` frame, then call `vm.cancelCurrentOperation(for: "s1")` and preserve the encoded cancel assertion. Add the resume/new-concierge shapes in Task 5.
- [ ] **Step 7:** Give the existing `QueueReleaseHarness` its own `let socket: BeekeeperSocket`, construct it before the VM, and inject/retain the same instance. Replace its three `h.vm.socket` expressions with `h.socket`. Keep the deliberate state-subscription cancellation and all rejected-head/attachment/FIFO assertions unchanged. No test reads a VM's socket after this migration.
- [ ] **Step 8:** Continue directly into Task 3 before compiling/committing: this task's Duration and helper call sites intentionally depend on its watchdog replacement. Task 3 Step 8 is the first validation/commit boundary and includes all 26 baseline Chat methods plus Task 5's new core tests. Do not commit a temporarily uncompilable midpoint.

### Task 3: replace force-idle timers and reconcile the full server list

**Files:** Modify `ViewModels/ChatViewModel.swift:90-91,151-176,277-290,331-347,416-444,490-494,556-559,704-712,760-849,850-875`; tests in `KeeperTests/ChatViewModelTests.swift` and retained B suites.

- [ ] **Step 1:** Replace `busyTimers` with the following representation/helpers. Each closure captures only the interval/ID/token strongly before its sleep. It never owns Chat across a suspension. A stale task may neither act nor remove a replacement task; a synchronous reply during `listSessions()` is also allowed to replace the timer.

```swift
private struct BusyWatch {
    let token: UUID
    let task: Task<Void, Never>
}
private var busyTimers: [String: BusyWatch] = [:]

private func isActiveBusy(_ id: String) -> Bool {
    guard let state = sessionStatuses[id] else { return false }
    return state != "idle" && state != "session_ended"
}
private func cancelBusyWatchdog(for id: String) {
    busyTimers.removeValue(forKey: id)?.task.cancel()
}
private func cancelAllBusyWatchdogs() {
    let watches = busyTimers.values
    busyTimers.removeAll()
    for watch in watches { watch.task.cancel() }
}
private func armBusyWatchdog(for id: String) {
    cancelBusyWatchdog(for: id)
    guard isAuthenticated, connectionState == .connected,
          isActiveBusy(id), staleBusyTimeout > .zero else { return }
    let token = UUID(), delay = staleBusyTimeout
    let task = Task { @MainActor [weak self] in
        do { try await Task.sleep(for: delay) } catch { return }
        guard !Task.isCancelled, let self,
              self.busyTimers[id]?.token == token,
              self.isAuthenticated, self.connectionState == .connected,
              self.isActiveBusy(id) else { return }
        self.listSessions()
        guard !Task.isCancelled, self.busyTimers[id]?.token == token else { return }
        self.armBusyWatchdog(for: id)
    }
    busyTimers[id] = BusyWatch(token: token, task: task)
}
```

- [ ] **Step 2:** Replace the entire inline watchdog block in `.status` with `if isActiveBusy(effectiveId) { armBusyWatchdog(for: effectiveId) } else { cancelBusyWatchdog(for: effectiveId) }`. Keep status/tool/round-boundary handling and the existing idle release, non-idle reclassification and `endSession` calls in their existing order. The helper never releases a queue or mutates status.
- [ ] **Step 3:** In `handleSocketState`, after B's connected setup, arm each retained active status through `armBusyWatchdog`. This only schedules a future query; keep `onConnected` as the immediate list request. At every state other than connected, call `cancelAllBusyWatchdogs()` without editing retained statuses/queues. Preserve B's release-set and fallback transitions verbatim.
- [ ] **Step 4:** In `unpair`, call `cancelAllBusyWatchdogs()` and set `knownConciergeSessionId = nil` before invoking `onUnpair`/clearing credentials. Replace every direct timer cancellation in context-cleared, end-session, delete and stale-row paths with the helper. Also clear `lastCompletedMessageIds` in `endSession` so terminated stream state cannot leak into the next response. Keep pending removal via `clearPendingMessages` even for release-only IDs.
- [ ] **Step 5:** In `.sessionReplaced`, cancel both the old and new IDs' prior watchdogs after status migration, then arm the new ID if its migrated status is active. Preserve all existing message/transient/queue/name/selection/Workspace work and both release-set migrations; no closure retaining the old ID survives. In `.sessionInfo`, cancel the relevant timer whenever the existing branch assigns idle, without awarding queue release.
- [ ] **Step 6:** Replace `.sessionList` with `serverSessions = sessions; syncSessions(serverSessions: sessions, context: context)`. Replace `syncSessions` with this complete algorithm. The full-list argument is not overwritten by the Session-table filter.

```swift
private func syncSessions(serverSessions: [ServerSession], context: ModelContext) {
    let allServerIds = Set(serverSessions.map(\.sessionId))
    var conciergeIds = Set(serverSessions.filter { $0.mode == "concierge" }.map(\.sessionId))
    if let knownConciergeSessionId { conciergeIds.insert(knownConciergeSessionId) }
    if let cached = ConciergeSessionStore.cachedSessionId { conciergeIds.insert(cached) }
    let tableRows = serverSessions.filter {
        $0.mode == "sessions" && !conciergeIds.contains($0.sessionId)
    }
    let tableIds = Set(tableRows.map(\.sessionId))
    guard let fetched = try? context.fetch(FetchDescriptor<Session>()) else { return }

    // Snapshot every release-only identity before consuming reconnect bookkeeping.
    let knownIds = Set(sessionStatuses.keys).union(pendingMessages.map(\.sessionId))
        .union(queueReleasePendingIdle).union(releasedBeforeReconnectSync)
    let isPostReconnectSync = awaitingPostReconnectSync
    let alreadyReleased = isPostReconnectSync ? releasedBeforeReconnectSync : Set<String>()
    if isPostReconnectSync {
        awaitingPostReconnectSync = false
        releasedBeforeReconnectSync.removeAll()
        postReconnectFlushFallback?.cancel()
        postReconnectFlushFallback = nil
        reclassifyOfflineAsBusy()
    }

    for row in fetched where conciergeIds.contains(row.id) { context.delete(row) }
    let localSessions = fetched.filter { !conciergeIds.contains($0.id) }
    for local in localSessions {
        let wasStale = local.isStale
        local.isStale = !tableIds.contains(local.id)
        if local.isStale && !wasStale {
            streamingMessageIds[local.id] = nil
            lastCompletedMessageIds[local.id] = nil
            sessionToolNames.removeValue(forKey: local.id)
            cancelBusyWatchdog(for: local.id)
        }
    }
    for id in knownIds where !allServerIds.contains(id) {
        if isActiveBusy(id) { endSession(id) }
        else { clearPendingMessages(for: id); cancelBusyWatchdog(for: id) }
    }
    let localIds = Set(localSessions.map(\.id))
    for server in tableRows where !localIds.contains(server.sessionId) {
        context.insert(Session(id: server.sessionId, path: server.path))
    }

    var flushed = alreadyReleased
    for server in serverSessions {
        let id = server.sessionId
        let wasBusy = isActiveBusy(id)
        if server.state == "idle" {
            sessionStatuses[id] = "idle"
            sessionToolNames.removeValue(forKey: id)
            cancelBusyWatchdog(for: id)
            if wasBusy, !flushed.contains(id), releaseQueuedHead(for: id) {
                flushed.insert(id)
            }
        } else {
            if !wasBusy { sessionStatuses[id] = server.state }
            // Preserve useful tool/thinking detail on busy → busy.
            armBusyWatchdog(for: id)
        }
    }
    try? context.save()
    if let currentSessionId,
       localSessions.first(where: { $0.id == currentSessionId })?.isStale == true {
        self.currentSessionId = nil
    }
    if isPostReconnectSync { flushOfflineQueue(skipping: flushed) }
}
```

This uses the existing coarse `idle`/`busy` server contract; do not introduce typed status fallbacks here. A normal repeated idle list cancels its watch but cannot clear `queueReleasePendingIdle` or release another head. A still-busy reply resets the watch even when preserving detailed client state. Fetch failure still returns before any reconnect-pass consumption, vestigial-row deletion or status/queue mutation.

- [ ] **Step 7:** Add the following Chat cleanup. Retain weak timer captures; do not call `unpair()` from destruction or clear credentials merely because a VM is released.

```swift
deinit {
    for watch in busyTimers.values { watch.task.cancel() }
    postReconnectFlushFallback?.cancel()
    lastErrorTimer?.cancel()
}
```

- [ ] **Step 8:** Implement Task 5's core/watchdog and timeout tests, then run the focused command's Chat/timeout/pairing/Team/transport groups (concierge is completed in Task 4). Expect only server evidence to change busy/queue state. Commit the complete verified Tasks 1–3 increment with `git add Managers/AsyncTimeout.swift ViewModels/ChatViewModel.swift ViewModels/TeamViewModel.swift KeeperTests/FakeWebSocketTask.swift KeeperTests/ChatTestHarness.swift KeeperTests/ChatViewModelSocketTests.swift KeeperTests/ChatViewModelTests.swift KeeperTests/AsyncTimeoutTests.swift` and `git commit -m "refactor: make chat core injectable and server reconciled"`.

## Chunk B — bounded concierge orchestration

### Task 4: replace polling with a buffered request-local wait and weak run ownership

**Files:** Replace only `ConciergeViewModel` and its obsolete introduction at `Views/BeekeeperRootView.swift:76-260`; leave the `BeekeeperRootView` body and cleanup function unchanged. Test in `KeeperTests/ConciergeViewModelTests.swift`.

- [ ] **Step 1:** Replace the entire coordinator class with the following. `Run` is an identity and the owner of one live reply latch, not an unbounded subscription bag. The flow task captures Run; Run's coordinator reference is weak. No instance async method holds a strong coordinator across a suspension. The relay retains the first reply even if it arrives synchronously from `send` before `.values` is iterated, as specified by [CurrentValueSubject's latest-value behavior](https://developer.apple.com/documentation/combine/currentvaluesubject). Do not forward upstream completion to the relay before its async reader starts.

```swift
/// Coordinates concierge requests using Chat's post-handler decoded stream.
@MainActor
final class ConciergeViewModel: ObservableObject {
    enum State: Equatable {
        case loading
        case ready(sessionId: String, path: String)
        case error(String)
    }
    @Published private(set) var state: State = .loading
    private(set) var bailedOffline = false
    private var hasStarted = false
    private var flowTask: Task<Void, Never>?
    private var activeRun: Run?
    private static let offlineBailMessage = "Not connected. Retry when reconnected."

    private struct Identity: Sendable {
        let sessionId: String
        let path: String
    }
    private enum Reply: Sendable {
        case info(Identity)
        case discovery(Identity?)  // .discovery(nil) is a received no-match list.
    }
    private enum WaitResult {
        case reply(Reply), timeout, offline, stopped
    }
    private final class ReplyLatch {
        let relay = CurrentValueSubject<Reply?, Never>(nil)
        var subscription: AnyCancellable?
        init(incoming: PassthroughSubject<WSIncoming, Never>,
             match: @escaping (WSIncoming) -> Reply?) {
            let relay = self.relay
            subscription = incoming.compactMap(match).prefix(1).sink { reply in
                relay.send(reply)
            }
        }
        func cancel() {
            subscription?.cancel()
            subscription = nil
            relay.send(completion: .finished)
        }
    }
    private final class Run {
        weak var owner: ConciergeViewModel?
        let viewModel: ChatViewModel
        let store: ConciergeSessionStore
        var authSubscription: AnyCancellable?
        var replyLatch: ReplyLatch?
        init(owner: ConciergeViewModel, viewModel: ChatViewModel, store: ConciergeSessionStore) {
            self.owner = owner
            self.viewModel = viewModel
            self.store = store
        }
        var isCurrent: Bool {
            !Task.isCancelled && viewModel.isAuthenticated && owner?.activeRun === self
        }
        func bailOffline() {
            guard isCurrent else { return }
            owner?.bailedOffline = true
            owner?.state = .error(ConciergeViewModel.offlineBailMessage)
        }
        func ready(_ info: Identity) {
            guard isCurrent else { return }
            viewModel.registerConciergeSession(info.sessionId)
            store.cache(sessionId: info.sessionId, path: info.path)
            owner?.state = .ready(sessionId: info.sessionId, path: info.path)
        }
        func mayContinue(after result: WaitResult) -> Bool {
            guard isCurrent else { return false }
            switch result {
            case .offline: bailOffline(); return false
            case .stopped: return false
            case .timeout, .reply: return true
            }
        }
    }

    deinit { flowTask?.cancel() }

    func start(viewModel: ChatViewModel, store: ConciergeSessionStore) {
        guard !hasStarted, viewModel.isAuthenticated else { return }
        hasStarted = true
        bailedOffline = false
        state = .loading
        let run = Run(owner: self, viewModel: viewModel, store: store)
        activeRun = run
        // Start was checked synchronously above; ignore only this initial value.
        run.authSubscription = viewModel.$isAuthenticated.dropFirst().sink { [weak self] authenticated in
            if !authenticated { self?.cancelFlow() }
        }
        flowTask = Task { @MainActor in await Self.runFlow(run) }
    }
    private func cancelFlow() {
        flowTask?.cancel()
        flowTask = nil
        activeRun?.authSubscription?.cancel()
        activeRun = nil
        hasStarted = false
    }
    private func finished(_ run: Run) {
        guard activeRun === run else { return }
        activeRun = nil
        flowTask = nil
    }
    func retry(viewModel: ChatViewModel, store: ConciergeSessionStore) {
        cancelFlow()
        start(viewModel: viewModel, store: store)
    }
    func retryIfBailedOffline(viewModel: ChatViewModel, store: ConciergeSessionStore) {
        guard bailedOffline, viewModel.connectionState == .connected else { return }
        retry(viewModel: viewModel, store: store)
    }

    private static func waitForSocketConnected(_ run: Run) async -> Bool {
        if run.viewModel.connectionState == .connected { return true }
        let result: Bool? = await withTimeout(.seconds(5)) {
            for await state in run.viewModel.$connectionState.values {
                guard !Task.isCancelled else { return nil }
                switch state {
                case .connected: return true
                case .disconnected where run.viewModel.hasRequestedConnection
                    && run.viewModel.connectionState == .disconnected: return false
                case .disconnected, .connecting, .reconnecting: continue
                }
            }
            return nil
        }
        return result == true || run.viewModel.connectionState == .connected
    }
    private static func request(
        _ run: Run, timeout: Duration,
        match: @escaping (WSIncoming) -> Reply?,
        send: () -> Bool
    ) async -> WaitResult {
        guard run.isCurrent else { return .stopped }
        let latch = ReplyLatch(incoming: run.viewModel.incoming, match: match)
        run.replyLatch = latch
        defer {
            latch.cancel()
            if run.replyLatch === latch { run.replyLatch = nil }
        }
        guard run.isCurrent else { return .stopped }
        // There is NO await between subscription installation and this request.
        guard send() else { return .offline }
        let reply = await withTimeout(timeout) {
            for await value in latch.relay.values {
                guard !Task.isCancelled else { return nil }
                if let value { return value }
            }
            return nil
        }
        guard run.isCurrent else { return .stopped }
        if let reply { return .reply(reply) }
        return run.viewModel.connectionState == .connected ? .timeout : .offline
    }
    private static func resume(_ identity: Identity, run: Run) async -> WaitResult {
        guard run.isCurrent else { return .stopped }
        // Metadata is available to the real handler BEFORE the response arrives.
        run.viewModel.registerConciergeSession(identity.sessionId)
        return await request(run, timeout: .seconds(3), match: { frame in
            guard case .sessionInfo(let id, let path, _) = frame,
                  id == identity.sessionId, !path.isEmpty else { return nil }
            return .info(Identity(sessionId: id, path: path))
        }, send: {
            run.viewModel.resumeSession(sessionId: identity.sessionId, path: identity.path)
        })
    }
    private static func runFlow(_ run: Run) async {
        defer {
            run.authSubscription?.cancel()
            run.authSubscription = nil
            run.owner?.finished(run)
        }
        guard run.isCurrent else { return }
        let connected = await waitForSocketConnected(run)
        guard run.isCurrent else { return }
        guard connected else { run.bailOffline(); return }

        if let cached = run.store.cachedSession {
            let result = await resume(Identity(sessionId: cached.sessionId, path: cached.path), run: run)
            guard run.mayContinue(after: result) else { return }
            if case .reply(.info(let info)) = result { run.ready(info); return }
            // Only a connected response timeout reaches this cache mutation.
            run.store.clear()
            run.viewModel.registerConciergeSession(nil)
        }

        let discovery = await request(run, timeout: .seconds(3), match: { frame in
            guard case .sessionList(let sessions) = frame else { return nil }
            let chosen = ConciergeSessionStore.pickConciergeSession(from: sessions)
            return .discovery(chosen.map { Identity(sessionId: $0.sessionId, path: $0.path) })
        }, send: { run.viewModel.listSessions() })
        guard run.mayContinue(after: discovery) else { return }
        if case .reply(.discovery(let match)) = discovery, let match {
            let result = await resume(match, run: run)
            guard run.mayContinue(after: result) else { return }
            if case .reply(.info(let info)) = result { run.ready(info); return }
            run.viewModel.registerConciergeSession(nil)
        }

        let spawned = await request(run, timeout: .seconds(5), match: { frame in
            guard case .sessionInfo(let id, let path, let mode) = frame,
                  mode == "concierge", !path.isEmpty else { return nil }
            return .info(Identity(sessionId: id, path: path))
        }, send: { run.viewModel.newConciergeSession() })
        guard run.mayContinue(after: spawned) else { return }
        if case .reply(.info(let info)) = spawned { run.ready(info); return }
        run.owner?.state = .error("Concierge did not respond in time")
    }
}
```

- [ ] **Step 2:** With all four coordinator callers migrated, make Chat's generic method `private func send(_ outgoing: WSOutgoing) -> Bool`; keep its body and discardable-result annotation. The compiler must accept both platform targets under the existing isolation settings. If it needs an explicit `Reply?` annotation for `withTimeout` inference, add `let reply: Reply?`; do not change protocol model Sendability or add detached tasks. `ReplyLatch`/`Run` inherit the enclosing MainActor isolation. The operation called by `withTimeout` must prove cancellation on the actual Combine `.values` iterator via Task 6's tests; a result-only check is insufficient.
- [ ] **Step 3:** Retain the existing three concierge test names and assertions, remove obsolete comments claiming their waits poll, strengthen their non-asserting `waitUntil` with `eventually`, and include `Workspace` in their in-memory schema. Explicitly tear down VMs/coordinators so tests do not leave active response waits after completion. Add Task 6's cases before declaring the rewrite complete.
- [ ] **Step 4:** Run `xcodebuild test -project Keepur.xcodeproj -scheme Keepur -destination 'platform=iOS Simulator,id=ABAF19FA-8DE4-4EE1-B57E-DAA88C935FDE' -only-testing:KeeperTests/ConciergeViewModelTests -only-testing:KeeperTests/AsyncTimeoutTests -resultBundlePath build/kpr443-concierge.xcresult`. Expect every original and new case discovered and passing. Commit with `git add Views/BeekeeperRootView.swift ViewModels/ChatViewModel.swift KeeperTests/ConciergeViewModelTests.swift KeeperTests/AsyncTimeoutTests.swift` and `git commit -m "refactor: await concierge replies with bounded ownership"`.

## Chunk C — executable behavior evidence and regression retention

### Task 5: add timeout and ten-group Chat behavior tests

**Files:** Create `KeeperTests/AsyncTimeoutTests.swift`, `KeeperTests/ChatViewModelTests.swift`; use `KeeperTests/ChatTestHarness.swift`; retain the B files listed in Task 7.

- [ ] **Step 1:** Add these timeout tests, including an outer XCTest bound that cannot hang if the helper stops cooperating. Keep the explicit loser-finished assertion; cancellation is not proven merely by receiving nil.

```swift
import XCTest
@testable import Keepur

@MainActor
final class AsyncTimeoutTests: XCTestCase {
    func testValueAndImmediateNilDoNotWaitForLongDeadline() async {
        let finished = expectation(description: "both bodies finish")
        let task = Task { @MainActor in
            let value: Int? = await withTimeout(.seconds(30)) { 7 }
            XCTAssertEqual(value, 7)
            let nilValue: Int? = await withTimeout(.seconds(30)) { nil }
            XCTAssertNil(nilValue)
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 1)
        task.cancel()
    }
    func testTimeoutAndParentCancellationFinishSuspendedBody() async throws {
        for cancelParent in [false, true] {
            let entered = expectation(description: "body entered")
            let bodyFinished = expectation(description: "loser finished")
            let returned = expectation(description: "timeout returned")
            var sawCancellation = false
            let task = Task { @MainActor in
                let result: Int? = await withTimeout(cancelParent ? .seconds(30) : .milliseconds(50)) {
                    entered.fulfill()
                    defer { bodyFinished.fulfill() }
                    do { try await Task.sleep(for: .seconds(30)) }
                    catch { sawCancellation = Task.isCancelled }
                    return nil
                }
                XCTAssertNil(result)
                returned.fulfill()
            }
            await fulfillment(of: [entered], timeout: 1)
            if cancelParent { task.cancel() }
            await fulfillment(of: [bodyFinished, returned], timeout: 1)
            task.cancel()
            XCTAssertTrue(sawCancellation)
        }
    }
    func testNonpositiveAndAlreadyCanceledEntryDoNotInvokeBody() async {
        var calls = 0
        for duration in [Duration.zero, .milliseconds(-1)] {
            let result: Int? = await withTimeout(duration) { calls += 1; return 1 }
            XCTAssertNil(result)
        }
        let returned = expectation(description: "canceled parent returned")
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            let result: Int? = await withTimeout(.seconds(30)) { calls += 1; return 1 }
            XCTAssertNil(result)
            returned.fulfill()
        }
        await fulfillment(of: [returned], timeout: 1)
        task.cancel()
        XCTAssertEqual(calls, 0)
    }
}
```

- [ ] **Step 2:** Add the following Chat test class. Helpers return fetched rows rather than inferring persistence from published state. When a test seeds several kinds of transient state, assert their presence before cleanup. The required extension matrix in Step 3 completes variants intentionally parameterized separately from these main scenarios.

```swift
import XCTest
import SwiftData
import Combine
@testable import Keepur

@MainActor
final class ChatViewModelTests: XCTestCase {
    func testStreamingAssemblySingleFinalAndRoundBoundary() async throws {
        let h = try ChatTestHarness(); defer { h.close() }; try await h.connect()
        try await h.chunk("one")
        let id = try XCTUnwrap(h.messages("a", role: "assistant").first?.id)
        try await h.chunk(" two"); try await h.chunk(" three"); try await h.chunk("!", final: true)
        let rows = try h.messages("a", role: "assistant")
        XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows.first?.id, id)
        XCTAssertEqual(rows.first?.text, "one two three!")
        try await h.chunk("single", id: "b", final: true)
        XCTAssertEqual(try h.messages("b", role: "assistant").map(\.text), ["single"])
        try await h.chunk("before", id: "c")
        let before = try XCTUnwrap(h.messages("c").first?.id)
        try await h.status("thinking", id: "c"); try await h.chunk("after", id: "c")
        let split = try h.messages("c", role: "assistant")
        XCTAssertEqual(Set(split.map(\.text)), ["before", "after"])
        XCTAssertEqual(split.count, 2); XCTAssertEqual(split.filter { $0.id == before }.count, 1)
    }
    func testBusyQueueCancelAndOtherSessionIsolation() async throws {
        let h = try ChatTestHarness(); defer { h.close() }; try await h.connect()
        try await h.list([("a", "idle", "sessions"), ("b", "idle", "sessions")])
        try await h.status("busy"); try await h.status("busy", id: "b")
        let a = try h.send("A"), tail = try h.send("A2")
        let bytes = Data([1, 2, 3])
        let b = try h.send("B", id: "b", attachment: AttachmentData(data: bytes, name: "b.bin", mimeType: "application/octet-stream"))
        XCTAssertEqual(h.vm.pendingReasons, [a: .busy, tail: .busy, b: .busy])
        XCTAssertTrue(try h.frames("message").isEmpty)
        h.vm.cancelCurrentOperation(for: "b")
        XCTAssertEqual(h.vm.pendingReasons, [a: .busy, tail: .busy])
        XCTAssertEqual(h.vm.queuedAttachmentCountForTesting, 0)
        try await h.status("idle"); XCTAssertEqual(try h.frames("message").compactMap { $0["text"] as? String }, ["A"])
        try await h.status("idle"); XCTAssertEqual(try h.frames("message").compactMap { $0["text"] as? String }, ["A", "A2"])
    }
    func testSessionEndedCleansSeededStateWithoutTouchingOtherSession() async throws {
        let h = try ChatTestHarness(watchdog: .milliseconds(50)); defer { h.close() }; try await h.connect()
        try await h.list([("a", "idle", "sessions"), ("b", "idle", "sessions")])
        try await h.status("tool_running", tool: "shell")
        try await h.chunk("old-stream"); try await h.approval("ua"); try await h.approval("ub", id: "b")
        let queued = try h.send("never", attachment: AttachmentData(data: Data([4]), name: "a.bin", mimeType: "application/octet-stream"))
        XCTAssertEqual(h.vm.pendingReasons[queued], .busy); XCTAssertEqual(h.vm.queuedAttachmentCountForTesting, 1)
        XCTAssertEqual(h.vm.sessionToolNames["a"], "shell"); XCTAssertNotNil(h.vm.pendingApprovals["a"])
        let old = try XCTUnwrap(h.messages("a", role: "assistant").first?.id)
        try await h.status("session_ended")
        XCTAssertNil(h.vm.sessionStatuses["a"]); XCTAssertNil(h.vm.sessionToolNames["a"])
        XCTAssertNil(h.vm.pendingApprovals["a"]); XCTAssertNotNil(h.vm.pendingApprovals["b"])
        XCTAssertNil(h.vm.pendingReasons[queued]); XCTAssertEqual(h.vm.queuedAttachmentCountForTesting, 0)
        let queries = try h.frames("list_sessions").count
        try await Task.sleep(for: .milliseconds(140))
        XCTAssertEqual(try h.frames("list_sessions").count, queries); XCTAssertTrue(try h.frames("message").isEmpty)
        try await h.chunk("fresh-stream")
        let rows = try h.messages("a", role: "assistant")
        XCTAssertEqual(rows.count, 2); XCTAssertNotEqual(rows.first { $0.text == "fresh-stream" }?.id, old)
    }
    func testOfflineHandshakeRequiresIdleListAndBusyListHolds() async throws {
        for busy in [false, true] {
            let h = try ChatTestHarness(); defer { h.close() }
            let a = try h.send("A"), b = try h.send("B")
            XCTAssertEqual(h.vm.pendingReasons, [a: .offline, b: .offline])
            try await h.connect(); XCTAssertTrue(try h.frames("message").isEmpty)
            try await h.list([("a", busy ? "busy" : "idle", "sessions")])
            XCTAssertEqual(try h.frames("message").count, busy ? 0 : 1)
            XCTAssertEqual(h.vm.pendingReasons[b], .busy)
            XCTAssertEqual(h.vm.pendingReasons[a], busy ? .busy : nil)
        }
    }
    func testClearHandoffKeepsOldUntilMatchingPathHasReplacementRow() async throws {
        let h = try ChatTestHarness(); defer { h.close() }; try await h.connect()
        h.context.insert(Session(id: "a", path: "/work", name: "Named")); try h.context.save()
        h.vm.currentSessionId = "a"; h.vm.currentPath = "/work"
        try await h.status("busy"); try await h.chunk("old"); try await h.approval("u")
        let pending = try h.send("queued")
        try await h.receive(["type": "context_cleared", "oldSessionId": "a", "sessionId": "a"])
        XCTAssertEqual(h.vm.currentSessionId, "a"); XCTAssertEqual(try h.sessions().map(\.id), ["a"])
        XCTAssertTrue(try h.messages("a").isEmpty); XCTAssertNil(h.vm.pendingReasons[pending])
        XCTAssertNil(h.vm.pendingApprovals["a"]); XCTAssertNil(h.vm.sessionStatuses["a"])
        try await h.receive(["type": "session_info", "sessionId": "unrelated", "path": "/elsewhere"])
        XCTAssertNotNil(try h.sessions().first { $0.id == "a" })
        var observed = false
        let observer = h.vm.incoming.sink { frame in
            if case .sessionInfo("new", "/work", _) = frame {
                observed = true
                XCTAssertEqual(h.vm.currentSessionId, "new")
                XCTAssertEqual(try? h.sessions().first { $0.id == "new" }?.name, "Named")
                XCTAssertNil(try? h.sessions().first { $0.id == "a" })
            }
        }
        defer { observer.cancel() }
        try await h.receive(["type": "session_info", "sessionId": "new", "path": "/work"])
        XCTAssertTrue(observed); XCTAssertEqual(h.vm.currentPath, "/work")
    }
    func testReplacementMigratesHistoryStreamApprovalQueueAndWatchdog() async throws {
        let h = try ChatTestHarness(watchdog: .milliseconds(50)); defer { h.close() }; try await h.connect()
        h.context.insert(Session(id: "a", path: "/work", name: "Named")); try h.context.save()
        try await h.list([("a", "idle", "sessions")])
        try await h.status("tool_running", tool: "shell"); try await h.chunk("before")
        try await h.approval("u"); let queued = try h.send("queued")
        let streamId = try XCTUnwrap(h.messages("a", role: "assistant").first?.id)
        try await h.receive(["type": "session_replaced", "oldSessionId": "a", "newSessionId": "new", "path": "/work"])
        XCTAssertEqual(h.vm.currentSessionId, "new"); XCTAssertNil(h.vm.sessionStatuses["a"])
        XCTAssertEqual(h.vm.sessionStatuses["new"], "tool_running"); XCTAssertEqual(h.vm.sessionToolNames["new"], "shell")
        XCTAssertNotNil(h.vm.pendingApprovals["new"]); XCTAssertNil(h.vm.pendingApprovals["a"])
        XCTAssertEqual(try h.sessions().map(\.id), ["new"]); XCTAssertEqual(try h.sessions().first?.name, "Named")
        let migrated = try h.messages("new"); XCTAssertFalse(migrated.isEmpty)
        XCTAssertTrue(try h.messages("a").isEmpty); XCTAssertEqual(h.vm.pendingReasons[queued], .busy)
        try await h.chunk(" after", id: "new")
        XCTAssertEqual(try h.messages("new", role: "assistant").first?.id, streamId)
        XCTAssertEqual(try h.messages("new", role: "assistant").first?.text, "before after")
        let queries = try h.frames("list_sessions").count
        try await eventually("replacement remains watched") { try h.frames("list_sessions").count > queries }
        try await h.status("idle", id: "new")
        XCTAssertEqual(try h.frames("message").compactMap { $0["sessionId"] as? String }, ["new"])
    }
    func testFullListFiltersOnlyTableAndKeepsConciergeSelection() async throws {
        for legacy in [false, true] {
            let h = try ChatTestHarness(); defer { h.close() }; try await h.connect()
            h.context.insert(Session(id: "old", path: "/old"))
            h.context.insert(Session(id: "c", path: "/c")); try h.context.save()
            if legacy { h.vm.registerConciergeSession("c") }
            h.vm.currentSessionId = "c"; h.vm.currentPath = "/c"
            try await h.status("tool_running", id: "c", tool: "shell")
            let queued = try h.send("held", id: "c")
            try await h.list([("normal", "idle", "sessions"), ("c", "busy", legacy ? "sessions" : "concierge")])
            XCTAssertEqual(h.vm.serverSessions.count, 2); XCTAssertEqual(h.vm.currentSessionId, "c")
            XCTAssertEqual(h.vm.sessionStatuses["c"], "tool_running"); XCTAssertEqual(h.vm.pendingReasons[queued], .busy)
            let rows = try h.sessions(); XCTAssertEqual(Set(rows.map(\.id)), ["old", "normal"])
            XCTAssertEqual(rows.first { $0.id == "old" }?.isStale, true)
            XCTAssertTrue(try h.workspaces().isEmpty)
            h.vm.currentSessionId = "old"
            try await h.list([("normal", "idle", "sessions"), ("c", "busy", legacy ? "sessions" : "concierge")])
            XCTAssertNil(h.vm.currentSessionId); XCTAssertTrue(try h.frames("message").isEmpty)
        }
    }
    func testErrorRoutingKeepsUnscopedBannerAndScopedBubbleSeparate() async throws {
        let h = try ChatTestHarness(); defer { h.close() }; try await h.connect()
        h.vm.currentSessionId = "a"; h.vm.currentPath = "/a"
        try await h.receive(["type": "error", "message": "unscoped"])
        XCTAssertNotNil(h.vm.lastError); XCTAssertTrue(try h.messages(role: "system").isEmpty)
        h.vm.lastError = nil
        try await h.receive(["type": "error", "message": "scoped", "sessionId": "b"])
        XCTAssertNil(h.vm.lastError); XCTAssertEqual(try h.messages("b", role: "system").map(\.text), ["Error: scoped"])
        XCTAssertEqual(h.vm.currentSessionId, "a"); XCTAssertTrue(try h.messages("a").isEmpty)
    }
    func testApprovalIsolationFallbackAndAddressedRemoval() async throws {
        let h = try ChatTestHarness(); defer { h.close() }; try await h.connect()
        h.vm.currentSessionId = "a"; h.vm.currentPath = "/a"
        try await h.approval("ua"); try await h.approval("ub", id: "b")
        XCTAssertEqual(h.vm.currentSessionId, "a"); XCTAssertEqual(h.vm.currentPath, "/a")
        XCTAssertEqual(h.vm.pendingApprovals["a"]?.id, "ua"); XCTAssertEqual(h.vm.pendingApprovals["b"]?.id, "ub")
        h.vm.approve(toolUseId: "ub", sessionId: "b")
        XCTAssertNil(h.vm.pendingApprovals["b"]); XCTAssertNotNil(h.vm.pendingApprovals["a"])
        try await h.approval("fallback", id: nil); XCTAssertEqual(h.vm.pendingApprovals["a"]?.id, "fallback")
        h.vm.deny(toolUseId: "fallback", sessionId: "a"); XCTAssertTrue(h.vm.pendingApprovals.isEmpty)
        h.vm.currentSessionId = nil
        let before = try h.frames("deny").count
        try await h.approval("unscoped", id: nil)
        XCTAssertEqual(try h.frames("deny").count, before + 1); XCTAssertTrue(h.vm.pendingApprovals.isEmpty)
        XCTAssertEqual(try h.frames("deny").last?["toolUseId"] as? String, "unscoped")
    }
    func testWatchdogQueriesRearmsAndOnlyIdleReplyReleases() async throws {
        let h = try ChatTestHarness(watchdog: .milliseconds(50)); defer { h.close() }; try await h.connect()
        h.vm.registerConciergeSession("c")
        try await h.list([("c", "idle", "concierge")])
        try await h.status("tool_running", id: "c", tool: "shell"); try await h.approval("u", id: "c")
        let a = try h.send("A", id: "c"), b = try h.send("B", id: "c")
        let initial = try h.frames("list_sessions").count
        try await eventually("first watchdog query") { try h.frames("list_sessions").count > initial }
        XCTAssertEqual(h.vm.sessionStatuses["c"], "tool_running"); XCTAssertEqual(h.vm.sessionToolNames["c"], "shell")
        XCTAssertNotNil(h.vm.pendingApprovals["c"]); XCTAssertEqual(h.vm.pendingReasons, [a: .busy, b: .busy])
        XCTAssertTrue(try h.frames("message").isEmpty)
        let first = try h.frames("list_sessions").count
        try await eventually("no-reply watch remains armed") { try h.frames("list_sessions").count > first }
        try await h.list([("c", "busy", "concierge")])
        let reset = try h.frames("list_sessions").count
        XCTAssertEqual(h.vm.sessionStatuses["c"], "tool_running")
        try await eventually("busy reply rearms") { try h.frames("list_sessions").count > reset }
        try await h.list([("c", "idle", "concierge")])
        XCTAssertEqual(h.vm.sessionStatuses["c"], "idle"); XCTAssertNil(h.vm.sessionToolNames["c"])
        XCTAssertEqual(try h.frames("message").compactMap { $0["text"] as? String }, ["A"])
        XCTAssertEqual(h.vm.pendingReasons, [b: .busy])
        try await h.list([("c", "idle", "concierge")])
        let idleQueries = try h.frames("list_sessions").count
        try await Task.sleep(for: .milliseconds(140))
        XCTAssertEqual(try h.frames("list_sessions").count, idleQueries)
        XCTAssertEqual(try h.frames("message").count, 1)
    }
}
```

- [ ] **Step 3:** Implement these additional named tests using the same harness; every sequence and expected outcome is mandatory. They cover the remaining branches that the ten main scenarios do not establish.

| Test name in `ChatViewModelTests` | Input sequence and exact required assertions |
|---|---|
| `testDecodedMulticastReadsPostHandlerStateOncePerFrame` | Attach two synchronous `incoming.sink` observers before frames. Send `session_info` for normal N, an explicit B approval with A selected, then a full list containing normal N and concierge C. Inside **each** callback verify selection/path and persisted N; unchanged A selection plus B approval; full list/status map and no C Session row. Each sees each frame exactly once in the same order. Deliver an unknown raw dictionary; each sees `.unknown` once and a persisted unknown-role row is already visible. |
| `testReconfigureAndRepairKeepOneDecodedPublication` | Configure twice with the same context, handshake, deliver a status, assert each observer fires once. Save old fake delivery callback, unpair, restore fake credentials/auth flag, configure/connect again, invoke saved old callback (no decoded event), then deliver on latest fake (one event). Keep the same `incoming` subject/observer throughout. |
| `testNamedRequestsAndHeadlessSpeechStorage` | Start unconfigured: all three named requests return false, stored speech reflected as `Optional<SpeechManager>.none`. Configure while handshaking: still false and no outgoing frames. After handshake record count and assert true requests encode exactly `{type:list_sessions}`, `{type:resume_session,sessionId:c,path:/c}`, `{type:new_session,mode:concierge}`, with no additional keys. Drive sends/chunks/final/status/approval/list with `autoReadAloud == false`; storage stays nil without touching the getter. A separately injected `SpeechManager` is returned identically (`===`) and its liveText is cleared on send; do not invoke audio permission APIs. |
| `testWatchdogAbsenceUsesTerminationCleanup` | Parameterize normal/concierge. Seed detailed busy status/tool, stream ID via chunk, approval, queued text+attachment and an unrelated idle session. Send a full list omitting only the busy ID. Assert status/tool/approval/reasons/queued bytes removed, other session intact, no message sent, no timer query after >2 intervals, and later chunk gets a distinct row ID. |
| `testWatchdogCancelsOnIdleClearDisconnectAndUnpair` | One active watched ID per fresh fixture, 150 ms duration to allow actions before expiry. Parameterize explicit idle, `context_cleared`, `clearSession`, `session_cleared`, disconnect and unpair. Seed a row/stream/approval/queue first where appropriate; record list count after the action, observe 350 ms and assert unchanged. Disconnect retains busy/queue; unpair removes queue bytes and both release sets. Reconnect the disconnected case: `onConnected` sends its immediate list, then absence of a reply still yields a watchdog query. |
| `testReplacementOldWatchCannotReapOrQueryNewLifecycle` | 150 ms watch; busy old ID, replace it before expiry, then set new ID idle before either deadline. After 350 ms there are no new list queries or messages. Then set reused old ID busy and subsequently idle; old canceled generation cannot act on the reused ID. Separately keep new ID busy and assert a query occurs (main replacement case already pins migration). |
| `testBusyReplyResetsDeadlineAndMaintainsOneWatch` | 200 ms watch; seed one busy ID, wait 120 ms, deliver still-busy reply and record query count. After another 120 ms count is unchanged (old deadline was canceled); within a further 250 ms one query arrives. Deliver consecutive busy statuses/list updates, then idle and observe >2 intervals without another query. No message or reason mutation occurs during timer-only actions. |
| `testCachedLegacyResumeNeverCreatesWorkspaceHistory` | Register the cached ID from an isolated store before legacy missing-mode `session_info`; assert both selection/path and zero Session/Workspace rows in the decoded callback. Task 6 additionally proves real coordinator registration rather than directly seeding this method. |

Read-only reflection for `storedSpeech` is already established by B's private state-subscription inspection pattern: `Mirror(reflecting: h.vm).descendant("storedSpeech") as? Optional<SpeechManager>`, then unwrap the outer cast and assert its inner value nil. Reflection must fail loudly if the field disappears; never substitute reading `speechManager`, which constructs it.

- [ ] **Step 4:** Review the fetch-failure early return structurally: the `context.fetch` guard must precede all reconnect flag/fallback/release and SwiftData deletions. Do not add a production fetch override or D's persistence abstraction to manufacture this failure. Preserve B's fallback tests and record this guard audit alongside runtime evidence.
- [ ] **Step 5:** Run the focused command from the Testing Contract; confirm every new method is discovered in xcresult. Use the commit boundaries from Tasks 2–4 after their associated tests exist and pass.

### Task 6: prove concierge freshness, synchronous buffering and actual destruction

**Files:** Extend `KeeperTests/ConciergeViewModelTests.swift`; read-only lifetime probe helpers may live in `KeeperTests/ChatTestHarness.swift`. New tests run the actual coordinator and use raw transport frames except the one explicit synchronous-decoded latch test.

- [ ] **Step 1:** Add the following read-only probe helpers. They unwrap private reference storage rather than exporting a mutable test API. Weakly retaining the actual subscription token proves it is disposed; checking `state == .ready` or nil owner alone is insufficient. Keep field names synchronized with Task 4 and let a missing field fail the test.

```swift
@MainActor
final class WeakReference {
    weak var value: AnyObject?
    init(_ value: AnyObject) { self.value = value }
}
@MainActor
func reflectedObject(_ root: Any, _ name: String) throws -> AnyObject {
    let field = try XCTUnwrap(Mirror(reflecting: root).descendant(name))
    let mirror = Mirror(reflecting: field)
    let value: Any = mirror.displayStyle == .optional
        ? try XCTUnwrap(mirror.children.first?.value) : field
    XCTAssertEqual(Mirror(reflecting: value).displayStyle, .class)
    return value as AnyObject
}
@MainActor
struct ConciergeFlowProbe {
    let task: Task<Void, Never>
    let run: WeakReference
    let latch: WeakReference
    let subscription: WeakReference
    init(_ coordinator: ConciergeViewModel) throws {
        let stored = try XCTUnwrap(Mirror(reflecting: coordinator).descendant("flowTask") as? Optional<Task<Void, Never>>)
        task = try XCTUnwrap(stored)
        let run = try reflectedObject(coordinator, "activeRun")
        let latch = try reflectedObject(run, "replyLatch")
        let subscription = try reflectedObject(latch, "subscription")
        self.run = WeakReference(run)
        self.latch = WeakReference(latch)
        self.subscription = WeakReference(subscription)
    }
}
```

- [ ] **Step 2:** Add these two independent seam tests. The direct-incoming send callback is confined to the second test; it cannot establish raw decoder ordering and does not replace Task 5's raw-frame observer test.

```swift
func testDroppingCoordinatorDuringSuspendedReplyCancelsOwnedWork() async throws {
    let h = try ChatTestHarness(); defer { h.close() }; try await h.connect()
    h.store.cache(sessionId: "cached", path: "/cached")
    var coordinator: ConciergeViewModel? = ConciergeViewModel()
    weak var weakCoordinator = coordinator
    coordinator?.start(viewModel: h.vm, store: h.store)
    try await eventually("resume sent with suspended reply wait") { try h.frames("resume_session").count == 1 }
    let probe = try ConciergeFlowProbe(XCTUnwrap(coordinator))
    XCTAssertNotNil(probe.run.value); XCTAssertNotNil(probe.latch.value); XCTAssertNotNil(probe.subscription.value)
    let completed = expectation(description: "canceled flow actually finishes")
    let observer = Task { @MainActor in await probe.task.value; completed.fulfill() }
    defer { observer.cancel() }
    coordinator = nil
    XCTAssertNil(weakCoordinator, "the flow must not retain its owning coordinator")
    await fulfillment(of: [completed], timeout: 1)
    try await eventually("request-local objects released") {
        probe.run.value == nil && probe.latch.value == nil && probe.subscription.value == nil
    }
    let count = try h.frames().count
    try await h.receive(["type": "session_info", "sessionId": "cached", "path": "/late", "mode": "concierge"])
    XCTAssertEqual(h.store.cachedSession?.path, "/cached")
    XCTAssertEqual(try h.frames().count, count, "late reply cannot send a fallback")
}

func testSynchronousDecodedReplyInsideSendIsBufferedAndFirstOnly() async throws {
    let h = try ChatTestHarness(); defer { h.close() }; try await h.connect()
    h.store.cache(sessionId: "cached", path: "/cached")
    let coordinator = ConciergeViewModel()
    var invoked = false
    h.task.onSend = { text in
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              object["type"] as? String == "resume_session" else { return }
        invoked = true
        h.vm.incoming.send(.sessionInfo(sessionId: "other", path: "/other", mode: "sessions"))
        h.vm.incoming.send(.sessionInfo(sessionId: "cached", path: "/first", mode: "sessions"))
        h.vm.incoming.send(.sessionInfo(sessionId: "cached", path: "/second", mode: "concierge"))
    }
    coordinator.start(viewModel: h.vm, store: h.store)
    try await eventually("synchronous reply consumed") { coordinator.state == .ready(sessionId: "cached", path: "/first") }
    XCTAssertTrue(invoked); XCTAssertEqual(h.store.cachedSession?.path, "/first")
    XCTAssertEqual(try h.frames("resume_session").count, 1)
    XCTAssertTrue(try h.frames("new_session").isEmpty)
}
```

- [ ] **Step 3:** Implement this complete request/exit-path matrix as additional named methods in the existing `ConciergeViewModelTests` class. Use `eventually` with the stated generous outer bounds; production stage budgets remain 3/3/3/5 seconds and connection budget 5 seconds. Do not introduce a timeout injection solely to make these tests shorter. Save a `ConciergeFlowProbe` immediately after the corresponding request is recorded and before replying; after each exit assert weak latch/subscription disposal and observe `probe.task.value` finishing (when the whole flow exits). During a multi-stage transition only the old latch/subscription must release; the run remains active.

| Test | Exact setup, stimuli and required outcomes |
|---|---|
| `testCachedLegacyResumeUpdatesCacheWithoutSessionOrWorkspaceRows` | Isolated store caches C at `/old`; connect, start, wait for `resume_session(C,/old)`. Deliver through `h.receive` a **missing-mode** `session_info(C,/actual)`. An `incoming` subscriber reads selection/path `/actual` and empty Session/Workspace tables before ready. Coordinator becomes ready C `/actual`, cache changes to authoritative path, no spawn. Standard defaults remain untouched. |
| `testDiscoveryRegistersIdentityBeforeLegacyResumeHandler` | Empty isolated store; connect/start; ignore the pre-start onConnected list (record count). Wait for coordinator's new list request, deliver `[normal N, concierge C]`; wait for exact resume C. Assert the store is still empty before the reply (no speculative cache write). Deliver missing-mode `session_info(C,/actual)`. In the raw decoded callback assert no C Session/Workspace and correct selection/path; then assert ready/cache C. This explicitly proves advisory 1 with the **actual** coordinator. |
| `testEmptyFreshListImmediatelySpawnsAndFiltersNormalInfo` | Seed `vm.serverSessions` by a pre-start real concierge list then start with empty store. No resume occurs from that old snapshot. Only a **new** empty list advances discovery; within 1 second one `new_session` `{mode:concierge}` is sent. Deliver normal N info and empty-path concierge info: coordinator remains loading, cache empty. Deliver concierge C info: ready/cache C. A repeated known ID with valid concierge mode is also accepted on a fresh-spawn test. |
| `testRawReplyDeliveredByFakeSendHookSeesHandlerBeforeReady` | In fake `onSend`, when resume is recorded, deliver its JSON reply through `task.deliver` (the normal socket actor hop remains). Synchronous decoded observers see VM selection/path/table effects; ready/cache then match. This is separate from the synchronous direct-subject seam. |
| `testConnectedCachedResumeTimeoutFallsThroughOnce` | Cache old C, connect/start, hold the response beyond 3 seconds; within 4.5 seconds cache is cleared and exactly one additional list is recorded. Reply with a concierge D list, then matching D info; ready D, one resume per attempted identity, no spawn. Save the old latch probe and prove it releases at the stage transition. |
| `testConnectedDiscoveredResumeTimeoutSpawnsOnce` | New list discovers C; withhold resume C reply for 3 seconds; within 4.5 seconds exactly one fresh spawn is recorded. Reply with mode concierge D; ready D. A late exact C reply cannot overwrite coordinator/cache D. |
| `testDiscoveryTimeoutAndSpawnTimeoutKeepExistingError` | Empty store; withhold fresh list. Within 4.5 seconds spawn occurs once. Withhold spawn reply; within a further 6.5 seconds state is exactly `.error("Concierge did not respond in time")`. No retry loop or duplicate spawn; old latch/subscription/run release. |
| `testFreshSpawnIgnoresLegacyModeWithoutKnownIdentity` | Empty fresh list triggers spawn. Deliver a missing-mode info for an arbitrary ID and a scoped/unscoped error; none completes spawn. Within 6.5 seconds existing timeout copy appears. Chat retains its existing error routing; coordinator invents no correlation. |
| `testRejectedResumeBailsOfflineAndRetainsCache` | Connect, then cancel only Chat's state subscription with B's read-only reflection technique and call retained `h.socket.disconnect()`. VM published state remains connected while socket rejects sends. Start cached coordinator: named resume returns false; state becomes existing offline error, cache unchanged, no discovery/spawn emitted. Assert activeRun/flowTask clear after the asynchronous flow exits. No mutable production bypass. |
| `testDisconnectDuringResumeTimeoutKeepsCacheAndDoesNotSpawn` | Normal connected cached resume begins; disconnect before any response and leave disconnected. Within 4.5 seconds existing offline bail is set, cache unchanged, no new list/spawn from the old run. Reconnect and call `retryIfBailedOffline` twice: exactly one replacement cached resume. Complete it and verify a later retry-if-bailed is a no-op. |
| `testExplicitRetryDisposesOldWaitAndRejectsOldIdentity` | Start cached C and capture old probe. Change isolated cache to D, call retry (cancel/invalidate C first), wait for D resume. Assert C latch/subscription/run/task release within 1 second. Deliver late C info; coordinator stays loading and cache D is unchanged. Deliver D missing-mode info; ready D, no D Session/Workspace rows. One outgoing C resume and one D resume; no old fallback after >3 seconds. |
| `testAuthLossThenRepairCannotReviveOldRun` | Start cached C; capture probe; call actual `h.vm.unpair()` (auth observer cancels synchronously). Restore fake credentials and `isAuthenticated`, cache D, configure/reconnect and start/retry the same coordinator. Complete a fresh D run and emit old C info afterward; only D ready/cache remains. Captured old run/task/latch/subscription release; no old-run spawn/cache clear. Preserve VM/transport old-generation rejection separately. |
| `testStartBeforeConfigureWaitsThroughColdDisconnected` | Construct harness with `configure:false`, cached C, start coordinator first; for 100 ms no error and no request. Configure after start, handshake, assert one resume C and complete it. Initial `.disconnected` was not terminal. |
| `testConnectionTimeoutBailsAndPreservesCache` | Configure but never complete handshake (or retain reconnecting through the 5-second budget without hitting auth failure). Start cached C. Within 6.5 seconds existing offline bail, original cache, zero coordinator resume/spawn; no cancellation leak. The live reread semantics are retained in the implementation, and the baseline cold-start tests remain. |

- [ ] **Step 4:** In the success, timeout, explicit retry, auth-loss and owner-destruction cases, inspect both subscription/latch weak references and flow completion. Failed-send creates/disposes its latch without suspension, so assert the private run/task have cleared and a weak coordinator drops immediately afterward; the source's unconditional defer covers that synchronous path. Any leaked `.values` child is a product issue to fix, not a reason to increase every timeout or drop the assertion.
- [ ] **Step 5:** Verify the production source has no 50 ms session polling, no coordinator generic send and no Task capturing a strong coordinator across an await. Run Task 4's command and then the complete focused command.

### Task 7: preserve predecessor assertions and collect final gate evidence

**Files:** `KeeperTests/ChatViewModelSocketTests.swift`, `KeeperTests/PairingTeardownTests.swift`, `KeeperTests/ConciergeViewModelTests.swift`, `KeeperTests/TeamViewModelTests.swift`, `.github/workflows/test.yml`, all changed source/test files.

- [ ] **Step 1:** Preserve this one-to-one baseline coverage map. No baseline method moves to a different file/class in this plan; new C methods are additive. If implementation consolidates a fixture, retain each named method and its assertions so there is no ambiguous replacement mapping.

| Existing test in `ChatViewModelSocketTests.swift` | Must remain covered at the same method |
|---|---|
| `testConfigureConnectsOnBeekeeperChannelAndListsSessionsAfterHandshake` | Injected channel, empty pre-handshake sends, ping then onConnected list. |
| `testInboundFrameIsDecodedAndDispatchedToHandleIncoming` | Real transport/decoder status dispatch. |
| `testSendIsGatedOnConnectionAndForwardsEncodedFrame` | False before/while connecting, true named request after handshake, encoded cancel retained. |
| `testCloseCode4001UnpairsAndClearsCredentials` | Auth failure and credential clear. |
| `testSendWhileConnectingQueuesOfflineAndFlushesAfterSessionList` | Handshake does not itself flush; first idle list does. |
| `testReconnectFallbackFlushesOneHeadPerIdleSessionAndLateListDoesNotFlushAgain` | One pass/head, cached busy gate, late-list no duplicate. |
| `testConnectionLossCancelsReconnectFallbackAndPreservesOfflineQueue` | Old fallback cancellation and retained queue. |
| `testOfflineEntryReclassifiedBusyWhenServerBusy` | Reason change with no send. |
| `testAttachmentOnlyOfflineSendEmitsNoTextFrame` | Exact bytes and absent invented text. |
| `testErrorWithNilSessionIdSetsLastErrorNotBubble` | Banner/scoped errors, active browse inline and rejected-browse-send guard. |
| `testAbsentBusySessionGetsSessionEndedCleanup` | Full-ID absence and cleanup. |
| `testUnpairClearsOfflineQueue` | Queue and retained attachment reset. |
| `testSendAfterReconnectHandshakeJoinsEarlierOfflineEntries` | Both older busy/offline variants, per-session FIFO. |
| `testReconnectBacklogDoesNotBlockUnrelatedSession` | Independent idle session direct send. |
| `testAttachmentEntryCannotBeOvertakenDuringReconnect` | Text/file/image ordering, bytes, attachment-only variant. |
| `testNewSendWaitsForIdleAfterQueueHeadEmptiesQueue` | Release gate outlives an emptied queue. |
| `testBusyReconnectListHoldsBothNewAndEarlierEntries` | Busy server result holds every queued entry. |
| `testLiveBusyBeforeListReclassifiesOnlyItsSession` | Scoped reclassification. |
| `testEarlyIdleReleaseIsNotRepeatedByInitialSync` | Early live-idle skip set and one pass. |
| `testEarlyIdleReleaseIsNotRepeatedByFallback` | Fallback uses same already-released skip. |
| `testSendAfterHandshakeWaitsForFallbackAndLateListDoesNotDoubleFlush` | Post-handshake admission and late-list no double flush. |
| `testSessionReplacementMigratesReleaseAndInitialSyncSkip` | Both release sets, with queued tail and emptied queue variants. |
| `testSessionCleanupRemovesReleaseOnlyAndQueuedBookkeeping` | Every existing clear/cancel/end/absence origin, with and without tail. |
| `testDisconnectClearsReleaseGateAndCancelsEarlierFallback` | New connection receives fresh gate/fallback ownership. |
| `testRejectedDirectSendKeepsAttachmentAheadOfLaterSubmission` | Retained injected socket fault, rejected attachment head/bytes/reason/FIFO. |
| `testOrdinaryBusyToIdleSyncReleasesHeldQueueHead` | Ordinary status reconciliation releases one; repeated idle does not. |

| Existing file/class | Retention mapping |
|---|---|
| `PairingTeardownTests.swift` | Keep `testManualUnpairClearsBothVMsBeforeReturning`, `testChat4001ClearsBothVMs`, `testCapabilityUnauthorizedClearsBothVMsBeforeReturning`, `testTeam4001ClearsBothVMsWithoutCallbackCycle`, `testUnboundTeam4001ReleasesAttachmentsAndMappingsIdempotently`, `testOrdinaryAndDirectHiveSwitchPreserveQueuedAttachment`. Retain shared lifecycle's same-instance re-pair/fresh sends, retained-byte/mapping checks, synchronous origins and idempotency. |
| `ConciergeViewModelTests.swift` | Keep `testRunFlowWaitsForHandshakeBeforeCacheHitResume`, `testRunFlowBailsWithoutClearingCacheWhenDisconnected`, `testBailedFlowRerunsOnConnected`; only strengthen waits/fixtures and add tests. |
| `TeamViewModelTests.swift` | Keep every method: dynamic device credentials, observable connection/retry, offline slash errors, incoming error/auto-clear, never-sent/unacked resend, original-hive isolation/return, auth reset. Team's only production edit is socket visibility. |
| `BeekeeperSocketTests.swift`, `ChatResilienceTests.swift` and remaining `KeeperTests` | Keep all tests and run the affected groups plus broad suite. KPR-448 timing failure, if observed, requires recorded baseline classification; it is not an excuse to delete or silently skip the method. |

- [ ] **Step 2:** Run these static checks from the C implementation root. Inspect matches; constructor assignments `self.socket = ...` inside VMs and harness `h.socket` are valid. There must be no external `vm.socket`, `viewModel.socket`, `chat.socket` or `team.socket` access, and no coordinator `viewModel.send` or production force-idle timeout closure.

```bash
git diff --check
rg -n '\.(socket|send)\b' Views ViewModels KeeperTests --glob '*.swift'
rg -n 'private let socket|private func send|let incoming|storedSpeech|staleBusyTimeout|busyTimers' ViewModels/ChatViewModel.swift ViewModels/TeamViewModel.swift
rg -n 'milliseconds\(50\)|waitForSessionInfo|waitForConciergeInList|Task \{|runFlow|replyLatch' Views/BeekeeperRootView.swift
rg -n '^    func test' KeeperTests/ChatViewModelSocketTests.swift KeeperTests/PairingTeardownTests.swift KeeperTests/ConciergeViewModelTests.swift KeeperTests/ChatViewModelTests.swift KeeperTests/AsyncTimeoutTests.swift
```

- [ ] **Step 3:** Run the complete focused suite, then the broad local regression with the **explicit** CapabilityManager exclusion, and the macOS build from the Testing Contract. Do not disable signing on iOS tests. Read xcresults to verify real test discovery/counts and failure details:

```bash
xcrun xcresulttool get test-results summary --path build/kpr443-focused.xcresult
xcrun xcresulttool get test-results summary --path build/kpr443-local-regression.xcresult
git rev-parse HEAD
git diff --stat
```

- [ ] **Step 4:** Before the normal child-PR delivery gate is declared green, require the existing GitHub `Unit tests (iOS Simulator)` job at the current reviewed C head, running **all** `KeeperTests` with zero exclusions. Capture run URL, head SHA, test count and conclusion; an earlier B run or C run before the last change is insufficient. PM/PR creation/review/merge are owned by the delivery/orchestration lane, not this plan writer; no new workflow or approval bypass is needed.
- [ ] **Step 5:** Review actual changed persistence sites for downstream D (full-list sync, metadata-only concierge registration, lazy speech, cancellation and pairing callbacks) and note E's unchanged history/hive obligations in the implementation handoff. Do not implement them here. Commit remaining verified test additions with explicit paths, e.g. `git add KeeperTests/ChatViewModelTests.swift KeeperTests/ConciergeViewModelTests.swift KeeperTests/AsyncTimeoutTests.swift KeeperTests/ChatTestHarness.swift` and `git commit -m "test: cover chat state and concierge lifecycle"`.

## Assumptions and review handoff

- Metadata-only `registerConciergeSession(_:)` is the minimal refinement needed by the approved legacy-ID advisory. It adds no outgoing wire operation, constructor dependency, persistent cache format, or mutable transport seam; only the coordinator supplies cached/discovered/ready identity.
- The shared subject is observation-only in production; direct `.send` from a test is confined to the expressly requested synchronous latch seam. All core state and persistence assertions use fake transport → real decoder.
- The full-list server states remain `idle`/`busy`; new typed policies belong to D. Concurrent list requests and delayed matching replies have no protocol correlation; these tests promise only fresh matching events within the current run.
- Existing fixture-level reflection is extended only for read-only lifetime/speech observations and the already-approved rejected-send state-subscription fault. No runtime test flags or public socket access are introduced.
- Source/destination discovery was performed on the named baseline. No C source files were edited, built or tested by this draft. The next action is an independent plan review; this document does not self-approve or authorize implementation.
