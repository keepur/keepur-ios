# Multi-Hive Capability Picker Implementation Plan

> **For agentic workers:** Use `dodi-dev:implement` to execute this plan.

**Goal:** Land the iOS-side changes for KPR-28: switch team WS channel from the hardcoded `team` literal to a runtime-resolved capability name, fetch capabilities from `GET /capabilities`, and render a 0/1/2+ hive tab structure with a master-detail picker.

**Architecture:** Introduce `CapabilityManager` as a third `@StateObject` on `ContentView`, sibling to `ChatViewModel` and `TeamViewModel`. It owns the live capability list, the persisted `selectedHive`, and a refresh method. `ContentView` derives its tab set from `capabilityManager.hives.count`. `TeamViewModel` reads `selectedHive` before calling `TeamWebSocketManager.connect(channel:)`, and runs a refetch-and-reconcile flow on any non-4001 WS failure. A new `HivesGridView` only renders in the 2+ case.

**Tech Stack:** Swift 5, SwiftUI, SwiftData, URLSession WebSocket, UserDefaults, XCTest.

**Spec:** `docs/specs/2026-04-15-keepur-ios-multi-hive-capability-picker-design.md`

**Server dependency:** Beekeeper KPR-25 must be deployed to the target instance before this client build ships. Ship order: server → client.

---

## File Structure

| File | Role | State |
|---|---|---|
| `Managers/CapabilityManager.swift` | Runtime capability list + selectedHive persistence + refresh | **New** |
| `Managers/APIManager.swift` | Drop `capabilities` from `PairResponse`, add `fetchCapabilities()` | Modified |
| `Managers/WebSocketManager.swift` | Explicit `&channel=beekeeper` on URL | Modified |
| `Managers/TeamWebSocketManager.swift` | `connect(channel:)` parameter; delete `&channel=team` literal | Modified |
| `Managers/KeychainManager.swift` | Remove `capabilities` accessor + `hasHiveCapability`; clear `selectedHive` in `clearAll()` | Modified |
| `ViewModels/TeamViewModel.swift` | Hold `CapabilityManager` ref; pass channel to `ws.connect`; `disconnectedBanner` + refetch-and-reconcile | Modified |
| `Views/ContentView.swift` | Own `CapabilityManager`; render tabs from `hives.count`; refresh on foreground | Modified |
| `Views/PairingView.swift` | Drop `capabilities` read; take `CapabilityManager`; refresh before `onPaired()` | Modified |
| `Views/Team/TeamRootView.swift` | Title from `selectedHive`; render `disconnectedBanner` | Modified |
| `Views/Team/HivesGridView.swift` | Card grid, pull-to-refresh, NavigationStack push to `TeamRootView` (2+ hives only) | **New** |
| `KeeperTests/CapabilityManagerTests.swift` | Unit tests for refresh/filter/auto-set/reconcile/persist | **New** |
| `KeeperTests/APIManagerCapabilitiesTests.swift` | Unit tests for `fetchCapabilities()` (200/401/500) | **New** |

---

## Task 1: APIManager — drop pair capabilities, add fetchCapabilities

**Files:**
- Modify: `Managers/APIManager.swift`

- [ ] **Step 1:** Remove `capabilities` from `PairResponse` and the `pair()` decode.

Replace the `PairResponse` struct and the tail of `pair()`:

```swift
struct PairResponse {
    let token: String
    let deviceId: String
    let deviceName: String
}
```

In `pair()`, delete the `capabilities` extraction line and update the return:

```swift
return PairResponse(token: token, deviceId: deviceId, deviceName: deviceName)
```

- [ ] **Step 2:** Add `fetchCapabilities()` static method.

Append to `enum APIManager`:

