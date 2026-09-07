# KPR-443 — Injectable, unit-tested ChatViewModel

## TL;DR

Make the existing chat state machine testable without constructing speech services, replace concierge's two polling loops with bounded waits on decoded frames, and hide both view models' sockets. Approvals stay in their owning session, and the busy watchdog asks the server for status instead of declaring a session idle. Preserve the queue, attachment, reconnect, and pairing behavior merged in KPR-442 while adding the ten approved core behavior cases.

## Key Points

- Derive C from merged B, `af6a9ed15f0607cf22abae83be414c956d7f5803` / PR #105. The baseline already has 26 Chat socket/queue tests and six pairing tests; C expands that evidence rather than starting from zero.
- Add optional speech injection with lazy construction and a `Duration` watchdog timeout, preserving A's optional socket construction with the injected credentials and B's error timeout.
- Publish each decoded `WSIncoming` after its complete synchronous state handler. Concierge waits subscribe before their named VM request, accept only relevant fresh frames, and release their subscriptions on every exit.
- ⚠ Use a one-result, request-local buffered relay for the async wait so even a reply delivered during the send is retained. This is a technical refinement of the approved `incoming.values` sketch; the shared stream remains the specified `PassthroughSubject`.
- Approval storage remains keyed by session; another session's approval cannot change selection. No additional approval presentation is added.
- Reconcile statuses against the full server list, including concierge, while filtering only the SwiftData Session-table work. Preserve B's fetch-failure return and its single reconnect/fallback release pass.
- ⚠ A busy watchdog remains armed while a connected session awaits a reply, queries at the existing 90-second cadence, and resets its deadline on a still-busy reply. It never changes status or releases a queue head on timeout alone.
- Scope is C's injection, orchestration, state fixes, socket visibility, and tests. D's enums/persistence work, E's Team fixes, new UX, wire changes, migrations, and standalone KPR-446/447/448 are excluded.

## Authority and starting point

