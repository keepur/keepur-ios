# KPR-442 — Connection Truth, Banner, Offline Send Queue Implementation Plan

> **For agentic workers:** Use dodi-dev:implement to execute this plan.

**Ticket:** [KPR-442](https://linear.app/keepur/issue/KPR-442) (child B of epic KPR-441). **Spec:** `docs/specs/2026-09-07-kpr-442-connection-truth-design.md` (source of truth; section numbers below refer to it). Epic context: `docs/specs/2026-09-04-cleanup-epic-design.md` § Child B.
**Worktree:** `/Users/mokie/github/keepur-ios-mature-kpr-442`, branch `mature-kpr-442` (the implementer's child worktree/branch will differ — substitute), base `epic-kpr-441`.

**Goal:** Make connection state observable and truthful in both view models and every view, surface server errors and offline actions through one `lastError` → `KeepurConnectionBanner` path, stop silently dropping sends by queueing them per reason (Beekeeper) and per hive (Team) and re-sending on reconnect, and land the five carried-in transport/concierge fixes from child A's review — all with the spec's ~24-case test contract.

**Architecture:** Both `ChatViewModel` and `TeamViewModel` subscribe to `socket.$state` in `init` and republish it as `@Published connectionState`, plus a `@Published lastError` that auto-clears; views read only those two (never `viewModel.socket`). The Beekeeper queue becomes `[PendingMessage]` + `pendingReasons: [id: .busy | .offline]`, flushed exactly once per reconnect after the post-reconnect `session_list` (5 s fallback) — never from inside the `$state` sink, because Combine publishes on `willSet` and the socket's send gate still reads the old state there. The Team queue is an ordered, hive-stamped `[OfflineEntry]` re-sent at the end of `onConnected()` for the hive just connected. The banner is a token-only `Theme/Components` view taking a `Presentation?`; the socket-state → `Presentation` mapping is a `Views/`-side extension.

**Tech Stack:** Swift 5 mode (app target default isolation MainActor), SwiftUI, Combine (`@Published`, `.values`), SwiftData, `os.Logger`, XCTest with the child-A fakes (`FakeWebSocketTask`, `FakeWebSocketTaskFactory`, `FakeCredentialStore`). iOS 26.2 / macOS 15 targets; both must keep building.

## Working constraints (read first)

- **Local Xcode 26.3 is available** (unlike child A). Run tests locally; CI (`Tests` workflow on PRs to `epic-*`) is authoritative.
- **Test run command** (from the worktree root; iPhone 17 Pro is installed):
  ```bash
  xcodebuild test -project Keepur.xcodeproj -scheme Keepur \
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:KeeperTests \
    -derivedDataPath /tmp/keepur-dd 2>&1 | grep -E "error:|failed|Executed [0-9]+ tests, with|TEST (SUCCEEDED|FAILED)"
  ```
  Add `-only-testing:KeeperTests/<Class>` for a focused run. `CapabilityManagerTests` intermittently crashes the test host on this machine (`malloc: pointer being freed was not allocated` in `CapabilityManager()` init — known, #101); if it bites, add `-skip-testing:KeeperTests/CapabilityManagerTests` and expect 12 fewer tests. Never run the iOS and macOS `xcodebuild`s concurrently (simulator `Busy` errors, SourcePackages collisions).
- **macOS build check:**
  ```bash
  xcodebuild build -project Keepur.xcodeproj -scheme Keepur -destination 'platform=macOS' \
    CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/keepur-dd-mac 2>&1 | grep -E "warning:|error:|BUILD (SUCCEEDED|FAILED)"
  ```
- **Test count today: 192.** This plan adds 24 (`KeepurConnectionBannerTests` 6, `TeamViewModelTests` +7 net of one replacement, `ChatViewModelSocketTests` +6, `BeekeeperSocketTests` +3, `ConciergeViewModelTests` +2) → the final full run must print `Executed 216 tests, with 0 failures` (204 with `CapabilityManagerTests` skipped).
- `MemberImportVisibility` is on: any file that calls `Log.x.…` must `import os` itself. Every file this plan touches that logs already does; new files do not log.
- Zsh is the shell: quote globs (`--include='*.swift'`) or grep directories by name as the commands below do.
- Commit after each task with the message given. Do not push mid-task; the dispatcher owns the PR lifecycle.

## Testing Contract

### Required Test Groups

- Unit: `required`
  - Scope: (1) `KeepurConnectionBanner.Presentation.make(state:error:)` mapping + component smoke; (2) `TeamViewModel` offline queue (queue while connecting, un-acked → offline on loss, hive-scoped re-send, auth-failure clear), `connectionState` forwarding, `lastError` from slash-command-offline / `error` frame / auto-clear; (3) `ChatViewModel` offline queue (queue while connecting → flush after `session_list`, reclassify to `.busy` when server busy, attachment-only send emits no text frame, `.error` nil-session → `lastError`, absent-id `session_ended` cleanup, `unpair` clears); (4) `BeekeeperSocket` carried-in fixes (bail resets attempts, `reconnect()` no-op after `disconnect()`, close codes); (5) `ConciergeViewModel` offline bail without cache wipe + re-run on `.connected`; (6) `TeamMessageBubble(isOffline:)` smoke.
  - Reason: every behavior above is otherwise observable only against a live server with a flaky link; the child-A fakes make them deterministic.
  - Minimum assertions: the cases numbered 1–20 in the spec's *Testing contract* (§ Testing contract), reproduced verbatim as the tests in Tasks 1, 2, 4, 6, 8 (plus 13a). Existing `ChatViewModelSocketTests:67,111`, `ConciergeViewModelTests:94`, `TeamViewModelTests:90,104` switch from `vm.socket.*` to `vm.connectionState` so the forwarding is what they prove.
  - Harness: `present` — `KeeperTests/` with in-memory `ModelContainer`, `FakeWebSocketTaskFactory`, `FakeCredentialStore`, `settle()`; `FakeWebSocketTask` gains `lastCloseCode` (Task 1).

- Integration: `not-required`
  - Scope: n/a
  - Reason: see Non-Required Rationale.
  - Harness: `not-applicable`
  - Minimum assertions: none

- E2E: `not-required`
  - Scope: n/a
  - Reason: see Non-Required Rationale.
  - Harness: `not-applicable`
  - Minimum assertions: none

### Critical Flows

- **Beekeeper cold start / reconnect with typing:** `configure` → `.connecting` → user sends → `.offline` entry → handshake → `.connected` arms `awaitingPostReconnectSync` + 5 s fallback → `list_sessions` → `session_list` → `syncSessions` reclassifies `.offline` → `.busy`, reconciles statuses, flushes one head per idle session not already flushed → `.status("idle")` drains the rest.
- **Beekeeper loss mid-flight:** `.connected` → `.reconnecting(1)` cancels the fallback; queued entries stay; a `sendToServer` that hits a `false` re-enqueues at the head as `.offline`.
- **Team cold start:** `connectIfPossible()` (stamps `activeHive`) → user sends during `.connecting` → `OfflineEntry(hive:)` → handshake → `onConnected()` bookkeeping frames → `resendOfflineEntries()` for that hive → `ack` flips `pending`.
- **Team loss with un-acked sends:** leaving `.connected` moves `pendingMessageIds.values` to `offlineEntries` (row `createdAt` order, current `activeHive` stamp); same-hive reconnect re-sends with fresh ids; a different hive's `onConnected` skips them; returning to the original hive delivers them.
- **Auth failure / unpair:** 4001 → transition-out move → `handleAuthFailure` / `unpair()` clear both in-memory queues so nothing flushes into the next pairing.
- **Errors:** Beekeeper `.error` nil-session → `browseError` if a browse is pending else `lastError`; Team `.error` → `lastError`; slash command / `openAgentDM` offline → `lastError`; hive vanished → `lastError` + `disconnect()`; `lastError` auto-clears after 6 s (injectable) or on banner tap.
- **Concierge offline cold start:** configured-but-unpaired → `.disconnected` → `waitForSocketConnected` returns `false` immediately → `state = .error("Not connected. Retry when reconnected.")`, `bailedOffline = true`, cache kept, nothing sent → next `.connected` transition → `BeekeeperRootView.onChange` → `retryIfBailedOffline` re-runs the flow once.

### Regression Surface

- `WSOutgoing` / `TeamWSOutgoing` encoders untouched; every frame sent today is sent with the same shape. The only intentional frame-level change: an attachment-only Beekeeper send flushed from the queue no longer emits a spurious `message` frame carrying the attachment name (§4, test 13a).
- `syncSessions`: stale marking, row insertion, status adoption, watchdog arming, current-session clearing are untouched — only the three named insertions (§5). C and D edit this function next; keep the diff to those insertions.
- `.status("session_ended")` behavior is unchanged (now via `endSession(_:)`).
- `/clear` handoff (`contextCleared` → `sessionInfo`) and `sessionReplaced` queue migration keep working on the struct queue.
- Team `sendWithId` correlation maps (`pendingCommandChannels`, `pendingNewCommands`, `pendingDMRequestId`, `pendingAgentDM`) are untouched except that `pendingMessageIds` is drained on loss and on auth failure.
- `TeamViewModel.disconnect()` still resets `pendingAgentDM`/`pendingDMRequestId` and clears **no** queue state (§7 *Hive switch*).
- Hive-vanished check still runs once per loss on `.reconnecting(attempt: 1)` (A's documented deviation).
- Existing `testDeviceIdFollowsCredentialStore` sends before any `connectIfPossible()`; those rows are stamped `""`, stay queued and `pending: true`, exactly as the test asserts — compatible as-is, no edit.
- Existing `testRunFlowWaitsForHandshakeBeforeCacheHitResume` (test 20) keeps passing unchanged: it drives `.connecting → .connected`.
- `TeamSortedAgentsTests` constructs `TeamViewModel()` with defaults; the `init` sink on a default socket is inert (no connect).
- macOS target builds with **no new warnings** (fix 5 removes one).
- No wire change, no persistence of queues, no other UI (§ Non-goals).

### Commands

- Unit (full): the `xcodebuild test … -only-testing:KeeperTests` command under *Working constraints*; expected final line `Executed 216 tests, with 0 failures` (204 if `CapabilityManagerTests` is skipped).
- Unit (focused): same command with `-only-testing:KeeperTests/<ClassName>`; expected counts are stated per task.
- Integration: `not-applicable`
- E2E: `not-applicable`
- Broader regression / build gate (Task 9): macOS build prints `BUILD SUCCEEDED` and no `warning:` line that is new relative to `epic-kpr-441`; `grep -rn 'viewModel\.socket\.' Views` prints nothing; `grep -rn 'disconnectedBanner\|retryConnect\|handleConnectionLost\|previousSocketState' Views ViewModels KeeperTests Managers Models` prints nothing; `git diff epic-kpr-441 --stat -- Keepur.xcodeproj/project.pbxproj` shows exactly `4 insertions(+)`.

### Harness Requirements

- Xcode 26.3 with an iPhone simulator (present). `KeeperTests` in-memory containers: `ChatViewModelSocketTests`/`ConciergeViewModelTests` use `Session`+`Message`; `TeamViewModelTests` uses `TeamChannel`+`TeamMessage`.
- `FakeWebSocketTask.lastCloseCode` (added in Task 1) for test 18.
- Injectable `lastErrorAutoClear: Duration` on both VM inits (Tasks 3, 7) for tests 11b.
- `BeekeeperSocketTests.makeSocket` gains a `maxReconnectDelay:` parameter (Task 1) for test 16.
- pbxproj wiring in Task 2: a verified four-line hand edit is the expected path (no tooling); the `xcodeproj` Ruby gem is an optional alternative — **not installed** on this machine, and may not install on the system Ruby 2.6.

### Non-Required Rationale

- Integration: the only integration boundary is the live Beekeeper/Hive server, which has no test instance; the fake `WebSocketTasking` covers the socket contract and every flow above is driven end-to-end through the fake at the view-model level.
- E2E: no UI-test target exists; the one new screen element (`KeepurConnectionBanner`) is covered by the pure `Presentation` mapping tests plus a `body` smoke, the same pattern as every other `Theme/Components` file.

### Verification Rules

- Missing harness is not a skip reason; set it up or report a concrete blocker.
- If a test failure exposes an implementation issue, fix the implementation, not the test.
- If testing exposes a spec or plan mismatch, demote the ticket to the spec lane (the dispatcher's call — report, do not improvise).
- Every "Verify" step must be run and its output confirmed before the task's commit (`dodi-dev:verify`).
- The hive-vanished path is **not unit-testable in B** (needs a `CapabilityManager.refresh` seam) — covered manually; noted for E (spec § Out-of-scope findings). Do not add a network-hitting test for it.

---

### Task 1: Transport carried-in fixes (`BeekeeperSocket` 1, 2, 3, 5) + tests 16–18

**Files:**
- Modify: `Managers/BeekeeperSocket.swift:127-136` (`disconnect`), `:248-259` (`receive` failure branch), `:271-275` (`scheduleReconnect` bail), `:289-297` (`teardown`)
- Modify: `KeeperTests/FakeWebSocketTask.swift:15,26-28`
- Test: `KeeperTests/BeekeeperSocketTests.swift` (`makeSocket` gains `maxReconnectDelay:`; three new cases)

- [ ] **Step 1:** In `Managers/BeekeeperSocket.swift`, replace `disconnect()` (lines 127–136) with:

```swift
    /// User-initiated close. Clears `lastChannel` (so `reconnect()` is a no-op until the
    /// next `connect(channel:)`, matching the old Team manager) and closes with
    /// `.normalClosure` — internal teardowns keep `.goingAway`. Safe: in `.disconnected`
    /// `connect(channel:)` never consults `lastChannel`, and the generation bump means no
    /// callback can reach `scheduleReconnect` afterwards.
    func disconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        tokenRetryTask?.cancel()
        tokenRetryTask = nil
        reconnectAttempts = 0
        tokenReadRetries = 0
        lastChannel = nil
        teardown(closeCode: .normalClosure)
        setState(.disconnected)
    }
```

- [ ] **Step 2:** In the `receive()` `.failure` branch (line 249), replace `if task.closeCode.rawValue == 4001 {` with:

```swift
                    // `self.task` — not the captured `task` — clears the macOS Sendable warning;
                    // the `gen == self.generation` guard above already proves they are the same task.
                    if self.task?.closeCode.rawValue == 4001 {
```

- [ ] **Step 3:** In `scheduleReconnect()` replace the bail (lines 272–275) with:

```swift
        guard credentials.isPaired, let channel = lastChannel else {
            // An exhausted token-read retry lands here with the count still set; without
            // the reset the next `connect()` skips `.connecting` (`open` only sets it at 0)
            // and the next failure starts backoff one exponent high.
            reconnectAttempts = 0
            setState(.disconnected)
            return
        }
```

- [ ] **Step 4:** Replace `teardown()` (lines 289–297) with:

```swift
    /// Cancels the task and the ping loop and invalidates their callbacks. Does not
    /// touch `state`; callers set it. Failure and channel-switch teardowns close with
    /// `.goingAway`; `disconnect()` passes `.normalClosure`.
    private func teardown(closeCode: URLSessionWebSocketTask.CloseCode = .goingAway) {
        generation += 1
        pingTask?.cancel()
        pingTask = nil
        task?.cancel(with: closeCode, reason: nil)
        task = nil
    }
```

- [ ] **Step 5:** In `KeeperTests/FakeWebSocketTask.swift` add a recorded close code. After line 15 (`private(set) var cancelled = false`) add:

```swift
    /// The code the socket cancelled this task with (`disconnect()` → `.normalClosure`,
    /// failure/channel-switch teardown → `.goingAway`).
    private(set) var lastCloseCode: URLSessionWebSocketTask.CloseCode?
```

and replace `cancel(with:reason:)` (lines 26–28) with:

```swift
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        cancelled = true
        lastCloseCode = closeCode
    }
```

- [ ] **Step 6:** In `KeeperTests/BeekeeperSocketTests.swift` replace `makeSocket` (lines 25–41) with:

```swift
    private func makeSocket(
        pingInterval: Duration = .seconds(30),
        maxReconnectDelay: TimeInterval = 30,
        tokenReadRetryDelay: Duration = .seconds(2),
        maxTokenReadRetries: Int = 3
    ) -> BeekeeperSocket {
        var config = BeekeeperSocket.Config.standard
        config.pingInterval = pingInterval
        config.maxReconnectDelay = maxReconnectDelay
        config.tokenReadRetryDelay = tokenReadRetryDelay
        config.maxTokenReadRetries = maxTokenReadRetries
        let factory = self.factory!
        return BeekeeperSocket(
            config: config,
            credentials: credentials,
            endpoint: { URL(string: "wss://unit.test")! },
            taskFactory: { factory.make(url: $0) }   // closure literal, not `factory.make`
        )
    }
```

- [ ] **Step 7:** Append these three tests before the closing brace of `BeekeeperSocketTests` (after `testStandardKeepAliveFrameMatchesBothPingEncoders`):

```swift
    // MARK: - Child B carried-in fixes

    /// Fix 1: a `scheduleReconnect` bail (not paired) must reset the attempt count, or the
    /// next `connect` skips `.connecting` and the next failure starts backoff at attempt 2.
    func testBailedReconnectResetsAttemptCount() async throws {
        let socket = makeSocket(maxReconnectDelay: 0.01, tokenReadRetryDelay: .milliseconds(1), maxTokenReadRetries: 1)
        socket.connect(channel: "beekeeper")
        try XCTUnwrap(factory.latest).completeHandshake(error: URLError(.cannotConnectToHost))
        await settle()
        XCTAssertEqual(socket.state, .reconnecting(attempt: 1))

        credentials.token = nil                          // the 10 ms backoff retry finds no token
        try await Task.sleep(for: .milliseconds(100))    // backoff + one 1 ms token retry + hops; generous for a loaded CI simulator
        XCTAssertEqual(socket.state, .disconnected, "unpaired, so the retry bails out of backoff")
        XCTAssertEqual(factory.made.count, 1, "no task was opened without a token")

        credentials.token = "test-token"
        socket.connect(channel: "beekeeper")
        XCTAssertEqual(socket.state, .connecting, "a bailed reconnect must reset the attempt count, or .connecting is skipped")
        try XCTUnwrap(factory.latest).completeHandshake(error: URLError(.cannotConnectToHost))
        await settle()
        XCTAssertEqual(socket.state, .reconnecting(attempt: 1), "backoff restarts at attempt 1, not 2")
    }

    /// Fix 2: `disconnect()` clears `lastChannel`, so `reconnect()` is a no-op afterwards.
    func testReconnectAfterDisconnectIsNoOp() async throws {
        let socket = makeSocket()
        _ = await connectAndHandshake(socket)

        socket.disconnect()
        socket.reconnect()

        XCTAssertEqual(factory.made.count, 1)
        XCTAssertNil(socket.lastChannel)
        XCTAssertEqual(socket.state, .disconnected)
    }

    /// Fix 3: user close is `.normalClosure`; failure teardown stays `.goingAway`.
    func testDisconnectClosesNormallyAndFailureClosesGoingAway() async throws {
        let socket = makeSocket()
        let task = await connectAndHandshake(socket)
        socket.disconnect()
        XCTAssertEqual(task.lastCloseCode, .normalClosure)

        let other = makeSocket()
        other.connect(channel: "beekeeper")
        let failing = try XCTUnwrap(factory.latest)
        XCTAssertFalse(failing === task)
        failing.completeHandshake(error: URLError(.cannotConnectToHost))
        await settle()
        XCTAssertEqual(failing.lastCloseCode, .goingAway)
    }
```

- [ ] **Step 8:** Verify (focused run):

```bash
xcodebuild test -project Keepur.xcodeproj -scheme Keepur -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:KeeperTests/BeekeeperSocketTests -derivedDataPath /tmp/keepur-dd 2>&1 | grep -E "error:|failed|Executed [0-9]+ tests, with|TEST (SUCCEEDED|FAILED)"
```

Expected: `Executed 14 tests, with 0 failures` and `TEST SUCCEEDED`.

- [ ] **Step 9:** Commit:

```bash
git add Managers/BeekeeperSocket.swift KeeperTests/FakeWebSocketTask.swift KeeperTests/BeekeeperSocketTests.swift
git commit -m "fix(socket): reset attempts on bailed reconnect, clear lastChannel and close normally on disconnect, drop Sendable capture (KPR-442)"
```

### Task 2: `UserFacingError`, `KeepurConnectionBanner`, `Presentation.make`, pbxproj wiring + tests 1–6

**Files:**
- Create: `Models/UserFacingError.swift` (synchronized group — no pbxproj edit)
- Create: `Theme/Components/KeepurConnectionBanner.swift` (**explicit pbxproj group** — must be wired, Step 4)
- Create: `Views/ConnectionBannerPresentation.swift` (synchronized group)
- Modify: `Keepur.xcodeproj/project.pbxproj` (exactly four insertions)
- Test: `KeeperTests/KeepurConnectionBannerTests.swift` (new; synchronized group)

- [ ] **Step 1:** Create `Models/UserFacingError.swift`:

```swift
import Foundation

/// A toast-style message for the connection banner. `Identifiable` so the
/// auto-clear timer can tell "still the same error" from a newer one.
struct UserFacingError: Identifiable, Equatable {
    let id = UUID()
    let text: String

    init(_ text: String) {
        self.text = text
    }
}
```

- [ ] **Step 2:** Create `Theme/Components/KeepurConnectionBanner.swift` (token-only; imports SwiftUI only; no `Managers/`/`ViewModels/` type):

```swift
import SwiftUI

/// Thin connection strip above a message list: connecting / reconnecting /
/// not-connected / error. Renders nothing for a `nil` presentation; the container's
/// `.animation(.default, value:)` covers appear/disappear. Not color-only — the
/// symbol and copy carry the state. The state → `Presentation` mapping lives in
/// `Views/ConnectionBannerPresentation.swift`, so this file stays token-only.
struct KeepurConnectionBanner: View {
    struct Presentation: Equatable {
        enum Tint: Equatable { case warning, danger }

        let text: String
        let tint: Tint
        let symbol: String                 // "arrow.triangle.2.circlepath" (warning) / "exclamationmark.triangle.fill" (danger)
        let actionTitle: String?           // "Retry now" / "Retry" / nil
        let accessibilityLabel: String
        let dismissesOnTap: Bool           // true iff an error is showing
    }

    let presentation: Presentation?        // nil → renders nothing
    let onRetry: () -> Void
    let onDismissError: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let presentation {
                strip(presentation)
            }
        }
        .animation(.default, value: presentation)
    }

    private func strip(_ p: Presentation) -> some View {
        HStack(spacing: KeepurTheme.Spacing.s2) {
            HStack(spacing: KeepurTheme.Spacing.s2) {
                Image(systemName: p.symbol)
                    .foregroundStyle(tintColor(p.tint))
                Text(p.text)
                    .font(KeepurTheme.Font.bodySm)
                    .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            // Tap-to-dismiss on the text region only while an error is showing; the action
            // button stays a separate accessibility element. The accessibility modifiers
            // run consecutively: a non-accessibility ViewModifier interposed between
            // `.accessibilityElement(children: .ignore)` and the trait/hint would leave
            // the trait/hint on an inner element the `.ignore` then discards.
            .contentShape(Rectangle())
            .onTapGesture { if p.dismissesOnTap { onDismissError() } }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(p.accessibilityLabel)
            .accessibilityAddTraits(p.dismissesOnTap ? .isButton : [])
            .accessibilityHint(p.dismissesOnTap ? "Dismiss" : "")

            if let title = p.actionTitle {
                Button(action: onRetry) {
                    Text(title)
                        .font(KeepurTheme.Font.bodySm)
                        .fontWeight(.bold)
                        .foregroundStyle(KeepurTheme.Color.honey700)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(KeepurTheme.Spacing.s3)
        .frame(maxWidth: .infinity)
        .background(KeepurTheme.Color.bgSunkenDynamic)
    }

    private func tintColor(_ tint: Presentation.Tint) -> Color {
        switch tint {
        case .warning: return KeepurTheme.Color.warning
        case .danger:  return KeepurTheme.Color.danger
        }
    }
}
```

- [ ] **Step 3:** Create `Views/ConnectionBannerPresentation.swift`:

```swift
import Foundation

extension KeepurConnectionBanner.Presentation {
    static let disconnectedText = "Not connected. Messages will send when reconnected."
    private static let warningSymbol = "arrow.triangle.2.circlepath"
    private static let dangerSymbol = "exclamationmark.triangle.fill"

    /// Pure mapping from socket state + optional error to what the banner shows; the
    /// unit under test. `nil` → render nothing. A non-nil error replaces the *text* in
    /// every state and the state's *action* is kept (spec §3 table).
    static func make(state: BeekeeperSocket.State, error: UserFacingError?) -> Self? {
        switch (state, error) {
        case (.connected, nil):
            return nil
        case (.connected, let e?):
            return Self(text: e.text, tint: .danger, symbol: dangerSymbol,
                        actionTitle: nil, accessibilityLabel: e.text, dismissesOnTap: true)
        case (.connecting, nil):
            return Self(text: "Connecting…", tint: .warning, symbol: warningSymbol,
                        actionTitle: nil, accessibilityLabel: "Connecting", dismissesOnTap: false)
        case (.connecting, let e?):
            return Self(text: e.text, tint: .danger, symbol: dangerSymbol,
                        actionTitle: nil, accessibilityLabel: e.text, dismissesOnTap: true)
        case (.reconnecting(let n), nil):
            return Self(text: "Reconnecting…", tint: .warning, symbol: warningSymbol,
                        actionTitle: "Retry now", accessibilityLabel: "Reconnecting, attempt \(n)", dismissesOnTap: false)
        case (.reconnecting(let n), let e?):
            return Self(text: e.text, tint: .danger, symbol: dangerSymbol,
                        actionTitle: "Retry now", accessibilityLabel: "\(e.text). Reconnecting, attempt \(n)", dismissesOnTap: true)
        case (.disconnected, nil):
            return Self(text: disconnectedText, tint: .danger, symbol: dangerSymbol,
                        actionTitle: "Retry", accessibilityLabel: disconnectedText, dismissesOnTap: false)
        case (.disconnected, let e?):
            return Self(text: e.text, tint: .danger, symbol: dangerSymbol,
                        actionTitle: "Retry", accessibilityLabel: "\(e.text). Not connected.", dismissesOnTap: true)
        }
    }
}
```

- [ ] **Step 4:** Wire `KeepurConnectionBanner.swift` into the `Keepur` target. `Theme/Components` is an explicit `PBXGroup` (`86E3C5B2B906AAB8C221E5D9`), not a synchronized group, so the file is invisible to the build until the project knows it. Two routes that produce the same four-line diff. **(a) the hand edit is the expected path**; (b) the `xcodeproj` gem is the alternative if you prefer it and it installs (it is not installed today, and current gem releases may not install cleanly on the system Ruby 2.6 at `/usr/bin/ruby`).

  **(a) Hand edit** — insert these four lines in `Keepur.xcodeproj/project.pbxproj` (tabs as in the neighbours; the two 24-hex ids are unused in the file — `grep -c B442C0EE` prints `0` before the edit). The `PBXBuildFile` and `PBXFileReference` sections are **id-sorted** — insert in sorted position, or the next Xcode save re-sorts them and produces a noisy unrelated diff; the group `children` and Sources `files` lists are insertion-ordered, so those go after the `KeepurChatHeader` neighbour:
  - In `/* Begin PBXBuildFile section */`, after the `A7E6E1EEC8C1CB9138421004 /* KeepurUnreadBadge.swift in Sources */` line (and before `DD3B48812F866DF4002EA052 /* MarkdownUI in Frameworks */`):
    ```
    		B442C0EE1A2B3C4D5E6F7A02 /* KeepurConnectionBanner.swift in Sources */ = {isa = PBXBuildFile; fileRef = B442C0EE1A2B3C4D5E6F7A01 /* KeepurConnectionBanner.swift */; };
    ```
  - In `/* Begin PBXFileReference section */`, after the `B31BDB567D5A0BD76B26AA46 /* KeepurActionSheet.swift */` line (and before `CA606BA21C3A5266389DD07E /* KeepurChipCluster.swift */`):
    ```
    		B442C0EE1A2B3C4D5E6F7A01 /* KeepurConnectionBanner.swift */ = {isa = PBXFileReference; includeInIndex = 1; lastKnownFileType = sourcecode.swift; path = KeepurConnectionBanner.swift; sourceTree = "<group>"; };
    ```
  - In the `86E3C5B2B906AAB8C221E5D9 /* Components */` group's `children`, after `4DEB9F85E98BE473CD9920FD /* KeepurChatHeader.swift */,`:
    ```
    				B442C0EE1A2B3C4D5E6F7A01 /* KeepurConnectionBanner.swift */,
    ```
  - In `A1ABEBBD2F79E16C009B0AFC /* Sources */` `files`, after `94129812225D71F33A70FE11 /* KeepurChatHeader.swift in Sources */,`:
    ```
    				B442C0EE1A2B3C4D5E6F7A02 /* KeepurConnectionBanner.swift in Sources */,
    ```
  (The `KeeperTests` target's Sources phase is empty — that group is synchronized — so nothing is added there.)

  **(b) `xcodeproj` gem** (per the KPR-146 precedent) — the gem generates its own ids and placement, so the diff is four insertions but not byte-identical to (a); Step 5's checks hold either way:
  ```bash
  /usr/bin/ruby -e 'require "xcodeproj"' 2>/dev/null || /usr/bin/gem install --user-install xcodeproj
  cat > /tmp/keepur-wire-banner.rb <<'RUBY'
  require 'xcodeproj'
  project = Xcodeproj::Project.open('Keepur.xcodeproj')
  group = project.main_group['Theme']['Components']
  ref = group.new_reference('KeepurConnectionBanner.swift')
  target = project.targets.find { |t| t.name == 'Keepur' }
  target.source_build_phase.add_file_reference(ref)
  project.save
  RUBY
  /usr/bin/ruby /tmp/keepur-wire-banner.rb
  ```
  If `gem install` fails, fall back to (a) — do not chase the toolchain.

- [ ] **Step 5:** Verify the wiring:

```bash
git diff --stat -- Keepur.xcodeproj/project.pbxproj
git diff -- Keepur.xcodeproj/project.pbxproj | grep '^+' | grep -c KeepurConnectionBanner
```

Expected: `1 file changed, 4 insertions(+)` and `4` (one `PBXBuildFile`, one `PBXFileReference`, one group child, one Sources entry). Anything else → `git checkout Keepur.xcodeproj/project.pbxproj` and redo via route (a).

- [ ] **Step 6:** Create `KeeperTests/KeepurConnectionBannerTests.swift`:

```swift
import XCTest
import SwiftUI
@testable import Keepur

/// Pure mapping tests for `KeepurConnectionBanner.Presentation.make(state:error:)`
/// (spec §3 table) plus a `body` smoke for every row. @MainActor because
/// `BeekeeperSocket.State` and the mapping live in the MainActor-isolated app target.
@MainActor
final class KeepurConnectionBannerTests: XCTestCase {
    private typealias P = KeepurConnectionBanner.Presentation

    func testConnectedWithoutErrorRendersNothing() {
        XCTAssertNil(P.make(state: .connected, error: nil))
    }

    func testConnecting() throws {
        let p = try XCTUnwrap(P.make(state: .connecting, error: nil))
        XCTAssertEqual(p.text, "Connecting…")
        XCTAssertNil(p.actionTitle)
        XCTAssertEqual(p.tint, .warning)
        XCTAssertEqual(p.accessibilityLabel, "Connecting")
        XCTAssertFalse(p.dismissesOnTap)
    }

    func testReconnectingKeepsAttemptOutOfVisibleText() throws {
        let p = try XCTUnwrap(P.make(state: .reconnecting(attempt: 3), error: nil))
        XCTAssertEqual(p.text, "Reconnecting…")
        XCTAssertEqual(p.actionTitle, "Retry now")
        XCTAssertEqual(p.tint, .warning)
        XCTAssertTrue(p.accessibilityLabel.contains("attempt 3"))
        XCTAssertFalse(p.text.contains("3"), "attempt count is accessibility-only")
    }

    func testDisconnected() throws {
        let p = try XCTUnwrap(P.make(state: .disconnected, error: nil))
        XCTAssertEqual(p.text, "Not connected. Messages will send when reconnected.")
        XCTAssertEqual(p.actionTitle, "Retry")
        XCTAssertEqual(p.tint, .danger)
        XCTAssertEqual(p.accessibilityLabel, p.text)
        XCTAssertFalse(p.dismissesOnTap)
    }

    func testErrorWinsInEveryStateAndKeepsTheStateAction() throws {
        let error = UserFacingError("boom")
        let states: [BeekeeperSocket.State] = [.connected, .connecting, .reconnecting(attempt: 2), .disconnected]
        for state in states {
            let p = try XCTUnwrap(P.make(state: state, error: error), "\(state)")
            XCTAssertEqual(p.text, "boom", "\(state)")
            XCTAssertEqual(p.tint, .danger, "\(state)")
            XCTAssertTrue(p.dismissesOnTap, "\(state)")
            XCTAssertEqual(p.actionTitle, P.make(state: state, error: nil)?.actionTitle,
                           "\(state): the action is unchanged from the nil-error row")
            XCTAssertTrue(p.accessibilityLabel.hasPrefix("boom"), "\(state)")
        }
        XCTAssertEqual(try XCTUnwrap(P.make(state: .reconnecting(attempt: 2), error: error)).accessibilityLabel,
                       "boom. Reconnecting, attempt 2")
        XCTAssertEqual(try XCTUnwrap(P.make(state: .disconnected, error: error)).accessibilityLabel,
                       "boom. Not connected.")
    }

    func testBannerInstantiatesForEveryRow() {
        let error = UserFacingError("boom")
        var presentations: [P?] = [nil]
        for state in [BeekeeperSocket.State.connected, .connecting, .reconnecting(attempt: 1), .disconnected] {
            presentations.append(P.make(state: state, error: nil))
            presentations.append(P.make(state: state, error: error))
        }
        for p in presentations {
            _ = KeepurConnectionBanner(presentation: p, onRetry: {}, onDismissError: {}).body
        }
    }
}
```

- [ ] **Step 7:** Verify (focused run):

```bash
xcodebuild test -project Keepur.xcodeproj -scheme Keepur -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:KeeperTests/KeepurConnectionBannerTests -derivedDataPath /tmp/keepur-dd 2>&1 | grep -E "error:|failed|Executed [0-9]+ tests, with|TEST (SUCCEEDED|FAILED)"
```

Expected: `Executed 6 tests, with 0 failures`, `TEST SUCCEEDED`. A `cannot find 'KeepurConnectionBanner' in scope` error means Step 4's wiring did not land.

- [ ] **Step 8:** Commit:

```bash
git add Models/UserFacingError.swift Theme/Components/KeepurConnectionBanner.swift Views/ConnectionBannerPresentation.swift Keepur.xcodeproj/project.pbxproj KeeperTests/KeepurConnectionBannerTests.swift
git commit -m "feat(theme): KeepurConnectionBanner + UserFacingError with state→presentation mapping (KPR-442)"
```

### Task 3: `ChatViewModel` connection surface (`connectionState`, `lastError`, `.error` routing)

**Files:**
- Modify: `ViewModels/ChatViewModel.swift:30-31` (published state), `:37-38` (private vars), `:62-82` (`init`/`configure`), `:86-88` (`reconnect`), `:478-488` (`.error` case)

- [ ] **Step 1:** After line 31 (`@Published var pendingAttachment: AttachmentData?`) add:

```swift
    /// Mirrors `socket.$state`; views observe this, never `socket` directly.
    @Published private(set) var connectionState: BeekeeperSocket.State = .disconnected
    /// Banner-consumed. Auto-clears after `lastErrorAutoClear` or on tap (set to nil).
    @Published var lastError: UserFacingError? {
        didSet {
            lastErrorTimer?.cancel()
            lastErrorTimer = nil
            guard let id = lastError?.id else { return }
            let delay = lastErrorAutoClear
            lastErrorTimer = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self, self.lastError?.id == id else { return }
                self.lastError = nil
            }
        }
    }
    /// True once `configure()` or `reconnect()` has asked the socket to connect. Lets
    /// the concierge coordinator tell the cold initial `.disconnected` from a failed one.
    private(set) var hasRequestedConnection = false
```

> ⚠ **Plan-level delegated assumption P1 — `hasRequestedConnection`.** Spec §8.4 says `waitForSocketConnected` "returns `false` immediately on `.disconnected`" and treats the `configure()`-before-`.task` ordering as acknowledged-but-not-load-bearing. This plan tightens that: a `.disconnected` seen *before* any connect request is the cold initial value and is waited through (Task 6 Step 4), so the bail never depends on that ordering at all. Strictly narrower than the spec's behavior (the spec's tests 19/19a/20 pass unchanged — test 19 drives a configured-but-unpaired VM, so `hasRequestedConnection` is `true` there), no wire or UI effect. Named here so a later reviewer reads it as deliberate, not unrequested scope.

- [ ] **Step 2:** After line 38 (`private var frameSubscription: AnyCancellable?`) add:

```swift
    private var stateSubscription: AnyCancellable?     // sibling of frameSubscription; no Set here
    private var lastErrorTimer: Task<Void, Never>?
    private let lastErrorAutoClear: Duration
```

- [ ] **Step 3:** Replace `init` (lines 62–68) with:

```swift
    init(
        socket: BeekeeperSocket? = nil,
        credentials: CredentialStore = KeychainCredentialStore(),
        lastErrorAutoClear: Duration = .seconds(6)
    ) {
        self.socket = socket ?? BeekeeperSocket(config: .standard, credentials: credentials)
        self.credentials = credentials
        self.lastErrorAutoClear = lastErrorAutoClear
        // Subscribed in init, not configure, so Settings and the list views observe
        // truth before configure runs and independently of it.
        stateSubscription = self.socket.$state.sink { [weak self] state in
            self?.handleSocketState(state)
        }
    }
```

- [ ] **Step 4:** In `configure(context:)` insert `hasRequestedConnection = true` on the line before `socket.connect(channel: Self.channel)`; in `reconnect()` insert the same line before its `socket.connect(channel: Self.channel)`.

- [ ] **Step 5:** After `disconnect()` (line 92) add the sink handler (Task 4 extends it with the reconnect-flush hooks):

```swift
    // MARK: - Connection state

    private func handleSocketState(_ state: BeekeeperSocket.State) {
        connectionState = state
    }
```

- [ ] **Step 6:** Replace the `.error` case (lines 478–488) with:

```swift
        case .error(let message, let sessionId):
            if let sessionId {
                let msg = Message(sessionId: sessionId, text: "Error: \(message)", role: "system")
                context.insert(msg)
                try? context.save()
            } else if isBrowsePending {
                isBrowsePending = false
                browseError = message                    // the picker shows it inline; no banner
            } else {
                lastError = UserFacingError(message)     // no more bubble in whichever session is current
            }
```

- [ ] **Step 7:** Verify it compiles and nothing regresses (focused run of the existing socket tests):

```bash
xcodebuild test -project Keepur.xcodeproj -scheme Keepur -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:KeeperTests/ChatViewModelSocketTests -derivedDataPath /tmp/keepur-dd 2>&1 | grep -E "error:|failed|Executed [0-9]+ tests, with|TEST (SUCCEEDED|FAILED)"
```

Expected: `Executed 4 tests, with 0 failures`.

- [ ] **Step 8:** Commit:

```bash
git add ViewModels/ChatViewModel.swift
git commit -m "feat(chat): publish connectionState and lastError; route nil-session errors to the banner (KPR-442)"
```

### Task 4: Beekeeper offline queue (`pendingReasons`, reconnect flush, `syncSessions` new shape, badge) + tests 12–15a

**Files:**
- Modify: `ViewModels/ChatViewModel.swift:30` (`pendingMessageIds`), `:43` (queue tuple), `:111-137` (`sendText`), `:185-189` (`unpair`), handler added in Task 3 (`handleSocketState`), `:252-258` (`session_ended` branch), `:318-342` (`.sessionList` call), `:460-468` (`sessionReplaced` migration), `:506-531` (`sendToServer`/`flushNextPendingMessage`/`clearPendingMessages`), `:579-632` (`syncSessions`)
- Modify: `Views/MessageBubble.swift:6,70-84`; `Views/ChatView.swift:80`
- Test: `KeeperTests/ChatViewModelSocketTests.swift` (helpers + six new cases; migrate lines 67 and 111)

Line numbers are those of the file at `4f97d0c` before Task 3; Task 3 shifted everything below line 31 by its insertions — locate by content.

- [ ] **Step 1:** Replace `@Published var pendingMessageIds: Set<String> = []` with:

```swift
    enum PendingReason: Equatable { case busy, offline }
    /// Message id → why it has not gone out yet. Replaces the old id set; the
    /// bubble badge reads "waiting" for `.busy` and "not sent" for `.offline`.
    @Published private(set) var pendingReasons: [String: PendingReason] = [:]
```

- [ ] **Step 2:** Replace the tuple queue line (`private var pendingMessages: [(text: String, messageId: String, sessionId: String, attachment: AttachmentData?)] = []`) with:

```swift
    private struct PendingMessage {
        /// The trimmed input text — empty for an attachment-only send. Not
        /// `effectiveText` (the attachment name), which the `Message` row keeps for
        /// display; sending it would emit a text frame the direct path never did.
        let text: String
        let messageId: String
        var sessionId: String
        let attachment: AttachmentData?
    }
    /// Ordered queue for both `.busy` and `.offline` entries; `pendingReasons` mirrors it.
    private var pendingMessages: [PendingMessage] = []
    /// Armed on the transition into `.connected`; whichever of the next `syncSessions`
    /// and the fallback fires first clears it — exactly one reclassify + flush per reconnect.
    private var awaitingPostReconnectSync = false
    private var postReconnectFlushFallback: Task<Void, Never>?
    private static let postReconnectFlushTimeout: Duration = .seconds(5)
```

- [ ] **Step 3:** In `sendText()`, replace the block from `if statusFor(sessionId) != "idle" {` through its closing `}` (before `messageText = ""`) with:

```swift
        let entry = PendingMessage(text: text, messageId: message.id, sessionId: sessionId, attachment: attachment)
        if connectionState != .connected {
            enqueue(entry, reason: .offline)
        } else if statusFor(sessionId) != "idle" {
            enqueue(entry, reason: .busy)
        } else {
            sendToServer(entry)   // a `false` re-enqueues at the head as .offline
        }
```

- [ ] **Step 4:** Replace `unpair()` with:

```swift
    func unpair() {
        socket.disconnect()
        credentials.clearAll()
        isAuthenticated = false
        // Both VMs are @StateObjects on ContentView and outlive a re-pair; nothing
        // queued here may flush into the next pairing's sessions (spec ⚠6).
        pendingMessages.removeAll()
        pendingReasons.removeAll()
    }
```

- [ ] **Step 5:** Replace the Task-3 `handleSocketState` with the full version:

```swift
    // MARK: - Connection state

    private func handleSocketState(_ state: BeekeeperSocket.State) {
        let previous = connectionState
        connectionState = state
        // NEVER call socket.send from here: @Published emits on willSet, so the socket's
        // own send gate still reads the previous state during this call. Beekeeper
        // flushes on the post-reconnect session_list (or the fallback below).
        if state == .connected, previous != .connected {
            awaitingPostReconnectSync = true
            postReconnectFlushFallback?.cancel()
            postReconnectFlushFallback = Task { [weak self] in
                try? await Task.sleep(for: Self.postReconnectFlushTimeout)
                guard !Task.isCancelled, let self else { return }
                // Clear the flag and the handle FIRST so a session_list that lands later is an
                // ordinary sync and a fired task is never cancelled or mistaken for pending.
                self.awaitingPostReconnectSync = false
                self.postReconnectFlushFallback = nil
                self.flushOfflineQueue(skipping: [])
            }
        } else if state != .connected, previous == .connected {
            postReconnectFlushFallback?.cancel()
            postReconnectFlushFallback = nil
            awaitingPostReconnectSync = false
            // Queued entries stay; nothing else.
        }
    }
```

- [ ] **Step 6:** In the `.status` case, replace the `if state == "session_ended" { … }` block (five lines of removals + `clearPendingMessages`) with:

```swift
                if state == "session_ended" {
                    endSession(effectiveId)
                }
```

- [ ] **Step 7:** In the `.sessionList` case, replace `syncSessions(serverSessions: sessionsTabOnly, context: context)` with:

```swift
            // The absent-id check needs the FULL reply, not the Sessions-tab filter,
            // or the concierge slot (never in the Session table) is reaped every list.
            syncSessions(serverSessions: sessionsTabOnly,
                         allServerIds: Set(sessions.map(\.sessionId)),
                         context: context)
```

- [ ] **Step 8:** In `.sessionReplaced`, replace the `// Migrate queued pending messages.` loop with:

```swift
            // Migrate queued pending messages.
            for i in pendingMessages.indices where pendingMessages[i].sessionId == oldSessionId {
                pendingMessages[i].sessionId = newSessionId
            }
```

- [ ] **Step 9:** Replace the three private queue functions (`sendToServer(text:attachment:sessionId:)`, `flushNextPendingMessage(for:)`, `clearPendingMessages(for:)`) with this section:

```swift
    // MARK: - Private: busy / offline queue

    private func enqueue(_ entry: PendingMessage, reason: PendingReason, atFront: Bool = false) {
        if atFront {
            pendingMessages.insert(entry, at: 0)
        } else {
            pendingMessages.append(entry)
        }
        pendingReasons[entry.messageId] = reason
    }

    /// Sends the entry's frames in order (text if non-empty, then image/file). The
    /// first `false` from the socket re-enqueues the whole entry at the head of the
    /// queue as `.offline` and returns `false`. The socket's gate is read synchronously
    /// on the main actor, so a later frame cannot fail after an earlier one succeeded;
    /// partial re-sends do not occur.
    @discardableResult
    private func sendToServer(_ entry: PendingMessage) -> Bool {
        var frames: [WSOutgoing] = []
        if !entry.text.isEmpty {
            frames.append(.message(text: entry.text, sessionId: entry.sessionId))
        }
        if let attachment = entry.attachment {
            let base64 = attachment.data.base64EncodedString()
            if attachment.mimeType.hasPrefix("image/") {
                frames.append(.image(sessionId: entry.sessionId, data: base64, filename: attachment.name))
            } else {
                frames.append(.file(sessionId: entry.sessionId, data: base64, filename: attachment.name, mimetype: attachment.mimeType))
            }
        }
        for frame in frames {
            guard send(frame) else {
                enqueue(entry, reason: .offline, atFront: true)
                return false
            }
        }
        return true
    }

    private func flushNextPendingMessage(for sessionId: String) {
        guard let index = pendingMessages.firstIndex(where: { $0.sessionId == sessionId }) else { return }
        let entry = pendingMessages.remove(at: index)
        pendingReasons.removeValue(forKey: entry.messageId)
        sendToServer(entry)   // on `false` the entry is back at the head with reason .offline
    }

    private func clearPendingMessages(for sessionId: String) {
        let removed = pendingMessages.filter { $0.sessionId == sessionId }
        guard !removed.isEmpty else { return }
        pendingMessages.removeAll { $0.sessionId == sessionId }
        for entry in removed {
            pendingReasons.removeValue(forKey: entry.messageId)
        }
    }

    private func reclassifyOfflineAsBusy() {
        guard pendingReasons.values.contains(.offline) else { return }
        pendingReasons = pendingReasons.mapValues { $0 == .offline ? .busy : $0 }
    }

    /// Post-reconnect flush: one head per idle session that `syncSessions` did not
    /// already flush, in first-appearance order. The existing one-in-flight rule
    /// (`.status("idle")` flushes the next) drains the rest.
    private func flushOfflineQueue(skipping flushed: Set<String>) {
        reclassifyOfflineAsBusy()   // no-op on the sync path; real work on the fallback path
        var seen = Set<String>()
        for sessionId in pendingMessages.map(\.sessionId) where seen.insert(sessionId).inserted {
            guard statusFor(sessionId) == "idle", !flushed.contains(sessionId) else { continue }
            flushNextPendingMessage(for: sessionId)
        }
    }

    /// The `session_ended` cleanup, shared by the status frame and the absent-id check
    /// in `syncSessions` (child C's watchdog relies on the latter).
    private func endSession(_ sessionId: String) {
        streamingMessageIds.removeValue(forKey: sessionId)
        pendingApprovals.removeValue(forKey: sessionId)
        sessionStatuses.removeValue(forKey: sessionId)
        sessionToolNames.removeValue(forKey: sessionId)
        busyTimers[sessionId]?.cancel()
        busyTimers.removeValue(forKey: sessionId)
        clearPendingMessages(for: sessionId)
    }
```

- [ ] **Step 10:** Replace `syncSessions` in full. Only the three commented `B insertion` blocks and the `flushed` bookkeeping are new; everything else is byte-for-byte the current body (C and D layer on this function next — keep it that way):

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
        if isPostReconnectSync {
            awaitingPostReconnectSync = false
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
        var flushed = Set<String>()
        for server in serverSessions {
            let serverState = server.state  // "idle" or "busy"
            let clientState = sessionStatuses[server.sessionId]
            if clientState != nil && clientState != "idle" && serverState == "idle" {
                sessionStatuses[server.sessionId] = "idle"
                busyTimers[server.sessionId]?.cancel()
                busyTimers.removeValue(forKey: server.sessionId)
                flushNextPendingMessage(for: server.sessionId)
                flushed.insert(server.sessionId)
            } else if clientState == nil || clientState == "idle" {
                sessionStatuses[server.sessionId] = serverState
                // Start watchdog if adopting a non-idle state from the server
                if serverState != "idle" {
                    busyTimers[server.sessionId]?.cancel()
                    busyTimers[server.sessionId] = Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .seconds(Self.staleBusyTimeout))
                        guard !Task.isCancelled else { return }
                        self?.sessionStatuses[server.sessionId] = "idle"
                        self?.flushNextPendingMessage(for: server.sessionId)
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

- [ ] **Step 11:** `Views/MessageBubble.swift` — replace `var showWaitingBadge: Bool = false` (line 6) with `var pendingReason: ChatViewModel.PendingReason? = nil`, and replace the `if showWaitingBadge { … }` badge block (lines 70–84) with:

```swift
                    if let pendingReason {
                        let badgeText = pendingReason == .busy ? "waiting" : "not sent"
                        Text(badgeText)
                            .font(KeepurTheme.Font.caption)
                            .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
                            .padding(.horizontal, KeepurTheme.Spacing.s2)
                            .padding(.vertical, 2)
                            .background(
                                Capsule()
                                    .fill(KeepurTheme.Color.honey200)
                            )
                            .offset(x: 4, y: 4)
                            .opacity(isPulsing ? 0.6 : 1.0)
                            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: isPulsing)
                            .onAppear { isPulsing = true }
                            .accessibilityLabel(badgeText)
                    }
```

- [ ] **Step 12:** `Views/ChatView.swift:80` — replace `showWaitingBadge: viewModel.pendingMessageIds.contains(message.id),` with `pendingReason: viewModel.pendingReasons[message.id],`.

- [ ] **Step 13:** In `KeeperTests/ChatViewModelSocketTests.swift`: change line 67 to `XCTAssertEqual(vm.connectionState, .connected)` and line 111 to `XCTAssertEqual(vm.connectionState, .disconnected)`; update the class doc comment so its second line reads `/// cold-start frame order, inbound routing, send gating, 4001 → unpair, and the child-B offline queue.`; then add these helpers after `sentTypes(_:)`:

```swift
    /// Every frame the fake task was asked to send, decoded, in order.
    private func sentFrames(_ task: FakeWebSocketTask) throws -> [[String: Any]] {
        try task.sentTexts.map { text in
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        }
    }

    /// `text` of every `message` frame, in order.
    private func messageTexts(_ task: FakeWebSocketTask) throws -> [String] {
        try sentFrames(task)
            .filter { $0["type"] as? String == "message" }
            .compactMap { $0["text"] as? String }
    }

    private func rows(role: String) throws -> [Message] {
        try context.fetch(FetchDescriptor<Message>()).filter { $0.role == role }
    }

    /// Minimal decodable `session_list`: the decoder requires sessionId/path/state and
    /// `mode` must be "sessions" (or omitted) to survive the Sessions-tab filter.
    private static let s1Idle = #"{"type":"session_list","sessions":[{"sessionId":"s1","path":"/tmp/p","state":"idle","mode":"sessions"}]}"#
    private static let s1Busy = #"{"type":"session_list","sessions":[{"sessionId":"s1","path":"/tmp/p","state":"busy","mode":"sessions"}]}"#

    /// `configure`, select `s1` idle, and queue "hi" while still handshaking.
    private func queueOfflineHi() throws -> (task: FakeWebSocketTask, rowId: String) {
        vm.configure(context: context)
        let task = try XCTUnwrap(factory.latest)
        vm.currentSessionId = "s1"
        vm.sessionStatuses["s1"] = "idle"
        vm.messageText = "hi"
        vm.sendText()
        let rowId = try XCTUnwrap(rows(role: "user").first?.id)
        XCTAssertEqual(vm.pendingReasons[rowId], .offline)
        XCTAssertTrue(task.sentTexts.isEmpty, "nothing goes out before the handshake")
        return (task, rowId)
    }
```

- [ ] **Step 14:** Append the six tests before the class's closing brace:

```swift
    // MARK: - Child B: offline queue (⚠3 — C re-homes these into ChatViewModelTests)

    func testSendWhileConnectingQueuesOfflineAndFlushesAfterSessionList() async throws {
        let (task, _) = try queueOfflineHi()

        task.completeHandshake()
        await settle()
        XCTAssertEqual(vm.connectionState, .connected)
        XCTAssertEqual(try messageTexts(task), [], "no flush before the post-reconnect session_list")

        task.deliver(Self.s1Idle)
        await settle()

        XCTAssertEqual(try messageTexts(task), ["hi"])
        XCTAssertTrue(vm.pendingReasons.isEmpty)
    }

    func testOfflineEntryReclassifiedBusyWhenServerBusy() async throws {
        let (task, rowId) = try queueOfflineHi()
        task.completeHandshake()
        await settle()

        task.deliver(Self.s1Busy)
        await settle()
        XCTAssertEqual(vm.pendingReasons[rowId], .busy)
        XCTAssertEqual(try messageTexts(task), [], "busy session: nothing flushed")

        task.deliver(#"{"type":"status","state":"idle","sessionId":"s1"}"#)
        await settle()
        XCTAssertEqual(try messageTexts(task), ["hi"])
        XCTAssertNil(vm.pendingReasons[rowId])
    }

    /// 13a: the queue carries the trimmed text (empty here), not `effectiveText`, so an
    /// attachment-only send flushed from the queue emits no `message` frame.
    func testAttachmentOnlyOfflineSendEmitsNoTextFrame() async throws {
        vm.configure(context: context)
        let task = try XCTUnwrap(factory.latest)
        vm.currentSessionId = "s1"
        vm.sessionStatuses["s1"] = "idle"
        vm.pendingAttachment = AttachmentData(data: Data([0x89, 0x50, 0x4E, 0x47]), name: "pic.png", mimeType: "image/png")
        vm.sendText()
        let row = try XCTUnwrap(rows(role: "user").first)
        XCTAssertEqual(row.text, "pic.png", "the row keeps effectiveText for display")
        XCTAssertEqual(vm.pendingReasons[row.id], .offline)

        task.completeHandshake()
        await settle()
        task.deliver(Self.s1Idle)
        await settle()

        XCTAssertEqual(try sentTypes(task), ["ping", "list_sessions", "image"],
                       "no spurious message frame carrying the attachment name")
        XCTAssertTrue(vm.pendingReasons.isEmpty)
    }

    func testErrorWithNilSessionIdSetsLastErrorNotBubble() async throws {
        vm.configure(context: context)
        let task = try XCTUnwrap(factory.latest)
        task.completeHandshake()
        await settle()

        task.deliver(#"{"type":"error","message":"bad"}"#)
        await settle()
        XCTAssertEqual(vm.lastError?.text, "bad")
        XCTAssertEqual(try rows(role: "system").count, 0, "no bubble in whichever session is current")

        vm.lastError = nil
        task.deliver(#"{"type":"error","message":"scoped","sessionId":"s1"}"#)
        await settle()
        XCTAssertNil(vm.lastError, "a session-scoped error stays a bubble")
        XCTAssertEqual(try rows(role: "system").count, 1)
        XCTAssertEqual(try rows(role: "system").first?.sessionId, "s1")
    }

    func testAbsentBusySessionGetsSessionEndedCleanup() async throws {
        vm.configure(context: context)
        let task = try XCTUnwrap(factory.latest)
        vm.currentSessionId = "gone"
        vm.sessionStatuses["gone"] = "thinking"
        vm.messageText = "late"
        vm.sendText()
        let rowId = try XCTUnwrap(rows(role: "user").first?.id)
        XCTAssertEqual(vm.pendingReasons[rowId], .offline)

        task.completeHandshake()
        await settle()
        task.deliver(Self.s1Idle)   // `gone` is absent from the full reply
        await settle()

        XCTAssertNil(vm.sessionStatuses["gone"], "non-idle absent session gets the session_ended cleanup")
        XCTAssertTrue(vm.pendingReasons.isEmpty)
        XCTAssertEqual(try messageTexts(task), [], "dropped, not sent")
    }

    /// 15a (⚠6): `unpair()` drops the queue so nothing flushes into the next pairing.
    func testUnpairClearsOfflineQueue() async throws {
        _ = try queueOfflineHi()

        vm.unpair()
        XCTAssertTrue(vm.pendingReasons.isEmpty)
        XCTAssertFalse(vm.isAuthenticated)
        XCTAssertEqual(vm.connectionState, .disconnected)

        credentials.token = "test-token"   // a re-pair
        vm.reconnect()
        let task = try XCTUnwrap(factory.latest)
        XCTAssertEqual(factory.made.count, 2)
        task.completeHandshake()
        await settle()
        task.deliver(Self.s1Idle)
        await settle()
        XCTAssertEqual(try messageTexts(task), [], "nothing queued before the unpair reaches the new pairing")
    }
```

- [ ] **Step 15:** Verify (focused):

```bash
xcodebuild test -project Keepur.xcodeproj -scheme Keepur -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:KeeperTests/ChatViewModelSocketTests -derivedDataPath /tmp/keepur-dd 2>&1 | grep -E "error:|failed|Executed [0-9]+ tests, with|TEST (SUCCEEDED|FAILED)"
```

Expected: `Executed 10 tests, with 0 failures`.

- [ ] **Step 16:** Commit:

```bash
git add ViewModels/ChatViewModel.swift Views/MessageBubble.swift Views/ChatView.swift KeeperTests/ChatViewModelSocketTests.swift
git commit -m "feat(chat): offline send queue with busy/offline reasons, post-reconnect flush gated on session_list, absent-id cleanup (KPR-442)"
```

### Task 5: Beekeeper views — banner mount, `connectionState` reads, picker re-browse

**Files:**
- Modify: `Views/ChatView.swift:73-75` (banner mount)
- Modify: `Views/SessionListView.swift:95`
- Modify: `Views/SettingsView.swift:99-103`, `:187-188`, plus one computed property
- Modify: `Views/WorkspacePickerView.swift:40`, `:46-50`, `:170-176` (`.onChange`)

- [ ] **Step 1:** `Views/ChatView.swift` — make the banner the first child of the outer `VStack(spacing: 0)` (before `ScrollViewReader`). This covers the Sessions tab and the concierge tab (both render `ChatView`):

```swift
        VStack(spacing: 0) {
            KeepurConnectionBanner(
                presentation: .make(state: viewModel.connectionState, error: viewModel.lastError),
                onRetry: { viewModel.reconnect() },
                onDismissError: { viewModel.lastError = nil }
            )

            ScrollViewReader { proxy in
```

- [ ] **Step 2:** `Views/SessionListView.swift:95` — replace `.fill(viewModel.socket.isConnected ? KeepurTheme.Color.success : KeepurTheme.Color.danger)` with:

```swift
                    .fill(viewModel.connectionState == .connected ? KeepurTheme.Color.success : KeepurTheme.Color.danger)
```

- [ ] **Step 3:** `Views/SettingsView.swift` — add this computed property inside `SettingsView` under `// MARK: - Sections` (before `deviceSection`):

```swift
    /// Status row copy + tint by connection state (spec §2 table).
    private var connectionStatus: (label: String, tint: Color) {
        switch viewModel.connectionState {
        case .connected:    return ("Connected",     KeepurTheme.Color.success)
        case .connecting:   return ("Connecting…",   KeepurTheme.Color.warning)
        case .reconnecting: return ("Reconnecting…", KeepurTheme.Color.warning)
        case .disconnected: return ("Disconnected",  KeepurTheme.Color.danger)
        }
    }
```

Replace lines 99–103 (the `Circle()` … `Text(...)` … `.foregroundStyle(...)` trio inside `HStack(spacing: 6)`) with:

```swift
                            Circle()
                                .fill(connectionStatus.tint)
                                .frame(width: 8, height: 8)
                            Text(connectionStatus.label)
                                .foregroundStyle(connectionStatus.tint)
```

Replace lines 187–188 with:

```swift
                Button(viewModel.connectionState == .connected ? "Disconnect" : "Reconnect") {
                    if viewModel.connectionState == .connected {
```

- [ ] **Step 4:** `Views/WorkspacePickerView.swift` — line 40 becomes `if viewModel.connectionState != .connected {`; the Reconnect button (lines 46–50) becomes:

```swift
                            Button("Reconnect") {
                                viewModel.browseError = nil
                                viewModel.reconnect()
                                // No browse() here: it would be dropped while handshaking
                                // (child A's documented interim). The .onChange below re-browses.
                            }
```

and after the `.onAppear { … }` block (line 176) add:

```swift
            .onChange(of: viewModel.connectionState) { _, newState in
                // ⚠5: browse once the handshake lands, whether from Reconnect above or
                // from the picker having appeared while still connecting.
                if newState == .connected {
                    viewModel.browse()
                }
            }
```

- [ ] **Step 5:** Verify the view grep and the iOS build:

```bash
grep -rn 'viewModel\.socket\.' Views
```

Expected: exactly **three** hits — `Views/BeekeeperRootView.swift:176` (doc comment) and `:184`, which Task 6 removes, and `Views/Team/TeamRootView.swift:42` (the Team connection dot), which Task 7 Step 10 removes. Do **not** edit `TeamRootView:42` now: it cannot compile until Task 7 adds `TeamViewModel.connectionState`.

```bash
xcodebuild build -project Keepur.xcodeproj -scheme Keepur -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /tmp/keepur-dd 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 6:** Commit:

```bash
git add Views/ChatView.swift Views/SessionListView.swift Views/SettingsView.swift Views/WorkspacePickerView.swift
git commit -m "feat(views): mount KeepurConnectionBanner in ChatView; views read connectionState, picker re-browses on connect (KPR-442)"
```

### Task 6: Concierge offline cold start (carried-in fix 4) + tests 19, 19a

**Files:**
- Modify: `Views/BeekeeperRootView.swift:42-56` (`.onChange`), `:86-102` (`state`, `start`, `retry`), `:104-116` (`runFlow` head), `:176-187` (`waitForSocketConnected`)
- Test: `KeeperTests/ConciergeViewModelTests.swift` (helper + two cases; migrate line 94)

- [ ] **Step 1:** In `BeekeeperRootView.body`, after the closing brace of the `.task { … }` modifier (the one that calls `cleanupVestigialConciergeRow()` and `concierge.start(...)`; it is the last modifier in `body`, so the insertion sits just before `body`'s own closing brace — locate by content, not line number) add:

```swift
        .onChange(of: viewModel.connectionState) { _, newState in
            // ⚠9: a slow-but-eventually-successful connect after an offline bail re-runs
            // the flow once, so the tab does not sit on "Not connected…" while the banner
            // already says nothing.
            if newState == .connected {
                concierge.retryIfBailedOffline(viewModel: viewModel, store: store)
            }
        }
```

- [ ] **Step 2:** In `ConciergeViewModel`, replace lines 86–102 (`state` through `retry`) with:

```swift
    @Published private(set) var state: State = .loading

    /// True after `runFlow` gave up because the socket was down (nothing sent, cache
    /// kept). Reset by `start`/`retry`; `BeekeeperRootView` re-runs the flow on the
    /// next `.connected` transition (spec ⚠9). No self-heal loop: a flapping link
    /// re-runs at most once per bail.
    private(set) var bailedOffline = false

    private var hasStarted = false
    private static let offlineBailMessage = "Not connected. Retry when reconnected."

    func start(viewModel: ChatViewModel, store: ConciergeSessionStore) {
        // Idempotent: tab `.task` fires on every appear; only run the dance once
        // unless the caller explicitly retries.
        guard !hasStarted else { return }
        hasStarted = true
        bailedOffline = false
        state = .loading
        Task { await runFlow(viewModel: viewModel, store: store) }
    }

    func retry(viewModel: ChatViewModel, store: ConciergeSessionStore) {
        hasStarted = false
        start(viewModel: viewModel, store: store)
    }

    /// What `BeekeeperRootView`'s `.onChange(of: connectionState)` calls: re-run only
    /// after an offline bail and only once actually connected. Unit-reachable so the
    /// predicate is tested without the view.
    func retryIfBailedOffline(viewModel: ChatViewModel, store: ConciergeSessionStore) {
        guard bailedOffline, viewModel.connectionState == .connected else { return }
        retry(viewModel: viewModel, store: store)
    }
```

- [ ] **Step 3:** Replace the head of `runFlow` — the long comment plus `await waitForSocketConnected(viewModel: viewModel, timeoutSeconds: 5)` (lines 105–116) — with:

```swift
        // Cold start races this task against the socket handshake: the tab's `.task`
        // fires `start()` → `runFlow` as soon as the view appears, while `configure()`
        // has only just called `connect()`. Sending into `.connecting` is a silent
        // no-op (`BeekeeperSocket.send` returns `false`), which used to lose the
        // cache-hit `resume_session` and spawn duplicates. Wait for the connection.
        // If the socket is definitively down (`.disconnected` after a connect request:
        // not paired, host unconfigured, token retries exhausted) bail right away —
        // without sending and WITHOUT `store.clear()`; the old flow would burn
        // 3 s + 3 s + 5 s of dead timeouts and wipe the cached concierge id.
        let connected = await waitForSocketConnected(viewModel: viewModel, timeoutSeconds: 5)
        // The transition may have landed in the timeout's own turn; re-read before bailing.
        if !connected, viewModel.connectionState != .connected {
            bailedOffline = true
            state = .error(Self.offlineBailMessage)
            return
        }
```

- [ ] **Step 4:** Replace `waitForSocketConnected` and its doc comment (lines 176–187) with:

```swift
    /// Consumes `viewModel.$connectionState` (no polling, no `socket` read). Returns
    /// `true` on `.connected`; `false` immediately on `.disconnected` once the VM has
    /// asked the socket to connect (nothing is in flight), or when the timeout elapses
    /// while still `.connecting`/`.reconnecting` — waiting through `.reconnecting` is
    /// deliberate: on a flaky cold start the first 2 s backoff often lands inside the
    /// budget. A `.disconnected` seen before any connect request is the cold initial
    /// value, not a failure, so the result does not depend on `configure()` having run
    /// before the tab's `.task` (ordering-proof). The `.disconnected` case also re-reads
    /// `viewModel.connectionState` live rather than trusting the buffered value alone:
    /// `AsyncPublisher` can hand this loop a stale `.disconnected` on a main-actor turn
    /// after `configure()`/`reconnect()` has already flipped the socket to `.connecting`
    /// (that emission just has not been consumed yet); without the re-read the flow
    /// would bail "Not connected…" while a connect is in flight. The buffered
    /// `.connecting`, if any, arrives on the next iteration and the wait continues.
    private func waitForSocketConnected(viewModel: ChatViewModel, timeoutSeconds: Double) async -> Bool {
        await withTaskGroup(of: Bool?.self) { group in
            group.addTask { @MainActor in
                for await state in viewModel.$connectionState.values {
                    switch state {
                    case .connected:
                        return true
                    case .disconnected where viewModel.hasRequestedConnection && viewModel.connectionState == .disconnected:
                        return false
                    case .disconnected, .connecting, .reconnecting:
                        continue
                    }
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()   // AsyncPublisher honours cancellation; the loser finishes
            return first ?? false
        }
    }
```

- [ ] **Step 5:** In `KeeperTests/ConciergeViewModelTests.swift`: change line 94 to `XCTAssertEqual(vm.connectionState, .connected)`; in `setUp` replace the socket/vm construction (lines 26–33) with a call `makeViewModel()`; add these helpers after `sentTypes(_:)`:

```swift
    /// (Re)build `vm` on a socket with the given token-read config; `setUp` uses the defaults.
    private func makeViewModel(tokenReadRetryDelay: Duration = .seconds(2), maxTokenReadRetries: Int = 3) {
        var config = BeekeeperSocket.Config.standard
        config.tokenReadRetryDelay = tokenReadRetryDelay
        config.maxTokenReadRetries = maxTokenReadRetries
        let factory = self.factory!
        let socket = BeekeeperSocket(
            config: config,
            credentials: credentials,
            endpoint: { URL(string: "wss://unit.test")! },
            taskFactory: { factory.make(url: $0) }   // closure literal, not `factory.make`
        )
        vm = ChatViewModel(socket: socket, credentials: credentials)
    }

    private func waitUntil(timeoutMs: Int, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .milliseconds(timeoutMs)
        while !condition() && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Test 19's setup: a configured-but-unpaired VM whose flow has bailed offline.
    private func bailOffline() async throws -> (store: ConciergeSessionStore, concierge: ConciergeViewModel) {
        makeViewModel(tokenReadRetryDelay: .milliseconds(1), maxTokenReadRetries: 1)
        credentials.token = nil
        let store = ConciergeSessionStore(defaults: defaults)
        store.cache(sessionId: "cached-session", path: "/cached/path")

        vm.configure(context: context)   // configured, so the bail comes from state, not from ordering
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(vm.connectionState, .disconnected)

        let concierge = ConciergeViewModel()
        concierge.start(viewModel: vm, store: store)
        try await waitUntil(timeoutMs: 500) {
            if case .error = concierge.state { return true }
            return false
        }
        return (store, concierge)
    }
```

- [ ] **Step 6:** Append the two tests before the class's closing brace:

```swift
    /// 19: offline cold start bails at once — no sends, no dead timeouts, cache kept.
    func testRunFlowBailsWithoutClearingCacheWhenDisconnected() async throws {
        let (store, concierge) = try await bailOffline()

        XCTAssertEqual(concierge.state, .error("Not connected. Retry when reconnected."))
        XCTAssertTrue(concierge.bailedOffline)
        XCTAssertNotNil(store.cachedSession, "an offline bail must not wipe the cached concierge id")
        XCTAssertEqual(factory.made.count, 0, "nothing was opened or sent")
    }

    /// 19a (⚠9): the next `.connected` re-runs the flow once via the view's `.onChange` hook.
    func testBailedFlowRerunsOnConnected() async throws {
        let (store, concierge) = try await bailOffline()

        credentials.token = "test-token"
        vm.reconnect()
        let task = try XCTUnwrap(factory.latest)
        task.completeHandshake()
        await settle()
        XCTAssertEqual(vm.connectionState, .connected)

        concierge.retryIfBailedOffline(viewModel: vm, store: store)   // what BeekeeperRootView's .onChange calls
        try await waitUntil(timeoutMs: 500) { (try? self.sentTypes(task))?.contains("resume_session") == true }

        XCTAssertFalse(concierge.bailedOffline)
        XCTAssertEqual(try sentTypes(task), ["ping", "list_sessions", "resume_session"],
                       "the flow re-ran from the top with the cache hit")
        XCTAssertNotNil(store.cachedSession)

        task.deliver(#"{"type":"session_info","sessionId":"cached-session","path":"/cached/path","mode":"concierge"}"#)
        try await waitUntil(timeoutMs: 500) { concierge.state == .ready(sessionId: "cached-session", path: "/cached/path") }
        XCTAssertEqual(concierge.state, .ready(sessionId: "cached-session", path: "/cached/path"))

        concierge.retryIfBailedOffline(viewModel: vm, store: store)   // not bailed: must be a no-op
        XCTAssertEqual(concierge.state, .ready(sessionId: "cached-session", path: "/cached/path"))
    }
```

- [ ] **Step 7:** Verify:

```bash
grep -rn 'viewModel\.socket\.' Views
```

Expected: exactly one hit, `Views/Team/TeamRootView.swift:42` — the Team connection dot, which Task 7 Step 10 migrates (leave it; it needs `TeamViewModel.connectionState`). Task 9 Step 1, which runs after Task 7, is the gate that must print nothing.

```bash
xcodebuild test -project Keepur.xcodeproj -scheme Keepur -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:KeeperTests/ConciergeViewModelTests -derivedDataPath /tmp/keepur-dd 2>&1 | grep -E "error:|failed|Executed [0-9]+ tests, with|TEST (SUCCEEDED|FAILED)"
```

Expected: `Executed 3 tests, with 0 failures` (test 20 — `testRunFlowWaitsForHandshakeBeforeCacheHitResume` — unchanged and green).

- [ ] **Step 8:** Commit:

```bash
git add Views/BeekeeperRootView.swift KeeperTests/ConciergeViewModelTests.swift
git commit -m "fix(concierge): observe connectionState, bail offline without wiping the cache, re-run on connect (KPR-442)"
```

### Task 7: `TeamViewModel` connection surface + hive-scoped offline queue; `TeamRootView` banner

**Files:**
- Modify: `ViewModels/TeamViewModel.swift:36-37` (`disconnectedBanner`), `:42-53` (internal state), `:55-83` (`init`/`configure`), `:93-159` (`connectIfPossible` … `disconnect`), `:172-177` (`sendWithId`), `:181-227` (`sendMessage`), `:295-325` (`onConnected`/`handleAuthFailure`), `:329-367` (slash / DM), `:466-469` (`.error`)
- Modify: `Views/Team/TeamRootView.swift:11-31` (banner), `:42` (dot)

`TeamRootView` is edited in this task (not Task 8) because deleting `disconnectedBanner` would otherwise leave the tree uncompilable between commits.

- [ ] **Step 1:** Replace lines 36–37 (`weak var capabilityManager…` stays; `@Published var disconnectedBanner: String?` goes) with:

```swift
    weak var capabilityManager: CapabilityManager?

    /// Mirrors `socket.$state`; views observe this, never `socket` directly.
    @Published private(set) var connectionState: BeekeeperSocket.State = .disconnected
    /// Banner-consumed. Auto-clears after `lastErrorAutoClear` or on tap (set to nil).
    @Published var lastError: UserFacingError? {
        didSet {
            lastErrorTimer?.cancel()
            lastErrorTimer = nil
            guard let id = lastError?.id else { return }
            let delay = lastErrorAutoClear
            lastErrorTimer = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self, self.lastError?.id == id else { return }
                self.lastError = nil
            }
        }
    }

    struct OfflineEntry: Equatable {
        let localId: String
        let hive: String   // the socket channel the message was written for
    }
    /// Never-sent and un-acked messages in send order (⚠2). Hive-scoped: an entry is
    /// re-sent only by an `onConnected` for the hive it was written for; it is never
    /// delivered into another hive (§7 *Hive switch*). Whole-queue clears happen only
    /// on auth failure (⚠6); a single entry is dropped only if its row is gone at re-send.
    @Published private(set) var offlineEntries: [OfflineEntry] = []
    /// Projection for views (bubble badge) and tests.
    var offlineMessageIds: [String] { offlineEntries.map(\.localId) }
```

- [ ] **Step 2:** In `// MARK: - Internal State`, delete `private var previousSocketState: BeekeeperSocket.State = .disconnected` and, after `private var pendingDMRequestId: String?`, add:

```swift
    private var offlineAttachments: [String: AttachmentData] = [:]   // localId → attachment, in-memory only
    /// Channel of the last `socket.connect(channel:)`, assigned AFTER that call returns:
    /// a connected→connected hive switch emits `.connecting` synchronously inside
    /// `connect`, and that transition must stamp un-acked entries with the hive they
    /// were *sent to*, not the one being connected. Never cleared by `disconnect()` or
    /// the hive-vanished path — an entry queued while `.disconnected` still belongs to
    /// the hive the user is looking at. The `?? ""` fallbacks below never match a hive
    /// and so can only leave an entry queued, never misroute it.
    private var activeHive: String?
    private var lastErrorTimer: Task<Void, Never>?
    private let lastErrorAutoClear: Duration
    private static let notConnectedText = "Not connected. Try again when reconnected."
```

- [ ] **Step 3:** Replace `init` and `configure` (lines 55–83) with:

```swift
    init(
        socket: BeekeeperSocket? = nil,
        credentials: CredentialStore = KeychainCredentialStore(),
        lastErrorAutoClear: Duration = .seconds(6)
    ) {
        self.socket = socket ?? BeekeeperSocket(config: .standard, credentials: credentials)
        self.credentials = credentials
        self.lastErrorAutoClear = lastErrorAutoClear
        // In init, not configure: Settings observes truth before configure runs. The
        // `capabilityManager` uses in the handler are `guard let`-safe before configure.
        self.socket.$state
            .sink { [weak self] state in self?.handleSocketState(state) }
            .store(in: &subscriptions)
    }

    // MARK: - Setup

    func configure(context: ModelContext, capabilityManager: CapabilityManager) {
        guard modelContext == nil else { return }  // Idempotency guard
        self.modelContext = context
        self.capabilityManager = capabilityManager

        socket.frames
            .sink { [weak self] data in self?.handleFrame(data) }
            .store(in: &subscriptions)
        socket.onAuthFailure = { [weak self] in
            self?.handleAuthFailure()
        }
        socket.onConnected = { [weak self] in
            self?.onConnected()
        }
    }
```

- [ ] **Step 4:** Replace everything from `func connectIfPossible()` through the end of `disconnect()` (lines 93–159) with:

```swift
    func connectIfPossible() {
        guard let manager = capabilityManager,
              let channel = manager.selectedHive,
              manager.hives.contains(channel) else {
            Log.team.info("connectIfPossible: no valid selectedHive; disconnecting")
            socket.disconnect()
            return
        }
        Log.team.info("connectIfPossible: channel=\(channel, privacy: .public)")
        socket.connect(channel: channel)
        activeHive = channel   // after connect returns — see the activeHive doc comment
    }

    /// Foregrounding, the Settings button and the banner's Retry call this; during
    /// backoff it attempts immediately, keeping the attempt count.
    func reconnect() {
        connectIfPossible()
    }

    /// The banner is state-driven (`connectionState`), so nothing is re-set here. Two
    /// hooks: leaving `.connected` moves sent-but-un-acked messages into the offline
    /// queue; the first `.reconnecting` of a loss runs the hive-vanished check (once
    /// per loss — child A's documented deviation). NEVER call `socket.send` from here:
    /// @Published emits on willSet, so the socket's gate still reads the old state.
    private func handleSocketState(_ state: BeekeeperSocket.State) {
        let previous = connectionState
        connectionState = state
        if previous == .connected, state != .connected {
            moveUnackedToOffline()
        }
        if case .reconnecting(let attempt) = state, state != previous, attempt == 1 {
            refreshCapabilitiesAfterConnectionLost()
        }
    }

    private func refreshCapabilitiesAfterConnectionLost() {
        guard let manager = capabilityManager else { return }
        Task { [weak self] in
            await manager.refresh()
            guard let self else { return }
            if let current = manager.selectedHive, manager.hives.contains(current) {
                // Hive still exists; the socket keeps backing off and the banner offers retry-now.
            } else {
                // After the 6 s auto-clear the banner falls back to "Not connected… Retry";
                // Retry → connectIfPossible() → no valid hive → disconnect(). Accepted (§7).
                self.lastError = UserFacingError("This hive is no longer available.")
                self.socket.disconnect()
            }
        }
    }

    /// Clears no queue state on purpose: entries keep their hive stamp and go out on
    /// the next connect to that hive (§7 *Hive switch*).
    func disconnect() {
        pendingAgentDM = nil
        pendingDMRequestId = nil
        socket.disconnect()
    }
```

- [ ] **Step 5:** In `sendMessage(text:)`, replace the block from `if let requestId = sendWithId(.teamMessage(...)) {` through the attachment `if let attachment { … }` (lines 210–220) with:

```swift
        if connectionState == .connected,
           let requestId = sendWithId(.teamMessage(channelId: channelId, text: trimmed, threadId: nil)) {
            pendingMessageIds[requestId] = localId
            if let attachment {
                sendAttachment(attachment, channelId: channelId)   // untracked, as today
            }
        } else {
            offlineEntries.append(OfflineEntry(localId: localId, hive: activeHive ?? ""))
            if let attachment {
                offlineAttachments[localId] = attachment
            }
        }
```

- [ ] **Step 6:** After `sendWithId` (line 177) add the attachment helper and, at the end of `// MARK: - Sending`, nothing else:

```swift
    private func sendAttachment(_ attachment: AttachmentData, channelId: String) {
        let base64 = attachment.data.base64EncodedString()
        if attachment.mimeType.hasPrefix("image/") {
            _ = sendWithId(.teamImage(channelId: channelId, data: base64, filename: attachment.name))
        } else {
            _ = sendWithId(.teamFile(channelId: channelId, data: base64, filename: attachment.name, mimetype: attachment.mimeType))
        }
    }
```

- [ ] **Step 7:** Replace `onConnected()` and `handleAuthFailure()` (lines 295–325) with:

```swift
    private func onConnected() {
        pendingAgentDM = nil
        pendingDMRequestId = nil
        fetchChannels()
        send(.agentList)
        send(.commandList)
        // Reconnect gap-fill: fetch latest messages for the active channel.
        // Use fetchHistory (not direct send) so cursor and loading state
        // are managed correctly and we don't race with seeding fetches.
        if let channelId = activeChannelId {
            // Reset cursor so we get the latest page, not stale pagination
            if let context = modelContext {
                let cid = channelId
                let descriptor = FetchDescriptor<TeamChannel>(
                    predicate: #Predicate { $0.id == cid }
                )
                if let channel = try? context.fetch(descriptor).first {
                    channel.lastServerMessageId = nil
                }
            }
            fetchHistory(channelId: channelId)
        }
        // Bookkeeping frames first, then the offline queue for this hive (§7).
        resendOfflineEntries()
    }

    private func handleAuthFailure() {
        socket.disconnect()
        // Don't clear credentials here — ContentView observes `isAuthenticated`
        // and calls `chatViewModel.unpair()`, which owns that.
        isAuthenticated = false
        // ⚠6: the VM outlives a re-pair; nothing queued may flush into the new pairing.
        // The transition-out move has already run (the socket set .disconnected before
        // calling onAuthFailure), so this also drains what was un-acked.
        offlineEntries.removeAll()
        offlineAttachments.removeAll()
        pendingMessageIds.removeAll()
    }

    // MARK: - Private: Offline queue

    /// Leaving `.connected`: every sent-but-un-acked message re-sends on the next
    /// connect to this hive rather than staying "sending" forever. Ordered by the row's
    /// `createdAt`; ids whose row is already gone are appended and dropped at re-send.
    private func moveUnackedToOffline() {
        guard !pendingMessageIds.isEmpty else { return }
        let localIds = Array(pendingMessageIds.values)
        pendingMessageIds.removeAll()
        let hive = activeHive ?? ""

        var ordered: [String] = []
        if let context = modelContext {
            let ids = localIds
            let descriptor = FetchDescriptor<TeamMessage>(
                predicate: #Predicate { ids.contains($0.id) },
                sortBy: [SortDescriptor(\TeamMessage.createdAt)]
            )
            ordered = ((try? context.fetch(descriptor)) ?? []).map(\.id)
        }
        for id in localIds where !ordered.contains(id) {
            ordered.append(id)
        }
        for id in ordered where !offlineEntries.contains(where: { $0.localId == id }) {
            offlineEntries.append(OfflineEntry(localId: id, hive: hive))
        }
    }

    /// End of `onConnected()`: re-send, in order, only the entries stamped with the hive
    /// just connected. A missing row (channel archived/left meanwhile) drops the entry;
    /// a `sendWithId` nil stops the pass and leaves the rest queued.
    private func resendOfflineEntries() {
        guard let context = modelContext, let hive = activeHive else { return }
        for entry in offlineEntries where entry.hive == hive {
            let lid = entry.localId
            let descriptor = FetchDescriptor<TeamMessage>(
                predicate: #Predicate { $0.id == lid }
            )
            guard let row = try? context.fetch(descriptor).first else {
                offlineEntries.removeAll { $0.localId == lid }
                offlineAttachments.removeValue(forKey: lid)
                continue
            }
            guard let requestId = sendWithId(.teamMessage(channelId: row.channelId, text: row.text, threadId: row.threadId)) else {
                break
            }
            pendingMessageIds[requestId] = lid
            if let attachment = offlineAttachments.removeValue(forKey: lid) {
                sendAttachment(attachment, channelId: row.channelId)
            }
            offlineEntries.removeAll { $0.localId == lid }
        }
    }
```

- [ ] **Step 8:** In `sendSlashCommand`, replace `if let requestId = sendWithId(command) { … }` (lines 339–345) with:

```swift
        guard connectionState == .connected, let requestId = sendWithId(command) else {
            lastError = UserFacingError(Self.notConnectedText)   // no pending* state touched
            return
        }
        pendingCommandChannels[requestId] = channelId
        // Track /new commands for auto-refresh
        if commandName == "new" || commandName == "dm" {
            pendingNewCommands.insert(requestId)
        }
```

In `openAgentDM`, replace `guard let requestId = sendWithId(command) else { return }  // offline — no-op` with:

```swift
        guard connectionState == .connected, let requestId = sendWithId(command) else {
            lastError = UserFacingError(Self.notConnectedText)
            return
        }
```

- [ ] **Step 9:** In `handleIncoming`, replace the `.error` case with:

```swift
        case .error(let message):
            pendingAgentDM = nil
            pendingDMRequestId = nil
            Log.team.error("server error: \(message, privacy: .private)")
            lastError = UserFacingError(message)
```

- [ ] **Step 10:** `Views/Team/TeamRootView.swift` — replace the `if let banner = viewModel.disconnectedBanner { … }` block (lines 11–31) with the banner in the same slot ⚠1 (outside the navigation stack, so it stays visible on the pushed `TeamChatView` and the sidebar-only state; `TeamChatView` mounts no second one):

```swift
            KeepurConnectionBanner(
                presentation: .make(state: viewModel.connectionState, error: viewModel.lastError),
                onRetry: { viewModel.reconnect() },
                onDismissError: { viewModel.lastError = nil }
            )
```

and line 42 becomes:

```swift
                                .fill(viewModel.connectionState == .connected ? KeepurTheme.Color.success : KeepurTheme.Color.danger)
```

- [ ] **Step 11:** Verify the deletions and the build. `TeamViewModelTests` is expected to **fail to compile** at this point (it still references `disconnectedBanner`/`retryConnect`; Task 8 rewrites it), so build the app target only:

```bash
grep -rn 'disconnectedBanner\|retryConnect\|handleConnectionLost\|previousSocketState' Views ViewModels Managers Models
xcodebuild build -project Keepur.xcodeproj -scheme Keepur -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /tmp/keepur-dd 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
```

Expected: the grep prints nothing; `BUILD SUCCEEDED`.

- [ ] **Step 12:** Commit:

```bash
git add ViewModels/TeamViewModel.swift Views/Team/TeamRootView.swift
git commit -m "feat(team): connectionState/lastError, hive-scoped offline re-send queue, banner replaces disconnectedBanner (KPR-442)"
```

### Task 8: Team bubble `isOffline`, `TeamChatView` wiring, `TeamViewModelTests` 7–11b, bubble smoke

**Files:**
- Modify: `Views/Team/TeamMessageBubble.swift:6-7`, `:40-51`
- Modify: `Views/Team/TeamChatView.swift:166-172`
- Test: `KeeperTests/TeamViewModelTests.swift` (rewrite: helpers, replace `testBannerReturnsAfterFailedManualRetry` with test 9, add 7, 8, 8a, 10, 11, 11a, 11b)
- Test: `KeeperTests/TeamMessageBubbleTests.swift:28-34`

- [ ] **Step 1:** `Views/Team/TeamMessageBubble.swift` — after `let isOwnMessage: Bool` (line 6) add `var isOffline: Bool = false` (before `onSpeak`, so existing `TeamMessageBubble(message:isOwnMessage:onSpeak:)` call sites keep compiling), and replace the `if message.pending { Text("sending") … }` block (lines 40–51) with:

```swift
                    if isOffline || message.pending {
                        let badgeText = isOffline ? "not sent" : "sending"
                        Text(badgeText)
                            .font(KeepurTheme.Font.caption)
                            .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
                            .padding(.horizontal, KeepurTheme.Spacing.s2)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(KeepurTheme.Color.honey200))
                            .offset(x: 4, y: 4)
                            .opacity(isPulsing ? 0.6 : 1.0)
                            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: isPulsing)
                            .onAppear { isPulsing = true }
                            .accessibilityLabel(badgeText)
                    }
```

- [ ] **Step 2:** `Views/Team/TeamChatView.swift` — the bubble call becomes:

```swift
                        TeamMessageBubble(
                            message: message,
                            isOwnMessage: message.senderId == deviceId,
                            isOffline: viewModel.offlineMessageIds.contains(message.id),
                            onSpeak: message.senderType == "agent" && message.senderId != "system" ? { text in
                                viewModel.speechManager?.speak(text, agentId: message.senderId)
                            } : nil
                        )
```

- [ ] **Step 3:** `KeeperTests/TeamMessageBubbleTests.swift` — in `testUserBubbleInstantiates` add after the `pending` instantiation:

```swift
        _ = TeamMessageBubble(message: pending, isOwnMessage: true, isOffline: true).body
```

- [ ] **Step 4:** Rewrite `KeeperTests/TeamViewModelTests.swift` in full (the `setUp` seam, `testDeviceIdFollowsCredentialStore` and its rationale are kept verbatim; `testBannerReturnsAfterFailedManualRetry` is replaced by test 9):

```swift
import XCTest
import SwiftData
@testable import Keepur

/// `TeamViewModel` on an injected `BeekeeperSocket` driven by the fake task: the
/// stale-`deviceId` fix from child A, and child B's `connectionState` forwarding,
/// `lastError`, and hive-scoped offline queue.
///
/// Every case that connects inherits the cross-suite `KeychainManager.token` ordering
/// dependency (#102) through `refreshCapabilitiesAfterConnectionLost`'s real
/// `manager.refresh()`; B does not fix it and must not add a second one. Seeding a hive
/// with `_setHivesForTesting` is required, not incidental: `connectIfPossible()` needs a
/// valid `selectedHive`, and on the first `.reconnecting` the refresh fails in tests (no
/// token) leaving `hives`/`selectedHive` untouched, so it takes the harmless "hive still
/// exists" path instead of the hive-vanished branch.
@MainActor
final class TeamViewModelTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var credentials: FakeCredentialStore!
    private var factory: FakeWebSocketTaskFactory!
    private var capability: CapabilityManager!   // held here: TeamViewModel keeps it weak
    private var vm: TeamViewModel!

    override func setUp() async throws {
        UserDefaults.standard.removeObject(forKey: "selectedHive")
        let schema = Schema([TeamChannel.self, TeamMessage.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [config])
        context = ModelContext(container)
        credentials = FakeCredentialStore(deviceId: "device-old")
        factory = FakeWebSocketTaskFactory()
        capability = CapabilityManager()
        makeViewModel()
    }

    override func tearDown() async throws {
        vm = nil
        capability = nil
        context = nil
        container = nil
        UserDefaults.standard.removeObject(forKey: "selectedHive")
    }

    // MARK: - Helpers

    /// (Re)build `vm` on a fresh socket; `setUp` uses the default auto-clear.
    private func makeViewModel(lastErrorAutoClear: Duration = .seconds(6)) {
        let factory = self.factory!
        let socket = BeekeeperSocket(
            config: .standard,
            credentials: credentials,
            endpoint: { URL(string: "wss://unit.test")! },
            taskFactory: { factory.make(url: $0) }   // closure literal, not `factory.make`
        )
        vm = TeamViewModel(socket: socket, credentials: credentials, lastErrorAutoClear: lastErrorAutoClear)
        vm.configure(context: context, capabilityManager: capability)
        vm.activeChannelId = "channel-1"
    }

    private func senderIdsByText() throws -> [String: String] {
        let rows = try context.fetch(FetchDescriptor<TeamMessage>())
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.text, $0.senderId) })
    }

    private func rows() throws -> [TeamMessage] {
        try context.fetch(FetchDescriptor<TeamMessage>())
    }

    /// Let the socket's `Task { @MainActor in … }` hops run.
    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
    }

    private func sentFrames(_ task: FakeWebSocketTask) throws -> [[String: Any]] {
        try task.sentTexts.map { text in
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        }
    }

    /// `(id, text)` of every `message` frame on the task, in order.
    private func messageFrames(_ task: FakeWebSocketTask) throws -> [(id: String, text: String)] {
        try sentFrames(task)
            .filter { $0["type"] as? String == "message" }
            .map { (id: try XCTUnwrap($0["id"] as? String), text: try XCTUnwrap($0["text"] as? String)) }
    }

    /// Seed one hive, connect, complete the handshake on the first task.
    private func connectHive1() async throws -> FakeWebSocketTask {
        capability._setHivesForTesting(["hive-1"])
        XCTAssertEqual(capability.selectedHive, "hive-1")
        vm.connectIfPossible()
        let task = try XCTUnwrap(factory.latest)
        task.completeHandshake()
        await settle()
        XCTAssertEqual(vm.connectionState, .connected)
        return task
    }

    // MARK: - Child A

    /// Sends before any `connectIfPossible()`: the rows are stamped `""`, stay queued
    /// and `pending: true` by design (§7) — exactly what this asserts; unchanged by B.
    func testDeviceIdFollowsCredentialStore() throws {
        vm.sendMessage(text: "first")
        credentials.deviceId = "device-new"     // what a re-pair does
        vm.sendMessage(text: "second")

        let senders = try senderIdsByText()
        XCTAssertEqual(senders, ["first": "device-old", "second": "device-new"],
                       "sender id must be read at send time, not captured in configure")
        let rows = try context.fetch(FetchDescriptor<TeamMessage>())
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy(\.pending), "socket never connected, so nothing was acked")
    }

    // MARK: - Child B: connection state

    /// 9 (replaces testBannerReturnsAfterFailedManualRetry): the banner is now
    /// state-driven, and `reconnect()` during backoff opens a fresh task at once.
    func testConnectionStateFollowsSocketAndRetryOpensFreshTask() async throws {
        capability._setHivesForTesting(["hive-1"])
        vm.connectIfPossible()
        let firstTask = try XCTUnwrap(factory.latest)
        XCTAssertTrue(firstTask.url.absoluteString.hasSuffix("&channel=hive-1"))
        XCTAssertEqual(vm.connectionState, .connecting)
        firstTask.completeHandshake(error: URLError(.networkConnectionLost))
        await settle()
        XCTAssertEqual(vm.connectionState, .reconnecting(attempt: 1))

        vm.reconnect()
        XCTAssertEqual(factory.made.count, 2, "retry must open a fresh task immediately, during backoff")
        let secondTask = try XCTUnwrap(factory.latest)
        XCTAssertFalse(secondTask === firstTask)
        secondTask.completeHandshake(error: URLError(.networkConnectionLost))
        await settle()
        XCTAssertEqual(vm.connectionState, .reconnecting(attempt: 2))
    }

    /// 10
    func testSlashCommandWhileOfflineSetsLastError() throws {
        vm.messageText = "/new x"
        vm.sendMessage(text: "/new x")

        XCTAssertEqual(vm.lastError?.text, "Not connected. Try again when reconnected.")
        XCTAssertTrue(try rows().isEmpty, "slash commands insert no row")
        XCTAssertEqual(vm.messageText, "")
    }

    /// 11
    func testErrorFrameSetsLastError() async throws {
        let task = try await connectHive1()
        task.deliver(#"{"type":"error","message":"nope"}"#)
        await settle()
        XCTAssertEqual(vm.lastError?.text, "nope")
    }

    /// 11b
    func testLastErrorAutoClears() async throws {
        makeViewModel(lastErrorAutoClear: .milliseconds(50))
        let task = try await connectHive1()

        task.deliver(#"{"type":"error","message":"nope"}"#)
        await settle()
        XCTAssertNotNil(vm.lastError)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(vm.lastError, "auto-cleared after the injected delay")

        task.deliver(#"{"type":"error","message":"again"}"#)
        await settle()
        XCTAssertEqual(vm.lastError?.text, "again")
        vm.lastError = nil                           // banner tap before the deadline
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(vm.lastError, "a manual dismiss must not crash or resurrect the value")
    }

    // MARK: - Child B: offline queue

    /// 7: the real cold-start route — connect first (stamps `activeHive`), send during
    /// `.connecting`, re-send after the handshake's bookkeeping frames, ack flips pending.
    func testOfflineSendIsQueuedAndResentOnReconnect() async throws {
        capability._setHivesForTesting(["hive-1"])
        vm.connectIfPossible()
        let task = try XCTUnwrap(factory.latest)
        XCTAssertEqual(factory.made.count, 1)
        XCTAssertEqual(vm.connectionState, .connecting)

        vm.sendMessage(text: "hello")
        let row = try XCTUnwrap(rows().first)
        XCTAssertTrue(row.pending)
        XCTAssertEqual(vm.offlineMessageIds, [row.id])
        XCTAssertTrue(try messageFrames(task).isEmpty, "nothing is sent before the handshake")

        task.completeHandshake()
        await settle()
        let frames = try messageFrames(task)
        XCTAssertEqual(frames.map(\.text), ["hello"])
        XCTAssertTrue(vm.offlineMessageIds.isEmpty)
        let types = try sentFrames(task).compactMap { $0["type"] as? String }
        XCTAssertEqual(types.last, "message", "the re-send comes after the bookkeeping frames")

        task.deliver(#"{"type":"ack","id":"\#(frames[0].id)"}"#)
        await settle()
        XCTAssertFalse(try XCTUnwrap(rows().first).pending)
    }

    /// 8: same-hive reconnect re-sends what was un-acked when the link dropped.
    func testUnackedMessagesMoveToOfflineOnDisconnect() async throws {
        let first = try await connectHive1()
        vm.sendMessage(text: "a")
        let row = try XCTUnwrap(rows().first)
        let firstFrames = try messageFrames(first)
        XCTAssertEqual(firstFrames.map(\.text), ["a"])
        XCTAssertTrue(row.pending)
        XCTAssertTrue(vm.offlineMessageIds.isEmpty)

        first.failReceive(closeCode: .abnormalClosure)
        await settle()
        XCTAssertEqual(vm.connectionState, .reconnecting(attempt: 1))
        XCTAssertEqual(vm.offlineMessageIds, [row.id], "un-acked moves to offline on leaving .connected")

        vm.reconnect()                               // same selectedHive, during backoff
        let second = try XCTUnwrap(factory.latest)
        XCTAssertFalse(second === first)
        second.completeHandshake()
        await settle()
        let resent = try messageFrames(second)
        XCTAssertEqual(resent.map(\.text), ["a"])
        XCTAssertNotEqual(resent[0].id, firstFrames[0].id, "a fresh request id")
        XCTAssertTrue(vm.offlineMessageIds.isEmpty)

        second.deliver(#"{"type":"ack","id":"\#(resent[0].id)"}"#)
        await settle()
        XCTAssertFalse(try XCTUnwrap(rows().first).pending)
    }

    /// 8a: a hive switch never delivers a queued message into another hive; returning
    /// to the original hive delivers it.
    func testQueuedEntriesAreNotResentIntoAnotherHive() async throws {
        capability._setHivesForTesting(["hive-1", "hive-2"])
        capability.selectedHive = "hive-1"
        vm.connectIfPossible()
        let first = try XCTUnwrap(factory.latest)
        XCTAssertTrue(first.url.absoluteString.hasSuffix("&channel=hive-1"))
        first.completeHandshake()
        await settle()
        vm.sendMessage(text: "a")                    // sent, never acked
        let row = try XCTUnwrap(rows().first)

        vm.disconnect()                              // what the hive-grid pop does
        XCTAssertEqual(vm.connectionState, .disconnected)
        XCTAssertEqual(vm.offlineMessageIds, [row.id])

        capability.selectedHive = "hive-2"
        vm.connectIfPossible()
        let second = try XCTUnwrap(factory.latest)
        XCTAssertTrue(second.url.absoluteString.hasSuffix("&channel=hive-2"))
        second.completeHandshake()
        await settle()
        XCTAssertTrue(try messageFrames(second).isEmpty, "written for hive-1: must not go into hive-2")
        XCTAssertEqual(vm.offlineMessageIds, [row.id])
        XCTAssertTrue(try XCTUnwrap(rows().first).pending)

        capability.selectedHive = "hive-1"
        vm.connectIfPossible()                       // connected→connected channel switch
        let third = try XCTUnwrap(factory.latest)
        XCTAssertEqual(factory.made.count, 3)
        third.completeHandshake()
        await settle()
        XCTAssertEqual(try messageFrames(third).map(\.text), ["a"])
        XCTAssertTrue(vm.offlineMessageIds.isEmpty)
    }

    /// 11a (⚠6): auth failure clears both the offline queue and the un-acked map.
    /// Asserts `offlineMessageIds` (the queue), not the private request-id map;
    /// the second connect proves the latter was cleared too.
    func testAuthFailureClearsOfflineQueues() async throws {
        let first = try await connectHive1()
        vm.sendMessage(text: "a")
        XCTAssertEqual(try messageFrames(first).map(\.text), ["a"])

        first.failReceive(closeCode: URLSessionWebSocketTask.CloseCode(rawValue: 4001)!)
        await settle()
        XCTAssertFalse(vm.isAuthenticated)
        XCTAssertEqual(vm.connectionState, .disconnected)
        XCTAssertTrue(vm.offlineMessageIds.isEmpty, "the transition-out move ran, then the auth-failure clear")

        vm.connectIfPossible()                       // a re-pair reconnects the same VM
        let second = try XCTUnwrap(factory.latest)
        XCTAssertEqual(factory.made.count, 2)
        second.completeHandshake()
        await settle()
        XCTAssertTrue(try messageFrames(second).isEmpty, "nothing from the old pairing is re-sent")
    }
}
```

- [ ] **Step 5:** Verify (focused, both suites):

```bash
xcodebuild test -project Keepur.xcodeproj -scheme Keepur -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:KeeperTests/TeamViewModelTests -only-testing:KeeperTests/TeamMessageBubbleTests \
  -derivedDataPath /tmp/keepur-dd 2>&1 | grep -E "error:|failed|Executed [0-9]+ tests, with|TEST (SUCCEEDED|FAILED)"
```

Expected: `Executed 12 tests, with 0 failures` (9 + 3). If `testQueuedEntriesAreNotResentIntoAnotherHive` sees "a" on the second task, `activeHive` is being assigned *before* `socket.connect(channel:)` returns — re-check Task 7 Step 4.

- [ ] **Step 6:** Commit:

```bash
git add Views/Team/TeamMessageBubble.swift Views/Team/TeamChatView.swift KeeperTests/TeamViewModelTests.swift KeeperTests/TeamMessageBubbleTests.swift
git commit -m "feat(team): 'not sent' badge for queued rows; offline queue and lastError tests (KPR-442)"
```

### Task 9: Build gate — greps, macOS build, full suite, quality gate

**Files:** none (verification only; fix-ups, if any, get their own `fix:` commit).

- [ ] **Step 1:** Grep gates (spec § Build gate):

```bash
grep -rn 'viewModel\.socket\.' Views
grep -rn 'disconnectedBanner\|retryConnect\|handleConnectionLost\|previousSocketState' Views ViewModels KeeperTests Managers Models
grep -rn 'pendingMessageIds' Views ViewModels KeeperTests
git diff epic-kpr-441 --stat -- Keepur.xcodeproj/project.pbxproj
```

Expected: the first two print nothing; the third prints only `ViewModels/TeamViewModel.swift` hits (the Team request-id map, unchanged in name); the last prints `1 file changed, 4 insertions(+)`.

- [ ] **Step 2:** macOS build with the warning check (fix 5 must remove the Sendable warning and nothing new may appear):

```bash
xcodebuild build -project Keepur.xcodeproj -scheme Keepur -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/keepur-dd-mac 2>&1 | grep -E "warning:|error:|BUILD (SUCCEEDED|FAILED)" | sort -u
```

Expected: `BUILD SUCCEEDED`; no `warning:` line naming `BeekeeperSocket.swift`, and no `warning:` line for any file this plan created or edited. Pre-existing warnings in untouched files are not B's; list them in the completion report rather than fixing them.

- [ ] **Step 3:** Full iOS suite (never concurrently with Step 2):

```bash
xcodebuild test -project Keepur.xcodeproj -scheme Keepur \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:KeeperTests \
  -derivedDataPath /tmp/keepur-dd 2>&1 | grep -E "error:|failed|Executed [0-9]+ tests, with|TEST (SUCCEEDED|FAILED)"
```

Expected: `Executed 216 tests, with 0 failures` and `TEST SUCCEEDED`. If the host crashes in `CapabilityManagerTests` (#101), rerun with `-skip-testing:KeeperTests/CapabilityManagerTests` and expect `Executed 204 tests, with 0 failures`; CI runs the full 216.

- [ ] **Step 4:** Run `/quality-gate` (swift compliance → create tests → pre-submit). `/create-tests` may add a `MessageBubbleTests` smoke for `MessageBubble(pendingReason: .offline)` — welcome but not required (spec § Testing contract); anything it adds must be committed with its own `test:` message and the expected total in Step 3 adjusted in the completion report.

- [ ] **Step 5:** Confirm the working tree is clean and the log reads as eight feature/fix commits on top of the epic branch:

```bash
git status --short
git log --oneline epic-kpr-441..HEAD
```

Expected: no output from `status`; eight (or nine, with a `/create-tests` commit) lines, each carrying `(KPR-442)`.

## Notes for the reviewer / implementer

- **Willset-lag rule** (spec § Key Points): no `socket.send` from any `$state` sink. Both `handleSocketState` bodies only mutate state and schedule tasks; the flushes live in `syncSessions`/the fallback task (Beekeeper) and in `onConnected()` (Team).
- **Plan-level delegated assumption P1:** `ChatViewModel.hasRequestedConnection` (Task 3 Step 1, consumed in Task 6 Step 4 with a live `connectionState` re-read) refines spec §8.4's "false immediately on `.disconnected`" into an ordering-proof gate; spec tests unchanged. Deliberate, not scope creep.
- **Round-3 reviewer items folded in:** the ordering-proof concierge bail (`hasRequestedConnection`, Task 3/6 — see P1); test 11a asserts `offlineMessageIds`, not `pendingMessageIds` (Task 8); the §3 single-hive cold-start sentence is corrected here — with one hive, `reconcileSelectedHive` auto-selects it, so a Retry tapped during the pre-`connectIfPossible()` window **connects** rather than no-ops (still harmless; the strip then reads "Connecting…"); test 13a covers `PendingMessage.text` vs `effectiveText` (Task 4); `testDeviceIdFollowsCredentialStore` is compatible with the hive stamp as-is (Task 8 keeps it verbatim).
- **Out-of-scope carry-overs for the review phase** (spec § Out-of-scope findings): the Team empty-text frame for attachment-only sends; the concierge 50 ms polls of `currentSessionId`/`serverSessions` (C); the untestable hive-vanished path (E); and KPR-445's `TeamStore.deleteChannel` must spare rows whose ids are in `offlineEntries` — comment on KPR-445 during review, do not fix here.