```swift
static func fetchCapabilities() async throws -> [String] {
    guard let token = KeychainManager.token else { throw APIError.unauthorized }

    let baseURL = try BeekeeperConfig.httpsURL()
    let url = baseURL.appendingPathComponent("capabilities")
    var request = URLRequest(url: url)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

    let (data, response): (Data, URLResponse)
    do {
        (data, response) = try await URLSession.shared.data(for: request)
    } catch {
        throw APIError.requestFailed
    }

    guard let http = response as? HTTPURLResponse else {
        throw APIError.requestFailed
    }
    if http.statusCode == 401 {
        throw APIError.unauthorized
    }
    guard http.statusCode == 200,
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let caps = json["capabilities"] as? [String] else {
        throw APIError.requestFailed
    }
    return caps
}
```

- [ ] **Step 3:** Verify build.

Run: `xcodebuild -project Keepur.xcodeproj -scheme Keepur -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -20`
Expected: compile fails at `PairingView.swift:197` (`KeychainManager.capabilities = response.capabilities`) and `KeychainManager.swift` references — these are fixed in Tasks 3 and 7. That's expected for this intermediate step; Task 11 is the final green build.

- [ ] **Step 4:** Commit.

```bash
git add Managers/APIManager.swift
git commit -m "feat(api): drop capabilities from PairResponse, add fetchCapabilities()"
```

---

## Task 2: CapabilityManager — new state owner

**Files:**
- Create: `Managers/CapabilityManager.swift`

- [ ] **Step 1:** Create the file.

```swift
import Foundation
import Combine
import SwiftUI

@MainActor
final class CapabilityManager: ObservableObject {
    @Published private(set) var hives: [String] = []
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var lastError: String?

    var onAuthFailure: (() -> Void)?

    private static let selectedHiveKey = "selectedHive"
    private var inFlightTask: Task<Void, Never>?

    var selectedHive: String? {
        get { UserDefaults.standard.string(forKey: Self.selectedHiveKey) }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: Self.selectedHiveKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.selectedHiveKey)
            }
            objectWillChange.send()
        }
    }

    func refresh() async {
        if let inFlightTask {
            await inFlightTask.value
            return
        }
        let task = Task { await performRefresh() }
        inFlightTask = task
        await task.value
        inFlightTask = nil
    }

    private func performRefresh() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let all = try await APIManager.fetchCapabilities()
            let filtered = all.filter { $0 != "beekeeper" }.sorted()
            hives = filtered
            lastError = nil
            reconcileSelectedHive()
        } catch APIManager.APIError.unauthorized {
            lastError = "unauthorized"
            onAuthFailure?()
        } catch {
            lastError = "refresh failed"
        }
    }

    private func reconcileSelectedHive() {
        if hives.count == 1 {
            selectedHive = hives[0]
            return
        }
        if let current = selectedHive, !hives.contains(current) {
            selectedHive = nil
        }
    }

    /// Test seam: inject a pre-built list without hitting the network.
    func _setHivesForTesting(_ values: [String]) {
        hives = values.filter { $0 != "beekeeper" }.sorted()
        reconcileSelectedHive()
    }
}
```

- [ ] **Step 2:** Verify it compiles in isolation by building the full project.

Run: `xcodebuild -project Keepur.xcodeproj -scheme Keepur -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -20`
Expected: new file compiles; same pre-existing errors from Task 1 remain.

- [ ] **Step 3:** Commit.

```bash
git add Managers/CapabilityManager.swift
git commit -m "feat(capabilities): add CapabilityManager state owner"
```

---

## Task 3: KeychainManager — remove capabilities accessor, clear selectedHive

**Files:**
- Modify: `Managers/KeychainManager.swift`

- [ ] **Step 1:** Delete the `capabilitiesKey` constant (line 9), the `capabilities` computed property (lines 44–59), and the `hasHiveCapability` computed property (line 61).

- [ ] **Step 2:** Update `clearAll()` to drop the direct `delete(key: capabilitiesKey)` line and add the `UserDefaults` removal for `selectedHive`:

```swift
static func clearAll() {
    token = nil
    deviceId = nil
    deviceName = nil
    UserDefaults.standard.removeObject(forKey: "selectedHive")
    BeekeeperConfig.host = nil
}
```

