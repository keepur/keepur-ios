# Keepur

iOS & macOS chat client for the Beekeeper backend (Claude via WebSocket).

## Build & Run

- Open `Keepur.xcodeproj` in Xcode 16+
- Targets: iOS 26.2+, macOS 15.0+ (Sequoia), Swift 5
- MarkdownUI (SPM) for rich markdown rendering in chat bubbles
- Cmd+R to build and run on device/simulator
- First launch: enter Beekeeper auth token in setup screen

## Architecture

**MVVM with SwiftUI + SwiftData**

```
KeepurApp.swift          → App entry, SwiftData ModelContainer
Views/RootView.swift     → Auth gate + navigation routing
ViewModels/ChatViewModel → Central state machine (@MainActor, @Published)
Views/                   → SwiftUI views (ChatView, SessionListView, SettingsView,
                           PairingView, WorkspacePickerView, ToolApprovalView, etc.)
Managers/                → Service layer (WebSocket, API, Keychain, Speech)
Models/                  → SwiftData models (Session, Message, Workspace) + WS protocol (WSMessage)
KeeperTests/             → Unit tests (resilience, busy state, keychain, workspace)
docs/specs/              → Product specs driving upcoming features
docs/plans/              → Implementation plans for in-progress work
```

## Key Patterns

- **MarkdownUI** (SPM) for assistant bubble rendering; otherwise native: URLSessionWebSocketTask, AVFoundation, Speech framework, Security (Keychain)
- **SwiftData** for persistence (Session, Message models with @Model)
- **@MainActor** on ViewModels and all UI-touching code
- **Enum-based WebSocket protocol**: WSIncoming/WSOutgoing in WSMessage.swift for type-safe serialization
- **Streaming messages**: Server sends chunks with `final: true/false`; ViewModel assembles by message ID
- **Tool approvals**: Modal sheet with 60s countdown, auto-deny on timeout
- **Auto-reconnect**: Exponential backoff (2^N, max 30s) on WebSocket failure

## WebSocket

- Endpoint: `ws://beekeeper.dodihome.com?token=<JWT>`
- Cleartext WS allowed via ATS exception for this host
- 30s ping interval to keep connection alive
- Views observe each VM's published `connectionState` and `lastError`, never `viewModel.socket`. `ChatViewModel` and `TeamViewModel` subscribe to `socket.$state` in `init`; never send synchronously from a state sink because `@Published` emits before the socket's send gate updates.
- `KeepurConnectionBanner` mounts in `ChatView` and once in `TeamRootView`. Its `Theme/Components` implementation accepts presentation values and closures only; socket/error mapping lives in `Views/ConnectionBannerPresentation.swift`. `UserFacingError` overrides banner text while preserving the state's Retry action, and clears on dismissal or after 6 seconds.
- Chat's `pendingReasons` distinguishes `.busy` ("waiting") from `.offline` ("not sent"). Sends preserve per-session FIFO, including new sends behind a backlog or a released head awaiting idle. Reconnect reconciliation (`syncSessions`, with a 5-second fallback) releases one head per idle session, skipping sessions already released by an earlier idle event. Absent-session cleanup uses the full server ID set, including concierge sessions.
- Team's ordered `offlineEntries` retain the original hive and resend never-sent and unacknowledged text only on that hive's `onConnected`; lost acknowledgements can cause duplicates. Both queues and retained queued attachments are in memory only and are not restored from persisted message rows after relaunch.
- Manual `BeekeeperSocket.disconnect()` clears its remembered channel and closes normally; its `reconnect()` does nothing until another `connect(channel:)`. VM reconnect methods supply the channel. Ordinary disconnect/hive switch preserves queued messages.
- Manual unpair or auth failure from Beekeeper, Team, or capabilities synchronously clears both VMs' queues, retained queued attachments, and Team's pending message-request mappings before re-pairing. `ContentView.bindPairingTeardown` installs the callbacks before configure/connect; `ChatViewModel.unpair()` owns credential clearing, and auth view observers only update navigation state.

## Code Conventions

- Commit messages: `feat:`, `fix:`, `docs:` prefixes
- `guard let` over force unwraps
- MARK comments for file sections
- Private properties/methods grouped together
- Views composed via extracted subviews in extensions

## Tests

Unit tests live in `KeeperTests/`. CI (`.github/workflows/test.yml`) runs them on the iOS Simulator for every pull request to `main` or an `epic-*` branch, and on every push to `main`. Unit tests only; no macOS run, no UI tests.

