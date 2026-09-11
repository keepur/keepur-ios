# KPR-444 Typed State and Persistence Reporting Implementation Plan

> **For agentic workers:** Use dodi-dev:implement to execute this plan.

**Goal:** Replace six runtime string domains with typed values and report all existing SwiftData failures while preserving the approved storage, wire, queue and concierge behavior.

**Architecture:** Wire decoders construct lossless enums; SwiftData keeps its existing String attributes and exposes computed typed accessors. A synchronous `ModelContext` helper family has one catch/log implementation, with a failure output for the three array-success boundaries; each VM retains ownership of `lastError`. Instance-scoped operation closures inject only save attempts and Chat's all-Session fetch for deterministic tests, without introducing a storage service.

**Tech Stack:** Swift 5, SwiftUI, SwiftData, Combine, XCTest, Xcode 26.3; iOS 26.2+ and macOS 15.0+.

**Authority:** Approved `docs/specs/2026-09-07-kpr-444-typed-state-persistence-design.md` at `38ce4379220358b74a5e0fd4fb5259f7437fa5d0`; `docs/specs/2026-09-04-cleanup-epic-design.md` Child D; Gate 1 delegation and Decision Register—Canon through merged Child C `fe6907b60933869fff46cdcba260010f53e2a235`. The spec's final review has zero findings. Its duplicate-ID upsert ruling and explicit listed-terminal correction are binding. This document is a draft for plan review, not permission to implement before readiness.

**Path convention:** All source and command paths below are exact repository-relative paths, run from the implementing child worktree. Source inspected at `/Users/mokie/github/keepur-ios-mature-kpr444`. Baseline line numbers identify the pre-D source and are not expected to remain stable. New files belong to existing synchronized Xcode groups; do not edit project membership.

## Testing Contract

### Required Test Groups

- Unit: **required**
  - Scope: six enums, both incoming codecs, AgentStatus presentation, stored-value accessors, persistence catch/result semantics.
  - Reason: changes affect forward compatibility, queue activity classification and error reporting.
  - Minimum assertions: every known value plus arbitrary and empty unknown values; missing/non-string defaults; malformed-row rejection unchanged; all four agent presentation fields and absent-agent behavior; literal MessageRole.unknown versus unsupported stored role; one operation attempt, original thrown-error identity, nil-on-success/reset-after-failure, successful empty fetch distinct from failed fetch.
- Integration: **required**
  - Scope: real Chat/Team VM → codec → helper → in-memory SwiftData, fake WebSocketTasking and CredentialStore.
  - Reason: source-only error replacement can change nested saves, queue ownership, publication or continuation.
  - Harness: **existing**, extend `KeeperTests/ChatTestHarness.swift` and the private builder in `KeeperTests/TeamViewModelTests.swift` with the exact closures below; no deployed service.
  - Minimum assertions: both VMs' failed optimistic saves show exact copy while preserving input clearing, send/queue choice, attachment retention and pending state; conditional incoming saves report; later successful saves do not clear/reset existing errors; failed full-list fetch performs no sync mutations/save and keeps fallback eligible while publishing; empty successful fetch owns the pass; empty clear/replacement arrays still save; listed terminal performs cleanup with no send/watchdog/release; unknown active status remains watched; Team missing-row removal preserves remaining order; unknown sender/channel values survive decode and storage; real SwiftData unique-ID upsert succeeds with one identity.
- E2E: **not-required**
  - Scope: no new backend/wire/authentication/navigation journey.
  - Reason: existing CI has only the XCTest target and no UI target; introducing backend/UI automation is outside D.
  - Harness: **not-applicable**.
  - Minimum assertions: none automated. The bounded UI smoke in Task 7 remains mandatory.

### Critical Flows

- Failed save → one safe log → exact VM banner → same next operation and queue behavior.
- Failed Chat all-Session fetch → publish received list/event but preserve table/status/selection/queue and reconnect fallback ownership.
- Successful empty Chat fetch → insert ordinary rows, reconcile full server identity set including concierge, one reconnect pass.
- Listed `session_ended` → existing `endSession` cleanup, retained listed Session row/selection, zero idle release.
- Unknown non-idle status → active indicator/watchdog and no queued send; unknown mode/type values retain exact membership behavior.
- Clear/replacement preserves ordered persistence, transient migration, old/new watch cancellation and post-handler publication.

### Regression Surface

Retain **every existing assertion** in the 275-test merged-C CI baseline. In particular: `ChatViewModelTests`, `ChatViewModelSocketTests` (including its queue-test extension), `ConciergeViewModelTests`, `AsyncTimeoutTests`, `PairingTeardownTests`, `SessionReplacedTests`, `ContextClearedTests`, `ChatResilienceTests`, `TeamViewModelTests`, `TeamSortedAgentsTests`, `BeekeeperSocketTests`, codec/attachment/header/row/bubble suites, CapabilityManager selection/filtering, Keychain and foundation component tests. Migrate typed fixtures/expectations, not JSON wire fixtures. No test removal, `XCTSkip`, weakened ordering, or new CI exclusion is authorized. Keep the badge component/tests; only AgentRow's literal-zero invocation is removed.

### Commands

Run discovery once before execution (read-only; do not reset any simulator):

```sh
xcodebuild -version
xcrun simctl list devices available
xcodebuild -list -project Keepur.xcodeproj
xcodebuild -showdestinations -project Keepur.xcodeproj -scheme Keepur
```

Observed for planning: Xcode 26.3 (17C529), available iPhone 17 / iOS 26.3 UDID `ABAF19FA-8DE4-4EE1-B57E-DAA88C935FDE`. If unavailable, select a discovered available iPhone whose installed runtime meets 26.2; record the actual UDID/runtime. The real test target is **KeeperTests**, scheme/app **Keepur**.

Define these shell helpers for the execution session. They are commands, not repository files. Every invocation uses a new result path; retain raw logs and inspect exit status/results. Shared derived data is reusable only serially with other lanes.

```sh
export KPR444_SIM=ABAF19FA-8DE4-4EE1-B57E-DAA88C935FDE
export KPR444_DD=/tmp/keepur-kpr443-task3-dd
kpr444_test() {
  local kpr444_label="$1"
  shift
  local kpr444_stamp="$(date +%Y%m%d-%H%M%S)"
  local kpr444_result="/tmp/keepur-kpr444-${kpr444_label}-${kpr444_stamp}.xcresult"
  set -o pipefail
  xcodebuild test -project Keepur.xcodeproj -scheme Keepur \
    -destination "platform=iOS Simulator,id=$KPR444_SIM" \
    -derivedDataPath "$KPR444_DD" -resultBundlePath "$kpr444_result" \
    "$@" 2>&1 | tee "/tmp/keepur-kpr444-${kpr444_label}-${kpr444_stamp}.log"
}
kpr444_macos() {
  local kpr444_stamp="$(date +%Y%m%d-%H%M%S)"
  set -o pipefail
  xcodebuild build -project Keepur.xcodeproj -scheme Keepur \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath /tmp/keepur-kpr444-macos-dd CODE_SIGNING_ALLOWED=NO \
    2>&1 | tee "/tmp/keepur-kpr444-macos-${kpr444_stamp}.log"
}
```

- Unit: `kpr444_test unit -only-testing:KeeperTests/TypedStateTests -only-testing:KeeperTests/PersistenceTests -only-testing:KeeperTests/ChatHeaderMappingTests -only-testing:KeeperTests/AgentRowTests -only-testing:KeeperTests/AgentDetailSheetTests -only-testing:KeeperTests/BusyStateRecoveryTests -only-testing:KeeperTests/TeamWSMessageTests -only-testing:KeeperTests/WorkspaceBrowsingTests -only-testing:KeeperTests/WSMessageAttachmentTests`
- Integration: `kpr444_test integration -only-testing:KeeperTests/ChatPersistenceTests -only-testing:KeeperTests/TeamViewModelTests -only-testing:KeeperTests/PersistenceTests`
- E2E: not applicable; Task 7's UI smoke is manual/preview validation.
- Broader local regression: `kpr444_test regression -only-testing:KeeperTests -skip-testing:KeeperTests/CapabilityManagerTests`
- macOS: `kpr444_macos` (timestamped raw log; pipeline retains build failure status).
- Full authoritative regression: the unchanged `.github/workflows/test.yml` **Unit tests (iOS Simulator)** job at the final reviewed PR head, `-only-testing:KeeperTests`, **no exclusion**, normal signing. Task 8 gives exact head/run checks.

Expected iOS output: `** TEST SUCCEEDED **`, exit 0, the selected classes actually discovered in xcresult, zero failures; test count grows beyond the prior baseline. Expected macOS output: `** BUILD SUCCEEDED **`, exit 0. Do not substitute disabled iOS signing: Keychain tests need the signed host. The existing scheme is nonparallel.

### Harness Requirements

- Xcode/runtime above; resolve existing packages with `xcodebuild -resolvePackageDependencies -project Keepur.xcodeproj -scheme Keepur` if required.
- Real in-memory SwiftData containers; disable autosave in deterministic operation-count fixtures only, so incidental framework autosave cannot distort the explicit call count. Production autosave stays unchanged.
- Existing fake socket, shared fake credentials, request-latched Chat harness, `eventually` bounded observation. Do not access a real backend or real account for the new tests.
- Team integration fixtures retain CapabilityManager strongly and restore `selectedHive` on teardown; avoid reconnect-failure capability refresh to avoid introducing the KPR-447 real-Keychain ordering dependency.
- KPR-446's 12 CapabilityManager tests may be excluded **locally only**, as already approved; don't reproduce the known local host crash merely to claim a full run. Full unexcluded GitHub CI is required. KPR-447/448 remain outside D; record exact failures, don't silently change assertions or timing contracts.

### Non-Required Rationale

- E2E: no E2E target or new backend journey; deterministic VM/codec/SwiftData tests exercise the changed boundaries. This does not waive the three-state hive/UI smoke.

### Verification Rules

- Missing harness is not a skip reason; set it up or report a concrete blocker.
- If a test failure exposes an implementation issue, fix the implementation, not the test.
- If testing exposes a spec or plan mismatch, demote the ticket to the spec lane.
- Read command output and xcresult before claiming success. Any commit after final CI/review, including documentation, invalidates final-head evidence and requires checking the new head again.
- Local compliance rules contain pre-existing conflicts with approved D scope (direct view saves, existing imports/JSON encoding, coordinator location). Review the D delta and apply the approved spec; do not move the coordinator, extract storage, rewrite codecs to Codable, or clean unrelated imports to satisfy stale generic guidance.

---

## File Map and Review Chunks

| Chunk | Tasks | Exact paths and responsibility |
|---|---|---|
| A | 1–2 | Create `Models/SessionStatus.swift`, `Models/MessageRole.swift`, `Models/SessionMode.swift`; modify `Models/WSMessage.swift`, `Models/TeamWSMessage.swift`, `Models/Message.swift`, `Models/TeamMessage.swift`, `Models/TeamChannel.swift`; create `Views/Team/AgentStatusPresentation.swift`; modify all enumerated consumers and typed test fixtures. One coherent type migration. |
| B | 3 | Create `Managers/Persistence.swift`, `KeeperTests/PersistenceTests.swift`; shared helper and real persistence characterization. |
| C | 4 | Modify `ViewModels/ChatViewModel.swift`, `KeeperTests/ChatTestHarness.swift`; create `KeeperTests/ChatPersistenceTests.swift`; 15 fetch/17 save replacements, terminal alignment and integration tests. |
| D | 5–6 | Modify `ViewModels/TeamViewModel.swift`, `Views/SessionListView.swift`, `Views/BeekeeperRootView.swift`, `KeeperTests/TeamViewModelTests.swift`; 16 Team fetch/10 save and 1 view fetch/3 save replacements, tests. |
| E | 7 | Modify `Views/Team/HivesGridView.swift`, `Views/Team/AgentRow.swift`, `Models/ConciergeSessionStore.swift`, `CLAUDE.md`, `Info.plist`; small assigned cleanup and UI smoke. |
| F | 8 | Verification only; attach evidence to lane/PR via the existing delivery workflow after implementation review. No workflow/schema additions. |

Each marked chunk is independently reviewable and under 1,000 lines (A: 458; B: 196; C: 400; D: 275; E: 510; F: 83). A's two tasks must land together before building because model/consumer typing is a compile-time dependency; B's helper is independent, but its combined tests/build require A's types/accessors. Execute A → B → C → D. Execute C then D serially because both touch shared persistence conventions. This is one plan because state typing and call-site replacement jointly touch the same two state machines; no independent product subsystem is being introduced.

### Shared Interfaces (binding across chunks)

| Owner | Signature/value | Consumers |
|---|---|---|
| SessionStatus | `Equatable`, `init(wire:)`, `wireValue: String`, `isActive: Bool`, `headerText: String?` | Chat codec/VM/views/tests; only explicit `.idle` releases queued work |
| SessionMode/SenderType/ChannelKind/AgentStatus | `Equatable`, known cases plus `.unknown(String)`, `init(wire:)`, `wireValue` | wire decoding; exact case membership; never normalize |
| MessageRole | `enum MessageRole: String { case user, assistant, system, tool, unknown }` | `Message.typedRole: MessageRole?`; nil preserves unsupported raw fallback |
| Persisted accessors | `Message.typedRole`, `TeamMessage.typedSenderType`, `TeamChannel.kind` computed read-only | decisions use typed values; constructors retain String and serialize at boundary |
| AgentStatus.presentation | `Presentation(label: String, headerText: String?, isActive: Bool, tint: KeepurStatusPill.Tint)` | all three agent consumers; optional header uses `?.presentation` and `?? false` |
| ModelContext helper | `fetchOrEmpty(_:_:)`, `fetchOrEmpty(_:_:failure:)`, operation overload; `saveReporting(_:)`, operation overload | every existing call; failure log is type/code + static label only |
| VM save seam | `(ModelContext) throws -> Void`, default `{ try $0.save() }` | private save wrapper calls helper's same catch path |
| Chat full-list seam | `(ModelContext, FetchDescriptor<Session>) throws -> [Session]`, default `{ try $0.fetch($1) }` | only all-Session fetch; no generic datastore abstraction |
| VM error | `UserFacingError("Couldn't save. Your last change may not be kept.")` | assigned on nonnil save error; success/fetch failure leave existing identity/timer untouched |

## Chunk A — Typed Domains and All Consumers

### Task 1: Define the six domains and unchanged storage boundaries

**Files:** Create `Models/SessionStatus.swift`, `Models/MessageRole.swift`, `Models/SessionMode.swift`; modify `Models/WSMessage.swift:5-9,91-92,113-138`, `Models/TeamWSMessage.swift:5-37,151-210`, `Models/Message.swift`, `Models/TeamMessage.swift`, `Models/TeamChannel.swift`.

- [ ] **Step 1:** Create the three files with this complete code (one file per labeled block):

```swift
// Models/SessionStatus.swift
import Foundation

enum SessionStatus: Equatable {
    case idle, thinking, toolStarting, toolRunning, busy, sessionEnded
    case unknown(String)

    init(wire: String) {
        switch wire {
        case "idle": self = .idle
        case "thinking": self = .thinking
        case "tool_starting": self = .toolStarting
        case "tool_running": self = .toolRunning
        case "busy": self = .busy
        case "session_ended": self = .sessionEnded
        default: self = .unknown(wire)
        }
    }
    var wireValue: String {
        switch self {
        case .idle: return "idle"
        case .thinking: return "thinking"
        case .toolStarting: return "tool_starting"
        case .toolRunning: return "tool_running"
        case .busy: return "busy"
        case .sessionEnded: return "session_ended"
        case .unknown(let raw): return raw
        }
    }
    var isActive: Bool {
        switch self {
        case .idle, .sessionEnded: return false
        case .thinking, .toolStarting, .toolRunning, .busy, .unknown: return true
        }
    }
    var headerText: String? {
        switch self {
        case .idle: return nil
        case .thinking: return "thinking"
        case .toolStarting: return "starting tool"
        case .toolRunning: return "running tool"
        case .busy: return "server busy"
        case .sessionEnded: return "session_ended"
        case .unknown(let raw): return raw
        }
    }
}
```

