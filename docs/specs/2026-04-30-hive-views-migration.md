# Keepur iOS — Hive (Team) Views Migration to Design System

**Date**: 2026-04-30
**Status**: Draft
**Ticket**: [DOD-399](https://linear.app/dodihome/issue/DOD-399/keepur-ios-migrate-hive-team-views-to-keepurtheme-tokens)
**Parent epic**: [DOD-390](https://linear.app/dodihome/issue/DOD-390/keepur-ios-per-screen-migration-to-keepur-design-system) — **final ticket**

## Problem

`Views/Team/` is the entire Hive surface — eight files, ~768 LOC. Today every color is system blue/red/green/orange/secondary, every bubble surface is `Color.secondarySystemFill`, every hexagon is `Color.accentColor`. The Hive feels distinctly stock-iOS even though this is the brand's most "bee-themed" surface (hexagons, agents, multi-agent chat).

## Scope

### In

All eight files in `Views/Team/` retoken to `KeepurTheme.*`:

1. `HivesGridView.swift` (78) — hexagon HiveCard
2. `TeamRootView.swift` (52) — disconnected banner + sidebar+detail layout
3. `TeamSidebarView.swift` (38) — agent list
4. `AgentRow.swift` (70) — sidebar row with status dot
5. `TeamChatView.swift` (140) — chat surface (mirrors ChatView)
6. `TeamMessageBubble.swift` (107) — bubble (mirrors MessageBubble)
7. `AgentDetailSheet.swift` (192) — info card + sections + voice navigation
8. `AgentVoicePickerView.swift` (91) — voice list (mirrors Settings voice section)

### Out

- TeamViewModel / SpeechManager / data flow.
- The user-customizable agent emoji icon (data, not chrome).
- Markdown theme — already brand-tuned at foundation.
- Re-architecting any view.

## Design Decisions

### D1. HivesGridView — hexagon cards

```swift
private struct HiveCard: View {
    let name: String
    var body: some View {
        VStack(spacing: KeepurTheme.Spacing.s3) {
            Image(systemName: "hexagon.fill")
                .font(.system(size: 36))
                .foregroundStyle(KeepurTheme.Color.honey500)
            Text(name)
                .font(KeepurTheme.Font.h4)
                .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 140)
        .background(KeepurTheme.Color.bgSurfaceDynamic)
        .clipShape(RoundedRectangle(cornerRadius: KeepurTheme.Radius.md))
        .keepurBorder(KeepurTheme.Color.borderDefaultDynamic, radius: KeepurTheme.Radius.md, width: 1)
}
}
```

- Hexagon icon is **honey-500** — the brand's marquee bee mark.
- `bgSurfaceDynamic` (white light / charcoal dark) replaces `.regularMaterial` — flat wax surface reads as "card" without iOS material chrome.
- `keepurBorder` adds the 1px wax-200 border (foundation already exports this modifier).
- `Font.h4` (18pt semibold) replaces `.headline` — same weight, derived from tokens.
- Outer page bg (when grid is shown) — adopt `bgPageDynamic` on the parent `Group`.

Empty-state ContentUnavailableView ("No hives available") stays system styling — nothing to retoken there.

### D2. TeamRootView — disconnected banner

The orange "exclamationmark.triangle.fill — Banner — Retry" full-width banner today uses `Color.orange` background + `.white` text. Replace with the same recipe as the Session List expiry banner (DOD-393 D2):

```swift
Button { viewModel.retryConnect() } label: {
    HStack {
        Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(KeepurTheme.Color.warning)
        Text(banner)
            .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
        Spacer()
        Text("Retry")
            .fontWeight(.bold)
            .foregroundStyle(KeepurTheme.Color.honey700)
    }
    .font(KeepurTheme.Font.bodySm)
    .padding(KeepurTheme.Spacing.s3)
    .frame(maxWidth: .infinity)
    .background(KeepurTheme.Color.honey100)
}
.buttonStyle(.plain)
```

`honey100` background reads as "warning, not danger" — the brand's amber wash. The "Retry" affordance in `honey700` is darker honey for emphasis without competing with the warning icon.

### D3. TeamRootView — sidebar status dot

```swift
Circle()
    .fill(viewModel.ws.isConnected ? KeepurTheme.Color.success : KeepurTheme.Color.danger)
    .frame(width: 8, height: 8)
```

Identical to Session List D7 + Settings D4.

### D4. TeamSidebarView — list & empty state

`.listStyle(.sidebar)` stays — iOS-native split-view chrome. Add wax page bg behind the sidebar:

```swift
List(...) { ... }
    .listStyle(.sidebar)
    .scrollContentBackground(.hidden)
    .background(KeepurTheme.Color.bgPageDynamic)
```

Empty state ContentUnavailableView ("No Agents — Connecting to Hive...") stays system styling.

### D5. AgentRow — status dot + name + subtitle + relative time

The 10pt status dot maps to:
- `idle` → `Color.success`
- `processing` → `Color.warning`
- `error`/`stopped` → `Color.danger`
- default → `Color.fgMuted`

```swift
private var statusColor: SwiftUI.Color {
    switch agent.status {
    case "idle": return KeepurTheme.Color.success
    case "processing": return KeepurTheme.Color.warning
    case "error", "stopped": return KeepurTheme.Color.danger
    default: return KeepurTheme.Color.fgMuted
    }
}
```

Text rows:

```swift
Text(agent.name)
    .font(KeepurTheme.Font.body)
    .fontWeight(isActive ? .semibold : .regular)
    .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
    .lineLimit(1)

if let secondLineText {
    Text(secondLineText)
        .font(KeepurTheme.Font.caption)
        .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
        .lineLimit(1)
}

// Trailing time:
Text(lastAt, style: .relative)
    .font(KeepurTheme.Font.caption)
    .foregroundStyle(KeepurTheme.Color.fgTertiary)
```

Spacing s3 for the outer HStack (was 12pt — same value, token-derived).

### D6. TeamChatView — toolbar speaker + load-earlier + paddings

Same toolbar speaker treatment as ChatView (DOD-395 D9):

```swift
.foregroundStyle(
    speechManager.isSpeaking ? KeepurTheme.Color.danger
    : autoReadAloud ? KeepurTheme.Color.honey500
    : KeepurTheme.Color.fgSecondaryDynamic
)
```

Info button stays as-is (`info.circle` literal, system tint).

"Load earlier messages" button:

```swift
Button("Load earlier messages") { /* ... */ }
    .font(KeepurTheme.Font.caption)
    .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
    .padding(.vertical, KeepurTheme.Spacing.s2)
```

Outer LazyVStack paddings → `Spacing.s3` for inner spacing, `s4`/`s3` for horizontal/vertical (matches ChatView D11).

ProgressView and `info.circle` toolbar button — stay system.

### D7. TeamMessageBubble — three variants

Mirror MessageBubble (DOD-394) with the team-specific adaptation: agent bubbles get the sender name as a leading caption.

**User bubble** (own message, right-aligned):
- Identical recipe to `MessageBubble.userBubble` (DOD-394 D1): honey-500 + `fgOnHoney`, asymmetric 6pt tail, `Font.body`. Same "sending" → "waiting" badge swap (D7.1 below).

**Agent bubble** (left-aligned):
- Sender name eyebrow above the bubble: `Font.caption` + `fgSecondaryDynamic`.
- Markdown body in `bgSunkenDynamic` with `Radius.lg` — identical to `MessageBubble.assistantBubble` (DOD-394 D2).
- Speaker button identical to MessageBubble D7.

**System bubble** (centered) — identical to MessageBubble D4.

Timestamps uniform: `Font.caption` + `fgTertiary`.

#### D7.1. "sending" badge

```swift
if message.pending {
    Text("sending")
        .font(KeepurTheme.Font.caption)
        .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
        .padding(.horizontal, KeepurTheme.Spacing.s2)
        .padding(.vertical, 2)
        .background(Capsule().fill(KeepurTheme.Color.honey200))
        .offset(x: 4, y: 4)
        .opacity(isPulsing ? 0.6 : 1.0)
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: isPulsing)
        .onAppear { isPulsing = true }
}
```

Same recipe as MessageBubble's "waiting" badge (DOD-394 D8). Pulse timing unchanged.

### D8. AgentDetailSheet — header + info grid + section cards + voice nav

**Header** (icon + name + status):

```swift
VStack(spacing: KeepurTheme.Spacing.s2) {
    Text(iconText)               // emoji — user data, untouched
        .font(.system(size: 48))
    Text(agent.name)
        .font(KeepurTheme.Font.h3)
        .tracking(KeepurTheme.Font.lsH3)
        .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
    HStack(spacing: 6) {
        Circle()
            .fill(statusColor)            // semantic per D5
            .frame(width: 10, height: 10)
        Text(agent.status)
            .font(KeepurTheme.Font.bodySm)
            .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
    }
}
.padding(.top)
```

Same `statusColor` switch as D5.

**Info grid** (Title / Model / Messages / Last Active rows):

```swift
VStack(spacing: 0) {
    if let title = agent.title, !title.isEmpty {
        infoRow(label: "Title", value: title)
    }
    // ... model, messages, last-active rows
}
.background(KeepurTheme.Color.bgSurfaceDynamic)
.clipShape(RoundedRectangle(cornerRadius: KeepurTheme.Radius.sm))
```

`infoRow(label:value:)` uses `Font.bodySm` + `fgSecondaryDynamic` for label, `Font.bodySm` + `fgPrimaryDynamic` for value, `Spacing.s4`/`Spacing.s2 + 2` paddings (16/10pt). Same numeric padding as the original.

**Section cards** (Tools / Schedule / Channels):

```swift
private func sectionCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: KeepurTheme.Spacing.s2) {
        Text(title)
            .font(KeepurTheme.Font.eyebrow)
            .tracking(KeepurTheme.Font.lsEyebrow)
            .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
            .textCase(nil)
        content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(KeepurTheme.Spacing.s4)
    .background(KeepurTheme.Color.bgSurfaceDynamic)
    .clipShape(RoundedRectangle(cornerRadius: KeepurTheme.Radius.sm))
}
```

Title becomes a true eyebrow ("TOOLS" / "SCHEDULE" / "CHANNELS" — uppercase the call sites). Body content keeps the existing per-section formatting except cron strings flip to JetBrains Mono:

```swift
Text(cron)
    .font(.custom(KeepurTheme.FontName.mono, size: 12))
    .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
```

(Cron strings are explicitly identifier-like — fits the JetBrains Mono use case.)

**Voice navigation row**:

```swift
NavigationLink {
    AgentVoicePickerView(agent: agent, speechManager: speechManager)
} label: {
    HStack {
        VStack(alignment: .leading, spacing: KeepurTheme.Spacing.s1) {
            Text("VOICE")
                .font(KeepurTheme.Font.eyebrow)
                .tracking(KeepurTheme.Font.lsEyebrow)
                .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                .textCase(nil)
            Text(currentVoiceLabel)
                .font(KeepurTheme.Font.bodySm)
                .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
        }
        Spacer()
        Image(systemName: "chevron.right")
            .font(KeepurTheme.Font.bodySm)
            .foregroundStyle(KeepurTheme.Color.fgTertiary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(KeepurTheme.Spacing.s4)
    .background(KeepurTheme.Color.bgSurfaceDynamic)
    .clipShape(RoundedRectangle(cornerRadius: KeepurTheme.Radius.sm))
}
.buttonStyle(.plain)
```

Outer page background of the sheet:

```swift
.background(KeepurTheme.Color.bgPageDynamic)
```

Replaces `Color.systemGroupedBackground`. The sheet's content cards float on the wax page.

### D9. AgentVoicePickerView — same as Settings voice picker

Mirror DOD-392's voice section pattern:

- "Use default" row with `Font.body` primary + `Font.caption` secondary subtitle.
- Voice list with eyebrow "VOICES" header.
- Selected checkmark in `Color.honey500` (was `.blue`).
- Wax row backgrounds via `.listRowBackground(KeepurTheme.Color.bgSurfaceDynamic)`.
- `.scrollContentBackground(.hidden)` + `.background(KeepurTheme.Color.bgPageDynamic)` on the List.
- Drop the outer `.foregroundStyle(.primary)` on each Button (every inner Text sets explicit foreground).

## File Layout (after this ticket)

```
Views/Team/HivesGridView.swift              (REWRITTEN)
Views/Team/TeamRootView.swift               (REWRITTEN)
Views/Team/TeamSidebarView.swift            (REWRITTEN)
Views/Team/AgentRow.swift                   (REWRITTEN)
Views/Team/TeamChatView.swift               (REWRITTEN)
Views/Team/TeamMessageBubble.swift          (REWRITTEN)
Views/Team/AgentDetailSheet.swift           (REWRITTEN)
Views/Team/AgentVoicePickerView.swift       (REWRITTEN)
```

No new files, no foundation expansion, no project.pbxproj edits.

## Implementation Outline

1. **Preconditions** — confirm tokens used resolve. Specifically need everything used by prior migrations plus: `Font.h4` (HivesGridView), `keepurBorder` modifier (HivesGridView). Confirm no Team* test references break.

2. **Rewrite the 8 files in this order** (smallest first, smaller files build confidence the recipe works before tackling AgentDetailSheet which is the largest):
   - TeamSidebarView (38 LOC)
   - TeamRootView (52 LOC)
   - AgentRow (70 LOC)
   - HivesGridView (78 LOC)
   - AgentVoicePickerView (91 LOC)
   - TeamMessageBubble (107 LOC)
   - TeamChatView (140 LOC)
   - AgentDetailSheet (192 LOC)

3. **Build for iOS and macOS, run unit suite on both** after every two files (catches arch problems early without per-file overhead).

4. **Visual diff in simulator** — switch to a Hive (gear → hive picker), browse the agent sidebar, open an agent DM, send a message, view agent details, change voice. Tick:
   - Hexagon HiveCards in honey, wax surface, wax-200 border
   - Disconnected banner: amber wash, charcoal text, honey "Retry"
   - Sidebar status dot uses success/danger
   - Agent rows: small dots in semantic colors (success for idle, warning for processing, danger for error)
   - Team user bubbles: honey amber with charcoal text, 6pt tail (matches DOD-394)
   - Agent bubbles: sender-name eyebrow above wax surface bubble
   - "sending" badge: amber capsule (was gray)
   - Agent detail sheet: wax page bg, eyebrow section headers (TOOLS / SCHEDULE / CHANNELS / VOICE), cron strings in JetBrains Mono
   - Voice picker: honey checkmark on selected voice

5. **Single commit** at the end: `feat: migrate Hive (Team) views to KeepurTheme tokens (DOD-399)`. The 8 files are tightly coupled by the same brand recipe; shipping them together means the visual diff is reviewable per-screen rather than per-file.

## Risks & Open Questions

- **`statusColor` on AgentRow vs AgentDetailSheet**: same switch logic in both files. After this ticket lands, a follow-up could extract to `Color.agentStatusColor(_ status: String)` in `KeepurTheme+Agent.swift` or similar. Out of scope here — YAGNI until a third caller appears.
- **Hexagon HiveCard losing `.regularMaterial`**: replacing with flat `bgSurfaceDynamic` removes the iOS material translucency. The kit's HiveCard mock is flat wax, so this is intentional. If users are accustomed to the material feel, they'll notice — but the wax+border+honey-icon recipe is more brand-coherent.
- **Agent emoji icon**: stays as user data. The 48pt size is fine.
- **Cron strings in JetBrains Mono**: a slightly different size from the original `.caption.monospaced()` (12pt mono SF). Mono = 12pt JetBrains. Effective size identical, but typeface shift visible.
- **macOS NavigationSplitView in TeamRootView**: the disconnected banner sits *outside* the NavigationSplitView (above it). Verify this layout still works with the new `frame(maxWidth: .infinity)` — should be unchanged because the original banner already used that.

## Follow-up

This is the **final ticket of [DOD-390](https://linear.app/dodihome/issue/DOD-390/keepur-ios-per-screen-migration-to-keepur-design-system)**. After this lands, every view in the app has been migrated. Possible epic follow-ups (separate, not in scope):
- macOS dark-mode `NSColor` adapter for `*Dynamic` color helpers.
- SVG `keepur-mark.svg` logo replacing `server.rack` SF Symbol on Pairing.
- Custom 3×4 keypad on Pairing per the kit's mock.
- Page-bg shade adjustment (`wax0` → `wax50`) if the user wants stronger visual differentiation from system white.
