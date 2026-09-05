# Child A (#90) — Session Handoff

**Parked:** 2026-09-05 (Pacific evening 2026-09-04). **Pick up from:** this doc, then `docs/plans/2026-09-05-child-a-beekeeper-socket.md` Task 9.

## Where things are

| Thing | Value |
|---|---|
| Ticket | keepur/keepur-ios#90 — Child A of epic #88 |
| Branch | `issue-90` (base `main@bcec8f1`) |
| Draft PR | #100 — https://github.com/keepur/keepur-ios/pull/100 |
| Worktree (this machine) | `/Users/mokie/github/keepur-ios-issue-90` (created from `/Users/mokie/github/keepur-ios`) |
| Plan | `docs/plans/2026-09-05-child-a-beekeeper-socket.md` — Tasks 1–8 implemented; Task 9 open |
| Spec | `docs/specs/2026-09-04-cleanup-epic-design.md` § Child A |

## Commits on `issue-90` (oldest → newest)

| SHA | Task | Push |
|---|---|---|
| `1a89b01`…`9c6b96b` | plan + 4 review rounds | — |
| `6ae9be4` | T1 — `Log`, `CredentialStore`, `WebSocketTasking` | 1 |
| `d74843e` | T2 — `BeekeeperSocket` | 1 |
| `2db665a` | T3 — fakes | 1 |
| `5bcca4c` | T4 — `BeekeeperSocketTests` (10) | **1 → run 33949644848 green, 184 tests** |
| `3b8137c` | T5 — `ChatViewModel` + 5 Beekeeper views on the socket | 2 |
| `1e75cbb` | T6 — `TeamViewModel` + `TeamRootView` on the socket | **2 → run 33950802012 green, 184 tests** |
| `6ba3dda` | T7 — delete both old managers; last `print` → `Log.capabilities` | 3+4 combined |
| `29fda96` | T8 — `TeamViewModelTests` (1 test) | 3+4 combined |
| (this doc) | handoff + plan checkboxes | 3+4 combined |

Pushes 3 and 4 were combined into one push at park time (the workflow cancels in-progress PR runs on a new push, so serial pushes would have to wait on each other). Expected result for that run: **`Executed 185 tests, with 0 failures`**. All of T5–T8 passed locally (172 with the two crash-prone suites skipped, see below) and the macOS target compiled.

## Remaining work (in order)

1. **Confirm CI** for the latest push: `gh run list -R keepur/keepur-ios --branch issue-90 --limit 3` → the newest run must be green with 185 tests. If red, read the "Print failure details" step.
2. **Task 9, Step 1 — PR body.** A draft is at the bottom of this doc; paste it into #100 with `gh pr edit 100 -R keepur/keepur-ios --body-file <file>` after filling the run ids. Keep it a draft.
3. **Task 9, Step 2 — acceptance greps** (already empty at park time, re-check after any change):
   `grep -rn 'WebSocketManager' --include='*.swift' .` · `grep -rn 'print(' Managers ViewModels` · `grep -rn 'viewModel\.ws\b' Views`
4. `/quality-gate` (its test step = the CI run), then `dodi-dev:review`, then `dodi-dev:submit`.
5. Next child: #91 (B — connection banner, observable state, offline send queue). Blocked on A merging.

## Deviations from the plan text (already in the code; mention in review)