```swift
// Models/MessageRole.swift
import Foundation

enum MessageRole: String {
    case user, assistant, system, tool, unknown
}
```

```swift
// Models/SessionMode.swift
import Foundation

enum SessionMode: Equatable {
    case sessions, concierge
    case unknown(String)

    init(wire: String) {
        switch wire {
        case "sessions": self = .sessions
        case "concierge": self = .concierge
        default: self = .unknown(wire)
        }
    }
    var wireValue: String {
        switch self {
        case .sessions: return "sessions"
        case .concierge: return "concierge"
        case .unknown(let raw): return raw
        }
    }
}
```

- [ ] **Step 2:** Insert the following enums after `import Foundation` in `Models/TeamWSMessage.swift`. Keep all incoming/outgoing cases, guards, field defaults, request IDs and encode shapes.

```swift
enum SenderType: Equatable {
    case person, agent, system
    case unknown(String)
    init(wire: String) {
        switch wire {
        case "person": self = .person
        case "agent": self = .agent
        case "system": self = .system
        default: self = .unknown(wire)
        }
    }
    var wireValue: String {
        switch self {
        case .person: return "person"
        case .agent: return "agent"
        case .system: return "system"
        case .unknown(let raw): return raw
        }
    }
}

enum ChannelKind: Equatable {
    case channel, dm
    case unknown(String)
    init(wire: String) {
        switch wire {
        case "channel": self = .channel
        case "dm": self = .dm
        default: self = .unknown(wire)
        }
    }
    var wireValue: String {
        switch self {
        case .channel: return "channel"
        case .dm: return "dm"
        case .unknown(let raw): return raw
        }
    }
}

enum AgentStatus: Equatable {
    case idle, processing, error, stopped
    case unknown(String)
    init(wire: String) {
        switch wire {
        case "idle": self = .idle
        case "processing": self = .processing
        case "error": self = .error
        case "stopped": self = .stopped
        default: self = .unknown(wire)
        }
    }
    var wireValue: String {
        switch self {
        case .idle: return "idle"
        case .processing: return "processing"
        case .error: return "error"
        case .stopped: return "stopped"
        case .unknown(let raw): return raw
        }
    }
}
```

- [ ] **Step 3:** Apply these complete boundary substitutions. Conversion happens after existing raw-string validation, so unknown strings never remove valid entries.

| File | Existing code | Replacement code |
|---|---|---|
| `Models/WSMessage.swift` ServerSession | `let state: String` / `let mode: String` | `let state: SessionStatus` / `let mode: SessionMode` |
| same, incoming cases | `case status(state: String, sessionId: String?, toolName: String?)` | `case status(state: SessionStatus, sessionId: String?, toolName: String?)` |
| same | `case sessionInfo(sessionId: String, path: String, mode: String)` | `case sessionInfo(sessionId: String, path: String, mode: SessionMode)` |
| status return | `.status(state: state, sessionId: sessionId, toolName: toolName)` | `.status(state: SessionStatus(wire: state), sessionId: sessionId, toolName: toolName)` |
| session-info return | `.sessionInfo(sessionId: sessionId, path: path, mode: mode)` | `.sessionInfo(sessionId: sessionId, path: path, mode: SessionMode(wire: mode))` |
| session-list return | `ServerSession(sessionId: sessionId, path: path, state: state, mode: mode)` | `ServerSession(sessionId: sessionId, path: path, state: SessionStatus(wire: state), mode: SessionMode(wire: mode))` |
| outgoing concierge | `["type": "new_session", "mode": "concierge"]` | `["type": "new_session", "mode": SessionMode.concierge.wireValue]` |
| `Models/TeamWSMessage.swift` TeamChannelInfo | `let type: String` | `let type: ChannelKind` |
| same, TeamAgentInfo | `let status: String` | `let status: AgentStatus` |
| same, TeamHistoryMessage | `let senderType: String` | `let senderType: SenderType` |
| channel-list construction | `type: channelType` | `type: ChannelKind(wire: channelType)` |
| agent-list construction | `status: status` | `status: AgentStatus(wire: status)` |
| history construction | `senderType: senderType` | `senderType: SenderType(wire: senderType)` |

Leave missing/non-string `mode` and agent `status` raw defaults exactly where they are (`"sessions"` / `"idle"`); these are justified codec boundaries, not runtime decisions.

- [ ] **Step 4:** Insert these **computed**, read-only members inside their existing `@Model` classes. Retain every stored property, attribute, constructor signature and container schema. Constructors remain String-based deliberately: production serializes known/raw values explicitly, avoiding ambiguous overloads for `.unknown` or literal fixtures.

```swift
// Models/Message.swift
var typedRole: MessageRole? { MessageRole(rawValue: role) }

// Models/TeamMessage.swift
var typedSenderType: SenderType { SenderType(wire: senderType) }

// Models/TeamChannel.swift
var kind: ChannelKind { ChannelKind(wire: type) }
```

Change `TeamChannel.displayName`'s expression to `kind == .channel ? "#\(name)" : name`. Keep the property (E owns its removal). No computed accessor goes into `#Predicate`; existing descriptors use persisted fields.

- [ ] **Step 5:** Review `git diff -- Models` for stored-property and wire-shape changes. Expected: only the new enums, computed accessors, typed wire model declarations/conversions and the one same-value outgoing expression. Finish Task 2 before building/committing.

### Task 2: Migrate all consumers and prove mappings/compatibility

**Files:** Create `Views/Team/AgentStatusPresentation.swift`, `KeeperTests/TypedStateTests.swift`; modify `ViewModels/ChatViewModel.swift`, `ViewModels/TeamViewModel.swift`, `Views/ChatView.swift`, `Views/MessageBubble.swift`, `Views/SessionListView.swift`, `Views/BeekeeperRootView.swift`, `Models/ConciergeSessionStore.swift`, `Views/Team/AgentRow.swift`, `Views/Team/AgentDetailSheet.swift`, `Views/Team/TeamChatView.swift`; modify `KeeperTests/ChatViewModelTests.swift`, `KeeperTests/ChatViewModelSocketTests.swift`, `KeeperTests/PairingTeardownTests.swift`, `KeeperTests/BusyStateRecoveryTests.swift`, `KeeperTests/ChatResilienceTests.swift`, `KeeperTests/WorkspaceBrowsingTests.swift`, `KeeperTests/ConciergeViewModelTests.swift`, `KeeperTests/TeamWSMessageTests.swift`, `KeeperTests/TeamSortedAgentsTests.swift`, `KeeperTests/AgentDetailSheetTests.swift`, `KeeperTests/AgentRowTests.swift`, `KeeperTests/ChatHeaderMappingTests.swift`.

- [ ] **Step 1:** Make Chat's runtime state typed, without changing branching/order. The complete replacement declaration/method is:

```swift
@Published var sessionStatuses: [String: SessionStatus] = [:]

func statusFor(_ sessionId: String) -> SessionStatus {
    sessionStatuses[sessionId] ?? .idle
}
```

Within `ViewModels/ChatViewModel.swift` only, replace state comparisons and dictionary values: `"idle"` → `.idle`, `"thinking"` → `.thinking`, `"tool_starting"` → `.toolStarting`, `"tool_running"` → `.toolRunning`, `"busy"` → `.busy`, `"session_ended"` → `.sessionEnded`. These apply to `state`, `server.state`, `statusFor`, and `sessionStatuses` expressions, **not arbitrary string occurrences**. Replace `isActiveBusy` body with `statusFor(id).isActive`. Preserve the individual tool and stream-round conditions. Keep send/admission/flush checks explicitly `== .idle` / `!= .idle`.

Replace mode membership in Chat `.sessionInfo` and `syncSessions`, the fresh-spawn guard in `Views/BeekeeperRootView.swift:280`, and `Models/ConciergeSessionStore.swift:49` with `.concierge` / `.sessions` cases. Unknown `.sessionInfo` still takes the ordinary path; unknown full-list mode still fails exact `.sessions` insertion.

Replace **all six** Chat production Message role constructor arguments with `MessageRole.user.rawValue`, `.assistant.rawValue` (two sites), `.system.rawValue`, `.tool.rawValue`, `.unknown.rawValue`, written with the `MessageRole` qualifier. Change final speech eligibility to `msg.typedRole == .assistant`. Keep fallback session ID `"unknown"` unchanged.

- [ ] **Step 2:** Apply these exact consumer replacements, with all occurrences in the listed files:

| Path / expression | Result |
|---|---|
| `ViewModels/TeamViewModel.swift`: `$0.type == "dm"`, `channel.type == "dm"` | `$0.kind == .dm`, `channel.kind == .dm` |
| same: `channel.type == "channel"` | `channel.kind == .channel` |
| same: `histMsg.senderType == "agent"` | `histMsg.senderType == .agent` |
| same, stored constructors: `senderType: "person"`, `senderType: "agent"` | `senderType: SenderType.person.wireValue`, `senderType: SenderType.agent.wireValue` |
| same: `senderType: histMsg.senderType`, `type: info.type` | `senderType: histMsg.senderType.wireValue`, `type: info.type.wireValue` |
| `Views/ChatView.swift`: `message.role == "assistant"` | `message.typedRole == .assistant` |
| same, both literal activity arrays | `viewModel.statusFor(sessionId).isActive` |
| `Views/SessionListView.swift:330`: `msg.role == "user"` | `msg.typedRole == .user` |
| `Views/Team/TeamChatView.swift`: `channel.type == "dm"` | `channel.kind == .dm` |
| same: `message.senderType == "agent"` | `message.typedSenderType == .agent` |

Preserve `senderId == "system"` and `senderId != "system"`, command name `"dm"`, capability role `"admin"`, hive/socket channel strings, and channel event strings. They are distinct domains. `Views/Team/TeamMessageBubble.swift` requires no change.

Replace `MessageBubble.body`'s switch with this complete switch, keeping the bubble implementations intact:

```swift
switch message.typedRole {
case .user: userBubble
case .tool: toolBubble
case .system: systemBubble
case .unknown: unknownBubble
case .assistant, nil: assistantBubble
}
```

- [ ] **Step 3:** Add the single agent presentation implementation:

```swift
// Views/Team/AgentStatusPresentation.swift
import SwiftUI

extension AgentStatus {
    struct Presentation {
        let label: String
        let headerText: String?
        let isActive: Bool
        let tint: KeepurStatusPill.Tint
    }

    var presentation: Presentation {
        switch self {
        case .idle:
            return Presentation(label: "Idle", headerText: nil, isActive: false, tint: .success)
        case .processing:
            return Presentation(label: "Processing", headerText: "working", isActive: true, tint: .warning)
        case .error:
            return Presentation(label: "Error", headerText: "error", isActive: false, tint: .danger)
        case .stopped:
            return Presentation(label: "Stopped", headerText: "stopped", isActive: false, tint: .danger)
        case .unknown(let raw):
            return Presentation(label: raw.prefix(1).uppercased() + raw.dropFirst(),
                                headerText: raw, isActive: false, tint: .muted)
        }
    }
}
```

`AgentRow`: use `statusOverlay: agent.status.presentation.tint`; remove the entire private `TeamAgentInfo.statusTint` extension. `AgentDetailSheet`: pill arguments become `agent.status.presentation.label` and `agent.status.presentation.tint`; remove only static `statusTint` and `statusDisplay`. Keep its other helpers. `TeamChatView`: remove `mapAgentStatus`; header properties become:

```swift
private var headerStatusText: String? { activeAgent?.status.presentation.headerText }
private var headerIsStatusActive: Bool { activeAgent?.status.presentation.isActive ?? false }
```

`ChatView`: remove `mapSessionStatus`; replace the two header properties with:

```swift
private var headerStatusText: String? { viewModel.statusFor(sessionId).headerText }
private var headerIsStatusActive: Bool { viewModel.statusFor(sessionId).isActive }
```

`StatusIndicator` remains in `Views/ChatView.swift`. Change `let status: String` to `let status: SessionStatus`, both thinking tests to `.thinking`, and busy test to `.busy`. Replace the final tool `else` with these two branches; preserve existing modifiers, animation, Cancel and layout:

```swift
} else if status == .toolStarting || status == .toolRunning {
    Image(systemName: "hammer.fill")
        .font(KeepurTheme.Font.caption)
        .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
    Text("Running \(toolName ?? "tool")...")
        .font(KeepurTheme.Font.caption)
        .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
} else {
    Text(status.headerText ?? "")
        .font(KeepurTheme.Font.caption)
        .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
}
```

This keeps existing tool-specific copy for starting/running and displays unknown raw status instead of a fabricated tool label. Eligibility is solely the caller's `isActive`.

- [ ] **Step 4:** Migrate predecessor fixtures in the files listed above. Exact conversions:

1. All `sessionStatuses[...] = "known"` and `XCTAssertEqual(sessionStatuses[...], "known")` / `statusFor` expectations use the SessionStatus cases in Step 1. Nil assertions, dictionary keys, tool-name strings and frame dictionaries remain identical.
2. `BusyStateRecoveryTests` decoded local `state` and `sessions[n].state`, and `WorkspaceBrowsingTests` decoded `state`/`mode` expectations use `.thinking`, `.toolRunning`, `.toolStarting`, `.idle`, `.sessionEnded`, `.busy`, `.sessions` as applicable. Keep their wire inputs, required-field and malformed-entry assertions. In `ChatResilienceTests`, both decoded busy assertions (baseline lines 121 and 134) become `XCTAssertEqual(state, .busy)`; preserve JSON strings and the session-ID/nil assertions.
3. `ChatViewModelTests` pattern `.sessionInfo("cached", "/cached", "sessions")` becomes `.sessionInfo("cached", "/cached", .sessions)`. Three direct `incoming.send(.sessionInfo(... mode: ...))` test fixtures in `ConciergeViewModelTests` become `.sessions`/`.concierge`; production still never sends into this subject.
4. `TeamWSMessageTests`: decoded `channels[0].type`/`channels[1].type` expectations become `.channel`/`.dm`; decoded agent statuses become `.idle`/`.processing`. In `testAgentInfoDMChannelMemberMatching`, change the two decoded `TeamChannelInfo` lookup/filter comparisons (baseline lines 450/455) to `$0.type == .dm` and `$0.type != .dm`; retain member predicates and all three DM-match assertions. These decoded values use `.type`, not the persisted accessor `.kind`. Keep JSON values as strings.
5. `AgentRowTests` and `AgentDetailSheetTests` helper `status: String = "idle"` becomes `status: AgentStatus = .idle`, with typed call arguments. `TeamSortedAgentsTests`' constructor status becomes `.idle`.
6. `AgentDetailSheetTests` replace `AgentDetailSheet.statusTint(for: "raw")` with `AgentStatus(wire: "raw").presentation.tint`, and `statusDisplay` with `.presentation.label`. Retain each existing expected result and all unrelated tests.
7. `AgentRowTests.testStatusTintMapping`: use explicit pairs `[("idle", .success), ("processing", .warning), ("error", .danger), ("stopped", .danger), ("unknown", .muted), ("", .muted)]` with array type `[(String, KeepurStatusPill.Tint)]`; construct `makeAgent(status: AgentStatus(wire: raw))`, assert `agent.status.presentation.tint == expected`, and retain `_ = AgentRow(...).body` as secondary construction coverage.
8. `ChatHeaderMappingTests`: replace `ChatView.mapSessionStatus("raw").text` with `SessionStatus(wire: "raw").headerText`, and `.isActive` with the enum property. Keep each known expectation; change only the approved custom activity expectation from false to true. Replace Team mapping calls with `AgentStatus(wire: "raw").presentation.headerText/isActive`; replace the nil assertions with `let absent: AgentStatus? = nil; XCTAssertNil(absent?.presentation.headerText); XCTAssertFalse(absent?.presentation.isActive ?? false)`. Do not retain redundant mapping wrappers to keep tests compiling.

