# macOS Support Implementation Plan

> **For agentic workers:** Use dodi-dev:implement to execute this plan.

**Goal:** Add native macOS destination so the same codebase builds for both iOS and macOS.

**Architecture:** No new files except a Color extension and entitlements. All changes are platform guards (`#if os(iOS)`) and Xcode config. The shared Color extension provides cross-platform semantic colors replacing UIColor-dependent inits.

**Tech Stack:** SwiftUI multiplatform, Swift 5, Xcode 16+

---

### Task 1: Cross-Platform Color Extension

**Files:**
- Create: `Extensions/Color+Platform.swift`

- [ ] **Step 1:** Create `Extensions/Color+Platform.swift` with cross-platform semantic colors

```swift
import SwiftUI

extension Color {
    /// Replaces Color(.systemGray5) — light neutral fill
    static var secondarySystemFill: Color {
        #if os(iOS)
        Color(UIColor.systemGray5)
        #else
        Color(NSColor.quaternarySystemFill)
        #endif
    }

    /// Replaces Color(.systemGray6) — very light neutral fill
    static var tertiarySystemFill: Color {
        #if os(iOS)
        Color(UIColor.systemGray6)
        #else
        Color(NSColor.controlBackgroundColor)
        #endif
    }

    /// Replaces Color(.tertiarySystemBackground)
    static var tertiaryBackground: Color {
        #if os(iOS)
        Color(UIColor.tertiarySystemBackground)
        #else
        Color(NSColor.textBackgroundColor)
        #endif
    }
}
```

- [ ] **Step 2:** Commit

```bash
git add Extensions/Color+Platform.swift
git commit -m "feat: add cross-platform Color extension for macOS support"
```

---

### Task 2: Remove Dead UIKit Imports

**Files:**
- Modify: `Views/ChatView.swift:3` — remove `import UIKit`
- Modify: `Views/MessageBubble.swift:3` — remove `import UIKit`
- Modify: `Views/ToolApprovalView.swift:2` — remove `import UIKit`

- [ ] **Step 1:** Delete `import UIKit` from all three files. These files have no UIKit API usage.

- [ ] **Step 2:** Commit

```bash
git add Views/ChatView.swift Views/MessageBubble.swift Views/ToolApprovalView.swift
git commit -m "fix: remove dead UIKit imports blocking macOS build"
```

---

### Task 3: Replace Color(.systemGrayN) Calls

**Files:**
- Modify: `Views/MessageBubble.swift:75,110,166` — `Color(.systemGray5)` → `Color.secondarySystemFill`, `Color(.systemGray6)` → `Color.tertiarySystemFill`
- Modify: `Views/ChatView.swift:225` — `Color(.systemGray5)` → `Color.secondarySystemFill`
- Modify: `Views/ToolApprovalView.swift:36` — `Color(.systemGray6)` → `Color.tertiarySystemFill`
- Modify: `Views/WorkspacePickerView.swift:71` — `Color(.systemGray6)` → `Color.tertiarySystemFill`
- Modify: `Views/PairingView.swift:84` — `Color(.systemGray6)` → `Color.tertiarySystemFill`
- Modify: `Views/MarkdownTheme+Keepur.swift:14` — `Color(.systemGray6)` → `Color.tertiarySystemFill`
- Modify: `Views/MarkdownTheme+Keepur.swift:28` — `Color(.tertiarySystemBackground)` → `Color.tertiaryBackground`

- [ ] **Step 1:** Replace each occurrence:

In `MessageBubble.swift`:
- Line 75: `.fill(Color(.systemGray5))` → `.fill(Color.secondarySystemFill)`
- Line 110: `.fill(Color(.systemGray5))` → `.fill(Color.secondarySystemFill)`
- Line 166: `.fill(Color(.systemGray6))` → `.fill(Color.tertiarySystemFill)`

In `ChatView.swift`:
- Line 225: `.fill(Color(.systemGray5))` → `.fill(Color.secondarySystemFill)`

In `ToolApprovalView.swift`:
- Line 36: `.fill(Color(.systemGray6))` → `.fill(Color.tertiarySystemFill)`

In `WorkspacePickerView.swift`:
- Line 71: `Color(.systemGray6)` → `Color.tertiarySystemFill`

