# KPR-147 — TabBar root architecture (Beekeeper / Hive / Sessions / Settings)

**Date:** 2026-05-02
**Epic:** [KPR-142 design v2](https://linear.app/keepur/issue/KPR-142)
**Layer:** 2 (architecture — blocks all per-screen consumption tickets)
**Depends on:** none

## Problem

The current app shell (`Views/ContentView.swift`) is in an awkward in-between state. It already wraps post-auth content in a `TabView`, but the tab set is dynamic (1 or 2 tabs depending on `capabilityManager.hives.count`) and only exposes Hive(s) and Beekeeper. Sessions are buried inside the Beekeeper tab via `RootView → SessionListView`, and Settings is reached only via a gear button hidden in `SessionListView`'s toolbar (`Views/SessionListView.swift:103-110`). The design v2 mockups specify a fixed 4-tab root (Beekeeper / Hive / Sessions / Settings) where each tab is a top-level destination with its own navigation stack.

This is the architecture ticket — it blocks every per-screen consumption ticket (KPR-148–KPR-155) because each layer-3 ticket's entry point depends on which tab it lands under.

## Solution

Replace `ContentView`'s conditional `tabView` builder with a fixed 4-tab `TabView`. Each tab owns its own `NavigationStack` (or `NavigationSplitView` on macOS where the existing screen already uses one). Add a tiny new `Views/BeekeeperRootView.swift` "Coming soon" placeholder. Delete the gear button from `SessionListView` (the Settings tab makes it redundant). The auth gate (`isPaired` check) stays exactly where it is in `ContentView` — the `TabView` only renders post-auth.

No changes to per-screen view internals. Sessions list, Hive grid, Settings list, and pairing flow all keep their current bodies; only their roosting changes.

## Key Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Tab order | Beekeeper, Hive, Sessions, Settings | Matches backlog spec literal ordering; Beekeeper-first gives the "direct chat" affordance top billing as the canonical entry point |
| Tab count | Fixed 4 (no hive-count gating) | Backlog spec is explicit: 4 tabs always render. Hive tab handles 0/1/N hives internally (existing `HivesGridView` already supports the empty + populated cases) |
| Beekeeper symbol | `bolt.fill` (`KeepurTheme.Symbol.bolt`) | Honey lightning bolt is already the brand signal for "live agent activity" (used in `SessionRow` active state). `terminal.fill` reads too "developer tools"; `eyes.inverse` (current placeholder) is opaque without context. Bolt reuses an existing `KeepurTheme.Symbol` constant — no new token needed |
| Hive symbol | `"hexagon.fill"` (raw string) | No `KeepurTheme.Symbol` token exists for hexagon and hive is the only consumer; adding a token is premature. Raw string matches backlog spec literal |
| Sessions symbol | `KeepurTheme.Symbol.chat` | Token exists, matches backlog spec literal |
| Settings symbol | `KeepurTheme.Symbol.settings` | Token exists, matches backlog spec literal |
| NavigationStack scope | One `NavigationStack` per tab on iOS; preserve existing `NavigationSplitView` per tab on macOS | Each tab's back stack stays isolated — popping inside Hive doesn't affect Sessions. Critical so a deep dive into an agent doesn't bounce the user back to the root when they switch tabs and return. SwiftUI `TabView` preserves each child's view state (including `NavigationStack` path) automatically |
| Tab accent color | `.tint(KeepurTheme.Color.honey500)` on the `TabView` | Per backlog acceptance ("honey accent on selected tab") and brand recipe (honey is the only accent) |
| Beekeeper placeholder | New view `BeekeeperRootView` — single `ContentUnavailableView` with bolt icon + "Coming soon" copy, wrapped in a `NavigationStack` so the tab has a title bar | Tab needs to render *something* and swiftUI requires a `View` body; deferring the placeholder out of this ticket would block the tab from rendering. Keep it minimal |
| Settings tab body | Existing `SettingsView` reused as-is, wrapped in a `NavigationStack` (it already brings its own internal `NavigationStack`) | "Global semantics" restructure (moving beekeeper URL / user / device name into Settings) is explicitly out of scope per the ticket — that's a follow-up. Today's Settings already covers Device + Connection + Voice + Unpair, which is good enough as a top-level tab |
| `RootView` removal | Delete `Views/RootView.swift` entirely; fold the `APIManager.fetchMe()` auth-revalidation `.task` into `ContentView.tabView` (or `ContentView.body` post-auth) | After this change `RootView` only owns one `.task` modifier — no longer earning its own file. Better hosted on the root `TabView` so the check runs once when the shell appears, not once per tab |
| Gear button removal | Delete the `showSettings`/`SettingsView` sheet machinery from `SessionListView` (toolbar button + `@State` + `.sheet` + macOS sheet copy) | Settings tab makes it redundant. Leaving a stale entry point would confuse users about which surface "owns" the settings |
| Pairing flow interaction | Unchanged — `PairingView` still renders pre-auth; `TabView` still renders post-auth; `onPaired` still flips `isPaired = true` | Auth gate and TabView are decoupled by design |
| Cross-platform parity | Accept SwiftUI's default per-platform `TabView` rendering: iOS = bottom tab bar, macOS = `NSTabViewController`-style title-bar tabs | Don't force a custom shape. Backlog spec doesn't mandate platform-identical chrome; the user-explicit memory is "as long as it more or less looks like the mockup, I don't care beyond that". The 4-tab structure and honey tint carry on both |

## Architecture

### Before

```
KeepurApp
└── ContentView (auth gate)
    ├── PairingView                          (pre-auth)
    └── tabView                              (post-auth, conditional 1-2 tabs)
        ├── Hive  / Hives                    (only if capabilityManager.hives ≥ 1)
        │   └── TeamRootView | HivesGridView
        └── Beekeeper                        (always)
            └── RootView
                └── SessionListView
                    ├── toolbar gear → SettingsView (sheet)
                    └── toolbar compose → WorkspacePickerView (sheet) → ChatView
```

### After

```
KeepurApp
└── ContentView (auth gate, unchanged)
    ├── PairingView                          (pre-auth, unchanged)
    └── tabView                              (post-auth, fixed 4 tabs)
        ├── Beekeeper
        │   └── NavigationStack { BeekeeperRootView }      (NEW placeholder)
        ├── Hive
        │   └── NavigationStack { HivesGridView } | TeamRootView
        ├── Sessions
        │   └── NavigationStack { SessionListView } (iOS)
        │       NavigationSplitView { SessionListView | ChatView } (macOS — existing internal split)
        └── Settings
            └── SettingsView                 (already brings its own NavigationStack)
        .tint(KeepurTheme.Color.honey500)
```

The `RootView.swift` indirection collapses; its `.task { _ = try? await APIManager.fetchMe() }` revalidation moves onto the post-auth root in `ContentView`.

## Component Designs

### `BeekeeperRootView` (new)

```swift
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

#### Visual Spec

- **Container:** `ContentUnavailableView` (matches the existing empty-state pattern in `SessionListView` and `HivesGridView`)
- **Icon:** `KeepurTheme.Symbol.bolt` rendered at default `ContentUnavailableView` icon size
- **Title:** "Beekeeper" — `Label` title slot picks up the system display tier
- **Description:** "Direct interaction with the Beekeeper backend is coming soon."
- **Background:** `KeepurTheme.Color.bgPageDynamic` (consistent with other empty-state surfaces)
- **Navigation title:** "Beekeeper" so the tab has a chromed top bar even though there's no detail to push to

No additional content. Future iterations replace the body wholesale; the tab plumbing (icon, label, navigation stack wrapper) stays.

### `ContentView.tabView` (modified)

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
            // HivesGridView already navigates into TeamRootView via
            // .navigationDestination(isPresented: $navigateToHive); preserve.
            NavigationStack {
                HivesGridView(
                    capabilityManager: capabilityManager,
                    teamViewModel: teamViewModel
                )
            }
        }

        Tab("Sessions", systemImage: KeepurTheme.Symbol.chat) {
            // SessionListView already wraps its iOS body in a NavigationStack
            // and its macOS body in a NavigationSplitView. Pass it through.
            SessionListView(viewModel: chatViewModel)
        }

        Tab("Settings", systemImage: KeepurTheme.Symbol.settings) {
            // SettingsView already has an internal NavigationStack.
            SettingsView(viewModel: chatViewModel)
        }
    }
    .tint(KeepurTheme.Color.honey500)
    .task {
        // Migrated from RootView — re-validate auth once on shell appear.
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

### `SessionListView` (modified — gear button deletion)

Three deletions, no additions:

1. **`@State private var showSettings = false`** — delete (no longer driven anywhere).
2. **`sessionToolbar`** — delete the `ToolbarItem(placement: .automatic) { Button { showSettings = true } ... gearshape ... }` block. Keep the connection-status circle and the compose button.
3. **`.sheet(isPresented: $showSettings) { SettingsView(...) }`** — delete from both `sessionSheets` (iOS path) and `macOSBody` (macOS path).

`SettingsView` itself is not modified — it just gets a new top-level home.

The pairing-expiry banner inside `sessionList` still references `showSettings = true` in its tap handler. Repurpose: change that tap to no-op or to a `print` placeholder, **OR** the cleaner option — change the banner's wording to remove the implication that tapping does something, since the user can navigate to Settings via the tab. Pick the latter: drop the `Button { showSettings = true }` wrapper around the banner row, leaving it as a static `HStack`. (Out of scope to redesign the banner; minimal change is to strip the tap.)

### `RootView.swift` (deleted)

The file's only responsibility — the `APIManager.fetchMe()` auth re-validation — moves onto `ContentView.tabView`'s `.task` modifier. Delete the file and its Xcode project reference.

## Tab semantics

| Tab | Body | Navigation surface | Future home of |
|---|---|---|---|
| Beekeeper | `BeekeeperRootView` (placeholder) | `NavigationStack` wrapper for title bar | Direct Claude chat (own future ticket) |
| Hive | `HivesGridView` → push `TeamRootView` | `NavigationStack` wrapper | Existing hive grid + team chat (per-screen redesigns land via KPR-150 / KPR-151 / KPR-153 / KPR-155) |
| Sessions | `SessionListView` (iOS: own `NavigationStack`; macOS: own `NavigationSplitView`) | Self-managed | Existing Claude Code sessions list (KPR-148 redesigns the row) |
| Settings | `SettingsView` (own internal `NavigationStack`) | Self-managed | Existing settings (KPR-149 redesigns to card-grouped sections; "global semantics" restructure is a separate follow-up) |

## State preservation across tab switches

SwiftUI `TabView` preserves each child view's state by default — view identity is keyed on tab position and the view tree is kept alive (not torn down + rebuilt) as the user switches tabs. This means:

- Scroll position in `SessionListView` survives a Sessions → Settings → Sessions round trip.
- `HivesGridView`'s `navigateToHive` `@State` survives, so a user who drilled into a hive and switched away returns to the same agent chat.
- `chatViewModel` and `teamViewModel` are owned by `ContentView` via `@StateObject` and persist across all tab switches — no reconnect on tab change.

No additional `@SceneStorage` or `id()` qualifier needed.

## Smoke Test Scope

Single test file `KeeperTests/KeepurTabBarRootTests.swift`, wired via the existing `KeepurThemeFontsTests.swift` pattern (`@testable import Keepur`).

| Component | Test cases |
|---|---|
| `BeekeeperRootView` | Instantiates without crash; `_ = view.body` doesn't throw |
| `ContentView.tabView` shape | Reflection / `Mirror` confirms `TabView` is the root post-auth body, has 4 `Tab` children, and tab labels in order are `["Beekeeper", "Hive", "Sessions", "Settings"]` (best-effort — SwiftUI introspection is brittle; if Mirror shape is unstable, downgrade to "instantiates without crash" + manual smoke checklist in the PR description) |
| `KeepurTheme.Symbol` references | `Symbol.bolt`, `Symbol.chat`, `Symbol.settings` all resolve to non-empty strings (guards against future token rename) |

No UI snapshot tests (no library in project; over-engineered for a tab shell).

## Out of Scope

- Beekeeper tab actual content (`BeekeeperRootView` ships as a placeholder; future ticket replaces the body)
- Settings restructure to "global semantics" (own follow-up — the *content* of Settings stays as it is today; only its rooting changes)
- Deep-linking between tabs (no `selection:` binding driven by external state)
- Per-tab badge counts (foundation atom `KeepurUnreadBadge` lands in KPR-144; consumption is held until per-channel unread tracking ships in the held-features epic)
- `KeepurTheme.Symbol.hexagon` token — Hive uses raw `"hexagon.fill"` literal; tokenization can come if a second consumer appears
- Custom tab-bar chrome (e.g., honey background, bespoke selected state) — accept SwiftUI defaults + `.tint(honey500)`
- macOS sidebar `TabView` style override (e.g., `.tabViewStyle(.sidebarAdaptable)`) — accept the default per-platform rendering
- Renaming the existing "Hive" / "Hives" pluralization gating (was conditional on hive count; now always "Hive" singular per backlog spec — `HivesGridView` already handles the empty case with `ContentUnavailableView`)

## Open Questions

None blocking. Two notes flagged for future tickets:

1. **`HivesGridView` already navigates into `TeamRootView` via `.navigationDestination(isPresented: $navigateToHive)`.** That destination preserves correctly inside the Hive tab's `NavigationStack`. Confirmed by inspection — no change needed.
2. **The pairing-expiry banner inside `SessionListView`** currently tapped open Settings. After this ticket the banner is non-interactive. If we want it to *deep-link* to the Settings tab, that needs a programmatic tab `selection` binding (out of scope here; trivial follow-up).

## Files Touched

- `Views/BeekeeperRootView.swift` (new)
- `Views/ContentView.swift` (modified — replace `tabView` body, fold in auth re-validation `.task`)
- `Views/RootView.swift` (deleted)
- `Views/SessionListView.swift` (modified — strip gear button, `showSettings` state, settings sheet on both iOS + macOS, banner tap handler)
- `KeeperTests/KeepurTabBarRootTests.swift` (new)
- `Keepur.xcodeproj/project.pbxproj` (wire new files in / out)

## Dependencies / Sequencing

- **Blocks:** KPR-148 (Sessions row — needs Sessions tab landing), KPR-149 (Settings card sections — needs Settings tab landing), KPR-150 / KPR-151 / KPR-153 / KPR-155 (all Hive-tab consumers), KPR-152 (chat header — both Sessions and Hive entry points)
- **Blocked by:** none (parallel with KPR-144, KPR-145, KPR-146 in layer 1)
- Layer 2 sole ticket — must merge before any layer-3 ticket lands

## Human Signoff

Pre-approved per durable user delegation (KPR-142 design v2 epic — backlog spec defines the 4-tab structure exactly; user explicit: "as long as it more or less looks like the mockup, I don't care beyond that"). Recorded in epic-orchestrator memory.
