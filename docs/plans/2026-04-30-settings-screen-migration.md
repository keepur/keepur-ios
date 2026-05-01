# Settings Screen Migration Implementation Plan

> **For agentic workers:** Use `dodi-dev:implement` to execute this plan.

**Goal:** Migrate `Views/SettingsView.swift` to consume `KeepurTheme` tokens with brand surfaces — wax page bg, eyebrow section headers, JetBrains Mono identifiers, semantic status dot colors, honey voice checkmark. No behavior changes, no new components.

**Architecture:** Single-file rewrite. The existing `NavigationStack { List { Section { ... } } }` shape stays intact. Each `Section("…")` becomes `Section { rows } header: { eyebrowHeader("…") }` where `eyebrowHeader` is a small private helper. The `List` gets `.scrollContentBackground(.hidden).background(KeepurTheme.Color.bgPageDynamic)` to expose a wax page background, and rows get `.listRowBackground(KeepurTheme.Color.bgSurfaceDynamic)` for consistent wax surface tone. Row buttons (Disconnect/Reconnect/Unpair) stay system-styled per spec D7 — no `KeepurDangerButtonStyle` extracted.

**Tech Stack:** SwiftUI, SwiftData, AVFoundation. iOS 26.2+ / macOS 15.0+. No xcodeproj edits — no new files.

**Spec:** [docs/specs/2026-04-30-settings-screen-migration.md](../specs/2026-04-30-settings-screen-migration.md)

**Out of scope:** Component extraction, button-style work, dark-mode `NSColor` adapter, copy changes.

---

## File Map

| File | Change |
|------|--------|
| `Views/SettingsView.swift` | **Rewrite** — same surface, all values from `KeepurTheme.*`, eyebrow headers, wax bg |

That's it. No new files, no project.pbxproj edits.

---

## Task 1: Preflight verification

**Files:** none

- [ ] **Step 1.1:** Confirm worktree state.

```bash
pwd
git rev-parse --abbrev-ref HEAD
git log --oneline -3
```

Expected: `/Users/mayhuang/github/keepur-ios-DOD-392`, branch `DOD-392`, top commit is the spec, parent `2caaeab` is the Pairing merge.

- [ ] **Step 1.2:** Confirm every cited token exists.

```bash
for sym in success danger honey500 bgPageDynamic bgSurfaceDynamic fgPrimaryDynamic fgSecondaryDynamic; do
  printf "Color.%-22s -> %s\n" "$sym" "$(grep -c "let $sym" Theme/KeepurTheme.swift)"
done
for sym in eyebrow caption lsEyebrow; do
  printf "Font.%-23s -> %s\n" "$sym" "$(grep -c "let $sym" Theme/KeepurTheme.swift)"
done
for sym in mono; do
  printf "FontName.%-19s -> %s\n" "$sym" "$(grep -c "let $sym " Theme/KeepurTheme.swift)"
done
for sym in check; do
  printf "Symbol.%-21s -> %s\n" "$sym" "$(grep -c "let $sym " Theme/KeepurTheme.swift)"
done
```

Expected: every count is at least `1`. `FontName.mono` returns `2` (collides with `Font.mono`); `Font.body` would return `2` if checked but isn't used here. Treat `0` as a blocker.

- [ ] **Step 1.3:** Confirm no SettingsView unit tests would break.

```bash
grep -rln "SettingsView" KeeperTests/ 2>/dev/null || echo "(no matches)"
```

Expected: `(no matches)`.

- [ ] **Step 1.4:** No commit. Surface results to user.

---

## Task 2: Rewrite `Views/SettingsView.swift`

**Files:**
- Modify: `Views/SettingsView.swift` (full rewrite, same surface, same behavior)

- [ ] **Step 2.1:** Replace the entire file contents.