No new string-literal conformance or raw initializer overload is needed to conceal unmigrated typed tests. Read the diff against the baseline, ensuring assertion bodies/order are retained. Task 8 also checks baseline test identities.

- [ ] **Step 5:** Create `KeeperTests/TypedStateTests.swift` with the following complete code. It tests actual decode boundaries, all mappings and unknown/default policy; Task 3 covers real storage round trips.

```swift
import XCTest
@testable import Keepur

@MainActor
final class TypedStateTests: XCTestCase {
    private func data(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    func testSessionStatusRoundTripsPresentationAndDecode() throws {
        let cases: [(String, SessionStatus, Bool, String?)] = [
            ("idle", .idle, false, nil), ("thinking", .thinking, true, "thinking"),
            ("tool_starting", .toolStarting, true, "starting tool"),
            ("tool_running", .toolRunning, true, "running tool"),
            ("busy", .busy, true, "server busy"),
            ("session_ended", .sessionEnded, false, "session_ended"),
            ("future", .unknown("future"), true, "future"),
            ("", .unknown(""), true, ""), (" Idle ", .unknown(" Idle "), true, " Idle ")
        ]
        for (raw, expected, active, header) in cases {
            let value = SessionStatus(wire: raw)
            XCTAssertEqual(value, expected); XCTAssertEqual(value.wireValue, raw)
            XCTAssertEqual(value.isActive, active); XCTAssertEqual(value.headerText, header)
            guard case .status(let state, let id, let tool) = WSIncoming.decode(from: try data([
                "type": "status", "state": raw, "sessionId": "s", "toolName": "Read"
            ])) else { return XCTFail("status did not decode") }
            XCTAssertEqual(state, expected); XCTAssertEqual(id, "s"); XCTAssertEqual(tool, "Read")
            guard case .sessionList(let rows) = WSIncoming.decode(from: try data([
                "type": "session_list", "sessions": [["sessionId": "s", "path": "/s", "state": raw]]
            ])) else { return XCTFail("list did not decode") }
            XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows.first?.state, expected)
        }
        guard case .status(let state, let id, let tool) = WSIncoming.decode(from: try data([
            "type": "status", "state": "idle"
        ])) else { return XCTFail("optional status fields") }
        XCTAssertEqual(state, .idle); XCTAssertNil(id); XCTAssertNil(tool)
        XCTAssertNil(WSIncoming.decode(from: try data(["type": "status", "state": 7])))
    }

    func testSessionModeDefaultsAndUnknownMembershipInBothFrames() throws {
        let cases: [(Any?, SessionMode)] = [
            (nil, .sessions), (7, .sessions), ("sessions", .sessions), ("concierge", .concierge),
            ("future", .unknown("future")), ("", .unknown(""))
        ]
        for (raw, expected) in cases {
            var info: [String: Any] = ["type": "session_info", "sessionId": "s", "path": "/s"]
            var row: [String: Any] = ["sessionId": "s", "path": "/s", "state": "idle"]
            if let raw { info["mode"] = raw; row["mode"] = raw }
            guard case .sessionInfo(_, _, let mode) = WSIncoming.decode(from: try data(info)),
                  case .sessionList(let rows) = WSIncoming.decode(from: try data([
                    "type": "session_list", "sessions": [row]
                  ])) else { return XCTFail("mode decode") }
            XCTAssertEqual(mode, expected); XCTAssertEqual(rows.first?.mode, expected)
            XCTAssertEqual(SessionMode(wire: expected.wireValue), expected)
        }
        XCTAssertNotEqual(SessionMode(wire: "future"), .sessions)
        XCTAssertNotEqual(SessionMode(wire: "future"), .concierge)
        let outgoing = try JSONSerialization.jsonObject(with: WSOutgoing.newSessionConcierge.encode()) as? [String: String]
        XCTAssertEqual(outgoing, ["type": "new_session", "mode": "concierge"])
    }

    func testTeamDomainsDecodeWithoutDroppingUnknownRows() throws {
        let senders: [(String, SenderType)] = [
            ("person", .person), ("agent", .agent), ("system", .system),
            ("future", .unknown("future")), ("", .unknown(""))
        ]
        for (raw, expected) in senders {
            guard case .history(_, let rows, _, let id) = TeamWSIncoming.decode(from: try data([
                "type": "history", "channelId": "c", "hasMore": false, "id": "request",
                "messages": [["id": "m", "senderId": "other", "senderType": raw,
                              "senderName": "Other", "text": "hello", "createdAt": "2026-09-07T12:00:00.000Z"]]
            ])) else { return XCTFail("history decode") }
            XCTAssertEqual(id, "request"); XCTAssertEqual(rows.count, 1)
            XCTAssertEqual(rows.first?.senderType, expected)
            XCTAssertEqual(rows.first?.senderType.wireValue, raw)
            XCTAssertEqual(SenderType(wire: raw), expected)
        }
        XCTAssertNotEqual(SenderType(wire: "future"), .agent)
        let kinds: [(String, ChannelKind)] = [
            ("channel", .channel), ("dm", .dm), ("future", .unknown("future")), ("", .unknown(""))
        ]
        for (raw, expected) in kinds {
            guard case .channelList(let rows, _) = TeamWSIncoming.decode(from: try data([
                "type": "channel_list", "id": "r", "channels": [["id": "c", "type": raw, "name": "Raw"]]
            ])) else { return XCTFail("channel decode") }
            XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows.first?.type, expected)
            XCTAssertEqual(rows.first?.type.wireValue, raw)
        }
        XCTAssertNotEqual(ChannelKind(wire: "future"), .dm)
        XCTAssertNotEqual(ChannelKind(wire: "future"), .channel)
    }

    func testAgentPresentationAllFieldsAndDecoderDefaults() throws {
        let cases: [(String, AgentStatus, String, String?, Bool, KeepurStatusPill.Tint)] = [
            ("idle", .idle, "Idle", nil, false, .success),
            ("processing", .processing, "Processing", "working", true, .warning),
            ("error", .error, "Error", "error", false, .danger),
            ("stopped", .stopped, "Stopped", "stopped", false, .danger),
            ("customState", .unknown("customState"), "CustomState", "customState", false, .muted),
            ("", .unknown(""), "", "", false, .muted)
        ]
        for (raw, expected, label, header, active, tint) in cases {
            let status = AgentStatus(wire: raw), p = status.presentation
            XCTAssertEqual(status, expected); XCTAssertEqual(status.wireValue, raw)
            XCTAssertEqual(p.label, label); XCTAssertEqual(p.headerText, header)
            XCTAssertEqual(p.isActive, active); XCTAssertEqual(p.tint, tint)
            guard case .agentList(let rows, _) = TeamWSIncoming.decode(from: try data([
                "type": "agent_list", "id": "r", "agents": [["id": "a", "name": "A", "status": raw]]
            ])) else { return XCTFail("agent decode") }
            XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows.first?.status, expected)
        }
        for row: [String: Any] in [["id": "a", "name": "A"], ["id": "a", "name": "A", "status": 7]] {
            guard case .agentList(let rows, _) = TeamWSIncoming.decode(from: try data([
                "type": "agent_list", "id": "r", "agents": [row]
            ])) else { return XCTFail("agent default") }
            XCTAssertEqual(rows.first?.status, .idle)
        }
        let absent: AgentStatus? = nil
        XCTAssertNil(absent?.presentation.headerText)
        XCTAssertFalse(absent?.presentation.isActive ?? false)
    }
}
```

- [ ] **Step 6:** Run the Unit command without `PersistenceTests` (Task 3 has not created it yet), plus `kpr444_test typed-legacy -only-testing:KeeperTests/ChatResilienceTests -only-testing:KeeperTests/TeamWSMessageTests` (both existing classes discovered; all assertions pass) and `kpr444_test typed-regression -only-testing:KeeperTests -skip-testing:KeeperTests/CapabilityManagerTests`. Expected: existing local 263 tests retained plus the new typed tests, no compile failures, all selected tests pass. Inspect schema/consumer diffs, then commit Tasks 1–2 together:

```sh
git diff --check
git add Models/SessionStatus.swift Models/MessageRole.swift Models/SessionMode.swift Models/WSMessage.swift Models/TeamWSMessage.swift Models/Message.swift Models/TeamMessage.swift Models/TeamChannel.swift Models/ConciergeSessionStore.swift ViewModels/ChatViewModel.swift ViewModels/TeamViewModel.swift Views/ChatView.swift Views/MessageBubble.swift Views/SessionListView.swift Views/BeekeeperRootView.swift Views/Team/AgentStatusPresentation.swift Views/Team/AgentRow.swift Views/Team/AgentDetailSheet.swift Views/Team/TeamChatView.swift KeeperTests/TypedStateTests.swift KeeperTests/ChatViewModelTests.swift KeeperTests/ChatViewModelSocketTests.swift KeeperTests/PairingTeardownTests.swift KeeperTests/BusyStateRecoveryTests.swift KeeperTests/ChatResilienceTests.swift KeeperTests/WorkspaceBrowsingTests.swift KeeperTests/ConciergeViewModelTests.swift KeeperTests/TeamWSMessageTests.swift KeeperTests/TeamSortedAgentsTests.swift KeeperTests/AgentDetailSheetTests.swift KeeperTests/AgentRowTests.swift KeeperTests/ChatHeaderMappingTests.swift
git commit -m "refactor: type runtime state and unify status presentation"
```

## Chunk B — One Reporting Helper and Real SwiftData Tests

### Task 3: Add the helper, thrown-operation tests and upsert characterization

**Files:** Create `Managers/Persistence.swift`, `KeeperTests/PersistenceTests.swift`.

- [ ] **Step 1:** Create the helper exactly as follows. Both live and injected operations traverse `attemptReporting`; this is the **only catch/log**. Labels are compile-time `StaticString`, logging never evaluates `localizedDescription`, `userInfo`, domain, model values or input. Closure overloads are internal, synchronous and nonescaping. No operation retries, implicit save, rollback, container mutation or global hook.

```swift
import Foundation
import SwiftData
import os

extension ModelContext {
    func fetchOrEmpty<T: PersistentModel>(
        _ descriptor: FetchDescriptor<T>, _ what: StaticString
    ) -> [T] {
        var failure: Error?
        return fetchOrEmpty(descriptor, what, failure: &failure)
    }

    func fetchOrEmpty<T: PersistentModel>(
        _ descriptor: FetchDescriptor<T>, _ what: StaticString,
        failure: inout Error?
    ) -> [T] {
        fetchOrEmpty(descriptor, what, failure: &failure, operation: { try self.fetch($0) })
    }

    func fetchOrEmpty<T: PersistentModel>(
        _ descriptor: FetchDescriptor<T>, _ what: StaticString,
        failure: inout Error?, operation: (FetchDescriptor<T>) throws -> [T]
    ) -> [T] {
        attemptReporting(what, failure: &failure) { try operation(descriptor) } ?? []
    }

    @discardableResult
    func saveReporting(_ what: StaticString) -> Error? {
        saveReporting(what, operation: { try self.save() })
    }

    @discardableResult
    func saveReporting(_ what: StaticString, operation: () throws -> Void) -> Error? {
        var failure: Error?
        let _: Void? = attemptReporting(what, failure: &failure, operation: operation)
        return failure
    }

    private func attemptReporting<Value>(
        _ what: StaticString, failure: inout Error?, operation: () throws -> Value
    ) -> Value? {
        failure = nil
        do {
            return try operation()
        } catch {
            let label = String(describing: what)
            let errorType = String(reflecting: type(of: error))
            let code = (error as NSError).code
            Log.persistence.error("\(label, privacy: .public) failed: type=\(errorType, privacy: .public) code=\(code, privacy: .public)")
            failure = error
            return nil
        }
    }
}
```

- [ ] **Step 2:** Create the complete tests below. The throwing closure tests execute the same private catch path as `context.save()`/`context.fetch()`. The unique-ID fixture characterizes real SwiftData success separately; no production uniqueness preflight is permitted.

```swift
import XCTest
import SwiftData
@testable import Keepur

@MainActor
final class PersistenceTests: XCTestCase {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Session.self, Message.self, Workspace.self,
                           TeamChannel.self, TeamMessage.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    func testRealFetchSaveAndSuccessfulEmptyFetch() throws {
        let store = try container(), context = ModelContext(store)
        context.autosaveEnabled = false
        var failure: Error? = NSError(domain: "old", code: 1)
        XCTAssertTrue(context.fetchOrEmpty(FetchDescriptor<Session>(), "test.empty", failure: &failure).isEmpty)
        XCTAssertNil(failure)
        context.insert(Session(id: "one", path: "/one"))
        XCTAssertNil(context.saveReporting("test.realSave"))
        let fresh = ModelContext(store)
        let rows = fresh.fetchOrEmpty(FetchDescriptor<Session>(), "test.realFetch")
        XCTAssertEqual(rows.map(\.id), ["one"]); XCTAssertEqual(rows.first?.path, "/one")
    }

    func testFetchFailureReturnsOriginalAndNextSuccessResetsOutput() throws {
        let store = try container(), context = ModelContext(store)
        let sentinel = NSError(domain: "PersistenceTests", code: 444,
                               userInfo: [NSLocalizedDescriptionKey: "do not log stored data"])
        var failure: Error?, attempts = 0
        let failed = context.fetchOrEmpty(FetchDescriptor<Session>(), "test.throwFetch", failure: &failure) { _ in
            attempts += 1
            throw sentinel
        }
        XCTAssertTrue(failed.isEmpty); XCTAssertTrue((failure as NSError?) === sentinel)
        XCTAssertEqual(attempts, 1)
        let empty = context.fetchOrEmpty(FetchDescriptor<Session>(), "test.emptyAfterError", failure: &failure) { _ in
            attempts += 1
            return []
        }
        XCTAssertTrue(empty.isEmpty); XCTAssertNil(failure); XCTAssertEqual(attempts, 2)
        let row = Session(id: "row", path: "/row")
        let result = context.fetchOrEmpty(FetchDescriptor<Session>(), "test.rows", failure: &failure) { _ in
            attempts += 1
            return [row]
        }
        XCTAssertEqual(result.map(\.id), ["row"]); XCTAssertNil(failure); XCTAssertEqual(attempts, 3)
    }

    func testSaveAttemptsOnceAndReturnsOriginalWithoutThrowing() throws {
        let store = try container(), context = ModelContext(store)
        let sentinel = NSError(domain: "PersistenceTests", code: 445)
        var attempts = 0
        let failure = context.saveReporting("test.throwSave") {
            attempts += 1
            throw sentinel
        }
        XCTAssertTrue((failure as NSError?) === sentinel); XCTAssertEqual(attempts, 1)
        XCTAssertNil(context.saveReporting("test.successSave") { attempts += 1 })
        XCTAssertEqual(attempts, 2)
    }

    func testUniqueSessionIDIsSuccessfulUpsertOnSupportedRuntime() throws {
        let store = try container(), context = ModelContext(store)
        context.autosaveEnabled = false
        context.insert(Session(id: "unique", path: "/first", name: "First"))
        XCTAssertNil(context.saveReporting("test.insertUnique"))
        context.insert(Session(id: "unique", path: "/second", name: "Second"))
        XCTAssertNil(context.saveReporting("test.upsertUnique"))
        let rows = ModelContext(store).fetchOrEmpty(FetchDescriptor<Session>(), "test.fetchUpsert")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.id, "unique")
        XCTAssertEqual(rows.first?.path, "/second")
        XCTAssertEqual(rows.first?.name, "Second")
    }

    func testStoredAccessorsRoundTripWithoutRewritingUnknownValues() throws {
        let store = try container(), context = ModelContext(store)
        context.autosaveEnabled = false
        let roles: [MessageRole] = [.user, .assistant, .system, .tool, .unknown]
        for role in roles {
            context.insert(Message(id: role.rawValue, sessionId: "s", text: "text", role: role.rawValue))
        }
        context.insert(Message(id: "legacy", sessionId: "s", text: "text", role: "future-role"))
        let senders: [SenderType] = [.person, .agent, .system, .unknown("future-sender"), .unknown("")]
        for (index, sender) in senders.enumerated() {
            context.insert(TeamMessage(id: "sender-\(index)", channelId: "c", senderId: "other",
                                       senderType: sender.wireValue, senderName: "Other", text: "text"))
        }
        let kinds: [ChannelKind] = [.channel, .dm, .unknown("future-kind"), .unknown("")]
        for (index, kind) in kinds.enumerated() {
            context.insert(TeamChannel(id: "kind-\(index)", type: kind.wireValue, name: "raw"))
        }
        XCTAssertNil(context.saveReporting("test.accessors"))
        let fresh = ModelContext(store)
        let messages = fresh.fetchOrEmpty(FetchDescriptor<Message>(), "test.roles")
        for role in roles {
            let row = try XCTUnwrap(messages.first { $0.id == role.rawValue })
            XCTAssertEqual(row.typedRole, role); XCTAssertEqual(row.role, role.rawValue)
        }
        let legacy = try XCTUnwrap(messages.first { $0.id == "legacy" })
        XCTAssertNil(legacy.typedRole); XCTAssertEqual(legacy.role, "future-role")
        XCTAssertEqual(messages.first { $0.id == "unknown" }?.typedRole, .unknown)
        let team = fresh.fetchOrEmpty(FetchDescriptor<TeamMessage>(), "test.senders")
        for (index, expected) in senders.enumerated() {
            let row = try XCTUnwrap(team.first { $0.id == "sender-\(index)" })
            XCTAssertEqual(row.typedSenderType, expected); XCTAssertEqual(row.senderType, expected.wireValue)
        }
        let channels = fresh.fetchOrEmpty(FetchDescriptor<TeamChannel>(), "test.kinds")
        for (index, expected) in kinds.enumerated() {
            let row = try XCTUnwrap(channels.first { $0.id == "kind-\(index)" })
            XCTAssertEqual(row.kind, expected); XCTAssertEqual(row.type, expected.wireValue)
            XCTAssertEqual(row.displayName, expected == .channel ? "#raw" : "raw")
        }
    }
}
```

