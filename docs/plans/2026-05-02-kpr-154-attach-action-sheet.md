# KPR-154 — Attach action sheet (Implementation Plan)

**Date:** 2026-05-02
**Spec:** [docs/specs/2026-05-02-kpr-154-attach-action-sheet.md](../specs/2026-05-02-kpr-154-attach-action-sheet.md)
**Ticket:** [KPR-154](https://linear.app/keepur/issue/KPR-154)

## Strategy

One existing file changes (`Views/MessageInputBar.swift`), one new test file is added (`KeeperTests/MessageInputBarAttachSheetTests.swift`), and the test file is wired into the Xcode project. Implementation order is: edit the view first (fast, contained), build to confirm zero regressions on existing consumers (`ChatView`, `TeamChatView`), then write the smoke test, then wire into the project, then run the test suite.

Per the spec, no surface other than `MessageInputBar` changes. The view's external API (`messageText`, `pendingAttachment`, `speechManager`, `onSend`) is preserved verbatim, so no consumer-side updates are needed.

## Steps

### Step 1: Edit `Views/MessageInputBar.swift`

**File:** `Views/MessageInputBar.swift`

Five surgical changes inside the existing struct:

1. **Add two `@State` properties** alongside the existing ones (after `@State private var attachmentError: String?`):

   ```swift
   @State private var showPhotoPicker = false
   @State private var showCameraPlaceholder = false
   ```

2. **Replace the `.popover(isPresented: $showAttachmentOptions) { ... }` block** (currently attached to the `+` `Button` at lines 36-64) with nothing — just remove the modifier from the `+` button. The `+` button's `Button { showAttachmentOptions = true } label: { Image(systemName: KeepurTheme.Symbol.plus)... }` body is unchanged.

3. **Add a `.sheet(isPresented: $showAttachmentOptions)` modifier** to the outermost `VStack(spacing: 0)` (the same `VStack` that already carries `.background(.ultraThinMaterial)` and the existing `.alert("Attachment Error", ...)`). Place it alongside the existing modifiers (order is not load-bearing for SwiftUI; group it with the other `.sheet`/`.alert`/`.fileImporter` modifiers for readability). Sheet body:

   ```swift
   .sheet(isPresented: $showAttachmentOptions) {
       KeepurActionSheet(
           title: "Attach",
           subtitle: "Add a file or photo to the message.",
           actions: [
               .init(
                   symbol: "doc",
                   title: "Choose file",
                   subtitle: "Browse documents on this device"
               ) {
                   showAttachmentOptions = false
                   DispatchQueue.main.async { showDocumentPicker = true }
               },
               .init(
                   symbol: "photo",
                   title: "Photo library",
                   subtitle: "Pick from your photos"
               ) {
                   showAttachmentOptions = false
                   DispatchQueue.main.async { showPhotoPicker = true }
               },
               .init(
                   symbol: "camera",
                   title: "Take photo",
                   subtitle: "Use the camera now"
               ) {
                   showAttachmentOptions = false
                   DispatchQueue.main.async { showCameraPlaceholder = true }
               },
           ]
       )
       .presentationDetents([.medium])
   }
   ```

4. **Add a `.photosPicker(isPresented:selection:matching:)` modifier** on the same outer `VStack`, replacing the inline `PhotosPicker(selection: $selectedPhoto, matching: .images)` that lived inside the popover:

   ```swift
   .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhoto, matching: .images)
   ```

   The existing `.onChange(of: selectedPhoto) { ... }` loader stays as-is — `selectedPhoto` is set by both pickers identically.

5. **Add the camera placeholder `.alert(...)` modifier** on the same outer `VStack`:

   ```swift
   .alert(
       "Camera capture coming soon",
       isPresented: $showCameraPlaceholder
   ) {
       Button("OK", role: .cancel) { showCameraPlaceholder = false }
   } message: {
       Text("Take photo will be wired up when KPR-159 lands. For now, choose a file or pick from your photo library.")
   }
   ```

**Verification:** file compiles. Manual visual confirmation deferred to step 3 (build).

### Step 2: Build verification

Sequential builds (parallel iOS + macOS collide on SourcePackages — known issue from theming epic):

```bash
xcodebuild -project Keepur.xcodeproj -scheme Keepur \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -quiet build

xcodebuild -project Keepur.xcodeproj -scheme Keepur \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  -quiet build
```

**Verification:** both exit 0. Confirms `MessageInputBar` still satisfies its consumers (`ChatView`, `TeamChatView`) and that the `.sheet`, `.photosPicker(isPresented:)`, and `.alert` modifiers all resolve on both platforms.

### Step 3: Create `KeeperTests/MessageInputBarAttachSheetTests.swift`

**File:** `KeeperTests/MessageInputBarAttachSheetTests.swift`

Per the spec, we **do not** instantiate `MessageInputBar.body` directly (it owns a `@ObservedObject SpeechManager` whose init touches Speech framework / mic permission and is not safe in test env). Instead we test the action-sheet shape by re-constructing the same `KeepurActionSheet` the view builds — a parallel-construction test. If MessageInputBar's production code drifts, the parallel construction in the test will still construct correctly but a manual smoke test will catch the divergence; this is consistent with how the foundation-composites tests in the epic verify `KeepurActionSheet` itself.

```swift
import XCTest
import SwiftUI
@testable import Keepur

final class MessageInputBarAttachSheetTests: XCTestCase {
    /// Builds the same KeepurActionSheet that MessageInputBar wires up
    /// when the user taps the `+` button. Test-only mirror of the
    /// production construction so we can assert shape and per-action
    /// dispatch without instantiating MessageInputBar.body (which
    /// requires a SpeechManager).
    private func makeAttachSheet(
        onChooseFile: @escaping () -> Void = {},
        onPhotoLibrary: @escaping () -> Void = {},
        onTakePhoto: @escaping () -> Void = {}
    ) -> KeepurActionSheet {
        KeepurActionSheet(
            title: "Attach",
            subtitle: "Add a file or photo to the message.",
            actions: [
                .init(symbol: "doc",    title: "Choose file",   subtitle: "Browse documents on this device", action: onChooseFile),
                .init(symbol: "photo",  title: "Photo library", subtitle: "Pick from your photos",          action: onPhotoLibrary),
                .init(symbol: "camera", title: "Take photo",    subtitle: "Use the camera now",              action: onTakePhoto),
            ]
        )
    }

    func testAttachSheetTitleAndSubtitle() {
        let sheet = makeAttachSheet()
        XCTAssertEqual(sheet.title, "Attach")
        XCTAssertEqual(sheet.subtitle, "Add a file or photo to the message.")
    }

    func testAttachSheetHasThreeActionsInOrder() {
        let sheet = makeAttachSheet()
        XCTAssertEqual(sheet.actions.count, 3)
        XCTAssertEqual(sheet.actions.map(\.title),    ["Choose file", "Photo library", "Take photo"])
        XCTAssertEqual(sheet.actions.map(\.symbol),   ["doc",          "photo",         "camera"])
        XCTAssertEqual(sheet.actions.map { $0.subtitle ?? "" }, [
            "Browse documents on this device",
            "Pick from your photos",
            "Use the camera now",
        ])
    }

    func testAttachSheetActionClosuresFire() {
        var fileFired = false
        var photoFired = false
        var cameraFired = false
        let sheet = makeAttachSheet(
            onChooseFile:   { fileFired   = true },
            onPhotoLibrary: { photoFired  = true },
            onTakePhoto:    { cameraFired = true }
        )
        sheet.actions[0].action()
        sheet.actions[1].action()
        sheet.actions[2].action()
        XCTAssertTrue(fileFired)
        XCTAssertTrue(photoFired)
        XCTAssertTrue(cameraFired)
    }

    func testAttachSheetBodyConstructs() {
        let sheet = makeAttachSheet()
        _ = sheet.body  // sanity: KeepurActionSheet still composes the wired actions
    }
}
```

**Verification:** file compiles inside test target.

### Step 4: Wire the new test file into Xcode project

Use `xcodeproj` Ruby gem (per project convention from theming epic). Script template:

```ruby
require 'xcodeproj'
project = Xcodeproj::Project.open('Keepur.xcodeproj')
group_tests = project.main_group['KeeperTests']

ref = group_tests.new_reference('MessageInputBarAttachSheetTests.swift')
project.targets.each do |t|
  next unless t.name.include?('Tests')
  t.source_build_phase.add_file_reference(ref)
end

project.save
```

**Verification:** `git diff Keepur.xcodeproj/project.pbxproj` shows file ref added to the test target's source build phase.

### Step 5: Run test suite

```bash
xcodebuild test -project Keepur.xcodeproj -scheme Keepur \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing KeeperTests/MessageInputBarAttachSheetTests \
  -quiet
```

Then full suite to confirm no regression:

```bash
xcodebuild test -project Keepur.xcodeproj -scheme Keepur \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -quiet
```

**Verification:** both exit 0; new test class shows 4 passes; total test count = previous + 4.

### Step 6: Commit

```
feat: attach action sheet — KeepurActionSheet replaces popover (KPR-154)

Layer-3 design v2 consumer migration. MessageInputBar's attach popover
is replaced with KeepurActionSheet (medium detent) hosting three rows:
Choose file (doc importer), Photo library (PhotosPicker via
.photosPicker(isPresented:)), and Take photo (placeholder alert until
KPR-159 wires real camera capture). External MessageInputBar API
unchanged; ChatView and TeamChatView consumers untouched. Smoke tests
assert sheet title, subtitle, three-row order/copy/symbols, and that
each action closure dispatches.

Closes KPR-154
```

## Test Groups

| Group | Coverage | File |
|---|---|---|
| **Unit (smoke)** | Attach sheet shape: title + subtitle + 3 ordered rows + symbols + per-row subtitles + action closures dispatch + `KeepurActionSheet.body` composes | `KeeperTests/MessageInputBarAttachSheetTests.swift` |
| **Integration** | N/A — sheet/picker presentation is covered by SwiftUI itself; manual smoke during quality gate confirms the picker flows on iOS sim |  |
| **E2E** | N/A — no automated UI test infrastructure in repo |  |

## Risks / Mitigations

| Risk | Mitigation |
|---|---|
| `.sheet` ↔ `.fileImporter` / `.photosPicker` modal collision on iOS (presenting one before the prior dismisses produces a silent no-op) | Each row closure flips `showAttachmentOptions = false` first, then defers the destination flag with `DispatchQueue.main.async` so the sheet's dismissal animation completes before the destination presents. Documented in the spec; verified by manual smoke during quality gate. |
| `.presentationDetents([.medium])` is iOS-only and silently ignored on macOS | Acceptable — sheet renders at natural size on macOS, no `#if os(...)` needed. Confirmed by `KeepurActionSheet`'s own foundation tests passing on both platforms. |
| Removing the inline `PhotosPicker` view-based picker breaks the photo flow | Replaced with `.photosPicker(isPresented:selection:matching:)` modifier which is the supported sheet-driven alternative; `selection: $selectedPhoto` binding is unchanged so the existing `.onChange(of: selectedPhoto)` loader fires identically. |
| Camera row tap looks broken (silent / no-op) | Wired to a real `.alert` with single-button dismissal that names the held ticket KPR-159; satisfies the spec's "Wired to placeholder alert until held feature ticket lands" requirement. |
| Test re-constructs the sheet rather than introspecting `MessageInputBar` | Documented limitation — `MessageInputBar` owns a `@ObservedObject SpeechManager` whose init is unsafe in test env (Speech framework / mic permission). Parallel-construction shape tests are the same approach used by the foundation-composites tests in the epic. Drift between production and test construction is caught by manual quality-gate smoke. |
| Project file (`project.pbxproj`) corrupted by `xcodeproj` gem mid-edit | Run `git diff project.pbxproj` after script; revert and retry if anything looks off; gem is well-tested in this repo. |
| Build cache stale-index warnings on SwiftPM dirs | Cosmetic; `xcodebuild` exit code is authoritative (per theming epic notes). |

## Dependencies Check

- **External (foundation composite):** `KeepurActionSheet` confirmed present at `Theme/Components/KeepurActionSheet.swift` (KPR-146 already shipped on epic branch). Public init `KeepurActionSheet(title:subtitle:actions:)` accepts `[KeepurActionSheet.Action]` with `(symbol: String, title: String, subtitle: String?, action: () -> Void)` — matches the wiring in step 1.
- **External (SwiftUI modifier):** `.photosPicker(isPresented:selection:matching:)` — available from PhotosUI on iOS 16+ / macOS 13+; well below the project's iOS 26.2+ / macOS 15+ floor.
- **External (existing state):** `selectedPhoto: PhotosPickerItem?`, `showDocumentPicker: Bool`, `attachmentError: String?` — all present in current `MessageInputBar.swift`, untouched.
- **External (test target):** existing `KeeperTests/KeepurFoundationCompositesTests.swift` confirms `@testable import Keepur` reaches `KeepurActionSheet`'s public initializer and lets us read `.title`, `.subtitle`, `.actions` for assertions.
- **Ticket dependencies:** KPR-146 (composites) — shipped. No other blocks.

## Human Signoff

Pre-approved per durable user delegation (KPR-142 design v2 epic). No human plan-review checkpoint required.
