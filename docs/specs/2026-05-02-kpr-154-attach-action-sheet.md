# KPR-154 — Attach action sheet (rich bottom sheet)

**Date:** 2026-05-02
**Epic:** [KPR-142 design v2](https://linear.app/keepur/issue/KPR-142)
**Layer:** 3 (per-screen consumption)
**Depends on:** KPR-146 (foundation composites — `KeepurActionSheet`)

## Problem

Today's attach affordance in `Views/MessageInputBar.swift` (lines 30-64) presents a 200pt-wide popover anchored to the `+` button. The popover stacks two un-iconed `Label`-based buttons (`Choose File`, `Photo Library`) in a thin vertical list with a hairline `Divider` between them. There is no header, no subtitle, no per-row context, no chevron, and no third "Take photo" affordance the design v2 mockups call for. On iOS the popover renders as a hovering capsule that collides poorly with the input bar's blurred `.ultraThinMaterial` background; on macOS it's a tight free-floating panel that doesn't match the otherwise-branded chrome.

The mockups for design v2 specify a full-width branded bottom sheet with a title, subtitle, and three rich rows (icon container + title + subtitle + chevron). The `KeepurActionSheet` foundation composite (KPR-146) provides exactly this surface — KPR-154 is the consumer migration.

## Solution

Surgical edit to `MessageInputBar` only. Replace the `.popover(isPresented:) { VStack { ... } }` with a `.sheet(isPresented:) { KeepurActionSheet(...).presentationDetents([.medium]) }`. The sheet contains three actions wired to the existing pickers (`fileImporter`, `PhotosPicker`-backed flow) plus a new placeholder alert for "Take photo" (gated behind held feature ticket KPR-159).

The `+` button itself, the `pendingAttachment` state, the photo loading `Task`, the `loadAttachment(from:)` helper, the `selectedPhoto: PhotosPickerItem?` binding, the file-importer wiring, the macOS `dropDestination`, the 10MB cap, and the existing `attachmentError` alert all stay exactly as they are. Only the menu surface itself changes.

The current attach popover uses an inline `PhotosPicker` whose `selection: $selectedPhoto` binding triggers the existing `.onChange(of: selectedPhoto)` loader. We can't put a `PhotosPicker` inside a `KeepurActionSheet.Action` (it's a closure-based row, not a view-based row). The migration therefore introduces a separate `@State private var showPhotoPicker = false` flag, presents the system `PhotosPicker` as a modifier `.photosPicker(isPresented:selection:matching:)` on the input bar, and the action sheet's "Photo library" row simply flips that flag (just like "Choose file" already flips `showDocumentPicker`).

