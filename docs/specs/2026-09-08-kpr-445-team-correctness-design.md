# KPR-445 — Team-layer correctness

## TL;DR

Reconcile Team history by server identity and one bounded match to an unreconciled local row, preserving legitimate repeated messages. Correlate preview and full-page history requests, remove unqueued channel orphans while preserving original-hive delivery, and release an unanswered DM creation lock after 10 seconds. This is the final cleanup child after merged D; it adds only an optional `TeamMessage.serverId` attribute, uses the existing typed and persistence boundaries, and adds no wire protocol or screen layout.

## Key Points

- `TeamMessage.id` remains the row and bubble identity. New live/optimistic rows keep UUIDs; history inserts have `id == serverId`. `serverId` defaults to nil for existing stores and live rows.
- Pure `HistoryMerger` skips known server IDs, otherwise stamps at most one unreconciled row with the same channel, sender and text within the existing 30-second window; the closest date wins. A stamped row cannot match another server message. Distinct repeated messages survive.
- Full history and preview seeds retain their generated request IDs. Only the matching active full-page response changes loading, pagination and message reconciliation; seeds update previews only. Selection changes and connection teardown retire obsolete requests.
- Channel cleanup protects the union of queued and sent-but-unacknowledged local IDs, regardless of their `pending` flag. Queued attachment bytes and original-hive stamps survive real channel-list cleanup and delivery still occurs at the end of that hive's `onConnected`.
- A cancellable, request-scoped DM timer expires after 10 seconds with “Couldn't open a direct message. Try again.” Command maps clear after unacknowledged messages move to the offline queue on departure from connected state.
- The inspected server already echoes request IDs in the history envelope and ack. Live messages have no stored server ID, and neither ack nor history rows associate a client send ID with a stored message. E uses current capabilities; adding that association remains server follow-up work.
- ⚠ Delegated compatibility details: recognize pre-upgrade history rows by exact existing row-ID equality, retain the current strict `< 30 seconds` boundary, use deterministic date/ID tie-breaks, and spare runtime-protected rows without adding a stored hive field or relationship.
- ⚠ Keep D's lossless unknown values and shared reporting helper, VM-owned save-error banner, and nontransactional delivery. Preserve B/C/D behavior assertions, including pairing teardown, original-hive queues, private sockets, Chat/concierge lifecycle and typed-state failures. KPR-446/447/448 and the epic-to-main merge remain outside this child.

## Authority and inspected baseline

