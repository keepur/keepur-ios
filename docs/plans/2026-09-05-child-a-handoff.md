# Child A (#90) — Session Handoff

**Updated:** 2026-09-05 (round 4 complete). **Pick up from:** this doc. Tasks 1–9 of `docs/plans/2026-09-05-child-a-beekeeper-socket.md` are done; `/quality-gate` passed; review round 4 is clean; the fable final round is the only thing left before `dodi-dev:submit` (see "Where the review stands").

## Where things are

| Thing | Value |
|---|---|
| Ticket | keepur/keepur-ios#90 — Child A of epic #88 |
| Branch | `issue-90` (base `main@bcec8f1`), head `b761c69`, pushed, worktree clean |
| Draft PR | #100 — https://github.com/keepur/keepur-ios/pull/100 (body current as of this park) |
| Worktree (this machine) | `/Users/mokie/github/keepur-ios-issue-90` |
| Latest CI | run 33956287117 on `b761c69` — green, **192 tests, 0 failures** |
| Spec | `docs/specs/2026-09-04-cleanup-epic-design.md` § Child A |

## Commits since the first park (`c4ff1f4`), oldest → newest

| SHA | What | Source |
|---|---|---|
| `f3186c5` | plan checkboxes for Task 9 steps 1–2 | — |
| `b0c4d1d` | `ChatViewModelSocketTests` (4) | `/quality-gate` create-tests step |
| `544b923` | `ConciergeViewModel.runFlow` waits for the handshake before its first send; `ConciergeViewModelTests` (1) | review round 1 (important) |
| `4006376` | `isBrowsePending = send(.browse)` so a dropped browse doesn't misattribute later errors | round 1 |
| `1de2177` | fallback socket gets the injected `credentials` | round 1 |
| `42ace9e` | error-string log interpolations `.private` | round 1 |
| `ecd57ac` | `CredentialStore` protocol read-only | round 1 |
| `c301f65` | test pins `Config.standard.keepAliveFrame` to both ping encoders | round 1 |
| `c9a83e2` | Team banner re-set on **every** `.reconnecting` transition; capability refresh still gated at attempt 1; `testBannerReturnsAfterFailedManualRetry` | round 2 |
| `de1c504` | `frameType` parse gated on `Log.socketEnablement.isEnabled(type: .debug)` (parallel `OSLog`; `os.Logger` has no `isEnabled` in this SDK) | round 2 |
| `ce18713` | dead setters dropped from `KeychainCredentialStore` | round 2 |
| `d0b656f` | fix the banner test: seed `_setHivesForTesting(["hive-1"])`, drive `connectIfPossible`/`retryConnect`, clear `selectedHive` default | round 3 (blocker: test failed deterministically) |
| `b761c69` | CredentialStore comment; `socketRaw` → `socketEnablement` | round 3 nits |

CI runs: 33953912730 (`b0c4d1d`, 189 ✅) → 33955710783 (`ce18713`, ❌ the round-3 test bug) → 33956287117 (`b761c69`, 192 ✅).

## Where the review stands (`dodi-dev:review`, manual mode, post-implementation context)

| Round | Tier | Result |
|---|---|---|
| 1 | opus | 1 important + 5 minor → fixed (`544b923`…`c301f65`) |
| 2 | opus | 3 minor → fixed (`c9a83e2`…`ce18713`) |
| 3 | opus | 1 blocker (test) + 2 nits → fixed (`d0b656f`, `b761c69`) |
| 4 | opus | ✅ Approved — 3 minor, all demoted to follow-up (see below), none fixed in-loop |
| final | fable | not run |