## Key Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Sheet vs popover | `.sheet(isPresented:)` with `.presentationDetents([.medium])` | Backlog explicit: "Replace popover with `KeepurActionSheet` (medium detent)". Matches `KeepurActionSheet`'s documented integration pattern. |
| Photo library row mechanism | Bottom-sheet row flips `showPhotoPicker = true`; outer view applies `.photosPicker(isPresented:selection:matching:)` | `KeepurActionSheet.Action` only takes a `() -> Void`; can't host a view-based `PhotosPicker` inside the row label. The sheet-driven `photosPicker(isPresented:)` modifier is the official replacement and re-uses the existing `selectedPhoto` state and `.onChange` loader unchanged. |
| Sheet auto-dismiss | Each action closure sets `showAttachmentOptions = false` before triggering its destination state | Matches existing popover behavior (row tap currently sets `showAttachmentOptions = false` then opens picker). Without explicit dismissal the sheet would stay over the document/photo picker, layering two modals on iOS. |
| Sheet/picker presentation ordering | Use `DispatchQueue.main.async` (or `Task { @MainActor in }`) to set the destination flag after the sheet has dismissed | `.sheet` ↔ `.fileImporter` / `.photosPicker` modal collisions are a well-known SwiftUI footgun on iOS — presenting one before the prior dismisses produces silent no-ops. Deferring one runloop tick after the sheet flag flips lets the outgoing sheet finish its dismissal animation cleanly. The current popover flow doesn't need this because popovers are non-modal on iOS, but full sheets do. |
| Camera row behavior | Wired to `showCameraPlaceholder = true` flag; outer view shows a single-button `Alert` titled "Camera capture coming soon" with body "Take photo will be wired up when KPR-159 lands. For now, choose a file or pick from your photo library." Single OK button, no destructive role. | Backlog explicit: "Wired to placeholder alert until held feature ticket lands." Constraint: must be a real alert, not silent no-op. Copy mentions the held ticket so a curious tester can find it in Linear. Shorter "Coming soon" was considered but provides less context to internal users running design-v2 builds. |
| Camera SF Symbol | `"camera"` (filled variant of system camera icon) | Matches the foundation composite's smoke-test row in `KeepurFoundationCompositesTests` and standard iOS attach-menu convention (Messages, Mail). |
| Choose file SF Symbol | `"doc"` | Matches existing popover's `Label("Choose File", systemImage: "doc")` — preserves visual continuity. |
| Photo library SF Symbol | `"photo"` | Matches existing popover's `Label("Photo Library", systemImage: "photo")` — preserves visual continuity. |
| Title / subtitle copy | `"Attach"` / `"Add a file or photo to the message."` | Verbatim from backlog. Title in `Font.h3`, subtitle in `Font.bodySm` — already baked into `KeepurActionSheet`. |
| Row title / subtitle copy | "Choose file" / "Browse documents on this device", "Photo library" / "Pick from your photos", "Take photo" / "Use the camera now" | Verbatim from backlog. Note "Choose file" (lowercase 'f') replaces today's "Choose File" — matches backlog phrasing. |
| Sheet detent | `[.medium]` only (not also `.large`) | Backlog explicit: "medium detent". Three rows + header fit comfortably in medium; no need for resize affordance. Matches `KeepurActionSheet`'s doc-comment integration example verbatim. |
| Existing 200pt popover frame | Removed | Backlog replaces the entire popover with a sheet; the sheet is full-width, not a fixed 200pt panel. |
| macOS behavior | Same `.sheet` modifier | `KeepurActionSheet` works on both platforms (no `UIKit` deps). `.presentationDetents` is iOS-only but is silently ignored on macOS — the sheet just renders at its natural size. No `#if os(...)` needed. |
| Order of rows | Choose file → Photo library → Take photo | Backlog list order; "Take photo" intentionally last because it's not yet functional and shouldn't be the most prominent option. |
| Error alert / attachment error binding | Unchanged | The existing `.alert("Attachment Error", isPresented: ...)` for size/load failures stays. The new camera placeholder alert is a separate `.alert` modifier with its own `@State` flag. |

## Visual Spec

### Sheet body (rendered by `KeepurActionSheet`)

```
┌──────────────────────────────────────────────────────────┐
│  (medium detent — ~50% of screen height on iOS)          │
│                                                          │
│  Attach                                       (Font.h3)  │
│  Add a file or photo to the message.       (Font.bodySm) │
│                                                          │
│  ┌────────────────────────────────────────────────────┐  │
│  │ ┌────┐                                          ›  │  │
│  │ │ 📄 │  Choose file                                │  │
│  │ │    │  Browse documents on this device            │  │
│  │ └────┘                                             │  │
│  └────────────────────────────────────────────────────┘  │
│  ┌────────────────────────────────────────────────────┐  │
│  │ ┌────┐                                          ›  │  │
│  │ │ 🖼️ │  Photo library                              │  │
│  │ │    │  Pick from your photos                      │  │
│  │ └────┘                                             │  │
│  └────────────────────────────────────────────────────┘  │
│  ┌────────────────────────────────────────────────────┐  │
│  │ ┌────┐                                          ›  │  │
│  │ │ 📷 │  Take photo                                 │  │
│  │ │    │  Use the camera now                         │  │
│  │ └────┘                                             │  │
│  └────────────────────────────────────────────────────┘  │
│                                                          │
└──────────────────────────────────────────────────────────┘
```

All visual styling (icon container fill `accentTint`, icon tint `honey700`, row background `bgSurfaceDynamic`, chevron `fgTertiary`, etc.) is owned by `KeepurActionSheet` itself — no overrides needed. KPR-154 is purely a wiring change.

### Action wiring

```swift
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
```

### Camera placeholder alert

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

### State surface (added)

