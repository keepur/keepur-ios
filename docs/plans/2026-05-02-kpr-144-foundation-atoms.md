# KPR-144 — Foundation Atoms (Implementation Plan)

**Date:** 2026-05-02
**Spec:** [docs/specs/2026-05-02-kpr-144-foundation-atoms.md](../specs/2026-05-02-kpr-144-foundation-atoms.md)
**Ticket:** [KPR-144](https://linear.app/keepur/issue/KPR-144)

## Strategy

Three new component files + one new test file + Xcode project wiring. Implementation order is bottom-up (StatusPill first, since its `Tint` enum is referenced by Avatar's `statusOverlay` parameter), then Avatar, then UnreadBadge (independent), then tests, then project wiring.

Per the spec, no existing files change. This is purely additive.

## Steps

### Step 1: Create `KeepurStatusPill.swift`

**File:** `Theme/Components/KeepurStatusPill.swift`

Implementation matches spec §"KeepurStatusPill" verbatim. Key bits:

- `Tint` enum (5 cases: `.success`, `.warning`, `.danger`, `.honey`, `.muted`) with computed `var color: Color` mapping each case to its `KeepurTheme.Color.*` token.
- `init(_ text: String, tint: Tint)` — unlabeled text param for ergonomic `KeepurStatusPill("Active", tint: .success)`.
- Body: `Text(text).font(...).foregroundStyle(tint.color).padding(.horizontal, s2).padding(.vertical, s1).background(tint.color.opacity(0.15)).clipShape(Capsule())`.
- `accessibilityLabel(text)` + `accessibilityAddTraits(.isStaticText)`.

**Verification:** file compiles standalone (no ext deps beyond `KeepurTheme`).

### Step 2: Create `KeepurAvatar.swift`

**File:** `Theme/Components/KeepurAvatar.swift`

- Nested `Content` enum with `.letter(String)` + `.emoji(String)` cases.
- Init signature per spec.
- Body: `ZStack(alignment: .bottomTrailing)` with rounded rect background + content + optional overlay.
- Letter rendering: `Text(String(content.first?.uppercased() ?? "?"))` at `.system(size: size * 0.45, weight: .semibold)` with `fgPrimary`.
- Emoji rendering: `Text(content.first.map(String.init) ?? "")` at `.system(size: size * 0.6)` (no foreground tint).
- Status overlay: `Circle().fill(tint.color).frame(width: max(8, size * 0.16))` with `.overlay(Circle().stroke(.white, lineWidth: 1.5))` and `.padding(size * 0.05)`.
- `accessibilityLabel` extracted via switch on Content.

**Verification:** file compiles. Confirms Step 1's `Tint` enum is accessible.

### Step 3: Create `KeepurUnreadBadge.swift`

**File:** `Theme/Components/KeepurUnreadBadge.swift`

- `init(count: Int)`.
- `body: some View`: `Group { if count <= 0 { EmptyView() } else { Text(displayText).font(.caption).fontWeight(.semibold).foregroundStyle(.white).padding(.horizontal, s1).padding(.vertical, 1).frame(minWidth: 18).background(KeepurTheme.Color.honey500).clipShape(Capsule()).accessibilityLabel("\(count) unread") } }`.
- `displayText`: computed property `count > 9 ? "9+" : "\(count)"`.

**Verification:** file compiles.

### Step 4: Create `KeepurFoundationAtomsTests.swift`

**File:** `KeeperTests/KeepurFoundationAtomsTests.swift`

Three test methods, one per component. Each instantiates the component with a representative parameter sweep and verifies `_ = view.body` doesn't crash (SwiftUI views are values, so this is a sanity check on the view tree construction — not a render assertion).

Per the spec's test scope table:

```swift
import XCTest
import SwiftUI
@testable import Keepur

final class KeepurFoundationAtomsTests: XCTestCase {
    func testAvatarInstantiates() {
        let cases: [KeepurAvatar] = [
            KeepurAvatar(content: .letter("M")),
            KeepurAvatar(size: 24, content: .letter("Bob"), statusOverlay: .success),
            KeepurAvatar(size: 60, content: .emoji("🤖"), statusOverlay: .warning),
            KeepurAvatar(content: .letter("")),  // empty letter → "?"
        ]
        for avatar in cases { _ = avatar.body }
    }

    func testStatusPillRendersAllTints() {
        for tint in [KeepurStatusPill.Tint.success, .warning, .danger, .honey, .muted] {
            _ = KeepurStatusPill("Active", tint: tint).body
        }
    }

    func testUnreadBadgeOverflowAndNullState() {
        for count in [-1, 0, 1, 9, 10, 100] {
            _ = KeepurUnreadBadge(count: count).body
        }
    }
}
```

**Verification:** file compiles inside test target.

### Step 5: Wire all 4 files into Xcode project

Use `xcodeproj` Ruby gem (per project convention from theming epic). Script template:

```ruby
require 'xcodeproj'
project = Xcodeproj::Project.open('Keepur.xcodeproj')
group_components = project.main_group['Theme']['Components']
group_tests = project.main_group['KeeperTests']

# Add component files to both iOS + macOS targets
['KeepurAvatar.swift', 'KeepurStatusPill.swift', 'KeepurUnreadBadge.swift'].each do |name|
  ref = group_components.new_reference("Theme/Components/#{name}")
  project.targets.each do |t|
    next unless t.name == 'Keepur'
    t.source_build_phase.add_file_reference(ref)
  end
end

# Add test file to test targets only
ref = group_tests.new_reference("KeeperTests/KeepurFoundationAtomsTests.swift")
project.targets.each do |t|
  next unless t.name.include?('Tests')
  t.source_build_phase.add_file_reference(ref)
end

project.save
```

**Verification:** `git diff Keepur.xcodeproj/project.pbxproj` shows file refs added to both source build phases (iOS + macOS) for components and to test build phase for tests.

### Step 6: Build verification

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

**Verification:** both exit 0.

### Step 7: Run test suite

```bash
xcodebuild test -project Keepur.xcodeproj -scheme Keepur \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing KeeperTests/KeepurFoundationAtomsTests \
  -quiet
```

Then full suite to confirm no regression:

```bash
xcodebuild test -project Keepur.xcodeproj -scheme Keepur \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -quiet
```

**Verification:** both exit 0; new test class shows 3 passes; total test count = previous + 3.

### Step 8: Commit

```
feat: foundation atoms — KeepurAvatar + KeepurStatusPill + KeepurUnreadBadge (KPR-144)

Layer-1 design v2 components in Theme/Components/. Pure addition; no
view changes. Smoke tests verify instantiation across parameter sweep.

Closes KPR-144
```

## Test Groups

| Group | Coverage | File |
|---|---|---|
| **Unit (smoke)** | Each component instantiates across the spec's parameter sweep | `KeeperTests/KeepurFoundationAtomsTests.swift` |
| **Integration** | N/A — these are leaf components with no integration surface |  |
| **E2E** | N/A — no user-facing flow change |  |

## Risks / Mitigations

| Risk | Mitigation |
|---|---|
| Project file (`project.pbxproj`) corrupted by `xcodeproj` gem mid-edit | Run `git diff project.pbxproj` after script; revert and retry if anything looks off; gem is well-tested in this repo from theming epic |
| Test file accidentally compiled into main app target | Step 5 explicitly filters to `Tests`-named targets |
| Build cache stale-index warnings on SwiftPM dirs | Cosmetic; `xcodebuild` exit code is authoritative (per theming epic notes) |

## Dependencies Check

- **External (foundation tokens):** `KeepurTheme.Color.{honey500, wax100, success, warning, danger, fgMuted, fgPrimary}`, `KeepurTheme.Spacing.{s1, s2}`, `KeepurTheme.Radius.sm`, `KeepurTheme.Font.caption` — all confirmed present in `Theme/KeepurTheme.swift`
- **External (test target):** existing `KeeperTests/KeepurThemeFontsTests.swift` confirms `@testable import Keepur` pattern works
- **No ticket dependencies** — KPR-144 is a leaf (head of dependency graph)

## Human Signoff

Pre-approved per durable user delegation (KPR-142 design v2 epic). No human plan-review checkpoint required.
