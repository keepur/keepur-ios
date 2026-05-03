# KPR-146 — Foundation Composites (Implementation Plan)

**Date:** 2026-05-02
**Spec:** [docs/specs/2026-05-02-kpr-146-foundation-composites.md](../specs/2026-05-02-kpr-146-foundation-composites.md)
**Ticket:** [KPR-146](https://linear.app/keepur/issue/KPR-146)

## Strategy

Two new component files + one new test file + Xcode project wiring. Implementation order is independent-first (`KeepurActionSheet` has no internal dependencies, `KeepurChatHeader` has no internal dependencies), so order is `KeepurActionSheet` → `KeepurChatHeader` → tests → project wiring purely by complexity (action sheet is structurally simpler).

Per the spec, no existing files change. This is purely additive.

## Steps

### Step 1: Create `KeepurActionSheet.swift`

**File:** `Theme/Components/KeepurActionSheet.swift`

Implementation matches spec §"KeepurActionSheet" verbatim. Key bits:

- Top of file: `///` doc comment showing the integration pattern (`.sheet { KeepurActionSheet(...).presentationDetents([.medium]) }`).
- Nested `Action` struct: `id: UUID` (auto-generated), `symbol`, `title`, `subtitle: String?`, `action: () -> Void`. Custom `init` so `subtitle` defaults to `nil`.
- `init(title: String, subtitle: String? = nil, actions: [Action])`.
- Body:
  - Outer `ScrollView` containing `VStack(alignment: .leading, spacing: KeepurTheme.Spacing.s4)`.
  - Header `VStack(alignment: .leading, spacing: KeepurTheme.Spacing.s1)` with title (`Font.h3` + `tracking(lsH3)` + `fgPrimaryDynamic`) and optional subtitle (`Font.bodySm` + `fgSecondaryDynamic`).
  - Action rows `VStack(spacing: KeepurTheme.Spacing.s2)`, `ForEach(actions) { action in actionRow(action) }`.
- Private `actionRow(_ action: Action)` helper:
  - `Button { action.action() } label: { HStack(spacing: KeepurTheme.Spacing.s3) { iconContainer; textBlock; Spacer(); chevron } }`.
  - Icon container: `RoundedRectangle(cornerRadius: KeepurTheme.Radius.sm).fill(KeepurTheme.Color.accentTint).frame(width: 40, height: 40).overlay(Image(systemName: action.symbol).foregroundStyle(KeepurTheme.Color.honey700).font(.system(size: 18, weight: .medium)))`.
  - Text block: `VStack(alignment: .leading, spacing: 2) { title with .lineLimit(2) .truncationMode(.tail); if let sub = action.subtitle { subtitle text } }`.
  - Chevron: `Image(systemName: "chevron.right").font(KeepurTheme.Font.bodySm).foregroundStyle(KeepurTheme.Color.fgTertiary)`.
  - Row padding: `.padding(.horizontal, KeepurTheme.Spacing.s3).padding(.vertical, KeepurTheme.Spacing.s2)`.
  - Row background: `.background(KeepurTheme.Color.bgSurfaceDynamic).clipShape(RoundedRectangle(cornerRadius: KeepurTheme.Radius.sm))`.
  - Accessibility: `.accessibilityLabel("\(action.title), \(action.subtitle ?? "")")` and `.accessibilityHint("Double tap to select")`.
  - `.buttonStyle(.plain)` on the button.
- Outer padding: `.padding(.horizontal, KeepurTheme.Spacing.s4).padding(.top, KeepurTheme.Spacing.s5).padding(.bottom, KeepurTheme.Spacing.s4)`.
- Outer background: `.background(KeepurTheme.Color.bgPageDynamic)`.
- Title carries `.accessibilityAddTraits(.isHeader)`.

**Verification:** file compiles standalone (no ext deps beyond `KeepurTheme`).

### Step 2: Create `KeepurChatHeader.swift`

**File:** `Theme/Components/KeepurChatHeader.swift`

- Top of file: `///` doc comment showing the integration pattern (toolbar item + `navigationBarBackButtonHidden(true)` for iOS).
- Nested `Action` struct: `id: UUID` (auto-generated), `symbol: String`, `action: () -> Void`. `Identifiable` for `ForEach`.
- `init(title:statusText:statusDate:isStatusActive:onBack:trailingActions:)` per spec.
- `@State private var pulse = false` for the dot animation.
- Body: `HStack(spacing: KeepurTheme.Spacing.s3) { backButton; titleBlock; trailingStack }`.
- Private subviews:
  - `backButton`: `if let onBack { Button { onBack() } label: { circleButton(symbol: KeepurTheme.Symbol.chevronBack) }.buttonStyle(.plain).accessibilityLabel("Back") }`.
  - `titleBlock`: `VStack(spacing: 2) { Text(title).font(.h4).foregroundStyle(.fgPrimaryDynamic).lineLimit(1).truncationMode(.tail).accessibilityAddTraits(.isHeader); if statusText != nil || statusDate != nil { statusLine } }.frame(maxWidth: .infinity)`.
  - `statusLine`: `HStack(spacing: KeepurTheme.Spacing.s1) { pulseDot; if let s = statusText { Text(s).font(.caption).foregroundStyle(.fgSecondaryDynamic) }; if statusText != nil && statusDate != nil { Text("·").font(.caption).foregroundStyle(.fgMuted) }; if let d = statusDate { Text(d, style: .relative).font(.caption).foregroundStyle(.fgSecondaryDynamic) } }`.
  - `pulseDot`: `Circle().fill(isStatusActive ? KeepurTheme.Color.honey500 : KeepurTheme.Color.fgMuted).frame(width: 6, height: 6).scaleEffect(isStatusActive && pulse ? 1.4 : 1.0).opacity(isStatusActive && pulse ? 0.6 : 1.0)`.
  - `trailingStack`: `HStack(spacing: KeepurTheme.Spacing.s2) { ForEach(trailingActions) { action in Button { action.action() } label: { circleButton(symbol: action.symbol) }.buttonStyle(.plain) } }`.
  - `circleButton(symbol:)` helper: `Image(systemName: symbol).font(.system(size: 15, weight: .medium)).foregroundStyle(KeepurTheme.Color.fgPrimary).frame(width: 36, height: 36).background(Circle().fill(KeepurTheme.Color.wax100))`.
- `.onAppear { if isStatusActive { withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { pulse = true } } }`.

**Verification:** file compiles standalone. Cross-platform sanity: no `UIKit` imports needed; `Image(systemName:)` and `Circle().fill(...)` work on both iOS and macOS.

### Step 3: Create `KeepurFoundationCompositesTests.swift`

**File:** `KeeperTests/KeepurFoundationCompositesTests.swift`

Two test methods, one per component. Each instantiates the component with a representative parameter sweep and verifies `_ = view.body` doesn't crash (SwiftUI views are values, so this is a sanity check on the view tree construction).

```swift
import XCTest
import SwiftUI
@testable import Keepur

final class KeepurFoundationCompositesTests: XCTestCase {
    func testChatHeaderInstantiates() {
        let cases: [KeepurChatHeader] = [
            KeepurChatHeader(title: "Chat"),
            KeepurChatHeader(title: "hive-dodi", onBack: {}),
            KeepurChatHeader(title: "T", statusText: "working", isStatusActive: true),
            KeepurChatHeader(title: "T", statusDate: .now),
            KeepurChatHeader(
                title: "Long title that should truncate cleanly at the tail end",
                statusText: "working",
                statusDate: .now,
                isStatusActive: true,
                onBack: {},
                trailingActions: [
                    .init(symbol: "speaker.wave.2", action: {}),
                    .init(symbol: "info.circle",    action: {}),
                    .init(symbol: "ellipsis",       action: {}),
                ]
            ),
        ]
        for header in cases { _ = header.body }
    }

    func testActionSheetInstantiates() {
        let cases: [KeepurActionSheet] = [
            KeepurActionSheet(title: "Empty", actions: []),
            KeepurActionSheet(
                title: "One",
                actions: [.init(symbol: "doc", title: "Choose file", action: {})]
            ),
            KeepurActionSheet(
                title: "Attach",
                subtitle: "Add a file or photo to the message.",
                actions: [
                    .init(symbol: "doc",    title: "Choose file",   subtitle: "Browse documents on this device", action: {}),
                    .init(symbol: "photo",  title: "Photo library", subtitle: "Pick from your photos",          action: {}),
                    .init(symbol: "camera", title: "Take photo",    subtitle: "Use the camera now",              action: {}),
                ]
            ),
            KeepurActionSheet(
                title: String(repeating: "Long title ", count: 8),
                subtitle: String(repeating: "Long subtitle ", count: 6),
                actions: [.init(symbol: "doc", title: "Pick", subtitle: "x", action: {})]
            ),
        ]
        for sheet in cases { _ = sheet.body }
    }
}
```

**Verification:** file compiles inside test target.

### Step 4: Wire all 3 files into Xcode project

Use `xcodeproj` Ruby gem (per project convention from theming epic). Script template:

```ruby
require 'xcodeproj'
project = Xcodeproj::Project.open('Keepur.xcodeproj')
group_components = project.main_group['Theme']['Components']
group_tests = project.main_group['KeeperTests']

# Add component files to both iOS + macOS targets
['KeepurActionSheet.swift', 'KeepurChatHeader.swift'].each do |name|
  ref = group_components.new_reference("Theme/Components/#{name}")
  project.targets.each do |t|
    next unless t.name == 'Keepur'
    t.source_build_phase.add_file_reference(ref)
  end
end

# Add test file to test targets only
ref = group_tests.new_reference("KeeperTests/KeepurFoundationCompositesTests.swift")
project.targets.each do |t|
  next unless t.name.include?('Tests')
  t.source_build_phase.add_file_reference(ref)
end

project.save
```

**Verification:** `git diff Keepur.xcodeproj/project.pbxproj` shows file refs added to both source build phases (iOS + macOS) for components and to the test build phase for tests.

### Step 5: Build verification

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

### Step 6: Run test suite

```bash
xcodebuild test -project Keepur.xcodeproj -scheme Keepur \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing KeeperTests/KeepurFoundationCompositesTests \
  -quiet
```

Then full suite to confirm no regression:

```bash
xcodebuild test -project Keepur.xcodeproj -scheme Keepur \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -quiet
```

**Verification:** both exit 0; new test class shows 2 passes; total test count = previous + 2.

### Step 7: Commit

```
feat: foundation composites — KeepurActionSheet + KeepurChatHeader (KPR-146)

Layer-1 design v2 components in Theme/Components/. Pure addition; no
view changes. KeepurActionSheet is a sheet body (caller owns
presentation + detents); KeepurChatHeader is a View embedded inside
ToolbarItem(placement: .principal). Smoke tests verify instantiation
across parameter sweep.

Closes KPR-146
```

## Test Groups

| Group | Coverage | File |
|---|---|---|
| **Unit (smoke)** | Each component instantiates across the spec's parameter sweep | `KeeperTests/KeepurFoundationCompositesTests.swift` |
| **Integration** | N/A — these are leaf chrome components with no integration surface until KPR-152/KPR-154 consume them |  |
| **E2E** | N/A — no user-facing flow change |  |

## Risks / Mitigations

| Risk | Mitigation |
|---|---|
| Pulse animation leaks beyond view lifecycle | `withAnimation` is gated by `if isStatusActive` inside `.onAppear`; SwiftUI tears down the `@State pulse` when the view leaves the hierarchy. No `Task` or `Timer` to clean up. |
| `Text(date, style: .relative)` formatting differs across platforms / locales | Already used in 4 other call sites in this repo (AgentRow, AgentDetailSheet, WorkspacePickerView, SessionListView) — consistent behavior. |
| Project file (`project.pbxproj`) corrupted by `xcodeproj` gem mid-edit | Run `git diff project.pbxproj` after script; revert and retry if anything looks off; gem is well-tested in this repo from theming epic. |
| Test file accidentally compiled into main app target | Step 4 explicitly filters to `Tests`-named targets. |
| `ToolbarItem(placement: .principal)` on macOS is silently ignored | macOS toolbar item placement is more permissive than iOS; `.automatic` is the safe macOS default. KPR-152 will use `#if os(iOS)` to pick `.principal` and `.automatic` for macOS. KPR-146 itself doesn't touch any toolbars; this is a downstream concern. |
| Status line accessibility label phrasing (`RelativeDateTimeFormatter.shared.localizedString(...)`) requires constructing a static formatter helper | Inline the formatter as a `private static let` on `KeepurChatHeader` to avoid per-render allocation. Trivial. |
| Build cache stale-index warnings on SwiftPM dirs | Cosmetic; `xcodebuild` exit code is authoritative (per theming epic notes). |

## Dependencies Check

- **External (foundation tokens):** `KeepurTheme.Color.{honey500, honey700, accentTint, wax100, fgPrimary, fgPrimaryDynamic, fgSecondaryDynamic, fgTertiary, fgMuted, bgPageDynamic, bgSurfaceDynamic}`, `KeepurTheme.Spacing.{s1, s2, s3, s4, s5}`, `KeepurTheme.Radius.sm`, `KeepurTheme.Font.{h3, h4, body, bodySm, caption, lsH3}`, `KeepurTheme.Symbol.chevronBack` — all confirmed present in `Theme/KeepurTheme.swift`
- **External (test target):** existing `KeeperTests/KeepurThemeFontsTests.swift` confirms `@testable import Keepur` pattern works
- **External (animation):** `withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true))` — same tempo as existing `StatusIndicator` thinking dots in `Views/ChatView.swift` line 238
- **External (relative time):** `Text(date, style: .relative)` — existing convention across 4 call sites
- **No ticket dependencies** — KPR-146 is a leaf (head of dependency graph)

## Human Signoff

Pre-approved per durable user delegation (KPR-142 design v2 epic). No human plan-review checkpoint required.
