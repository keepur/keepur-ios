# Design v2 backlog (to be re-filed in Keepur Linear org as KPR-*)

**Why this file exists:** these 19 tickets were originally filed in the dodihome Linear workspace as DOD-400 through DOD-418. That was wrong — Keepur is a separate Linear organization (KPR-*), and the OAuth scope from this session only saw dodihome. The DOD-400–418 tickets have been cancelled. Re-file these in the Keepur workspace when MCP auth is wired against it.

**Source mockups:** chat history with the Keepur design team, late April / early May 2026.

**Naming convention assumed:** all tickets use the prefix `design v2:` for the visual epic, `feature:` for the held-features epic.

---

## Parent epic 1 — design v2 (UI/UX refinement post-theming)

### KPR-?: keepur-ios: design v2 — UI/UX refinement (post-theming)

The design system theming epic shipped tokens + retoken. Every view consumes `KeepurTheme.*`. But the mockups for "design v2" go further — they introduce new component primitives, an architecture change (TabBar root with 4 tabs), and meaningfully different per-screen layouts.

This epic covers **visual + structural design changes only**. New features hiding inside mockups (unread counts, delivered status, spoken indicator, streaming visual, camera capture) are tracked separately under a sibling "missing chat surface features" epic and are *not* prerequisites for design v2 — design v2 ships with empty/static placeholders for those affordances and adopts them when the feature work lands.

**Three layers, in order:**

- **Layer 1 — Foundation primitives** (3 tickets, additions only). Pre-extract the 8 reusable components that recur across the mockups. No view changes.
- **Layer 2 — Architecture** (1 ticket, blocks per-screen work). TabBar root with 4 tabs.
- **Layer 3 — Per-screen consumption** (8 tickets). Mirror the per-screen migration cadence from the theming epic.

