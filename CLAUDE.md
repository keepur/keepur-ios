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
- Auth failure (401) → clears token, returns to setup

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

### Multi-Child Epics — Manual Mode Only

**Do not invoke `dodi-dev:drive-epic`** (the automated resident-driver skill) on this repo. It requires `LINEAR_API_KEY` and a Linear-tracked epic/ticket set; this repo has neither — its PM system is GitHub Issues. The scripts it depends on (`driver-claim.sh`, `claim.sh`, `watchdog-scan.sh`, the coherence register) are hard-wired to Linear's GraphQL API and will error or silently target the wrong system.

The fallback — and the actual process for every epic here — is to run the Execution Phase steps above **by hand, one child ticket at a time**:

- The epic is one GitHub Issue with a checklist of child issues (e.g. `[Epic] iOS cleanup`, #88, children #90–#94), each child a separate issue linking back with "Part of #N". Sequencing/blocking is stated in prose in each child's body (e.g. "Blocked by #90").
- Work children in the stated order. For each: `pickup` → `write-plan` → `implement` → `/quality-gate` → `dodi-dev:review` (manual mode — a capped round loop of `opus` reviewers plus one `fable` final round, run by hand, not the Florist autonomous seats) → `dodi-dev:submit`.
- **Review findings that are real but out of scope for the current child** (belongs to a later child, is an environment/tooling issue, or is a standalone hygiene item) get demoted to a tracked follow-up, not left buried in a local plan doc: post a comment on the downstream child issue it belongs to, or file a new standalone issue if it doesn't belong to any open child. See #90/#91/#93/#101/#102 (child A of epic #88, 2026-09-05) for the pattern.
- If a session parks mid-review or mid-implementation, write a session handoff doc under `docs/plans/` (e.g. `YYYY-MM-DD-<child>-handoff.md`) with exact resume steps, current SHAs, and open review-round state — the next session (or human) resumes from that doc.

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
