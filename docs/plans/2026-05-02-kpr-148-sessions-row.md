# KPR-148 — Sessions row + list redesign (Implementation Plan)

**Date:** 2026-05-02
**Spec:** [docs/specs/2026-05-02-kpr-148-sessions-row.md](../specs/2026-05-02-kpr-148-sessions-row.md)
**Ticket:** [KPR-148](https://linear.app/keepur/issue/KPR-148)

## Strategy

Three-touch surgical edit:

1. Modify `SessionRow` body in `Views/SessionListView.swift` — remove leading icon, swap badge helper for `KeepurStatusPill`, add divider, then delete the obsolete `semanticBadge` helper.
2. Suppress the system list separator at the `ForEach` call site so the new explicit `Divider` is the only line.
3. Add a smoke-test file to `KeeperTests/` and wire it into the project via `xcodeproj` Ruby gem.

`Views/` is a synchronized folder group (per epic constraints) — modifying `SessionListView.swift` needs no project wiring. Only the new test file does.

## Steps

### Step 1: Modify `SessionRow.body` in `Views/SessionListView.swift`

**File:** `Views/SessionListView.swift`

Edit the `body` of `struct SessionRow` (currently lines 261-305) to:

1. Remove the leading `Circle()` block entirely (lines 263-269).
2. Wrap the remaining `HStack` in a `VStack(alignment: .leading, spacing: 0)` so we can append a `Divider` below it.
3. Inside the title row HStack, replace both `semanticBadge(...)` calls with `KeepurStatusPill(_:tint:)`.
4. Change outer HStack `alignment` to `.top` so the timestamp aligns with the first line of text rather than vertically centering on a 2- or 3-line row.
5. Append `Divider().background(KeepurTheme.Color.borderSubtle)` after the HStack but inside the new VStack wrapper.

Resulting `body`:

```swift
var body: some View {
    VStack(alignment: .leading, spacing: 0) {
        HStack(alignment: .top, spacing: KeepurTheme.Spacing.s3) {
            VStack(alignment: .leading, spacing: KeepurTheme.Spacing.s1) {
                HStack(spacing: KeepurTheme.Spacing.s2) {
                    Text(session.displayName)
                        .font(KeepurTheme.Font.body)
                        .fontWeight(.medium)
                        .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
                    if isActive {
                        KeepurStatusPill("Active", tint: .success)
                    }
                    if session.isStale {
                        KeepurStatusPill("Stale", tint: .warning)
                    }
                }

                Text(session.path)
                    .font(.custom(KeepurTheme.FontName.mono, size: 12))
                    .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                    .lineLimit(1)

                if let preview = lastMessagePreview {
                    Text(preview)
                        .font(KeepurTheme.Font.bodySm)
                        .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                        .lineLimit(1)
                }
            }

            Spacer()

            Text(session.createdAt, style: .relative)
                .font(KeepurTheme.Font.caption)
                .foregroundStyle(KeepurTheme.Color.fgTertiary)
        }
        .padding(.vertical, KeepurTheme.Spacing.s1)

        Divider()
            .background(KeepurTheme.Color.borderSubtle)
    }
}
```

### Step 2: Delete the `semanticBadge` helper

In the same file, delete the now-unused private helper (lines 307-315):

```swift
private func semanticBadge(_ text: String, tint: Color) -> some View {
    Text(text)
        ...
}
```

The `lastMessagePreview` computed property (lines 317-326) stays.

**Verification:** `grep -n 'semanticBadge' Views/SessionListView.swift` returns nothing.

### Step 3: Hide system list separator at the call site

In `SessionListView.sessionList` (around line 44 in the `ForEach`), append `.listRowSeparator(.hidden)` to the `SessionRow(...)` modifier chain. Other modifiers (`.opacity`, `.tag`, `.contentShape`, `.onTapGesture`, `.swipeActions`, `.contextMenu`) stay. Order: place `.listRowSeparator(.hidden)` right after `.tag(session.id)` to keep semantic modifiers grouped at the top.

**Verification:** Visual — system separator gone, custom Divider line present below each row.

### Step 4: Create `KeeperTests/SessionRowTests.swift`

**File:** `KeeperTests/SessionRowTests.swift`

```swift
import XCTest
import SwiftUI
import SwiftData
@testable import Keepur

final class SessionRowTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(
            for: Session.self, Message.self,
            configurations: config
        )
        context = ModelContext(container)
    }

    override func tearDown() async throws {
        container = nil
        context = nil
    }

    private func makeSession(
        id: String = "s1",
        path: String = "/Users/dev/project",
        name: String? = nil,
        isStale: Bool = false
    ) -> Session {
        let s = Session(id: id, path: path, name: name, isStale: isStale)
        context.insert(s)
        return s
    }

    func testRowActiveNotStale() {
        let s = makeSession()
        let row = SessionRow(session: s, isActive: true, modelContext: context)
        _ = row.body
    }

    func testRowStaleNotActive() {
        let s = makeSession(isStale: true)
        let row = SessionRow(session: s, isActive: false, modelContext: context)
        _ = row.body
    }

    func testRowActiveAndStale() {
        let s = makeSession(isStale: true)
        let row = SessionRow(session: s, isActive: true, modelContext: context)
        _ = row.body
    }

    func testRowNeitherActiveNorStale() {
        let s = makeSession()
        let row = SessionRow(session: s, isActive: false, modelContext: context)
        _ = row.body
    }

    func testRowLongPath() {
        let s = makeSession(path: "/very/long/path/that/should/truncate/in/the/ui/projectname")
        let row = SessionRow(session: s, isActive: false, modelContext: context)
        _ = row.body
    }

    func testRowNoPreviewMessage() {
        // No Message inserted → lastMessagePreview returns nil
        let s = makeSession()
        let row = SessionRow(session: s, isActive: false, modelContext: context)
        _ = row.body
    }
}
```

**Notes:**
- Tests do not instantiate `SessionListView` (depends on `ChatViewModel` → Keychain → crashes in test env per epic constraints).
- We construct an in-memory `ModelContainer` so the `lastMessagePreview` fetch on `modelContext` succeeds (returning `nil` for the no-message cases, which is fine).
- We do not assert visual output (no snapshot library in repo); construction-without-crash is the contract for this layer of test, matching the foundation-atoms pattern from KPR-144.

**Verification:** file compiles inside test target.

### Step 5: Wire `SessionRowTests.swift` into Xcode project

`Theme/Components/` files were wired by KPR-144; only the new test file needs explicit wiring. `Views/SessionListView.swift` is in a synchronized folder group — its edits don't touch `project.pbxproj`.

```ruby
require 'xcodeproj'
project = Xcodeproj::Project.open('Keepur.xcodeproj')
group_tests = project.main_group['KeeperTests']

ref = group_tests.new_reference('SessionRowTests.swift')   # bare filename per epic constraint
project.targets.each do |t|
  next unless t.name.include?('Tests')
  t.source_build_phase.add_file_reference(ref)
end

project.save
```

**Verification:** `git diff Keepur.xcodeproj/project.pbxproj` shows the new file ref added to the test target's source build phase. No changes to main app target build phases.

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

### Step 7: Run targeted + full test suite

```bash
xcodebuild test -project Keepur.xcodeproj -scheme Keepur \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing KeeperTests/SessionRowTests \
  -quiet
```

Then full suite to confirm no regression:

```bash
xcodebuild test -project Keepur.xcodeproj -scheme Keepur \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -quiet
```

**Verification:** both exit 0; new test class shows 6 passes; total test count = previous + 6.

### Step 8: Commit

```
feat: redesign Sessions row — drop avatar, KeepurStatusPill, cleaner divider (KPR-148)

Sessions row no longer has a leading icon — it is now a text-forward
record of name + path + preview + relative time. Active/Stale tags use
KeepurStatusPill instead of the obsolete inline semanticBadge helper,
and the system list separator is replaced with an explicit borderSubtle
divider.

No model or view-model changes. Smoke tests cover row construction
across active/stale/preview permutations.

Closes KPR-148
```

## Test Groups

| Group | Coverage | File |
|---|---|---|
| **Unit (smoke)** | `SessionRow` constructs across active/stale/preview permutations | `KeeperTests/SessionRowTests.swift` |
| **Integration** | N/A — `SessionListView` depends on `ChatViewModel`/Keychain and is not test-instantiable per epic constraints |  |
| **E2E** | N/A — purely visual layer reshuffle |  |

## Risks / Mitigations

| Risk | Mitigation |
|---|---|
| `Divider().background(...)` doesn't tint on iOS 26 (Divider's color API is finicky) | If `.background(...)` fails to color the line, fall back to `Rectangle().fill(KeepurTheme.Color.borderSubtle).frame(height: 0.5)` — same visual result, more predictable. Decide during implementation based on visual check. |
| `.listRowSeparator(.hidden)` interaction with `List(selection:)` on macOS sidebar | macOS NavigationSplitView sidebar may render selection background that visually competes with our Divider. Acceptable — selection background is the system-blessed active-row affordance and the Divider sits below it; they don't overlap. |
| Removing the leading icon shifts the visual baseline; users may briefly miss the "active" cue | The "Active" `KeepurStatusPill` (success-tinted) is the explicit active affordance. This is the mockup-blessed pattern. |
| `KeepurStatusPill` package privacy — `internal` struct must be visible to `SessionListView` in same module | Both live in the `Keepur` target (default `internal` access) — confirmed by direct file read. No access-modifier change needed. |
| Tests crash from SwiftData container setup if model schema mismatches | Use `ModelConfiguration(isStoredInMemoryOnly: true)` and only register `Session` + `Message` — both already exist. Mirrors the standard test pattern in the repo. |
| `xcodeproj` Ruby gem corrupts `project.pbxproj` mid-edit | `git diff Keepur.xcodeproj/project.pbxproj` after the script; revert and retry if anything looks off. Gem is well-tested in this repo from the theming epic. |

## Dependencies Check

- **External (foundation):** `KeepurStatusPill` (Tints `.success`, `.warning`) — confirmed present at `Theme/Components/KeepurStatusPill.swift`
- **External (tokens):** `KeepurTheme.Color.{fgPrimaryDynamic, fgSecondaryDynamic, fgTertiary, borderSubtle}`, `KeepurTheme.Spacing.{s1, s2, s3}`, `KeepurTheme.Font.{body, bodySm, caption}`, `KeepurTheme.FontName.mono` — all confirmed present in `Theme/KeepurTheme.swift`
- **External (model):** `Session.{id, path, displayName, isStale, createdAt}`, `Message.{sessionId, timestamp, role, text}` — confirmed in `Models/Session.swift` and `Models/Message.swift` (Message access verified through existing `lastMessagePreview` query in the file we're editing)
- **Test target wiring:** mirrors KPR-144 Step 5 — bare filename ref into `KeeperTests` group, added only to `*Tests` targets

## Human Signoff

Pre-approved per durable user delegation (KPR-142 design v2 epic). No human plan-review checkpoint required.