- [ ] **Step 3:** Run `kpr444_test helper -only-testing:KeeperTests/PersistenceTests`. Expected: 5 tests, zero failures, successful unique-ID save with one identity. Record runtime and actual failure evidence if upsert characterization fails; do not replace it with an invalid container, duplicate-rejection policy or synthetic post-success error. Inspect the single log line statically: only static label, type name and numeric code. Do not scrape asynchronous unified logs.

- [ ] **Step 4:** Verify and commit:

```sh
git diff --check
git add Managers/Persistence.swift KeeperTests/PersistenceTests.swift
git commit -m "fix: report SwiftData failures through one helper"
```

## Chunk C — Chat's 32 Persistence Sites and Terminal Alignment

### Task 4: Preserve every Chat continuation and exercise real callers

**Files:** Modify `ViewModels/ChatViewModel.swift`, `KeeperTests/ChatTestHarness.swift`; create `KeeperTests/ChatPersistenceTests.swift`.

- [ ] **Step 1:** Add the two private properties next to `modelContext`, append these defaulted parameters to the existing VM initializer after `lastErrorAutoClear`, and assign them before subscriptions. Preserve all earlier parameters/defaults and lazy speech.

```swift
private let saveOperation: (ModelContext) throws -> Void
private let sessionFetchOperation: (ModelContext, FetchDescriptor<Session>) throws -> [Session]

// Append initializer parameters (add comma after lastErrorAutoClear):
saveOperation: @escaping (ModelContext) throws -> Void = { try $0.save() },
sessionFetchOperation: @escaping (ModelContext, FetchDescriptor<Session>) throws -> [Session] = { try $0.fetch($1) }

// Assign in initializer:
self.saveOperation = saveOperation
self.sessionFetchOperation = sessionFetchOperation
```

Add this complete private wrapper inside the VM; its closure is synchronous, the VM owns no new Task, and the default closure captures no owner:

```swift
private func save(_ context: ModelContext, _ what: StaticString) {
    if context.saveReporting(what, operation: { try saveOperation(context) }) != nil {
        lastError = UserFacingError("Couldn't save. Your last change may not be kept.")
    }
}
```

- [ ] **Step 2:** Replace each first-row fetch using the exact expression below, retaining its existing `if let`, `guard let`, optional binding or insertion alternative. Labels are unique so review can match every original call to one replacement.

| Baseline line / caller | Complete replacement expression | Failure/empty continuation |
|---|---|---|
| 419 session-info upsert | `context.fetchOrEmpty(existingDescriptor, "chat.sessionInfo.existing.fetch").first` | Existing `else` inserts; keep save, selection/status, handoff and workspace steps. |
| 440 handoff old row | `context.fetchOrEmpty(oldDescriptor, "chat.sessionInfo.old.fetch").first` | Skip old deletion/nested save; continue workspace. |
| 479 context-cleared old row | `context.fetchOrEmpty(sessionDescriptor, "chat.contextCleared.old.fetch").first` | No handoff recorded; message/transient cleanup continues. |
| 513 replacement old row | `context.fetchOrEmpty(oldSessDescriptor, "chat.sessionReplaced.old.fetch").first` | Keep nil old/name; continue upsert/migration; later old-row save skipped. |
| 519 replacement new row | `context.fetchOrEmpty(existingNewDescriptor, "chat.sessionReplaced.new.fetch").first` | Existing `else` inserts; all following steps retained. |
| 757 final append | `context.fetchOrEmpty(descriptor, "chat.stream.final.fetch").first` | No append/save or replacement; completion/speech bookkeeping continues. |
| 772 final speech | `context.fetchOrEmpty(descriptor, "chat.stream.speech.fetch").first` | No speech/lazy speech construction; completion bookkeeping continues. |
| 785 nonfinal append | `context.fetchOrEmpty(descriptor, "chat.stream.append.fetch").first` | No append/save/new row; stream identity remains. |
| 885 local deletion Session | `context.fetchOrEmpty(sessionDescriptor, "chat.deleteLocal.session.fetch").first` | Skip row deletion; unconditional final save still runs. |
| 897 workspace upsert | `context.fetchOrEmpty(descriptor, "chat.workspace.existing.fetch").first` | Existing insertion alternative; pruning/save continue. |

At lines 878 and 909 the complete replacement blocks are:

```swift
// deleteLocalSession: replaces the optional fetched-array block only.
for msg in context.fetchOrEmpty(msgDescriptor, "chat.deleteLocal.messages.fetch") {
    context.delete(msg)
}

// saveWorkspace: replaces the optional stale-array block only.
for workspace in context.fetchOrEmpty(allDescriptor, "chat.workspace.stale.fetch") {
    context.delete(workspace)
}
```

Failure yields an empty loop; neither block gains a return or moves the unconditional final save.

- [ ] **Step 3:** Replace the three array-success boundaries with this exact code. These are the only Chat fetches that need the failure output. On success with zero rows the existing save/continuation still occurs.

```swift
// .contextCleared, baseline 490–493:
var messageFetchFailure: Error?
let messages = context.fetchOrEmpty(msgDescriptor, "chat.contextCleared.messages.fetch",
                                    failure: &messageFetchFailure)
if messageFetchFailure == nil {
    for msg in messages { context.delete(msg) }
    save(context, "chat.contextCleared.messages.save")
}
// Leave subsequent streaming/completed/status/tool/approval/watch/queue cleanup here.

// .sessionReplaced, baseline 534–537:
var messageFetchFailure: Error?
let messages = context.fetchOrEmpty(msgDescriptor, "chat.sessionReplaced.messages.fetch",
                                    failure: &messageFetchFailure)
if messageFetchFailure == nil {
    for msg in messages { msg.sessionId = newSessionId }
    save(context, "chat.sessionReplaced.messages.save")
}
// Leave selection, path, runtime/queue migration, old deletion and workspace flow here.

// syncSessions, baseline 806, after computing full IDs/table subsets but BEFORE knownIds:
var sessionFetchFailure: Error?
let fetched = context.fetchOrEmpty(FetchDescriptor<Session>(), "chat.syncSessions.fetch",
                                  failure: &sessionFetchFailure) { descriptor in
    try sessionFetchOperation(context, descriptor)
}
guard sessionFetchFailure == nil else { return }
```

A thrown all-Session operation invokes the same helper catch as a live fetch. The caller already assigned `serverSessions`, and `handleFrame` still publishes `incoming` after the returned handler. Don't move the guard below any reconnect snapshot/cancellation/mutation. Don't use `guard !fetched.isEmpty`.

- [ ] **Step 4:** Replace all 17 original save sites with the following statements **in place**, including the two already supplied above. Each stays in its original condition/order; no combined saves.

| Baseline line | Complete resulting statement |
|---|---|
| 234 optimistic user insert | `save(context, "chat.sendText.save")` |
| 429 session-info upsert | `save(context, "chat.sessionInfo.upsert.save")` |
| 442 handoff old-row deletion | `save(context, "chat.sessionInfo.old.save")` |
| 492 context-clear messages | `save(context, "chat.contextCleared.messages.save")` |
| 527 replacement upsert | `save(context, "chat.sessionReplaced.upsert.save")` |
| 536 replacement migration | `save(context, "chat.sessionReplaced.messages.save")` |
| 580 replacement old-row deletion | `save(context, "chat.sessionReplaced.old.save")` |
| 589 scoped error bubble | `save(context, "chat.error.save")` |
| 603 tool-output bubble | `save(context, "chat.toolOutput.save")` |
| 609 unknown frame | `save(context, "chat.unknown.save")` |
| 759 final append | `save(context, "chat.stream.final.save")` |
| 765 single-shot final | `save(context, "chat.stream.single.save")` |
| 787 nonfinal append | `save(context, "chat.stream.append.save")` |
| 792 first stream chunk | `save(context, "chat.stream.first.save")` |
| 859 full-list sync | `save(context, "chat.syncSessions.save")` |
| 889 local deletion | `save(context, "chat.deleteLocal.save")` |
| 915 workspace upsert/prune | `save(context, "chat.workspace.save")` |

- [ ] **Step 5:** Isolate the approved listed-terminal alignment in the full-list status loop. Replace the typed loop's `if server.state == .idle ... else ...` with this exact branch body. All table work before it and the save/selection/flush after it remain in place:

```swift
if server.state == .sessionEnded {
    endSession(id)
} else if server.state == .idle {
    sessionStatuses[id] = .idle
    sessionToolNames.removeValue(forKey: id)
    cancelBusyWatchdog(for: id)
    if wasBusy, !flushed.contains(id), releaseQueuedHead(for: id) {
        flushed.insert(id)
    }
} else {
    if !wasBusy { sessionStatuses[id] = server.state }
    // Preserve useful tool/thinking detail on busy → busy.
    armBusyWatchdog(for: id)
}
```

`endSession` already removes stream/completed IDs, approvals, status, tool, watch, queued payloads and release-only sets. It leaves listed table rows/selection intact. Do not set terminal to `.idle` or call release. The later reconnect flush sees no terminal queued entry. Preserve ordinary busy/busy detail, idle suppression and absence logic.

- [ ] **Step 6:** Extend `ChatTestHarness.init` by appending defaulted `saveOperation` and `sessionFetchOperation` parameters with the **same signatures/defaults as Step 1**, plus `lastErrorAutoClear: Duration = .seconds(6)`. Forward all three to the existing Chat initializer, after `staleBusyTimeout: watchdog`. Set `context.autosaveEnabled = false` in the new integration tests after constructing the harness, not globally. Keep harness `status`/`list` methods String-based because they send JSON. Keep close, subscription and speech behavior.

- [ ] **Step 7:** Create the complete integration tests below. Bounded sleeps occur only when proving absence over a known watchdog/fallback deadline, with positive socket observations before them. The five-second fallback is deliberately real; do not add a timer seam.

