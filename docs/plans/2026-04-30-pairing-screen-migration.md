# Pairing Screen Migration Implementation Plan

> **For agentic workers:** Use `dodi-dev:implement` to execute this plan.

**Goal:** Migrate `Views/PairingView.swift` to consume `KeepurTheme` tokens and apply brand surfaces (wax page bg, honey CTA, JetBrains Mono digit cards), and extract a reusable `KeepurPrimaryButtonStyle` SwiftUI ButtonStyle for use by every following screen migration. Pure styling — no behavior changes.

**Architecture:** A new `Theme/Components/PrimaryButton.swift` defines `KeepurPrimaryButtonStyle: ButtonStyle` that combines `Color.honey500`, `Shadow.honey`, `Radius.md`, `Font.button`, and `Color.fgOnHoney` into a single `.buttonStyle(...)`-compatible primary CTA recipe with pressed and disabled states. `Views/PairingView.swift` is rewritten to (a) use the new button style for its three step CTAs, (b) consume `KeepurTheme.*` tokens for every color, font, padding, and radius, (c) wrap its body in a wax page background, (d) treat each pairing-code digit cell as a JetBrains Mono SemiBold sunken card with tap-to-refocus, and (e) restructure the name step from `HStack { Back; Continue }` to `VStack { Continue; Back }` so the full-width primary style composes correctly. No state machine, no API, no test changes.

**Tech Stack:** SwiftUI, Xcode 16+. iOS 26.2+ / macOS 15.0+. Ruby `xcodeproj` gem (already user-installed from DOD-389) for project file edits.

**Spec:** [docs/specs/2026-04-30-pairing-screen-migration.md](../specs/2026-04-30-pairing-screen-migration.md)

**Out of scope for this plan:** SVG `keepur-mark.svg` logo, custom 3×4 onscreen keypad, Inter Tight wordmark, dark-mode tuning of macOS `*Dynamic` aliases, any data-flow change.

---

## File Map

| File | Change |
|------|--------|
| `Theme/Components/PrimaryButton.swift` | **Create** — `KeepurPrimaryButtonStyle: ButtonStyle` (~30 LOC) |
| `Views/PairingView.swift` | **Rewrite** — same surface, all values from `KeepurTheme.*`, name step VStack, brand surfaces |
| `Keepur.xcodeproj/project.pbxproj` | **Modify** — add `Theme/Components/PrimaryButton.swift` to Compile Sources for the Keepur target |

---

## Task 1: Preflight verification

Read-only checks. If any fail, escalate before proceeding.

**Files:** none

- [ ] **Step 1.1:** Confirm we're on a fresh worktree off `main` with the foundation merged.

```bash
pwd
git rev-parse --abbrev-ref HEAD
git log --oneline -3
```

Expected: working directory is `/Users/mayhuang/github/keepur-ios-DOD-391`, branch is `DOD-391`, top commit is the spec (`docs: design spec for Pairing screen migration`), parent `6c8d0b3` is the foundation merge.

- [ ] **Step 1.2:** Confirm every `KeepurTheme.*` symbol the spec cites actually exists in `Theme/KeepurTheme.swift`.

```bash
for sym in honey500 fgPrimaryDynamic fgSecondaryDynamic fgOnHoney bgPageDynamic bgSurfaceDynamic borderDefaultDynamic charcoal900 danger; do
  printf "Color.%-22s -> %s\n" "$sym" "$(grep -c "let $sym" Theme/KeepurTheme.swift)"
done
for sym in s2 s3 s4 s6 s7; do
  printf "Spacing.%-20s -> %s\n" "$sym" "$(grep -c "let $sym:" Theme/KeepurTheme.swift)"
done
for sym in xs sm md; do
  printf "Radius.%-21s -> %s\n" "$sym" "$(grep -c "let $sym:" Theme/KeepurTheme.swift)"
done
for sym in mono monoMedium monoBold; do
  printf "FontName.%-19s -> %s\n" "$sym" "$(grep -c "let $sym " Theme/KeepurTheme.swift)"
done
for sym in h1 body bodySm button caption lsH1; do
  printf "Font.%-23s -> %s\n" "$sym" "$(grep -c "let $sym" Theme/KeepurTheme.swift)"
done
for sym in server; do
  printf "Symbol.%-21s -> %s\n" "$sym" "$(grep -c "let $sym " Theme/KeepurTheme.swift)"
done
for fn in keepurFocusRing keepurShadow keepurBorder; do
  printf "%-29s -> %s\n" "$fn" "$(grep -c "func $fn" Theme/KeepurTheme.swift)"
done
```