- **Init default argument.** `init(socket: BeekeeperSocket = BeekeeperSocket(config: .standard), …)` does not compile under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` ("call to main actor-isolated initializer in a synchronous nonisolated context" — default-arg expressions aren't isolated). Both view models use `socket: BeekeeperSocket? = nil` and `self.socket = socket ?? BeekeeperSocket(config: .standard)`. Call sites unchanged; `TeamSortedAgentsTests` still constructs `TeamViewModel()`.
- **`handleConnectionLost`** no longer wraps post-`await` code in `MainActor.run` (the old `handleReceiveFailure` did) — class is MainActor-isolated, matches the plan's exact replacement text.
- **Process:** T5 and T6 went through `dodi-dev:implement` subagents; T7 (two `git rm` + one line) and T8 (verbatim file from the plan) were done directly by the orchestrating session.

## Environment quirks on this machine (Xcode 26.3, iOS 26.3.1 sim)

- **`CapabilityManagerTests` crashes the test host** (`malloc: *** error for object …: pointer being freed was not allocated`) in `CapabilityManager()` init, on every one of its 12 tests. **Pre-existing on `main`**, reproduces only locally — CI (Xcode 26.6 / iOS 26.5) passes it. `TeamViewModelTests` constructs a `CapabilityManager` too, so it crashes locally as well. Each crash spawns a macOS "Keepur quit unexpectedly" dialog. Not child A's problem; worth a follow-up ticket.
- **Local test command** (expect `Executed 172 tests, with 0 failures`, ~4 min):
  ```bash
  cd /Users/mokie/github/keepur-ios-issue-90 && xcodebuild test -project Keepur.xcodeproj -scheme Keepur \
    -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:KeeperTests \
    -skip-testing:KeeperTests/CapabilityManagerTests -skip-testing:KeeperTests/TeamViewModelTests \
    -derivedDataPath /tmp/keepur-dd 2>&1 | grep -E "error:|Executed [0-9]+ tests, with|TEST (SUCCEEDED|FAILED)"
  ```
- **macOS compile check** needs `CODE_SIGNING_ALLOWED=NO` (no "Mac Development" cert here):
  ```bash
  xcodebuild build -project Keepur.xcodeproj -scheme Keepur -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/keepur-dd-mac 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
  ```
- **Pushing / `gh` writes use `may-keepur`** (not the active `bot-dodi`):
  ```bash
  export GH_TOKEN="$(gh auth token --user may-keepur)"
  git -c credential.helper= -c credential.helper='!f(){ echo "username=may-keepur"; echo "password=$GH_TOKEN"; }; f' push origin issue-90
  ```
- **CI concurrency:** `tests-<ref>` group with `cancel-in-progress` on `pull_request` — a new push cancels the running PR check. Don't push while waiting on a run you want to keep.
- SourceKit "Cannot find type …" diagnostics in the IDE are index noise from the main worktree, not real errors.

## PR body draft (fill RUN2/RUN34)

Closes #90. Child A of epic #88. Spec: `docs/specs/2026-09-04-cleanup-epic-design.md` § Child A. Plan: `docs/plans/2026-09-05-child-a-beekeeper-socket.md`.

### What changed

One `BeekeeperSocket` transport replaces both WebSocket managers. Both view models consume it by injection; raw `Data` frames are multicast via Combine and decoded by each view model's existing `WSIncoming` / `TeamWSIncoming` enum.

| Action | Path | Responsibility |
|---|---|---|
| Create | `Managers/Log.swift` | `os.Logger` per category; never logs a URL, token, or frame body |
| Create | `Managers/CredentialStore.swift` | protocol + `KeychainCredentialStore` |
| Create | `Managers/WebSocketTasking.swift` | protocol + `URLSessionWebSocketTaskAdapter` |
| Create | `Managers/BeekeeperSocket.swift` | handshake, Task ping, backoff, 4001 → `onAuthFailure`, channel switch |
| Delete | `Managers/WebSocketManager.swift`, `Managers/TeamWebSocketManager.swift` | replaced |
| Modify | `ViewModels/ChatViewModel.swift` | `init(socket:credentials:)`; `send` / `reconnect` / `disconnect` |
| Modify | `ViewModels/TeamViewModel.swift` | inject; `$state` observer replaces `onReceiveFailure`; computed `deviceId`; `send` / `sendWithId` |
| Modify | `Managers/CapabilityManager.swift` | last `print` → `Log.capabilities` |
| Modify | `ContentView`, `SettingsView`, `WorkspacePickerView`, `SessionListView`, `Team/TeamRootView`, `BeekeeperRootView` | new view-model surface |
| Create | `KeeperTests/FakeWebSocketTask.swift`, `FakeCredentialStore.swift`, `BeekeeperSocketTests.swift` (10), `TeamViewModelTests.swift` (1) | tests |

Deviation: both view models take `socket: BeekeeperSocket? = nil` (default-argument expressions aren't MainActor-isolated); call sites unchanged.

### CI runs (`Tests` workflow)

| Push | Run | Tests |
|---|---|---|
| 1 — socket, seams, fakes, tests | 33949644848 | 184 ✅ |
| 2 — both view models on the socket | 33950802012 | 184 ✅ |
| 3+4 — managers deleted, `TeamViewModelTests`, handoff doc | latest run on `issue-90` (`gh run list -R keepur/keepur-ios --branch issue-90 --limit 1`) — pending at park time | 185 |

Acceptance greps empty: `WebSocketManager` in `*.swift`; `print(` in `Managers`/`ViewModels`; `viewModel.ws` in `Views`.

### Behavior changes

1. Team layer reconnects with backoff instead of stopping at the retry banner; hive-vanished check runs off `$state` at `.reconnecting(attempt: 1)`.
2. `TeamViewModel.deviceId` is read at send time, so a re-pair is picked up immediately.
3. Known interim in `WorkspacePickerView`: "Reconnect" calls `reconnect()` then `browse()`; the browse frame is dropped while the handshake is in flight. Child B's offline queue closes the gap; until then the user taps Retry once more.

### Local-toolchain note

On Xcode 26.3 / iOS 26.3.1 sim, `CapabilityManagerTests` (and `TeamViewModelTests`, which builds a `CapabilityManager`) crash the test host in `CapabilityManager()` init — pre-existing on `main`, not reproducible on CI (Xcode 26.6). Skip both locally; CI is authoritative.