- [ ] **Step 3:** In `migrateAccessibility()`, remove `capabilitiesKey` from the loop:

```swift
for key in [tokenKey, deviceIdKey, deviceNameKey] {
```

- [ ] **Step 4:** Verify no other references remain.

Run: `grep -rn "hasHiveCapability\|KeychainManager\.capabilities" --include="*.swift"`
Expected: no matches.

- [ ] **Step 5:** Commit.

```bash
git add Managers/KeychainManager.swift
git commit -m "feat(keychain): remove capabilities accessor; clear selectedHive on unpair"
```

---

## Task 4: WebSocketManager — explicit channel=beekeeper

**Files:**
- Modify: `Managers/WebSocketManager.swift:45`

- [ ] **Step 1:** Change the URL construction:

```swift
guard let baseURL = try? BeekeeperConfig.wssURL(),
      let url = URL(string: "\(baseURL.absoluteString)?token=\(token)&channel=beekeeper") else {
```

- [ ] **Step 2:** Commit.

```bash
git add Managers/WebSocketManager.swift
git commit -m "feat(ws): explicit channel=beekeeper on primary WebSocket URL"
```

---

## Task 5: TeamWebSocketManager — connect(channel:)

**Files:**
- Modify: `Managers/TeamWebSocketManager.swift`

- [ ] **Step 1:** Add a stored `currentChannel` property and change `connect()` to `connect(channel:)`, storing the channel for later reconnect attempts.

Add right below `private var tokenReadRetries = 0`:

```swift
private var currentChannel: String?
```

Replace `func connect()` signature and body-top with:

```swift
func connect(channel: String) {
    guard !isConnected, !isConnecting else { return }
    currentChannel = channel
    guard let token = KeychainManager.token else {
        if tokenReadRetries < maxTokenReadRetries {
            tokenReadRetries += 1
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                self?.retryConnect()
            }
        } else {
            tokenReadRetries = 0
            handleDisconnect()
        }
        return
    }
    tokenReadRetries = 0

    cleanupConnection()
    isConnecting = true

    guard let baseURL = try? BeekeeperConfig.wssURL(),
          let url = URL(string: "\(baseURL.absoluteString)/?token=\(token)&channel=\(channel)") else {
        print("[TeamWS] host not configured — routing to auth gate")
        isConnecting = false
        onAuthFailure?()
        return
    }
    session = URLSession(configuration: .default)
    webSocketTask = session?.webSocketTask(with: url)
    webSocketTask?.resume()

    isConnecting = false
    isConnected = true
    reconnectAttempts = 0
    isReconnecting = false
    startPing()
    receiveMessage()
    onConnect?()
}

private func retryConnect() {
    guard let channel = currentChannel else { return }
    connect(channel: channel)
}
```

- [ ] **Step 2:** Update `scheduleReconnect()` to reconnect with the stored channel:

```swift
private func scheduleReconnect() {
    guard KeychainManager.isPaired, !isReconnecting, let channel = currentChannel else { return }
    isReconnecting = true
    reconnectAttempts += 1
    let delay = min(pow(2.0, Double(reconnectAttempts)), maxReconnectDelay)
    Task { [weak self] in
        try? await Task.sleep(for: .seconds(delay))
        guard let self, self.isReconnecting else { return }
        self.isConnected = false
        self.connect(channel: channel)
    }
}
```

- [ ] **Step 3:** Expose a new `onReceiveFailure` closure so the ViewModel can run refetch-and-reconcile. Add near the other callbacks:

```swift
var onReceiveFailure: (() -> Void)?
```

In `receiveMessage()` `case .failure:` branch, after the existing `4001` check, also call the new hook before delegating to reconnect backoff:

```swift
case .failure:
    let closeCode = task.closeCode
    if closeCode.rawValue == 4001 {
        self.onAuthFailure?()
    } else {
        self.onReceiveFailure?()
        self.handleDisconnect()
    }
```