Expected: every count is at least `1`. Two known-acceptable values >1:

- `FontName.mono` returns `2` because `Font.mono` (the SwiftUI Font alias) shadows the grep pattern. Both declarations exist intentionally.
- `Font.body` may return `2` for the same reason if grepped loosely. Both count as pass.

Treat `0` as a blocker — the spec cited a token that doesn't exist; halt and escalate.

- [ ] **Step 1.3:** Confirm the existing pairing code path doesn't have unit tests that lock in current visuals.

```bash
grep -rln "PairingView\|server.rack\|tertiarySystemFill\|borderedProminent" KeeperTests/ 2>/dev/null || echo "(no matches)"
```

Expected: `(no matches)` or matches only in unrelated comments. If any test asserts on visual properties of `PairingView`, that's a behavior preservation concern — surface to user.

- [ ] **Step 1.4:** Confirm `xcodeproj` Ruby gem is still installed (from DOD-389).

```bash
gem list xcodeproj | grep -q xcodeproj && echo "OK" || echo "MISSING"
```

Expected: `OK`. If `MISSING`, run `gem install --user-install xcodeproj` and re-check.

- [ ] **Step 1.5:** No commit — verification only. Surface a one-line pass/fail summary to the user.

---

## Task 2: Create `Theme/Components/PrimaryButton.swift`

**Files:**
- Create: `Theme/Components/PrimaryButton.swift`

- [ ] **Step 2.1:** Create the directory and file.

```bash
mkdir -p Theme/Components
```

- [ ] **Step 2.2:** Write `Theme/Components/PrimaryButton.swift`:

```swift
import SwiftUI

/// Honey-amber primary call-to-action with the brand's signature shadow,
/// pressed-state opacity, and disabled-state opacity. Used by every primary
/// CTA across the app (pairing, settings save, tool approval, etc.).
///
/// Apply with `.buttonStyle(KeepurPrimaryButtonStyle())`.
struct KeepurPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(KeepurTheme.Font.button)
            .foregroundStyle(KeepurTheme.Color.fgOnHoney)
            .frame(maxWidth: .infinity)
            .padding(.vertical, KeepurTheme.Spacing.s3)
            .background(
                KeepurTheme.Color.honey500
                    .opacity(configuration.isPressed ? 0.85 : 1.0)
            )
            .clipShape(RoundedRectangle(cornerRadius: KeepurTheme.Radius.md))
            .keepurShadow(.honey)
            .opacity(isEnabled ? 1.0 : 0.4)
    }
}
```

- [ ] **Step 2.3:** Confirm the file parses.

```bash
xcrun swiftc -parse Theme/Components/PrimaryButton.swift 2>&1 | tail -5
echo "exit: $?"
```

Expected: empty output, exit 0.

- [ ] **Step 2.4:** Don't commit yet — Task 3 wires the file into the Xcode project, then we commit Task 2 + Task 3 together as one logical change.

---

## Task 3: Wire `Theme/Components/PrimaryButton.swift` into the Xcode project

**Files:**
- Modify: `Keepur.xcodeproj/project.pbxproj`

- [ ] **Step 3.1:** Save the wiring script as `/tmp/wire_primary_button.rb`:

```ruby
#!/usr/bin/env ruby
require 'xcodeproj'

project = Xcodeproj::Project.open('Keepur.xcodeproj')

app_target = project.targets.find { |t| t.product_reference&.path == 'Keepur.app' }
raise "Main app target not found" unless app_target

# Find or create Theme/Components group
theme_group = project.main_group.find_subpath('Theme', true)
theme_group.set_source_tree('<group>')
theme_group.set_path('Theme')
components_group = theme_group.find_subpath('Components', true)
components_group.set_source_tree('<group>')
components_group.set_path('Components')

unless components_group.files.any? { |f| f.path == 'PrimaryButton.swift' }
  ref = components_group.new_reference('PrimaryButton.swift')
  app_target.add_file_references([ref])
  puts "Added Theme/Components/PrimaryButton.swift to #{app_target.name}"
end

project.save
```

- [ ] **Step 3.2:** Run the script.

```bash
ruby /tmp/wire_primary_button.rb
```

Expected: `Added Theme/Components/PrimaryButton.swift to Keepur`

- [ ] **Step 3.3:** Verify the file ref landed.

```bash
grep -c "PrimaryButton.swift" Keepur.xcodeproj/project.pbxproj
```

Expected: `2` (one PBXFileReference + one PBXBuildFile).