Running ledger: `gate-ledger: pre-pr rounds=4 findings=6/0,4/0,3/0,3/0 outcome=clean(3 demoted)`. Round 4 result posted on [#90](https://github.com/keepur/keepur-ios/issues/90#issuecomment-5554370642).

**Resume here:**
1. Dispatch the **final round** at `model: fable` (`review-prompt.md`, `caught-by: pre-pr/5/fable`), same diff range and "already accepted" list as round 4 below. If it finds issues: sonnet fix worker → fresh opus round; cap is 5 rounds total.
2. On clean: post the gate-ledger line in the close-out, then `dodi-dev:submit` (mark #100 ready, wait for CI, merge, clean up the worktree).
3. Next child: #91 (B — connection banner, observable state, offline send queue). Blocked on A merging.

**Tell the final reviewer these are already accepted (don't re-raise without new evidence):** `socket: BeekeeperSocket? = nil` init; views read `viewModel.socket.isConnected` without republishing (same as `main`; child B); `WorkspacePickerView` reconnect-then-browse drop (documented interim); the parallel `OSLog` enablement handle; banner-on-every-reconnecting as a documented deviation from the spec's literal attempt-1 wording; `.goingAway` close code, unreferenced `reconnect()`/`Log.persistence`, the 5 s concierge wait, `ConciergeSessionStore.swift` `print` — all follow-up-ticket notes, not fixes. Also now accepted from round 4: `reconnectAttempts` not reset on a `scheduleReconnect` bail, `disconnect()` leaving `lastChannel` set, and the `TeamViewModelTests.swift:83` cross-suite ordering dependency — all filed (see below).

## Follow-up tickets (filed, not child A's scope)

All of these were carried out of child A's review into the tracker rather than left only in this doc — see the ticket/comment for full context:

- `disconnect()` closes with `.goingAway` where the old managers sent `.normalClosure`; `BeekeeperSocket.reconnect()`/`Log.persistence` unreferenced until B/D; `reconnectAttempts` not reset on a `scheduleReconnect` bail; offline cold start's 5 s `waitForSocketConnected` wait — all posted on [#91](https://github.com/keepur/keepur-ios/issues/91#issuecomment-5554371228) (child B).
- `Models/ConciergeSessionStore.swift:51` `print(` outside the spec's Managers/ViewModels sweep scope; `Log.persistence` first-use candidate — posted on [#93](https://github.com/keepur/keepur-ios/issues/93#issuecomment-5554371596) (child D).
- `CapabilityManager()` init crash on Xcode 26.3 locally (intermittent, CI-clean) — filed as [#101](https://github.com/keepur/keepur-ios/issues/101).
- `TeamViewModelTests.swift:83` implicit cross-suite `KeychainManager.token` ordering dependency — filed as [#102](https://github.com/keepur/keepur-ios/issues/102).

## Environment quirks on this machine (Xcode 26.3, iOS 26.3.1 sim)

- **`CapabilityManagerTests` host crash** (`malloc: pointer being freed was not allocated` in `CapabilityManager()` init) — reproduced at the first park; **did not reproduce** for the round-3 reviewer or the round-3 fix worker, and `TeamViewModelTests` ran 10× clean locally. Treat as intermittent: try the full suite skipping only `CapabilityManagerTests` first (expect 180), fall back to skipping both if the host crashes (expect 178). CI is authoritative either way.
  ```bash
  cd /Users/mokie/github/keepur-ios-issue-90 && xcodebuild test -project Keepur.xcodeproj -scheme Keepur \
    -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:KeeperTests \
    -skip-testing:KeeperTests/CapabilityManagerTests -derivedDataPath /tmp/keepur-dd 2>&1 | grep -E "error:|Executed [0-9]+ tests, with|TEST (SUCCEEDED|FAILED)"
  ```
- Simulator occasionally refuses to launch the test host with `FBSOpenApplicationServiceErrorDomain ... Busy`, especially when a macOS build runs concurrently. Rerun; don't run the two xcodebuilds at once.
- **macOS compile check** needs `CODE_SIGNING_ALLOWED=NO`:
  ```bash
  xcodebuild build -project Keepur.xcodeproj -scheme Keepur -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/keepur-dd-mac 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
  ```
- **Pushing / `gh` writes use `may-keepur`** (not the active `bot-dodi`):
  ```bash
  export GH_TOKEN="$(gh auth token --user may-keepur)"
  git -c credential.helper= -c credential.helper='!f(){ echo "username=may-keepur"; echo "password=$GH_TOKEN"; }; f' push origin issue-90
  ```
- **CI concurrency:** a new push cancels the in-progress PR run. Don't push while waiting on a run you want to keep.
- SourceKit "Cannot find type …" / "No such module XCTest" diagnostics in the IDE are index noise from the main worktree.