```swift
import XCTest
import SwiftData
import Combine
@testable import Keepur

@MainActor
final class ChatPersistenceTests: XCTestCase {
    private let copy = "Couldn't save. Your last change may not be kept."

    func testFailedOptimisticSaveKeepsOfflinePayloadAndInputContinuation() async throws {
        let sentinel = NSError(domain: "ChatPersistenceTests", code: 1)
        var attempts = 0, fail = true
        let h = try ChatTestHarness(saveOperation: { context in
            attempts += 1
            if fail { throw sentinel }
            try context.save()
        })
        defer { h.close() }; h.context.autosaveEnabled = false
        let attachment = AttachmentData(data: Data([4, 4, 4]), name: "a.bin", mimeType: "application/octet-stream")
        let id = try h.send("", attachment: attachment)
        XCTAssertEqual(attempts, 1); XCTAssertEqual(h.vm.lastError?.text, copy)
        let errorID = try XCTUnwrap(h.vm.lastError?.id)
        XCTAssertEqual(h.vm.messageText, ""); XCTAssertNil(h.vm.pendingAttachment)
        XCTAssertEqual(h.vm.pendingReasons[id], .offline); XCTAssertEqual(h.vm.queuedAttachmentCountForTesting, 1)
        XCTAssertTrue(try h.frames("message").isEmpty); XCTAssertTrue(try h.frames("file").isEmpty)
        let row = try XCTUnwrap(h.messages().first { $0.id == id })
        XCTAssertEqual(row.text, "a.bin"); XCTAssertEqual(row.attachmentData, attachment.data)
        fail = false
        try await h.connect()
        try await h.list([("a", "idle", "sessions")])
        XCTAssertEqual(h.vm.lastError?.id, errorID, "successful sync save must not replace or clear error")
        XCTAssertEqual(try h.frames("file").count, 1); XCTAssertTrue(try h.frames("message").isEmpty)
        XCTAssertEqual(try h.frames("file").first?["data"] as? String, attachment.data.base64EncodedString())
        XCTAssertNil(h.vm.pendingReasons[id]); XCTAssertEqual(h.vm.queuedAttachmentCountForTesting, 0)
    }

    func testFailedSaveStillSendsWhenConnectedAndConditionalAppendReports() async throws {
        let sentinel = NSError(domain: "ChatPersistenceTests", code: 2)
        var fail = false, attempts = 0
        let h = try ChatTestHarness(saveOperation: { context in
            attempts += 1
            if fail { throw sentinel }
            try context.save()
        })
        defer { h.close() }; h.context.autosaveEnabled = false
        try await h.connect(); try await h.list([("a", "idle", "sessions")])
        fail = true
        let start = attempts, id = try h.send("direct")
        XCTAssertEqual(attempts, start + 1); XCTAssertEqual(h.vm.lastError?.text, copy)
        XCTAssertNil(h.vm.pendingReasons[id]); XCTAssertEqual(h.vm.messageText, "")
        XCTAssertEqual(try h.frames("message").compactMap { $0["text"] as? String }, ["direct"])
        fail = false
        try await h.chunk("first")
        let streamID = try XCTUnwrap(h.messages("a", role: "assistant").first?.id)
        let before = attempts
        let previousErrorID = try XCTUnwrap(h.vm.lastError?.id)
        fail = true
        try await h.chunk(" second")
        XCTAssertEqual(attempts, before + 1)
        XCTAssertEqual(h.vm.lastError?.text, copy)
        XCTAssertNotEqual(try XCTUnwrap(h.vm.lastError?.id), previousErrorID,
                          "conditional append must assign a new persistence error")
        let rows = try h.messages("a", role: "assistant")
        XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows.first?.id, streamID)
        XCTAssertEqual(rows.first?.text, "first second")
    }

    func testSuccessfulSaveLeavesExistingErrorTimerIdentityAndDeadline() async throws {
        let h = try ChatTestHarness(lastErrorAutoClear: .seconds(2))
        defer { h.close() }; try await h.connect()
        try await h.receive(["type": "error", "message": "server error"])
        let original = try XCTUnwrap(h.vm.lastError?.id)
        try await Task.sleep(for: .seconds(1))
        _ = try h.send("saved")
        XCTAssertEqual(h.vm.lastError?.id, original)
        try await eventually("original error deadline", timeout: .milliseconds(1500)) { h.vm.lastError == nil }
    }

    func testFailedFullListPublishesWithoutSyncMutationAndFallbackStillWins() async throws {
        let sentinel = NSError(domain: "ChatPersistenceTests", code: 3)
        var saves = 0, fetches = 0
        let h = try ChatTestHarness(saveOperation: { context in saves += 1; try context.save() },
                                   sessionFetchOperation: { _, _ in fetches += 1; throw sentinel })
        defer { h.close() }; h.context.autosaveEnabled = false
        h.context.insert(Session(id: "kept", path: "/kept", name: "Kept")); try h.context.save()
        h.vm.sessionStatuses["a"] = .idle
        h.vm.sessionStatuses["busy"] = .toolRunning
        h.vm.sessionToolNames["busy"] = "Read"
        let first = try h.send("head"), tail = try h.send("tail")
        let held = try h.send("held", id: "busy")
        h.vm.currentSessionId = "kept"; h.vm.currentPath = "/kept"
        let beforeReasons = h.vm.pendingReasons, beforeStatuses = h.vm.sessionStatuses
        try await h.connect()
        let beforeSave = saves, beforeReceived = h.received
        var published = 0
        let observer = h.vm.incoming.sink { frame in
            if case .sessionList = frame {
                published += 1
                XCTAssertEqual(h.vm.serverSessions.map(\.sessionId), ["new", "a", "busy"])
                XCTAssertEqual(h.vm.sessionStatuses, beforeStatuses)
            }
        }
        defer { observer.cancel() }
        try await h.list([("new", "idle", "sessions"), ("a", "idle", "sessions"), ("busy", "session_ended", "sessions")])
        XCTAssertEqual(fetches, 1); XCTAssertEqual(saves, beforeSave)
        XCTAssertEqual(published, 1); XCTAssertEqual(h.received, beforeReceived + 1)
        XCTAssertEqual(h.vm.pendingReasons, beforeReasons); XCTAssertEqual(h.vm.sessionStatuses, beforeStatuses)
        XCTAssertEqual(h.vm.sessionToolNames["busy"], "Read"); XCTAssertNil(h.vm.lastError)
        XCTAssertEqual(h.vm.currentSessionId, "kept"); XCTAssertEqual(h.vm.currentPath, "/kept")
        XCTAssertEqual(try h.sessions().map(\.id), ["kept"])
        XCTAssertEqual(try h.sessions().first?.isStale, false)
        XCTAssertTrue(try h.frames("message").isEmpty)
        try await eventually("five-second fallback retains eligibility", timeout: .seconds(6)) {
            try h.frames("message").count == 1
        }
        XCTAssertEqual(try h.frames("message").first?["text"] as? String, "head")
        XCTAssertNil(h.vm.pendingReasons[first]); XCTAssertEqual(h.vm.pendingReasons[tail], .busy)
        XCTAssertEqual(h.vm.pendingReasons[held], .busy)
        XCTAssertEqual(h.vm.sessionStatuses["busy"], .toolRunning)
        XCTAssertEqual(saves, beforeSave, "fallback is not a new persistence path")
    }

    func testSuccessfulEmptyFullListFetchOwnsReconnectAndInsertsOnlyExactSessions() async throws {
        var fetches = 0
        let h = try ChatTestHarness(sessionFetchOperation: { context, descriptor in
            fetches += 1
            return try context.fetch(descriptor)
        })
        defer { h.close() }; h.context.autosaveEnabled = false
        let first = try h.send("head"), tail = try h.send("tail")
        XCTAssertTrue(try h.sessions().isEmpty)
        try await h.connect()
        try await h.list([("a", "idle", "sessions"), ("c", "busy", "concierge"), ("future", "idle", "new-mode")])
        XCTAssertEqual(fetches, 1); XCTAssertEqual(try h.sessions().map(\.id), ["a"])
        let awaiting = try XCTUnwrap(Mirror(reflecting: h.vm).children.first {
            $0.label == "awaitingPostReconnectSync"
        }?.value as? Bool)
        XCTAssertFalse(awaiting, "successful empty fetch consumes the reconnect pass")
        let fallback = try XCTUnwrap(Mirror(reflecting: h.vm).children.first {
            $0.label == "postReconnectFlushFallback"
        }?.value)
        XCTAssertEqual(Mirror(reflecting: fallback).displayStyle, .optional)
        XCTAssertTrue(Mirror(reflecting: fallback).children.isEmpty,
                      "successful empty fetch cancels and clears fallback ownership")
        XCTAssertEqual(h.vm.serverSessions.count, 3); XCTAssertEqual(h.vm.sessionStatuses["c"], .busy)
        XCTAssertNil(h.vm.pendingReasons[first]); XCTAssertEqual(h.vm.pendingReasons[tail], .busy)
        XCTAssertEqual(try h.frames("message").count, 1)
        try await Task.sleep(for: .milliseconds(5200))
        XCTAssertEqual(try h.frames("message").count, 1, "consumed fallback cannot release a second head")
        try await h.list([("a", "idle", "sessions"), ("c", "busy", "concierge"), ("future", "idle", "new-mode")])
        XCTAssertEqual(try h.frames("message").count, 1, "repeated idle list gives no additional release")
        try await h.status("idle")
        XCTAssertEqual(try h.frames("message").compactMap { $0["text"] as? String }, ["head", "tail"])
        try await h.receive(["type": "session_info", "sessionId": "future", "path": "/future", "mode": "new-mode"])
        XCTAssertTrue(try h.sessions().contains { $0.id == "future" }, "unknown info keeps ordinary path")
    }

    func testSuccessfulEmptyClearAndReplacementKeepNestedSaveBoundaries() async throws {
        var saves = 0
        let h = try ChatTestHarness(saveOperation: { context in saves += 1; try context.save() })
        defer { h.close() }; h.context.autosaveEnabled = false
        try await h.connect()
        h.context.insert(Session(id: "a", path: "/work", name: "Named")); try h.context.save()
        h.vm.currentSessionId = "a"
        try await h.status("busy"); try await h.approval("approval")
        let beforeClear = saves
        try await h.receive(["type": "context_cleared", "oldSessionId": "a", "sessionId": "a"])
        XCTAssertEqual(saves, beforeClear + 1, "successful empty Message fetch still saves")
        XCTAssertEqual(h.vm.currentSessionId, "a"); XCTAssertEqual(try h.sessions().first?.name, "Named")
        XCTAssertNil(h.vm.sessionStatuses["a"]); XCTAssertNil(h.vm.pendingApprovals["a"])
        let beforeReplace = saves
        try await h.receive(["type": "session_replaced", "oldSessionId": "a", "newSessionId": "b", "path": "/work"])
        XCTAssertEqual(saves, beforeReplace + 4, "upsert, empty migration, old delete, workspace")
        XCTAssertEqual(try h.sessions().map(\.id), ["b"]); XCTAssertEqual(try h.sessions().first?.name, "Named")
        XCTAssertEqual(h.vm.currentSessionId, "b"); XCTAssertEqual(h.vm.currentPath, "/work")
        XCTAssertTrue(try h.messages().isEmpty)
    }

    func testListedTerminalClearsBusyRuntimeWithoutIdleReleaseOrRowDeletion() async throws {
        let h = try ChatTestHarness(watchdog: .milliseconds(100))
        defer { h.close() }; try await h.connect()
        try await h.list([("a", "idle", "sessions"), ("other", "idle", "sessions")])
        h.vm.currentSessionId = "a"; h.vm.currentPath = "/a"
        try await h.status("tool_running", tool: "Read")
        try await h.chunk("completed", final: true); try await h.chunk("partial")
        try await h.approval("ua"); try await h.approval("uo", id: "other")
        let oldIDs = Set(try h.messages("a", role: "assistant").map(\.id))
        let queued = try h.send("never", attachment: AttachmentData(data: Data([9]), name: "a.bin", mimeType: "application/octet-stream"))
        try await h.list([("a", "session_ended", "sessions"), ("other", "idle", "sessions")])
        XCTAssertNil(h.vm.sessionStatuses["a"]); XCTAssertNil(h.vm.sessionToolNames["a"])
        XCTAssertNil(h.vm.pendingApprovals["a"]); XCTAssertNotNil(h.vm.pendingApprovals["other"])
        let completed = try XCTUnwrap(Mirror(reflecting: h.vm).children.first {
            $0.label == "lastCompletedMessageIds"
        }?.value as? [String: String])
        XCTAssertNil(completed["a"], "terminal also clears completed-message speech bookkeeping")
        XCTAssertNil(h.vm.pendingReasons[queued]); XCTAssertEqual(h.vm.queuedAttachmentCountForTesting, 0)
        XCTAssertEqual(h.vm.currentSessionId, "a"); XCTAssertEqual(h.vm.currentPath, "/a")
        XCTAssertEqual(try h.sessions().first { $0.id == "a" }?.isStale, false)
        XCTAssertTrue(try h.frames("message").isEmpty); XCTAssertTrue(try h.frames("file").isEmpty)
        let queries = try h.frames("list_sessions").count
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(try h.frames("list_sessions").count, queries, "terminal does not re-arm watch")
        try await h.status("idle")
        XCTAssertTrue(try h.frames("message").isEmpty, "no retained queued terminal payload")
        try await h.chunk("fresh")
        let fresh = try XCTUnwrap(h.messages("a", role: "assistant").first { $0.text == "fresh" })
        XCTAssertFalse(oldIDs.contains(fresh.id))
        // A fresh direct send remains eligible after the terminated queue was cleared.
        _ = try h.send("after")
        XCTAssertEqual(try h.frames("message").compactMap { $0["text"] as? String }, ["after"])
    }

    func testListedTerminalDuringReconnectCannotFlushAndClearsReleaseOnlyState() async throws {
        let h = try ChatTestHarness(); defer { h.close() }
        _ = try h.send("first"); let tail = try h.send("never")
        try await h.connect()
        try await h.status("idle") // releases first before the initial list; both release sets now contain a.
        try await h.status("thinking")
        try await h.list([("a", "session_ended", "sessions")])
        XCTAssertNil(h.vm.pendingReasons[tail]); XCTAssertNil(h.vm.sessionStatuses["a"])
        XCTAssertEqual(try h.frames("message").compactMap { $0["text"] as? String }, ["first"])
        _ = try h.send("fresh")
        XCTAssertEqual(try h.frames("message").compactMap { $0["text"] as? String }, ["first", "fresh"])
        XCTAssertTrue(h.vm.pendingReasons.isEmpty)
    }

    func testUnknownNonIdleStatusIsActiveWatchedAndNeverReleasesPendingWork() async throws {
        let h = try ChatTestHarness(watchdog: .milliseconds(80))
        defer { h.close() }; try await h.connect()
        try await h.list([("a", "mystery", "sessions")])
        XCTAssertEqual(h.vm.statusFor("a"), .unknown("mystery")); XCTAssertTrue(h.vm.statusFor("a").isActive)
        let pending = try h.send("held")
        XCTAssertEqual(h.vm.pendingReasons[pending], .busy)
        let count = try h.frames("list_sessions").count
        try await eventually("unknown status is watched") { try h.frames("list_sessions").count > count }
        XCTAssertEqual(h.vm.statusFor("a"), .unknown("mystery"))
        XCTAssertTrue(try h.frames("message").isEmpty); XCTAssertEqual(h.vm.pendingReasons[pending], .busy)
        try await h.list([("a", "another-mystery", "sessions")])
        XCTAssertEqual(h.vm.statusFor("a"), .unknown("mystery"), "busy/busy preserves detail")
        XCTAssertTrue(try h.frames("message").isEmpty)
    }
}
```

- [ ] **Step 8:** Audit all **15 fetches / 17 saves** against Steps 2–4 and the original source. Specifically attest that the three failure checks surround exactly the original work, all success-empty paths still save, and fetch failures never write `lastError`. Shared-helper throw tests plus this caller audit cover non-injected fetches; do not add global context registries to force every descriptor to fail.

Run `kpr444_test chat -only-testing:KeeperTests/ChatPersistenceTests -only-testing:KeeperTests/ChatViewModelTests -only-testing:KeeperTests/ChatViewModelSocketTests -only-testing:KeeperTests/ConciergeViewModelTests -only-testing:KeeperTests/PairingTeardownTests -only-testing:KeeperTests/ContextClearedTests -only-testing:KeeperTests/SessionReplacedTests -only-testing:KeeperTests/ChatResilienceTests`. `ChatViewModelSocketTests` includes the queue cases declared in its same-class extension at baseline line 463; verify those methods appear in the run. Expected: all existing assertions and 9 new tests execute and pass.

- [ ] **Step 9:** Verify and commit:

```sh
git diff --check
git add ViewModels/ChatViewModel.swift KeeperTests/ChatTestHarness.swift KeeperTests/ChatPersistenceTests.swift
git commit -m "fix: preserve Chat persistence failure paths and terminal cleanup"
```

## Chunk D — Team and Direct-View Persistence

### Task 5: Replace Team's 26 calls without changing its history or queue policy

**Files:** Modify `ViewModels/TeamViewModel.swift`, `KeeperTests/TeamViewModelTests.swift`.

- [ ] **Step 1:** Add `private let saveOperation: (ModelContext) throws -> Void` beside `modelContext`. Append `saveOperation: @escaping (ModelContext) throws -> Void = { try $0.save() }` after the existing `lastErrorAutoClear` initializer parameter; assign `self.saveOperation = saveOperation` before subscriptions. Add this complete private method:

```swift
private func save(_ context: ModelContext, _ what: StaticString) {
    if context.saveReporting(what, operation: { try saveOperation(context) }) != nil {
        lastError = UserFacingError("Couldn't save. Your last change may not be kept.")
    }
}
```

Every original save still runs once, in place; success never writes `lastError`. Fetches remain log-only and use live helper defaults; no Team fetch seam is needed.

- [ ] **Step 2:** Replace every Team fetch expression with the complete expression below, retaining the surrounding control flow. This inventory is **16 fetches**, not the historical count in the ticket.

| Baseline / caller | Complete resulting expression or statement | Failed/empty result behavior |
|---|---|---|
| 288 selectChannel | `context.fetchOrEmpty(channelDescriptor, "team.selectChannel.fetch").first` | Skip cursor reset; still fetch history. |
| 312 fetchHistory | `context.fetchOrEmpty(channelDescriptor, "team.fetchHistory.fetch").first` | Leave `before` nil; keep loading state/latest-page send. |
| 331 joinChannel | `if context.fetchOrEmpty(descriptor, "team.joinChannel.fetch").first != nil { return }` | Failure/empty still sends join; found row returns. |
| 357 onConnected | `context.fetchOrEmpty(descriptor, "team.onConnected.fetch").first` | Skip cursor reset; keep prior request order, history and end-of-handler resend. |
| 400 moveUnackedToOffline | `ordered = context.fetchOrEmpty(descriptor, "team.moveUnacked.fetch").map(\.id)` | Empty fetched order; original unmatched IDs still append in existing iteration; maps/hive stamping unchanged. |
| 420 resendOfflineEntries | `context.fetchOrEmpty(descriptor, "team.resendOffline.fetch").first` | Guard removes this entry and attachment, continues; rejected-send guard still breaks, never changed to continue. |
| 570 ack | `context.fetchOrEmpty(descriptor, "team.ack.fetch").first` | Mapping already removed; no row pending mutation/save/refresh. |
| 605 syncChannels | `let localChannels = context.fetchOrEmpty(descriptor, "team.syncChannels.fetch")` | Empty local set still inserts supplied channels, saves and reloads. |
| 652 loadChannels | `channels = context.fetchOrEmpty(descriptor, "team.loadChannels.fetch")` | Publish empty; recompute sortedAgents. |
| 674 history cursor | `context.fetchOrEmpty(descriptor, "team.history.cursor.fetch").first` | Skip cursor only; dedup/insertion/save/preview/loading continue. |
| 687 history dedup | `let existingMessages = context.fetchOrEmpty(allDescriptor, "team.history.messages.fetch")` | Empty lookup sets; existing insertion algorithm continues. |
| 765 joined-other member | `context.fetchOrEmpty(descriptor, "team.channelEvent.joined.fetch").first` | Skip member append/save; duplicate-member condition retained. |
| 777 self-left | `context.fetchOrEmpty(descriptor, "team.channelEvent.left.fetch").first` | Skip deletion/save/reload and nested active selection/message clearing. |
| 794 archived | `context.fetchOrEmpty(descriptor, "team.channelEvent.archived.fetch").first` | Skip deletion/save/reload and nested active selection/message clearing. |
| 815 preview | `context.fetchOrEmpty(descriptor, "team.preview.fetch").first` | Skip mutation/save/sort/recompute. |
| 851 active messages | `activeMessages = context.fetchOrEmpty(descriptor, "team.activeMessages.fetch")` | Publish empty array. |