**Brand recipes already established (don't relitigate):**
- Honey (`#F5A524`) is the only accent
- Wax warm neutrals + charcoal text
- SF for UI, JetBrains Mono for identifiers
- `KeepurPrimaryButtonStyle` / `KeepurDestructiveButtonStyle` for full-width CTAs
- Eyebrow section headers with letterspacing
- Semantic colors: success/warning/danger/honey

**Out of scope:** anything in the held-features epic (sibling ticket).

---

### Layer 1 — Foundation primitives

#### KPR-?: design v2: foundation atoms — KeepurAvatar + KeepurStatusPill + KeepurUnreadBadge

Pure additions to `Theme/Components/`. No view changes.

**Components:**
1. `KeepurAvatar` — square rounded container (configurable size: 24/40/56/60pt) with letter or emoji content. Optional bottom-right `statusOverlay` (8pt circle with semantic color).
2. `KeepurStatusPill` — capsule with semantic-tinted background + matching text color. Variants: `Connected`/`Idle`/`Active`/`Stale`/`Thinking` via tint parameter.
3. `KeepurUnreadBadge` — small honey capsule with white digit. Hides when count=0.

**Acceptance:** all three exist in `Theme/Components/`, wired into Xcode project, smoke-tested. No existing view changes.

---

#### KPR-?: design v2: foundation data display — KeepurChipCluster + KeepurMetricGrid + KeepurCard

**Components:**
1. `KeepurChipCluster` — wrapping flow-layout container of small pill chips. Supports `+N` overflow. Used for Tools, Channels.
2. `KeepurMetricGrid` — 3-column horizontal grid for label/value pairs (MODEL / MESSAGES / LAST ACTIVE). Eyebrow label above value.
3. `KeepurCard` — rounded wax surface container with optional 1px border. Used by Settings sections, Agent Info chunks, Saved Workspaces rows.

**Acceptance:** all three exist, wired into Xcode project, smoke-tested. `KeepurChipCluster` correctly handles `+N` overflow.

---

#### KPR-?: design v2: foundation composites — KeepurActionSheet + KeepurChatHeader

**Components:**
1. `KeepurActionSheet` — branded bottom-sheet replacement for popovers. Title + subtitle + N action rows (icon container + title + subtitle + chevron).
2. `KeepurChatHeader` — toolbar/header showing: circular back button, title with status line beneath ("● working · 2m ago"), trailing circular action buttons (mute, info).

**Acceptance:** both exist, wired into Xcode project. `KeepurActionSheet` is a reusable sheet `View`; `KeepurChatHeader` drops into existing `.toolbar { }` blocks.

---

### Layer 2 — Architecture

#### KPR-?: design v2: TabBar root architecture (Beekeeper / Hive / Sessions / Settings)

**Blocks all per-screen consumption tickets.**

Restructure app root from current single `NavigationStack(SessionListView)` to:

```swift
TabView {
    BeekeeperRootView()     // Coming soon placeholder
        .tabItem { Label("Beekeeper", systemImage: "<TBD>") }
    HivesGridView(...)
        .tabItem { Label("Hive", systemImage: "hexagon.fill") }
    SessionListView(...)
        .tabItem { Label("Sessions", systemImage: KeepurTheme.Symbol.chat) }
    SettingsView(...)
        .tabItem { Label("Settings", systemImage: KeepurTheme.Symbol.settings) }
}
```

**Tab semantics:**
- **Beekeeper**: direct interaction with the Beekeeper backend. Future content (placeholder for now — actual surface is its own future ticket).
- **Hive**: existing Hives grid + Team UI stays. Move root entry into this tab.
- **Sessions**: existing Sessions list moves under this tab.
- **Settings**: becomes "global" settings (beekeeper URL, user, device name). Promotes from gear button to top-level tab.

**Out of scope:** Beekeeper tab content (placeholder), Settings restructure to "global" semantics (own follow-up), deep-linking between tabs.

**Acceptance:** app launches into TabView root, all four tabs render, sheet flows still work, honey accent on selected tab.

---

### Layer 3 — Per-screen consumption

#### KPR-?: design v2: Sessions row + list redesign

- Drop the 44pt circular avatar — sessions row no longer has a leading icon.
- Session name in body weight; status as `KeepurStatusPill` inline (Active / Stale).
- Path beneath name in JetBrains Mono caption.
- Last-message preview line if present.
- Trailing relative time + tertiary tone.
- Cleaner divider; no full-bleed grouped style.

**Depends on:** foundation atoms (`KeepurStatusPill`), TabBar (Sessions tab landing).
**Out of scope:** unread badge (held feature ticket).

---

#### KPR-?: design v2: Settings card-grouped sections

- Wrap each `Section { ... }` content in a `KeepurCard` (rounded wax surface with 1px border). Eyebrow header stays above the card.
- Status text colored by semantic ("Connected" in `Color.success`).
- Saved Workspaces row gets a chevron (becomes navigation destination).
- Voice rows tap target = full row.

**Depends on:** foundation data display (`KeepurCard`), TabBar.
**Out of scope:** Saved Workspaces detail content, restructure to "global settings" semantics.

---

#### KPR-?: design v2: Hive sidebar agent rows (square avatars + corner status)

- Replace circular avatar with `KeepurAvatar` (~56pt square rounded with letter, status overlay in bottom-right).
- Title becomes the actual hive name (e.g., "hive-dodi") — currently `selectedHive ?? "Hive"`.
- Trailing relative time when DM exists.
- Empty `KeepurUnreadBadge` placeholder slot — wired to `0` for now.

**Depends on:** foundation atoms (`KeepurAvatar` + `KeepurUnreadBadge`).
**Out of scope:** real unread count (held feature ticket).

---

#### KPR-?: design v2: Agent detail half-sheet (metric grid + chips + status pill)

- Header: square `KeepurAvatar` (60pt) + name in display tier + status as `KeepurStatusPill`.
- Replace 4-row info card with `KeepurMetricGrid` showing 3 columns (MODEL / MESSAGES / LAST ACTIVE).
- Tools / Channels become `KeepurChipCluster` (with `+N` overflow).
- Schedule entries: cron in JetBrains-Mono pill chip + plain task label.
- Voice navigation row stays; minor refinement.
- Sheet detents: medium first, expandable to large.

**Depends on:** foundation atoms, foundation data display.
**Out of scope:** real-time agent status updates (existing reactivity preserved).

---

#### KPR-?: design v2: Chat header redesign (avatar + status line + circular toolbar)

Apply to `Views/ChatView.swift` (Claude Code sessions) and `Views/Team/TeamChatView.swift` (agent DMs).

- Replace `navigationTitle(...)` + system back arrow with `KeepurChatHeader`: circular back chevron, title with status line beneath, circular trailing actions (mute, info).
- Status line under title shows agent state + relative last activity (DM context) or session state (Claude Code context).

**Depends on:** foundation composites (`KeepurChatHeader`).
**Out of scope:** mute toggle behavior (existing speaker button relocated/restyled).

---

#### KPR-?: design v2: Chat error message bubble variant

- New `MessageBubble` variant for `message.role == "error"` (verify the data model first).
- Card style: thin red border + light red tint background (`Color.danger.opacity(0.08)`) + `Radius.md`.
- "ERROR" eyebrow at top in `Color.danger`.
- Error text in JetBrains Mono.
- Trailing timestamp.
- Inline "Retry" outline button (small, bordered with `Color.danger` tint).

**Apply to:** `Views/MessageBubble.swift`. Verify whether team-side errors take the same path.

**Open question:** where do error messages currently come from? `Message` SwiftData model with `role: "error"`, or surfaced separately on the ViewModel? Inspect before sizing.

---

#### KPR-?: design v2: Attach action sheet (rich bottom sheet)

- Replace popover with `KeepurActionSheet` (medium detent).
- Title: "Attach". Subtitle: "Add a file or photo to the message."
- Three action rows:
  - **Choose file** — doc icon (honey-tinted container), subtitle "Browse documents on this device".
  - **Photo library** — photo icon, subtitle "Pick from your photos".
  - **Take photo** — camera icon, subtitle "Use the camera now". **Wired to placeholder alert** until held feature ticket lands.
- Each row: leading icon container (~40pt square rounded honey-100 with honey-700 icon), title, subtitle, trailing chevron.

**Depends on:** foundation composites (`KeepurActionSheet`).
**Out of scope:** actual camera capture (held feature ticket).

---

#### KPR-?: design v2: TeamMessageBubble polish (mini avatar)

Smaller scope — most chat polish lands via header redesign + error bubble + DOD-395 (chat chrome).

- Agent bubble: instead of plain sender-name eyebrow, show a mini `KeepurAvatar` (~24pt square) below the bubble, alongside timestamp.
- Maintain three-variant routing (system / user / agent).

**Depends on:** foundation atoms (`KeepurAvatar`).
**Out of scope:** "Spoken" indicator (held), "Delivered" status (held), streaming honey lightning bolt (held design ticket).

---

## Parent epic 2 — Held chat surface features (deferred from design v2)

### KPR-?: keepur-ios: chat surface features (deferred from design v2)

Sibling epic to design v2. The design v2 mockups smuggle in five feature additions disguised as styling — they require backend / state work that isn't a fit for the design v2 epic.

Each child is a real product feature, not paint. Design v2 ships placeholders/no-ops for these affordances; when each lands, the corresponding design surface gets wired up.

---

#### KPR-?: feature: per-channel unread count tracking

The Hive sidebar mockup shows an unread count badge (honey pill with "2"). The `KeepurUnreadBadge` foundation provides the visual; this ticket provides the count.

**Scope:**
- Add per-channel `unreadCount` tracking to `TeamChannel` SwiftData model.
- Increment on incoming message when channel is not active.
- Reset to 0 when user opens the channel.
- Persist across app launches.
- Surface to `TeamSidebarView` so `AgentRow` renders the count.

**Open questions:** server-side last-read pointer? Multi-device sync?

**Acceptance:** new unread → badge appears, open channel → clears, restart → persists.

---

#### KPR-?: feature: user message delivery state ("Delivered")

Chat mockup shows "Delivered" status under user message timestamps. Today: only `pending` (sending badge).

**Scope:**
- Track lifecycle on `Message` / `TeamMessage`: `sending` → `delivered` → (later) `read`?
- WebSocket protocol: server should ack delivery.
- Render below user message timestamp in `MessageBubble.userBubble` and `TeamMessageBubble.userBubble`.

**Open questions:** does Beekeeper currently emit delivery acks? Read receipts in scope or separate?

**Acceptance:** sent → "Sending" → "Delivered". Network failure → visible state.

---

#### KPR-?: feature: TTS "spoken" message indicator

Chat mockup shows "🔊 Spoken" affordance under agent messages already read aloud.

**Scope:**
- Track which message IDs have been spoken by `SpeechManager` (per device, per agent).
- Persist (UserDefaults or new SwiftData column).
- Render speaker icon + "Spoken" below agent message timestamps when true.
- Bonus: tap-to-replay.

**Open questions:** cleanup policy? Multi-device sync?

**Acceptance:** auto-read or manual-tap → indicator appears, persists across launches.

---

#### KPR-?: feature: camera capture in attachment picker (Take photo)

The attach action sheet shows three rows: Choose file / Photo library / **Take photo**. We only support the first two today.

**Scope:**
- Add camera capture path using `UIImagePickerController` (iOS).
- macOS: hide row OR use `AVCaptureSession`. Hide is simpler.
- Permission flow: `NSCameraUsageDescription` in `Info.plist`, runtime request.
- Captured image flows through `AttachmentData` to `pendingAttachment`.
- Same 10MB cap.

**Open questions:** macOS strategy? Edit/crop after capture?

**Acceptance:** tap → camera opens, capture → pending attachment, permission denied → graceful explanation.

---

#### KPR-?: design: streaming-state visual indicator (replace lightning bolt)

The chat mockup shows a static **honey lightning bolt** at the end of an agent message indicating "this is currently streaming." Twee and undecipherable without a label.

**Scope (design + ship):**
1. Pulsing dot at message tail (like iMessage typing indicator at end of streamed text)
2. Border pulse — subtle 1px honey border that pulses while streaming
3. Caret cursor at end of text (mimics terminal cursor — fits brand)
4. No visible indicator — rely on existing `StatusIndicator` ("thinking" dots)

Recommendation: pick (3) or (4).

**Out of scope:** backend streaming protocol (already exists per DOD-389 spec).

**Acceptance:** streaming visually distinct from "done" without user explanation. Works on `MessageBubble.assistantBubble` and `TeamMessageBubble.agentBubble`.
