# keepur-ios: Multi-Hive Capability Picker

**Date:** 2026-04-15
**Status:** Draft
**Author:** brainstorm session
**Related:** beekeeper KPR-21 (merged), KPR-25 (in progress); hive KPR-23 (in progress); federation spec `beekeeper/docs/specs/2026-04-12-pair-gateway-and-hive-federation.md`

## Problem

The keepur-ios client speaks to beekeeper using a hardcoded `channel=team` string and reads the `capabilities` array out of the `/pair` response. Both contracts are going away in the upcoming server work:

- **KPR-25** deletes `channel=team` server-side and replaces it with `channel=<capability-name>`. Once deployed, the existing `TeamWebSocketManager` URL (`Managers/TeamWebSocketManager.swift:43`) will receive `404 unknown-capability` on every upgrade attempt.
- **KPR-25** also drops the `capabilities` field from the `/pair` response. `Managers/APIManager.swift:41` and `Views/PairingView.swift:197` will silently end up with an empty list.
- **The federation spec** moves capabilities to a runtime-fetched `GET /capabilities` endpoint, refreshed on app foreground and WS reconnect, so a Hive starting/stopping after pairing is reflected without re-pairing.
- **KPR-25 explicitly punts** the iOS picker UX and the multi-hive landing experience to this client. With more than one Hive registered behind a single beekeeper, the user needs a way to choose which one to talk to.

This spec covers the iOS-side changes required to (a) keep working against the new wire contract and (b) land the picker UX for the multi-Hive case.

## Goals

- Client picks the team WebSocket channel by capability name from a runtime-fetched list, never from a hardcoded string.
- The Team tab renders correctly across the 0/1/2+ hive cases without restart or re-pair.
- A user with two or more registered Hives can choose between them via a master-detail picker, and that choice persists across cold starts.
- Health drops and stale capability lists self-heal via refetch — no manual reconnect dance.
- Existing single-Hive deployments (the dodi mac mini today) see no functional change in tab layout or navigation.

## Non-Goals

- Concurrent fan-out across multiple Hives (single-active model only — N concurrent sockets is rejected for this release).
- macOS-specific UX. The sidebar/grouping conversation is deferred until the macOS pass.
- Avatars, icons, or friendly display names for capabilities. Capability names render verbatim. Friendly mapping is a future ticket.
- Surfacing the `user` identity in iOS UI. The new `?user=` server contract is internal between beekeeper and hive — no client change.
- Pair-flow body changes. `POST /pair { code, name }` is unchanged.
- Caching the capability list across launches. Always refetch.

## Design

### Server contract recap

- `GET /capabilities` (Bearer device JWT) → `{ "capabilities": ["beekeeper", "hive-personal", ...] }`. Names sorted, `beekeeper` always first and always present.
- WebSocket upgrade: `wss://<host>/?token=<jwt>&channel=<capability-name>`. `channel=beekeeper` is the in-process Claude Code session path. Any other value is proxied to the matching capability or rejected with `404 unknown-capability` (never registered) or closed `1011 capability-unavailable` (any upstream failure — covers both early-upgrade error and mid-session drop).
- `/pair` response no longer includes `capabilities`.

### CapabilityManager — new state owner

New file: `Managers/CapabilityManager.swift`. `@MainActor`, `ObservableObject`. Owned by `ContentView` as a third `@StateObject`, sibling to `chatViewModel` and `teamViewModel`.

```swift
@MainActor
final class CapabilityManager: ObservableObject {
    @Published private(set) var hives: [String] = []        // non-beekeeper, sorted
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var lastError: String?

    var selectedHive: String? { get set }                   // UserDefaults-backed
    var onAuthFailure: (() -> Void)?

    func refresh() async                                    // GET /capabilities
}
```

- `refresh()` is idempotent and concurrency-safe (in-flight guard). On 401 it calls `onAuthFailure`, wired to the same unpair path as the existing managers. On success it filters out the literal `"beekeeper"`, replaces `hives`, and reconciles `selectedHive` (clears it if the persisted name is no longer in the list).
- `selectedHive` setter writes through to `UserDefaults.standard` under key `"selectedHive"`. Reads on cold start return whatever was last persisted, even if the current list hasn't been fetched yet — `refresh()` will reconcile shortly after.
- When `hives.count == 1`, `refresh()` auto-sets `selectedHive` to the sole entry. This means the single-Hive code path always has a value to read and never has to special-case nil.

### Tab structure