- [ ] **Step 3:** Replace all ten save statements **at their existing nesting level**:

| Baseline line | Complete resulting statement |
|---|---|
| 253 optimistic send | `save(context, "team.sendMessage.save")` |
| 498 incoming team message | `save(context, "team.message.save")` |
| 538 incoming system response | `save(context, "team.systemMessage.save")` |
| 572 ack | `save(context, "team.ack.save")` |
| 629 channel sync | `save(context, "team.syncChannels.save")` |
| 738 history | `save(context, "team.history.save")` |
| 768 joined member | `save(context, "team.channelEvent.joined.save")` |
| 779 self left | `save(context, "team.channelEvent.left.save")` |
| 796 archived | `save(context, "team.channelEvent.archived.save")` |
| 820 preview | `save(context, "team.preview.save")` |

Do not fix content-key history matching, request-ID correlation, orphan deletion, DM timeout, command-map lifetime, serverId storage or queued-channel retention. Those are E. Existing system-message construction still stores `SenderType.agent.wireValue` and uses sender ID `"system"`.

- [ ] **Step 4:** Document the two no-ops in place, with both enum/decoder cases and outgoing command-list request retained:

```swift
case .typing:
    break // Deliberately ignored: the current Team UI has no typing surface.

case .commandList:
    break // Deliberately ignored: slash commands use the existing free-form input.
```

Keep their positions in the switch; the snippets are separate replacements, not adjacent new switch branches.

- [ ] **Step 5:** Extend the private `makeViewModel` test builder in `KeeperTests/TeamViewModelTests.swift` with `saveOperation: @escaping (ModelContext) throws -> Void = { try $0.save() }` after its current `lastErrorAutoClear` argument, and forward it into `TeamViewModel`. Retain the existing container/factory/capability and selected-channel setup. Make fixture isolation explicit: add `private var savedHive: String?` beside the existing properties; make `savedHive = UserDefaults.standard.string(forKey: "selectedHive")` the first line of `setUp`, before its existing removal. In `tearDown`, replace its final unconditional removal with the following, after releasing the VM/capability/context/container:

```swift
if let savedHive { UserDefaults.standard.set(savedHive, forKey: "selectedHive") }
else { UserDefaults.standard.removeObject(forKey: "selectedHive") }
```

This follows `PairingTeardownTests` and preserves both a prior value and prior absence. Add the following helper and tests **inside the existing class**; keep every previous test unchanged apart from typed fixtures already covered by Task 2:

```swift
private func receivePersistenceFrame(_ object: [String: Any], on task: FakeWebSocketTask) async throws {
    try await eventually("Team receive armed") { task.receiveRequested }
    let data = try JSONSerialization.data(withJSONObject: object)
    task.deliver(String(decoding: data, as: UTF8.self))
    try await eventually("Team handler completed and receive rearmed") { task.receiveRequested }
}

func testFailedOptimisticSaveRetainsOfflineAttachmentAndResendsNormally() async throws {
    let sentinel = NSError(domain: "TeamPersistenceTests", code: 1)
    var fail = true, attempts = 0
    makeViewModel(saveOperation: { context in
        attempts += 1
        if fail { throw sentinel }
        try context.save()
    })
    context.autosaveEnabled = false
    capability._setHivesForTesting(["hive-1"])
    vm.connectIfPossible()
    let task = try XCTUnwrap(factory.latest)
    let bytes = Data([4, 4, 4])
    vm.pendingAttachment = AttachmentData(data: bytes, name: "a.bin", mimeType: "application/octet-stream")
    vm.messageText = "draft"
    vm.sendMessage(text: "queued")
    let row = try XCTUnwrap(rows().first)
    XCTAssertEqual(attempts, 1)
    XCTAssertEqual(vm.lastError?.text, "Couldn't save. Your last change may not be kept.")
    let errorID = try XCTUnwrap(vm.lastError?.id)
    XCTAssertEqual(vm.messageText, ""); XCTAssertNil(vm.pendingAttachment)
    XCTAssertTrue(row.pending); XCTAssertEqual(row.typedSenderType, .person)
    XCTAssertEqual(vm.offlineEntries, [.init(localId: row.id, hive: "hive-1")])
    XCTAssertEqual(vm.queuedAttachmentCountForTesting, 1)
    XCTAssertEqual(vm.pendingMessageRequestCountForTesting, 0)
    XCTAssertTrue(task.sentTexts.isEmpty)
    fail = false
    task.completeHandshake()
    try await eventually("Team queued payload resent") { try self.messageFrames(task).count == 1 }
    XCTAssertEqual(try messageFrames(task).map(\.text), ["queued"])
    let file = try XCTUnwrap(sentFrames(task).first { $0["type"] as? String == "file" })
    XCTAssertEqual(file["data"] as? String, bytes.base64EncodedString())
    XCTAssertTrue(vm.offlineEntries.isEmpty); XCTAssertEqual(vm.queuedAttachmentCountForTesting, 0)
    XCTAssertTrue(row.pending, "socket acceptance is not ack")
    XCTAssertEqual(vm.pendingMessageRequestCountForTesting, 1)
    let request = try XCTUnwrap(messageFrames(task).first?.id)
    try await receivePersistenceFrame(["type": "ack", "id": request], on: task)
    XCTAssertFalse(row.pending); XCTAssertEqual(vm.pendingMessageRequestCountForTesting, 0)
    XCTAssertEqual(vm.lastError?.id, errorID, "successful ack save leaves error timer/identity alone")
    vm.disconnect()
}

func testFailedSaveKeepsConnectedSendAndConditionalAckContinuation() async throws {
    let sentinel = NSError(domain: "TeamPersistenceTests", code: 2)
    var fail = true, attempts = 0
    makeViewModel(saveOperation: { context in
        attempts += 1
        if fail { throw sentinel }
        try context.save()
    })
    context.autosaveEnabled = false
    let task = try await connectHive1()
    vm.messageText = "direct"; vm.sendMessage(text: "direct")
    let row = try XCTUnwrap(rows().first), request = try XCTUnwrap(messageFrames(task).first?.id)
    XCTAssertEqual(attempts, 1); XCTAssertEqual(vm.messageText, "")
    XCTAssertTrue(row.pending); XCTAssertTrue(vm.offlineEntries.isEmpty)
    XCTAssertEqual(try messageFrames(task).map(\.text), ["direct"])
    XCTAssertEqual(vm.pendingMessageRequestCountForTesting, 1)
    XCTAssertEqual(vm.lastError?.text, "Couldn't save. Your last change may not be kept.")
    vm.lastError = nil // normal supported dismissal; subsequent error comes from actual ack save.
    try await receivePersistenceFrame(["type": "ack", "id": request], on: task)
    XCTAssertEqual(attempts, 2)
    XCTAssertEqual(vm.lastError?.text, "Couldn't save. Your last change may not be kept.")
    XCTAssertFalse(row.pending); XCTAssertEqual(vm.pendingMessageRequestCountForTesting, 0)
    XCTAssertEqual(vm.activeMessages.first { $0.id == row.id }?.pending, false)
    fail = false
    let previous = try XCTUnwrap(vm.lastError?.id)
    vm.sendMessage(text: "later")
    XCTAssertEqual(vm.lastError?.id, previous)
    vm.disconnect()
}

func testMissingOfflineRowDropsOnlyThatEntryAndPreservesResendOrder() async throws {
    context.autosaveEnabled = false
    capability._setHivesForTesting(["hive-1"]); vm.connectIfPossible()
    let task = try XCTUnwrap(factory.latest)
    vm.sendMessage(text: "first")
    vm.pendingAttachment = AttachmentData(data: Data([9]), name: "gone.bin", mimeType: "application/octet-stream")
    vm.sendMessage(text: "missing")
    vm.sendMessage(text: "last")
    let missing = try XCTUnwrap(rows().first { $0.text == "missing" })
    let first = try XCTUnwrap(rows().first { $0.text == "first" })
    let last = try XCTUnwrap(rows().first { $0.text == "last" })
    XCTAssertEqual(vm.offlineMessageIds, [first.id, missing.id, last.id])
    context.delete(missing); try context.save()
    task.completeHandshake()
    try await eventually("remaining rows resent") { try self.messageFrames(task).count == 2 }
    XCTAssertEqual(try messageFrames(task).map(\.text), ["first", "last"])
    XCTAssertTrue(vm.offlineEntries.isEmpty); XCTAssertEqual(vm.queuedAttachmentCountForTesting, 0)
    XCTAssertEqual(vm.pendingMessageRequestCountForTesting, 2)
    XCTAssertTrue(first.pending); XCTAssertTrue(last.pending)
    XCTAssertTrue(try sentFrames(task).filter { $0["type"] as? String == "file" }.isEmpty)
    vm.disconnect()
}

func testMissingChannelEventsRetainSelectionAndMessagesButJoinStillSends() async throws {
    let task = try await connectHive1()
    vm.sendMessage(text: "retained")
    let id = try XCTUnwrap(rows().first?.id)
    XCTAssertTrue(try context.fetch(FetchDescriptor<TeamChannel>()).isEmpty)
    for event in ["left", "archived"] {
        try await receivePersistenceFrame([
            "type": "channel_event", "channelId": "channel-1", "event": event,
            "detail": ["memberId": "device-old"], "id": "event-\(event)"
        ], on: task)
        XCTAssertEqual(vm.activeChannelId, "channel-1")
        XCTAssertEqual(vm.activeMessages.map(\.id), [id])
    }
    let before = try sentFrames(task).filter { $0["type"] as? String == "join" }.count
    vm.joinChannel(channelId: "missing")
    XCTAssertEqual(try sentFrames(task).filter { $0["type"] as? String == "join" }.count, before + 1)
    vm.disconnect()
}

func testUnknownTeamKindsAndSendersPersistWithoutKnownTypeMembership() async throws {
    let task = try await connectHive1()
    vm.agents = [TeamAgentInfo(id: "agent-1", name: "Agent", icon: "", title: nil,
                              model: "", status: .idle, tools: [], schedule: [], channels: [],
                              messagesProcessed: 0, lastActivity: nil)]
    try await receivePersistenceFrame([
        "type": "channel_list", "id": "channels", "channels": [
            ["id": "channel-1", "type": "future-kind", "name": "Raw name", "members": ["agent-1"]]
        ]
    ], on: task)
    let channel = try XCTUnwrap(vm.channels.first)
    XCTAssertEqual(channel.type, "future-kind"); XCTAssertEqual(channel.kind, .unknown("future-kind"))
    XCTAssertEqual(vm.displayName(for: channel), "Raw name")
    XCTAssertEqual(vm.sortedAgents.count, 1); XCTAssertNil(vm.sortedAgents.first?.dmChannel)
    context.insert(TeamMessage(id: "live", channelId: "channel-1", senderId: "other",
                               senderType: SenderType.agent.wireValue, senderName: "Other", text: "same"))
    try context.save()
    let history: [[String: Any]] = ["one", "two"].map { id in
        ["id": id, "senderId": "other", "senderType": "future-sender", "senderName": "Other",
         "text": "same", "createdAt": "2026-09-07T12:00:00.000Z"]
    }
    try await receivePersistenceFrame([
        "type": "history", "channelId": "channel-1", "hasMore": false, "id": "history", "messages": history
    ], on: task)
    let inserted = try rows().filter { $0.id == "one" || $0.id == "two" }
    XCTAssertEqual(inserted.count, 2, "unknown sender must not enter agent content-key dedup")
    XCTAssertTrue(inserted.allSatisfy { $0.senderType == "future-sender" && $0.typedSenderType == .unknown("future-sender") })
    XCTAssertFalse(vm.isLoadingHistory); XCTAssertFalse(vm.hasMoreHistory)
    XCTAssertEqual(channel.lastMessageText, "same"); XCTAssertEqual(vm.activeMessages.count, 3)
    vm.disconnect()
}
```

The tests deliberately use existing Team matching and missing-row behavior. The new helper does not change it. Last-error success identity assertions accompany B's existing auto-clear tests; no generic save-policy mock is introduced.

- [ ] **Step 6:** Run `kpr444_test team -only-testing:KeeperTests/TeamViewModelTests -only-testing:KeeperTests/TeamSortedAgentsTests -only-testing:KeeperTests/TeamWSMessageTests -only-testing:KeeperTests/TeamMessageBubbleTests -only-testing:KeeperTests/PairingTeardownTests -only-testing:KeeperTests/PersistenceTests`. Expected: all predecessor tests plus 5 new Team tests pass. Audit all 16 fetch and 10 save labels against baseline, including self-left/archived nested selection and resend guard continue versus rejected-send break.

- [ ] **Step 7:** Verify and commit:

```sh
git diff --check
git add ViewModels/TeamViewModel.swift KeeperTests/TeamViewModelTests.swift
git commit -m "fix: report Team persistence failures without changing continuation"
```

### Task 6: Migrate the four direct-view calls as log-only operations

**Files:** Modify `Views/SessionListView.swift:138,206`, `Views/BeekeeperRootView.swift:72-74`.

- [ ] **Step 1:** Apply these complete replacements; keep all surrounding view actions, visibility and selection logic.

```swift
// SessionListView iOS rename, original line 138:
modelContext.saveReporting("view.sessionList.rename.iOS.save")

// SessionListView macOS rename, original line 206:
modelContext.saveReporting("view.sessionList.rename.macOS.save")

// BeekeeperRootView vestigial concierge row cleanup, original lines 72–74:
guard let row = modelContext.fetchOrEmpty(descriptor, "view.conciergeCleanup.fetch").first else { return }
modelContext.delete(row)
modelContext.saveReporting("view.conciergeCleanup.save")
```

Failure/missing first row still returns before delete/save. No VM reference, banner, alert, persistence service or ownership move is added to a view. The second SessionList save is macOS rename, **not workspace removal**.

- [ ] **Step 2:** Run `kpr444_test view-persistence -only-testing:KeeperTests/SessionRowTests -only-testing:KeeperTests/ConciergeViewModelTests -only-testing:KeeperTests/PersistenceTests` and the macOS build command. Expected: all selected tests pass and macOS compiles its rename branch. Source review supplies the simple log-only action proof; no mirror-implementation view tests are required.

- [ ] **Step 3:** Verify and commit:

```sh
git diff --check
git add Views/SessionListView.swift Views/BeekeeperRootView.swift
git commit -m "fix: report persistence errors in direct view actions"
```

## Chunk E — Assigned Loading, Dead UI, Documentation and Configuration Cleanup

### Task 7: Finish bounded cleanup and inspect the existing UI surfaces

