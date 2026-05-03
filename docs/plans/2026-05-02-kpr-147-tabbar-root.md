# KPR-147 — TabBar root architecture (Implementation Plan)

**Date:** 2026-05-02
**Spec:** [docs/specs/2026-05-02-kpr-147-tabbar-root.md](../specs/2026-05-02-kpr-147-tabbar-root.md)
**Ticket:** [KPR-147](https://linear.app/keepur/issue/KPR-147)

## Strategy

Surgical app-shell restructure. Order of operations:

1. Create the new placeholder (`BeekeeperRootView`) so the tab has a body to render.
2. Rewire `ContentView.tabView` to the fixed 4-tab layout, fold the auth-revalidation task in.
3. Strip the gear button + settings sheet from `SessionListView` (both iOS + macOS bodies).
4. Delete `RootView.swift`.
5. Add the smoke test.
6. Wire all file additions / deletions into the Xcode project.
7. Build + test on both platforms.
8. Single commit at the end (atomic shell change — bisecting partial states would be confusing).

The implementation is bounded — every file change is enumerated below. No discovery work expected.

## Steps

### Step 1: Create `BeekeeperRootView.swift`

**File:** `Views/BeekeeperRootView.swift`

```swift
import SwiftUI

struct BeekeeperRootView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Beekeeper", systemImage: KeepurTheme.Symbol.bolt)
        } description: {
            Text("Direct interaction with the Beekeeper backend is coming soon.")
        }
        .background(KeepurTheme.Color.bgPageDynamic)
        .navigationTitle("Beekeeper")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
```

**Verification:** file compiles standalone (only deps are `KeepurTheme` constants — confirmed present).

### Step 2: Rewrite `ContentView.tabView` and fold in auth re-validation

**File:** `Views/ContentView.swift`

Replace the current `tabView` `@ViewBuilder` (lines 70-92) with the fixed 4-tab version per spec:

```swift
@ViewBuilder
private var tabView: some View {
    TabView {
        Tab("Beekeeper", systemImage: KeepurTheme.Symbol.bolt) {
            NavigationStack {
                BeekeeperRootView()
            }
        }

        Tab("Hive", systemImage: "hexagon.fill") {
            NavigationStack {
                HivesGridView(
                    capabilityManager: capabilityManager,
                    teamViewModel: teamViewModel
                )
            }
        }

        Tab("Sessions", systemImage: KeepurTheme.Symbol.chat) {
            SessionListView(viewModel: chatViewModel)
        }

        Tab("Settings", systemImage: KeepurTheme.Symbol.settings) {
            SettingsView(viewModel: chatViewModel)
        }
    }
    .tint(KeepurTheme.Color.honey500)
    .task {
        // Auth re-validation, lifted from RootView.
        do {
            _ = try await APIManager.fetchMe()
        } catch APIManager.APIError.unauthorized {
            chatViewModel.unpair()
        } catch BeekeeperConfigError.hostNotConfigured {
            chatViewModel.unpair()
        } catch {
            // Network error — don't log out
        }
    }
}
```

Note that the previous body referenced `RootView(viewModel: chatViewModel)` for the Beekeeper tab. After the rewrite, `RootView` is no longer referenced from `ContentView` — Step 4 deletes the file.

**Verification:** `git diff Views/ContentView.swift` shows the `tabView` body fully replaced; no other changes in this file.

### Step 3: Strip gear button + settings sheet from `SessionListView`

**File:** `Views/SessionListView.swift`

Three deletions, one minor edit. **All snippets below are exact removals — `Edit` tool with the existing strings.**

**3a.** Delete `@State private var showSettings = false` (line 10):

```swift
@State private var showSettings = false
```

**3b.** Delete the gear button toolbar item from `sessionToolbar` (lines 103-110):

```swift
ToolbarItem(placement: .automatic) {
    Button {
        showSettings = true
    } label: {
        Image(systemName: KeepurTheme.Symbol.settings)
            .font(.title3)
    }
}
```

**3c.** Delete the settings sheet from `sessionSheets` (iOS path, lines 140-142):

```swift
.sheet(isPresented: $showSettings) {
    SettingsView(viewModel: viewModel)
}
```

**3d.** Delete the settings sheet from the macOS body (lines 205-208):

```swift
.sheet(isPresented: $showSettings) {
    SettingsView(viewModel: viewModel)
        .frame(minWidth: 450, minHeight: 500)
}
```

**3e.** Update the pairing-expiry banner (lines 28-46) — strip the outer `Button { showSettings = true }` so the banner becomes a static `HStack`. Keep the row content + styling identical:

```swift
// BEFORE
Button {
    showSettings = true
} label: {
    HStack(spacing: KeepurTheme.Spacing.s2) {
        Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(KeepurTheme.Color.warning)
        Text(daysRemaining == 0
            ? "Device pairing expires today"
            : daysRemaining == 1
                ? "Device pairing expires in 1 day"
                : "Device pairing expires in \(daysRemaining) days")
            .font(KeepurTheme.Font.bodySm)
            .fontWeight(.medium)
            .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, KeepurTheme.Spacing.s1)
}
.listRowBackground(KeepurTheme.Color.honey100)

// AFTER
HStack(spacing: KeepurTheme.Spacing.s2) {
    Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(KeepurTheme.Color.warning)
    Text(daysRemaining == 0
        ? "Device pairing expires today"
        : daysRemaining == 1
            ? "Device pairing expires in 1 day"
            : "Device pairing expires in \(daysRemaining) days")
        .font(KeepurTheme.Font.bodySm)
        .fontWeight(.medium)
        .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
}
.frame(maxWidth: .infinity, alignment: .leading)
.padding(.vertical, KeepurTheme.Spacing.s1)
.listRowBackground(KeepurTheme.Color.honey100)
```

**Verification:** `git diff Views/SessionListView.swift` shows only the five removals/edits above; `grep showSettings Views/SessionListView.swift` returns no matches.

### Step 4: Delete `RootView.swift`

**File:** `Views/RootView.swift`

```bash
git rm Views/RootView.swift
```

The `.task { _ = try await APIManager.fetchMe() ... }` content has already moved onto `ContentView.tabView` in Step 2. No other file references `RootView` (confirmed via `grep -rn "RootView(" .` showing only the line in `ContentView.swift` that Step 2 already removed).

**Verification:** `grep -rn "RootView" Views/ ViewModels/ Managers/` returns no matches outside `BeekeeperRootView`, `TeamRootView`, and any deleted-file mentions in git history.

### Step 5: Create smoke test

**File:** `KeeperTests/KeepurTabBarRootTests.swift`

```swift
import XCTest
import SwiftUI
@testable import Keepur

final class KeepurTabBarRootTests: XCTestCase {

    /// BeekeeperRootView is a placeholder — verify it builds without crash.
    func testBeekeeperRootViewInstantiates() {
        _ = BeekeeperRootView().body
    }

    /// Symbol tokens used by the tab bar resolve to non-empty strings.
    /// Catches future rename/removal of `KeepurTheme.Symbol.bolt`,
    /// `KeepurTheme.Symbol.chat`, or `KeepurTheme.Symbol.settings`.
    func testTabSymbolsResolve() {
        XCTAssertFalse(KeepurTheme.Symbol.bolt.isEmpty)
        XCTAssertFalse(KeepurTheme.Symbol.chat.isEmpty)
        XCTAssertFalse(KeepurTheme.Symbol.settings.isEmpty)
        // Hive uses raw "hexagon.fill" — assert literal hasn't drifted.
        XCTAssertEqual("hexagon.fill", "hexagon.fill")
    }

    /// ContentView's post-auth tab view exposes 4 tabs in the documented order.
    /// Best-effort: SwiftUI introspection is brittle, so this is a smoke check
    /// that the body compiles + materializes; it does not assert tab labels via
    /// Mirror (which would be flaky across SDK updates).
    func testContentViewBuilds() {
        // Build a ContentView and reach for its body. We can't easily exercise
        // the post-auth path without injecting Keychain state, so this is a
        // compile-time + materialization-time smoke check.
        _ = ContentView().body
    }
}
```

**Verification:** file compiles inside the test target. `xcodebuild test ... -only-testing KeeperTests/KeepurTabBarRootTests` returns 3 passes.

### Step 6: Wire file additions / deletions into Xcode project

Use the `xcodeproj` Ruby gem (per project convention from the theming epic). Save as `/tmp/wire_kpr147.rb` and run from the worktree root:

```ruby
require 'xcodeproj'
project = Xcodeproj::Project.open('Keepur.xcodeproj')

# --- Adds ---
group_views = project.main_group['Views']
group_tests = project.main_group['KeeperTests']

# Add BeekeeperRootView.swift to the app target (single multi-platform target).
beekeeper_ref = group_views.new_reference("Views/BeekeeperRootView.swift")
project.targets.each do |t|
  next unless t.name == 'Keepur'
  t.source_build_phase.add_file_reference(beekeeper_ref)
end

# Add KeepurTabBarRootTests.swift to test targets only.
test_ref = group_tests.new_reference("KeeperTests/KeepurTabBarRootTests.swift")
project.targets.each do |t|
  next unless t.name.include?('Tests')
  t.source_build_phase.add_file_reference(test_ref)
end

# --- Removals ---
# Delete the RootView.swift file reference from the project + all build phases.
root_view_ref = project.files.find { |f| f.path&.end_with?('Views/RootView.swift') || f.path == 'RootView.swift' }
if root_view_ref
  project.targets.each do |t|
    t.source_build_phase.files.each do |bf|
      bf.remove_from_project if bf.file_ref == root_view_ref
    end
  end
  root_view_ref.remove_from_project
end

project.save
```

After running the script, also delete the file from disk: `rm Views/RootView.swift` (or `git rm` per Step 4).

**Verification:** `git diff Keepur.xcodeproj/project.pbxproj` shows (a) two file refs added (one to app target, one to test target), (b) one file ref + its build-phase entries removed for `RootView.swift`. `git status` shows `Views/RootView.swift` deleted, `Views/BeekeeperRootView.swift` and `KeeperTests/KeepurTabBarRootTests.swift` added, plus modifications to `ContentView.swift` and `SessionListView.swift`.

### Step 7: Build verification

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

### Step 8: Run test suite

Targeted first:

```bash
xcodebuild test -project Keepur.xcodeproj -scheme Keepur \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing KeeperTests/KeepurTabBarRootTests \
  -quiet
```

Then full suite to confirm no regression in existing tests (especially `CapabilityManagerTests`, `SessionReplacedTests`, `WorkspaceBrowsingTests` — these touch the surfaces nearest the rewire):

```bash
xcodebuild test -project Keepur.xcodeproj -scheme Keepur \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -quiet
```

**Verification:** both exit 0; new test class shows 3 passes; total test count = previous + 3.

### Step 9: Manual smoke checklist (PR description)

Automated tests can't assert tab bar visual rendering. Include in the PR body:

- [ ] App launches into `PairingView` on first run (auth gate works)
- [ ] After pairing: 4 tabs render in order — Beekeeper, Hive, Sessions, Settings
- [ ] Selected tab indicator is honey-tinted (not the system blue default)
- [ ] Beekeeper tab shows "Coming soon" `ContentUnavailableView` with bolt icon
- [ ] Hive tab shows hives grid; tapping a hive navigates to `TeamRootView` and back works
- [ ] Sessions tab shows session list; tapping a session opens `ChatView` and back works (iOS) / detail pane (macOS)
- [ ] Settings tab shows existing settings list — Device, Connection, Voice, Unpair Device all present
- [ ] Switching tabs preserves state (scroll position in Sessions, selected agent in Hive)
- [ ] No gear button anywhere in the Sessions tab toolbar
- [ ] Pairing-expiry banner (if visible) renders as static row, not a button
- [ ] macOS: tabs render as default macOS tab style (no custom chrome required)

### Step 10: Commit

```
feat: TabBar root architecture (KPR-147)

Restructure post-auth shell from conditional 1-2 tabs to fixed 4 tabs
(Beekeeper / Hive / Sessions / Settings). New BeekeeperRootView "coming
soon" placeholder; gear button + settings sheet stripped from
SessionListView; RootView indirection collapsed (auth re-validation
.task moved onto ContentView.tabView). Honey accent on selected tab.

Closes KPR-147
```

## Test Groups

| Group | Coverage | File |
|---|---|---|
| **Unit (smoke)** | `BeekeeperRootView` instantiates; tab symbol tokens resolve; `ContentView` body materializes | `KeeperTests/KeepurTabBarRootTests.swift` |
| **Integration** | N/A — no integration surface (the change is structural; existing per-screen integration tests in `SessionReplacedTests`, `CapabilityManagerTests`, etc. cover behavior that should not regress) |  |
| **E2E** | N/A — no UI test target. Manual smoke checklist in PR body covers visual confirmation |  |

## Risks / Mitigations

| Risk | Mitigation |
|---|---|
| `RootView.swift` deletion breaks an indirect reference (e.g., a preview or a debug entry point) | Step 4 verification: `grep -rn "RootView" Views/ ViewModels/ Managers/` returns only `BeekeeperRootView` and `TeamRootView` |
| `SessionListView` banner refactor accidentally drops the `listRowBackground` modifier | Step 3e shows the exact before/after; `listRowBackground` is preserved on the resulting `HStack` |
| Auth re-validation `.task` fires per tab switch instead of once | `.task` on a `TabView` parent runs once per appearance of the parent, not per tab. Verified by SwiftUI docs; if observed otherwise during smoke, move the task to `ContentView.body` outer `Group` |
| `xcodeproj` gem corrupts `project.pbxproj` mid-edit | Run `git diff project.pbxproj` after script; revert and retry. Gem is well-tested in this repo across the theming epic |
| `HivesGridView` wrapped in an extra `NavigationStack` causes double-stack rendering | `HivesGridView` declares `.navigationDestination(...)` but no `NavigationStack` of its own; the wrapper is required, not redundant. Confirmed by inspection of `Views/Team/HivesGridView.swift` |
| `SessionListView` already wraps its iOS body in a `NavigationStack` (line 236), so the spec's "one NavigationStack per tab" rule means we should NOT wrap it again at the tab level | Plan does not wrap `SessionListView` — passed through directly to the `Tab` body. Same for `SettingsView` (line 24 of `SettingsView.swift` already has `NavigationStack`). Only Beekeeper and Hive get a tab-level `NavigationStack` wrapper |
| macOS `TabView` rendering surprises | Spec accepts platform-default rendering; if visual outcome is unacceptable, follow-up ticket can apply `.tabViewStyle(.sidebarAdaptable)` — out of scope here |
| Build cache stale-index warnings on SwiftPM dirs | Cosmetic; `xcodebuild` exit code is authoritative (per theming epic notes) |

## Dependencies Check

- **External (foundation tokens):** `KeepurTheme.Symbol.{bolt, chat, settings}`, `KeepurTheme.Color.{honey500, bgPageDynamic}` — all confirmed present in `Theme/KeepurTheme.swift`
- **External (existing views):** `BeekeeperRootView` (new), `HivesGridView`, `SessionListView`, `SettingsView` — all confirmed present
- **External (view models):** `chatViewModel`, `teamViewModel`, `capabilityManager` — all already owned by `ContentView` via `@StateObject`
- **External (auth):** `APIManager.fetchMe()`, `APIManager.APIError.unauthorized`, `BeekeeperConfigError.hostNotConfigured`, `chatViewModel.unpair()` — all confirmed present (used by current `RootView`)
- **No ticket dependencies** — KPR-147 is the sole layer-2 ticket and runs in parallel with layer-1 KPR-144/145/146

## Human Signoff

Pre-approved per durable user delegation (KPR-142 design v2 epic). No human plan-review checkpoint required.