`ContentView.body` derives the tab set from `capabilityManager.hives.count`:

| Hive count | Tabs rendered |
|---|---|
| 0 | Beekeeper only |
| 1 | Hive + Beekeeper (current shape; single-Hive landing screen) |
| 2+ | Hives + Beekeeper (plural label; tab opens a `NavigationStack` rooted in `HivesGridView`) |

The Hive(s) tab label and icon are static (`"Hive"` / `"Hives"`, `hexagon.fill`) — the *landing screen header* is what reflects the active capability name (see TeamRootView header below).

**Cold-start sequencing.** On `ContentView.onAppear` (when paired), `Task { await capabilityManager.refresh() }` fires. Until the first refresh returns, `hives` is empty and only the Beekeeper tab is rendered. When the refresh lands, the Hive(s) tab appears via the normal SwiftUI re-render. No placeholder tab, no flicker-prone spinner-tab. The user sees the Beekeeper tab immediately and the Hive tab appears within one network round-trip.

### Pair flow & APIManager

**`Managers/APIManager.swift`:**

- `PairResponse` drops the `capabilities` field. The decode in `pair()` no longer reads `json["capabilities"]`.
- New method:
  ```swift
  static func fetchCapabilities() async throws -> [String]
  ```
  `GET https://<host>/capabilities` with `Authorization: Bearer <token>`. Returns the verbatim array (including `"beekeeper"`). 401 → `APIError.unauthorized`. Other failures → `APIError.requestFailed`. Caller (CapabilityManager) is responsible for filtering out `"beekeeper"`.

**`Views/PairingView.swift`:**

- The line that does `KeychainManager.capabilities = response.capabilities` is removed.
- `PairingView` now takes a `capabilityManager: CapabilityManager` parameter (passed down from `ContentView`).
- After `KeychainManager.token = response.token` and friends, but before `onPaired()` is called, kick off `await capabilityManager.refresh()`. This guarantees the first render after pairing already has the correct tab set — no flicker through "Beekeeper only" while a background fetch races.

**`Managers/KeychainManager.swift`:**

- The `capabilities` accessor is removed entirely. Capabilities are runtime state, not persisted-with-token state, per the federation spec. Any read sites are cleaned up.
- `KeychainManager.clearAll()` (the unpair path) also removes `"selectedHive"` from `UserDefaults` so re-pairing starts clean.

### WebSocket connection changes

**`Managers/WebSocketManager.swift`** (the Beekeeper-channel manager):

- The URL becomes `wss://<host>/?token=<jwt>&channel=beekeeper`. Currently it omits the `channel` param and relies on the server default. KPR-25 has an open item about removing that default; explicit-is-cheap and future-proofs the client.

**`Managers/TeamWebSocketManager.swift`:**

- The hardcoded `&channel=team` literal at line 43 is deleted.
- `connect()` becomes `connect(channel: String)`. Caller (`TeamViewModel`) passes the resolved capability name, which it reads from `capabilityManager.selectedHive`. If the manager has no selected hive (transient — should be impossible if the tab is visible), `connect` is a no-op and logs.
- The URL becomes `wss://<host>/?token=<jwt>&channel=<capability-name>`.

**`ViewModels/TeamViewModel.swift`:**

- `configure(context:)` gains a `capabilityManager: CapabilityManager` parameter and stores a weak reference.
- `ws.connect()` calls become `ws.connect(channel: capabilityManager?.selectedHive ?? <noop>)`.
- A new `@Published var disconnectedBanner: String?` drives an inline banner in `TeamRootView` for the soft-warn and 404-reconcile paths described next.

### Close-code & failure handling (unified Q2/Q4 path)

`URLSessionWebSocketTask` doesn't surface HTTP upgrade response codes cleanly — a 404 on upgrade typically arrives as a generic `failure` with `closeCode == .invalid`, and may also surface as a `URLError` from the `receive` continuation with no close code at all. Rather than introspect HTTP at the task level, the client uses **refetch-and-reconcile**, which collapses the health-drop case (1011 `capability-unavailable`) and the unknown-capability case (404) into one mechanism, differentiated by what the refetched list says:

1. On any team-WS failure (close callback **or** receive-error continuation) **other than** the existing `4001` auth-failure path — both wire-up sites in `TeamWebSocketManager` must funnel into this single handler:
   - `TeamViewModel` sets `disconnectedBanner = "<capability-name> is unavailable — tap to retry."`
   - `TeamViewModel` calls `capabilityManager.refresh()`.