The sole product input is [Child C of the approved cleanup design](2026-09-04-cleanup-epic-design.md#child-c--injectable-tested-chatviewmodel), expanded under the [Gate 1 package](https://linear.app/keepur/issue/KPR-441/epic-ios-cleanup-structural-debt-and-silent-failures-pre-ux-epic#comment-9280145a) and unconstrained [Approved signoff](https://linear.app/keepur/issue/KPR-441/epic-ios-cleanup-structural-debt-and-silent-failures-pre-ux-epic#comment-21fb1443). The ticket is [KPR-443](https://linear.app/keepur/issue/KPR-443/c-injectable-unit-tested-chatviewmodel). Its dependency B has merged; the ticket snapshot's stale dependency status does not reopen B.

The decision canon through B and its `ALIGNED` coherence ruling bind this spec, particularly R4/R5/R7/R9: FIFO and release bookkeeping, complete-list absent cleanup, pairing ownership, and preservation of existing tests. This is a draft for the upstream spec gate, not a gate approval or an implementation plan.

Relevant code inspected at the starting SHA:

| Area | Current behavior and C consequence |
|---|---|
| `ViewModels/ChatViewModel.swift` | Constructs `SpeechManager` eagerly; resets `speechManager.liveText` on send; exposes `socket` and generic `send`; handles frames privately; forces idle in two watchdog closures; filters concierge before status reconciliation. |
| `Views/BeekeeperRootView.swift` | `ConciergeViewModel` lives below the view; its connection wait is already event driven, but its session-info/list waits poll every 50 ms. Four generic sends remain. |
| `Models/WSMessage.swift` | Existing `session_info`, `session_list`, and request shapes suffice. No request IDs correlate Chat replies; missing `mode` defaults to `sessions`. |
| `Models/ConciergeSessionStore.swift` | Cache stores ID/path; discovery picks the first `mode == concierge` row. Static cached-ID fallback reads standard defaults. |
| `ViewModels/TeamViewModel.swift`, `Views/ContentView.swift` | Team only needs socket privacy. ContentView already binds synchronous, weak pairing teardown callbacks before configure/connect and shares Chat's speech instance. |
| `KeeperTests/ChatViewModelSocketTests.swift`, `PairingTeardownTests.swift`, `ConciergeViewModelTests.swift` | Real socket/fake task harnesses already exercise transport adoption, B's delivery/reset behavior, and concierge cold start. One fault-injection test accesses the exposed Chat socket; the harness must retain its own injected reference instead. |

The reported 238-test CI result belongs to merged B, not this draft. No source build or test result is claimed here.

## Goals and boundaries

The result is a headless, observable Chat core whose tests drive real decoding and state handling through the existing transport seam. The two intended user behavior changes are the approved approval isolation and server-authoritative busy recovery. Concierge keeps its resume → list → resume discovered session → fresh spawn flow, existing UI, cache format, connection bail behavior, and timeout copy.

Keep String statuses, modes, and roles until D. Keep existing SwiftData models, persistence failure handling, messages/history, workspace behavior, and in-memory queues. Do not add a Speech protocol, transport mock protocol, request broker, shared event bus, MessageStore, new dependencies, new UI, or server work. Existing unrelated layering/persistence violations are not prerequisites for C; D retains its enumerated cleanup. Team behavior changes, including orphan cleanup and history correlation, remain E's responsibility.

## 1. Construction, speech, and VM boundary

The initializer adds the approved parameters without losing either predecessor's injection:

```swift
init(
    socket: BeekeeperSocket? = nil,
    credentials: CredentialStore = KeychainCredentialStore(),
    speech: SpeechManager? = nil,
    staleBusyTimeout: Duration = .seconds(90),
    lastErrorAutoClear: Duration = .seconds(6)
)
```

Store `speech` in a private optional backing property. Keep the existing nonoptional `speechManager: SpeechManager` accessor for views and the Team binding: return the supplied instance, or construct and retain one on first explicit access. `nil` means lazy production behavior, not permanently disabled speech.

`init`, `configure`, ordinary frame processing, queue admission/release, and `sendText` with `autoReadAloud == false` must not access the constructing getter. In particular, resetting transcription after a send uses the optional backing instance if one exists; there is nothing to clear when it does not. Automatic read-aloud may access the getter only inside the existing enabled branch. ContentView's explicit speech sharing/loading and speech UI therefore retain their existing behavior and instance identity.

`staleBusyTimeout` is a stored `Duration`; production remains 90 seconds. Positive short values, including 50 ms, support tests without a wall-clock abstraction. Keep B's separate five-second reconnect fallback and configurable six-second error clear unchanged.

Both `ChatViewModel.socket` and `TeamViewModel.socket` become `private let`. Chat's generic `send(_:) -> Bool` becomes private. The coordinator uses only these named methods:

```swift
@discardableResult func resumeSession(sessionId: String, path: String) -> Bool
@discardableResult func listSessions() -> Bool
@discardableResult func newConciergeSession() -> Bool
```

Their results report synchronous encode/socket acceptance, with the existing wire cases `.resumeSession`, `.listSessions`, and `.newSessionConcierge`. A `true` result is not a server acknowledgement. Existing callers may discard it. No additional outgoing API or raw-Data access is introduced.

`configure(context:)` keeps subscription/callback installation before `socket.connect(channel: Self.channel)`, where the channel remains `beekeeper`. Reconfigure replaces the frame subscription rather than accumulating duplicate handlers. State observation remains installed in init, with no synchronous sends from its sink. `unpair()` retains `credentials.clearAll()` and B's teardown callback ordering; C additionally cancels its watchdog work. No production Keychain access is added to testable paths.

## 2. Decoded-frame contract

Chat exposes exactly one instance-lifetime subject:

```swift
let incoming = PassthroughSubject<WSIncoming, Never>()
```

For each accepted raw frame, `handleFrame` performs the existing decode (including the existing `.unknown` fallback), calls `handleIncoming`, and then synchronously calls `incoming.send(decoded)` on the main actor. Publication occurs after the handler returns, including early-return paths such as an unscoped approval being denied. Do not publish inside individual switch cases, from `@Published` will-set hooks, or before table/status/queue handling finishes.

Every frame is published once; there is no replay. Two subscribers receive the same events without competing with Chat's handler or one another. At notification time a synchronous subscriber can read the handler's resulting in-memory state and persistence attempts: selection/path, server list, pending approvals, and queue effects are already applied. This does not promise that a failed SwiftData save succeeded; existing failure semantics remain D's work.

Consumers treat the subject as observation-only. They must not inject production events or finish the shared subject. Ordinary disconnect, reconfigure, and re-pair do not finish it; a reusable VM continues publishing on later connections. Transport generation guards still reject callbacks from obsolete socket tasks before they can reach this stream.

## 3. Concierge request waits

### Flow and response matching

Keep `ConciergeViewModel` and the BeekeeperRootView body in their existing location for C; moving business logic or changing presentation is unnecessary. Replace `waitForSessionInfo` and `waitForConciergeInList` and remove both 50 ms loops. Do not use `currentSessionId`, `currentPath`, or a previous `serverSessions` snapshot as evidence of a new response.

| Stage | Request after subscription | Successful response | Budget / next action |
|---|---|---|---|
| Connection | None | B's published connected state, with its live reread | Five seconds; existing offline bail on definitive failure or connection timeout, cache preserved. |
| Cached resume | `resumeSession(cached ID/path)` | New `.sessionInfo` for that exact ID with nonempty path; mode may be omitted/legacy because identity is known | Three seconds; cache authoritative returned ID/path and become ready. Connected timeout falls through after clearing failed cache. |
| Discovery | `listSessions()` | First new `.sessionList`; apply existing first-concierge picker to that reply | Three seconds; match proceeds to resume; an empty/no-match reply proceeds immediately to fresh spawn. Timeout also proceeds to spawn. |
| Discovered resume | `resumeSession(discovered ID/path)` | New `.sessionInfo` for that exact ID with nonempty path | Three seconds; ready/cache on match; connected timeout proceeds to fresh spawn. |
| Fresh spawn | `newConciergeSession()` | New `.sessionInfo` with `mode == concierge` and nonempty path | Five seconds; cache/ready on match; connected timeout keeps existing `Concierge did not respond in time` error. |

Fresh spawn must ignore unrelated normal-session info. It does not require a change from a snapshot of current selection: a valid concierge reply can repeat a known ID. Exact-ID resume accepts legacy mode classification, preserving the existing cache fallback. A fresh response lacking any concierge identity cannot be safely identified from the unchanged protocol; it follows the existing timeout path. Do not change decoder defaults or infer that an unrelated workspace session is the concierge.

Errors retain Chat's existing routing. The response wait ignores unrelated frame types, including errors, and reaches its existing timeout/fallback rather than inventing error correlation or new copy. There are no request IDs on these replies: concurrent independent `list_sessions` requests can produce indistinguishable fresh list frames, and a delayed matching reply cannot be attributed to one request. Accept the first fresh response meeting the stage's predicate; do not claim stronger correlation.

### Subscribe before send, including synchronous replies

For each stage, create a fresh request-local reply latch and synchronously install a Combine subscription to `viewModel.incoming` before invoking its named request. Filter/map at this subscription and retain only the first matching response. A discovery latch must distinguish a received empty/no-match list from no response.

Use a small private `CurrentValueSubject<Reply?, Never>` relay, initially nil, fed by the filtered `.prefix(1)` subscription. It retains at most one matching result while the async consumer starts. Consume its `.values` with `for await` inside `withTimeout`; skip the initial nil and return the first stored reply. The shared decoded stream remains a `PassthroughSubject`; the request-local relay provides the buffering needed for the approved subscribe-before-send guarantee. Reply values contain only the needed String ID/path data or a no-match marker, and can be `Sendable` without changing protocol models.

This concretizes the epic's `incoming.values` sketch. Constructing an async sequence or scheduling a task is not proof that upstream demand is installed. Apple documents that [PassthroughSubject drops values without demand/subscribers](https://developer.apple.com/documentation/combine/passthroughsubject), while [CurrentValueSubject retains its latest value](https://developer.apple.com/documentation/combine/currentvaluesubject). The chosen relay makes the guarantee independent of task scheduling and retains a reply delivered inside the request call itself.

Required order on the main actor is: validate active run → create empty latch → install filtered subscription → validate again → invoke one named request → await buffered async values with a deadline → cancel subscription and release latch on every exit. There is no suspension between subscription and send. The subscription is not added to an ever-growing coordinator-wide set. Do not finish the local relay immediately on the upstream first-event completion, since the async reader may not have started yet; its owner disposes it after the wait.

### Errors, cancellation, and ownership

Keep B's connection wait semantics: initial `.disconnected` before a request to connect is not definitive failure; `.connecting` and `.reconnecting` wait; definitive `.disconnected` uses both `hasRequestedConnection` and the live state; reread connected state before the timeout bail. Keep `bailedOffline` and the existing once-per-bail retry on the next connected transition. The connection wait may reuse `withTimeout` if these semantics remain intact.

A rejected named send cannot start the next fallback request as if the server rejected a session. Dispose its wait and use the existing offline bail/cache-preserving path. After every await, check cancellation/current-run ownership before touching state/cache or sending again; on a no-result response wait, reread connection state before clearing cache or falling through. If no longer connected, use the same offline bail with cache retained. A connected session-response timeout retains the stage transitions in the table.

The coordinator owns one flow task. `start` remains idempotent; `retry` cancels the earlier task, invalidates its run identity, then starts one replacement. A canceled/superseded run cannot clear cache, overwrite ready/error state, or send a later list/spawn request. Observe authentication loss during an active run to invalidate/cancel it, so a rapid unpair/re-pair cannot revive the old run against replacement credentials; remove that observation with the run. No new user-facing auth flow is needed.

The task must not keep its owning coordinator alive through an owner → task → owner cycle across waits. Cancel on coordinator destruction and release reply subscriptions on success, timeout, failed send, cancellation, or authentication loss. Preserve tab appearance behavior: hiding/revisiting a tab does not itself add a restart or cancel UI action.

## 4. AsyncTimeout helper

Add `Managers/AsyncTimeout.swift` with the approved optional-result, two-task race. A concrete Swift-concurrency-compatible signature for its callers is:

```swift
@MainActor
func withTimeout<T: Sendable>(
    _ duration: Duration,
    _ body: @escaping @MainActor @Sendable () async -> T?
) async -> T?
```

One child executes the body on the main actor; the other sleeps for the duration and returns nil. The first completed result wins, including an immediate nil from the body. Cancel the loser on every exit and return nil if the parent is canceled. A nonpositive duration or an already canceled parent returns nil without invoking the body. The request-wait owner checks cancellation before its separately ordered send; all production stage budgets are positive. Callers distinguish cancellation from timeout via their task/run checks before any fallback effect.

The helper is for cooperative async operations; it cannot interrupt arbitrary synchronous work. Both the sleep and async response iterator must finish when canceled, because a [structured task group waits for its children to finish](https://developer.apple.com/documentation/swift/taskgroup). Do not swallow sleep cancellation and then continue body work. Keep the helper independent of ViewModels, sockets, SwiftData, and any networking framework. No timeout exception type, retry policy, clock library, or unstructured detached race is needed.

## 5. Approval isolation

In `.toolApproval`, remove the assignment to `currentSessionId` for an explicitly different session. Resolve the dictionary key as today: explicit session ID first, otherwise the selected session ID. Store the approval under that key without changing `currentSessionId` or `currentPath`.

When neither an explicit nor selected session exists, send the existing deny and store nothing. Existing approve/deny methods remove only the addressed session's pending approval. ChatView's existing per-session sheet binding displays another session's approval when that session is opened. Notifications or badges elsewhere remain out of scope.

## 6. Watchdog and complete-list reconciliation

### One watchdog policy

Consolidate the duplicated force-idle closures behind small private arm/cancel helpers. A session with any active non-idle status (including generic `busy`, `thinking`, and tool states) has at most one watchdog task; `session_ended` is terminal, not active busy. A new active status cancels/replaces that session's deadline. Idle/end/clear/delete/absent cleanup cancels and removes its timer.

On expiry, verify the task is still current, the VM is authenticated/connected, and that session remains active busy. Send `listSessions()` only. Do not assign idle, clear a tool name/approval/stream, reclassify a pending reason, clear a release gate, or send a queued payload merely because time elapsed.

Keep a next watchdog deadline for the same still-busy connected session while a reply is outstanding, so a missing/rejected reply does not retire observation forever. A new status or a list reply replaces that deadline; do not stack timers. This uses the same injected interval and existing request, with no additional timer thresholds, error banner, or retry backoff. Multiple sessions may each request a list at expiry; batching is unnecessary for C.

Leaving connected cancels watchdog tasks without changing statuses or queues. On reconnect, arm a fresh deadline for retained active statuses, without sending synchronously in the socket state sink; the existing `onConnected` session list remains the immediate reconciliation request. This also leaves busy sessions watched if that response is absent. Unpair cancels all watchdog tasks synchronously. Timer closures use weak ownership and cancellation/current-task guards; a canceled old task must not remove a replacement timer or act on a reused session ID.

On `session_replaced`, cancel the old-ID watchdog and arm the new ID if its migrated status is still busy and connected. Keep message/transient/queue/release-set migration as B implements it. No closure retaining the old session ID survives the swap.

### Full reply in, filtered table work

Change `syncSessions` to receive the full `[ServerSession]`. The `.sessionList` handler assigns `serverSessions` to that same full list and invokes sync before publishing `incoming`.

Within sync, derive three views of one reply: the complete ID set, concierge IDs (`mode == concierge` plus the cached-ID fallback), and Session-table rows (`mode == sessions` excluding concierge IDs). The full reply drives status reconciliation and absent-ID cleanup; the filtered rows drive local Session insertion/stale marking only.

Fetch local Session rows successfully before consuming `awaitingPostReconnectSync`, clearing `releasedBeforeReconnectSync`, canceling the fallback, or otherwise running the sync pass. Preserve the existing failed-fetch early return: a failure leaves B's fallback eligible. Moving the existing vestigial-concierge-row deletion into this sync is permitted to avoid a duplicate fetch, but it must keep this guard boundary.

Delete vestigial concierge Session rows and exclude them from later local stale-selection checks. Then preserve normal local insertion, name/history behavior, stale marking, and clearing selection for an actual stale normal Session. A selected concierge must not be cleared merely because it intentionally has no table row, including the cached-ID/legacy-mode case. C adds no Session rows or Workspace history for concierge and does not change persistence schemas.

### Status transition rules

Apply these rules to every row in the full reply, including concierge. Retain the existing coarse server-state contract (`idle`/`busy`) and String representations; D owns typed fallbacks.

| Client before reply | Server reply | Result |
|---|---|---|
| Busy/detail state | Idle | Set idle, clear stale tool name, cancel watchdog. Release through B's queue helper only if the reconnect skip set allows it. |
| Busy/detail state | Busy | Preserve the more informative client status/tool name and explicitly re-arm its watchdog. No queue release. |
| Nil or idle | Busy | Adopt busy and arm watchdog. No queue release. |
| Nil or idle | Idle | Keep/adopt idle and ensure no busy watchdog remains. An ordinary repeated idle list grants no extra release; the initial reconnect pass may release through B's existing post-loop helper. |
| Known busy session absent from full reply | Absent | Use shared `session_ended` cleanup: status, tool name, streaming ID, approval, timer, pending entries/attachments/reasons, and both queue release sets are removed. |
| Known idle queued/release-only session absent | Absent | Drop its pending entries and clear both release sets, as B does. No payload is sent. |

The complete known-ID scan retains B's union of status keys, pending session IDs, and both release sets. Table absence alone must never reap a present concierge.

### Preserve B's release invariants

On the first successful list after reconnect, snapshot the already-released IDs, consume the reconnect flag once, cancel its five-second fallback, and reclassify offline entries once. Busy-to-idle reconciliation uses the existing release helper and adds newly released session IDs to the local skipped/flushed set. The final offline flush skips every ID already released by a live idle or by this pass.

Do not allow full-list concierge reconciliation to bypass `queueReleasePendingIdle`. A successful queued head continues holding later same-session sends even if it emptied the queue. An initial list/fallback cannot award a second release after a live idle. A later ordinary busy-to-idle server transition can release one head; a repeated idle list cannot. The fallback still passes through cached busy gates and never forces idle.

Retain per-session FIFO, independent direct sends for unrelated empty idle sessions, attachment bytes and attachment-only empty wire text, failed-send head retention, release-set migration, and cleanup of release-only IDs with no remaining queued entry. Neither queue is rehydrated from persisted bubbles after relaunch.

## 7. Testing contract

### Harness and meaningful observation

Create `KeeperTests/ChatViewModelTests.swift` using an in-memory `ModelContainer` with `Session`, `Message`, and `Workspace`, one fake credential store shared by the VM and a real `BeekeeperSocket`, the existing fake task/factory, `speech: nil`, and short watchdog durations where relevant. A `receive(_ json: [String: Any])` helper serializes and delivers through the fake transport; it does not call the private state handler or send directly into `incoming` for core behavior tests.

Retain the injected socket in the test harness when transport fault injection needs it. This replaces `vm.socket` access without weakening privacy. Replace generic-send assertions with named methods' return values and encoded frames. Existing B state-subscription fault injection may be consolidated with the harness; preserve its rejected-send/attachment/FIFO assertions. Do not introduce a production mutable transport bypass to make the test easier.

Tests assert fetched rows, IDs/text/roles/names/stale flags, published state, pending reasons, and exact outgoing payload order/count. Seed state before asserting its cleanup, assert nonempty collections before `allSatisfy`, and verify that the expected frame actually arrived. For private streaming/timer state, prefer behavior: a subsequent chunk creates a new row after cleanup; a second deadline emits a new list only while still busy; a replacement timer queries the new session's lifecycle. A read-only backing-storage inspection may establish that headless operations did not construct speech without invoking its lazy getter.

Use bounded async expectations or condition waits that fail if unmet. Fixed counts of `Task.yield()` may settle known hops but are not the sole evidence of completion. Deliver multiple frames only after the fake receive loop has rearmed, since the existing fake holds one receive callback. Record a list-request count after handshake to distinguish watchdog queries from `onConnected`'s list and keep-alive ping. Isolate one active watchdog when asserting query cancellation, since `list_sessions` has no session-ID field. No real socket, Keychain, audio permission prompt, speech service, or persistent test store is needed.

### Ten required core behavior groups

1. **Streaming assembly:** Three non-final chunks and a final append produce exactly one assistant row with concatenated text and stable row ID. A lone final produces exactly one row. A `thinking` boundary followed by another chunk produces a distinct bubble; use different text to prove rows were not merged.
2. **Status/tool name/termination:** A named `tool_running` sets both status and name; idle clears the name. Seed a stream, approval, queued payload/attachment, and timer before `session_ended`; assert the published removals, zero queued bytes, no later queued sends, no stale timer query, and a fresh bubble on later streaming. Preserve another session's seeded state.
3. **Busy queue and cancel:** Connected busy sends produce `.busy` reasons and no message payloads; each idle event releases exactly one oldest entry. Cancel one session and verify its payload/reason/bytes disappear while the other session remains queued and can still release.
4. **Offline queue:** Disconnected/handshaking sends are `.offline`; handshake alone does not release the backlog; an idle list sends one head, while a busy list reclassifies `.busy` without sending. Preserve all B reconnect/fallback/order variants below.
5. **`/clear` handoff:** Seed an old named Session, rows, transient state, and queued work. `context_cleared` deletes its messages/transients/queue but retains old Session and selection until the matching-path `session_info`. That reply creates/updates the new row, preserves the name, selects the new ID, removes the old row, and never leaves the handler's observable result without the replacement row. An unrelated-path reply must not consume the old handoff.
6. **`session_replaced`:** Seed old messages, streaming state, approval, detailed busy state/tool name, and queued entries. Verify messages and state belong to the new ID, the old row is gone, the name is retained, later chunks append to the migrated stream, and queued wire payloads use the new ID. Include B's released-head/initial-sync-skip migration with both an existing tail and an emptied queue, and prove the migrated busy lifecycle has a working watchdog.
7. **`session_list` sync:** Missing normal rows insert, absent local rows become stale, and selected stale normal sessions clear. Test wire-mode concierge and cached-ID legacy concierge: each remains in the full published list/status map but has no Session row and keeps valid selection. A present busy concierge must not lose its queue through absent cleanup. Include removal of a preexisting vestigial concierge row.
8. **Error routing:** Nil-session error becomes `lastError` without a system bubble; explicit-session error creates one scoped system row without changing another session or producing a banner. Preserve active-browse inline routing and the failed-browse-send guard from B.
9. **Approval isolation:** With A selected, B's approval populates only B's dictionary entry and changes neither selection nor path; an existing A approval remains. Nil-session approval binds to A; no current/explicit session sends one deny and stores none. Approve/deny affects only its addressed entry.
10. **Watchdog truth/re-arm/absence:** Inject 50 ms and seed a busy session plus queued work. First expiry adds a `list_sessions` request but leaves busy status, tool/approval, pending reasons, and message payload count unchanged. A concierge idle reply cancels the watch and releases only the permitted head; a still-busy reply preserves detail and yields another query after its reset deadline. No reply leaves the watch querying at the same cadence without queue release. An absent busy reply performs the seeded termination cleanup and drops its queue. Exercise explicit idle, disconnect, unpair, and replacement before expiry to prove obsolete tasks cannot act later.

### Additional seam tests

- **Decoded ordering/multicast:** Attach two synchronous subscribers before a fake-transport frame. In each callback assert the corresponding post-handler selection/path or approval/status state, once per frame. Include `.sessionList` so its full list, table filtering, and reconciliation are complete before publication; unknown fallback still publishes once.
- **Concierge fast reply and filtering:** Add an optional test-only fake send callback so delivery can occur as soon as the request is recorded. Verify cached/discovered resume and fresh spawn complete with the correct ID/path, ignore unrelated info, accept only new list frames, and keep the view-model updates visible by ready time. In a separate seam test, run the actual coordinator and emit a synchronous decoded event into `incoming` from that fake send callback; this pins the installed latch without exposing a private helper, even though real socket handling uses an actor hop. The raw-frame ordering test independently proves state mutation before real publication.
- **Concierge exit paths:** Cover empty discovery, connected timeout fallbacks with existing budgets, failed-send/offline cache preservation, existing cold-start/deferred-configure semantics, once-per-bail connected retry, explicit retry canceling an old flow, and authentication loss followed by re-pair. Late replies must not trigger duplicate spawn, old-run cache writes, or old-run ready/error changes. Check subscription disposal using publisher receive-cancel observation or an equivalent lifetime assertion; waiting until the final result alone does not prove cleanup.
- **AsyncTimeout unit tests:** Add `KeeperTests/AsyncTimeoutTests.swift`: body success before deadline returns its value; immediate body nil returns nil; timeout cancels a suspended cooperative body and returns within a generous outer bound; parent cancellation does the same; nonpositive duration does not invoke body. Observe the loser's cancellation/completion so a result-only assertion cannot hide a leaked child or a group that hangs until the original long deadline.
- **Injection/privacy:** A nil-speech VM remains uninitialized through configure, sends, and incoming core cases when read-aloud is off. Named requests return false before connected and encode the existing wire shape once connected. Source audit finds no external VM socket or generic Chat send access; both platforms compile all call sites.

### Preserve predecessor coverage

Keep all behavioral assertions from the 26 tests in `ChatViewModelSocketTests.swift` (including its queue-release class), six in `PairingTeardownTests.swift`, existing `ConciergeViewModelTests.swift`, and relevant `TeamViewModelTests.swift`. File/class consolidation into the new core harness is allowed; deletion of covered behavior is not. The later implementation plan must map moved tests to replacements rather than treating the ten groups as a reason to reduce coverage.

In particular retain: after-handshake admission behind existing busy/offline work; unrelated-session direct sends; text/file/image order and bytes; attachment-only no-text; the emptied-queue release gate; early live-idle skip for initial sync and fallback; ordinary busy-to-idle release; late-list no double flush; disconnect cancellation of old fallback; failed-send attachment head retention; every clear/cancel/end/absence cleanup variant; session replacement of both release sets; four production-bound unpair/auth origins and idempotent Team reset; same-instance re-pair with fresh sends; and direct/ordinary hive switching with delivery only on return to the original hive.

Run C's core/timeout/concierge suites, retained Chat and pairing suites, and affected Team/transport regression groups during implementation verification. Broader regression is the full `KeeperTests` suite using the repository's CI-compatible iOS Simulator command and normal ad-hoc signing; do not suppress Keychain host signing. Build the macOS target as required by Gate 1. New test files use the synchronized test group; any new production helper must be included in both app-platform build configurations. The plan records actual destinations, commands, SHA, and result evidence. KPR-446/447/448 failures remain classified standalone baseline issues rather than silently expanding C or dropping required coverage.

## 8. Downstream propagation and assumptions

D must derive its persistence-site inventory from C's merged code, including the consolidated full-list sync and any local helper call sites. Preserve the successful-fetch guard before reconnect state is consumed, the queue/release behavior during enum conversion, the lazy speech boundary, decoded post-handler ordering, and pairing callbacks. C does not implement D's six enums, persistence wrappers, logging cleanup, or CLAUDE rewrite.

E still owns history request correlation, DM timeout, dynamic device identity coverage, hive-vanished refresh, and true orphan cleanup. B's queued Team rows must survive or be re-homed during channel cleanup so their original-hive resend contract survives; C's socket privacy and retained harness must not prevent that work. C does not fix the recorded Team attachment-only baseline or redesign history reconciliation.

| Assumption / decision | Classification |
|---|---|
| One-result relay feeding a `for await` `.values` loop concretizes the no-loss requirement instead of relying on an unbuffered `incoming.values` consumer starting in time. Shared stream/API and wire stay as approved. | Non-blocking, delegated technical choice. |
| Named concierge methods return discardable Bool to distinguish transport rejection; existing callers are source-compatible. | Non-blocking, delegated technical choice. |
| Fresh concierge responses identify themselves with existing `mode == concierge`; legacy missing mode is accepted for known-ID resume only. No wire identity is invented. | Non-blocking, grounded in existing decoder/request/cache behavior. |
| Watchdog uses the same interval to remain armed while awaiting a server reply, pauses disconnected, re-arms on reconnect/busy reply/replacement, and never creates queue eligibility. | Non-blocking, delegated lifecycle detail of the approved server-query watchdog. |
| Coordinator run ownership and cancellation can change privately while the view body, user flow, cache format, and messages remain as specified. | Non-blocking, necessary async lifetime detail. |
| Local B evidence is existing coverage; the supplied 238 passing CI tests are predecessor evidence, not validation of C. | Non-blocking, corrected baseline. |

No blocking product questions were found. The next action is upstream spec review; this document does not authorize itself past that gate.
