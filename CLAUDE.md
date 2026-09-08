# Keepur

iOS and macOS SwiftUI chat client for Beekeeper and Team hives.

## Build and Run

- Project and scheme: `Keepur.xcodeproj`, `Keepur`; app target `Keepur`, test target `KeeperTests`.
- Use Xcode with the iOS 26.2+ SDK/runtime (currently verified with Xcode 26.3); macOS deployment target is 15.0, language mode Swift 5.
- Resolve the existing MarkdownUI package with `xcodebuild -resolvePackageDependencies -project Keepur.xcodeproj -scheme Keepur`.
- Discover an installed supported simulator with `xcrun simctl list devices available` and run `xcodebuild test -project Keepur.xcodeproj -scheme Keepur -destination 'platform=iOS Simulator,id=<discovered-UDID>' -only-testing:KeeperTests`.
- Keep normal ad-hoc signing for iOS Simulator tests because the host app uses Keychain. The shared scheme runs tests nonparallel.
- Build the shared macOS code with `xcodebuild build -project Keepur.xcodeproj -scheme Keepur -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO` on Apple Silicon.
- First launch pairs against a user-configured TLS host using the pairing code flow in `PairingView`; do not paste a token into a setup screen.

## Architecture

- `KeepurApp.swift`: app entry and the existing SwiftData container/recovery path.
- `Views/ContentView.swift`: authentication/navigation gate and synchronous weak pairing-teardown binding for both VMs.
- `Views/BeekeeperRootView.swift`: concierge surface and its existing `ConciergeViewModel` coordinator; ownership remains here.
- `ViewModels/ChatViewModel.swift`: main-actor Chat state machine, streaming, approvals, queues, watchdogs and decoded publication.
- `ViewModels/TeamViewModel.swift`: main-actor Team channels, agents, history and hive-scoped queues.
- `Managers/`: `BeekeeperSocket`, `WebSocketTasking`, credentials/Keychain, configurable endpoints, API/capabilities, speech, timeout, logging and synchronous persistence helpers.
- `Models/`: SwiftData `Session`, `Message`, `Workspace`, `TeamChannel`, `TeamMessage`; Chat/Team wire enums, typed state, concierge cache and user-facing errors. These are the five models in the app container.
- `Views/` and `Theme/`: SwiftUI surfaces and existing tokens/components; MarkdownUI renders rich message text.
- `KeeperTests/`: XCTest, in-memory SwiftData, fake transport/credentials and request-latched Chat/concierge harnesses.
- `docs/specs/` and `docs/plans/`: reviewed design and executable implementation artifacts.

## State and Persistence

- `SessionStatus`, `SessionMode`, `MessageRole`, `SenderType`, `ChannelKind` and `AgentStatus` define runtime state decisions. Chat/Team codecs construct typed values without changing wire shapes or missing-field defaults.
- Unknown session status preserves raw text and stays active; only explicit idle releases queued work. Terminal `session_ended` is inactive and uses existing cleanup in status frames and full lists, without an idle release or deleting a still-listed Session row.
- Unknown supplied modes/sender/channel/agent values preserve raw strings. Exact sessions/concierge/agent/channel/DM membership stays exact. `MessageRole` distinguishes literal unknown from unsupported stored text.
- `Message.role`, `TeamMessage.senderType` and `TeamChannel.type` remain String attributes. Computed typed accessors do not rewrite data; constructor arguments serialize enum raw values at storage boundaries. SwiftData predicates use stored fields. D changes no stored schema; E's separate optional serverId work is not implemented here.
- `AgentStatus.presentation` supplies all existing label, header text, activity and tint mappings in one place under `Views/Team/`.
- `Managers/Persistence.swift` provides synchronous `fetchOrEmpty` and `saveReporting` with one catch/log implementation. Every call attempts once; no retry, rollback, implicit save or alternate uniqueness policy. SwiftData unique-ID upserts remain framework behavior.
- Static operation labels plus safe error type/code go to `Log.persistence`; never log error descriptions/userInfo, IDs, paths, model contents, tokens, URLs or frames. VM save errors set “Couldn't save. Your last change may not be kept.” through the existing banner. Success and fetch failures do not clear/reset the current error. Direct view saves log only.
- A failed fetch preserves each original caller's continuation. Chat clear/replacement arrays and full-session fetch explicitly distinguish failed fetch from successful empty results. In particular, full-list failure leaves reconnect fallback ownership untouched and still publishes the decoded frame after the handler.
- Test-only instance operation closures inject save failures and the full-Session fetch through the same helper catch; production defaults directly invoke ModelContext. No persistence service or MessageStore is introduced.
- CapabilityManager owns/coalesces refresh loading. HivesGridView preserves nonempty cards during refresh, shows standard progress only for empty/loading, and keeps the existing finished-empty copy.
- Team typing and command-list results are deliberately ignored: there is no typing surface and slash commands use free-form input. Their wire cases and connect-time command-list request remain.