In `PairingView.swift`:
- Line 84: `Color(.systemGray6)` → `Color.tertiarySystemFill`

In `MarkdownTheme+Keepur.swift`:
- Line 14: `BackgroundColor(Color(.systemGray6))` → `BackgroundColor(Color.tertiarySystemFill)`
- Line 28: `.fill(Color(.tertiarySystemBackground))` → `.fill(Color.tertiaryBackground)`

- [ ] **Step 2:** Commit

```bash
git add Views/MessageBubble.swift Views/ChatView.swift Views/ToolApprovalView.swift Views/WorkspacePickerView.swift Views/PairingView.swift Views/MarkdownTheme+Keepur.swift
git commit -m "fix: replace UIColor-dependent Color inits with cross-platform extension"
```

---

### Task 4: Guard iOS-Only SwiftUI Modifiers

**Files:**
- Modify: `Views/ChatView.swift:77,79`
- Modify: `Views/SettingsView.swift:133,135`
- Modify: `Views/WorkspacePickerView.swift:149`
- Modify: `Views/SessionListView.swift:72,77,85`

- [ ] **Step 1:** In `ChatView.swift`, wrap line 77 and replace toolbar placement:

Line 77 — replace:
```swift
        .navigationBarTitleDisplayMode(.inline)
```
with:
```swift
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
```

Lines 79 — replace:
```swift
            ToolbarItem(placement: .topBarTrailing) {
```
with:
```swift
            ToolbarItem(placement: .automatic) {
```

Note: `.automatic` works on both platforms. On iOS it places items in the trailing position by default.

- [ ] **Step 2:** In `SettingsView.swift`:

Line 133 — wrap:
```swift
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
```

Line 135 — replace:
```swift
            ToolbarItem(placement: .topBarTrailing) {
```
with:
```swift
            ToolbarItem(placement: .automatic) {
```

- [ ] **Step 3:** In `WorkspacePickerView.swift`:

Line 149 — wrap:
```swift
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
```

Note: WorkspacePickerView already uses `.cancellationAction` and `.confirmationAction` placements which work on both platforms.

- [ ] **Step 4:** In `SessionListView.swift`, replace toolbar placements:

Line 72 — replace:
```swift
                ToolbarItem(placement: .topBarLeading) {
```
with:
```swift
                ToolbarItem(placement: .navigation) {
```

Note: `.navigation` places items on the leading side on both platforms, preserving the connection status dot position.

Line 77 — replace:
```swift
                ToolbarItem(placement: .topBarTrailing) {
```
with:
```swift
                ToolbarItem(placement: .automatic) {
```

Line 85 — replace:
```swift
                ToolbarItem(placement: .topBarTrailing) {
```
with:
```swift
                ToolbarItem(placement: .primaryAction) {
```

- [ ] **Step 5:** Commit

```bash
git add Views/ChatView.swift Views/SettingsView.swift Views/WorkspacePickerView.swift Views/SessionListView.swift
git commit -m "fix: guard iOS-only SwiftUI modifiers for macOS compatibility"
```

---

### Task 5: VoiceButton — Guard Haptics

**Files:**
- Modify: `Views/VoiceButton.swift:1-3,17,23`

- [ ] **Step 1:** Replace imports at top:

```swift
import SwiftUI
import Speech
#if os(iOS)
import UIKit
#endif
```

- [ ] **Step 2:** Wrap haptic calls at lines 17 and 23:

Line 17 — replace:
```swift
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
```
with:
```swift
                #if os(iOS)
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                #endif
```

Line 23 — replace:
```swift
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
```
with:
```swift
                #if os(iOS)
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                #endif
```

- [ ] **Step 3:** Commit

```bash
git add Views/VoiceButton.swift
git commit -m "fix: guard UIKit haptics in VoiceButton for macOS"
```

---

### Task 6: PairingView — Guard iOS-Only APIs

**Files:**
- Modify: `Views/PairingView.swift:64,133-134,139-140`

- [ ] **Step 1:** Wrap `.keyboardType(.numberPad)` at line 64:

```swift
            TextField("", text: $code)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
                .focused($codeFieldFocused)
```

- [ ] **Step 2:** Guard `UINotificationFeedbackGenerator` at lines 133-134 and 139-140:

Lines 133-134 — wrap:
```swift
                #if os(iOS)
                let generator = UINotificationFeedbackGenerator()
                generator.notificationOccurred(.success)
                #endif
```

Lines 139-140 — wrap:
```swift
                #if os(iOS)
                let generator = UINotificationFeedbackGenerator()
                generator.notificationOccurred(.error)
                #endif
```

- [ ] **Step 3:** Add conditional UIKit import at top of file:

```swift
import SwiftUI
#if os(iOS)
import UIKit
#endif
```

- [ ] **Step 4:** Commit

```bash
git add Views/PairingView.swift
git commit -m "fix: guard iOS-only APIs in PairingView for macOS"
```

---

### Task 7: SpeechManager — Guard AVAudioSession

**Files:**
- Modify: `Managers/SpeechManager.swift:56-61,110-112`

- [ ] **Step 1:** In `startRecording()`, wrap lines 56-61:

Replace:
```swift
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            return
        }
```
with:
```swift
        #if os(iOS)
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            return
        }
        #endif
```

- [ ] **Step 2:** In `speak()`, wrap lines 110-112:

Replace:
```swift
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(.playback, mode: .default)
        try? audioSession.setActive(true)
```
with:
```swift
        #if os(iOS)
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(.playback, mode: .default)
        try? audioSession.setActive(true)
        #endif
```

- [ ] **Step 3:** Commit

```bash
git add Managers/SpeechManager.swift
git commit -m "fix: guard AVAudioSession calls for macOS compatibility"
```

---

### Task 8: Xcode Project Configuration

**Files:**
- Modify: `Keepur.xcodeproj/project.pbxproj`

- [ ] **Step 1:** This task is best done in Xcode. The changes needed in `project.pbxproj`:

For the **Keepur app target** (both Debug and Release):
- Change `SDKROOT = iphoneos` → `SDKROOT = auto`
- Change `SUPPORTED_PLATFORMS = "iphoneos iphonesimulator"` → `SUPPORTED_PLATFORMS = "iphoneos iphonesimulator macosx"`
- Verify `MACOSX_DEPLOYMENT_TARGET = 26.2` is set (already present)

For the **KeeperTests target** (both Debug and Release):
- Change `SDKROOT = iphoneos` → `SDKROOT = auto`
- Change `SUPPORTED_PLATFORMS = "iphoneos iphonesimulator"` → `SUPPORTED_PLATFORMS = "iphoneos iphonesimulator macosx"`
- Add `MACOSX_DEPLOYMENT_TARGET = 26.2`

- [ ] **Step 2:** Create macOS entitlements file `Keepur.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.network.client</key>
    <true/>
    <key>com.apple.security.device.microphone</key>
    <true/>
    <key>com.apple.security.device.audio-input</key>
    <true/>
</dict>
</plist>
```

- [ ] **Step 3:** Reference entitlements in project for macOS builds. Add `CODE_SIGN_ENTITLEMENTS = Keepur.entitlements` to the app target build settings (or set conditionally for macOS via `CODE_SIGN_ENTITLEMENTS[sdk=macosx*]`).

- [ ] **Step 4:** Remove `REGISTER_APP_GROUPS = YES` from the app target (both Debug and Release) if no app group is actually used. This setting causes signing issues on macOS without a matching entitlement.

- [ ] **Step 5:** Commit

```bash
git add Keepur.xcodeproj/project.pbxproj Keepur.entitlements
git commit -m "feat: add macOS destination and sandbox entitlements"
```

---

### Task 9: Build Verification

- [ ] **Step 1:** Build for iOS simulator

```bash
xcodebuild -project Keepur.xcodeproj -scheme Keepur -destination 'platform=iOS Simulator,name=iPhone 16' build
```

Expected: BUILD SUCCEEDED

- [ ] **Step 2:** Build for macOS

```bash
xcodebuild -project Keepur.xcodeproj -scheme Keepur -destination 'platform=macOS' build
```

Expected: BUILD SUCCEEDED

- [ ] **Step 3:** If either build fails, fix the errors and re-run.

- [ ] **Step 4:** Commit any fixes

```bash
git commit -m "fix: resolve build errors for dual-platform support"
```
