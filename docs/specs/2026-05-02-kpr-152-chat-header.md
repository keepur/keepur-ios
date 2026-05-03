# KPR-152 — design v2: Chat header redesign (avatar + status line + circular toolbar)

**Date:** 2026-05-02
**Epic:** [KPR-142 design v2](https://linear.app/keepur/issue/KPR-142)
**Layer:** 3 (per-screen consumption)
**Depends on:** KPR-146 (foundation composites — `KeepurChatHeader`), KPR-147 (TabBar root + chat tab-bar visibility wiring)

## Problem

Both chat surfaces — `Views/ChatView.swift` (Claude Code sessions) and `Views/Team/TeamChatView.swift` (agent DMs) — currently render their header via SwiftUI's stock `navigationTitle(...)` + `.inline` display mode + a system back chevron, with a small `.toolbar` cluster of speaker / settings / info buttons in the trailing slot. This collapses to a flat string title with no status context and toolbar buttons that float in default-shape space — not the "circular" branded chrome the design v2 mockups call for. The mockups put the agent / session name in a centered title block with a status line beneath ("● working · 2m ago"), a circular back chevron at leading, and circular trailing actions for mute and info.

The `KeepurChatHeader` composite already exists from KPR-146; this ticket wires it into the two chat surfaces. The work is two near-identical edits but each chat has its own status semantics and its own info action — they don't share a call site.

## Solution

Replace the `navigationTitle(...)` + system back + ad-hoc toolbar in each chat with `KeepurChatHeader`, embedded in a `ToolbarItem(placement: .principal)` (iOS) so it occupies the centered title slot, and `.navigationBarBackButtonHidden(true)` on iPhone so the system back chevron doesn't compete with `KeepurChatHeader`'s custom back button. macOS uses a different placement (`.automatic`) since macOS toolbars don't have a principal slot the same way and don't render a system back chevron at all in a `NavigationSplitView` detail.

Both surfaces extract their existing speaker button into `KeepurChatHeader.trailingActions`. `TeamChatView` additionally extracts its info button. `ChatView` additionally extracts its iOS settings button. Behavior of those buttons (toggling autoReadAloud, opening sheets, etc.) is unchanged — they are relocated, not reimplemented. Tab-bar visibility wiring from KPR-147 (parent's `isViewingChat` for TeamRootView; `selectedSessionId == nil` for SessionListView's iOSBody) is **not touched** — those drivers are external to the chat view's own toolbar surface.

## Key Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Toolbar placement (iOS) | `ToolbarItem(placement: .principal)` | Principal is the centered slot under the navigation bar; `KeepurChatHeader` is designed to occupy the full title line including its own leading back chevron and trailing action stack |
| Toolbar placement (macOS) | `ToolbarItem(placement: .automatic)` | macOS doesn't expose `.principal` consistently; `.automatic` lets AppKit place it sensibly. macOS doesn't render a competing system back chevron in `NavigationSplitView` detail mode, so there's no collision |
| iOS back-button hiding | `.navigationBarBackButtonHidden(true)` on both ChatView and TeamChatView (iOS only) | Required by `KeepurChatHeader`'s docs. Without it, iOS shows the system chevron alongside the header's circular chevron |
| `onBack` wiring | `@Environment(\.dismiss) private var dismiss` per view, passed as `onBack: { dismiss() }` (iOS only); `nil` on macOS | `dismiss` works for ChatView (pushed into NavigationStack from SessionListView's iOSBody) and TeamChatView (pushed into NavigationSplitView detail). On macOS, neither view has a back affordance today and a back button in a SplitView detail is conceptually wrong — pass `nil` so `KeepurChatHeader` skips rendering the chevron |
| Keep `navigationTitle(...)` as accessibility label | Yes — leave `.navigationTitle(...)` calls in place but set the title-display content via the principal toolbar item | The string title is still consumed by VoiceOver, the back-stack title hint, and the iOS large-title fallback; removing it would regress accessibility. Inline display mode means the visible title comes from the principal item, not the nav bar string |
| ChatView status line content | `statusText`: human-readable form of `viewModel.statusFor(sessionId)` (e.g. `"thinking"` / `"busy"` / `"running tool"` / nil for `"idle"`); `statusDate`: most recent message's `timestamp`; `isStatusActive`: true when status is non-idle | Mirrors the existing `StatusIndicator` semantics in the message list, surfacing the same signal in the header. Idle → no status line, just the title |
| TeamChatView status line content | `statusText`: human-readable `activeAgent?.status` mapped (e.g. `"processing"` → `"working"`, `"idle"` → nil, `"error"` → `"error"`, `"stopped"` → `"stopped"`); `statusDate`: active channel's `lastMessageAt`; `isStatusActive`: true when status is `"processing"` | Mirrors the data already shown in the agent detail half-sheet. For non-DM channels (no `activeAgent`), status line is omitted — title only |
| Status text mapping helper | Inline private computed properties on each view (`headerStatusText`, `headerStatusDate`, `headerIsStatusActive`) | Two views, two data sources — extracting a shared helper would over-abstract; inline keeps the call site readable |
| Trailing actions order | speaker → info (TeamChatView); speaker → settings (ChatView, iOS only) | Matches existing toolbar order; `KeepurChatHeader` renders left-to-right |
| Speaker symbol selection | Reuse the existing tri-state logic (`stop.circle.fill` / `speaker.wave.2.fill` / `speaker.slash`) inside the action's `symbol` parameter | The dynamic symbol drives the existing visual state; KeepurChatHeader's `Action` takes a static `symbol` string but it can be re-instantiated each render so the symbol updates with state |
| Speaker symbol color | Lost in migration | `KeepurChatHeader` renders all trailing actions in `fgPrimary` per its design (uniform circular chrome). The existing color-coded speaker (danger when speaking, honey when auto-read) becomes uniform — semantic state still readable via the symbol shape change. Acceptable per backlog: "existing speaker button relocated/restyled" |
| Tab-bar visibility wiring | Unchanged — do not touch | KPR-147 follow-up #68 deliberately moved tab-bar control to the parent (TeamRootView's `isViewingChat`, SessionListView's `selectedSessionId == nil`). The chat view's `.toolbar` block contains only the principal item; it does not own tab-bar state |
| Sheet wiring | Unchanged — `.sheet(...)` modifiers stay attached to the chat view bodies | Sheet presentation is orthogonal to header chrome; rewiring sheets is out of scope |

## Visual Spec

### ChatView (Claude Code sessions)

```
┌────────────────────────────────────────────────────────────────┐
│  ◐  ←  ┌──────────────────────────┐   ⚇ ⚙   ◑                  │  ← principal toolbar item
│        │  acquire-cursor           │                            │
│        │  ● thinking · 2m ago      │                            │
│        └──────────────────────────┘                             │
├────────────────────────────────────────────────────────────────┤
│                                                                 │
│  (message list — unchanged)                                     │
│                                                                 │
└────────────────────────────────────────────────────────────────┘
```

- **Title:** `session.displayName` (existing `navigationTitle` source)
- **Status line:**
  - `viewModel.statusFor(sessionId) == "idle"` → no status line
  - `"thinking"` → "thinking" + active dot + last-message timestamp
  - `"tool_running"` / `"tool_starting"` → "running tool" + active dot
  - `"busy"` → "server busy" + active dot
- **Trailing:**
  - speaker (existing tri-state symbol)
  - settings (iOS only; existing behavior)

### TeamChatView (agent DMs)

```
┌────────────────────────────────────────────────────────────────┐
│  ◐  ←  ┌──────────────────────────┐   ⚇ ⓘ                       │
│        │  Cursor                   │                            │
│        │  ● working · 30s ago      │                            │
│        └──────────────────────────┘                             │
├────────────────────────────────────────────────────────────────┤
│  (message list — unchanged)                                     │
└────────────────────────────────────────────────────────────────┘
```

- **Title:** `viewModel.displayName(for: channel)` (existing `channelTitle` source)
- **Status line (DM channels only):**
  - `activeAgent?.status == "processing"` → "working" + active dot + `channel.lastMessageAt` (relative)
  - `"idle"` → no status text, but `channel.lastMessageAt` if present
  - `"error"` → "error" + inactive dot
  - `"stopped"` → "stopped" + inactive dot
- **Status line (non-DM / no active agent):** title only
- **Trailing:**
  - speaker (when `viewModel.speechManager != nil`)
  - info (when `isDMWithAgent` — opens existing `showAgentDetail` sheet)

## Status Mapping

### ChatView — `viewModel.statusFor(sessionId)` → header

| Raw status | `statusText` | `isStatusActive` |
|---|---|---|
| `"idle"` | `nil` | `false` |
| `"thinking"` | `"thinking"` | `true` |
| `"tool_running"` | `"running tool"` | `true` |
| `"tool_starting"` | `"starting tool"` | `true` |
| `"busy"` | `"server busy"` | `true` |
| anything else | raw value | `false` |

`statusDate`: `messages.last?.timestamp` (already computed in view).

### TeamChatView — `activeAgent?.status` → header

| Raw status | `statusText` | `isStatusActive` |
|---|---|---|
| `"idle"` or `nil` | `nil` | `false` |
| `"processing"` | `"working"` | `true` |
| `"error"` | `"error"` | `false` |
| `"stopped"` | `"stopped"` | `false` |
| anything else | raw value | `false` |

`statusDate`: `viewModel.channels.first(where: { $0.id == viewModel.activeChannelId })?.lastMessageAt`.

## Implementation Sketch

### ChatView body changes

```swift
@Environment(\.dismiss) private var dismiss

// existing private properties + body unchanged through `.toolbar { }`

.navigationTitle(navigationTitle)
#if os(iOS)
.navigationBarTitleDisplayMode(.inline)
.navigationBarBackButtonHidden(true)
#endif
.toolbar {
    #if os(iOS)
    ToolbarItem(placement: .principal) {
        chatHeader
    }
    #else
    ToolbarItem(placement: .automatic) {
        chatHeader
    }
    #endif
}
// rest of modifiers unchanged

private var chatHeader: KeepurChatHeader {
    KeepurChatHeader(
        title: navigationTitle,
        statusText: headerStatusText,
        statusDate: headerStatusDate,
        isStatusActive: headerIsStatusActive,
        onBack: backAction,
        trailingActions: headerTrailingActions
    )
}

private var headerStatusText: String? { /* mapping table */ }
private var headerStatusDate: Date? { messages.last?.timestamp }
private var headerIsStatusActive: Bool { /* mapping table */ }

private var backAction: (() -> Void)? {
    #if os(iOS)
    return { dismiss() }
    #else
    return nil
    #endif
}

private var headerTrailingActions: [KeepurChatHeader.Action] {
    var actions: [KeepurChatHeader.Action] = [
        .init(symbol: speakerSymbol) {
            if viewModel.speechManager.isSpeaking {
                viewModel.speechManager.stopSpeaking()
            } else {
                autoReadAloud.toggle()
            }
        }
    ]
    #if os(iOS)
    actions.append(.init(symbol: KeepurTheme.Symbol.settings) { showSettings = true })
    #endif
    return actions
}

private var speakerSymbol: String {
    if viewModel.speechManager.isSpeaking { return "stop.circle.fill" }
    return autoReadAloud ? "speaker.wave.2.fill" : "speaker.slash"
}
```

### TeamChatView body changes

```swift
@Environment(\.dismiss) private var dismiss

// existing properties unchanged

.navigationTitle(channelTitle)
#if os(iOS)
.navigationBarTitleDisplayMode(.inline)
.navigationBarBackButtonHidden(true)
#endif
.toolbar {
    #if os(iOS)
    ToolbarItem(placement: .principal) { chatHeader }
    #else
    ToolbarItem(placement: .automatic) { chatHeader }
    #endif
}

private var chatHeader: KeepurChatHeader {
    KeepurChatHeader(
        title: channelTitle,
        statusText: headerStatusText,
        statusDate: headerStatusDate,
        isStatusActive: headerIsStatusActive,
        onBack: backAction,
        trailingActions: headerTrailingActions
    )
}

private var activeChannel: TeamChannel? {
    guard let id = viewModel.activeChannelId else { return nil }
    return viewModel.channels.first(where: { $0.id == id })
}

private var headerStatusText: String? { /* mapping table */ }
private var headerStatusDate: Date? { activeChannel?.lastMessageAt }
private var headerIsStatusActive: Bool { activeAgent?.status == "processing" }

private var backAction: (() -> Void)? {
    #if os(iOS)
    return { dismiss() }
    #else
    return nil
    #endif
}

private var headerTrailingActions: [KeepurChatHeader.Action] {
    var actions: [KeepurChatHeader.Action] = []
    if let speech = viewModel.speechManager {
        actions.append(.init(symbol: speakerSymbol(speech)) {
            if speech.isSpeaking { speech.stopSpeaking() } else { autoReadAloud.toggle() }
        })
    }
    if isDMWithAgent {
        actions.append(.init(symbol: "info.circle") { showAgentDetail = true })
    }
    return actions
}

private func speakerSymbol(_ speech: SpeechManager) -> String {
    if speech.isSpeaking { return "stop.circle.fill" }
    return autoReadAloud ? "speaker.wave.2.fill" : "speaker.slash"
}
```

## Smoke Test Scope

Both `ChatView` and `TeamChatView` depend on `@StateObject`-managed view models, Keychain, and SwiftData — full-body smoke tests would require an in-memory `ModelContainer` and a stubbed `WebSocketManager`, which is over-engineering for header chrome.

Per the constraint "don't smoke-test full View bodies depending on @StateObject/Keychain", this ticket adds **two tightly-scoped helper tests** in a new `KeeperTests/ChatHeaderMappingTests.swift`:

| Test | What it asserts |
|---|---|
| `testChatViewStatusMapping` | Pure-function mapping `String -> (String?, Bool)` for the ChatView status states. The mapping table is implemented as a free `chatViewHeaderStatus(for:)` helper (or a static method on `ChatView`) so it's testable without instantiating the view |
| `testTeamChatViewAgentStatusMapping` | Same shape, for the TeamChatView mapping |

The mapping helpers live in the view files (`fileprivate` or `internal`); to test them they must be `internal` (default access). Acceptable — these are pure value-mapping functions with no dependencies.

`KeepurChatHeader` itself is already exercised by `KeeperTests/KeepurFoundationCompositesTests.swift` from KPR-146; this ticket does not duplicate that coverage.

## Non-Goals (Out of Scope)

- **Mute toggle behavior:** existing speaker button is relocated/restyled, not redesigned. The dynamic tri-state symbol (`stop.circle.fill` / `speaker.wave.2.fill` / `speaker.slash`) and its tap behavior are preserved. Color coding is dropped because `KeepurChatHeader` uses uniform `fgPrimary` for trailing actions
- **Tab-bar visibility:** wired by parents (KPR-147 follow-up #68). This ticket must not introduce tab-bar modifiers on the chat views themselves
- **MessageBubble / message list redesign:** scrollable content area is unchanged
- **StatusIndicator inline indicator:** still rendered inside the message list — header status line is additive, not a replacement
- **Sheet presentation flows:** ToolApprovalView, SettingsView, AgentDetailSheet sheets stay attached to chat views with unchanged triggers
- **macOS back affordance:** macOS doesn't get a back chevron (NavigationSplitView semantics — there's no back to go to in a detail pane)
- **Server-side state:** no protocol changes; consumes existing `sessionStatuses` and `TeamAgentInfo.status`

## Risks

| Risk | Mitigation |
|---|---|
| iOS principal slot might clip on narrow iPhones if title + status + 2 actions overflow | `KeepurChatHeader` uses `.lineLimit(1).truncationMode(.tail)` on the title and `frame(maxWidth: .infinity)` on the title block — overflow-tolerant by design |
| `.navigationBarBackButtonHidden(true)` could break existing back-swipe gesture on iOS | iOS preserves the edge swipe-to-go-back gesture independent of the visible chevron — known SwiftUI behavior. No mitigation needed; verified during build |
| Speaker symbol color loss might confuse users mid-speech | The shape change (`stop.circle.fill` vs `speaker.wave.2.fill`) carries the state. Acceptable trade-off per backlog scope |
| macOS `.automatic` placement might land in an unexpected toolbar position | If macOS placement looks wrong during build verification, fall back to `.navigation` or `.principal` per platform observation. macOS toolbar inspection happens in step 6 |
| Sheet re-entry from header info button breaks existing `.onChange(of: viewModel.activeChannelId)` reset | Existing `.sheet(isPresented: $showAgentDetail)` and `onChange` reset are unmodified — header just triggers the same `showAgentDetail = true` |

## Open Questions

None. Backlog scope is precise, `KeepurChatHeader`'s API is stable from KPR-146, both data sources (`statusFor`, `activeAgent.status`, `channel.lastMessageAt`, `messages.last?.timestamp`) already exist in the view models and SwiftData models.

## Files Touched

- `Views/ChatView.swift` (modify — replace inline title + toolbar)
- `Views/Team/TeamChatView.swift` (modify — replace inline title + toolbar)
- `KeeperTests/ChatHeaderMappingTests.swift` (new — pure-function mapping tests)
- `Keepur.xcodeproj/project.pbxproj` (wire new test file into both test targets)

## Dependencies / Sequencing

- **Blocks:** none (terminal layer-3 ticket on this surface)
- **Blocked by:** KPR-146 (foundation composites — provides `KeepurChatHeader`), KPR-147 (TabBar root + tab-bar visibility wiring — must not be regressed)
- Can run in parallel with other Layer 3 tickets that touch different files (KPR-148/150/151/153/154/155)

## Human Signoff

Pre-approved per durable user delegation (KPR-142 design v2 epic — mockups already approve component intent; user explicit: "as long as it more or less looks like the mockup, I don't care beyond that"). Recorded in epic-orchestrator memory.
