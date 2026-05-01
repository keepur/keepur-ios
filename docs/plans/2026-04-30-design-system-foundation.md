# Design System Foundation Implementation Plan

> **For agentic workers:** Use `dodi-dev:implement` to execute this plan.

**Goal:** Land the Keepur Design System foundation on iOS+macOS — `Theme/KeepurTheme.swift` token file, JetBrains Mono v2.304 font bundling, cross-platform Info.plist registration, and a smoke test that proves the fonts resolve at runtime. Zero view migrations.

**Architecture:** A new `Theme/` group holds the typed brand tokens (`KeepurTheme.Color`, `.Font`, `.Spacing`, `.Radius`, `.Shadow`, `.Motion`, `.Symbol`). A new `Fonts/` group at the repo root holds the three OFL-licensed `.ttf` files plus `OFL.txt`. The shared `Info.plist` registers the fonts via `UIAppFonts` (iOS) and `ATSApplicationFontsPath` (macOS) — the unused key on each platform is silently ignored. A single `XCTestCase` in `KeeperTests/KeepurThemeFontsTests.swift` asserts both bundle presence and PostScript-name resolution for every weight, on whichever platform the test scheme runs.

**Tech Stack:** SwiftUI, XCTest, Xcode 16+. iOS 26.2+ / macOS 15.0+. Ruby `xcodeproj` gem for project file edits.

**Spec:** [docs/specs/2026-04-30-design-system-foundation.md](../specs/2026-04-30-design-system-foundation.md)

**Out of scope for this plan:** All view migrations (separate epic). All visual changes a user can see. Inter Tight / IBM Plex Sans bundling. macOS dark-mode `NSColor` adapter for `*Dynamic` colors.

---

## File Map

| File | Change |
|------|--------|
| `Theme/KeepurTheme.swift` | **Create** — copy of `~/Downloads/KeepurTheme.swift` (~340 LOC, the generated Swift port) |
| `Fonts/JetBrainsMono-Regular.ttf` | **Create** — from `JetBrainsMono-2.304.zip` |
| `Fonts/JetBrainsMono-Medium.ttf` | **Create** — from `JetBrainsMono-2.304.zip` |
| `Fonts/JetBrainsMono-SemiBold.ttf` | **Create** — from `JetBrainsMono-2.304.zip` |
| `Fonts/OFL.txt` | **Create** — from `JetBrainsMono-2.304.zip` (license redistribution) |
| `Info.plist` | **Modify** — add `UIAppFonts` array + `ATSApplicationFontsPath` string |
| `KeeperTests/KeepurThemeFontsTests.swift` | **Create** — single smoke test, dual-platform |
| `Keepur.xcodeproj/project.pbxproj` | **Modify** — file refs for Theme + Fonts + test, in Compile Sources / Copy Bundle Resources for both iOS and macOS targets |

---

## Task 1: Preflight verification

Verify the spec's preconditions hold against the current branch HEAD before touching anything else. If any check fails, **stop and surface to the user** — do not proceed.

**Files:** none (read-only)

- [ ] **Step 1.1:** Verify no `Color(hex:)` collision in the repo.

```bash
grep -rn "extension Color" --include="*.swift" .
grep -rn "init(hex:" --include="*.swift" .
```