## WebSocket and Lifecycle Contracts

- `BeekeeperSocket` is the sole socket implementation. `BeekeeperConfig` builds HTTPS/WSS endpoints from the configured TLS-only host. On each open, the socket adds the current credential token and channel query parameters; never log a credential-bearing URL. There are no ATS network exceptions.
- The protocol-level WebSocket ping handshake must succeed before connected. After the handshake, the socket starts receiving and sends the bare application ping before `onConnected` bookkeeping; the application ping then repeats every 30 seconds.
- Ordinary failures use exponential backoff (2^attempt seconds, capped at 30). Generation guards discard stale callbacks. Auth failure/4001 does not reconnect. Same-channel connect while a handshake is already in flight is a no-op; while sleeping in backoff it cancels the delay and retries immediately, retaining attempt count. Missing-token reads follow the existing bounded retry path.
- Headless Chat retains supplied speech or constructs it lazily on first access. Configure, decode, queues and sends with read-aloud off never construct speech. Existing optional socket construction shares injected credentials; watchdog/error delays are Duration values.
- Streaming chunks assemble by message ID. Tool approvals remain keyed by owning session with the existing timeout/deny surface; receiving another session's approval never changes selection/path, and approve/deny removes only the addressed entry.
- Both VM sockets and Chat's generic `send(_:)` are private. Views observe each VM's published `connectionState` and `lastError`, never `viewModel.socket`. `ChatViewModel` and `TeamViewModel` subscribe to `socket.$state` in `init`; never send synchronously from a state sink because `@Published` emits before the socket's send gate updates.
- Concierge uses Chat's named `resumeSession(sessionId:path:)`, `listSessions()`, and `newConciergeSession()` requests; their `Bool` reports encode/socket acceptance, not server acknowledgement. `registerConciergeSession(_:)` supplies metadata before cached/discovered resumes so legacy replies avoid Session/Workspace insertion; it sends nothing and writes no cache.
- Chat's instance-lifetime `incoming: PassthroughSubject<WSIncoming, Never>` publishes each decoded frame once, synchronously after its complete handler, including unknown/early-return paths. It has no replay; production consumers only observe it and never send or finish it, including across reconfigure/re-pair.
- `ConciergeViewModel` in `Views/BeekeeperRootView.swift` subscribes with a request-local, one-result buffer before sending and accepts only fresh matching decoded replies. Its cached resume → list → discovered resume → spawn waits have 3/3/3/5-second budgets; connection waits have 5 seconds. Runs hold the coordinator weakly; retry, auth loss, and destruction cancel old work, with subscriptions disposed on every exit. Rejected sends/offline bails preserve cache. `Managers/AsyncTimeout.swift` provides `withTimeout`; its body must cooperate with cancellation.
- `KeepurConnectionBanner` mounts in `ChatView` and once in `TeamRootView`. Its `Theme/Components` implementation accepts presentation values and closures only; socket/error mapping lives in `Views/ConnectionBannerPresentation.swift`. `UserFacingError` overrides banner text while preserving the state's Retry action, and clears on dismissal or after 6 seconds.
- Chat's `pendingReasons` distinguishes `.busy` ("waiting") from `.offline` ("not sent"). Sends preserve per-session FIFO, including new sends behind a backlog or a released head awaiting idle. Reconnect reconciliation (`syncSessions`, with a 5-second fallback) releases one head per idle session, skipping sessions already released by an earlier idle event. Absent-session cleanup uses the full server ID set, including concierge sessions.
- Chat reconciles statuses against the full `session_list`; only Session-table work filters concierge, including registered/cached legacy IDs, and a selected concierge is preserved. A failed Session fetch must return before consuming reconnect bookkeeping, leaving its fallback eligible.
- Each connected busy session has one weak, token-checked watchdog (`staleBusyTimeout`, default 90 seconds). Expiry only requests `listSessions()`; it never forces idle or releases queued work. It re-arms while awaiting replies and on still-busy replies/reconnect, cancels on disconnect/unpair/cleanup, and cancels the old ID before re-arming a busy replacement.
- Team's ordered `offlineEntries` retain the original hive and resend never-sent and unacknowledged text only on that hive's `onConnected`; lost acknowledgements can cause duplicates. Both queues and retained queued attachments are in memory only and are not restored from persisted message rows after relaunch.
- Manual `BeekeeperSocket.disconnect()` clears its remembered channel and closes normally; its `reconnect()` does nothing until another `connect(channel:)`. VM reconnect methods supply the channel. Ordinary disconnect/hive switch preserves queued messages.
- Manual unpair or auth failure from Beekeeper, Team, or capabilities synchronously clears both VMs' queues, retained queued attachments, and Team's pending message-request mappings before re-pairing. `ContentView.bindPairingTeardown` installs the callbacks before configure/connect; `ChatViewModel.unpair()` owns credential clearing, and auth view observers only update navigation state.

