# KPR-444 — Typed state and reported persistence failures

**Date:** 2026-09-07

**Status:** Draft for spec review; routine decisions delegated by Gate 1

**Child:** [KPR-444](https://linear.app/keepur/issue/KPR-444), D of KPR-441

**Implementation baseline:** merged Child C / PR #106, `fe6907b60933869fff46cdcba260010f53e2a235`

**Authority:** approved [cleanup epic design](2026-09-04-cleanup-epic-design.md), Child D; [Gate 1 delegation](https://linear.app/keepur/issue/KPR-441/epic-ios-cleanup-structural-debt-and-silent-failures-pre-ux-epic#comment-21fb1443); decision-register canon through C / [coherence ruling](https://linear.app/keepur/issue/KPR-441/epic-ios-cleanup-structural-debt-and-silent-failures-pre-ux-epic#comment-2e03cacc).

## TL;DR

Replace six string state domains with enums and route all 62 current SwiftData fetch/save calls through one reporting helper family. Keep stored attributes, wire shapes, queue ownership and the post-C Chat/concierge lifecycle intact; failed saves use the existing error banner and failed fetches preserve each caller's current continuation or skip. Also connect the existing capability loading state to the hive picker, remove the always-zero unread badge, document intentionally ignored Team frames, and correct stale documentation, ATS configuration and the remaining model log.

## Key Points

- `SessionStatus`, `MessageRole`, `SessionMode`, `SenderType`, `ChannelKind` and `AgentStatus` replace domain string comparisons. Wire decoders emit typed values; persisted `Message.role`, `TeamMessage.senderType` and `TeamChannel.type` remain strings with computed accessors. There is no schema migration or wire change.
- Unknown session statuses preserve their raw text and remain active; `session_ended` is terminal and never earns an idle queue release. One agent presentation supplies existing labels, header text, activity and theme tint to all three consumers.
- The verified inventory is **32 Chat calls, 26 Team calls and four view calls**, still 62 total, rather than the historical 34/24/4 distribution. There are 32 fetches and 30 saves. Every save/fetch failure is logged, and every VM save error sets the exact approved banner copy.
- An error-reporting overload of `fetchOrEmpty` distinguishes failed fetch from successful empty fetch. In particular, Chat's full-list fetch must succeed before consuming reconnect/fallback ownership or mutating table/status/queue state; list reconciliation still uses all server identities, including concierge.
- Capability refresh already sets `isLoading`; the missing connection is in `HivesGridView`. Existing hive cards remain visible during refresh, and an empty loading picker uses a standard progress indicator in the existing content region. Empty-state copy and navigation stay unchanged.
- ⚠ **Delegated compatibility detail:** unknown session-mode, sender-type and channel-kind strings get lossless enum cases. Falling back to known values would change the current parser, Session-table filtering, history dedup or DM classification. MessageRole preserves its explicit `unknown` role separately from an unrecognized stored value.
- ⚠ **Delegated test correction:** SwiftData uniqueness collisions are documented as upserts, so duplicate IDs are not a deterministic throwing-save fixture. Exercise actual successful SwiftData persistence and uniqueness separately from a deterministic thrown-error path through the same helper; do not make production save reject duplicates to satisfy the old test wording.
- ⚠ **Delegated canon alignment:** the current full-list branch can preserve a previous busy state when the server reports `session_ended`. Give the typed terminal case explicit existing `endSession` cleanup before busy/busy reconciliation, with a regression proving no send or idle release. This narrow inherited gap is identified below rather than presented as a completed C guarantee.
- No MessageStore, persistence service architecture, server-owned concierge mode, new layout, unread feature, Team history redesign or E schema work. All B/C behavioral assertions remain the regression baseline.

## Problem and outcome

Post-C code still accepts and compares runtime state strings in the codec, VMs and views. Chat's header/indicator and watchdog disagree about unknown non-idle status, and agent presentation is spread across `AgentRow`, `AgentDetailSheet` and `TeamChatView`. Persisted messages and channels must remain readable by the current SwiftData schema, so directly replacing stored string attributes with enums would violate the epic's migration constraint.

All 62 current persistence calls swallow errors with `try?`. A failed fetch does not mean the same thing at every caller: some paths intentionally continue with an empty array, some skip a mutation or send, and Chat's full-session fetch protects reconnect ownership. Save errors currently continue execution but tell the user nothing. The desired change reports those failures while retaining the existing business decisions and operation order.

This child also closes the specifically assigned small cleanup items. It does not reopen B/C's approved queue or lifecycle policies. C is an implemented predecessor because PR #106 is merged and accounted for; its Linear workflow state remaining In Review until Gate 2 does not change this baseline.

## Scope and integration surface

Production changes are limited to the six typed domains and their consumers, `Managers/Persistence.swift`, persistence call sites, `HivesGridView`, `AgentRow` badge removal, Team no-op comments, `Models/ConciergeSessionStore.swift`, `CLAUDE.md` and `Info.plist`. Tests change to exercise these contracts and adopt typed fixtures without dropping predecessor assertions.

Use `Models/SessionStatus.swift`, `Models/MessageRole.swift` and `Models/SessionMode.swift` for the three Chat domains. Keep Team wire domains in `Models/TeamWSMessage.swift`, as the epic specifies. Agent UI presentation may be an `AgentStatus` extension in `Views/Team/AgentStatusPresentation.swift` so decoding/model definitions remain independent of SwiftUI/theme types. This still exposes one `AgentStatus.presentation` to all consumers. Existing synchronized project groups discover new files automatically.

Keep `ConciergeViewModel` in `Views/BeekeeperRootView.swift` and retain that view's vestigial concierge cleanup; D changes its persistence calls, not ownership. Leave `Workspace` identity/schema, `KeepurApp` container recovery, speech ownership, transport, outgoing encode-error handling and existing imports/layering outside this change. Do not reinterpret all strings in the project as one of the six domains: capability authorization roles, hive names/socket channels, slash-command names, tool names and channel event strings are distinct values.

E still owns history request correlation, additive optional `TeamMessage.serverId`, `HistoryMerger`, orphan deletion/queued-row preservation, DM timeout and the remaining Team correctness work. D must not repair current Team history matching or cleanup policy while replacing its literals and persistence calls.

## Typed state design

### SessionStatus

`SessionStatus` is `Equatable`, with `init(wire:)` and a lossless `wireValue` for boundary/tests. Known values are case sensitive; there is no normalization, trimming or default-to-idle for an unrecognized string.

| Wire value | Case | `isActive` | `headerText` |
|---|---|---|---|
| `idle` | `.idle` | false | nil |
| `thinking` | `.thinking` | true | `thinking` |
| `tool_starting` | `.toolStarting` | true | `starting tool` |
| `tool_running` | `.toolRunning` | true | `running tool` |
| `busy` | `.busy` | true | `server busy` |
| `session_ended` | `.sessionEnded` | false | `session_ended` |
| Any other string, including empty | `.unknown(raw)` | true | unchanged raw string |

`WSIncoming.status.state` and `ServerSession.state` become `SessionStatus`; `ChatViewModel.sessionStatuses` becomes `[String: SessionStatus]` and `statusFor(_:)` returns `.idle` for absent entries. Views read `headerText`/`isActive` directly, removing the copied Chat mapping and two literal arrays. `StatusIndicator` takes a typed status, preserves tool-specific text for starting/running, and uses raw text for the unknown fallback; it does not reintroduce a second activity predicate.

Use `.isActive` for watchdog/indicator eligibility, not as a universal replacement for `== .idle`. Queue admission/release preserves B's distinction: only an explicit idle state is eligible to send a queued head. Terminal is not idle, and an unknown state stays busy. Tool-name storage, stream round boundaries and status-frame cleanup continue to distinguish the existing individual cases.

Preserve C's full-list sequence at `ChatViewModel.swift:797–863`: derive full server IDs and the concierge/table subsets; successfully fetch local Session rows; snapshot and consume reconnect bookkeeping; reconcile rows, absent IDs and full-list status; save; update stale selection; flush through the existing gate. A save failure surfaces an error but does not roll back or undo this sequence.

**Inherited terminal gap and narrow alignment:** at baseline lines 845–856, `syncSessions` treats every non-idle incoming value as its busy branch and leaves the old status untouched when `wasBusy` is true. Consequently a listed `session_ended` can retain earlier `thinking`/tool detail and its watchdog. This is a pre-D implementation gap in the consolidated post-C path, not a new C feature decision. The canon explicitly says `session_ended` is terminal; implement an explicit `.sessionEnded` branch using existing `endSession(id)` before the ordinary active/busy branch. It clears transient stream/completion/status/tool/approval/queue/watchdog state, issues no send and grants no idle release. It does not delete Session rows, invent a server command, make the row stale while its ID is present, or change selection beyond existing stale-selection rules. Apply this only after the successful fetch boundary. Preserve ordinary busy/busy detail, busy-to-idle release, repeated-idle suppression and absent-ID behavior. This change must be isolated in review and covered by a listed-terminal regression.

### Remaining domains and unknown-value policy

| Domain | Known cases | Unknown/default behavior and typed consumers |
|---|---|---|
| `MessageRole: String` | `.user`, `.assistant`, `.system`, `.tool`, `.unknown` | Keep the five raw values from the epic. `Message.typedRole: MessageRole?` returns nil for an unrecognized stored string, without rewriting it. `MessageBubble` preserves the current distinction: literal `unknown` uses the unknown bubble; an unsupported raw role retains the current assistant-bubble fallback. Speech eligibility remains specifically `.assistant`. |
| `SessionMode` | `.sessions`, `.concierge` | `.unknown(String)` retains supplied unknown values. Only a missing/non-string mode keeps the current decoder default `.sessions`; a supplied unrecognized mode must not be relabeled `.sessions`. Both `ServerSession.mode` and `WSIncoming.sessionInfo.mode` are typed. Concierge discovery, fresh-spawn matching and full-list Session-table eligibility remain exact case checks. |
| `SenderType` | `.person`, `.agent`, `.system` | `.unknown(String)` preserves a history sender type through decode, comparison and storage. `TeamHistoryMessage.senderType` is typed; `TeamMessage.typedSenderType` converts its string attribute without mutation. Only `.agent` matches the existing agent-history predicate. Current system-message routing still uses `senderId == "system"`; do not change it to a new sender-type rule. |
| `ChannelKind` | `.channel`, `.dm` | `.unknown(String)` preserves a supplied channel type. `TeamChannelInfo.type` is typed, and `TeamChannel.kind` computes from its existing `type: String`. Unknown kinds remain neither a DM nor a named channel; their display name keeps the current raw-name fallback. |
| `AgentStatus` | `.idle`, `.processing`, `.error`, `.stopped` | `.unknown(String)` preserves a supplied status; only missing/non-string `agent_list.status` defaults to `.idle`, as now. `TeamAgentInfo.status` is typed. All UI uses its single presentation value. |

Lossless enums expose `init(wire:)`/`wireValue` and `Equatable`. The small raw enums in the epic are sketches of known values; the explicit unknown policies above preserve behavior that their naive failable raw-value initializers would lose. No enum is persisted as a new attribute or a transformable.

SwiftData constructors may retain their raw-string forms for compatibility, with typed overloads where they improve production call sites. All new production state decisions use the accessor/enum; assignments at the string storage boundary serialize the known or preserved raw value. Existing `#Predicate` expressions must continue to use stored attributes and representable raw constants, never computed accessors inside SwiftData predicates. Accessor reads do not normalize old data; a typed setter, if supplied, changes only the existing string attribute.

Neither incoming Chat messages nor live Team messages gain new wire role/sender fields. Their role/sender type remains inferred from the existing incoming case. Known outgoing values, including concierge mode, encode exactly the same strings and frame shapes as before. Preserve malformed/missing required-field handling, entry `compactMap` behavior, optional fields and Team's unknown-frame drop behavior.

In particular, Team's current `.systemMessage` handler writes sender ID `system` with sender type `agent`; preserve that as `.agent`, rather than opportunistically rewriting it to `.system`. Keep Chat's user/assistant/tool/system/unknown row assignments and Team's outgoing-person/incoming-agent assignments unchanged. Consumer adoption includes SessionListView's role-based preview, ChatView/streaming speech eligibility, TeamChatView's agent-only speech eligibility, Team DM lookup/sorting and channel display names, as well as the primary bubble/header switches.

### One AgentStatus presentation

Use one immutable presentation with `label`, `headerText`, `isActive` and theme `tint`. These explicitly named fields preserve the current difference between a title-cased detail label and a short chat status; consumers do not maintain their own status switches.

| Status | Detail `label` | Chat `headerText` | `isActive` | Tint |
|---|---|---|---|---|
| idle | `Idle` | nil | false | `.success` |
| processing | `Processing` | `working` | true | `.warning` |
| error | `Error` | `error` | false | `.danger` |
| stopped | `Stopped` | `stopped` | false | `.danger` |
| unknown(raw) | Existing first-character capitalization of raw | raw, unchanged | false | `.muted` |

An absent active agent gives nil header text and false activity through optional access, not a fabricated idle agent. Empty unknown text remains empty. `AgentRow` reads tint; `AgentDetailSheet` reads label/tint; `TeamChatView` reads header text/activity. Keep theme components presentation-only; do not teach `KeepurStatusPill` or `KeepurChatHeader` the domain enum.

## Persistence helper and caller behavior

### Shared contract

`Managers/Persistence.swift` extends `ModelContext` with the two approved entry points:

```swift
func fetchOrEmpty<T: PersistentModel>(
    _ descriptor: FetchDescriptor<T>, _ what: StaticString
) -> [T]

@discardableResult
func saveReporting(_ what: StaticString) -> Error?
```

Add a minimal `fetchOrEmpty` overload with `failure: inout Error?`. It resets that output to nil before each attempt, returns rows on success, and on catch logs once, puts the original error in the output and returns `[]`. The two-argument form delegates to that same implementation and discards the failure output. This is needed because the approved `[]` fallback alone cannot preserve successful-empty versus failed-fetch behavior. No mutable global "last fetch error" or separate persistence manager is introduced.

Each operation is synchronous on its caller's actor and attempts the requested fetch/save exactly once. There are no retries, implicit saves after fetch, rollback, automatic deletion, migration, queue changes or error suppression. `saveReporting` returns nil on success and the original thrown error on failure, never throws outward, and does not pre-check uniqueness or change SwiftData's merge behavior.

All failure logging is centralized through `Log.persistence`, with the static operation label and safe error identity such as error type/code. Do not log descriptions/userInfo, model contents, message text, IDs, paths, URLs, tokens or frame bodies: database errors can embed stored values. Use compile-time labels such as `"chat.syncSessions.fetch"`, not interpolated identifiers. Success needs no log.

Inside either VM, each non-nil save result sets `lastError` to a new `UserFacingError("Couldn't save. Your last change may not be kept.")`. A tiny private VM save wrapper may centralize this assignment, but every current save still occurs at the same place/order. A successful save must not clear an earlier persistence or server error; B's dismiss/identity-checked six-second timer remains the owner of clearing. Fetch failures log only. The three direct view saves log only and do not acquire a new banner, alert or VM dependency.

The added error message does not make persistence transactional. In particular, a failed optimistic-message save still continues the existing send/queue path, preserves in-memory rows and clears the input as before; a later successful save can commit pending changes. Do not add a resend/rollback/retry policy or reinterpret socket acceptance as persistence success. Conversely, do not execute a save which a failed-fetch guard used to skip, because that could commit unrelated pending changes.

### Exact fetch inventory and preservation requirements

The following baseline line numbers identify **all 32 fetch sites**; implementation plans must retain this inventory with resulting call sites and review each continuation. "Failed or empty" below means the existing `.first` semantics intentionally conflate those outcomes; a successful empty *array* is different where the table explicitly says so.

| File / baseline line | Caller / fetched model | Behavior to preserve on fetch failure |
|---|---|---|
| Chat 419 | `.sessionInfo` / matching Session | Enter existing insertion alternative; continue save, selection/status and workspace flow. |
| Chat 440 | `.sessionInfo` handoff / old Session | Skip old-row deletion and its nested save; still continue workspace flow. |
| Chat 479 | `.contextCleared` / old Session | Skip recording a path/name handoff; continue message cleanup and transient cleanup. |
| Chat 490 | `.contextCleared` / Message array | Skip deletion **and nested save**, then continue transient cleanup. A successful empty array still performs the existing save. Use failure output. |
| Chat 513 | `.sessionReplaced` / old Session | Keep nil old row/name; continue new-row insertion/update, message migration, selection and runtime-state migration; skip later old-row deletion/save. |
| Chat 519 | `.sessionReplaced` / new Session | Enter existing insertion alternative; continue following steps. |
| Chat 534 | `.sessionReplaced` / Message array | Skip message migration **and its nested save**, but continue selection/runtime-state/old-row/workspace steps. A successful empty array still saves. Use failure output. |
| Chat 757 | final streaming chunk / current Message | Skip append/save; retain the existing final speech/completion bookkeeping that follows. Do not insert a replacement row on lookup failure. |
| Chat 772 | final speech / completed Message | Skip speech; continue completion bookkeeping; do not construct lazy speech as a side effect of failure. |
| Chat 785 | nonfinal chunk / current Message | Skip append/save; do not create a replacement message or alter stream identity. |
| Chat 806 | `syncSessions` / all Session rows | Return before consuming reconnect/fallback ownership, snapshot mutations, table/status/queue changes or save. `serverSessions` publication in the caller still happened. A successful empty array **must continue** and insert eligible server rows/reconcile statuses. Use failure output, never `guard !rows.isEmpty`. |
| Chat 878 | `deleteLocalSession` / Message array | Skip deletion loop; continue Session lookup and the existing unconditional final save. Empty-array iteration is equivalent; no extra error guard is required. |
| Chat 885 | `deleteLocalSession` / Session | Skip row deletion; retain the unconditional final save. |
| Chat 897 | `saveWorkspace` / matching Workspace | Enter existing insertion alternative; continue pruning and final save. |
| Chat 909 | `saveWorkspace` / stale Workspace array | Skip pruning loop; retain final save. Empty-array iteration is equivalent. |
| Team 288 | `selectChannel` / TeamChannel | Skip cursor reset; still fetch history. |
| Team 312 | `fetchHistory` / TeamChannel | Leave `before` nil; keep loading state and send the existing latest-page request. |
| Team 331 | `joinChannel` / TeamChannel | A failed or empty lookup still sends join; only a found row returns early. Do not invert the guard. |
| Team 357 | `onConnected` / TeamChannel | Skip cursor reset; retain bookkeeping sends, history fetch and end-of-handler resend ordering. |
| Team 400 | `moveUnackedToOffline` / TeamMessage array | Use an empty fetched order, then append the original unmatched IDs by the existing fallback iteration. Retain original-hive stamping and mapping removal order. |
| Team 420 | `resendOfflineEntries` / TeamMessage | Failed or missing row removes only this queue entry/attachment and continues; no send for it. Do not change this inherited behavior into stop/retry, and preserve rejected-send break behavior separately. |
| Team 570 | `.ack` / TeamMessage | Request mapping has already been removed; skip pending mutation, save and active-message refresh. |
| Team 605 | `syncChannels` / TeamChannel array | Continue with empty local list, insert supplied server channels, save and reload. Do not add a new guard or E's orphan policy here. |
| Team 652 | `loadChannels` / TeamChannel array | Publish empty channels and recompute sorted agents. |
| Team 674 | `processHistory` / TeamChannel cursor | Skip cursor mutation; continue dedup, inserts, save, preview and loading completion. |
| Team 687 | `processHistory` / TeamMessage array | Continue with empty dedup lookups and existing insertion logic. |
| Team 765 | joined-other-member event / TeamChannel | Skip member append and save; retain the existing duplicate-member condition. |
| Team 777 | self-left event / TeamChannel | Skip deletion, save, channel reload **and nested active selection/message clearing**. |
| Team 794 | archived event / TeamChannel | Skip deletion, save, reload **and nested active selection/message clearing**. |
| Team 815 | `updateChannelPreview` / TeamChannel | Skip preview mutation, save, sort and sorted-agent recomputation. |
| Team 851 | `refreshActiveMessages` / TeamMessage array | Publish empty active messages. |
| BeekeeperRootView 72 | vestigial concierge cleanup / Session | Failed or missing first row returns before deletion/save; successful matching row deletes and saves. |

The array success/failure distinction is essential at Chat 490, 534 and 806. The first-row guard/conditional sites preserve their existing skip via `.first` on the helper result. Never replace an array-success guard with an emptiness guard. Do not unconditionally execute nested saves after an empty fallback.

### Exact save inventory

Each of the following 30 saves migrates once. Grouping does not authorize moving/combining saves:

| File | Baseline save lines and contexts | Error destination |
|---|---|---|
| ChatViewModel | 234 optimistic send; 429 session-info upsert; 442 old handoff deletion; 492 context-clear deletion; 527 replacement upsert; 536 replacement message migration; 580 replacement old-row deletion; 589 scoped error bubble; 603 tool output; 609 unknown frame; 759 final append; 765 final single shot; 787 nonfinal append; 792 first chunk; 859 full-list sync; 889 local session deletion; 915 workspace upsert/prune | Log once through helper, then assign VM `lastError` on non-nil error. |
| TeamViewModel | 253 optimistic send; 498 incoming team message; 538 system response; 572 ack; 629 channel sync; 738 history; 768 joined member; 779 self left; 796 archived; 820 preview | Same VM rule, with no change to request IDs, history algorithm, queue or channel cleanup. |
| SessionListView | 138 iOS rename; 206 macOS rename | Log through helper only; retain existing view state/actions. |
| BeekeeperRootView | 74 vestigial concierge row deletion | Log through helper only; retain failed/missing-row return. |

### Deterministic error tests without changing storage architecture

The helper's one catch/log implementation may have internal operation-closure overloads so a test can execute `throw sentinelError` through exactly the same path as the production `context.fetch`/`context.save` call. They are not alternate production save policies. A small initializer closure seam is allowed for each VM's save attempt, and for Chat's all-Session fetch, solely to drive those errors through the real call site and shared helper. Live defaults directly invoke the current ModelContext operation; test closures throw a sentinel. Keep these closures scoped to the VM/test instance and synchronously invoked; no global hooks, context registry, new datastore, mock storage implementation, persistence protocol/service, or MessageStore extraction is needed. Preserve all existing initializer defaults and lazy speech behavior.

The plan must show the concrete minimal signatures and that a forced error traverses the same helper catch/log and caller branch as a real error. Tests may not simulate reporting by directly setting `lastError`, return a synthetic error after a successful save, replace the whole VM handler, or rely on invalid containers/fatal SwiftData behavior. For other fetch sites, pair shared-helper failure tests with the complete caller branch audit and existing empty/missing-row integration fixtures rather than creating generic storage abstraction solely to inject every query.

## Capability state and assigned cleanup

`CapabilityManager.performRefresh()` already sets `isLoading = true` with a defer restoring false; `refresh()` coalesces concurrent calls. Retain that mechanism. In `HivesGridView`, use the following existing-state decision: nonempty `hives` renders the grid even while refreshing; empty `hives` plus loading renders an ordinary `ProgressView`; empty and not loading renders the unchanged `ContentUnavailableView`. No new loading string, error screen, navigation gate or polling is introduced. Do not erase cached hives at refresh start, move single-hive selection logic, or change authentication callbacks.

Remove only `KeepurUnreadBadge(count: 0)` from `AgentRow`. Keep the optional timestamp, row sizing, typography and avatar behavior; the shared badge component and its tests remain for other consumers/future work.

Retain both incoming `.typing` and `.commandList` decode cases and the existing outgoing command-list request. Document at the Team handler that typing is deliberately ignored because the UI has no typing surface, and command-list results are deliberately ignored because slash commands use the current free-form input. This is the approved document-no-op option: it preserves malformed-frame handling and connect-time request order, and does not create typing or command-palette UI.

Replace `ConciergeSessionStore.pickConciergeSession`'s remaining print at line 51 with `Log.chat.warning`/`notice`, emitting only its static diagnostic and non-sensitive match count. Selection still uses the first exact `.concierge` match. Widen the print acceptance search to `Managers`, `ViewModels` **and `Models`**; `Log.persistence` receives its first real calls through the helper.

Rewrite stale sections of `CLAUDE.md` against the actual tree while retaining the detailed B/C contracts. In particular: `ContentView` is the authentication/navigation gate, pairing is host-aware, `BeekeeperSocket` is the sole socket implementation, `BeekeeperConfig` builds configurable TLS-only HTTPS/WSS endpoints, and the socket adds current token/channel query parameters. Document the protocol-ping handshake, 30-second application ping and current retry gate truthfully, without credentials or a literal token-bearing URL. Correct obsolete targets/tooling, model inventory and workflow references against project files rather than repeating old instructions. Keep the Linear tracker and operator Gate 2 flow, C's private socket/named requests, post-handler publication/request-local buffer, metadata-only concierge identity, lazy speech and cancellation, B's queue/fallback/pairing/banner ownership, and D's typed/storage/helper contracts. Do not replace those contracts with a generic architecture paragraph or claim E is implemented.

Remove `hive.dodihome.com` from `Info.plist` and remove its now-empty `NSExceptionDomains`/`NSAppTransportSecurity` containers. Keep microphone/speech/audio/font keys unchanged. Do not add another exception or alter host validation, deployment targets, pairing schema or transport authentication.

## Invariants and edge cases

- **Unknown/missing values:** typed boundary conversions preserve arbitrary supplied raw values and current missing-field defaults. Unknown session mode must remain excluded from exact `.sessions` full-list insertion, while non-concierge `session_info` keeps its current ordinary path. This existing asymmetry is not redesigned here.
- **Fresh empty database:** successful `[]` from full Session fetch still performs reconciliation/insertion and consumes at most one reconnect pass. Failed fetch leaves it eligible for the original five-second fallback; a later successful list may still win first.
- **Queue semantics:** preserve B's FIFO, one-head release, release sets, same-session admission, attachment-only empty wire text, skipped already-released sessions, full-server-ID absence cleanup, original-hive Team retention, rejected-send behavior and runtime-only queue lifetime. Persistence errors do not invent an acknowledgment or queue release.
- **Terminal list evidence:** terminal cleanup removes release-only bookkeeping as well as queued payloads, so the same reconnect pass cannot later flush the terminated session. An ordinary active unknown status is not terminal, and no timer marks any status idle.
- **Streaming/clear/replacement:** preserve message concatenation, final speech gating, stream/completed IDs, two-phase clear handoff and names, insert-before-delete replacement, selected-path behavior, approval migration, and old/new watchdog cancellation order. Failure skips apply only at the documented site; unrelated continuation remains intact.
- **Concierge:** full-list runtime reconciliation still includes concierge; only Session-table work filters wire/registered/cached identities. Registration remains metadata only. Preserve fresh buffered replies, exact-ID/nonempty-path matching, stage budgets, offline cache bail, run cancellation and incoming publication after handler completion, including errors/early returns.
- **Errors:** save-reporting may replace the current error with the mandated persistence message; fetch-reporting does not clear or replace a VM error. Successful saves leave the current error's timer untouched. Direct view errors remain logs.
- **Pairing/lifetime:** every unpair/auth origin retains synchronous weak callback order, queue/bytes/request-map clearing before replacement credentials, and history/draft retention. The helper creates no Task and retains no VM; its test seams must not introduce owner cycles.
- **No migration:** retain every existing `@Model` stored property name/type/attribute and the container's schema list. No new persistence model, stored enum, destructive reset, relationship or `serverId` field is added in D. Existing raw values remain readable, including unrecognized strings.

## Testing Contract

### Unit tests — required

This child changes the state representation and error-handling boundary; these are deterministic, directly testable contracts.

1. Cover every SessionStatus wire value and at least two unknown values (including empty) with `init(wire:)`/`wireValue`, equality, header text and activity. Explicitly assert unknown active and terminal inactive. Decode actual `status` and `session_list` JSON into the typed values, retaining optional IDs/tool names and malformed-entry behavior. Keep wire fixtures as strings so tests exercise the boundary.
2. Cover SessionMode missing/default, known and unknown values in both `session_info` and `session_list`; all known SenderType/ChannelKind/AgentStatus values and unknown raw round-trips through Team decode. Unknown supplied values must not drop an otherwise valid row. Preserve required-field rejection/default assertions in `TeamWSMessageTests`, `BusyStateRecoveryTests` and attachment suites. There is no new incoming encoder requirement: round-trip means wire string → typed value → the same string, plus existing outgoing JSON assertions.
3. Cover all five MessageRole raw values, literal unknown versus unsupported stored value, all typed SwiftData accessors and raw backing strings. Verify known typed assignment/constructor paths write exactly the existing string; reading unknown data does not mutate it. Test ChannelKind/SessionMode unknown membership and SenderType unknown non-agent comparisons.
4. Assert all four AgentStatus presentation fields for every known status, arbitrary unknown and empty unknown, plus optional absent-agent header behavior. Migrate `ChatHeaderMappingTests`, `AgentDetailSheetTests` and `AgentRowTests` to the shared representation. Preserve existing label/tint/header expectations except Chat unknown activity, whose change is explicitly required by the approved enum contract. Construction-only checks are not sufficient evidence for presentation mappings.
5. Shared persistence helper: successful fetch with rows, successful empty fetch, thrown fetch returns `[]` plus original failure, failure output resets before a subsequent success, save success returns nil, and a sentinel thrown save returns that same error without throwing. Assert one operation invocation per helper call. Verify logging uses a static operation label and safe error identity through review or a bounded log sink assertion; do not depend on scraping unified-log timing.
6. Retain existing CapabilityManager selection/filtering tests. The manager already owns its loading lifecycle and this child only reads that value in the view; do not add a service or pure state abstraction merely to unit-test the small rendering conditional. Verify the visible states in the bounded smoke check below. If implementation changes the manager's loading/coalescing mechanism, that is an additional change requiring targeted lifecycle tests using the existing API URLProtocol stubbing approach.

### Integration tests — required

These are XCTest tests using the real VM/codec/helper and in-memory SwiftData plus the existing fake WebSocket/credential seams. They do not require a deployed backend.

1. Exercise both VMs' optimistic-message save through a throwing operation seam and assert the exact `lastError` message. Observe normal continuation: input clearing, the existing send-or-queue choice, pending payload/attachment retention and no fabricated acknowledgement. Verify a later successful helper save does not clear a current error; keep B's dismissal/auto-clear tests. Also cover a conditional incoming save path so helper adoption is not tested only on public send.
2. In Chat's real reconnect/session-list path, force the all-Session fetch to throw. Assert no table/status/queue mutation or save from sync and no consumption/cancellation of reconnect fallback; `serverSessions` and the post-handler incoming event still publish. Allow the existing five-second fallback to fire (or use the existing bounded harness seam if one is available) and prove it releases only the otherwise eligible head. Pair with a successful empty Session fetch which inserts ordinary rows/reconciles and owns the single pass. Avoid sleeps that merely assume success; use `eventually`/observable sends and bounded deadlines.
3. Preserve array-success save boundaries at context-cleared/replacement: the helper failure contract plus caller audit must show error skips the nested save while successful empty arrays retain it. Exercise the successful-empty cases and existing selection/runtime continuation in the real VM; do not alter semantics to make the test simpler.
4. Drive a full list reporting `.sessionEnded` for an already busy queued session. Assert existing terminal cleanup, no watchdog re-arm, no queue release/send, and no Session-table deletion/selection invention. Drive an unknown non-idle status to prove it stays active, queries via watchdog and does not send pending work. Retain busy/busy detail and ordinary busy-to-idle, repeated-idle, absent-ID and concierge reconciliation cases.
5. Preserve Team's missing-row guard behavior, one-entry removal and remaining queue order; ordinary offline/reconnect/hive-switch, rejected-send and pairing tests remain intact. Unknown sender/channel types must survive decode-to-persisted-row integration without being treated as `.agent`, `.channel` or `.dm`; retain the existing history algorithm unchanged for E.
6. Use a real in-memory ModelContainer for helper fetch/save success and model/accessor round trips. Include a unique-ID characterization: save a Session, then save a conflicting Session with the same unique ID and confirm SwiftData's successful upsert/one stored identity behavior on the supported test runtime. Do **not** assert that duplicate insertion must throw or simulate that rule in production. Record the target/runtime if this characterization exposes a platform problem instead of silently swapping in an invalid fixture.

**Why the duplicate-error wording changes:** the epic/ticket proposed duplicate unique IDs as a deterministic save error. Apple's [Model your schema with SwiftData, WWDC23](https://developer.apple.com/videos/play/wwdc2023/10195/) explains that `@Attribute(.unique)` collisions update the existing model through an upsert. Apple's [`ModelContext.save()` reference](https://developer.apple.com/documentation/swiftdata/modelcontext/save()) defines a throwing save operation; the helper must report an actual thrown error, not manufacture a constraint error for valid framework behavior. A deterministic thrown-operation test proves that requirement, while the real SwiftData characterization protects against accidental rejection of upserts. This is a correction to test technique under delegated implementation detail, not a new storage/product policy. No local duplicate-ID runtime experiment was performed during specification.

### End-to-end tests — not required

No wire shape, backend contract or end-to-end authentication/navigation flow is added. The project has no UI test target, and Gate 1 retains the existing unit-test-only CI. Real-backend/socket UI automation would add infrastructure and nondeterminism without improving the enum/error-boundary checks above. Perform a bounded manual/preview UI smoke check of the existing hive surface: empty/loading shows progress, empty/finished shows unchanged empty copy, and nonempty/loading retains cards. Also inspect Chat/Team status/banner surfaces for layout regressions. This is not a substitute for required tests and does not authorize creating an E2E framework.

### Regression, build and static acceptance

Run the complete `KeeperTests` suite through the existing signed iOS Simulator CI job with no new skip list. Retain all predecessor behavioral assertions, migrating typed expectations/constructors as necessary: `ChatViewModelTests`, `ChatViewModelSocketTests`, `ConciergeViewModelTests`, `AsyncTimeoutTests`, `PairingTeardownTests`, `SessionReplacedTests`, `ContextClearedTests`, `ChatResilienceTests`, `TeamViewModelTests`, `TeamSortedAgentsTests` and `BeekeeperSocketTests`, plus codec/UI mapping/bubble suites. Test names/counts may grow; type migration must not silently drop assertions or weaken event ordering/lifetime/FIFO checks. Keep C's headless speech and decoded-publication tests green.

Use the established project/scheme and a discovered installed simulator with a runtime meeting the project's iOS 26.2 target; preserve ad-hoc signing because Keychain tests require it. Build the macOS target as well because Models/Views are shared with macOS 15.0. No CI expansion is needed. Existing KPR-446/447/448 environment/order/timing follow-ups remain outside D; report any observed limitations with exact evidence rather than claiming a reduced local run is the complete CI result.

From the repository root, the following searches must have no production matches:

```sh
rg -n 'try\? .*\.(save|fetch)\(' --glob '*.swift' --glob '!KeeperTests/**' .
rg -n 'print\(' Managers ViewModels Models --glob '*.swift'
```

The implementation review must additionally inspect all remaining direct production `.fetch`/`.save` calls: SwiftData operations belong only in the shared helper/live operation defaults, and no multiline `try?`, renamed swallow-helper or `try!` may evade the acceptance search. Existing unrelated optional encode, sleep, JSON decoding and file-operation handling are outside this grep contract.

Verify `git diff --check`, `plutil -lint Info.plist`, no ATS exception/container remains, and the literal always-zero badge is absent from AgentRow. Inspect schema/model diffs for stored-property changes (there must be none) and search domain string comparisons to ensure they remain only at justified codec/storage/predicate boundaries. Check CLAUDE against the actual project and ensure all B/C contracts are retained. These are verification requirements for implementation; no test/build success is claimed by this draft.

## Delegated assumptions and open questions

There is no blocking product question under the Gate 1 delegation. The following choices are deliberately visible for spec review:

- **Non-blocking, delegated:** preserve unknown mode/sender/channel values losslessly even though the epic's known-case sketches used raw-value enums. Exact current string comparisons and persistence require this; fallback-to-known would be a behavior change.
- **Non-blocking, delegated:** use an optional typed MessageRole accessor to preserve literal `unknown` versus arbitrary legacy role fallback, without expanding the approved raw cases or rewriting stored data.
- **Non-blocking, delegated:** represent the existing different detail/header strings in one AgentStatus presentation rather than changing product copy to make a single label fit both surfaces.
- **Non-blocking, delegated:** add the helper's explicit failure output to preserve successful-empty versus failed-fetch behavior, and use only bounded operation-closure seams for deterministic error tests. A new persistence architecture is not authorized.
- **Non-blocking, delegated test correction:** replace the unsupported duplicate-ID-must-error expectation with separate uniqueness characterization and deterministic thrown-save coverage, based on the primary Apple sources above. Preserve upsert semantics.
- **Non-blocking, delegated canon alignment:** explicitly handle listed `.sessionEnded` with the existing terminal cleanup at the documented post-C sync branch. This enforces the canon; it is the only additional reconciliation correction specified here and must be separately reviewed/tested.
- **Non-blocking, delegated:** keep cached hive cards visible while loading and show the standard spinner only when the list is empty; retain both ignored Team cases with comments to avoid a protocol/request-order change.

If review determines any of these requires a new product decision rather than applying the approved constraints, maturity must stop at a focused question before implementation. This draft itself creates no labels, PM updates, commits or plan.
