# KPR-145 — Foundation Data Display (Implementation Plan)

**Date:** 2026-05-02
**Spec:** [docs/specs/2026-05-02-kpr-145-foundation-data-display.md](../specs/2026-05-02-kpr-145-foundation-data-display.md)
**Ticket:** [KPR-145](https://linear.app/keepur/issue/KPR-145)

## Strategy

Three new component files + one new test file + Xcode project wiring. Implementation order is bottom-up by complexity: `KeepurCard` first (trivial container), then `KeepurMetricGrid` (LazyVGrid wrap), then `KeepurChipCluster` (custom `Layout`-protocol implementation is the heaviest piece), then tests, then project wiring.

Per the spec, no existing files change. This is purely additive.

## Steps

### Step 1: Create `KeepurCard.swift`

**File:** `Theme/Components/KeepurCard.swift`

Implementation matches spec §"KeepurCard" verbatim. Key bits:

- Generic over `Content: View`.
- `init(bordered: Bool = false, @ViewBuilder content: () -> Content)` — `bordered` defaults to `false` so the simplest call site is `KeepurCard { ... }`.
- Body:
  ```swift
  content
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(KeepurTheme.Spacing.s4)
      .background(KeepurTheme.Color.bgSurfaceDynamic)
      .clipShape(RoundedRectangle(cornerRadius: KeepurTheme.Radius.sm))
      .modifier(OptionalBorder(visible: bordered))
  ```
- `OptionalBorder` is a private `ViewModifier` that calls `.keepurBorder(KeepurTheme.Color.borderDefaultDynamic, radius: KeepurTheme.Radius.sm, width: 1)` when visible, otherwise returns the view unchanged. (Avoids `Group { if ... }` so the resulting view tree stays flat.)

**Verification:** file compiles standalone (no ext deps beyond `KeepurTheme` and the existing `.keepurBorder` modifier).

### Step 2: Create `KeepurMetricGrid.swift`

**File:** `Theme/Components/KeepurMetricGrid.swift`

- Nested `Metric` struct conforming to `Identifiable` with `id = UUID()`, `label: String`, `value: String`. Public memberwise init.
- `init(_ metrics: [Metric])` — unlabeled array param for ergonomic call sites.
- Body:
  ```swift
  if metrics.isEmpty {
      EmptyView()
  } else {
      LazyVGrid(
          columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3),
          spacing: KeepurTheme.Spacing.s3
      ) {
          ForEach(metrics) { metric in
              VStack(alignment: .leading, spacing: KeepurTheme.Spacing.s1) {
                  Text(metric.label.uppercased())
                      .font(KeepurTheme.Font.eyebrow)
                      .tracking(KeepurTheme.Font.lsEyebrow)
                      .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                      .textCase(nil)
                  Text(metric.value)
                      .font(KeepurTheme.Font.bodySm)
                      .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
                      .lineLimit(1)
                      .truncationMode(.tail)
              }
              .accessibilityElement(children: .combine)
              .accessibilityLabel("\(metric.label): \(metric.value)")
          }
      }
  }
  ```

**Verification:** file compiles standalone.

### Step 3: Create `KeepurChipCluster.swift`

**File:** `Theme/Components/KeepurChipCluster.swift`

Two pieces in one file:

1. **`KeepurChipCluster` struct** — public component matching the spec API.
2. **`WrappingHStack` struct** — file-private (`fileprivate`) `Layout`-protocol implementation.

`WrappingHStack` (file-private):

```swift
fileprivate struct WrappingHStack: Layout {
    var hSpacing: CGFloat
    var vSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = computeRows(maxWidth: maxWidth, subviews: subviews)
        let totalHeight = rows.reduce(0) { $0 + $1.height } + CGFloat(max(0, rows.count - 1)) * vSpacing
        let usedWidth = rows.map { $0.width }.max() ?? 0
        return CGSize(width: min(usedWidth, maxWidth), height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(maxWidth: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + hSpacing
            }
            y += row.height + vSpacing
        }
    }

    private struct Row { var indices: [Int]; var width: CGFloat; var height: CGFloat }

    private func computeRows(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row(indices: [], width: 0, height: 0)
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let prospective = current.width + (current.indices.isEmpty ? 0 : hSpacing) + size.width
            if prospective > maxWidth, !current.indices.isEmpty {
                rows.append(current)
                current = Row(indices: [index], width: size.width, height: size.height)
            } else {
                if !current.indices.isEmpty { current.width += hSpacing }
                current.indices.append(index)
                current.width += size.width
                current.height = max(current.height, size.height)
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
```

`KeepurChipCluster`:

```swift
struct KeepurChipCluster: View {
    let labels: [String]
    let maxVisible: Int?

    init(_ labels: [String], maxVisible: Int? = nil) {
        self.labels = labels
        self.maxVisible = maxVisible
    }

    private var visibleLabels: [String] {
        guard let cap = maxVisible, cap < labels.count else { return labels }
        return Array(labels.prefix(cap))
    }

    private var overflowCount: Int {
        guard let cap = maxVisible, cap < labels.count else { return 0 }
        return labels.count - cap
    }

    private var combinedAccessibilityLabel: String {
        if overflowCount > 0 {
            return visibleLabels.joined(separator: ", ") + ", plus \(overflowCount) more"
        }
        return labels.joined(separator: ", ")
    }

    var body: some View {
        WrappingHStack(hSpacing: KeepurTheme.Spacing.s1, vSpacing: KeepurTheme.Spacing.s1) {
            ForEach(Array(visibleLabels.enumerated()), id: \.offset) { _, label in
                chipView(label: label)
            }
            if overflowCount > 0 {
                chipView(label: "+\(overflowCount)")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(combinedAccessibilityLabel)
    }

    private func chipView(label: String) -> some View {
        Text(label)
            .font(KeepurTheme.Font.caption)
            .foregroundStyle(KeepurTheme.Color.fgSecondary)
            .padding(.horizontal, KeepurTheme.Spacing.s2)
            .padding(.vertical, KeepurTheme.Spacing.s1)
            .background(KeepurTheme.Color.wax100)
            .clipShape(RoundedRectangle(cornerRadius: KeepurTheme.Radius.xs))
    }
}
```

**Verification:** file compiles standalone. `Layout` requires iOS 16+ / macOS 13+ — both targets (iOS 26.2+, macOS 15+) clear it easily.

### Step 4: Create `KeepurFoundationDataDisplayTests.swift`

**File:** `KeeperTests/KeepurFoundationDataDisplayTests.swift`

Three test methods, one per component. Each instantiates with the spec's parameter sweep and verifies `_ = view.body` doesn't crash.

```swift
import XCTest
import SwiftUI
@testable import Keepur

final class KeepurFoundationDataDisplayTests: XCTestCase {
    func testChipClusterAcrossOverflowModes() {
        let cases: [KeepurChipCluster] = [
            KeepurChipCluster([]),                                                  // empty
            KeepurChipCluster(["swift"]),                                           // single
            KeepurChipCluster(["swift", "ruby", "python", "go", "rust"]),           // many, no cap
            KeepurChipCluster(["swift", "ruby", "python", "go", "rust"], maxVisible: 3),  // cap engaged
            KeepurChipCluster(["swift", "ruby"], maxVisible: 5),                    // cap >= count → no overflow
            KeepurChipCluster(["swift", "ruby", "python"], maxVisible: 0),          // cap == 0 → only "+N"
        ]
        for cluster in cases { _ = cluster.body }
    }

    func testMetricGridAcrossSizes() {
        let one = KeepurMetricGrid([.init(label: "MODEL", value: "claude-sonnet-4")])
        let three = KeepurMetricGrid([
            .init(label: "MODEL",      value: "claude-sonnet-4"),
            .init(label: "MESSAGES",   value: "1,234"),
            .init(label: "LAST ACTIVE", value: "2m ago"),
        ])
        let four = KeepurMetricGrid([
            .init(label: "MODEL",      value: "claude-sonnet-4"),
            .init(label: "MESSAGES",   value: "1,234"),
            .init(label: "LAST ACTIVE", value: "2m ago"),
            .init(label: "OWNER",      value: "may"),
        ])
        let longValue = KeepurMetricGrid([
            .init(label: "MODEL", value: String(repeating: "claude-sonnet-4-very-long-id-", count: 5)),
        ])
        let empty = KeepurMetricGrid([])
        for grid in [one, three, four, longValue, empty] { _ = grid.body }
    }

    func testCardBorderedAndUnbordered() {
        _ = KeepurCard { Text("hello") }.body
        _ = KeepurCard(bordered: true) { Text("hello") }.body
        _ = KeepurCard { EmptyView() }.body
        _ = KeepurCard { KeepurCard { Text("nested") } }.body
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
['KeepurChipCluster.swift', 'KeepurMetricGrid.swift', 'KeepurCard.swift'].each do |name|
  ref = group_components.new_reference("Theme/Components/#{name}")
  project.targets.each do |t|
    next unless t.name == 'Keepur'
    t.source_build_phase.add_file_reference(ref)
  end
end

# Add test file to test targets only
ref = group_tests.new_reference("KeeperTests/KeepurFoundationDataDisplayTests.swift")
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
  -only-testing KeeperTests/KeepurFoundationDataDisplayTests \
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
feat: foundation data display — KeepurChipCluster + KeepurMetricGrid + KeepurCard (KPR-145)

Layer-1 design v2 components in Theme/Components/. Pure addition; no
view changes. KeepurChipCluster uses SwiftUI Layout protocol for native
flow-layout wrapping with optional "+N" overflow. Smoke tests verify
instantiation across parameter sweep (empty, single, many, cap engaged,
cap not engaged, cap zero) for each component.

Closes KPR-145
```

## Test Groups

| Group | Coverage | File |
|---|---|---|
| **Unit (smoke)** | Each component instantiates across the spec's parameter sweep; chip overflow logic exercised at boundaries (empty, cap=0, cap>=count) | `KeeperTests/KeepurFoundationDataDisplayTests.swift` |
| **Integration** | N/A — these are leaf components with no integration surface |  |
| **E2E** | N/A — no user-facing flow change |  |

## Risks / Mitigations

| Risk | Mitigation |
|---|---|
| Project file (`project.pbxproj`) corrupted by `xcodeproj` gem mid-edit | Run `git diff project.pbxproj` after script; revert and retry if anything looks off; gem is well-tested in this repo from theming epic |
| `Layout` protocol behavior differs subtly between iOS 16/17/18+ versions when measuring wrapped content | Both build targets are well above iOS 16 floor (iOS 26.2+, macOS 15+); unit-test instantiation catches construction crashes; visual regressions surface in layer-3 consumer tickets |
| `LazyVGrid` with `.flexible()` columns + 1-or-2 metrics looks visually unbalanced | Spec accepts trailing-empty behavior intentionally; consumers (KPR-151 Agent detail) always pass exactly 3 metrics in mockup |
| Test file accidentally compiled into main app target | Step 5 explicitly filters to `Tests`-named targets |
| Build cache stale-index warnings on SwiftPM dirs | Cosmetic; `xcodebuild` exit code is authoritative (per theming epic notes) |

## Dependencies Check

- **External (foundation tokens):** `KeepurTheme.Color.{wax100, fgSecondary, fgSecondaryDynamic, fgPrimaryDynamic, bgSurfaceDynamic, borderDefaultDynamic}`, `KeepurTheme.Spacing.{s1, s2, s3, s4}`, `KeepurTheme.Radius.{xs, sm}`, `KeepurTheme.Font.{caption, eyebrow, bodySm}`, `KeepurTheme.Font.lsEyebrow`, `View.keepurBorder(...)` — all confirmed present in `Theme/KeepurTheme.swift`
- **External (test target):** existing `KeeperTests/KeepurThemeFontsTests.swift` confirms `@testable import Keepur` pattern works
- **Platform floor:** `Layout` protocol requires iOS 16 / macOS 13 — both targets (iOS 26.2+, macOS 15+) clear it
- **No ticket dependencies** — KPR-145 is a leaf (head of dependency graph), parallelizable with KPR-144/146/147

## Human Signoff

Pre-approved per durable user delegation (KPR-142 design v2 epic). No human plan-review checkpoint required.