2. After refresh completes:
   - If `selectedHive` is no longer in `hives` → clear `selectedHive`, dismiss the banner, navigate back. In the 1-hive case this means the Hive tab disappears entirely on next render. In the 2+-hive case the user lands on `HivesGridView`.
   - If `selectedHive` is still in `hives` → leave the banner visible. Tap retry triggers `ws.connect(channel:)` again. Repeated retries are gated by the existing reconnect backoff in `TeamWebSocketManager`.

The `4001` auth-failure path is unchanged — still routes to `onAuthFailure` → unpair.

This design accepts that the client cannot distinguish "404 immediately on upgrade" from "1011 mid-session" at the URLSession layer, and uses the refetched list as the authoritative tiebreaker. The list is the right semantic check anyway: "is this hive still available, regardless of what the close code said."

### HivesGridView (2+ hives only)

New file: `Views/Team/HivesGridView.swift`. Used only when `hives.count >= 2`.

- `LazyVGrid` with adaptive columns. Each cell is a card showing the capability name verbatim (e.g. `hive-personal`). No avatar, no icon — future work.
- Tap a card → set `capabilityManager.selectedHive = name`, then push `TeamRootView` via `NavigationLink` / `navigationDestination`.
- Pull-to-refresh → `await capabilityManager.refresh()`.
- `.onAppear` → `await capabilityManager.refresh()` (Q5b: refetch when the user opens the picker).
- Empty-state `ContentUnavailableView` if `hives` becomes empty mid-view (last hive dropped between refreshes).

**Tab wiring (sketch):**

```swift
// 2+-hive case
Tab("Hives", systemImage: "hexagon.fill") {
    NavigationStack {
        HivesGridView(capabilityManager: capabilityManager,
                      teamViewModel: teamViewModel)
            .navigationDestination(isPresented: hasSelectionBinding) {
                TeamRootView(viewModel: teamViewModel)
            }
    }
}
```

`hasSelectionBinding` is a `Binding<Bool>` derived from `capabilityManager.selectedHive != nil`. On cold start, if the persisted `selectedHive` is in the refreshed `hives`, the destination push fires automatically — landing the user back on their last Hive (Q3b). Back-button from `TeamRootView` clears `selectedHive`, returning to the grid.

**1-hive case:** no `NavigationStack`, no grid. The Hive tab is just `TeamRootView` directly (current shape). `CapabilityManager` auto-sets `selectedHive` to the sole entry on every refresh, so the team WS always has a channel to read.

### TeamRootView header

`Views/Team/TeamRootView.swift:10` currently hardcodes `.navigationTitle("Team")` on the **sidebar column** of the `NavigationSplitView` (the `TeamSidebarView` modifier inside the master column closure). The change applies to that exact site:

```swift
.navigationTitle(capabilityManager.selectedHive ?? "Team")
```

`TeamRootView` takes the `CapabilityManager` as an `@ObservedObject` parameter. The fallback `"Team"` only renders during the brief window between unpair and view teardown.

### Refetch triggers (summary)

| Trigger | Site |
|---|---|
| App foreground | `ContentView` `.onChange(of: scenePhase)` — alongside the existing WS reconnect calls |
| Successful pair | `PairingView.pair()` — before `onPaired()` |
| Team WS failure | `TeamViewModel` failure handler (Section: close-code handling) |
| Hives tab opened (2+ case) | `HivesGridView.onAppear` |
| Pull-to-refresh | `HivesGridView` refreshable modifier |

The federation spec also lists "WS reconnect" as a trigger. That's covered transitively: the team WS failure path refetches, and a subsequent successful reconnect doesn't need its own refresh because the failure path already ran one.

### Migration

Existing installs already have a paired token but no `selectedHive` and no notion of capability state. On first launch after upgrade:

1. `ContentView.onAppear` runs `capabilityManager.refresh()`.
2. `selectedHive` is nil. After refresh, if `hives.count == 1`, the auto-set behavior writes the sole entry into `selectedHive`. If `hives.count >= 2`, `selectedHive` stays nil and the user sees the grid on first Hives-tab tap. If `hives.count == 0`, the Hive tab doesn't render — Beekeeper-only.
3. No data migration, no force re-pair. The token from the previous version is still valid (KPR-25 doesn't change pair semantics, only the response shape).

## Dependencies

- Beekeeper KPR-25 must be deployed to the user's beekeeper instance before this iOS build is shipped — the explicit `channel=beekeeper` and the `GET /capabilities` endpoint both require the new server. Coordination is via the `beekeeper.dodihome.com` mac mini deploy; ship order is **server first, client second**.
- This spec assumes the `/capabilities` endpoint shape is exactly `{ "capabilities": string[] }` as implemented in `beekeeper/src/index.ts` and `beekeeper/src/capabilities.ts` on the KPR-25 worktree. Any shape change server-side requires updating `APIManager.fetchCapabilities()`.

## Open Questions

None blocking. Possible follow-ups for future tickets:
- Friendly display names / avatars for capabilities.
- macOS sidebar treatment for multi-Hive (deferred until the macOS pass).
- Whether to surface the server-asserted `user` identity anywhere in the iOS UI.

## Files Touched

| File | Change |
|---|---|
| `Managers/CapabilityManager.swift` | **New** — capability state, refresh, persistence |
| `Managers/APIManager.swift` | Drop `capabilities` from `PairResponse`; add `fetchCapabilities()` |
| `Managers/WebSocketManager.swift` | URL gains explicit `&channel=beekeeper` |
| `Managers/TeamWebSocketManager.swift` | Delete `&channel=team` literal; `connect(channel:)` takes the capability name |
| `Managers/KeychainManager.swift` | Remove `capabilities` accessor; `clearAll()` clears `"selectedHive"` UserDefaults key |
| `ViewModels/TeamViewModel.swift` | Take `CapabilityManager` ref; pass channel into `ws.connect`; `disconnectedBanner` published; failure handler runs refetch-and-reconcile |
| `Views/ContentView.swift` | Own `CapabilityManager` as third `@StateObject`; render tabs from `hives.count`; refresh on foreground; pass manager to `PairingView` and the team views |
| `Views/PairingView.swift` | Drop `capabilities` read; take `CapabilityManager`; refresh after successful pair |
| `Views/Team/TeamRootView.swift` | `.navigationTitle` reads from `capabilityManager.selectedHive`; render `disconnectedBanner` |
| `Views/Team/HivesGridView.swift` | **New** — card grid, pull-to-refresh, navigation push to `TeamRootView` |
| `KeeperTests/CapabilityManagerTests.swift` | **New** — see Test Plan |
| `KeeperTests/APIManagerTests.swift` (or equivalent) | New tests for `fetchCapabilities()` shape, 401 path |

## Test Plan

**`CapabilityManager`:**
- `refresh()` populates `hives` with non-beekeeper names from a stubbed API response.
- `refresh()` filters out the literal `"beekeeper"` even if the server returns it first or last.
- Auto-set: when refresh returns exactly one non-beekeeper hive, `selectedHive` is set to that name.
- Reconcile: when `selectedHive` is set but the refreshed list no longer contains it, `selectedHive` is cleared.
- Persistence: setting `selectedHive` writes through to `UserDefaults`; reading after a re-init returns the same value.
- Unpair cleanup: `KeychainManager.clearAll()` removes the `"selectedHive"` key from `UserDefaults` so a subsequent pair starts with no persisted selection.
- 401 from API → `onAuthFailure` is called.
- Concurrent `refresh()` calls do not double-fire the network request.

**`APIManager.fetchCapabilities()`:**
- 200 with valid JSON → returns array verbatim.
- 401 → throws `APIError.unauthorized`.
- 500 / network error → throws `APIError.requestFailed`.

**Tab rendering (UI test or snapshot, whichever the project uses):**
- `hives.count == 0` → only Beekeeper tab.
- `hives.count == 1` → Hive + Beekeeper.
- `hives.count >= 2` → Hives + Beekeeper.

**Pair flow:**
- After successful pair, `capabilityManager.refresh()` has been called before `onPaired()` returns. (Spy on the manager.)
- A `PairResponse` JSON payload that omits `capabilities` decodes successfully.

**Team WS failure handling:**
- A team WS close triggers `disconnectedBanner` set + `capabilityManager.refresh()` call.
- After refresh, if the active hive is no longer in the list, `selectedHive` is cleared.
- After refresh, if the active hive is still in the list, the banner remains and `ws.connect(channel:)` is wired to a retry button.
- `4001` close code still routes to `onAuthFailure`, not the new banner path.

**Manual / smoke against a live two-Hive deploy** (after KPR-25 + the hive-repo registration-name change land):
- Register two distinct hives. Verify the iOS Hives tab renders both, picker navigates correctly, last-selected persists across cold start, and a `kill -9` of one hive's process surfaces the banner without taking down the other hive's tab.