Apply the same to the send-path error handler (`handleDisconnect` call sites inside `send` and `sendWithId`): wrap the existing `handleDisconnect()` call in `self?.onReceiveFailure?(); self?.handleDisconnect()`.

- [ ] **Step 4:** Commit.

```bash
git add Managers/TeamWebSocketManager.swift
git commit -m "feat(team-ws): connect(channel:) parameterized by capability; onReceiveFailure hook"
```

---

## Task 6: TeamViewModel — wire CapabilityManager + banner + reconcile

**Files:**
- Modify: `ViewModels/TeamViewModel.swift`

- [ ] **Step 1:** Add published banner state and weak ref to the manager. Below `weak var speechManager: SpeechManager?`:

```swift
weak var capabilityManager: CapabilityManager?
@Published var disconnectedBanner: String?
```

- [ ] **Step 2:** Change `configure(context:)` to also take a `CapabilityManager`, and wire the new closure. Replace existing signature:

```swift
func configure(context: ModelContext, capabilityManager: CapabilityManager) {
    guard modelContext == nil else { return }
    self.modelContext = context
    self.deviceId = KeychainManager.deviceId ?? ""
    self.capabilityManager = capabilityManager

    ws.onMessage = { [weak self] incoming in
        self?.handleIncoming(incoming)
    }
    ws.onAuthFailure = { [weak self] in
        self?.handleAuthFailure()
    }
    ws.onConnect = { [weak self] in
        self?.onConnected()
    }
    ws.onReceiveFailure = { [weak self] in
        self?.handleReceiveFailure()
    }

    connectIfPossible()
}

func connectIfPossible() {
    guard let channel = capabilityManager?.selectedHive else {
        print("[TeamVM] connectIfPossible: no selectedHive, skipping")
        return
    }
    ws.connect(channel: channel)
}

func retryConnect() {
    disconnectedBanner = nil
    connectIfPossible()
}

private func handleReceiveFailure() {
    guard let manager = capabilityManager else { return }
    let label = manager.selectedHive ?? "hive"
    disconnectedBanner = "\(label) is unavailable — tap to retry."
    Task { [weak self] in
        await manager.refresh()
        await MainActor.run {
            guard let self else { return }
            if let current = manager.selectedHive, manager.hives.contains(current) {
                // still available — keep banner, user can tap retry
            } else {
                // hive vanished — clear selection + banner
                self.disconnectedBanner = nil
                self.ws.disconnect()
            }
        }
    }
}
```

- [ ] **Step 3:** Update all other `ws.connect()` call sites in this file (none exist outside `configure`, but search anyway):

Run: `grep -n "ws.connect" ViewModels/TeamViewModel.swift`
Expected: matches only at the new `connectIfPossible()` site.

- [ ] **Step 4:** Commit.

```bash
git add ViewModels/TeamViewModel.swift
git commit -m "feat(team-vm): wire CapabilityManager, disconnectedBanner, refetch-and-reconcile"
```

---

## Task 7: PairingView — drop capabilities, accept CapabilityManager, refresh on pair

**Files:**
- Modify: `Views/PairingView.swift`

- [ ] **Step 1:** Add a new parameter for `CapabilityManager`:

```swift
struct PairingView: View {
    let onPaired: () -> Void
    let capabilityManager: CapabilityManager
```

- [ ] **Step 2:** In `pair()`, delete the `KeychainManager.capabilities = response.capabilities` line. After the three `KeychainManager.*` assignments and before `onPaired()`, call `await capabilityManager.refresh()`:

```swift
KeychainManager.token = response.token
KeychainManager.deviceId = response.deviceId
KeychainManager.deviceName = response.deviceName

await capabilityManager.refresh()

#if os(iOS)
let generator = UINotificationFeedbackGenerator()
generator.notificationOccurred(.success)
#endif

isLoading = false
onPaired()
```

- [ ] **Step 3:** Commit.