```swift
import SwiftUI
import SwiftData
import AVFoundation

struct SettingsView: View {
    @ObservedObject var viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showUnpairConfirmation = false
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Workspace.lastUsed, order: .reverse) private var savedWorkspaces: [Workspace]

    private var englishVoices: [AVSpeechSynthesisVoice] {
        let voices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.lowercased().hasPrefix("en") }
        return voices.sorted { (lhs: AVSpeechSynthesisVoice, rhs: AVSpeechSynthesisVoice) -> Bool in
            if lhs.quality.rawValue != rhs.quality.rawValue {
                return lhs.quality.rawValue > rhs.quality.rawValue
            }
            return lhs.name < rhs.name
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Text("Name")
                            .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
                        Spacer()
                        Text(KeychainManager.deviceName ?? "Unknown")
                            .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                    }
                    .listRowBackground(KeepurTheme.Color.bgSurfaceDynamic)

                    if let deviceId = KeychainManager.deviceId {
                        HStack {
                            Text("Device ID")
                                .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
                            Spacer()
                            Text(String(deviceId.prefix(8)))
                                .font(.custom(KeepurTheme.FontName.mono, size: 12))
                                .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                        }
                        .listRowBackground(KeepurTheme.Color.bgSurfaceDynamic)
                    }
                } header: {
                    eyebrowHeader("DEVICE")
                }

                Section {
                    HStack {
                        Text("Status")
                            .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
                        Spacer()
                        HStack(spacing: 6) {
                            Circle()
                                .fill(viewModel.ws.isConnected ? KeepurTheme.Color.success : KeepurTheme.Color.danger)
                                .frame(width: 8, height: 8)
                            Text(viewModel.ws.isConnected ? "Connected" : "Disconnected")
                                .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                        }
                    }
                    .listRowBackground(KeepurTheme.Color.bgSurfaceDynamic)

                    if let sessionId = viewModel.currentSessionId {
                        HStack {
                            Text("Session")
                                .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
                            Spacer()
                            Text(String(sessionId.prefix(8)))
                                .font(.custom(KeepurTheme.FontName.mono, size: 12))
                                .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                        }
                        .listRowBackground(KeepurTheme.Color.bgSurfaceDynamic)
                    }

                    if !viewModel.currentPath.isEmpty {
                        HStack {
                            Text("Workspace")
                                .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
                            Spacer()
                            Text(viewModel.currentPath)
                                .font(.custom(KeepurTheme.FontName.mono, size: 12))
                                .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                                .lineLimit(1)
                        }
                        .listRowBackground(KeepurTheme.Color.bgSurfaceDynamic)
                    }
                } header: {
                    eyebrowHeader("CONNECTION")
                }

                if !savedWorkspaces.isEmpty {
                    Section {
                        ForEach(savedWorkspaces, id: \.path) { workspace in
                            VStack(alignment: .leading) {
                                Text(workspace.displayName)
                                    .font(KeepurTheme.Font.body)
                                    .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
                                Text(workspace.path)
                                    .font(KeepurTheme.Font.caption)
                                    .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                            }
                            .listRowBackground(KeepurTheme.Color.bgSurfaceDynamic)
                        }
                        .onDelete { offsets in
                            for index in offsets {
                                modelContext.delete(savedWorkspaces[index])
                            }
                            try? modelContext.save()
                        }
                    } header: {
                        eyebrowHeader("SAVED WORKSPACES")
                    }
                }

                Section {
                    ForEach(englishVoices, id: \.identifier) { voice in
                        voiceRow(voice)
                            .listRowBackground(KeepurTheme.Color.bgSurfaceDynamic)
                    }
                } header: {
                    eyebrowHeader("VOICE")
                }

                Section {
                    Button(viewModel.ws.isConnected ? "Disconnect" : "Reconnect") {
                        if viewModel.ws.isConnected {
                            viewModel.ws.disconnect()
                        } else {
                            viewModel.ws.connect()
                        }
                    }
                    .listRowBackground(KeepurTheme.Color.bgSurfaceDynamic)

                    Button("Unpair Device", role: .destructive) {
                        showUnpairConfirmation = true
                    }
                    .listRowBackground(KeepurTheme.Color.bgSurfaceDynamic)
                    .confirmationDialog(
                        "Unpair this device?",
                        isPresented: $showUnpairConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button("Unpair", role: .destructive) {
                            viewModel.unpair()
                            dismiss()
                        }
                    } message: {
                        Text("You will need a new pairing code from your admin to reconnect.")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(KeepurTheme.Color.bgPageDynamic)
            .navigationTitle("Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Eyebrow header

    private func eyebrowHeader(_ title: String) -> some View {
        Text(title)
            .font(KeepurTheme.Font.eyebrow)
            .tracking(KeepurTheme.Font.lsEyebrow)
            .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
            .textCase(nil)
    }

    @ViewBuilder
    private func voiceRow(_ voice: AVSpeechSynthesisVoice) -> some View {
        Button {
            viewModel.speechManager.selectedVoiceId = voice.identifier
            let preview = "Hello, I'm " + voice.name + "."
            viewModel.speechManager.speak(preview)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(voice.name)
                        .font(KeepurTheme.Font.body)
                        .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
                    Text(qualityLabel(voice.quality))
                        .font(KeepurTheme.Font.caption)
                        .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                }
                Spacer()
                if viewModel.speechManager.selectedVoiceId == voice.identifier {
                    Image(systemName: KeepurTheme.Symbol.check)
                        .foregroundStyle(KeepurTheme.Color.honey500)
                }
            }
        }
    }

    private func qualityLabel(_ quality: AVSpeechSynthesisVoiceQuality) -> String {
        switch quality {
        case .premium: return "Premium"
        case .enhanced: return "Enhanced"
        default: return "Default"
        }
    }
}
```