**Files:** Modify `Views/Team/HivesGridView.swift:12-36`, `Views/Team/AgentRow.swift:58`, `Models/ConciergeSessionStore.swift:51`, `CLAUDE.md`, `Info.plist`. Team no-op comments already landed in Task 5. `Managers/CapabilityManager.swift` has no final production change.

- [ ] **Step 1:** Replace only the contents of `HivesGridView`'s outer `Group` with this complete conditional. Keep all modifiers, `.task`, `.refreshable`, destination, selection and auth callbacks outside the Group unchanged:

```swift
if !capabilityManager.hives.isEmpty {
    ScrollView {
        LazyVGrid(columns: columns, spacing: KeepurTheme.Spacing.s4) {
            ForEach(capabilityManager.hives, id: \.self) { hive in
                Button {
                    capabilityManager.selectedHive = hive
                    teamViewModel.connectIfPossible()
                    navigateToHive = true
                } label: {
                    HiveCard(name: hive)
                }
                .buttonStyle(.plain)
            }
        }
        .padding()
    }
} else if capabilityManager.isLoading {
    ProgressView()
} else {
    ContentUnavailableView {
        Label("No hives available", systemImage: "hexagon")
    } description: {
        Text("Pull to refresh.")
    }
}
```

There is no manager loading change: `performRefresh` already sets true and defers false, `refresh` coalesces requests, and cached cards stay visible. Preserve the current content region without new copy, spinner overlay, polling or navigation gate.

- [ ] **Step 2:** Delete exactly `KeepurUnreadBadge(count: 0)` from `AgentRow`. Keep its HStack/timestamp, avatar, spacing and typography; do not remove `KeepurUnreadBadge` itself or its tests. Add `import os` to `Models/ConciergeSessionStore.swift`, and replace its one print with:

```swift
Log.chat.warning("Multiple concierge slots returned; using first. count=\(matches.count, privacy: .public)")
```

Keep `if matches.count > 1`, first exact-concierge selection, cache and metadata behavior. The message contains only a static diagnostic and count.

- [ ] **Step 3:** Remove this entire XML block from `Info.plist`, leaving every other key/value untouched:

```xml
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSExceptionDomains</key>
    <dict>
        <key>hive.dodihome.com</key>
        <dict>
            <key>NSExceptionAllowsInsecureHTTPLoads</key>
            <true/>
        </dict>
    </dict>
</dict>
```

Do not remove `ATSApplicationFontsPath`: it is a font key, not an ATS network exception. Do not change host validation or pairing/transport.

- [ ] **Step 4:** Rewrite stale `CLAUDE.md` sections using this exact script from the repository root. It retains the detailed B/C WebSocket/queue/concierge contract block **byte-for-byte**, while replacing incorrect app entry, endpoints, model inventory, tooling/workflow and “upcoming” claims. Read the generated file against actual source before committing.

```sh
python3 - <<'PY'
from pathlib import Path
p = Path('CLAUDE.md')
old = p.read_text()
start = old.index('- Both VM sockets and Chat\'s generic')
end = old.index('\n## Code Conventions', start)
contracts = old[start:end]
preamble = '''# Keepur

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
'''
footer = '''

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
'''
p.write_text(preamble + contracts + footer)
assert contracts in p.read_text()
PY
```

- [ ] **Step 5:** Perform the mandatory rendered UI smoke using this **disposable simulator host**, after Tasks 1–6 and Steps 1–4 above. This is observation scaffolding, not a new app feature, E2E target or production seam. Use fresh simulators; do not pair, enter credentials or invoke microphone/speaker controls. The host replaces normal app startup, uses in-memory SwiftData, retains speech/capability dependencies, and drives private-set connection state through real VMs and fake socket handshakes. The two source backups below are taken **after the assigned edits**, so restoration retains all intended work.

First make backups and copy the existing fake implementations into the app's synchronized `Managers` group under temporary names. These copies have no XCTest dependency; do not import or reference `ChatTestHarness` from the app target:

```sh
export KPR444_SMOKE="$(mktemp -d /tmp/keepur-kpr444-smoke.XXXXXX)"
cp KeepurApp.swift "$KPR444_SMOKE/KeepurApp.swift"
cp Managers/CapabilityManager.swift "$KPR444_SMOKE/CapabilityManager.swift"
python3 - <<'PY'
from pathlib import Path
dest = Path('Managers/KPR444SmokeFakes.swift')
assert not dest.exists()
parts = []
for source in ['KeeperTests/FakeWebSocketTask.swift', 'KeeperTests/FakeCredentialStore.swift']:
    text = Path(source).read_text().replace('@testable import Keepur\n', '')
    text = text.replace('FakeWebSocketTask', 'KPR444SmokeWebSocketTask')
    text = text.replace('FakeCredentialStore', 'KPR444SmokeCredentialStore')
    parts.append(text)
dest.write_text('\n'.join(parts))
# Replace only this private method temporarily; no API/Keychain request runs.
# Its existing refresh coalescing and isLoading ownership still drive the view.
p = Path('Managers/CapabilityManager.swift')
s = p.read_text()
start = s.index('    private func performRefresh() async {')
end = s.index('    private func reconcileSelectedHive()', start)
s = s[:start] + '''    private func performRefresh() async {
        isLoading = true
        defer { isLoading = false }
        try? await Task.sleep(for: .seconds(15))
    }

''' + s[end:]
p.write_text(s)
PY
```

Temporarily replace the whole `KeepurApp.swift` with this complete host (the backup restores its original startup/container logic afterward):

```swift
import Foundation
import SwiftUI
import SwiftData
import Combine

@main
struct KeepurApp: App {
    @StateObject private var smoke = KPR444SmokeModel()
    var body: some Scene {
        WindowGroup {
            KPR444SmokeHost(smoke: smoke)
                .modelContainer(smoke.container)
        }
    }
}

@MainActor
private final class KPR444SmokeSave {
    var fail = false
    func call(_ context: ModelContext) throws {
        if fail { throw NSError(domain: "KPR444Smoke", code: 444) }
        try context.save()
    }
}

@MainActor
private final class KPR444SmokeModel: ObservableObject {
    let container: ModelContainer
    let context: ModelContext
    let capability: CapabilityManager
    let speech: SpeechManager
    let chat: ChatViewModel
    let team: TeamViewModel
    let chatFactory: KPR444SmokeWebSocketTaskFactory
    let teamFactory: KPR444SmokeWebSocketTaskFactory
    private let saveAttempt: KPR444SmokeSave
    private let dm: TeamChannel
    @Published var surface = "Chat"
    @Published var hiveGeneration = 0
    @Published var note = "Disconnected; choose a surface/state"
    let surfaces = ["Chat", "Team root", "Team chat", "Hives empty", "Hives cached"]
    let chatStates = ["idle", "thinking", "tool_starting", "tool_running", "busy", "session_ended", "customState"]
    let teamStates = ["idle", "processing", "error", "stopped", "customState"]

    init() {
        // This runs only in newly created disposable simulators.
        UserDefaults.standard.set(false, forKey: "autoReadAloud")
        UserDefaults.standard.set(false, forKey: "teamAutoReadAloud")
        let schema = Schema([Session.self, Message.self, Workspace.self,
                             TeamChannel.self, TeamMessage.self])
        do {
            container = try ModelContainer(for: schema, configurations: [
                ModelConfiguration(isStoredInMemoryOnly: true)
            ])
        } catch { fatalError("Smoke in-memory container failed: \(error)") }
        let context = container.mainContext
        context.autosaveEnabled = false
        self.context = context
        let capability = CapabilityManager(), speech = SpeechManager()
        let credentials = KPR444SmokeCredentialStore(
            token: "synthetic-smoke-token", deviceId: "smoke-device", deviceName: "Smoke")
        let chatFactory = KPR444SmokeWebSocketTaskFactory()
        let teamFactory = KPR444SmokeWebSocketTaskFactory()
        let saveAttempt = KPR444SmokeSave()
        let chatSocket = BeekeeperSocket(credentials: credentials,
            endpoint: { URL(string: "wss://smoke.invalid")! },
            taskFactory: { chatFactory.make(url: $0) })
        let teamSocket = BeekeeperSocket(credentials: credentials,
            endpoint: { URL(string: "wss://smoke.invalid")! },
            taskFactory: { teamFactory.make(url: $0) })
        let chat = ChatViewModel(socket: chatSocket, credentials: credentials,
            speech: speech, lastErrorAutoClear: .seconds(600),
            saveOperation: { try saveAttempt.call($0) })
        let team = TeamViewModel(socket: teamSocket, credentials: credentials,
            lastErrorAutoClear: .seconds(600), saveOperation: { try saveAttempt.call($0) })
        let dm = TeamChannel(id: "smoke-dm", type: ChannelKind.dm.wireValue,
            name: "Smoke agent", members: ["smoke-agent", "smoke-device"],
            lastMessageText: "A retained preview", lastMessageAt: .now.addingTimeInterval(-120))
        self.capability = capability; self.speech = speech
        self.chatFactory = chatFactory; self.teamFactory = teamFactory
        self.saveAttempt = saveAttempt; self.dm = dm
        self.chat = chat; self.team = team
        context.insert(Session(id: "smoke", path: "/smoke", name: "Smoke chat"))
        context.insert(Message(sessionId: "smoke", text: "A rendered chat message",
                               role: MessageRole.assistant.rawValue))
        context.insert(dm)
        let message = TeamMessage(channelId: dm.id, senderId: "smoke-agent",
            senderType: SenderType.agent.wireValue, senderName: "Smoke agent",
            text: "A rendered Team message")
        context.insert(message)
        do { try context.save() }
        catch { fatalError("Smoke seed save failed: \(error)") }
        capability._setHivesForTesting(["Hive A"])
        team.configure(context: context, capabilityManager: capability)
        team.speechManager = speech // weak in Team; retained above and by Chat.
        team.channels = [dm]; team.activeChannelId = dm.id
        team.activeMessages = [message]; team.hasMoreHistory = false
        chat.configure(context: context) // creates only an injected fake task.
        chat.disconnect()
        chat.currentSessionId = "smoke"; chat.currentPath = "/smoke"
        setChatState("thinking"); setTeamState("idle")
    }

    func show(_ value: String) {
        if value.hasPrefix("Hives") {
            chat.disconnect(); team.disconnect()
            capability._setHivesForTesting(value == "Hives cached" ? ["Hive A", "Hive B"] : [])
            capability.selectedHive = nil
            hiveGeneration += 1
        } else {
            capability._setHivesForTesting(["Hive A"])
        }
        surface = value
    }

    func setChatState(_ raw: String) {
        chat.sessionStatuses["smoke"] = SessionStatus(wire: raw)
        chat.sessionToolNames["smoke"] = "Read"
        note = "Chat state: \(raw)"
    }

    func setTeamState(_ raw: String) {
        let agent = TeamAgentInfo(id: "smoke-agent", name: "Smoke agent", icon: "",
            title: "Fixture", model: "Smoke model", status: AgentStatus(wire: raw),
            tools: ["Read"], schedule: [], channels: ["Hive A"], messagesProcessed: 1,
            lastActivity: "2026-09-07T12:00:00Z")
        team.agents = [agent]; team.sortedAgents = [(agent: agent, dmChannel: dm)]
        note = "Team state: \(raw)"
    }

    private func wait(_ label: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                throw NSError(domain: "KPR444Smoke.\(label)", code: 1)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func connect() async {
        do {
            capability._setHivesForTesting(["Hive A"])
            if chat.connectionState != .connected {
                chat.reconnect()
                try await wait("Chat handshake") { self.chatFactory.latest?.handshakeRequested == true }
                chatFactory.latest?.completeHandshake()
                try await wait("Chat connected") { self.chat.connectionState == .connected }
            }
            if team.connectionState != .connected {
                team.connectIfPossible()
                try await wait("Team handshake") { self.teamFactory.latest?.handshakeRequested == true }
                teamFactory.latest?.completeHandshake()
                try await wait("Team connected") { self.team.connectionState == .connected }
            }
            // Fake transport has no history reply; the fixture displays its seeded history.
            team.isLoadingHistory = false; team.hasMoreHistory = false
            note = "Both real VMs connected through fake handshakes"
        } catch { note = "SMOKE BLOCKED: \(error)" }
    }

    func disconnect() {
        chat.disconnect(); team.disconnect()
        note = "Both real VMs disconnected"
    }

    func failSave() {
        saveAttempt.fail = true
        defer { saveAttempt.fail = false }
        if surface == "Chat" {
            chat.messageText = "Smoke optimistic save"
            chat.sendText()
        } else {
            team.sendMessage(text: "Smoke optimistic save")
        }
        note = "Injected save throws through the real reporting helper"
    }
}

private struct KPR444SmokeHost: View {
    @ObservedObject var smoke: KPR444SmokeModel
    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Menu(smoke.surface) {
                    ForEach(smoke.surfaces, id: \.self) { value in
                        Button(value) { smoke.show(value) }
                    }
                }
                Menu("Chat state") {
                    ForEach(smoke.chatStates, id: \.self) { value in
                        Button(value) { smoke.setChatState(value) }
                    }
                }
                Menu("Team state") {
                    ForEach(smoke.teamStates, id: \.self) { value in
                        Button(value) { smoke.setTeamState(value) }
                    }
                }
            }
            HStack {
                Button("Connect") { Task { await smoke.connect() } }
                Button("Disconnect") { smoke.disconnect() }
                Button("Save error") { smoke.failSave() }
            }
            .disabled(smoke.surface.hasPrefix("Hives"))
            Text(smoke.note).font(.caption)
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    renderedSurface
                    Text("Rendered surface width: \(Int(geometry.size.width)) pt")
                        .font(.caption2)
                }
            }
        }
    }

    @ViewBuilder private var renderedSurface: some View {
        switch smoke.surface {
        case "Chat":
            NavigationStack {
                ChatView(viewModel: smoke.chat, sessionId: "smoke",
                         navigationTitle: "Smoke chat", showsBackButton: false)
            }
        case "Team root":
            TeamRootView(viewModel: smoke.team, capabilityManager: smoke.capability)
        case "Team chat":
            NavigationStack { TeamChatView(viewModel: smoke.team) }
        default:
            NavigationStack {
                HivesGridView(capabilityManager: smoke.capability, teamViewModel: smoke.team)
            }
            .id(smoke.hiveGeneration)
        }
    }
}
```

The standalone **Team chat** surface supplies deterministic access to the real header/info-sheet at narrow size, where `TeamRootView` initially displays its sidebar. Observe the actual root separately for its banner and `AgentRow` avatar/timestamp. This host does not change either view's navigation or sheet implementation. State menus set existing public presentation inputs; persistence errors use the approved throwing save seam. Connection state is never assigned directly. Long error lifetime is fixture-only so screenshots do not race the six-second production timer.

Create fresh narrow/wide devices using these planning-observed installed identifiers (verify them with `xcrun simctl list devicetypes` and `xcrun simctl list runtimes`; substitute only actual installed equivalents if unavailable). Build once with normal simulator signing, install the temporary app on both, and run it:

```sh
export KPR444_SMOKE_NARROW="$(xcrun simctl create KPR444-Smoke-Narrow com.apple.CoreSimulator.SimDeviceType.iPhone-17 com.apple.CoreSimulator.SimRuntime.iOS-26-3)"
export KPR444_SMOKE_WIDE="$(xcrun simctl create KPR444-Smoke-Wide com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB com.apple.CoreSimulator.SimRuntime.iOS-26-3)"
xcrun simctl boot "$KPR444_SMOKE_NARROW"
xcrun simctl bootstatus "$KPR444_SMOKE_NARROW" -b
xcrun simctl boot "$KPR444_SMOKE_WIDE"
xcrun simctl bootstatus "$KPR444_SMOKE_WIDE" -b
set -o pipefail
xcodebuild build -project Keepur.xcodeproj -scheme Keepur \
  -destination "platform=iOS Simulator,id=$KPR444_SMOKE_NARROW" \
  -derivedDataPath "$KPR444_SMOKE/dd" 2>&1 | tee "$KPR444_SMOKE/build.log"
export KPR444_SMOKE_APP="$KPR444_SMOKE/dd/Build/Products/Debug-iphonesimulator/Keepur.app"
export KPR444_SMOKE_BUNDLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$KPR444_SMOKE_APP/Info.plist")"
xcrun simctl install "$KPR444_SMOKE_NARROW" "$KPR444_SMOKE_APP"
xcrun simctl install "$KPR444_SMOKE_WIDE" "$KPR444_SMOKE_APP"
xcrun simctl launch "$KPR444_SMOKE_NARROW" "$KPR444_SMOKE_BUNDLE"
xcrun simctl launch "$KPR444_SMOKE_WIDE" "$KPR444_SMOKE_BUNDLE"
open -a Simulator
kpr444_smoke_capture() {
  xcrun simctl io "$1" screenshot "$KPR444_SMOKE/$2.png"
}
```

