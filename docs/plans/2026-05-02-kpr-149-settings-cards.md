# KPR-149 — Settings card-grouped sections (Implementation Plan)

**Date:** 2026-05-02
**Spec:** [docs/specs/2026-05-02-kpr-149-settings-cards.md](../specs/2026-05-02-kpr-149-settings-cards.md)
**Ticket:** [KPR-149](https://linear.app/keepur/issue/KPR-149)

## Strategy

Single-file rewrite of `Views/SettingsView.swift` body content, plus one new private placeholder destination, plus one new test file with project wiring. The bulk of the diff is structural (`List`/`Section` → `ScrollView`/`LazyVStack`/`KeepurCard`), with three small affordance changes layered in the same pass. Eyebrow header helper, voice row helper, quality label helper, and unpair `confirmationDialog` move over verbatim.

Implementation order:
1. Sketch new container structure (header + card pairs) inside body.
2. Migrate Device card.
3. Migrate Connection card with semantic status text color.
4. Migrate Saved Workspaces card with `NavigationLink` chevron + placeholder destination.
5. Migrate Voice card with full-row tap target.
6. Migrate footer card.
7. Add placeholder destination struct.
8. Add smoke test for the placeholder destination.
9. Wire test file into Xcode project.
10. Build verification (iOS + macOS).
11. Run test suite.
12. Commit.

`Views/` is a synchronized folder group per CLAUDE.md, so the modified `SettingsView.swift` needs no project wiring.

## Steps

### Step 1: Replace outer container in `SettingsView.body`

**File:** `Views/SettingsView.swift`

Replace:
```swift
List {
    // five sections
}
.scrollContentBackground(.hidden)
.background(KeepurTheme.Color.bgPageDynamic)
```

with:
```swift
ScrollView {
    LazyVStack(alignment: .leading, spacing: KeepurTheme.Spacing.s5) {
        // five header + card pairs
    }
    .padding(.horizontal, KeepurTheme.Spacing.s4)
    .padding(.vertical, KeepurTheme.Spacing.s5)
}
.background(KeepurTheme.Color.bgPageDynamic)
```

Keep `NavigationStack`, `.navigationTitle("Settings")`, `#if os(iOS) .navigationBarTitleDisplayMode(.inline) #endif`, and the `.toolbar { ToolbarItem(.automatic) { Button("Done") { dismiss() } } }` block untouched.

**Verification:** file compiles after a stub `LazyVStack { Text("temp") }` placeholder — confirms the outer scaffold is correct before pouring content in.

### Step 2: Migrate DEVICE card

Inside the `LazyVStack`:

```swift
eyebrowHeader("DEVICE")
KeepurCard(bordered: true) {
    VStack(spacing: 0) {
        HStack {
            Text("Name").foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
            Spacer()
            Text(KeychainManager.deviceName ?? "Unknown")
                .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
        }
        .padding(.vertical, KeepurTheme.Spacing.s3)

        if let deviceId = KeychainManager.deviceId {
            Divider()
            HStack {
                Text("Device ID").foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
                Spacer()
                Text(String(deviceId.prefix(8)))
                    .font(.custom(KeepurTheme.FontName.mono, size: 12))
                    .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
            }
            .padding(.vertical, KeepurTheme.Spacing.s3)
        }
    }
}
```

Drop all `.listRowBackground(...)` modifiers — they're no-ops outside `List` and irrelevant when content is inside a `KeepurCard` whose own background is `bgSurfaceDynamic`.

**Verification:** card renders with eyebrow above it; build succeeds.

### Step 3: Migrate CONNECTION card with semantic status text color

```swift
eyebrowHeader("CONNECTION")
KeepurCard(bordered: true) {
    VStack(spacing: 0) {
        HStack {
            Text("Status").foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
            Spacer()
            HStack(spacing: 6) {
                Circle()
                    .fill(viewModel.ws.isConnected ? KeepurTheme.Color.success : KeepurTheme.Color.danger)
                    .frame(width: 8, height: 8)
                Text(viewModel.ws.isConnected ? "Connected" : "Disconnected")
                    .foregroundStyle(viewModel.ws.isConnected ? KeepurTheme.Color.success : KeepurTheme.Color.danger)
            }
        }
        .padding(.vertical, KeepurTheme.Spacing.s3)

        if let sessionId = viewModel.currentSessionId {
            Divider()
            HStack {
                Text("Session").foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
                Spacer()
                Text(String(sessionId.prefix(8)))
                    .font(.custom(KeepurTheme.FontName.mono, size: 12))
                    .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
            }
            .padding(.vertical, KeepurTheme.Spacing.s3)
        }

        if !viewModel.currentPath.isEmpty {
            Divider()
            HStack {
                Text("Workspace").foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
                Spacer()
                Text(viewModel.currentPath)
                    .font(.custom(KeepurTheme.FontName.mono, size: 12))
                    .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                    .lineLimit(1)
            }
            .padding(.vertical, KeepurTheme.Spacing.s3)
        }
    }
}
```

Note the only behavioral change vs. today: status text foreground switches from `fgSecondaryDynamic` to `success`/`danger` to match the dot semantic per spec.

**Verification:** when WebSocket is connected the word "Connected" renders in green; when disconnected, "Disconnected" renders in red.

### Step 4: Migrate SAVED WORKSPACES card with NavigationLink chevron + destination

```swift
if !savedWorkspaces.isEmpty {
    eyebrowHeader("SAVED WORKSPACES")
    KeepurCard(bordered: true) {
        VStack(spacing: 0) {
            ForEach(Array(savedWorkspaces.enumerated()), id: \.element.path) { index, workspace in
                NavigationLink {
                    SavedWorkspacesPlaceholderView()
                } label: {
                    VStack(alignment: .leading) {
                        Text(workspace.displayName)
                            .font(KeepurTheme.Font.body)
                            .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
                        Text(workspace.path)
                            .font(KeepurTheme.Font.caption)
                            .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, KeepurTheme.Spacing.s3)
                }
                .buttonStyle(.plain)

                if index < savedWorkspaces.count - 1 {
                    Divider()
                }
            }
        }
    }
}
```

`NavigationLink` provides the trailing chevron automatically because we're inside a `NavigationStack` (declared at the top of `SettingsView.body`). `.buttonStyle(.plain)` keeps text in our `fgPrimaryDynamic` instead of iOS's default link tint.

Drop the `.onDelete { … }` modifier — swipe-to-delete is `List`-specific and the delete affordance moves to the (future) detail view per spec scope.

**Verification:** chevron appears on each saved workspace row; tapping pushes to the placeholder destination.

### Step 5: Migrate VOICE card with full-row tap target

The card itself:

```swift
eyebrowHeader("VOICE")
KeepurCard(bordered: true) {
    VStack(spacing: 0) {
        ForEach(Array(englishVoices.enumerated()), id: \.element.identifier) { index, voice in
            voiceRow(voice)
            if index < englishVoices.count - 1 {
                Divider()
            }
        }
    }
}
```

Update the `voiceRow` helper to use `.contentShape(Rectangle())` + `.buttonStyle(.plain)`:

```swift
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
        .padding(.vertical, KeepurTheme.Spacing.s3)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
}
```

Two added modifiers: `.contentShape(Rectangle())` on the label content (so the full HStack width registers taps) and `.buttonStyle(.plain)` on the Button (so the wrapped text doesn't tint blue). The action body and quality label helper are unchanged.

**Verification:** tapping anywhere on a voice row (including the trailing whitespace before the checkmark slot) plays the preview.

### Step 6: Migrate footer card (Disconnect / Unpair)

No eyebrow header — preserves the original "footer with no header" intent:

```swift
KeepurCard(bordered: true) {
    VStack(spacing: 0) {
        Button(viewModel.ws.isConnected ? "Disconnect" : "Reconnect") {
            if viewModel.ws.isConnected {
                viewModel.ws.disconnect()
            } else {
                viewModel.ws.connect()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, KeepurTheme.Spacing.s3)

        Divider()

        Button("Unpair Device", role: .destructive) {
            showUnpairConfirmation = true
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, KeepurTheme.Spacing.s3)
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
```

Buttons keep their roles; iOS handles the destructive tinting via the `.destructive` role.

**Verification:** Disconnect/Reconnect toggles label correctly; Unpair button shows the confirmation dialog and unpair flow works.

### Step 7: Add `SavedWorkspacesPlaceholderView` private struct

Same file, after the closing brace of `SettingsView`:

```swift
private struct SavedWorkspacesPlaceholderView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: KeepurTheme.Spacing.s5) {
                KeepurCard(bordered: true) {
                    Text("Saved workspace details coming soon.")
                        .font(KeepurTheme.Font.body)
                        .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                }
            }
            .padding(KeepurTheme.Spacing.s4)
        }
        .background(KeepurTheme.Color.bgPageDynamic)
        .navigationTitle("Saved Workspaces")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
```

Marked `private` so it stays scoped to this file — the placeholder destination is an implementation detail of the Saved Workspaces row.

**Verification:** file compiles. Tapping a saved workspace row pushes a screen with "Saved workspace details coming soon."

### Step 8: Create smoke test for `SavedWorkspacesPlaceholderView`

Wait — the placeholder is `private`. Either:
- (a) Make it `internal` (drop `private`) so the test can reference it under `@testable import Keepur`. `@testable` reaches `internal` symbols but not `private`.
- (b) Skip the test entirely since the placeholder is trivial and stays scoped.

Choose **(a)**. The test is cheap and proves the new destination view doesn't have a typo or wrong token reference. Drop the `private` modifier in Step 7's struct declaration; the type is otherwise still scoped to this file's compilation unit.

**File:** `KeeperTests/SavedWorkspacesPlaceholderViewTests.swift`

```swift
import XCTest
import SwiftUI
@testable import Keepur

final class SavedWorkspacesPlaceholderViewTests: XCTestCase {
    func testPlaceholderInstantiates() {
        let view = SavedWorkspacesPlaceholderView()
        _ = view.body
    }
}
```

Per CLAUDE.md constraint, do **not** add a smoke test for `SettingsView` itself — its body reads `KeychainManager` + `@ObservedObject viewModel.ws.isConnected`, which crashes in the test env.

**Verification:** test file compiles inside the test target.

### Step 9: Wire test file into Xcode project

Use the `xcodeproj` Ruby gem (per epic convention). Per CLAUDE.md: "Tests in `KeeperTests/` need xcodeproj wiring with bare filename (not full path)."

```ruby
require 'xcodeproj'
project = Xcodeproj::Project.open('Keepur.xcodeproj')
group_tests = project.main_group['KeeperTests']
ref = group_tests.new_reference('SavedWorkspacesPlaceholderViewTests.swift')
project.targets.each do |t|
  next unless t.name.include?('Tests')
  t.source_build_phase.add_file_reference(ref)
end
project.save
```

Note the bare filename `'SavedWorkspacesPlaceholderViewTests.swift'` (not `'KeeperTests/SavedWorkspacesPlaceholderViewTests.swift'`) per repo convention.

`Views/SettingsView.swift` does **not** need wiring — `Views/` is a synchronized folder group per CLAUDE.md.

**Verification:** `git diff Keepur.xcodeproj/project.pbxproj` shows exactly one new file reference under the test target; no diff in any source-file build phase.

### Step 10: Build verification (iOS + macOS)

Sequential builds (parallel iOS + macOS collide on SourcePackages — known issue from theming epic):

```bash
xcodebuild -project Keepur.xcodeproj -scheme Keepur \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -quiet build
```

```bash
xcodebuild -project Keepur.xcodeproj -scheme Keepur \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  -quiet build
```

**Verification:** both exit 0. macOS flags are required per CLAUDE.md — single multi-platform `Keepur` scheme means we drive both platforms from one build target.

### Step 11: Run test suite

Targeted test first:

```bash
xcodebuild test -project Keepur.xcodeproj -scheme Keepur \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing KeeperTests/SavedWorkspacesPlaceholderViewTests \
  -quiet
```

Then full suite (regression check):

```bash
xcodebuild test -project Keepur.xcodeproj -scheme Keepur \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -quiet
```

**Verification:** both exit 0. Targeted test reports 1 pass. Total test count = previous + 1.

### Step 12: Commit

```
feat: migrate Settings to KeepurCard sections (KPR-149)

Replace List/Section with ScrollView/LazyVStack/KeepurCard. Status text
adopts semantic color (Connected → success). Saved Workspaces row gains
NavigationLink chevron + placeholder destination. Voice rows take full-
width tap target. Detail content for Saved Workspaces deferred per scope.

Closes KPR-149
```

## Test Groups

| Group | Coverage | File |
|---|---|---|
| **Unit (smoke)** | `SavedWorkspacesPlaceholderView` instantiates without crash | `KeeperTests/SavedWorkspacesPlaceholderViewTests.swift` |
| **Integration** | N/A — pure view restructure with no behavioral change beyond visual grouping + three small affordance tweaks |  |
| **Manual** | (1) Status text matches dot color when connected/disconnected; (2) tapping any saved workspace row pushes placeholder; (3) tapping anywhere on a voice row plays preview — verified manually since `SettingsView` body cannot be smoke-tested per CLAUDE.md |  |

## Risks / Mitigations

| Risk | Mitigation |
|---|---|
| `LazyVStack` lays out lazily on iOS — first paint may flash without all cards | All five cards are above-the-fold on common device sizes; if visible regression appears, swap `LazyVStack` → `VStack`. Cost is negligible at this card count |
| `NavigationLink` chevron styling doesn't honor `.buttonStyle(.plain)` consistently across iOS versions | Visual inspection on iPhone 17 Pro simulator — if tinting bleeds through, add `.foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)` to the label HStack |
| Dropping `swipe-to-delete` on Saved Workspaces is a regression | Documented in spec Out of Scope — moves to detail view ticket. User can still pair-then-unpair as workaround until then. Pre-approved per epic delegation |
| `confirmationDialog` presentation anchor may shift when Unpair button moves out of `List` context | Confirmation dialogs are full-width modals on iOS — anchor doesn't matter visually. Behavior preserved |
| `SettingsView` is presented as both a sheet (existing) and a Tab (after KPR-147) — landing surface changes | The view itself is identical in both hosts. `NavigationStack` works in both contexts. No conditional needed |
| Project file (`project.pbxproj`) corrupted by `xcodeproj` gem mid-edit | Run `git diff project.pbxproj` after script; revert and retry if corrupt; gem is well-tested in this repo from theming epic and KPR-144 |

## Dependencies Check

- **External (foundation tokens):** `KeepurTheme.Color.{fgPrimaryDynamic, fgSecondaryDynamic, success, danger, honey500, bgPageDynamic, bgSurfaceDynamic, borderDefaultDynamic}`, `KeepurTheme.Spacing.{s3, s4, s5}`, `KeepurTheme.Font.{body, caption, eyebrow}`, `KeepurTheme.FontName.mono`, `KeepurTheme.Symbol.check` — all confirmed present in `Theme/KeepurTheme.swift`.
- **External (foundation components):** `KeepurCard<Content>` with `bordered: Bool` initializer — confirmed at `Theme/Components/KeepurCard.swift` (epic dep KPR-145, already on the epic branch per task statement).
- **External (test target):** existing `KeepurThemeFontsTests.swift` and KPR-144's `KeepurFoundationAtomsTests.swift` confirm `@testable import Keepur` pattern works.
- **Ticket dependencies:** KPR-145 (must be merged into epic branch before this ticket can build).

## Human Signoff

Pre-approved per durable user delegation (KPR-142 design v2 epic). No human plan-review checkpoint required.