Notes on the rewrite vs. main:
- Every `Section("Title")` → `Section { rows } header: { eyebrowHeader("TITLE") }`. Section titles are uppercased in the source string; `textCase(nil)` in the helper prevents iOS double-uppercasing.
- Every row gets `.listRowBackground(KeepurTheme.Color.bgSurfaceDynamic)` to create a uniform wax-surface row tone against the wax-page bg.
- Identifier values (Device ID, Session ID, workspace path) flip from SF Mono to JetBrains Mono via `.font(.custom(KeepurTheme.FontName.mono, size: 12))`.
- Status dot uses `KeepurTheme.Color.success` / `Color.danger` instead of `.green`/`.red`.
- Voice checkmark uses `KeepurTheme.Symbol.check` + `Color.honey500`.
- All `.foregroundStyle(.secondary)` → `KeepurTheme.Color.fgSecondaryDynamic`; explicit `KeepurTheme.Color.fgPrimaryDynamic` on row labels.
- Voice row's outer `.foregroundStyle(.primary)` is removed — the inner `Text` views now carry their own explicit colors, so the outer modifier was redundant.
- Buttons (Disconnect/Reconnect/Unpair, Done) stay system-styled per spec D7/D8.
- All behavior is identical: confirmation dialog, swipe-to-delete, voice tap-to-preview, dismiss, ws connect/disconnect, unpair.

- [ ] **Step 2.2:** Build for iOS.

```bash
xcodebuild build -project Keepur.xcodeproj -scheme Keepur \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -quiet 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`. The pre-existing WebSocketManager.swift Swift 6 warning is harmless.

- [ ] **Step 2.3:** Build for macOS.

```bash
xcodebuild build -project Keepur.xcodeproj -scheme Keepur \
  -destination 'platform=macOS' \
  -quiet 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 2.4:** Run iOS unit tests.

```bash
set -o pipefail
xcodebuild test -project Keepur.xcodeproj -scheme Keepur \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:KeeperTests \
  -quiet > /tmp/dod-392-ios-test.log 2>&1