This is derived from the approved [cleanup epic design](2026-09-04-cleanup-epic-design.md), Child E, the [Gate 1 package](https://linear.app/keepur/issue/KPR-441/epic-ios-cleanup-structural-debt-and-silent-failures-pre-ux-epic#comment-9280145a), and its unconstrained [Approved signoff](https://linear.app/keepur/issue/KPR-441/epic-ios-cleanup-structural-debt-and-silent-failures-pre-ux-epic#comment-21fb1443). That signoff delegates technical child-spec choices; it does not authorize new product scope. [KPR-445](https://linear.app/keepur/issue/KPR-445/e-team-layer-correctness-history-merge-orphaned-rows-dm-lock-hive) and all its B/C/D propagation comments bind the queue-preservation, typed-state and reporting requirements below.

The implementation starting point is D's merged epic head `49c3423ddf3057e9ae2b893b23dee325fe545094` (PR #107, ALIGNED). The current canon through D and the B/C/D derived specs remain binding. Read actual code at that head before implementation; this document is a specification, not an implementation plan or verification claim.

| Surface inspected | Present behavior and required change |
|---|---|
| `ViewModels/TeamViewModel.swift` | Private injected socket; dynamic credential reads; ordered hive-stamped queue; shared save wrapper. History discards response IDs, uses content-key dedup, and conflates seeds with pages. Channel deletion leaves messages behind. DM creation has no deadline. |
| `Models/TeamMessage.swift`, `Models/TeamChannel.swift` | String storage with typed computed accessors; no relationship between channels/messages and no stored hive ownership. E adds only optional `serverId` and removes the unused model `displayName`. |
| `Models/TeamWSMessage.swift` | Typed `TeamHistoryMessage.senderType`; outgoing `encodeWithId()` already returns the request ID; history/ack decode that ID. Live messages have no decoded stored-message ID. |
| `Managers/Persistence.swift`, `KeepurApp.swift` | One synchronous reporting helper; VM owns save-error presentation. Five existing models and automatic store migration/recovery remain. |
| Existing Team, pairing, Chat and concierge tests | Real in-memory SwiftData and a real `BeekeeperSocket` driven by `FakeWebSocketTask`; D has deterministic per-VM save injection. Extend behavior assertions rather than replacing them with implementation-only checks. |

### Server capability check

The local Hive source at `349d6d44bdb1d2fa410fce1ca19060fa314de005` was inspected in `src/channels/ws/protocol.ts`, `src/channels/ws/ws-adapter.ts` and `src/team/team-store.ts`. Beekeeper's `src/team-proxy.ts` at `df014f71fb1e44a49dd2b37d191673baa8d641b6` forwards frames without adding message identity. These are source observations, not an assertion about which revision is deployed.

- `ServerTextMessage` and its agent/command send sites contain text, agent identity, optional channel and `replyTo`; they do not contain the saved MongoDB message ID. The client therefore continues creating live agent/system rows with UUID `id` and nil `serverId`. Do not decode `replyTo` as a message ID.
- `handleHistory` returns envelope `id: msg.id`; its rows contain the stored `m._id`. `handleTeamMessage` echoes `msg.id` in ack before membership validation/persistence. The existing request echo enables page/seed correlation immediately, but an ack is not a durable-save receipt and cannot populate `serverId`.
- `TeamStore.saveMessage` allocates a new ObjectId; history rows do not expose the original client-send request ID. The remaining server follow-up is a reliable stored-ID on live frames and a send-request-to-stored-message association in acknowledgement/history data. Simply echoing the history request ID does not remove heuristic reconciliation. No server change is required or authorized by E.

## Problem, goals and boundaries

Current content-key dedup can discard later identical agent/system messages forever, while an unacknowledged own row may be duplicated because the own-message branch excludes pending rows. Multiple live rows with the same text also cannot be reconciled one-to-one. History responses are classified using whichever channel is active when they arrive, so a seed can complete a full-page spinner or overwrite its cursor after selection changes. A dropped `/dm` response can leave the creation lock held indefinitely. Channel removal cannot delete all messages indiscriminately: B relies on runtime-queued rows surviving the removal of their old hive's channel records.

The outcome is deterministic, lossless identity reconciliation within the approved heuristic; correctly owned history response state; bounded DM lock lifetime; and cleanup of messages that have neither a channel nor runtime delivery ownership. Keep the existing views, speech, command input, channel naming and optimistic send/ack flow.

No MessageStore, persistence service, transport rewrite, generic request broker, new dependency, stored hive identifier, new relationship, delivery transaction or exactly-once guarantee is introduced. Do not repair unrelated server pagination behavior, add an `after` API, redesign attachment-only sends, prune valid message history, or rebuild history after a long reconnect beyond the existing latest page. No new history-request timeout is required. Existing server errors, connection/error banner presentation, free-form commands, and documented typing/command-list no-ops remain.

## 1. Message identity and pure reconciliation

### Stored and value boundaries

Add `var serverId: String?` to `TeamMessage`, default nil, with an optional defaulted initializer argument. It is not unique and never replaces `id`. Existing String attributes, computed accessors and model container membership stay unchanged. Automatic lightweight migration must preserve pre-E messages and channels; the existing container-failure deletion path is not acceptable evidence of a successful migration.

All current live insertion paths—own `sendMessage`, `.teamMessage`, `.systemMessage`—keep local UUID IDs and nil `serverId`. New history inserts store the incoming server ID in both `id` and `serverId`, retain all incoming fields, serialize `senderType.wireValue`, and start unpended. A matched live row keeps its original `id`, text, sender values, thread and local date; only `serverId` and `pending` change. The approved match does not introduce a sender-type, sender-name or thread-equality condition.

`Models/HistoryMerger.swift` imports Foundation, not SwiftData. It owns value types and a pure entry point equivalent to the approved interface:

```swift
static func merge(
    existing: [TeamMessageSnapshot],
    incoming: [TeamHistoryMessage],
    ownDeviceId: String,
    now: Date
) -> MergeResult
```

`TeamMessageSnapshot` contains the local ID, optional server ID, channel, sender ID/type/name, text, thread, created date and pending flag as immutable values. `MergeResult` contains incoming rows to insert, server-ID stamps keyed by local ID, and local IDs to unpend. It contains no managed objects, context, callbacks, logging or saving. The VM converts fetched models to snapshots and applies the result synchronously on the main actor.

Pass the currently read `credentials.deviceId ?? ""` and one captured date at each merge. Own-device identity is never cached at configuration time, and does not restrict reconciliation to own messages or equate old and new device IDs. Date eligibility compares local and incoming dates, not their age relative to `now`; replaying an old page must have the same result. The extra call-time parameters do not authorize timestamp replacement or an age-based retention policy.

### Canonical rules and deterministic behavior

Before any heuristic match, reserve all existing server identities and all nil-`serverId` legacy rows whose local ID exactly equals an ID anywhere in the incoming batch. A legacy row awaiting its exact history item must not be consumed by an earlier identical-text item in that same batch. Process unique incoming IDs in ascending `(createdAt, id)` order. Within one merge, remember every server ID already represented or accepted and consume each matched local row once; newly inserted or stamped identities immediately count as known. A duplicate occurrence of the same server ID in a page or overlapping page is not a second message. Distinct server IDs with identical contents remain distinct.

For each incoming message:

1. **Known server ID:** if a local `serverId` already equals the incoming ID, skip the incoming row. Do not content-match another local row or rewrite the existing row's contents.
2. **Legacy history identity:** pre-E history rows already use the server ID as `id`, but migrate with nil `serverId`. Exact `local.id == incoming.id` on such a row is known identity: record its server-ID stamp and clear pending without inserting or using the timestamp heuristic. This is an additive compatibility bridge, not an eager migration, ObjectId-shape guess, or unique-ID upsert policy.
3. **One unreconciled match:** from rows with nil `serverId` not already consumed or reserved for exact identity, choose at most one with exactly the same channel ID, sender ID and text and `abs(local.createdAt - incoming.createdAt) < 30 seconds`. Pending and acknowledged rows are both eligible. Minimize absolute time difference; tie-break by earlier local date, then lexical local ID. Record the stamp and unpend that row. Never match a row already reconciled to another server ID.
4. **Insert:** if neither identity nor bounded match applies, return the incoming row for insertion with both IDs set to its server ID.

The strict boundary preserves the actual predecessor constant: exactly 30 seconds does not match. Structured field comparisons replace the `senderId + "|" + text` content key, avoiding delimiter collisions. Result inserts have deterministic chronological order; applying a result and merging the same page again produces no further insert/stamp work. No rule deletes an existing row. When multiple pre-existing local copies already represent one server message, E does not collapse them by guessing which history to erase.

### VM integration and runtime queues

Only an accepted full-page response invokes the merger. Fetch the relevant channel's existing rows once through `fetchOrEmpty`, convert to values, apply the result and use the VM's existing reporting save wrapper. Continue refreshing `activeMessages` by a date-sorted fetch; do not append managed rows directly or change `lastLiveMessageId`/speak for history. Fetch failure keeps D's existing empty-input continuation; save failure shows the existing banner and does not roll back the in-memory merge or change delivery semantics.

Runtime queue ownership is separate from the `pending` presentation flag. A heuristic history match is not an ack of a particular send request: do not clear `offlineEntries`, retained attachment bytes or `pendingMessageIds` on its basis. They retain B's resend/ack/reset rules, including possible duplicate text after an ack is lost. An offline badge can therefore continue to win while its row has been unpended by history. In particular, rows owned by an offline entry for a different hive must not be stamped or unpended by this hive's history; exclude those protected foreign-hive rows from reconciliation candidates and apply no result to them. Do not reinterpret their channel IDs or move their queue stamps to the current hive.

## 2. History request ownership and previews

Keep private `activeHistoryRequestId: String?` and `seedRequestIds: Set<String>` (or equivalent value-backed storage with these roles). Also retain each request's channel and connection/hive ownership so a response with the right ID and wrong channel cannot be accepted. This is small VM bookkeeping, not a reusable request service. IDs are registered only for accepted sends, synchronously without suspension; both the full-page path and seed loop use `sendWithId` instead of the fire-and-forget wrapper.

`fetchHistory(channelId:)` serves the selected channel's full-page request; current production callers are selection, reconnect gap-fill and active pagination. A call for a nonselected channel does not acquire the active loading state or start a competing full-page request. Keep a single full-page request in flight for the selected channel. A preview seed may remain in flight when that channel becomes selected.

| Event | Required effect |
|---|---|
| Select a channel | Retire the previous active full request even if loading; clear its loading state, set the selection, reset that channel's cursor and `hasMoreHistory`, refresh local rows, and request the latest 50. Same-hive seeds may remain registered. |
| Paginate | With no active full request, request 50 using the selected channel's `lastServerMessageId`. A failed/empty channel lookup retains nil `before` and still sends, as in D. |
| Send rejected/offline | Leave no registered request or stuck spinner. Keep cursor/`hasMoreHistory` unchanged beyond any explicit selection/reconnect reset. The existing connection banner supplies connection truth; add no new error copy. |
| Channel list | Keep the existing skip of the active channel when issuing one-message seeds. Register each accepted seed with its channel; seeds are preview requests, not cached full-page loads. |
| Matching active full response | Require matching ID, channel and current ownership. Consume the request once, merge rows, take `hasMoreHistory` from the response, clear loading, refresh active messages and update the channel preview from the newest row. Advance `lastServerMessageId` to the oldest response row, independent of wire array order and whether that row inserted or merely matched. |
| Matching seed response | Consume its ID once and update only that channel's preview using the newest returned row. Do not insert/stamp/unpend messages, set a cursor, set `hasMoreHistory`, clear an active spinner, or update `lastLiveMessageId`. This remains true if the seeded channel has since become active. |
| Empty response | A matching full response still ends loading and adopts `hasMore`; it leaves the cursor unchanged. An empty seed leaves preview fields unchanged. |
| Unmatched, duplicate, wrong-channel or retired response | Log a static diagnostic and ignore the response completely. Do not insert rows, change previews or consume another valid request. A wrong-channel reply does not consume the valid request ID. |

Use deterministic date/ID tie-breaks for oldest/newest choice when timestamps are equal. The server's existing `before` contract remains unchanged. A preview must keep text and timestamp together: an older seed/page cannot replace the text of a newer live or history preview while leaving the newer date. Only a candidate at least as recent as the stored preview date updates both preview fields; retain the existing 100-character text prefix and sidebar sorting.

On a connection transition out of `.connected`, explicit disconnect, pairing teardown, or actual hive change, retire full/seed request records and clear active loading. Reconnect obtains fresh IDs and resets the selected channel cursor for the latest-page gap fill before ordered offline resend. No state-sink send is introduced. When a channel is removed by a successful cleanup, retire its requests; clear selection/messages/loading if that existing selected channel was removed. The existing missing-channel event lookup remains a no-op for selection/messages.

An existing unscoped `.error` cannot identify a failed history request. Conservatively retire the current active full request and clear its spinner so the existing load action can retry; retain cursor/`hasMoreHistory` and the existing server-error banner. It does not authorize a response with an unregistered ID afterward. Silent unanswered history on an otherwise connected socket gains no new deadline in this child.

## 3. Thin channel cleanup with queued-row retention

Add `Models/TeamStore.swift` as a thin, synchronous SwiftData helper. Its channel deletion operation accepts the context, channel and protected message-ID set (an equivalent context-bound helper is fine). It fetches the channel's messages through the existing reporting helper, deletes unprotected messages first, then deletes the channel. It performs no implicit save, retries, rollback, queue mutations or error presentation. The calling VM retains its save boundary and banner ownership.

The protected set is the union of `offlineEntries.map(\.localId)` and `pendingMessageIds.values`, captured on the main actor for that cleanup. It is not all rows with `pending == true`: a persisted pending row after relaunch has no runtime resend ownership. Conversely, an unpended row can still have runtime ownership and must be retained. Protect all queued hives, including attachments and unacknowledged text; preserve the existing row `channelId` so it can be used when its original hive reconnects. No hidden replacement channel or re-homing storage is needed.

Use this deletion path for all three existing removal sites: channels absent in `syncChannels`, a found channel left by the current device, and a found archived channel. Non-self leave behavior, typed DM membership, channel insertion/update and missing-row event continuations stay unchanged. A message-fetch failure deletes no messages but retains the original channel-deletion/save continuation; it logs through the helper, without manufacturing a user save error.

To prevent previously protected rows becoming permanent unqueued orphans, a successful complete channel synchronization also removes unprotected messages whose channel no longer has a local row after that synchronization. This is narrowly orphan cleanup, not age/count pruning. It covers pre-E orphan rows and rows whose in-memory protection ended since an earlier cleanup. Use the helper's failure output to skip this additional sweep when the channel inventory could not be read; a failed inventory is not evidence that every message is orphaned. Failure of the orphan-message fetch performs no deletions. Preserve the original sync insertion/save/load continuation in either case.

Do not delete history as a side effect of pairing teardown or an ack: those retain B's existing persisted-row semantics. The next successful channel sync can collect rows that then meet the orphan definition. Ordinary disconnect, a hive switch and the hive-vanished path keep queue entries and bytes. Resend still runs at the end of `onConnected`, only for its original hive, without waiting for `channel_list`; missing-row drops affect one entry, rejected sends stop the pass, and already-submitted attachments are not replayed as unacknowledged text.

## 4. Command maps, hive changes and DM lifetime

### Connection-owned state

In the existing `previous == .connected && state != .connected` branch, first run `moveUnackedToOffline()` with the departing `activeHive`. Then clear `pendingCommandChannels` and `pendingNewCommands`; cancel the pending DM attempt and retire history request state. Clearing command maps must still occur when there were no unacknowledged message mappings. Explicit disconnect and pairing reset idempotently cancel request/timer state even if already disconnected.

Preserve `connectIfPossible()` calling `socket.connect(channel:)` directly and assigning `activeHive` only after the call returns. The socket's synchronous channel-switch transition must collect the old hive's unacknowledged sends before that assignment. No preceding manual `disconnect()` is necessary, and no sends occur synchronously from `$state`. The socket stays private. Ordinary disconnect retains queue state and the old hive stamp; pairing reset clears queues and bytes through the existing weak callback chain.

Retain capability refresh at reconnect attempt 1 and the existing “This hive is no longer available.” banner/disconnect path. The state-driven banner remains visible on later attempts. E must cover this branch and retention of the vanished hive's queued rows; it does not replace CapabilityManager's loading/auth ownership or add a new retry policy.

### DM creation deadline

Add a defaulted `dmTimeout: Duration = .seconds(10)` initializer argument, alongside existing injection, and one private cancellable timer/task with an attempt token. Arm it only after an accepted `openAgentDM` `/dm` send. An existing DM still selects immediately; a second creation tap while the lock is held remains ignored. Offline/rejected commands use “Not connected. Try again when reconnected.” without acquiring a lock or timer.

The attempt tracks the requested agent and connection ownership independently of `pendingDMRequestId`, which also serves response suppression. A matching system response may clear the suppression ID and request channels; it does not restart or cancel the deadline while waiting for the DM to appear. A channel list lacking the requested DM keeps waiting until the original deadline; remove the predecessor's early unlock based only on the suppression ID becoming nil.

Successful synchronization of the exact `.dm` channel containing the requested agent selects it and clears the creation lock, timer and any remaining command-refresh mapping for that request. If its system response has not arrived, preserve the suppression ID until that reply or teardown: an early channel list must not turn the later `/dm` response into a chat bubble. Unknown channel kinds cannot complete a DM. A server `.error` cancels/clears the attempt and both DM fields and retains that error's current banner behavior. Disconnect, hive change, reconnect initialization, pairing reset and VM destruction cancel old work without displaying a timeout error.

At expiry, the task verifies its token and connection ownership, then clears `pendingAgentDM`, `pendingDMRequestId`, the pending attempt/task, and that attempt's command-refresh entry, and sets `lastError` to exactly “Couldn't open a direct message. Try again.” The next tap can send again. An old cancelled timer must never unlock or error a newer attempt. The sleeping task captures the VM weakly and must not keep it alive across the delay. No retry or new channel-creation request is sent by the timer.

Late command replies retain the existing general system-message routing rules; they cannot clear a newer suppression ID or revive an expired auto-selection attempt. E adds no durable reply tombstone registry or request correlation to channel-list wire frames.

## 5. Persistence, typed boundaries and naming

Every new/moved fetch uses `fetchOrEmpty`; every save remains through the existing VM wrapper and `saveReporting` with the existing instance `saveOperation`. Static operation labels identify new history/cleanup work. Log no message text, sender/channel/message/request IDs, model contents, paths, token, URLs, frame bodies or error descriptions/userInfo. Correlation diagnostics need only a static reason, not the mismatched identifiers.

The save-error copy remains “Couldn't save. Your last change may not be kept.” Success and fetch failures do not reset its identity or auto-clear deadline. Save failure is not a reason to abort optimistic delivery, undo stamps, restore deleted objects, retry persistence or reinterpret acknowledgements. The helper remains the only catch/log implementation; TeamStore has no banner access. Any test seam for a newly introduced operation remains local and instance-scoped, using the same helper catch; no global hook or storage abstraction.

Preserve typed `TeamHistoryMessage.senderType`, exact `ChannelKind.dm/channel` checks, `TeamMessage.typedSenderType` and all supplied unknown raw values. New history rows round-trip unknown sender values; matching existing rows does not normalize their stored type. Live system messages retain `senderId == "system"` and sender type `.agent`, as in D. Do not add a live sender field or reinterpret command/event/hive strings as these enums.

Delete `TeamChannel.displayName`. Keep `TeamViewModel.displayName(for:)`: agent lookup for a known DM, server name fallback, `#` only for an exact named-channel kind, raw-name fallback for unknown kinds. Update CLAUDE's E status/contracts when implementation exists; do not claim E completion in this spec-only change.

## 6. Testing requirements

### Pure merger and model compatibility

Add `KeeperTests/HistoryMergerTests.swift` with fixed dates, explicit snapshots and no SwiftData. Assert outputs and a second merge after applying them as values, rather than internal data structures:

1. Known `serverId` skips; a pre-E history row with equal local ID is stamped in place, even when an earlier identical-text incoming item might otherwise consume it; repeated IDs within a page and overlapping pages remain idempotent.
2. One live agent row is stamped rather than duplicated; system-ID/agent-type rows use the same rule; local ID, text/date/type/thread remain intact.
3. Two distinct identical history messages both insert with no local candidate; with one candidate, exactly one stamps and the other inserts. Two local candidates can each be consumed once. Reconciled rows never content-match again.
4. Own pending and acknowledged rows both stamp/unpend, using exact sender IDs. A different channel/sender/text never matches, including strings containing the former delimiter.
5. Closest date wins with multiple candidates; exact ties are deterministic under shuffled snapshot/page order. Just inside the window matches, exactly 30 seconds and outside it insert. Distant `now` does not change eligibility.
6. Chronological result ordering, empty inputs, thread retention, and unknown sender values survive without introducing known-type membership.

Add real SwiftData tests for new-row nil defaults, a history insert with both IDs, saved/reopened stamps with stable local ID, and legacy exact-ID adoption. Verify lightweight migration using a pre-E store fixture or a reproducible two-version store check: existing own/live/history rows and channels survive with nil `serverId`, then reconciliation stamps the same rows. Record evidence that the container recovery deletion path did not run; do not change production recovery or uniqueness policy to manufacture this evidence.

### Team behavior integration

Use the current injected socket/fake task and real in-memory context. Capture actual encoded outgoing request IDs and deliver matched frames; update old arbitrary-ID history fixtures so assertions still exercise accepted history. Prefer request/receive latches and bounded eventual assertions. Inject a short DM duration; do not sleep for 10 seconds in tests.

| Behavior group | Required observable assertions |
|---|---|
| History ownership | Seed issued while a channel is inactive, then selection sends a full request for that channel. Exercise both reply orders: seed changes only preview; full controls loading/cursor/hasMore and rows. Prove seed does not persist a message. |
| Retirement | Switch selected channels while loading; the new full request sends immediately. Old response, duplicate response, wrong-channel same-ID response, and old-connection/hive response leave current state/rows/preview untouched. A later valid response still works. |
| Cursor/preview | Ascending and descending page arrays yield the same oldest cursor/newest preview; a fully deduplicated page still advances cursor. Empty full response clears loading, while empty seed changes nothing. Older seed/page cannot pair old text with a newer preview date. |
| Request failures | Offline/rejected history send leaves no stuck spinner; reconnect sends a fresh latest-page request. Existing unscoped error releases active loading without accepting a later retired response. |
| Real merger bridge | Drive own optimistic send, live agent/system insertion and matched history; inspect persisted server IDs, stable bubble IDs and pending flags. Confirm history is silent for speech/lastLiveMessageId and does not become a transport ack or drop attachment/queue ownership. |
| Re-pair identity | The same VM observes changed credentials on new sends and history merge; the new sender matches its own row, never a different old-device row. Keep production-bound teardown before re-pair and test with actual outgoing/decoded frames. |
| Cleanup | For each of sync absence, self-left and archived, seed a real channel plus messages; remove unqueued messages/channel, keep unrelated channels/messages, and preserve queued/unacknowledged rows regardless of pending flag. Missing-channel events retain D's no-op continuation. Later successful sync collects a previously protected row only once it has neither channel nor runtime protection. |
| Cross-hive delivery | Extend B's never-sent attachment and unacknowledged text cases through real hive B `channel_list` cleanup of hive A's channel. Prove the row, original stamp, byte payload and order survive; hive B emits none of A's payload; return to A emits it with fresh request ID and correct channel. Include a direct connected hive switch, not only manual disconnect. |
| Command lifetime | Queue an unacknowledged message and start `/new`/`dm`, then leave connected. Prove the old message remains queued for its old hive and late command IDs no longer trigger their retired channel-refresh/routing association. Test the no-unacknowledged-message branch too. |
| DM deadline | Offline rejection; rapid-tap lock; timeout copy and retry; system response then missing DM list still waits to deadline; exact DM arrival cancels timer and selects, including channel-before-system-response suppression; error/disconnect/hive change/pairing reset cancel; an older timer cannot affect a new attempt; releasing VM releases the sleeping task's ownership. |
| Hive vanished | Drive the attempt-1 capability refresh completion with no valid hive; assert exact banner, disconnect, original-hive queue/bytes retained and no sends from the state sink. Also retain the valid-hive/later-attempt behavior. |
| Persistence/typed regressions | Force a history/cleanup save failure through the existing save injection and assert banner plus the defined continuation. Preserve current error on successful save/fetch miss; test failure-aware orphan sweep without invalid containers. Retain unknown sender/channel raw strings and VM display-name behavior. |

If deterministic hive-refresh coverage needs a seam, use a narrowly scoped per-Team-VM async refresh operation defaulting to `await manager.refresh()`, so the test can complete the existing branch without network or global Keychain mutation. CapabilityManager still owns loading/coalescing/auth in production. Do not resolve standalone KPR-447 by broadly rewriting the harness in this child.

### Additive regression and completion evidence

Retain all B/C/D behavioral assertions; fixture updates for actual request IDs or renamed fields are allowed, assertion removal is not. This includes Team queue/attachment order, missing-row drop/rejected-send stop, four synchronous pairing origins and idempotent reset, Chat FIFO/reconnect fallback/full-list fetch failure, lazy speech, post-handler publication, concierge matching/cancellation/identity, isolated approvals, watchdog server-authority, typed unknown/terminal behavior and shared persistence error identity. D's unknown-sender history test must still prove raw-value preservation and no forced agent classification after replacing the old content-key logic.

Run focused merger/model/Team/codec/pairing tests and the applicable reporting tests while implementing. The completion gate remains the full signed iOS Simulator `KeeperTests` suite and local macOS build from CLAUDE, plus the quality gate and final-head review. New production/test files must participate in both app platforms and the synchronized test group. Verify zero production `try?` save/fetch calls, no `print(` in Managers/ViewModels, no old socket managers or view socket access, and no remaining model `displayName` consumers. The local KPR-446 exclusion does not waive full unexcluded GitHub CI at the final reviewed PR head. D's 298-test CI result is predecessor evidence, not E verification.

## Delegated assumptions and remaining questions

| Decision | Status |
|---|---|
| Exact existing row-ID equality bridges pre-E history identity; no eager data rewrite or string-shape inference. | Non-blocking, required additive-store compatibility. |
| Strict `< 30 seconds`, ascending incoming date/ID order and closest/date/local-ID tie-breaks make the approved rule deterministic. | Non-blocking, delegated mechanics grounded in the predecessor boundary. |
| Preserve runtime-protected rows in place; sweep only true unqueued orphans at successful channel sync. Queue protection is independent of the pending flag. | Non-blocking, fulfills B propagation without another schema change. |
| History changes message identity/presentation, not acknowledgement ownership; loss of ack can still duplicate text. Foreign-hive queued rows are excluded from this hive's reconciliation. | Non-blocking, retains B/D delivery semantics and original-hive protection. |
| Seed replies are preview-only; error/lifecycle invalidation releases obsolete full-page loading, and preview date/text update together. | Non-blocking, necessary ownership mechanics of the approved history race fix. |
| The DM deadline continues after response suppression until matching channel arrival; timer token/lifetime handling and short test injection are private mechanics. | Non-blocking, implements the approved 10-second unanswered-DM contract. |
| Local server source lacks live stored-message ID but already supports envelope request echo. Deployed feature parity is not assumed beyond the existing codec contract. | Non-blocking; remaining message association work is server follow-up, not an E dependency. |

No blocking product questions were found. This draft is ready for upstream spec review; it authorizes no implementation, commit, PR, PM mutation or main merge by itself.