```bash
git add Views/PairingView.swift
git commit -m "feat(pair): take CapabilityManager, refresh before onPaired"
```

---

## Task 8: ContentView — own CapabilityManager, derive tabs from hives.count

**Files:**
- Modify: `Views/ContentView.swift`

- [ ] **Step 1:** Add `@StateObject` and wire into configure/auth callbacks.

Replace the body of `ContentView` with:

```swift
struct ContentView: View {
    @StateObject private var chatViewModel = ChatViewModel()
    @StateObject private var teamViewModel = TeamViewModel()
    @StateObject private var capabilityManager = CapabilityManager()
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var isPaired = KeychainManager.isPaired

    var body: some View {
        Group {
            if isPaired {
                tabView
            } else {
                PairingView(
                    onPaired: {
                        isPaired = true
                        chatViewModel.isAuthenticated = true
                        chatViewModel.configure(context: modelContext)
                        teamViewModel.speechManager = chatViewModel.speechManager
                        teamViewModel.configure(context: modelContext, capabilityManager: capabilityManager)
                    },
                    capabilityManager: capabilityManager
                )
            }
        }
        .onAppear {
            capabilityManager.onAuthFailure = {
                chatViewModel.unpair()
            }
            if isPaired {
                chatViewModel.configure(context: modelContext)
                teamViewModel.speechManager = chatViewModel.speechManager
                teamViewModel.configure(context: modelContext, capabilityManager: capabilityManager)
                Task { await capabilityManager.refresh() }
            }
        }
        .onChange(of: scenePhase) {
            if scenePhase == .active && isPaired {
                chatViewModel.ws.connect()
                Task {
                    await capabilityManager.refresh()
                    teamViewModel.connectIfPossible()
                }
            }
        }
        .onChange(of: chatViewModel.isAuthenticated) {
            if !chatViewModel.isAuthenticated && isPaired {
                isPaired = false
                teamViewModel.disconnect()
            }
        }
        .onChange(of: teamViewModel.isAuthenticated) {
            if !teamViewModel.isAuthenticated && isPaired {
                isPaired = false
                chatViewModel.unpair()
            }
        }
        .task(id: isPaired) {
            guard isPaired else { return }
            await chatViewModel.speechManager.loadModel()
        }
    }

    @ViewBuilder
    private var tabView: some View {
        TabView {
            switch capabilityManager.hives.count {
            case 0:
                Tab("Beekeeper", systemImage: "eyes.inverse") {
                    RootView(viewModel: chatViewModel)
                }
            case 1:
                Tab("Hive", systemImage: "hexagon.fill") {
                    TeamRootView(viewModel: teamViewModel, capabilityManager: capabilityManager)
                }
                Tab("Beekeeper", systemImage: "eyes.inverse") {
                    RootView(viewModel: chatViewModel)
                }
            default:
                Tab("Hives", systemImage: "hexagon.fill") {
                    NavigationStack {
                        HivesGridView(
                            capabilityManager: capabilityManager,
                            teamViewModel: teamViewModel
                        )
                    }
                }
                Tab("Beekeeper", systemImage: "eyes.inverse") {
                    RootView(viewModel: chatViewModel)
                }
            }
        }
    }
}
```

Note: Swift's `TabView` doesn't support a raw `switch` inside its builder. If the build fails on that, fall back to three sibling `if` blocks — same semantics, more verbose:

```swift
TabView {
    if capabilityManager.hives.count >= 1 && capabilityManager.hives.count < 2 {
        Tab("Hive", systemImage: "hexagon.fill") { ... }
    }
    if capabilityManager.hives.count >= 2 {
        Tab("Hives", systemImage: "hexagon.fill") { ... }
    }
    Tab("Beekeeper", systemImage: "eyes.inverse") {
        RootView(viewModel: chatViewModel)
    }
}
```

- [ ] **Step 2:** Commit.

```bash
git add Views/ContentView.swift
git commit -m "feat(content): own CapabilityManager, derive tabs from hives.count"
```