Expected build: exit 0 and `** BUILD SUCCEEDED **`. If boot/build/render fails, retain its concrete failure and resolve the harness or report a blocker; do not replace rendered evidence with `.body` construction. In Simulator choose each named device window and keep it in portrait. For **each** device complete the following observations and record the displayed surface width (expected iPhone 17: 402 pt; iPad Pro 13: 1032 pt, verify actual values):

| Surface/actions | Required visible observation |
|---|---|
| Choose **Hives empty**, immediately capture, then capture after the 15-second refresh completes | Spinner inside the existing content area, then exactly “No hives available” / “Pull to refresh.”. No artificial loading copy. |
| Choose **Hives cached**, immediately capture before 15 seconds and again after completion | Both Hive A/Hive B cards remain visible throughout loading. Do not tap a card; selectedHive stays nil. The temporary refresh returns without HTTP/Keychain access. |
| Choose **Chat**, **Connect**, then each Chat state from its menu | idle/terminal have no active indicator; thinking, both tool states, busy and customState retain exact header/copy and Cancel affordance; customState is active with raw text. Message/query, timestamp and input render with no clipping at either width. |
| Chat thinking → tap the actual **Cancel** button | Existing action remains tappable, no crash. Inspect fake `sentTexts` in Xcode's debugger if needed; it must contain the existing cancel frame. Do not infer server completion from this fake transport. |
| Chat → **Disconnect** → **Save error** | Exact persistence banner with **Retry**, message/input layout remains visible. Tap banner text to dismiss, repeat Save error, then tap the banner's real Retry: connection banner updates via the VM to connecting, with persistence copy retained. Press fixture **Connect** to complete the pending fake handshake. |
| **Team root**, each Team state | Sidebar avatar overlay is success/warning/danger/danger/muted for idle/processing/error/stopped/customState; preview and timestamp remain and no zero badge appears. At wide size observe the root's detail if visible; use Team chat for deterministic narrow detail access. |
| **Team chat**, each Team state; tap the actual info button, inspect, dismiss before changing state | Actual Team header text/activity and real `AgentDetailSheet` pill: Idle/success, Processing/warning, Error/danger, Stopped/danger, CustomState/muted. Processing alone is active; idle header nil, other header values working/error/stopped/customState. Matching DM members make the info action available and retained speech makes its sheet nonempty. |
| **Team root** → **Disconnect** → **Save error**, dismiss/repeat, tap its actual **Retry**, then fixture Connect | The root owns exactly one persistence banner with the same copy and state-dependent Retry behavior. Inspect wrapping, controls and sidebar/detail layout at both widths. |

Capture each named observation with the helper, for example `kpr444_smoke_capture "$KPR444_SMOKE_NARROW" narrow-chat-customState` and `kpr444_smoke_capture "$KPR444_SMOKE_WIDE" wide-team-processing-sheet`. Use corresponding unique names for every matrix row/state and width; retain PNGs with a short observation record under `$KPR444_SMOKE`. Actually open/review screenshots before recording a pass. The temporary host's controls are outside the product views; no screenshot-only product UI or new behavior is to be committed.

After screenshots/observations are saved, terminate both temporary apps and restore **all** scaffolding before Step 6, any regression check or commit. Run this cleanup even if smoke is blocked (the logs/screenshots/backups remain outside the repository):

```sh
xcrun simctl terminate "$KPR444_SMOKE_NARROW" "$KPR444_SMOKE_BUNDLE"
xcrun simctl terminate "$KPR444_SMOKE_WIDE" "$KPR444_SMOKE_BUNDLE"
cp "$KPR444_SMOKE/KeepurApp.swift" KeepurApp.swift
cp "$KPR444_SMOKE/CapabilityManager.swift" Managers/CapabilityManager.swift
rm Managers/KPR444SmokeFakes.swift
cmp KeepurApp.swift "$KPR444_SMOKE/KeepurApp.swift"
cmp Managers/CapabilityManager.swift "$KPR444_SMOKE/CapabilityManager.swift"
xcrun simctl shutdown "$KPR444_SMOKE_NARROW"
xcrun simctl shutdown "$KPR444_SMOKE_WIDE"
xcrun simctl delete "$KPR444_SMOKE_NARROW"
xcrun simctl delete "$KPR444_SMOKE_WIDE"
git diff -- KeepurApp.swift Managers/CapabilityManager.swift
rg -n 'KPR444Smoke|KPR444-Smoke|synthetic-smoke-token|smoke\.invalid' KeepurApp.swift Managers Views --glob '*.swift'
git status --short
```

Expected: both `cmp` commands exit 0, startup/manager diff empty, temporary-file search has zero matches/exit 1, and no temporary source appears in git status/staging. Delete only the two returned smoke device IDs. The clean-source Step 6 tests/macOS build and Task 8 final iOS regression, not this temporary-host build, provide implementation verification. Do not count any smoke code as new permanent test methods.

- [ ] **Step 6:** Run static checks, selected UI/codec tests and macOS build:

```sh
plutil -lint Info.plist
rg -n 'NSAppTransportSecurity|NSExceptionDomains|hive\.dodihome\.com' Info.plist
rg -n 'KeepurUnreadBadge\(count: 0\)' Views/Team/AgentRow.swift
rg -n 'print\(' Managers ViewModels Models --glob '*.swift'
git diff -- Managers/CapabilityManager.swift
```

Expected: plist `OK`; the three rg searches have zero matches/exit 1; manager diff empty. Run `kpr444_test cleanup -only-testing:KeeperTests/TypedStateTests -only-testing:KeeperTests/ChatHeaderMappingTests -only-testing:KeeperTests/AgentRowTests -only-testing:KeeperTests/AgentDetailSheetTests -only-testing:KeeperTests/ConciergeViewModelTests -only-testing:KeeperTests/TeamWSMessageTests`, then the macOS build. Expected: all selected tests and build pass. Preserve CapabilityManager tests for complete CI; its loading logic was not changed.

- [ ] **Step 7:** Review the documentation against `Views/ContentView.swift`, `Managers/BeekeeperConfig.swift`, `Managers/BeekeeperSocket.swift`, `KeepurApp.swift`, project/workflow and B/C canon. Then commit only final assigned files:

```sh
git diff --check
git add Views/Team/HivesGridView.swift Views/Team/AgentRow.swift Models/ConciergeSessionStore.swift CLAUDE.md Info.plist
git commit -m "chore: finish loading and documentation cleanup"
```

## Chunk F — Full Verification and Final Reviewed-Head Evidence

### Task 8: Audit scope, run required checks and hand off exact evidence

**Files:** Read the complete implementation diff and existing `.github/workflows/test.yml`; no new production files. Write lane evidence through the existing delivery workflow after required review. Do not commit result bundles, credentials or temporary smoke files.

**Gate ownership and order:** The implementer executes Tasks 1–7 with their meaningful verification, supplies the post-implementation audit below, and hands off at the **implementation-reviewing** checkpoint. The delivery owner runs the implementation-review/fix loop, then the pre-PR test/verify gates, opens the child PR, and completes the GitHub CI/child-PR review gates. Task 8 is that downstream checklist; an unopened PR cannot provide CI and CI is not a prerequisite to opening the PR that triggers it. Full unexcluded final-reviewed-head CI is mandatory before **ready-to-merge-child**. Targeted checks run during implementation remain valid evidence of those individual changes, not completion of downstream gates.

- [ ] **Step 1:** Reconcile all **62 original calls**. The inventory in Tasks 4–6 is exhaustive: Chat 15 fetch + 17 save; Team 16 fetch + 10 save; views 1 fetch + 3 save. Each label must map to the listed original statement and preserve nesting/continuation. Inspect actual changed code, not only grep counts. The source now contains three legitimate direct live operation defaults (two saves, one Chat fetch), plus raw operations inside the helper; all actual call sites invoke reporting. No `.fetch`/`.save` operation may hide in a renamed swallow wrapper.

```sh
rg -n 'try\? .*\.(save|fetch)\(' --glob '*.swift' --glob '!KeeperTests/**' .
rg -n -U 'try[?!]\s*\n?[^\n]*\.(save|fetch)\(' Managers Models ViewModels Views --glob '*.swift'
rg -n '\.(fetch|save)\(' Managers Models ViewModels Views --glob '*.swift'
rg -n 'print\(' Managers ViewModels Models --glob '*.swift'
rg -n 'save\(context,|fetchOrEmpty\(|saveReporting\(' ViewModels Views --glob '*.swift'
```

Expected: the first, second and fourth searches have no production matches. Read **every** direct operation from the third search; only the approved helper/live closure defaults are allowed. Confirm one static label per original site, not interpolated IDs or user text. Compare every failure branch to the inventory, especially Chat 490/534/806, Team 420/570/777/794, and view cleanup. Review logger privacy and exact save-banner copy.

- [ ] **Step 2:** Verify typing and schema boundaries, wire fixtures and exclusions:

```sh
rg -n 'sessionStatuses|statusFor\(|mapSessionStatus|mapAgentStatus|\.role|senderType|\.mode|\.type ==|\.type !=|statusTint|statusDisplay' Models ViewModels Views --glob '*.swift'
git diff fe6907b60933869fff46cdcba260010f53e2a235 -- Models KeepurApp.swift Keepur.xcodeproj/project.pbxproj .github/workflows/test.yml
plutil -lint Info.plist
git diff --check
```

Expected: no runtime domain String comparisons except justified codec/storage/predicate boundaries and unrelated identity/auth/command values; no copied activity arrays or agent switches. Persisted String fields/attributes and five-model schema unchanged. No container recovery/transport/auth/history-policy change, no serverId, MessageStore, stored enum, transformable, UI target or new CI skip. No file migration or project membership edits. Static Info.plist comparison must show only the deleted `NSAppTransportSecurity` value; all microphone/speech/audio/font values preserved.

- [ ] **Step 3:** Retain the baseline test identities and assertions. Run this identity audit; it must report zero removed test methods. It is a guardrail, not a substitute for semantic assertion review:

```sh
python3 - <<'PY'
import re, subprocess
from pathlib import Path
base = 'fe6907b60933869fff46cdcba260010f53e2a235'
paths = subprocess.check_output(['git', 'ls-tree', '-r', '--name-only', base, 'KeeperTests'], text=True).splitlines()
missing = []
for path in paths:
    if not path.endswith('.swift'):
        continue
    old = subprocess.check_output(['git', 'show', f'{base}:{path}'], text=True)
    now = Path(path).read_text() if Path(path).exists() else ''
    before = set(re.findall(r'\bfunc\s+(test\w+)\s*\(', old))
    after = set(re.findall(r'\bfunc\s+(test\w+)\s*\(', now))
    missing.extend(f'{path}:{name}' for name in sorted(before - after))
assert not missing, '\n'.join(missing)
print('No baseline test methods removed')
PY
```

Review all existing-test edits to confirm assertions remain meaningful and event/FIFO/lifetime ordering is unchanged. Only the approved Chat unknown-activity expectation changes behavior. Unit decode wire strings, malformed-row tests, the Team command-list request/no-op cases, attachment bytes and C post-handler/lazy-speech assertions remain intact. There are 23 new test methods in this draft (4 typed, 5 helper, 9 Chat, 5 Team); expected full count is at least **298** if baseline 275 discovery remains unchanged, and local broad count at least **286** with the same 12-test KPR-446 exclusion. Any discrepancy must be explained with actual discovery, not accepted solely because the command exited zero.

- [ ] **Step 4:** Run the required Unit and Integration commands, broad local regression command and macOS build from the Testing Contract. Avoid repeating already-passing focused runs unless code changed; the final broad local regression/macOS pass must cover the actual final code. Preserve raw `.log` and `.xcresult` paths, including the timestamped `/tmp/keepur-kpr444-macos-<stamp>.log` created by `kpr444_macos`; require its pipeline exit 0 and `** BUILD SUCCEEDED **`. Read summaries:

```sh
xcrun xcresulttool get test-results summary --path /tmp/keepur-kpr444-REPLACE-WITH-ACTUAL-RESULT.xcresult
```

Replace that last path with the exact result emitted by the command; it is a lookup instruction, not an executable placeholder to leave in evidence. Record actual selected classes/counts, failures and Xcode/runtime. If KPR-447/448 appears, document exact failing assertion/log and route by existing authority; do not silently loosen or remove coverage. After the implementation-reviewing checkpoint and clean implementation-review/fix loop, the delivery owner performs the existing pre-PR compliance → tests → verification workflow for the D delta. Missing final checks block downstream readiness, not the earlier audit handoff.

- [ ] **Step 5:** After clean implementation review and child PR creation by the delivery lifecycle, verify the entire GitHub suite **at the final reviewed head**. Do not claim ready-to-merge based on the local exclusion or an earlier commit's green check. From the implementation branch run:

```sh
export KPR444_HEAD="$(git rev-parse HEAD)"
gh pr view --repo keepur/keepur-ios --json number,url,headRefOid,baseRefName,statusCheckRollup
gh run list --repo keepur/keepur-ios --workflow test.yml --event pull_request --commit "$KPR444_HEAD" --json databaseId,headSha,status,conclusion,url --limit 20
```

The PR must target `epic-kpr-441`, its `headRefOid` must equal `KPR444_HEAD`, and the reviewer must have reviewed that same head. Resolve the returned **Tests** workflow run ID for that head and inspect it:

```sh
gh run view RUN_ID --repo keepur/keepur-ios --json headSha,event,status,conclusion,jobs,url
gh run view RUN_ID --repo keepur/keepur-ios --log
```

Substitute the actual returned numeric run ID. Expected: `headSha == KPR444_HEAD`, event `pull_request`, completed/success, **Unit tests (iOS Simulator)** success, full KeeperTests discovery with no `CapabilityManagerTests` or other skip. Inspect workflow/log command and test totals, not only the green overall icon. If a run is pending, use bounded polling/wait with meaningful updates; if absent, use the normal child-PR workflow trigger/re-run process, not a CI rewrite. A run on a newer merge simulation still must attest this exact PR head and base; read `headSha`/PR metadata and record the relation.

Re-read `git rev-parse HEAD` and PR `headRefOid` after checks. **Any subsequent commit**—including plan, docs, evidence or review fix—requires rechecking review/head and full unexcluded CI at the new head; don't waive this for docs-only commits. Keep evidence off the source branch unless deliberately triggering that new-head cycle. Never merge the epic into main; Gate 2 is operator-owned.

- [ ] **Step 6:** Handoff the concrete evidence: reviewed head and base, final CI run/job URL and full counts, local count/exclusion (explicit), macOS build/log, smoke observations/screenshots, 62-site branch audit, no-schema/wire-change audit, assertion-retention audit, exact static checks and any tracked limitation. The implementer may hand off its post-implementation audit at implementation-reviewing before the PR exists. The delivery owner may declare ready-to-merge-child only when required code/tests/static/UI/build evidence and full unexcluded final-reviewed-head CI all pass. No product question is currently open; any new product/architecture ambiguity demotes to the spec lane rather than being resolved by expanding D.