echo "EXIT=$?"
echo "passed: $(grep -c 'passed on' /tmp/dod-392-ios-test.log)"
echo "failed: $(grep -c 'failed on' /tmp/dod-392-ios-test.log)"
```

Expected: `EXIT=0`, `failed: 0`.

- [ ] **Step 2.5:** Run macOS unit tests.

```bash
set -o pipefail
xcodebuild test -project Keepur.xcodeproj -scheme Keepur \
  -destination 'platform=macOS' \
  -only-testing:KeeperTests \
  -quiet \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  > /tmp/dod-392-mac-test.log 2>&1
echo "EXIT=$?"
echo "passed: $(grep -c 'passed on' /tmp/dod-392-mac-test.log)"
echo "failed: $(grep -c 'failed on' /tmp/dod-392-mac-test.log)"
```

Expected: `EXIT=0`, `failed: 0`.

- [ ] **Step 2.6:** Commit.

```bash
git add Views/SettingsView.swift
git commit -m "$(cat <<'EOF'
feat: migrate Settings screen to KeepurTheme tokens (DOD-392)

Visible changes:

- Wax page background (bgPageDynamic) replaces system grouped
- Wax-surface row backgrounds via listRowBackground
- Eyebrow-style section headers (Font.eyebrow + lsEyebrow tracking,
  textCase(nil) so already-uppercase strings aren't re-uppercased)
- JetBrains Mono Regular at 12pt for Device ID, Session ID, and
  current workspace path (was system caption / monospaced)
- Semantic colors for the connection status dot (Color.success /
  Color.danger replacing .green / .red)
- Honey accent on the selected-voice checkmark (replacing system
  blue)
- All foreground colors flow from fgPrimaryDynamic /
  fgSecondaryDynamic tokens

No behavior changes. Disconnect/Reconnect/Unpair stay as system
list-row buttons (.destructive's red is close enough to
Color.danger; List rows aren't full-width primary CTAs). Toolbar
Done button stays system-styled. Confirmation dialog, swipe-delete,
voice tap-to-preview, dismiss all preserved.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Visual diff (manual)

**Files:** none

- [ ] **Step 3.1:** Boot simulator and install.

```bash
APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData/Keepur-* -name "Keepur.app" -path "*Debug-iphonesimulator*" | head -1)
xcrun simctl install booted "$APP_PATH"
xcrun simctl launch booted io.keepur.Keepur
```

- [ ] **Step 3.2:** Open Settings (gear icon from Chat) and tick:

- [ ] Page background is wax (off-white, slightly warm — not the cool grouped-list gray)
- [ ] Section headers read in caps with letterspacing (eyebrow style), wax-700 color (not bold black)
- [ ] Row backgrounds are wax surface (not pure white) — visible contrast vs the page bg
- [ ] Device ID prefix renders in JetBrains Mono (square-tabular zeros — distinct from SF Mono)
- [ ] Session ID prefix and workspace path render in JetBrains Mono
- [ ] Connection dot is honey-green when connected (using `Color.success` semantic green) and the danger-red when disconnected
- [ ] Selected voice shows a honey-amber checkmark (not system blue)
- [ ] Saved workspace rows have the same wax surface tone
- [ ] Unpair button still appears red; tapping still opens the confirmation dialog
- [ ] Disconnect/Reconnect button still works

- [ ] **Step 3.3:** No commit.

---

## Task 4: Final regression sweep

- [ ] **Step 4.1:** Confirm clean tree and commit shape.

```bash
git status --short
git log --oneline main..HEAD
```

Expected: empty status, 2 commits ahead of main (spec + rewrite).

---

## Summary of commits this plan produces

1. (Spec already committed) `docs: design spec for Settings screen migration (DOD-392)`
2. `feat: migrate Settings screen to KeepurTheme tokens (DOD-392)` — Task 2

## After the plan

1. `/quality-gate`
2. `dodi-dev:review`
3. `dodi-dev:submit` — PR + cleanup, **no auto-merge**
