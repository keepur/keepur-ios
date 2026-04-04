# Native macOS Support

**Date:** 2026-04-04
**Status:** Draft

## Goal

Add a native macOS destination to Keepur so the same codebase produces both an iOS and macOS app. No Mac Catalyst — true multiplatform SwiftUI.

## Decisions

| Decision | Choice |
|----------|--------|
| Approach | Native macOS target via SwiftUI multiplatform |
| Voice features | Full support on both platforms |
| Window model | Single resizable window |
| macOS minimum | 26.2 |

## Scope

### 1. Xcode Project Configuration

- Add `macosx` to `SUPPORTED_PLATFORMS` for both app and test targets
- Set `MACOSX_DEPLOYMENT_TARGET = 26.2`
- Change `SDKROOT` from hard-coded `iphoneos` to `auto` (currently hard-coded, blocks macOS builds)
- Remove or conditionalize `REGISTER_APP_GROUPS = YES` if no app group is actually used (causes signing issues without a matching entitlement)
- Update test target's `BUNDLE_LOADER` to handle macOS app bundle path (differs from iOS `.app` structure)
- Verify MarkdownUI SPM dependency resolves for macOS (v2.4.1 supports macOS 12+ — no changes expected)

### 2. Sandbox Entitlements

macOS apps require explicit sandbox entitlements. Create/update a `.entitlements` file with:
- `com.apple.security.network.client` — for WebSocket connections
- `com.apple.security.device.microphone` — for speech recognition
- `com.apple.security.device.audio-input` — for audio engine recording

### 3. Remove Dead UIKit Imports

Three files import UIKit but use no UIKit APIs:
- `ChatView.swift` — remove `import UIKit`
- `MessageBubble.swift` — remove `import UIKit`
- `ToolApprovalView.swift` — remove `import UIKit`

These cause build failures on macOS since UIKit doesn't exist there.

### 4. Replace `Color(.systemGrayN)` Calls

Six files use `Color(.systemGray5)` / `Color(.systemGray6)` which implicitly rely on `UIColor`. These won't compile on macOS without UIKit.

Files affected:
- `MessageBubble.swift` (3 uses)
- `ChatView.swift` (1 use)
- `ToolApprovalView.swift` (1 use)
- `WorkspacePickerView.swift` (1 use)
- `PairingView.swift` (1 use)
- `MarkdownTheme+Keepur.swift` (1 use)

**Fix:** Replace with platform-adaptive `Color` values using `#if os(iOS)` / `#else` blocks, or define shared semantic colors in an extension that maps to `UIColor` on iOS and `NSColor` on macOS.

### 5. iOS-Only SwiftUI Modifiers

Several SwiftUI modifiers are iOS-only and will cause build errors on macOS. Wrap each with `#if os(iOS)`:

| Modifier | Files |
|----------|-------|
| `.navigationBarTitleDisplayMode(.inline)` | `ChatView.swift`, `SettingsView.swift`, `WorkspacePickerView.swift` |
| `ToolbarItem(placement: .topBarTrailing)` / `.topBarLeading` | `ChatView.swift`, `SessionListView.swift`, `SettingsView.swift` |
| `.keyboardType(.numberPad)` | `PairingView.swift` |

For toolbar placements, use `#if os(iOS)` with `.topBarTrailing` and `#else` with `.automatic` or `.primaryAction`.

### 6. VoiceButton — Platform-Conditional Haptics

`VoiceButton.swift` imports UIKit for `UIImpactFeedbackGenerator`. Guard with `#if os(iOS)`:

```swift
#if os(iOS)
import UIKit
#endif

// In button action:
#if os(iOS)
UIImpactFeedbackGenerator(style: .medium).impactOccurred()
#endif
```

No macOS replacement — haptics aren't meaningful on Mac.

### 7. SpeechManager — Platform Adaptation

`AVAudioSession` does not exist on macOS. The rest of the Speech/AVFoundation APIs (`SFSpeechRecognizer`, `AVSpeechSynthesizer`, `AVAudioEngine`) are available on both platforms.

Changes needed:

- Wrap all `AVAudioSession` calls in `#if os(iOS)`. On macOS, the audio engine and speech recognizer work without explicit session management.
- Three locations to guard:
  1. `startRecording()` — audio session setup (lines 56-61)
  2. `speak()` — audio session setup (lines 110-112)
  3. The import of AVFoundation stays (needed for `AVSpeechSynthesizer` on both platforms)

The macOS code paths skip the session configuration and proceed directly to engine/synthesizer usage. Note: this is untested behavior — audio routing on macOS without explicit session management should work but needs verification.

### 8. Info.plist — Permissions

Ensure the shared Info.plist includes macOS privacy descriptions:
- `NSSpeechRecognitionUsageDescription`
- `NSMicrophoneUsageDescription`

These are already present for iOS; verify they carry over to the macOS build.

### 9. ATS Exception

The existing `NSAppTransportSecurity` exception for `beekeeper.dodihome.com` (cleartext WS) applies to macOS as well — no changes needed with a shared Info.plist.

## Out of Scope

- Multi-window support
- macOS-specific UI refinements (menu bar, toolbar, keyboard shortcuts)
- Touch Bar support
- Mac App Store distribution
- These can be follow-up work

## Risk

| Risk | Mitigation |
|------|------------|
| MarkdownUI doesn't build on macOS | Low risk — library supports macOS 12+. Verify during build. |
| Speech recognition permissions differ on macOS | Test on macOS; permission prompts may behave differently but APIs are the same. |
| Navigation layout looks odd on large windows | SwiftUI NavigationSplitView adapts well by default; test and adjust if needed. |
| macOS audio engine without AVAudioSession | Should work — macOS manages audio routing at OS level. Verify with real hardware. |

## Verification

- Build succeeds for both iOS and macOS destinations
- App launches on macOS, connects to WebSocket, sends/receives messages
- Voice input (speech-to-text) works on macOS
- TTS (text-to-speech) works on macOS
- Session management works on macOS
- All existing iOS functionality unchanged
