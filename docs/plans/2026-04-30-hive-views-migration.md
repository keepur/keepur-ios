# Hive Views Migration Implementation Plan

> **For agentic workers:** Use `dodi-dev:implement` to execute this plan.

**Goal:** Migrate all 8 files in `Views/Team/` to consume `KeepurTheme` tokens. Final ticket of the per-screen migration epic (DOD-390).

**Architecture:** Eight-file rewrite, smallest first. No new components. No foundation changes.

**Spec:** [docs/specs/2026-04-30-hive-views-migration.md](../specs/2026-04-30-hive-views-migration.md) — implementer should keep this open while writing each file's rewrite. Each Task below references the relevant spec D-section instead of inlining the full snippet, since the spec already contains the canonical recipe.

**Tech Stack:** SwiftUI, MarkdownUI, AVFoundation. iOS 26.2+ / macOS 15.0+. No xcodeproj edits.

---

## File Map

| File | Spec sections | LOC |
|------|---------------|-----|
| `Views/Team/TeamSidebarView.swift` | D4 | 38 |
| `Views/Team/TeamRootView.swift` | D2, D3 | 52 |
| `Views/Team/AgentRow.swift` | D5 | 70 |
| `Views/Team/HivesGridView.swift` | D1 | 78 |
| `Views/Team/AgentVoicePickerView.swift` | D9 | 91 |
| `Views/Team/TeamMessageBubble.swift` | D7, D7.1 | 107 |
| `Views/Team/TeamChatView.swift` | D6 | 140 |
| `Views/Team/AgentDetailSheet.swift` | D8 | 192 |

Total: ~768 LOC.

---

## Task 1: Preflight verification

- [ ] **Step 1.1:** Worktree state.

```bash
pwd
git rev-parse --abbrev-ref HEAD
git log --oneline -2
```

Expected: `/Users/mayhuang/github/keepur-ios-DOD-399`, branch `DOD-399`, top commit is the spec.

- [ ] **Step 1.2:** Tokens resolve.

```bash
for sym in honey100 honey200 honey500 honey700 success warning danger fgPrimaryDynamic fgSecondaryDynamic fgTertiary fgMuted fgOnHoney bgPageDynamic bgSurfaceDynamic bgSunkenDynamic borderDefaultDynamic; do
  printf "Color.%-22s -> %s\n" "$sym" "$(grep -c "let $sym" Theme/KeepurTheme.swift)"
done
for sym in h3 h4 body bodySm caption eyebrow lsH3 lsEyebrow; do
  printf "Font.%-23s -> %s\n" "$sym" "$(grep -c "let $sym" Theme/KeepurTheme.swift)"
done
for sym in s1 s2 s3 s4; do
  printf "Spacing.%-20s -> %s\n" "$sym" "$(grep -c "let $sym:" Theme/KeepurTheme.swift)"
done
for sym in sm md lg; do
  printf "Radius.%-21s -> %s\n" "$sym" "$(grep -c "let $sym:" Theme/KeepurTheme.swift)"
done
for sym in mono; do
  printf "FontName.%-19s -> %s\n" "$sym" "$(grep -c "let $sym " Theme/KeepurTheme.swift)"
done
echo "keepurBorder:"
grep -c "func keepurBorder" Theme/KeepurTheme.swift
```

Expected: every count ≥ 1.

- [ ] **Step 1.3:** No tests reference these views.

```bash
grep -rln "TeamSidebar\|TeamRoot\|AgentRow\|HivesGrid\|AgentVoicePicker\|TeamMessageBubble\|TeamChat\|AgentDetail" KeeperTests/ 2>/dev/null || echo "(no matches)"
```

Expected: `(no matches)`.

- [ ] **Step 1.4:** No commit.

---

## Task 2: Rewrite all 8 files

Implement each file end-to-end against the spec's recipe. Each file is a complete rewrite — preserve all behavior, swap all styling values.

- [ ] **Step 2.1:** `Views/Team/TeamSidebarView.swift` per spec D4. Add `.scrollContentBackground(.hidden)` + `.background(KeepurTheme.Color.bgPageDynamic)` to the List. Empty-state ContentUnavailableView stays system styling.