---

## Task 9: TeamRootView — title from selectedHive, banner display

**Files:**
- Modify: `Views/Team/TeamRootView.swift`

- [ ] **Step 1:** Accept `CapabilityManager` as `@ObservedObject`, render banner above the split view, and switch the sidebar title.

```swift
import SwiftUI

struct TeamRootView: View {
    @ObservedObject var viewModel: TeamViewModel
    @ObservedObject var capabilityManager: CapabilityManager
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

    var body: some View {
        VStack(spacing: 0) {
            if let banner = viewModel.disconnectedBanner {
                Button {
                    viewModel.retryConnect()
                } label: {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(banner)
                        Spacer()
                        Text("Retry").bold()
                    }
                    .padding(12)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .background(Color.orange)
                }
                .buttonStyle(.plain)
            }

            NavigationSplitView(columnVisibility: $columnVisibility) {
                TeamSidebarView(viewModel: viewModel)
                    .navigationTitle(capabilityManager.selectedHive ?? "Hive")
                    .toolbar {
                        ToolbarItem(placement: .navigation) {
                            Circle()
                                .fill(viewModel.ws.isConnected ? .green : .red)
                                .frame(width: 8, height: 8)
                        }
                    }
            } detail: {
                if viewModel.activeChannelId != nil {
                    TeamChatView(viewModel: viewModel)
                } else {
                    ContentUnavailableView {
                        Label("Select a conversation", systemImage: "bubble.left.and.bubble.right")
                    } description: {
                        Text("Choose a channel or DM from the sidebar")
                    }
                }
            }
            .navigationSplitViewStyle(.balanced)
        }
    }
}
```

- [ ] **Step 2:** Commit.

```bash
git add Views/Team/TeamRootView.swift
git commit -m "feat(team-root): title from selectedHive; render disconnected banner"
```

---

## Task 10: HivesGridView — new picker

**Files:**
- Create: `Views/Team/HivesGridView.swift`

- [ ] **Step 1:** Create the file.

```swift
import SwiftUI

struct HivesGridView: View {
    @ObservedObject var capabilityManager: CapabilityManager
    @ObservedObject var teamViewModel: TeamViewModel
    @State private var navigateToHive = false

    private let columns = [GridItem(.adaptive(minimum: 140), spacing: 16)]

    var body: some View {
        Group {
            if capabilityManager.hives.isEmpty {
                ContentUnavailableView {
                    Label("No hives available", systemImage: "hexagon")
                } description: {
                    Text("Pull to refresh.")
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(capabilityManager.hives, id: \.self) { hive in
                            Button {
                                capabilityManager.selectedHive = hive
                                teamViewModel.connectIfPossible()
                                navigateToHive = true
                            } label: {
                                HiveCard(name: hive)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle("Hives")
        .refreshable {
            await capabilityManager.refresh()
        }
        .task {
            await capabilityManager.refresh()
            // Restore last selection on cold start.
            if let last = capabilityManager.selectedHive,
               capabilityManager.hives.contains(last) {
                teamViewModel.connectIfPossible()
                navigateToHive = true
            }
        }
        .navigationDestination(isPresented: $navigateToHive) {
            TeamRootView(viewModel: teamViewModel, capabilityManager: capabilityManager)
                .onDisappear {
                    capabilityManager.selectedHive = nil
                    teamViewModel.disconnect()
                }
        }
    }
}

private struct HiveCard: View {
    let name: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "hexagon.fill")
                .font(.system(size: 36))
                .foregroundStyle(Color.accentColor)
            Text(name)
                .font(.headline)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 140)
        .background(Color.secondarySystemFill)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
```

If `Color.secondarySystemFill` isn't already defined as an extension in this repo, fall back to `.background(.regularMaterial)`.

- [ ] **Step 2:** Commit.

```bash
git add Views/Team/HivesGridView.swift
git commit -m "feat(hives): add HivesGridView picker for 2+ hive case"
```

