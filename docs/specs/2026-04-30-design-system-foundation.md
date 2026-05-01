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
- Dark-mode work beyond what `KeepurTheme.Color.*Dynamic` already provides. **Note:** the `dynamic(light:dark:)` helper is gated by `#if canImport(UIKit)` and falls through to the `light` value on macOS. So `*Dynamic` aliases used on macOS are effectively static-light until a follow-up ports them to `NSColor(name:dynamicProvider:)`. Acceptable for this ticket because no view migrations land here.
- Any visual change a user can see.

## Design Decisions

### D1. Font sourcing — bundle from JetBrains official release, pinned

The design-system kit references a `fonts/` directory but ships empty (web side loads from Google Fonts at runtime; iOS can't). We download three weights from [github.com/JetBrains/JetBrainsMono](https://github.com/JetBrains/JetBrainsMono) and commit the `.ttf` files. Pinning the version makes the commit reproducible and the smoke test's PostScript-name expectations stable across re-runs.

**Pinned version: v2.304** (current stable as of 2026-04-30, OFL-1.1). This is the single source of truth — all other references in this spec derive from this line. If step 1's precondition finds v2.304 unpublished or yanked, update *only this line* to the next stable tag; downstream steps reference "the version pinned in D1" rather than the literal tag.

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
    let weights: [(name: String, file: String)] = [
        (KeepurTheme.FontName.mono,       "JetBrainsMono-Regular"),
        (KeepurTheme.FontName.monoMedium, "JetBrainsMono-Medium"),
        (KeepurTheme.FontName.monoBold,   "JetBrainsMono-SemiBold"),
    ]
    for (name, file) in weights {
        // Bundle presence — catches removal from Copy Bundle Resources.
        XCTAssertNotNil(
            Bundle.main.url(forResource: file, withExtension: "ttf"),
            "\(file).ttf missing from bundle"
        )
        // Font resolves by PostScript name — catches missing plist entry,
        // wrong PostScript name, and guards against accidentally hitting a
        // system-installed JetBrains Mono on dev machines (Homebrew users).
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

Two asserts per weight cover the full regression surface: bundle presence catches "removed from Copy Bundle Resources"; font-by-name catches "missing plist entry / wrong PostScript name / shadowed by a system install". Hex-color parsing and other token correctness are out of scope — pure compute on stdlib types.

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

1. **Preconditions** (verify at implementation time; all expected to already hold against `main` HEAD):
   - **No `Color(hex:)` collision** — `grep -rn "extension Color\b" .` and `grep -rn "init(hex:" .` should return nothing matching the Swift port's signature. If one exists, reconcile before adding `KeepurTheme.swift`.
   - **`KeeperTests` is dual-targeted** — `SUPPORTED_PLATFORMS` for the test target should include `macosx`. As of 2026-04-30 this is already true (`Keepur.xcodeproj/project.pbxproj` lines 287/308). If a future change has removed macOS, restore it as part of step 6.
   - **macOS test scheme actually runs the test bundle** — target membership alone doesn't guarantee a scheme exercises it. The project has no shared schemes (`Keepur.xcodeproj/xcshareddata/xcschemes/` is empty); schemes are autogenerated per developer in `xcuserdata/`. Verify in Xcode → Product → Scheme → Edit Scheme → Test that `KeeperTests` is checked under the macOS scheme. If not, check it. Without this, the macOS branch of the smoke test never executes and D4's regression catch is a no-op there.
   - **macOS app target shares `Info.plist`** — `INFOPLIST_FILE = Info.plist` should resolve in the macOS build configuration too (currently visible at lines 445/491 in `project.pbxproj`). If the macOS config has been split out to a different plist, update both files or consolidate.
   - **Pinned font release exists** — JetBrainsMono occasionally skips patch numbers between releases; confirm the version pinned in D1 is published before downloading. If not, update D1 only (step 2 below derefs D1) to the next stable tag.
2. Download the JetBrains Mono release pinned in D1; extract Regular / Medium / SemiBold `.ttf` files. Confirm PostScript names match `KeepurTheme.FontName.*` constants — `JetBrainsMono-Regular`, `JetBrainsMono-Medium`, `JetBrainsMono-SemiBold`. To inspect PostScript names, prefer `fc-scan --format "%{postscriptname}\n" <file>.ttf` (Homebrew fontconfig) or a Swift one-liner via `CTFontManagerCreateFontDescriptorsFromURL` — `mdls -name kMDItemFonts` returns the human-readable name, not always the PostScript name. If they mismatch, update either the constants or rename the files.
3. Create `Theme/` and `Fonts/` directories at repo root. Drop in the files above.
4. Add file references to `Keepur.xcodeproj`:
   - `Theme/KeepurTheme.swift` → **Compile Sources** for both iOS and macOS targets.
   - Each `Fonts/*.ttf` → **Copy Bundle Resources** for both iOS and macOS targets independently. In `project.pbxproj`, every `.ttf` must appear in *each* target's `PBXResourcesBuildPhase` section. Missing one is the classic "works on iOS, font missing on macOS" failure that the smoke test below is designed to catch.
   - `Fonts/OFL.txt` → **Copy Bundle Resources** for both iOS and macOS targets (license redistribution travels with the font binaries on every platform that ships them).
5. Update `Info.plist` per D2.
6. Write the smoke test per D4 in `KeeperTests`. Dual-targeting is verified in step 1's preconditions and is expected to already be in place — if step 1 found it missing, restore it here before writing the test. Without macOS test execution, D4 cannot catch macOS-specific font registration regressions and the ticket's main quality gate is a no-op there.
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