## Code Conventions and Verification

Use main-actor observable VMs, guard optional values, existing MARK/file organization and theme tokens. New persisted schema is outside D; keep existing storage boundaries and helpers. Test deterministic behavior with real in-memory SwiftData plus injected operation attempts and fake transport, never by forcing invalid containers or treating unique upserts as errors.

CI in `.github/workflows/test.yml` runs the entire `KeeperTests` target on signed iOS Simulator for pull requests to `main`/`epic-*` and pushes to `main`. There is no CI macOS or UI-test job; the epic also requires a local macOS build. KPR-446's known local CapabilityManager host-crash exclusion is local-only. Full unexcluded GitHub CI at the final reviewed PR head is mandatory; a later commit requires new-head review/check evidence. KPR-447/448 remain tracked external follow-ups.

Repo-specific guidance exists in `.claude/skills/quality-gate/SKILL.md`, `.claude/skills/swift-compliance/SKILL.md`, `.claude/skills/create-tests/SKILL.md` and `.claude/skills/pre-submit-testing/SKILL.md`. Apply the approved ticket/spec contract to the change; older generic guidance does not authorize rewriting existing JSON codecs, view persistence or coordinator ownership. The quality gate checks compliance, meaningful required tests and regression/build evidence in order. `dodi-dev:verify` requires evidence before completion claims or commits.

## Tracker and Delivery

Linear team `KPR` is authoritative; GitHub issues are mirrors. For Keepur access, read the access token from `~/.linear.env` and call the Linear API directly. Never print or store the token in instructions, logs or responses.

For ordinary features, `dodi-dev:brainstorm` and `dodi-dev:file-ticket` establish context before pickup, reviewed planning, implementation and review. In a signed-off epic, derive child specs/plans from approved authority through `dodi-dev:mature-ticket`; do not re-open approved product decisions. Product ambiguity demotes the ticket to the spec lane. Ready children use the dedicated pickup/implementation/test/review/child-PR lifecycle, not a generic submit-and-merge shortcut.

KPR-441 is the cleanup epic; children 0/A shipped before mirroring, and B–E accumulate serially on `epic-kpr-441`. The resident `dodi-dev:drive-epic` driver dispatches children with native blocked-by dependencies. Child PRs target the epic branch; serial merges receive decision-register coherence rulings. One epic PR targets `main`, and the operator merges it at Gate 2. A green child does not authorize shipping the epic to main.

Out-of-scope review findings belong in a downstream ticket/comment or standalone tracked follow-up, not only in a local plan. Mid-lane checkpoints and continuation briefs live on the ticket; local plan/handoff files supplement that durable record. Designs are in `docs/specs/YYYY-MM-DD-<topic>.md`, plans in `docs/plans/YYYY-MM-DD-<feature-name>.md`, with review before readiness.

Child E still owns Team history request correlation, additive optional serverId, HistoryMerger, queued-row-aware orphan cleanup and DM timeout. D does not implement those behaviors.