---

## Task 11: Green build

- [ ] **Step 1:** Full build.

Run: `xcodebuild -project Keepur.xcodeproj -scheme Keepur -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -30`
Expected: `** BUILD SUCCEEDED **`. Fix any remaining compile errors before proceeding.

- [ ] **Step 2:** Commit any fixes.

```bash
git add -A
git commit -m "fix: resolve build errors from capability picker wiring"
```

(If the build was already green, skip the commit.)

---

## Task 12: CapabilityManager unit tests

**Files:**
- Create: `KeeperTests/CapabilityManagerTests.swift`

- [ ] **Step 1:** Add tests that exercise the test seam `_setHivesForTesting(_:)` and the persistence path. Since `fetchCapabilities()` is static and network-backed, tests of the live `refresh()` path require URLProtocol stubbing — keep those in the APIManager test file (Task 13). This file focuses on the state-owner behavior.

```swift
import XCTest
@testable import Keepur

@MainActor
final class CapabilityManagerTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "selectedHive")
    }

    func testFilterBeekeeperFromHives() {
        let manager = CapabilityManager()
        manager._setHivesForTesting(["beekeeper", "hive-personal", "hive-work"])
        XCTAssertEqual(manager.hives, ["hive-personal", "hive-work"])
    }

    func testAutoSetSelectedHiveWhenSingle() {
        let manager = CapabilityManager()
        manager._setHivesForTesting(["beekeeper", "hive-personal"])
        XCTAssertEqual(manager.selectedHive, "hive-personal")
    }

    func testDoesNotAutoSetWhenMultiple() {
        let manager = CapabilityManager()
        manager._setHivesForTesting(["hive-a", "hive-b"])
        XCTAssertNil(manager.selectedHive)
    }

    func testReconcileClearsStaleSelection() {
        let manager = CapabilityManager()
        manager.selectedHive = "hive-old"
        manager._setHivesForTesting(["hive-a", "hive-b"])
        XCTAssertNil(manager.selectedHive)
    }

    func testReconcileKeepsValidSelection() {
        let manager = CapabilityManager()
        manager.selectedHive = "hive-a"
        manager._setHivesForTesting(["hive-a", "hive-b"])
        XCTAssertEqual(manager.selectedHive, "hive-a")
    }

    func testSelectedHivePersistsAcrossInstances() {
        let manager1 = CapabilityManager()
        manager1.selectedHive = "hive-persistent"

        let manager2 = CapabilityManager()
        XCTAssertEqual(manager2.selectedHive, "hive-persistent")
    }

    func testClearAllRemovesSelectedHive() {
        let manager = CapabilityManager()
        manager.selectedHive = "hive-x"
        KeychainManager.clearAll()
        XCTAssertNil(manager.selectedHive)
    }

    func testEmptyListClearsSelection() {
        let manager = CapabilityManager()
        manager.selectedHive = "hive-a"
        manager._setHivesForTesting(["beekeeper"])
        XCTAssertNil(manager.selectedHive)
    }
}
```

- [ ] **Step 2:** Run tests.

Run: `xcodebuild test -project Keepur.xcodeproj -scheme Keepur -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:KeeperTests/CapabilityManagerTests 2>&1 | tail -30`
Expected: all 8 tests pass.

- [ ] **Step 3:** Commit.

```bash
git add KeeperTests/CapabilityManagerTests.swift
git commit -m "test(capabilities): CapabilityManager state + persistence + reconcile"
```

---

## Task 13: APIManager.fetchCapabilities tests

**Files:**
- Create: `KeeperTests/APIManagerCapabilitiesTests.swift`

- [ ] **Step 1:** Stub URLProtocol for 200/401/500 paths.