- [ ] **Step 2.2:** `Views/Team/TeamRootView.swift` per spec D2 (disconnected banner) + D3 (status dot). Outer `VStack(spacing: 0)`, NavigationSplitView, ContentUnavailableView ("Select an agent") all preserved structurally.

- [ ] **Step 2.3:** `Views/Team/AgentRow.swift` per spec D5. Status switch: `idle → success`, `processing → warning`, `error/stopped → danger`, default → `fgMuted`. Text rows use `Font.body`/`Font.caption`/`Font.caption` with `fgPrimaryDynamic`/`fgSecondaryDynamic`/`fgTertiary`. HStack outer spacing = `Spacing.s3`.

- [ ] **Step 2.4:** `Views/Team/HivesGridView.swift` per spec D1. Hexagon icon = `honey500`. HiveCard background = `bgSurfaceDynamic` with `keepurBorder`, `Radius.md`. Text uses `Font.h4` + `fgPrimaryDynamic`. Outer Group adopts `bgPageDynamic` background (apply to the `Group { ... }` not the `ContentUnavailableView` branch).

- [ ] **Step 2.5:** `Views/Team/AgentVoicePickerView.swift` per spec D9 (mirrors Settings DOD-392 D5). Add `.scrollContentBackground(.hidden) + .background(bgPageDynamic)` to List. `Section("Voices")` becomes `Section { ... } header: { eyebrowHeader("VOICES") }` with the eyebrow helper inlined as a private function. Drop outer `.foregroundStyle(.primary)` on each Button. Checkmark = `Color.honey500`. Row backgrounds = `bgSurfaceDynamic`.

- [ ] **Step 2.6:** `Views/Team/TeamMessageBubble.swift` per spec D7 + D7.1. Three variants:
  - **userBubble**: identical to MessageBubble's userBubble (DOD-394 D1) — honey-500 + fgOnHoney + asymmetric 6pt tail. "sending" badge from D7.1 (amber `honey200` capsule + charcoal text + 0.9s pulse).
  - **agentBubble**: sender name eyebrow above bubble (`Font.caption` + `fgSecondaryDynamic`, NOT uppercased — sender names are user data). Markdown body in `bgSunkenDynamic` with `Radius.lg`. Speaker button per MessageBubble D7.
  - **systemBubble**: identical to MessageBubble's systemBubble (D4).
  - Timestamps uniform: `Font.caption` + `fgTertiary`.

- [ ] **Step 2.7:** `Views/Team/TeamChatView.swift` per spec D6. Toolbar speaker button mirrors ChatView (DOD-395 D9): `danger` when speaking, `honey500` when auto-read on, `fgSecondaryDynamic` otherwise. "Load earlier messages" button = `Font.caption` + `fgSecondaryDynamic` + `Spacing.s2` vertical padding. LazyVStack spacing = `Spacing.s3`, padding `s4`/`s3`. ProgressView and `info.circle` toolbar button stay system.

- [ ] **Step 2.8:** `Views/Team/AgentDetailSheet.swift` per spec D8. Largest file — work in this order:
  1. Status switch identical to AgentRow D5.
  2. Header: emoji icon stays at `.system(size: 48)`. Name = `Font.h3` + `lsH3` + `fgPrimaryDynamic`. Status row: dot (semantic) + `Font.bodySm` + `fgSecondaryDynamic`.
  3. `infoRow(label:value:)` and `infoRow(label:date:)` — both overloads use `Font.bodySm`, `Spacing.s4`/`Spacing.s2 + 2` (16/10pt) paddings, `fgSecondaryDynamic` label / `fgPrimaryDynamic` value.
  4. Info grid wrapper: `bgSurfaceDynamic` + `Radius.sm`.
  5. `sectionCard` generic helper: title becomes eyebrow (`Font.eyebrow` + `lsEyebrow` + `fgSecondaryDynamic` + `textCase(nil)`). Card body padding `Spacing.s4`, background `bgSurfaceDynamic`, `Radius.sm`. Title strings at call sites uppercase to "TOOLS" / "SCHEDULE" / "CHANNELS".
  6. Cron strings inside Schedule section flip to `Font.custom(KeepurTheme.FontName.mono, size: 12)` + `fgSecondaryDynamic`.
  7. Voice navigation row: eyebrow "VOICE" label + `currentVoiceLabel` body + chevron. Same wax-surface card. `chevron.right` stays inline literal.
  8. Outer ScrollView background = `bgPageDynamic`.