## Development Process

We follow the `dodi-dev` plugin workflow. All features go through two phases: planning then execution.

### Planning Phase

| Step | Skill | What Happens |
|------|-------|-------------|
| 1 | — | You have an idea, problem, or bug |
| 2 | `dodi-dev:brainstorm` | Explore intent, constraints, approaches → write design spec |
| 3 | `dodi-dev:file-ticket` | Create a GitHub Issue with context from the design session |

**Skip steps 2-3** for trivial fixes (typos, one-liners, obvious config changes). When in doubt, spec it.

### Execution Phase

| Step | Skill | What Happens |
|------|-------|-------------|
| 4 | `dodi-dev:pickup` | Take a ticket, create an isolated worktree |
| 5 | `dodi-dev:write-plan` | Create step-by-step implementation plan |
| 6 | `dodi-dev:implement` | Execute plan — subagent per task, tests along the way, commits as you go |
| 7 | `/quality-gate` | Swift compliance → create tests → run full suite (stops on failure) |
| 8 | `dodi-dev:review` | Agent code review: spec compliance, code quality, security, regression risk |
| 9 | `dodi-dev:submit` | Create PR → wait for CI → merge only after green → cleanup |

`dodi-dev:verify` is active throughout — enforces "evidence before claims" at every step.

**Skip step 5** if the change is small enough to implement directly without a plan.

### Project Tracker and Multi-Child Epics

**The tracker is Linear, team `KPR`** (not GitHub Issues). The API key lives in `~/.linear.env` as `LINEAR_KPR_API_KEY`; the `dodi-dev` scripts read `LINEAR_API_KEY`, so load it first in any session that touches tickets:

```bash
set -a; source ~/.linear.env; set +a; export LINEAR_API_KEY="$LINEAR_KPR_API_KEY"
```

Epics run on the `dodi-dev` epic path: a Linear epic (`epic`, `repo:keepur-ios`, `epic-signed-off` after Gate 1, `mode-sprint`/`mode-waterfall`) with children as sub-issues linked by native blocked-by relations; an epic branch named `epic-kpr-<id>` (the CI workflow triggers on PRs to `epic-*`) in a sibling worktree `../keepur-ios-epic-kpr-<id>`; child PRs merge into the epic branch; one epic PR to `main` is merged by a human (Gate 2). Day-to-day: load the key and run `/dodi-dev:drive-epic` — it boots from Linear + git state, so no session needs to reconstruct history by hand. Rulings go through `/dodi-dev:drive-epic rule-coherence <sha> approve|reject|redirect`.

**Current epic: [KPR-441](https://linear.app/keepur/issue/KPR-441)** (iOS cleanup; GitHub #88 is a read-only mirror). Children 0 and A shipped to `main` before the mirror on the single-ticket path; B–E (KPR-442…445) run on `epic-kpr-441`.

Either path:

- **Review findings that are real but out of scope for the current child** (belong to a later child, an environment/tooling issue, or a standalone hygiene item) get demoted to a tracked follow-up, not left in a local plan doc: a comment on the downstream child ticket, or a new standalone ticket (`repo:keepur-ios`). See KPR-446/447/448 for the pattern.
- If a session parks mid-lane, the durable record is the ticket (lane checkpoints, continuation brief), not a local file; a handoff doc under `docs/plans/` is a supplement, never the only copy.

### Design Specs and Plans

- Design specs go to `docs/specs/YYYY-MM-DD-<topic>.md`
- Implementation plans go to `docs/plans/YYYY-MM-DD-<feature-name>.md`
- Both include automated review loops before proceeding
- These files persist across context clearing and are read by downstream skills

### Repo-Specific Skills

| Skill | What It Does |
|-------|-------------|
| `/quality-gate` | 3-step pre-PR pipeline: swift compliance → create tests → run full suite |
| `/swift-compliance` | Architecture layering, concurrency safety, SwiftData hygiene, protocol consistency |
| `/create-tests` | Generate unit/UI tests for changed files, run/fix loop, commit passing tests |
| `/pre-submit-testing` | Build check + run full test suite with self-healing fix loop |

## Upcoming Features (specs in docs/specs/)

- Device pairing: 6-digit code entry, 90-day JWT
- Multi-session: Concurrent sessions with per-session status
- Workspace browsing: Directory picker, saved workspace history