- [ ] **Step 3.4:** Build for iOS to confirm the new file compiles inside the target context (this is what catches token-name typos that `swiftc -parse` can't see in isolation).

```bash
xcodebuild build -project Keepur.xcodeproj -scheme Keepur \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -quiet 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`. If a "cannot find 'KeepurTheme' in scope" error appears, the project group/target membership is wrong — re-check Task 3 step 3.

- [ ] **Step 3.5:** Build for macOS.

```bash
xcodebuild build -project Keepur.xcodeproj -scheme Keepur \
  -destination 'platform=macOS' \
  -quiet 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3.6:** Commit Task 2 + 3 together.

```bash
git add Theme/Components/PrimaryButton.swift Keepur.xcodeproj/project.pbxproj
git commit -m "$(cat <<'EOF'
feat: add KeepurPrimaryButtonStyle (DOD-391)

Reusable SwiftUI ButtonStyle implementing the brand's primary CTA
recipe — honey-500 background, charcoal text, honey shadow, 14pt
radius, 12pt vertical padding, full-width. Pressed-state opacity
0.85, disabled-state opacity 0.4.

First component under Theme/Components/, the convention every
following screen migration ticket will reuse and extend.

Not yet consumed by any view (next commit applies it to PairingView
in DOD-391's main migration).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Rewrite `Views/PairingView.swift`

**Files:**
- Modify: `Views/PairingView.swift` (full rewrite, same surface area, same behavior, new tokens + brand surfaces + name step layout)

- [ ] **Step 4.1:** Replace the entire file with this version.

```swift
import SwiftUI
#if os(iOS)
import UIKit
#endif

struct PairingView: View {
    let onPaired: () -> Void
    let capabilityManager: CapabilityManager

    @State private var host = BeekeeperConfig.host ?? ""
    @State private var code = ""
    @State private var deviceName = ""
    @State private var step = 0
    @State private var isLoading = false
    @State private var errorMessage: String?
    @FocusState private var codeFieldFocused: Bool
    @FocusState private var hostFieldFocused: Bool
    @FocusState private var deviceNameFieldFocused: Bool

    var body: some View {
        VStack(spacing: KeepurTheme.Spacing.s6) {
            Spacer()

            VStack(spacing: KeepurTheme.Spacing.s2) {
                Image(systemName: KeepurTheme.Symbol.server)
                    .font(.system(size: 48))
                    .foregroundStyle(KeepurTheme.Color.honey500)

                Text("Keepur")
                    .font(KeepurTheme.Font.h1)
                    .tracking(KeepurTheme.Font.lsH1)
                    .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)

                Text(subtitle)
                    .font(KeepurTheme.Font.bodySm)
                    .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, KeepurTheme.Spacing.s7)
            }

            switch step {
            case 0: hostEntryView
            case 1: codeEntryView
            default: nameEntryView
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(KeepurTheme.Font.caption)
                    .foregroundStyle(KeepurTheme.Color.danger)
                    .padding(.horizontal, KeepurTheme.Spacing.s7)
            }

            if isLoading {
                ProgressView()
            }

            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(KeepurTheme.Color.bgPageDynamic)
    }

    private var subtitle: String {
        switch step {
        case 0: return "Enter your Beekeeper host"
        case 1: return "Enter the 6-digit pairing code from your admin dashboard"
        default: return "Name this device"
        }
    }

    // MARK: - Step 0: Host Entry

    private var hostEntryView: some View {
        VStack(spacing: KeepurTheme.Spacing.s4) {
            keepurTextField(
                placeholder: "beekeeper.example.com",
                text: $host,
                focus: $hostFieldFocused
            )
            #if os(iOS)
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            #endif
            .autocorrectionDisabled(true)
            .onSubmit(continueFromHost)
            .padding(.horizontal, KeepurTheme.Spacing.s7)

            Text("Your administrator will give you this address.")
                .font(KeepurTheme.Font.caption)
                .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                .multilineTextAlignment(.center)
                .padding(.horizontal, KeepurTheme.Spacing.s7)

            Button("Continue", action: continueFromHost)
                .buttonStyle(KeepurPrimaryButtonStyle())
                .disabled(BeekeeperConfig.validate(host) == nil)
                .padding(.horizontal, KeepurTheme.Spacing.s7)
        }
        .onAppear { hostFieldFocused = true }
    }

    private func continueFromHost() {
        guard let normalized = BeekeeperConfig.validate(host) else {
            errorMessage = "Enter a valid hostname (e.g. beekeeper.example.com)"
            return
        }
        BeekeeperConfig.host = normalized
        host = normalized
        errorMessage = nil
        step = 1
        codeFieldFocused = true
    }

    // MARK: - Step 1: Code Entry

    private var codeEntryView: some View {
        VStack(spacing: KeepurTheme.Spacing.s4) {
            HStack(spacing: KeepurTheme.Spacing.s2) {
                ForEach(0..<6, id: \.self) { index in
                    digitBox(at: index)
                }
            }
            .padding(.horizontal, KeepurTheme.Spacing.s7)

            TextField("", text: $code)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
                .focused($codeFieldFocused)
                .opacity(0)
                .frame(height: 1)
                .onChange(of: code) {
                    code = String(code.filter(\.isNumber).prefix(6))
                    if code.count == 6 {
                        step = 2
                    }
                }

            Button("Back") {
                code = ""
                errorMessage = nil
                step = 0
                hostFieldFocused = true
            }
            .font(KeepurTheme.Font.bodySm)
            .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
        }
        .onAppear { codeFieldFocused = true }
    }

    private func digitBox(at index: Int) -> some View {
        let digit = index < code.count
            ? String(code[code.index(code.startIndex, offsetBy: index)])
            : ""
        return Text(digit)
            .font(.custom(KeepurTheme.FontName.monoBold, size: 32))
            .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(KeepurTheme.Color.charcoal900.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: KeepurTheme.Radius.xs))
            .contentShape(Rectangle())
            .onTapGesture { codeFieldFocused = true }
    }

    // MARK: - Step 2: Device Name

    private var nameEntryView: some View {
        VStack(spacing: KeepurTheme.Spacing.s4) {
            keepurTextField(
                placeholder: "Device name",
                text: $deviceName,
                focus: $deviceNameFieldFocused
            )
            .disabled(isLoading)
            .padding(.horizontal, KeepurTheme.Spacing.s7)

            Button("Continue") {
                pair()
            }
            .buttonStyle(KeepurPrimaryButtonStyle())
            .disabled(deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
            .padding(.horizontal, KeepurTheme.Spacing.s7)

            Button("Back") {
                code = ""
                errorMessage = nil
                step = 1
            }
            .font(KeepurTheme.Font.bodySm)
            .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
            .disabled(isLoading)
        }
        .onAppear { deviceNameFieldFocused = true }
    }

    // MARK: - Branded text field

    /// Wax-surface text field with 1px wax-200 border and a honey focus ring.
    /// Inline helper for now — extract to Theme/Components/ once a second
    /// screen needs it (see Theme/Components/PrimaryButton.swift for the
    /// extraction pattern).
    private func keepurTextField(
        placeholder: String,
        text: Binding<String>,
        focus: FocusState<Bool>.Binding
    ) -> some View {
        TextField(placeholder, text: text)
            .font(KeepurTheme.Font.body)
            .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
            .multilineTextAlignment(.center)
            .focused(focus)
            .padding(.vertical, KeepurTheme.Spacing.s3)
            .padding(.horizontal, KeepurTheme.Spacing.s4)
            .background(KeepurTheme.Color.bgSurfaceDynamic)
            .clipShape(RoundedRectangle(cornerRadius: KeepurTheme.Radius.sm))
            .overlay(
                RoundedRectangle(cornerRadius: KeepurTheme.Radius.sm)
                    .stroke(KeepurTheme.Color.borderDefaultDynamic, lineWidth: 1)
            )
            .keepurFocusRing(focus.wrappedValue, radius: KeepurTheme.Radius.sm)
    }

    // MARK: - Pairing

    private func pair() {
        let trimmedName = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        isLoading = true
        errorMessage = nil

        Task {
            do {
                let response = try await APIManager.pair(code: code, name: trimmedName)
                KeychainManager.token = response.token
                KeychainManager.deviceId = response.deviceId
                KeychainManager.deviceName = response.deviceName

                await capabilityManager.refresh()

                if capabilityManager.lastError != nil {
                    // Roll back the credentials only — leave BeekeeperConfig.host alone
                    // so the user can retry without re-entering the host.
                    KeychainManager.token = nil
                    KeychainManager.deviceId = nil
                    KeychainManager.deviceName = nil
                    UserDefaults.standard.removeObject(forKey: "selectedHive")
                    errorMessage = "Paired, but couldn't load hives. Check network and try again."
                    isLoading = false
                    return
                }

                #if os(iOS)
                let generator = UINotificationFeedbackGenerator()
                generator.notificationOccurred(.success)
                #endif

                isLoading = false
                onPaired()
            } catch is APIManager.PairError {
                #if os(iOS)
                let generator = UINotificationFeedbackGenerator()
                generator.notificationOccurred(.error)
                #endif

                errorMessage = "Invalid pairing code. Try again."
                isLoading = false
                code = ""
                step = 1
                codeFieldFocused = true
            } catch BeekeeperConfigError.hostNotConfigured {
                errorMessage = "Host not configured. Go back and enter your Beekeeper host."
                isLoading = false
            } catch {
                errorMessage = "Connection error. Check network."
                isLoading = false
            }
        }
    }
}
```

Notes on changes vs. the previous version:
- Added `@FocusState private var deviceNameFieldFocused` so the name step's text field can gain its own focus ring. The previous version had no focus binding for that field.
- Restructured the name step from `HStack { Back; Continue }` to `VStack { Continue; Back }`. Visually matches step 1's pattern. Functionally identical (Back still clears code and goes to step 1; Continue still calls `pair()`).
- Extracted `keepurTextField(...)` as a private helper to avoid copy-pasting the same six-modifier stack on host and name fields.
- Hidden code TextField (lines 119-131 in the old file, mid-function in the new file) is unchanged — same `opacity(0)`, same `frame(height: 1)`, same `onChange` filter.
- The `onTapGesture { codeFieldFocused = true }` on each digit cell is preserved with `contentShape(Rectangle())` to ensure the entire transparent cell area is tappable.
- All paddings, fonts, colors, radii now derive from `KeepurTheme.*`.

- [ ] **Step 4.2:** Build for iOS to verify the rewrite compiles.

```bash
xcodebuild build -project Keepur.xcodeproj -scheme Keepur \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -quiet 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`. If a "cannot find" error appears, the most likely cause is a typo in a `KeepurTheme.*` symbol — re-check Task 1 step 2.

- [ ] **Step 4.3:** Build for macOS.

```bash
xcodebuild build -project Keepur.xcodeproj -scheme Keepur \
  -destination 'platform=macOS' \
  -quiet 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4.4:** Run the full unit test suite on iOS to confirm no regression.

```bash
set -o pipefail
xcodebuild test -project Keepur.xcodeproj -scheme Keepur \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:KeeperTests \
  -quiet > /tmp/dod-391-ios-test.log 2>&1
echo "EXIT=$?"
echo "passed: $(grep -c 'passed on' /tmp/dod-391-ios-test.log)"
echo "failed: $(grep -c 'failed on' /tmp/dod-391-ios-test.log)"
```

Expected: `EXIT=0` and `failed: 0`. The `passed` count varies as new tests are added — record the current value in the PR description but don't assert against a fixed number. If `EXIT` is non-zero or any failures appear, halt and read the log.

- [ ] **Step 4.5:** Run the macOS suite.

```bash
set -o pipefail
xcodebuild test -project Keepur.xcodeproj -scheme Keepur \
  -destination 'platform=macOS' \
  -only-testing:KeeperTests \
  -quiet \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  > /tmp/dod-391-mac-test.log 2>&1
echo "EXIT=$?"
echo "passed: $(grep -c 'passed on' /tmp/dod-391-mac-test.log)"
echo "failed: $(grep -c 'failed on' /tmp/dod-391-mac-test.log)"
```

Expected: `EXIT=0` and `failed: 0`. Same caveat about test counts as 4.4. Signing flags carry over from DOD-389's macOS test invocation (no Mac Development cert on dev machines).

- [ ] **Step 4.6:** Commit.

```bash
git add Views/PairingView.swift
git commit -m "$(cat <<'EOF'
feat: migrate Pairing screen to KeepurTheme tokens (DOD-391)

Pairing screen now consumes design-system tokens and applies brand
surfaces. Visible changes:

- Wax page background (#FFFDF8 light, charcoal-900 dark via
  bgPageDynamic)
- Honey-amber primary CTA via KeepurPrimaryButtonStyle, with
  honey shadow, pressed/disabled states
- 6-digit pairing grid uses JetBrains Mono SemiBold 32pt in
  charcoal-tinted sunken cards
- Honey focus ring on text fields when active
- Charcoal/wax text colors instead of system primary/.secondary
- Semantic danger color for errors instead of system red

No behavior changes. State machine, focus order, API calls, error
handling, haptic feedback, and the hidden code TextField pattern
all preserved. Tap-to-refocus on digit cells preserved with
contentShape(Rectangle()).

Layout change: name step restructured from HStack { Back; Continue }
to VStack { Continue; Back } so KeepurPrimaryButtonStyle's full-width
shape composes correctly. Functionally identical.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Visual diff in simulator

This task is a manual checklist. The agent runs the simulator, the human steps through Pairing and verifies the listed visuals.

**Files:** none

- [ ] **Step 5.1:** Boot the iOS simulator and launch the app.

```bash
xcrun simctl list devices available | grep "iPhone 17" | head -1
xcodebuild -project Keepur.xcodeproj -scheme Keepur \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -configuration Debug \
  -quiet build 2>&1 | tail -3
xcrun simctl boot "iPhone 17" 2>/dev/null || true
open -a Simulator
```

Expected: simulator window appears with iPhone 17. If the simulator is already booted, the second command no-ops harmlessly.

- [ ] **Step 5.2:** Install and launch the just-built app. (The exact path depends on the build's `BUILT_PRODUCTS_DIR`; the simplest reliable invocation:)

```bash
APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData/Keepur-* -name "Keepur.app" -path "*Debug-iphonesimulator*" | head -1)
echo "Using $APP_PATH"
xcrun simctl install booted "$APP_PATH"
xcrun simctl launch booted io.keepur.Keepur
```

Expected: app launches. If a paired token exists in the simulator's keychain from prior testing, you'll go past Pairing — wipe with `xcrun simctl erase booted` and re-launch.

**Caveat:** `simctl erase booted` nukes *all* simulator state for every installed app on that device, not just Keepur. Acceptable for a clean dev simulator; if you have other in-progress test data on the same simulator, target Keepur specifically with `xcrun simctl uninstall booted io.keepur.Keepur && xcrun simctl install booted "$APP_PATH"` instead — that only resets Keepur's storage but doesn't reset the keychain (Keychain Services is per-device, not per-app on the simulator). The full erase is the only reliable way to clear a stale paired token.

- [ ] **Step 5.3:** Walk through the three steps and tick off this checklist:

- [ ] Step 0 (Host) — wax-0 page background visible (off-white, slightly warm — not pure white)
- [ ] Step 0 — `Keepur` wordmark renders in SF (not custom font), 36pt-ish
- [ ] Step 0 — `server.rack` icon is honey-amber (not blue, not gray)
- [ ] Step 0 — `Continue` button is honey-amber rectangle with a soft honey-tinted shadow underneath; charcoal-black text
- [ ] Step 0 — Tapping the host text field shows a honey ring around it
- [ ] Step 0 — `Continue` is dimmed (40% opacity) until a valid host is entered
- [ ] Step 0 — Pressing `Continue` briefly darkens the button (pressed state)
- [ ] Step 1 (Code) — Six digit cells visible, each with a slight charcoal tint background
- [ ] Step 1 — Typing digits shows JetBrains Mono SemiBold 32pt glyphs (square-tabular zeros, slabby — distinct from SF Mono)
- [ ] Step 1 — Tapping any digit cell re-opens the keyboard (verifies tap-to-refocus)
- [ ] Step 1 — Entering 6 digits auto-advances to step 2
- [ ] Step 1 — `Back` is a subtle text button below the grid (wax-700 color)
- [ ] Step 2 (Name) — `Continue` is the full-width honey button on top, `Back` is text below
- [ ] Step 2 — `Continue` dims when the name field is empty
- [ ] Error path — Forcing an error (invalid hostname) renders text in the danger red (`#C92A2A`), not iOS system red

If any item fails, halt and report which one. Don't try to "fix" by re-running — fixes are spec-level conversations.

- [ ] **Step 5.4:** No commit. This is verification only.

---

## Task 6: Final regression sweep

**Files:** none

- [ ] **Step 6.1:** Confirm the working tree is clean.

```bash
git status --short
```

Expected: empty output.

- [ ] **Step 6.2:** Confirm the branch's commit shape.

```bash
git log --oneline main..HEAD
```

Expected: 3 commits — spec, primary-button feature, pairing-migration feature.

- [ ] **Step 6.3:** No commit. Plan complete.

---

## Summary of commits this plan produces

1. (Spec already committed) `docs: design spec for Pairing screen migration (DOD-391)`
2. `feat: add KeepurPrimaryButtonStyle (DOD-391)` — Tasks 2 + 3
3. `feat: migrate Pairing screen to KeepurTheme tokens (DOD-391)` — Task 4

## After the plan

1. `/quality-gate` — Swift compliance + create tests + full suite
2. `dodi-dev:review` — agent code review
3. `dodi-dev:submit` — PR + cleanup, **no auto-merge** (per project memory)
4. After human review and merge, file the next migration ticket under epic DOD-390 (likely Settings or Session List).