Expected: only matches in the generated `Theme/KeepurTheme.swift` if it has already been added (it hasn't — Task 2). Any pre-existing `Color(hex: UInt32, opacity:)` initializer is a blocker — reconcile before continuing.

- [ ] **Step 1.2:** Verify `KeeperTests` is dual-targeted for macOS.

```bash
grep -n "SUPPORTED_PLATFORMS" Keepur.xcodeproj/project.pbxproj
```

Expected: lines around 287/308 read `SUPPORTED_PLATFORMS = "iphoneos iphonesimulator macosx";` for the test target. If macOS is missing, restore it now (this lifts a hard requirement off Task 6).

- [ ] **Step 1.3:** Verify `Info.plist` is shared by the macOS app target.

```bash
grep -n "INFOPLIST_FILE" Keepur.xcodeproj/project.pbxproj
```

Expected: `INFOPLIST_FILE = Info.plist;` appears in both Debug and Release configurations of the main app target (~lines 445/491). If the macOS config has been split out, consolidate before D2's plist edits.

- [ ] **Step 1.4:** Verify the JetBrains Mono v2.304 release tag exists.

```bash
curl -sI https://github.com/JetBrains/JetBrainsMono/releases/download/v2.304/JetBrainsMono-2.304.zip | head -1
```

Expected: `HTTP/2 302` (redirect to the asset). If `404`, the tag has been yanked/skipped — open the spec and update D1 only to the next stable tag, then re-run this step.

- [ ] **Step 1.5:** Verify the macOS test scheme runs the test bundle.

```bash
ls Keepur.xcodeproj/xcshareddata/xcschemes/ 2>/dev/null
ls Keepur.xcodeproj/xcuserdata/*/xcschemes/*.xcscheme 2>/dev/null
```

Expected: no shared schemes; per-user `Keepur.xcscheme` exists in `xcuserdata/`. If a `Keepur.xcscheme` exists, grep it for `KeeperTests`:

```bash
grep -l "KeeperTests" Keepur.xcodeproj/xcuserdata/*/xcschemes/*.xcscheme 2>/dev/null
```

Expected: at least one match. If the scheme exists but does not reference `KeeperTests` under its `<TestAction>`, the implementer must open Xcode → Product → Scheme → Edit Scheme → Test and check `KeeperTests`. Surface this to the user (cannot be done programmatically without parsing the .xcscheme XML).

- [ ] **Step 1.6:** No commit — this task is verification only. Surface the results back to the user as a checklist before proceeding.

---

## Task 2: Add `Theme/KeepurTheme.swift`

**Files:**
- Create: `Theme/KeepurTheme.swift`

- [ ] **Step 2.1:** Create the `Theme/` directory at the repo root.

```bash
mkdir -p Theme
```

- [ ] **Step 2.2:** Copy the generated Swift port into place.

```bash
cp ~/Downloads/KeepurTheme.swift Theme/KeepurTheme.swift
```

- [ ] **Step 2.3:** Sanity-check the file is non-empty and parses as Swift.

```bash
wc -l Theme/KeepurTheme.swift
xcrun swiftc -parse Theme/KeepurTheme.swift 2>&1 | tail -5
```

Expected: ~340 lines; `swiftc -parse` exits 0 with no output (or only platform-conditional warnings). The file imports `SwiftUI` and `UIKit` (gated by `#if canImport(UIKit)`), so `-parse` won't pull in those frameworks — that's fine, parse only checks syntax.

- [ ] **Step 2.4:** Commit (file is on disk but not yet in the Xcode project — that's Task 5).

```bash
git add Theme/KeepurTheme.swift
git commit -m "$(cat <<'EOF'
feat: add KeepurTheme token file (DOD-389)

Drop in the Swift port of the Keepur Design System tokens. Defines
KeepurTheme.{Color, Font, Spacing, Radius, Shadow, Motion, Symbol}
plus Color(hex:) and View modifiers (.keepurShadow, .keepurBorder,
.keepurFocusRing). Mirror of ~/Downloads/KeepurTheme.swift, which
mirrors colors_and_type.css from the design system kit.

Not yet referenced by any view; not yet wired into the Xcode project
(Task 5 of the implementation plan).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Download and stage JetBrains Mono fonts

**Files:**
- Create: `Fonts/JetBrainsMono-Regular.ttf`
- Create: `Fonts/JetBrainsMono-Medium.ttf`
- Create: `Fonts/JetBrainsMono-SemiBold.ttf`
- Create: `Fonts/OFL.txt`

- [ ] **Step 3.1:** Download the pinned release zip into a scratch directory.

```bash
SCRATCH=$(mktemp -d)
cd "$SCRATCH"
curl -L -o JetBrainsMono.zip https://github.com/JetBrains/JetBrainsMono/releases/download/v2.304/JetBrainsMono-2.304.zip
unzip -q JetBrainsMono.zip
ls
```

Expected: an `OFL.txt` file at the zip root and a `fonts/` directory containing `ttf/`, `webfonts/`, `variable/` subdirectories. The exact layout occasionally shifts between releases — if `fonts/ttf/JetBrainsMono-Regular.ttf` is not present, run `find . -name "JetBrainsMono-Regular.ttf"` and adapt the paths in step 3.3.

- [ ] **Step 3.2:** Verify PostScript names match the constants in `Theme/KeepurTheme.swift`.

The canonical inspection uses Core Text. If `fc-scan` (Homebrew fontconfig) is installed, this is a one-liner:

```bash
for f in fonts/ttf/JetBrainsMono-{Regular,Medium,SemiBold}.ttf; do
  echo "$f -> $(fc-scan --format '%{postscriptname}\n' "$f")"
done
```

Otherwise, use a Swift one-liner:

```bash
for f in fonts/ttf/JetBrainsMono-{Regular,Medium,SemiBold}.ttf; do
  swift -e "
import Foundation
import CoreText
let url = URL(fileURLWithPath: \"$f\")
let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] ?? []
for d in descriptors {
  let name = CTFontDescriptorCopyAttribute(d, kCTFontNameAttribute) as? String ?? \"?\"
  print(\"$f -> \(name)\")
}
"
done
```

Expected output (PostScript names must match `KeepurTheme.FontName.*` constants exactly):

```
fonts/ttf/JetBrainsMono-Regular.ttf -> JetBrainsMono-Regular
fonts/ttf/JetBrainsMono-Medium.ttf  -> JetBrainsMono-Medium
fonts/ttf/JetBrainsMono-SemiBold.ttf -> JetBrainsMono-SemiBold
```

If a name doesn't match, **either** rename the file so its filename matches the actual PostScript name (and update step 3.3 + the `Bundle.main.url(...)` strings in Task 6's test), **or** edit `Theme/KeepurTheme.swift` to align `KeepurTheme.FontName.*` with what's in the binary. Filename-renaming is usually wrong — PostScript names live inside the binary and are what `UIFont(name:size:)` looks up.

- [ ] **Step 3.3:** Stage the three fonts and the license into the repo's `Fonts/` directory.

```bash
cd /Users/mayhuang/github/keepur-ios-DOD-389  # back to the worktree
mkdir -p Fonts
cp "$SCRATCH"/fonts/ttf/JetBrainsMono-Regular.ttf  Fonts/
cp "$SCRATCH"/fonts/ttf/JetBrainsMono-Medium.ttf   Fonts/
cp "$SCRATCH"/fonts/ttf/JetBrainsMono-SemiBold.ttf Fonts/
cp "$SCRATCH"/OFL.txt                              Fonts/
ls -la Fonts/
rm -rf "$SCRATCH"
```

Expected: `Fonts/` contains three `.ttf` files (~200 KB each) and an `OFL.txt` (~5 KB).

- [ ] **Step 3.4:** Commit.

```bash
git add Fonts/
git commit -m "$(cat <<'EOF'
feat: bundle JetBrains Mono v2.304 fonts (DOD-389)

Add Regular / Medium / SemiBold .ttf weights from the official
JetBrains/JetBrainsMono v2.304 release (OFL-1.1). OFL.txt is
included as required by the license — the license must travel with
redistributed font binaries.

Not yet wired into the Xcode project (Task 5) or the Info.plist
font registration (Task 6 of the implementation plan).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Update `Info.plist` with font registration

**Files:**
- Modify: `Info.plist`

- [ ] **Step 4.1:** Add the two keys before the closing `</dict>`. The Edit tool should match the existing `</dict>\n</plist>` and insert the new keys above it.

Use `Edit` with:

`old_string`:
```
	</dict>
</plist>
```

`new_string`:
```
	<key>UIAppFonts</key>
	<array>
		<string>JetBrainsMono-Regular.ttf</string>
		<string>JetBrainsMono-Medium.ttf</string>
		<string>JetBrainsMono-SemiBold.ttf</string>
	</array>
	<key>ATSApplicationFontsPath</key>
	<string>.</string>
</dict>
</plist>
```

(Note: `Info.plist` uses tab indentation — preserve the existing whitespace style.)

- [ ] **Step 4.2:** Validate the plist is well-formed.

```bash
plutil -lint Info.plist
```

Expected: `Info.plist: OK`

- [ ] **Step 4.3:** Confirm both keys are present and parse correctly.

```bash
plutil -extract UIAppFonts json -o - Info.plist
plutil -extract ATSApplicationFontsPath raw -o - Info.plist
```

Expected output:
```
["JetBrainsMono-Regular.ttf","JetBrainsMono-Medium.ttf","JetBrainsMono-SemiBold.ttf"]
.
```

- [ ] **Step 4.4:** Commit.

```bash
git add Info.plist
git commit -m "$(cat <<'EOF'
feat: register JetBrains Mono in Info.plist for iOS+macOS (DOD-389)

UIAppFonts registers the .ttfs on iOS; ATSApplicationFontsPath = "."
makes macOS scan all bundled fonts. The unused key on each platform
is silently ignored — both targets share this Info.plist.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Wire new files into the Xcode project

**Files:**
- Modify: `Keepur.xcodeproj/project.pbxproj`

`project.pbxproj` is fragile to hand-edit (synthetic 24-char hex IDs, multiple cross-referencing sections). We use the `xcodeproj` Ruby gem for safe edits.

- [ ] **Step 5.1:** Ensure the `xcodeproj` Ruby gem is installed.

```bash
gem list xcodeproj | grep -q xcodeproj || sudo gem install xcodeproj
```

Expected: gem present. If `sudo` is not available in the agent environment, surface to the user and pause — installation requires admin permission on system Ruby. (If the user has rbenv/asdf, they can install without sudo.)

- [ ] **Step 5.2:** Run the wiring script. This adds `Theme/KeepurTheme.swift` to **Compile Sources** for the main app target, and adds each of `Fonts/JetBrainsMono-{Regular,Medium,SemiBold}.ttf` and `Fonts/OFL.txt` to **Copy Bundle Resources** for the main app target. The main app target supports both iOS and macOS via `SUPPORTED_PLATFORMS = "iphoneos iphonesimulator macosx"`, so a single target membership covers both platforms.

Save this as `/tmp/wire_design_system.rb` and run it from the worktree root:

```ruby
#!/usr/bin/env ruby
require 'xcodeproj'

project_path = 'Keepur.xcodeproj'
project = Xcodeproj::Project.open(project_path)

# Find the main app target (the one whose product is "Keepur.app")
app_target = project.targets.find { |t| t.product_reference&.path == 'Keepur.app' }
raise "Main app target not found" unless app_target

main_group = project.main_group

# 1. Theme/KeepurTheme.swift -> Compile Sources
theme_group = main_group.find_subpath('Theme', true)
theme_group.set_source_tree('<group>')
theme_group.set_path('Theme')
unless theme_group.files.any? { |f| f.path == 'KeepurTheme.swift' }
  theme_file = theme_group.new_reference('KeepurTheme.swift')
  app_target.add_file_references([theme_file])
  puts "Added Theme/KeepurTheme.swift to #{app_target.name} sources"
end

# 2. Fonts/* -> Copy Bundle Resources
fonts_group = main_group.find_subpath('Fonts', true)
fonts_group.set_source_tree('<group>')
fonts_group.set_path('Fonts')
font_files = [
  'JetBrainsMono-Regular.ttf',
  'JetBrainsMono-Medium.ttf',
  'JetBrainsMono-SemiBold.ttf',
  'OFL.txt',
]
font_refs = font_files.map do |name|
  existing = fonts_group.files.find { |f| f.path == name }
  existing || fonts_group.new_reference(name)
end
app_target.add_resources(font_refs)
puts "Added #{font_files.size} files to #{app_target.name} resources"

project.save
puts "Saved #{project_path}"
```

Run:
```bash
ruby /tmp/wire_design_system.rb
```

Expected output:
```
Added Theme/KeepurTheme.swift to Keepur sources
Added 4 files to Keepur resources
Saved Keepur.xcodeproj
```

If the script reports "already added" for any item (because `add_file_references` / `add_resources` is idempotent on the build phase but the file references were created first), that's fine — the goal is convergence on the desired state, not a clean re-run.

- [ ] **Step 5.3:** Verify the references landed by grepping `project.pbxproj`.

```bash
grep -c "KeepurTheme.swift" Keepur.xcodeproj/project.pbxproj
grep -c "JetBrainsMono-Regular.ttf" Keepur.xcodeproj/project.pbxproj
grep -c "JetBrainsMono-Medium.ttf" Keepur.xcodeproj/project.pbxproj
grep -c "JetBrainsMono-SemiBold.ttf" Keepur.xcodeproj/project.pbxproj
grep -c "OFL.txt" Keepur.xcodeproj/project.pbxproj
```

Expected: each grep returns at least `2` (one PBXFileReference + one PBXBuildFile entry).

- [ ] **Step 5.4:** Build for iOS to surface any project misconfiguration before tests.

```bash
xcodebuild -project Keepur.xcodeproj -scheme Keepur \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -quiet build 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`. If the build fails with "Multiple commands produce" for a font, the script ran twice and added duplicate entries — open `project.pbxproj` and remove the duplicate `PBXBuildFile`.

- [ ] **Step 5.5:** Build for macOS.

```bash
xcodebuild -project Keepur.xcodeproj -scheme Keepur \
  -destination 'platform=macOS' \
  -quiet build 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5.6:** Commit.

```bash
git add Keepur.xcodeproj/project.pbxproj
git commit -m "$(cat <<'EOF'
build: wire Theme + Fonts into Xcode project (DOD-389)

Add Theme/KeepurTheme.swift to Compile Sources and Fonts/*.{ttf,txt}
to Copy Bundle Resources on the main Keepur target. The target
supports both iOS and macOS via SUPPORTED_PLATFORMS, so a single
membership covers both platforms.

Edits made via the xcodeproj Ruby gem to avoid hand-rolling
synthetic UUIDs in project.pbxproj.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Add the font-registration smoke test

**Files:**
- Create: `KeeperTests/KeepurThemeFontsTests.swift`
- Modify: `Keepur.xcodeproj/project.pbxproj` (add test file to KeeperTests target)

- [ ] **Step 6.1:** Create the test file.

```swift
import XCTest
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
@testable import Keepur

final class KeepurThemeFontsTests: XCTestCase {

    /// Confirms the JetBrains Mono weights referenced by KeepurTheme.FontName
    /// are both bundled and registered. Catches:
    /// - .ttf removed from Copy Bundle Resources (Bundle.main.url assert)
    /// - Wrong PostScript name / missing UIAppFonts entry / shadowed by a
    ///   system-installed JetBrains Mono on dev machines (UIFont/NSFont assert)
    func testJetBrainsMonoFontsRegister() {
        let weights: [(name: String, file: String)] = [
            (KeepurTheme.FontName.mono,       "JetBrainsMono-Regular"),
            (KeepurTheme.FontName.monoMedium, "JetBrainsMono-Medium"),
            (KeepurTheme.FontName.monoBold,   "JetBrainsMono-SemiBold"),
        ]
        for (name, file) in weights {
            XCTAssertNotNil(
                Bundle.main.url(forResource: file, withExtension: "ttf"),
                "\(file).ttf missing from bundle"
            )
            #if canImport(UIKit)
            XCTAssertNotNil(UIFont(name: name, size: 14),
                            "Font \(name) failed to register")
            #else
            XCTAssertNotNil(NSFont(name: name, size: 14),
                            "Font \(name) failed to register")
            #endif
        }
    }
}
```

Note the `#if canImport(UIKit)` gate (rather than `#if os(iOS)`) — `UIKit` is available on Mac Catalyst and iOS but not on AppKit-only macOS. This matches the style used inside `KeepurTheme.swift` itself.

- [ ] **Step 6.2:** Wire the test file into the `KeeperTests` target via the `xcodeproj` gem. Save as `/tmp/wire_test.rb`:

```ruby
#!/usr/bin/env ruby
require 'xcodeproj'

project = Xcodeproj::Project.open('Keepur.xcodeproj')

test_target = project.targets.find { |t| t.name == 'KeeperTests' }
raise "KeeperTests target not found" unless test_target

# Find or create the KeeperTests group
tests_group = project.main_group.find_subpath('KeeperTests', true)
tests_group.set_source_tree('<group>')
tests_group.set_path('KeeperTests')

unless tests_group.files.any? { |f| f.path == 'KeepurThemeFontsTests.swift' }
  ref = tests_group.new_reference('KeepurThemeFontsTests.swift')
  test_target.add_file_references([ref])
  puts "Added KeepurThemeFontsTests.swift to #{test_target.name}"
end

project.save
```

Run:
```bash
ruby /tmp/wire_test.rb
```

Expected: `Added KeepurThemeFontsTests.swift to KeeperTests`

- [ ] **Step 6.3:** Verify the file reference landed.

```bash
grep -c "KeepurThemeFontsTests.swift" Keepur.xcodeproj/project.pbxproj
```

Expected: `2` (one PBXFileReference + one PBXBuildFile in the test target's Sources phase).

- [ ] **Step 6.4:** Run the test on iOS.

```bash
xcodebuild test -project Keepur.xcodeproj -scheme Keepur \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing KeeperTests/KeepurThemeFontsTests/testJetBrainsMonoFontsRegister \
  2>&1 | tail -15
```

Expected: `** TEST SUCCEEDED **`. If a `Bundle.main.url(...)` assertion fails, the font is missing from Copy Bundle Resources for the main app target — re-check Task 5. If a `UIFont(name:size:)` assertion fails, the `UIAppFonts` plist entry is missing or the PostScript name in the binary doesn't match the constant — re-check Task 4 / step 3.2.

- [ ] **Step 6.5:** Run the test on macOS.

```bash
xcodebuild test -project Keepur.xcodeproj -scheme Keepur \
  -destination 'platform=macOS' \
  -only-testing KeeperTests/KeepurThemeFontsTests/testJetBrainsMonoFontsRegister \
  2>&1 | tail -15
```

Expected: `** TEST SUCCEEDED **`. If the `NSFont(name:size:)` assertion fails on macOS but iOS passed, the most likely cause is `ATSApplicationFontsPath` — try changing the value in `Info.plist` from `.` to `Fonts` and re-run. If still failing, fall back to runtime registration via `CTFontManagerRegisterFontsForURL` in `KeepurApp.init()` (see spec Risks for the rationale).

- [ ] **Step 6.6:** Commit.

```bash
git add KeeperTests/KeepurThemeFontsTests.swift Keepur.xcodeproj/project.pbxproj
git commit -m "$(cat <<'EOF'
test: smoke test for JetBrains Mono font registration (DOD-389)

Asserts both bundle presence (Bundle.main.url) and runtime
resolution (UIFont/NSFont) for each of the three weights named in
KeepurTheme.FontName. Runs on whichever platform the test scheme
exercises — KeeperTests is dual-targeted (iOS + macOS) per
SUPPORTED_PLATFORMS.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Full-suite regression sweep

Confirm nothing else broke. This task is verification only — no commit unless a regression surfaces.

**Files:** none

- [ ] **Step 7.1:** Run the full iOS test suite.

```bash
xcodebuild test -project Keepur.xcodeproj -scheme Keepur \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -quiet 2>&1 | tail -25
```

Expected: `** TEST SUCCEEDED **`, no test failures. If any unrelated test fails, halt and surface to the user — this plan has not touched any view or manager code, so a failure here points at infrastructure (e.g. simulator state, scheme corruption) rather than the design-system work.

- [ ] **Step 7.2:** Run the full macOS test suite.

```bash
xcodebuild test -project Keepur.xcodeproj -scheme Keepur \
  -destination 'platform=macOS' \
  -quiet 2>&1 | tail -25
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 7.3:** Confirm the working tree is clean.

```bash
git status --short
```

Expected: empty output (all changes committed across Tasks 2–6).

- [ ] **Step 7.4:** Print the commit log for this branch so the user can review the shape before the PR.

```bash
git log --oneline main..HEAD
```

Expected: 5 commits (Tasks 2, 3, 4, 5, 6) plus the spec commit already on the branch.

---

## Summary of commits this plan produces

1. `feat: add KeepurTheme token file (DOD-389)` — Task 2
2. `feat: bundle JetBrains Mono v2.304 fonts (DOD-389)` — Task 3
3. `feat: register JetBrains Mono in Info.plist for iOS+macOS (DOD-389)` — Task 4
4. `build: wire Theme + Fonts into Xcode project (DOD-389)` — Task 5
5. `test: smoke test for JetBrains Mono font registration (DOD-389)` — Task 6

Each commit is independently reviewable. Tasks 1 and 7 produce no commits.

## After the plan

1. `/quality-gate` — Swift compliance + test creation gate + full suite
2. `dodi-dev:review` — agent code review
3. `dodi-dev:submit` — PR + CI wait + merge (with the standard "stop at PR creation" gate per project memory)
4. After merge: file the per-screen migration epic (Pairing, Chat, MessageBubble, MessageInputBar, SessionList, Settings, Workspace picker, Tool approval, Hive views).
