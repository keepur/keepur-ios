# KPR-155 — design v2: TeamMessageBubble polish (mini avatar)

**Date:** 2026-05-02
**Epic:** [KPR-142 design v2](https://linear.app/keepur/issue/KPR-142)
**Layer:** 3 (per-screen consumption)
**Depends on:** KPR-144 (foundation atoms — `KeepurAvatar`)

## Problem

The current `TeamMessageBubble` agent variant prints the sender's name as a plain caption "eyebrow" above the message bubble. The design v2 mockups replace that with a mini square avatar (~24pt) placed *below* the bubble alongside the timestamp, matching the visual cadence of the new Hive sidebar (KPR-150) and Agent detail header (KPR-151) — same `KeepurAvatar` primitive, smaller size, simpler footer row.

This is a deliberately narrow ticket. The bigger chat-surface polish lands via:
- KPR-152 (chat header redesign with `KeepurChatHeader`)
- KPR-153 (error message bubble variant)
- DOD-395 (chat chrome migration — already shipped on `main`)

So all that's left for the team-bubble surface is the mini-avatar swap on the agent variant.

## Solution

Modify `Views/Team/TeamMessageBubble.swift` agent variant only. Drop the leading `Text(message.senderName)` caption above the bubble. Below the bubble, prepend a 24pt `KeepurAvatar` to the existing footer `HStack` that contains the timestamp + speaker button.

System and user variants are not touched. Three-variant routing (`senderId == "system"` / `isOwnMessage` / agent) is preserved unchanged.

## Key Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Avatar content source | `.letter(message.senderName)` | `TeamMessage` only carries `senderName` — no `icon` field on the SwiftData model. The agent's emoji icon lives on `TeamAgentInfo` (WS payload struct) which the bubble does not currently receive. Adding agent lookup at the bubble call site is out-of-scope for a polish ticket. `KeepurAvatar` already takes the first character + uppercases it, so "claude-bot" → "C". |
| Avatar size | `24` (raw `CGFloat`) | Backlog explicit: "mini `KeepurAvatar` (~24pt square)". `KeepurAvatar` already supports raw `CGFloat` sizing per KPR-144. |
| Avatar position | First element in the existing footer `HStack` (left of timestamp) | Mockup intent: avatar + time on the same baseline below the bubble. Re-uses the existing footer row instead of adding a new container. |
| Drop sender-name eyebrow above bubble | Yes | Mockup explicitly replaces the eyebrow with the footer mini-avatar. The avatar's accessibility label preserves the identity affordance ("Avatar C"). Sender name is no longer surfaced visually — acceptable tradeoff since DM context already implies the agent. |
| Status overlay on mini avatar | None | Backlog explicitly holds "Spoken" indicator and "Delivered" status as separate feature tickets. Status overlay is reserved for the held streaming-state visual ticket (lightning-bolt replacement). Default `KeepurAvatar` `statusOverlay: nil` covers this. |
| Avatar background | Default `wax100` | KPR-144 default — matches the wax surface tone used throughout the new design language. No mockup signal for a per-agent honey tint. |
| Footer alignment / spacing | `KeepurTheme.Spacing.s2` between avatar and time (was `s3` between time and speaker button) | Tighter avatar↔time pairing reads as one unit; preserve `s3` between time and speaker button. |
| Footer vertical alignment | `.center` | 24pt avatar visually centers against caption-tier text and the speaker `Image`. |

## Visual Spec — Agent Bubble (After)

```
┌────────────────────────────────────────────────┐
│ ┌────────────────────────────────────────┐     │
│ │ [Markdown body]                        │     │
│ │                                        │     │
│ └────────────────────────────────────────┘     │
│ ┌──┐ 10:42 AM   🔊                              │
│ │ C│                                            │
│ └──┘                                            │
└────────────────────────────────────────────────┘
                                       (Spacer 60)
```

- Outer container: unchanged `HStack { VStack(...) Spacer(minLength: 60) }`.
- Inner `VStack(alignment: .leading, spacing: KeepurTheme.Spacing.s1)`.
- Element 1 (was: sender name `Text` — **removed**).
- Element 2: `Markdown(message.text).markdownTheme(.keepur)...` — unchanged.
- Element 3: footer `HStack(alignment: .center, spacing: KeepurTheme.Spacing.s3)` containing:
  - **NEW:** `KeepurAvatar(size: 24, content: .letter(message.senderName))`
  - existing `Text(message.createdAt, style: .time)` styled as before
  - existing speaker button (when `onSpeak` non-nil) styled as before
  - inner spacing between avatar and timestamp: `KeepurTheme.Spacing.s2` via a nested `HStack` or by tightening the parent spacing — implementation detail covered in plan.

## Variants — Routing Preserved

| Variant | Trigger | Change |
|---|---|---|
| System | `message.senderId == "system"` | None |
| User (own) | `isOwnMessage == true` | None |
| Agent | else | Drop sender-name eyebrow; add 24pt `KeepurAvatar.letter(senderName)` in footer |

## Out of Scope

- "Spoken" indicator (held — separate held-features epic ticket)
- "Delivered" status under user message timestamps (held)
- Streaming honey lightning bolt replacement (held design ticket — KPR sibling epic)
- Wiring agent `icon` (emoji) from `TeamAgentInfo` into the bubble — would require either (a) plumbing agent lookup through `TeamMessageBubble`'s init, or (b) extending `TeamMessage` with an `senderIcon` field. Both touch model/ViewModel layers and exceed the polish-ticket scope. Documented as an open question.
- User bubble footer changes
- System bubble changes
- Markdown rendering changes
- Speaker button behavior / restyle

## Open Questions

1. **Should the mini-avatar render the agent's emoji icon when available?** `TeamAgentInfo.icon` carries an emoji (e.g. "🤖") and `AgentDetailSheet` already renders it. Threading that through `TeamMessageBubble` requires changing the bubble's call signature in `TeamChatView.swift` (line 116) to pass an `icon: String?` — straightforward but expands the diff. Recommendation: ship letter-only for KPR-155, file a follow-up ticket to wire emoji icons once the held streaming-indicator + spoken-indicator tickets land (those will already be expanding the bubble's per-message metadata surface).
2. None other — backlog scope and existing `KeepurAvatar` API fully constrain the change.

## Files Touched

- `Views/Team/TeamMessageBubble.swift` (modify agent variant only)
- `KeeperTests/TeamMessageBubbleTests.swift` (new — smoke test for three-variant routing + agent footer composition)
- `Keepur.xcodeproj/project.pbxproj` (wire new test file into test target only — `Views/` is a synchronized folder group so the modified view needs no wiring)

## Dependencies / Sequencing

- **Blocks:** none (leaf consumer in layer 3)
- **Blocked by:** KPR-144 (`KeepurAvatar` must exist) — already merged into the epic branch
- Independent of KPR-150 (Hive sidebar), KPR-151 (Agent detail), KPR-152 (chat header), KPR-153 (error bubble) — different surfaces, no shared code beyond the `KeepurAvatar` primitive

## Smoke Test Scope

Single new test file `KeeperTests/TeamMessageBubbleTests.swift`. SwiftData `@Model` types can be instantiated in-memory (no `ModelContainer` needed for property access), so `TeamMessage(...)` constructors work in a unit context. Each test instantiates a bubble across the three variants and asserts `_ = view.body` doesn't crash — same pattern as `KeepurFoundationAtomsTests.swift`. No snapshot library available; visual rendering is not asserted.

| Test | Coverage |
|---|---|
| `testSystemBubbleInstantiates` | `senderId == "system"` routes to system variant |
| `testUserBubbleInstantiates` | `isOwnMessage == true` routes to user variant; pending + non-pending |
| `testAgentBubbleInstantiates` | `isOwnMessage == false`, non-system → agent variant; with and without `onSpeak` callback; verify mini-avatar synthesizes from empty + non-empty `senderName` (covers `KeepurAvatar.letter("")` placeholder path) |

Three tests, ~40 lines total. Matches the `KeepurFoundationAtomsTests.swift` cadence.

## Human Signoff

Pre-approved per durable user delegation (KPR-142 design v2 epic — mockups already approve component intent; user explicit: "as long as it more or less looks like the mockup, I don't care beyond that"). Recorded in epic-orchestrator memory.
