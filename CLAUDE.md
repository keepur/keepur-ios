# Keepur iOS

iOS chat client for the Beekeeper backend (Claude via WebSocket).

## Build & Run

- Open `Keepur.xcodeproj` in Xcode 16+
- Target: iOS 26.2+, Swift 5
- MarkdownUI (SPM) for rich markdown rendering in chat bubbles
- Cmd+R to build and run on device/simulator
- First launch: enter Beekeeper auth token in setup screen

## Architecture

**MVVM with SwiftUI + SwiftData**

```
KeepurApp.swift          → App entry, SwiftData ModelContainer
Views/RootView.swift     → Auth gate + navigation routing
ViewModels/ChatViewModel → Central state machine (@MainActor, @Published)
Views/                   → SwiftUI views (ChatView, SessionListView, SettingsView, etc.)
Managers/                → Service layer (WebSocket, Keychain, Speech)
Models/                  → SwiftData models (Session, Message) + WS protocol (WSMessage)
docs/specs/              → Product specs driving upcoming features
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

## No Tests or CI

No test targets or CI/CD pipeline exists yet.

## Development Process

We follow the `dodi-dev` plugin workflow. All features go through two phases: planning then execution.

### Planning Phase

| Step | Skill | What Happens |
|------|-------|-------------|
| 1 | — | You have an idea, problem, or bug |
| 2 | `dodi-dev:brainstorm` | Explore intent, constraints, approaches → write design spec |
| 3 | `dodi-dev:file-ticket` | Create a Linear ticket with context from the design session |

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

## Upcoming Features (specs in docs/)

- Device pairing (#63): 6-digit code entry, 90-day JWT
- Multi-session (#64): Concurrent sessions with per-session status
- Workspace browsing (#65): Directory picker, saved workspace history
