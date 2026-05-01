# Keepur iOS — Design System Foundation

**Date**: 2026-04-30
**Status**: Draft
**Ticket**: [DOD-389](https://linear.app/dodihome/issue/DOD-389/keepur-ios-adopt-keepur-design-system-foundation-theme-tokens)

## Problem

The Keepur Design System (`~/Downloads/Keepur Design System (1)/`) defines the brand: honey accent (`#F5A524`), wax warm neutrals, charcoal text, SF for UI, JetBrains Mono for code. A Swift port (`~/Downloads/KeepurTheme.swift`) translates the CSS tokens into typed SwiftUI constants.

The iOS client today has no central theme. Colors and fonts are inlined across 14+ views (`Color.orange`, `.font(.headline)`, etc.). Without tokens, brand drift is inevitable and per-screen migration to the new design has nothing to migrate *to*.

This ticket lays the foundation only. **No view migrations.** Each screen's redesign will land as its own follow-up PR so the visual diff is reviewable in isolation.

## Scope

### In

1. Add `KeepurTheme.swift` (the generated Swift port) to the project under a new `Theme/` group.
2. Bundle JetBrains Mono Regular / Medium / SemiBold from the official open-source release.
3. Register the fonts on **both iOS and macOS** via `Info.plist`.
4. Cross-platform smoke test asserting the three font names resolve.

### Out

- Migrating any existing view to use the tokens (separate epic).
- Inter Tight or IBM Plex Sans — the Swift port intentionally uses SF for UI.
- Dark-mode work beyond what `KeepurTheme.Color.*Dynamic` already provides.
- Any visual change a user can see.

## Design Decisions

### D1. Font sourcing — bundle from JetBrains official release, pinned

The design-system kit references a `fonts/` directory but ships empty (web side loads from Google Fonts at runtime; iOS can't). We download three weights from [github.com/JetBrains/JetBrainsMono](https://github.com/JetBrains/JetBrainsMono) **release v2.304** (current stable as of 2026-04-30, OFL-1.1) and commit the `.ttf` files. Pinning the version makes the commit reproducible and the smoke test's PostScript-name expectations stable across re-runs.

Rationale: JetBrains Mono is the brand's intended monospace and is visibly different from SF Mono. The added bundle size is ~600 KB total. SF Mono fallback is acceptable but loses brand fidelity in pairing codes, code blocks, and `.mono` eyebrow treatments — exactly the surfaces that lean on monospace character.

The OFL license requires keeping the LICENSE file with redistribution. We commit `OFL.txt` alongside the fonts.

### D2. Cross-platform font registration

The project supports iOS 26.2+ and macOS 15+. `UIAppFonts` only registers fonts on iOS. macOS uses `ATSApplicationFontsPath` in Info.plist.

We register both via the existing shared `Info.plist` (both iOS and macOS targets reference the same file via `INFOPLIST_FILE = Info.plist;`). The unused key on each platform is silently ignored — `UIAppFonts` is iOS-only and `ATSApplicationFontsPath` is macOS-only.

```xml
<key>UIAppFonts</key>
<array>
    <string>JetBrainsMono-Regular.ttf</string>
    <string>JetBrainsMono-Medium.ttf</string>
    <string>JetBrainsMono-SemiBold.ttf</string>
</array>
<key>ATSApplicationFontsPath</key>
<string>.</string>
```

`ATSApplicationFontsPath` is a path relative to the bundle's Resources directory; `.` means "scan all bundled fonts." This is simpler than enumerating files and matches the iOS list.

Note: the project also has `GENERATE_INFOPLIST_FILE = YES`. Xcode merges any `INFOPLIST_KEY_*` build settings on top of `Info.plist` contents — both approaches coexist. We use the file because it's already the established pattern (see `NSAppTransportSecurity`, `NSMicrophoneUsageDescription`, etc.).

### D3. File placement

```
Theme/
    KeepurTheme.swift         (the generated Swift port; one file for now)
Fonts/
    JetBrainsMono-Regular.ttf
    JetBrainsMono-Medium.ttf
    JetBrainsMono-SemiBold.ttf
    OFL.txt                   (license redistribution)
```

A new top-level `Theme/` group keeps brand foundation distinct from `Extensions/` (which holds platform-shim utilities like `Color+Platform.swift`). `Fonts/` at the root is the iOS convention.

### D4. Smoke test

One test in `KeeperTests/`:

```swift
func testJetBrainsMonoFontsRegister() {
    for name in [KeepurTheme.FontName.mono,
                 KeepurTheme.FontName.monoMedium,
                 KeepurTheme.FontName.monoBold] {
        #if os(iOS)
        XCTAssertNotNil(UIFont(name: name, size: 14),
                        "Font \(name) failed to register")
        #else
        XCTAssertNotNil(NSFont(name: name, size: 14),
                        "Font \(name) failed to register")
        #endif
    }
}
```

This catches every regression that matters: missing `.ttf`, wrong PostScript name, missing plist entry on either platform. Hex-color parsing and other token correctness are out of scope — they're pure compute on stdlib types.

## File Layout (after this ticket)

```
Theme/
    KeepurTheme.swift                       (NEW, ~340 LOC)
Fonts/
    JetBrainsMono-Regular.ttf               (NEW, ~200 KB)
    JetBrainsMono-Medium.ttf                (NEW, ~200 KB)
    JetBrainsMono-SemiBold.ttf              (NEW, ~200 KB)
    OFL.txt                                 (NEW, license)
Info.plist                                  (UPDATED, +UIAppFonts and +ATSApplicationFontsPath)
KeeperTests/
    KeepurThemeFontsTests.swift             (NEW)
Keepur.xcodeproj/project.pbxproj            (UPDATED, file references for above)
```

## Implementation Outline

1. **Preconditions**:
   - Confirm no existing `Color(hex:)` extension in the repo (`grep -rn "extension Color\b" .` and `grep -rn "init(hex:" .`). If one exists, reconcile before adding the Swift port.
   - Confirm `KeeperTests` target's supported platforms include macOS. If iOS-only, dual-target it as part of step 6 below (this is a hard requirement, not optional — see step 6).
2. Download JetBrains Mono **release v2.304** (pinned per D1); extract Regular / Medium / SemiBold `.ttf` files. Confirm PostScript names match `KeepurTheme.FontName.*` constants — `JetBrainsMono-Regular`, `JetBrainsMono-Medium`, `JetBrainsMono-SemiBold`. If they don't, update either the constants or rename the files (PostScript names live inside the binary and can be inspected with `mdls -name kMDItemFonts`).
3. Create `Theme/` and `Fonts/` directories at repo root. Drop in the files above.
4. Add file references to `Keepur.xcodeproj`:
   - `Theme/KeepurTheme.swift` → **Compile Sources** for both iOS and macOS targets.
   - Each `Fonts/*.ttf` → **Copy Bundle Resources** for both iOS and macOS targets independently. In `project.pbxproj`, every `.ttf` must appear in *each* target's `PBXResourcesBuildPhase` section. Missing one is the classic "works on iOS, font missing on macOS" failure that the smoke test below is designed to catch.
   - `Fonts/OFL.txt` → **Copy Bundle Resources** (license redistribution).
5. Update `Info.plist` per D2.
6. Write the smoke test per D4 in `KeeperTests`. **`KeeperTests` must be dual-targeted (iOS + macOS) before this ticket ships** — without macOS test execution, D4 cannot catch macOS-specific font registration regressions and the ticket's main quality gate is a no-op there. Per step 1's precondition, dual-targeting is part of the implementation work, not a ship-time fallback.
7. Run the test suite on both iOS and macOS schemes. Confirm the new test passes on each.
8. Sanity-check that no existing test or view broke (none should — this is pure addition).

## Risks & Open Questions

- **PostScript-name mismatch**: If the `.ttf` files in the latest release don't expose PostScript names matching the constants in the Swift port, the smoke test will fail. Mitigation: inspect the binaries before commit and update either side as needed. The constants live in `KeepurTheme.FontName` and are easy to change.
- **macOS `ATSApplicationFontsPath` quirk**: `.` is the conventional value but some references suggest it should be a subdirectory like `Fonts`. If runtime registration on macOS fails, fall back to either (a) a subpath value or (b) runtime `CTFontManagerRegisterFontsForURL` registration in `KeepurApp.init()`. The smoke test will catch this immediately.
- **Bundle size**: ~600 KB added to the app. Acceptable for the brand benefit.
- **`Color(hex:)` namespace collision**: The Swift port adds a public `Color(hex: UInt32, opacity:)` initializer extension. Re-verify at implementation time per step 1's precondition — collision-free as of spec authoring on 2026-04-30, but the check should happen against the branch HEAD at code-gen time in case main has moved.

## Follow-up

After this lands, file a per-screen migration epic (separate brainstorm):
Pairing, Chat, MessageBubble, MessageInputBar, SessionList, Settings, Workspace picker, Tool approval, Hive (Team) views.