```swift
import XCTest
@testable import Keepur

final class APIManagerCapabilitiesTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        URLProtocolStub.reset()
        URLProtocol.registerClass(URLProtocolStub.self)
        BeekeeperConfig.host = "test.example.com"
        KeychainManager.token = "test-token"
    }

    override func tearDown() async throws {
        URLProtocol.unregisterClass(URLProtocolStub.self)
        URLProtocolStub.reset()
        KeychainManager.token = nil
        BeekeeperConfig.host = nil
        try await super.tearDown()
    }

    func test200ReturnsArrayVerbatim() async throws {
        URLProtocolStub.nextStatusCode = 200
        URLProtocolStub.nextBody = Data(#"{"capabilities":["beekeeper","hive-a","hive-b"]}"#.utf8)
        let result = try await APIManager.fetchCapabilities()
        XCTAssertEqual(result, ["beekeeper", "hive-a", "hive-b"])
    }

    func test401ThrowsUnauthorized() async {
        URLProtocolStub.nextStatusCode = 401
        URLProtocolStub.nextBody = Data()
        do {
            _ = try await APIManager.fetchCapabilities()
            XCTFail("expected unauthorized")
        } catch APIManager.APIError.unauthorized {
            // ok
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func test500ThrowsRequestFailed() async {
        URLProtocolStub.nextStatusCode = 500
        URLProtocolStub.nextBody = Data()
        do {
            _ = try await APIManager.fetchCapabilities()
            XCTFail("expected requestFailed")
        } catch APIManager.APIError.requestFailed {
            // ok
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testMissingTokenThrowsUnauthorized() async {
        KeychainManager.token = nil
        do {
            _ = try await APIManager.fetchCapabilities()
            XCTFail("expected unauthorized")
        } catch APIManager.APIError.unauthorized {
            // ok
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}

// MARK: - URLProtocol stub

final class URLProtocolStub: URLProtocol {
    static var nextStatusCode: Int = 200
    static var nextBody: Data = Data()

    static func reset() {
        nextStatusCode = 200
        nextBody = Data()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.nextStatusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.nextBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
```

**Caveat:** `APIManager.fetchCapabilities()` uses `URLSession.shared`. URLProtocol stubs registered globally will intercept it. If `URLSession.shared` resists registration in your Xcode version (common on recent SDKs), this test file will need `APIManager.fetchCapabilities()` refactored to accept an injected `URLSession` — in which case, add an `internal static var sessionForTesting: URLSession?` override in `APIManager` and use it when non-nil. Only do this refactor if the first test-run can't intercept.

- [ ] **Step 2:** Run tests.

Run: `xcodebuild test -project Keepur.xcodeproj -scheme Keepur -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:KeeperTests/APIManagerCapabilitiesTests 2>&1 | tail -30`
Expected: all 4 tests pass. If URLProtocol doesn't intercept `URLSession.shared`, apply the caveat refactor above before re-running.

- [ ] **Step 3:** Commit.

```bash
git add KeeperTests/APIManagerCapabilitiesTests.swift Managers/APIManager.swift
git commit -m "test(api): fetchCapabilities 200/401/500/missing-token"
```

---

## Task 14: Full test suite + quality gate

- [ ] **Step 1:** Full test run.

Run: `xcodebuild test -project Keepur.xcodeproj -scheme Keepur -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -40`
Expected: all tests pass (existing + new). No red.

- [ ] **Step 2:** Invoke `/quality-gate` — swift compliance → create tests → full suite. Fix any flagged issues.

- [ ] **Step 3:** Invoke `dodi-dev:review` before PR.

---

## Execution Notes

- **Migration:** No data migration. Existing installs already have a paired token; the first `CapabilityManager.refresh()` on cold start reconciles state.
- **Server-first ordering:** Do not merge this PR until the beekeeper KPR-25 PR is deployed to `beekeeper.dodihome.com`. Client-first ordering bricks all existing installs on team WS.
- **2+ hive smoke test** (requires live two-hive deploy, after hive-repo registration-name landings): register two hives, cold-start the app, verify the grid renders, last-selected persists, and `kill -9` of one hive's process surfaces the banner on that tab only.