- [ ] **Step 2.9:** Build for iOS.

```bash
xcodebuild build -project Keepur.xcodeproj -scheme Keepur \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -quiet 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 2.10:** Build for macOS.

```bash
xcodebuild build -project Keepur.xcodeproj -scheme Keepur \
  -destination 'platform=macOS' \
  -quiet 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 2.11:** iOS unit tests.

```bash
set -o pipefail
xcodebuild test -project Keepur.xcodeproj -scheme Keepur \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:KeeperTests \
  -quiet > /tmp/dod-399-ios-test.log 2>&1
echo "EXIT=$?"
echo "passed: $(grep -c 'passed on' /tmp/dod-399-ios-test.log)"
echo "failed: $(grep -c 'failed on' /tmp/dod-399-ios-test.log)"
```

Expected: `EXIT=0`, `failed: 0`.

- [ ] **Step 2.12:** macOS unit tests.

```bash
set -o pipefail
xcodebuild test -project Keepur.xcodeproj -scheme Keepur \
  -destination 'platform=macOS' \
  -only-testing:KeeperTests \
  -quiet \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  > /tmp/dod-399-mac-test.log 2>&1
echo "EXIT=$?"
echo "passed: $(grep -c 'passed on' /tmp/dod-399-mac-test.log)"
echo "failed: $(grep -c 'failed on' /tmp/dod-399-mac-test.log)"
```

Expected: `EXIT=0`, `failed: 0`.

- [ ] **Step 2.13:** Single commit covering all 8 file rewrites.

```bash
git add Views/Team/
git commit -m "$(cat <<'EOF'
feat: migrate Hive (Team) views to KeepurTheme tokens (DOD-399)

Final migration of epic DOD-390. Eight files in Views/Team/ —
every Hive surface from hexagon hive cards to agent detail sheets
to team message bubbles.

Visible changes:
- HivesGridView: hexagon icons in honey-500, wax-surface cards
  with wax-200 border (was .accentColor + .regularMaterial)
- TeamRootView disconnected banner: amber wash (honey100) with
  warning icon + charcoal text + honey-700 Retry (was orange)
- TeamRootView status dot: success/danger semantic
- AgentRow status dot: idle=success, processing=warning,
  error/stopped=danger, default=fgMuted (was green/yellow/red/gray)
- TeamMessageBubble user bubble: honey-500 + charcoal text +
  6pt tail (matches MessageBubble from DOD-394)
- TeamMessageBubble agent bubble: wax sunken surface + sender
  name eyebrow above
- TeamMessageBubble "sending" badge: amber capsule (was gray)
- TeamChatView toolbar speaker button: danger/honey/secondary per
  state (mirrors ChatView from DOD-395)
- AgentDetailSheet header: status dot semantic, h3 typography
- AgentDetailSheet info grid + section cards: wax-surface cards
  with eyebrow titles (TOOLS / SCHEDULE / CHANNELS / VOICE),
  cron strings in JetBrains Mono
- AgentVoicePickerView: honey checkmark on selected voice
  (mirrors Settings voice picker from DOD-392)

No behavior changes. Status switch logic, message bubble routing,
loadHistory + scroll-to-bottom, agent detail sheet trigger,
autoReadAloud UserDefaults binding, per-agent voice routing,
ISO date formatter fallback, sectionCard generic, infoRow String
and Date overloads, hive selection navigation all preserved.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Final regression sweep

- [ ] **Step 3.1:** Confirm clean tree, 3 commits ahead of main.

```bash
git status --short
git log --oneline main..HEAD
```

Expected: empty status, 3 commits (spec + plan + Hive views rewrite).
