# KPR-153 — design v2: Chat error message bubble variant

**Date:** 2026-05-02
**Epic:** [KPR-142 design v2](https://linear.app/keepur/issue/KPR-142)
**Layer:** 3 (per-screen consumption)
**Depends on:** none (foundation tokens already exist; no atom/composite needed)

## Problem

The design v2 mockup adds a distinct **error bubble** to the chat surface — a card with a thin red border, a light red tint, an "ERROR" eyebrow, monospaced error text, and an inline "Retry" button. Today errors do not have a dedicated bubble: server-side `error` WebSocket frames are flattened into a `role: "system"` `Message` row whose text is prefixed `"Error: "`, and they render through `MessageBubble.systemBubble` as small centered grey caption text. There's no visual distinction between "Session cleared" and "Auth failed — token rejected", and there's no retry affordance.

This ticket introduces the visual variant. Wiring real retry behavior and a clean error data flow are described as **explicit in-scope** below — without them the bubble has nothing to render and no button to wire.

## Central open question — answered

**Q: Where do error messages currently come from?**

**A: They don't exist as a distinct role.** The `Message` SwiftData model declares `role: String  // "user", "assistant", "system", "tool"` (`Models/Message.swift:9`). Inside `ChatViewModel.handleIncoming` the `.error` WS case does:

```swift
case .error(let message, let sessionId):
    if sessionId == nil && isBrowsePending {
        isBrowsePending = false
        browseError = message
    }
    let targetSessionId = sessionId ?? currentSessionId
    if let targetSessionId {
        let msg = Message(sessionId: targetSessionId, text: "Error: \(message)", role: "system")
        context.insert(msg)
        try? context.save()
    }
```

So today an in-chat error is **a `system` Message with `"Error: "`-prefixed text**. There is no `role: "error"` anywhere in the codebase (`grep -rn 'role.*error\|"error"' --include='*.swift'` returns hits only in WebSocket protocol enums — `Models/WSMessage.swift:154`, `Models/TeamWSMessage.swift:228`, the agent status colors `AgentRow.swift:12`, `AgentDetailSheet.swift:12` — none refer to a `Message` row's role).

There is also no retry path. `ChatViewModel.pendingMessages` is a queue of *outgoing* messages waiting on session idle; once dispatched, a failure produces only the system-bubble error row and the original user message stays where it was. The only "retry" verbs in the codebase are `TeamWebSocketManager.retryConnect` (transport-level reconnect) and `WorkspacePickerView`'s browse retry button — neither retries a chat message.

**Implication for sizing:** this ticket can't just restyle a bubble — there's no row to restyle. Three things must land together for the variant to be reachable:

1. Add `"error"` as a recognized `Message.role` value (data model documentation only — `role` is `String`, no enum to extend).
2. Update `ChatViewModel.handleIncoming` `.error` branch to insert `role: "error"` instead of `role: "system"` with the `"Error: "` prefix stripped (text becomes the raw server message).
3. Capture enough context to retry meaningfully. Minimum viable: persist the **failing user message id** on the error row so Retry knows what text to resend. Implementation: thread it through a new `Message.failedUserMessageId` optional field, populated when the most recent prior `role: "user"` message in the same session looks like the trigger.

The spec below assumes all three. The plan stages them as discrete steps so the variant can land even if retry wiring slips.

## Scope

### In

1. New `errorBubble` variant on `MessageBubble` for `message.role == "error"`.
2. Card style: 1px `Color.danger` border + `Color.danger.opacity(0.08)` tint background + `Radius.md` (14pt — distinguishes from chat bubble's `Radius.lg` 18pt, matches the tool-card recipe).
3. "ERROR" eyebrow at top in `Color.danger`, `Font.eyebrow` with `lsEyebrow` letterspacing (matches the established eyebrow recipe across the app).
4. Error message text in JetBrains Mono (`FontName.mono` at 14pt — matches tool-output mono treatment).
5. Trailing timestamp using the same `Font.caption` + `fgTertiary` recipe as every other bubble.
6. Inline "Retry" button: small, bordered (`Color.danger`-tinted outline), with `Color.danger` foreground. Visible only when the `Message` has a non-nil `failedUserMessageId` *and* the referenced user message still exists in the same session (defensive: covers `/clear` wiping history).
7. Add `failedUserMessageId: String?` (optional) field to `Message` SwiftData model — schema migration is additive (SwiftData handles a new optional column automatically with a lightweight migration; no manual `VersionedSchema` needed since the project has not yet pinned a schema version).
8. Update `ChatViewModel.handleIncoming` `.error` case to insert `role: "error"`, strip the `"Error: "` prefix from `text`, and capture the most recent prior `role: "user"` message id (within the same session, by descending timestamp) as `failedUserMessageId`.
9. Add `ChatViewModel.retry(errorMessage:)` method: looks up the referenced user message, re-sends its text + attachment via `sendToServer`, deletes the error message row.
10. Wire `MessageBubble`'s Retry button to call `onRetry?(message)` callback — `ChatView` injects `viewModel.retry`.

### Out

- Team-side errors. **Verified:** `TeamMessage` model (`Models/TeamMessage.swift`) has no `role` field — it has `senderType` and a hardcoded `"system"` `senderId` check in `TeamMessageBubble.swift:11`. Team errors today flow through agent-status badges (`AgentRow.swift`, `AgentDetailSheet.swift`) and disconnect banners (`TeamViewModel.disconnectedBanner`) — *not* through `TeamMessage` rows. There is no equivalent in-chat error row to migrate. If team-side error rows become a thing later, they get their own ticket.
- Backend protocol changes — the `WSIncoming.error` case stays as-is; only the client-side handling changes.
- Retry policy beyond "re-send the same text + attachment". No exponential backoff, no "tried 3 times" counter. If a retry fails, a new error row appears and the user retries again.
- Preserving the original `"Error: "`-prefixed system messages on existing installs — the migration is forward-only; old error rows stay as `role: "system"` and continue to render via `systemBubble` (their text already includes `"Error: "`, so this is harmless).
- Read receipts, dismiss-error swipe gesture, error history view.

## Key Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Error data flow | Add `"error"` as a `Message.role` value (string, not enum — model uses `String` today) | Matches the backlog's explicit framing (`message.role == "error"`); keeps the bubble routing pattern consistent with the existing `switch message.role` in `MessageBubble.body` |
| Schema change | Add optional `failedUserMessageId: String?` to `Message` | SwiftData handles new optional fields with lightweight migration automatically; no `VersionedSchema` ceremony needed (project has no schema versioning yet) |
| Retry source-of-truth | Reference the failing user `Message.id` on the error row | Surviving across app relaunches matters — `pendingMessages` is in-memory only. Storing the id keeps retry useful after a relaunch |
| Retry behavior | Re-send original text + attachment via existing `sendToServer`; delete the error row on tap | Minimal — matches the `WorkspacePickerView` retry pattern (one-shot, no state machine) |
| Border + tint recipe | 1px `Color.danger` stroke + `Color.danger.opacity(0.08)` fill + `Radius.md` | Backlog spells the recipe verbatim. `Radius.md` keeps it visually grouped with tool cards (also "this is not a chat bubble, this is a notice card") |
| Eyebrow treatment | "ERROR" in `Font.eyebrow` (12pt semibold) + `lsEyebrow` tracking (0.96) + `Color.danger` foreground | Matches the eyebrow tracking recipe in `KeepurTheme.Font.lsEyebrow`; danger color is the only token that says "this is bad" without ambiguity |
| Error text typeface | `Font.custom(FontName.mono, size: 14)` | Backlog says JetBrains Mono. 14pt body-equivalent for readability (matches `Font.mono` default size) |
| Retry button style | `.bordered` button modifier with `.tint(Color.danger)` and `.controlSize(.small)` | Native SwiftUI bordered button picks up `.tint` on iOS 15+ / macOS 12+; smaller than full-width CTA which would dominate the card. **Not** `KeepurDestructiveButtonStyle` (that's full-width) |
| Retry alignment | Trailing edge of the card, inline with timestamp | Matches the user-bubble pattern of timestamp at trailing; gives Retry a predictable hit target |
| Existing system errors | Leave alone — old `"Error: "`-prefixed system rows continue to render unchanged | Forward-only migration; no SwiftData backfill |
| Stripping `"Error: "` prefix | Strip on insert — error rows store the raw server message | The "ERROR" eyebrow is now visible; the prefix would be redundant |
| Team side | Out of scope — `TeamMessage` has no role field and team errors flow through different surfaces (status badges, banners) | Confirmed by code inspection (see Out section) |

## Component Designs

### Updated `Message` model

```swift
@Model
final class Message {
    @Attribute(.unique) var id: String
    var sessionId: String
    var text: String
    var role: String  // "user", "assistant", "system", "tool", "error"
    var timestamp: Date
    var attachmentName: String?
    var attachmentType: String?
    @Attribute(.externalStorage) var attachmentData: Data?
    var failedUserMessageId: String?    // populated only on role == "error"

    init(
        id: String = UUID().uuidString,
        sessionId: String,
        text: String,
        role: String,
        timestamp: Date = .now,
        attachmentName: String? = nil,
        attachmentType: String? = nil,
        attachmentData: Data? = nil,
        failedUserMessageId: String? = nil
    ) { /* assign all */ }
}
```

The role-doc-comment gains `"error"`. The new optional field defaults to `nil`. SwiftData migrates by adding a new nullable column on next launch — no manual migration code needed.

### `MessageBubble` — new `errorBubble` variant

```swift
struct MessageBubble: View {
    let message: Message
    var showWaitingBadge: Bool = false
    var onSpeak: ((String) -> Void)? = nil
    var onRetry: ((Message) -> Void)? = nil    // NEW
    @State private var isPulsing = false

    var body: some View {
        switch message.role {
        case "user":      userBubble
        case "tool":      toolBubble
        case "system":    systemBubble
        case "error":     errorBubble        // NEW
        case "unknown":   unknownBubble
        default:          assistantBubble
        }
    }

    private var errorBubble: some View {
        HStack {
            VStack(alignment: .leading, spacing: KeepurTheme.Spacing.s2) {
                // Eyebrow
                Text("ERROR")
                    .font(KeepurTheme.Font.eyebrow)
                    .tracking(KeepurTheme.Font.lsEyebrow)
                    .foregroundStyle(KeepurTheme.Color.danger)

                // Mono error text
                Text(message.text)
                    .font(.custom(KeepurTheme.FontName.mono, size: 14))
                    .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Trailing row: timestamp + optional Retry
                HStack(spacing: KeepurTheme.Spacing.s3) {
                    Text(message.timestamp, style: .time)
                        .font(KeepurTheme.Font.caption)
                        .foregroundStyle(KeepurTheme.Color.fgTertiary)

                    Spacer()

                    if let onRetry, message.failedUserMessageId != nil {
                        Button { onRetry(message) } label: {
                            Text("Retry")
                                .font(KeepurTheme.Font.caption)
                                .fontWeight(.semibold)
                        }
                        .buttonStyle(.bordered)
                        .tint(KeepurTheme.Color.danger)
                        .controlSize(.small)
                    }
                }
            }
            .padding(.horizontal, KeepurTheme.Spacing.s3)
            .padding(.vertical, KeepurTheme.Spacing.s2)
            .background(
                RoundedRectangle(cornerRadius: KeepurTheme.Radius.md)
                    .fill(KeepurTheme.Color.danger.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: KeepurTheme.Radius.md)
                    .stroke(KeepurTheme.Color.danger, lineWidth: 1)
            )

            Spacer(minLength: 60)
        }
    }
}
```

### `ChatViewModel` — error handling + retry

```swift
case .error(let message, let sessionId):
    if sessionId == nil && isBrowsePending {
        isBrowsePending = false
        browseError = message
    }
    let targetSessionId = sessionId ?? currentSessionId
    if let targetSessionId {
        // Find the most recent user message in this session — the likely trigger.
        let descriptor: FetchDescriptor<Message> = {
            var d = FetchDescriptor<Message>(
                predicate: #Predicate { $0.sessionId == targetSessionId && $0.role == "user" },
                sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
            )
            d.fetchLimit = 1
            return d
        }()
        let trigger = try? context.fetch(descriptor).first

        let errorRow = Message(
            sessionId: targetSessionId,
            text: message,                              // raw, no "Error: " prefix
            role: "error",
            failedUserMessageId: trigger?.id
        )
        context.insert(errorRow)
        try? context.save()
    }
```

```swift
func retry(errorMessage: Message) {
    guard let context = modelContext,
          let triggerId = errorMessage.failedUserMessageId else { return }

    let descriptor = FetchDescriptor<Message>(
        predicate: #Predicate { $0.id == triggerId }
    )
    guard let trigger = try? context.fetch(descriptor).first else {
        // Original message is gone (e.g. /clear wiped history). Just remove the error row.
        context.delete(errorMessage)
        try? context.save()
        return
    }

    let attachment: AttachmentData? = {
        guard let data = trigger.attachmentData,
              let name = trigger.attachmentName,
              let mime = trigger.attachmentType else { return nil }
        return AttachmentData(name: name, mimeType: mime, data: data)
    }()

    sendToServer(text: trigger.text, attachment: attachment, sessionId: trigger.sessionId)
    context.delete(errorMessage)
    try? context.save()
}
```

`sendToServer` is already private; no visibility change needed since `retry` lives on the same type.

### `ChatView` wiring

Wherever `MessageBubble(message:)` is constructed inside `ChatView`, add `onRetry: { viewModel.retry(errorMessage: $0) }`. (Single call site; the spec doesn't enumerate the line because the file isn't part of this ticket's surface — the plan will locate it.)

## Visual Spec

- **Card:** `RoundedRectangle(cornerRadius: Radius.md)` filled with `Color.danger.opacity(0.08)`, overlaid with a 1pt `Color.danger` stroke at the same corner radius
- **Card padding:** `Spacing.s3` horizontal (12pt), `Spacing.s2` vertical (8pt) — matches tool-card recipe
- **Card alignment:** leading-aligned with `Spacer(minLength: 60)` trailing — same convention as assistant/tool/unknown bubbles
- **Eyebrow row:** "ERROR" at `Font.eyebrow` + `lsEyebrow` tracking + `Color.danger`
- **Error text:** JetBrains Mono regular 14pt, charcoal foreground (`fgPrimaryDynamic`), text-selection enabled, leading-aligned, full card width
- **Trailing row:** time on left (caption + `fgTertiary`), `Spacer()`, Retry button on right when applicable
- **Retry button:** `.bordered` style + `.tint(Color.danger)` + `.controlSize(.small)`; label is "Retry" at `Font.caption` semibold

## Edge cases

- **Error with no prior user message in session:** `failedUserMessageId` is `nil`; Retry button is hidden; the bubble still renders the eyebrow + mono text + timestamp.
- **Original user message deleted between error insertion and retry tap** (e.g. `/clear` wipe): `retry()` deletes the error row and no-ops. This is intentional graceful degradation.
- **Server-level error with `sessionId == nil` while not browsing:** falls through to `currentSessionId`. If `currentSessionId` is also `nil`, no error row is inserted (matches today's behavior — error is dropped).
- **Repeated identical errors:** each WS error frame inserts a new error row; we don't deduplicate. This matches today's behavior and keeps the data flow simple.
- **Old `"Error: "`-prefixed `system` rows from before this ticket:** continue to render via `systemBubble` (centered grey caption); not migrated.

## Smoke Test Scope

Single test file `KeeperTests/MessageBubbleErrorVariantTests.swift`. Per CLAUDE.md guidance ("Don't smoke-test full View bodies depending on @StateObject/Keychain"), tests focus on:

| Layer | Test | Notes |
|---|---|---|
| Model | `Message` with `role: "error"` and `failedUserMessageId` round-trips through SwiftData | Use in-memory `ModelContainer` like existing `KeepurTheme...Tests` |
| ViewModel | `ChatViewModel.retry(errorMessage:)` looks up trigger and calls send path | Inject a fake `WebSocketManager` if feasible; otherwise assert side-effects on `ModelContext` (error row deleted) |
| ViewModel | `.error` WS frame produces a `role: "error"` Message with `failedUserMessageId` set to most recent user message id | In-memory ModelContainer + manually-driven `handleIncoming` |
| ViewModel | `.error` WS frame with no prior user message produces a `role: "error"` Message with `nil` `failedUserMessageId` | Edge case |
| ViewModel | `retry()` with stale `failedUserMessageId` (referenced message deleted) deletes the error row and no-ops | Edge case |

`MessageBubble.errorBubble` body itself is not asserted — SwiftUI views are visual and the project has no snapshot library. We trust the token wiring (covered by foundation tests) and verify by `xcodebuild build` succeeding.

## Out of Scope

- Team-side errors (no equivalent surface today; see central question).
- Error history view, dismiss-error swipe, "view error details" disclosure.
- Per-error retry policy (backoff, attempt counter).
- Surfacing transport-level errors (WebSocket disconnect) as in-chat error rows — those flow through `TeamViewModel.disconnectedBanner` for the team side; chat side has no banner today and that's a separate UX question.
- Migrating existing `"Error: "`-prefixed system rows.
- Animating the bubble's appearance.

## Open Questions

- **Retry on a stale-busy session:** if the original send was queued in `pendingMessages` and the server eventually returned an error for it (rare), the retry could collide with another queued send. Acceptable: the queue serializes and the user just sees a second error if it fails again. Flagged here so reviewers don't miss it.
- **macOS Retry button styling:** `.bordered` + `.tint` looks slightly different on macOS (more subtle outline). Not blocking — both renderings read as "destructive bordered button". Visual diff during plan execution will confirm.
- **`failedUserMessageId` ambiguity** when multiple user messages are queued and the server returns a generic error without echoing which one failed: we attribute to the most recent. The server doesn't currently identify which message a given error belongs to. If/when it does (a future protocol change), tighten the attribution.

## Files Touched

- `Models/Message.swift` (extend role doc comment, add `failedUserMessageId` field + init param)
- `ViewModels/ChatViewModel.swift` (rewrite `.error` case; add `retry(errorMessage:)`)
- `Views/MessageBubble.swift` (add `errorBubble` variant; add `onRetry` callback param; add `case "error"` to switch)
- `Views/ChatView.swift` (wire `onRetry` on `MessageBubble` instantiation site)
- `KeeperTests/MessageBubbleErrorVariantTests.swift` (new — wired into test target via `Keepur.xcodeproj/project.pbxproj`)
- `Keepur.xcodeproj/project.pbxproj` (test file wiring only — `Views/` and `Models/` are synchronized folder groups per CLAUDE.md, no project edits needed for source files)

## Dependencies / Sequencing

- **Blocks:** none (leaf consumer)
- **Blocked by:** none (foundation tokens `Color.danger`, `Radius.md`, `FontName.mono`, `Font.eyebrow`, `Font.lsEyebrow` all exist in `Theme/KeepurTheme.swift`)
- Can run in parallel with other Layer 3 tickets; touches only chat-side files (no overlap with Hive sidebar / Sessions / Settings tickets).

## Human Signoff

Pre-approved per durable user delegation (KPR-142 design v2 epic). The retry data-flow additions go beyond pure styling, but they're load-bearing for the variant being usable — the bubble would be inert without them. Recorded for transparency; no checkpoint required.