| Field | Type | Default | Replaces |
|---|---|---|---|
| `showPhotoPicker` | `@State Bool` | `false` | Inline `PhotosPicker` inside popover |
| `showCameraPlaceholder` | `@State Bool` | `false` | (new — camera row didn't exist) |

`showAttachmentOptions`, `showDocumentPicker`, `selectedPhoto`, `attachmentError`, `pendingAttachment` — all unchanged.

### Modifier diff on the input bar's outermost `VStack`

**Removed:**
- `.popover(isPresented: $showAttachmentOptions) { VStack { Choose-File-Button; Divider; PhotosPicker } .frame(width: 200) }` — anchored on the `+` button itself
- The inline `PhotosPicker` view inside the popover

**Added:**
- `.sheet(isPresented: $showAttachmentOptions) { KeepurActionSheet(...).presentationDetents([.medium]) }` — applied to the outermost `VStack` (not the `+` button)
- `.photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhoto, matching: .images)` — applied to the outermost `VStack`
- `.alert("Camera capture coming soon", isPresented: $showCameraPlaceholder) { ... }` — applied to the outermost `VStack`

**Unchanged:**
- `.fileImporter(isPresented: $showDocumentPicker, allowedContentTypes: [.item]) { ... }` — same closure body
- `.alert("Attachment Error", ...)` — unchanged
- `.onChange(of: selectedPhoto) { ... }` — unchanged (loader logic re-used by both pickers)
- `.onReceive(speechManager.$liveText) { ... }` — unchanged
- macOS `.dropDestination(for: URL.self) { ... }` — unchanged

### Token map

All visual tokens are owned by `KeepurActionSheet` itself (already verified in KPR-146 spec). MessageInputBar adds no new token references. Tokens consumed transitively via the composite:

| Element | Token |
|---|---|
| Sheet outer padding | `Spacing.s4` horizontal, `s5` top, `s4` bottom |
| Header → rows spacing | `Spacing.s4` |
| Row icon container | 40×40, `Radius.sm`, fill `Color.accentTint` (which is `honey100`), icon `Color.honey700` |
| Row text title | `Font.body`, `fgPrimaryDynamic` |
| Row text subtitle | `Font.caption`, `fgSecondaryDynamic` |
| Row chevron | `Font.bodySm`, `fgTertiary` |
| Row background | `bgSurfaceDynamic`, `Radius.sm` |
| Sheet background | `bgPageDynamic` |
| Title | `Font.h3` + `tracking(lsH3)`, `fgPrimaryDynamic` |
| Subtitle | `Font.bodySm`, `fgSecondaryDynamic` |

### Edge cases

- **User taps `+` while `pendingAttachment` is non-nil:** sheet still opens; user can attach a second file (which replaces the first — existing behavior, not part of this scope).
- **User taps Take photo, dismisses alert, taps Take photo again:** alert re-opens via `showCameraPlaceholder` flipping false → true. Standard `.alert` semantics; no leaked state.
- **User taps Choose file, sheet dismisses, file picker opens, user cancels file picker:** falls through `case .failure: break` in `fileImporter` — no error alert, no state change. Matches existing behavior.
- **User selects photo: photo picker dismisses, `selectedPhoto` non-nil, existing `.onChange` loads it into `pendingAttachment`.** No change.
- **macOS `.presentationDetents` is iOS-only:** silently ignored on macOS; sheet renders at natural size. No `#if os(...)` needed.
- **Sheet collision with `attachmentError` alert:** independent flags; if loading the attachment after the sheet dismisses produces an error, that alert presents on the input bar in the usual way. The new camera-placeholder alert and the size/load-error alert have separate `@State` flags and never need to coexist.
- **Rapid double-tap on a row:** the `DispatchQueue.main.async` defer prevents the destination modal from racing the sheet dismissal. Worst case: sheet dismisses → destination opens. Acceptable.
- **VoiceOver:** each row already announces title + subtitle via `KeepurActionSheet`'s built-in `.accessibilityLabel("\(title), \(subtitle ?? "")")` and hint "Double tap to select." No additional accessibility work required at this site.

## Files Touched

- `Views/MessageInputBar.swift` — replace popover with sheet, add `showPhotoPicker` + `showCameraPlaceholder` state, add `.photosPicker` modifier, add camera placeholder alert
- `KeeperTests/MessageInputBarAttachSheetTests.swift` (new) — smoke tests for the action-sheet construction (testing the sheet `KeepurActionSheet` factory in isolation; not the full `MessageInputBar.body` which depends on `SpeechManager`)
- `Keepur.xcodeproj/project.pbxproj` — wire the new test file into the test target

No changes to `Views/ChatView.swift` or `Views/Team/TeamChatView.swift` (the two `MessageInputBar` consumers) — the input bar's external API is unchanged.

## Smoke Test Scope

Single new test file `KeeperTests/MessageInputBarAttachSheetTests.swift`. Per the constraint "Don't smoke-test full View bodies depending on @StateObject/Keychain," we do **not** instantiate `MessageInputBar.body` directly (it owns a `@ObservedObject SpeechManager` whose init touches Speech framework / mic permission). Instead we extract the attach-sheet factory into a static helper on `MessageInputBar` (or test it as a free function in the test file by mirroring the construction) and assert:

| Case | Assertion |
|---|---|
| Action sheet has title "Attach" and the verbatim subtitle | `sheet.title == "Attach"`, `sheet.subtitle == "Add a file or photo to the message."` |
| Action sheet has exactly 3 actions in declared order | `sheet.actions.count == 3`; titles `["Choose file", "Photo library", "Take photo"]`; symbols `["doc", "photo", "camera"]`; subtitles match backlog copy |
| Each action's closure flips its corresponding flag without crashing | Construct the sheet with capture-by-reference flag mutations and invoke each closure; assert the right flag flipped to `true` |
| `KeepurActionSheet` body itself constructs without crash | `_ = sheet.body` (re-verifies the composite still composes the wired-up actions correctly) |

The test extracts the sheet construction into a top-level test helper that mirrors the production builder; the production code's actual inline construction is identical, so the test exercises the real shape (titles, subtitles, symbols) without trying to touch `MessageInputBar`'s `@ObservedObject` graph.

We **do not** assert `.presentationDetents` (no public introspection API in stock SwiftUI), **do not** snapshot, **do not** instantiate `MessageInputBar` itself, and **do not** assert that the destination flags actually present pickers (out of unit-test scope; those are SwiftUI modifiers exercised by manual smoke-testing during quality gate).

## Out of Scope

- **Camera capture itself** — held in KPR-159 (camera capture in attachment picker). This ticket only ships the placeholder.
- **`NSCameraUsageDescription` Info.plist key** — held with KPR-159; not needed for an alert that never invokes `AVCaptureDevice`.
- **macOS-specific camera handling** — held with KPR-159 (whether to hide the row or use `AVCaptureSession`).
- **Edit / crop after capture** — held with KPR-159.
- **Drag-and-drop on iOS** — separate affordance; existing macOS `.dropDestination` is the only drop path and is unchanged.
- **Multiple attachments** — `pendingAttachment` remains single-slot; backlog doesn't expand it.
- **Replacing the `+` button visual** — unchanged (still `KeepurTheme.Symbol.plus` in `fgMuted`).
- **Updating `ChatView.swift` / `TeamChatView.swift`** — they consume `MessageInputBar` via the same external API; no change required.

## Open Questions

None. Backlog scope is unambiguous (replace popover with `KeepurActionSheet` medium-detent, three rows with verbatim copy, camera row → placeholder alert). All required tokens, the `KeepurActionSheet` composite, and the `.photosPicker(isPresented:selection:matching:)` modifier are confirmed present in the epic worktree.

## Dependencies / Sequencing

- **Blocked by:** KPR-146 (`KeepurActionSheet` must exist in `Theme/Components/`). Already shipped on epic branch — confirmed by direct file read of `Theme/Components/KeepurActionSheet.swift`.
- **Soft dependency on:** none.
- **Blocks:** none. KPR-159 (held feature: camera capture) will replace the placeholder alert wiring with real camera presentation, but does not block this ticket.

## Human Signoff

Pre-approved per durable user delegation (KPR-142 design v2 epic — mockups already approve component intent; user explicit: "as long as it more or less looks like the mockup, I don't care beyond that"). Recorded in epic-orchestrator memory.
