# Child A — BeekeeperSocket Implementation Plan

> **For agentic workers:** Use dodi-dev:implement to execute this plan.

**Ticket:** [#90](https://github.com/keepur/keepur-ios/issues/90) (epic #88). **Spec:** `docs/specs/2026-09-04-cleanup-epic-design.md` § Child A.
**Worktree:** `/Users/may/github/keepur/keepur-ios-issue-90`, branch `issue-90`, base `main@bcec8f1`.

**Goal:** Replace `WebSocketManager` and `TeamWebSocketManager` with one `BeekeeperSocket` transport that both view models consume by injection, with observable connection state, a real handshake, Task-based ping, `os.Logger` logging that never includes a token, URL, or frame body, and unit tests driven by a fake socket task.

**Architecture:** `BeekeeperSocket` owns connect/handshake/ping/reconnect/auth-failure and emits raw `Data` frames through a Combine `PassthroughSubject`. Each view model subscribes, decodes with its existing `WSIncoming` / `TeamWSIncoming` enum, and dispatches to its existing `handleIncoming` unchanged. Two small protocols make it testable: `WebSocketTasking` (a fake replaces `URLSessionWebSocketTask`) and `CredentialStore` (a fake replaces the Keychain statics). Behavior outside the transport is unchanged in this child except where the spec says otherwise: the Team layer now reconnects with backoff, and its stale `deviceId` is fixed.

**Tech Stack:** Swift 5 mode, SwiftUI, Combine, `os.Logger`, `URLSessionWebSocketTask`, XCTest. iOS 26.2 / macOS 15 targets; both must keep building.

## Working constraints (read first)

- **No Xcode on the authoring machine.** Nothing compiles locally. Every "Verify" step below means: commit, push, and read the `Tests` workflow result. One run takes 8–10 minutes. Batch work into the four push points marked **PUSH**; do not push per step.
- **Push and `gh` writes use the `may-keepur` account.** Before any push or `gh` write in a shell:
  ```bash
  export GH_TOKEN="$(gh auth token --user may-keepur)"
  ```
  and push with
  ```bash
  git -c credential.helper= -c credential.helper='!f(){ echo "username=may-keepur"; echo "password=$GH_TOKEN"; }; f' push -u origin issue-90
  ```
- **Reading a run:** `gh run list -R keepur/keepur-ios --branch issue-90 --limit 1 --json databaseId --jq '.[0].databaseId'` then `gh run watch <id> -R keepur/keepur-ios --exit-status --interval 20`, then `gh run view <id> -R keepur/keepur-ios --log | perl -pe 's/\^\[\[[0-9;]*m//g' | grep -E 'error:|Executed [0-9]+ tests, with'`. On a red run the "Print failure details" step lists assertion messages; compile errors appear as `error:` lines with file:line.
- Ignore `##[error]` lines that are CoreData/SwiftData stderr from the test host (`Failed to stat path`, `NSPersistentStoreCoordinator`); they appear on green runs too.
- The test count today is **174**. Task 4 adds 10 tests (pushes 1–3 expect `Executed 184 tests, with 0 failures`); Task 8 adds 1 more (push 4 expects **185**).

## Testing Contract

### Required Test Groups

- Unit: `required`
  - Scope: `BeekeeperSocket` state machine (handshake, reconnect backoff, auth-failure close code, send gating, multicast, channel switch, backoff short-circuit, ping loop cancellation, token-read retry); `TeamViewModel.deviceId` following the credential store.
  - Reason: the transport is the foundation for children B–E; its behaviors are otherwise only observable on a live server.
  - Minimum assertions: the ten `BeekeeperSocketTests` cases and one `TeamViewModelTests` case listed in Tasks 4 and 8.

- Integration: `not-required`
  - Scope: n/a
  - Reason: see Non-Required Rationale.
  - Harness: `not-applicable`
  - Minimum assertions: none

- E2E: `not-required`
  - Scope: n/a
  - Reason: see Non-Required Rationale.
  - Harness: `not-applicable`
  - Minimum assertions: none

### Critical Flows

- Cold start: `configure` → `connect(channel: "beekeeper")` → handshake → `onConnected` → `list_sessions` sent → frames decoded and dispatched to `ChatViewModel.handleIncoming`.
- Team: `connectIfPossible` → `connect(channel: <hive>)` → handshake → `onConnected` → existing `onConnected()` fetches channels/agents/commands.
- Connection loss: receive failure → `.reconnecting(attempt: 1)` → Team layer refreshes capabilities and either keeps backing off or disconnects if the hive vanished; Beekeeper layer just backs off. Foregrounding the app calls `reconnect()`, which attempts immediately during backoff.
- Auth failure: close code 4001 → `onAuthFailure` → existing unpair / `isAuthenticated = false` paths; no reconnect.

### Regression Surface

- Every send site in both view models (listed in Tasks 5 and 6) must send the same frames as before; `WSOutgoing` / `TeamWSOutgoing` encoders are untouched.
- Team `sendWithId` request-id correlation (`pendingMessageIds`, `pendingCommandChannels`, `pendingNewCommands`, `pendingDMRequestId`) must keep working.
- Views that read `viewModel.ws.isConnected` compile against `viewModel.socket.isConnected` (still not observed correctly; that is child B).
- `ConciergeViewModel` in `BeekeeperRootView` keeps working through `viewModel.send(_:)`.
- macOS target builds (no `#if os(iOS)` code is touched, but the scheme builds both).
- Existing 174 tests stay green; `TeamSortedAgentsTests` constructs `TeamViewModel()` with defaults and must still work without touching the Keychain (defaults construct a `KeychainCredentialStore`, which is lazy: nothing is read until `connect`).

### Commands

- Unit: push, then `gh run watch <id> -R keepur/keepur-ios --exit-status` (the `Tests` workflow runs `xcodebuild test -scheme Keepur -only-testing:KeeperTests` on an iPhone simulator)
- Integration: `not-applicable`
- E2E: `not-applicable`
- Broader regression: same workflow; the full suite is the regression run. Plus `grep -rn 'print(' Managers ViewModels` must print nothing after Task 7, and `grep -rn 'WebSocketManager' --include='*.swift' .` must print nothing.

### Harness Requirements

- GitHub Actions `Tests` workflow (exists since #89). `may-keepur` credentials for pushing. No local tooling.
- In-memory `ModelContainer` for `TeamViewModelTests` (pattern already in `KeeperTests/TeamSortedAgentsTests.swift`).

### Non-Required Rationale

- Integration: the only integration boundary is the live Beekeeper server, which has no test instance; the fake `WebSocketTasking` covers the socket's contract, and frame encode/decode already has 60+ unit tests.
- E2E: no UI-test target exists and the ticket changes no screens.

### Verification Rules

- Missing harness is not a skip reason; set it up or report a concrete blocker.
- If a test failure exposes an implementation issue, fix the implementation, not the test.
- If testing exposes a spec or plan mismatch, demote the ticket to the spec lane.

---

## File map

| Action | Path | Responsibility |
|---|---|---|
| Create | `Managers/Log.swift` | `os.Logger` instances by category |
| Create | `Managers/CredentialStore.swift` | `CredentialStore` protocol + `KeychainCredentialStore` forwarding to `KeychainManager` |
| Create | `Managers/WebSocketTasking.swift` | `WebSocketTasking` protocol + `URLSessionWebSocketTaskAdapter` (owns the `URLSession`) |
| Create | `Managers/BeekeeperSocket.swift` | The transport |
| Delete | `Managers/WebSocketManager.swift` | replaced |
| Delete | `Managers/TeamWebSocketManager.swift` | replaced |
| Modify | `ViewModels/ChatViewModel.swift` | inject socket + credentials; subscribe; `send`, `reconnect`, `disconnect` |
| Modify | `ViewModels/TeamViewModel.swift` | inject; subscribe; state observer replaces `onReceiveFailure`; computed `deviceId`; `send`/`sendWithId` helpers |
| Modify | `Managers/CapabilityManager.swift:49` | `print` → `Log.capabilities` |
| Modify | `Views/ContentView.swift:45`, `Views/SettingsView.swift:100-103,187-191`, `Views/WorkspacePickerView.swift:40,48`, `Views/SessionListView.swift:95`, `Views/Team/TeamRootView.swift:42`, `Views/BeekeeperRootView.swift:105,117,119,128` | call the new view-model surface |
| Create | `KeeperTests/FakeWebSocketTask.swift` | test double for `WebSocketTasking` + factory |
| Create | `KeeperTests/FakeCredentialStore.swift` | in-memory `CredentialStore` |
| Create | `KeeperTests/BeekeeperSocketTests.swift` | 10 tests |
| Create | `KeeperTests/TeamViewModelTests.swift` | 1 test (more land in child E) |

`KeeperTests/` is a synchronized group (#98): new test files need no project-file edit. `Managers/` is a synchronized group too, so the new and deleted manager files need no project-file edit either.

**Two deliberate deviations from the spec text:**
1. The spec says `BeekeeperRootView`'s four `viewModel.ws.send` calls "stay until C". Renaming `ws` → `socket` and changing `send` to take `Data` means they cannot stay verbatim, so they become `viewModel.send(_:)` (a new internal `ChatViewModel` method that encodes and forwards). Child C still replaces them with named methods and makes `socket` private, as the spec says.
2. `Config.maxReconnectDelay` is a `TimeInterval` (the spec sketch says `Duration`) because it feeds `min(pow(2, n), cap)`; `pingInterval` and `tokenReadRetryDelay` stay `Duration` because they feed `Task.sleep(for:)`.

**Build settings to know about (CI is the only compiler, so these matter):**
- `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY` is on: any file that calls `Log.x.info(...)` must itself `import os`. The plan adds that import to `BeekeeperSocket.swift`, `ChatViewModel.swift`, `TeamViewModel.swift`, and `CapabilityManager.swift`.
- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` is on: every new type without an explicit isolation (`WebSocketTasking`, `CredentialStore`, `Log`, the adapter) is MainActor-isolated by default. Consequences the plan already accounts for: the socket's default `taskFactory` is written as a closure, not a bare reference to an isolated static; `frameType` is computed into a local before the `Logger` interpolation rather than inside its autoclosure; the test target has **no** default isolation, so the fakes are explicitly `@MainActor` (a conformer to a MainActor protocol inherits it anyway, but the factory that constructs one does not), and the factory is always passed as a closure literal; both test classes are `@MainActor`, which is what makes `State: Equatable` usable in `XCTAssertEqual` (with `InferIsolatedConformances`, that conformance is MainActor-isolated).

---

### Task 1: Logging, credential store, socket-task protocol

**Files:**
- Create: `Managers/Log.swift`
- Create: `Managers/CredentialStore.swift`
- Create: `Managers/WebSocketTasking.swift`

- [ ] **Step 1:** Create `Managers/Log.swift`

```swift
import os

/// One `Logger` per subsystem area. Never log a URL, a token, or a frame body:
/// the socket logs frame *types* only, at debug level.
enum Log {
    private static let subsystem = "io.keepur"

    static let socket       = Logger(subsystem: subsystem, category: "socket")
    static let chat         = Logger(subsystem: subsystem, category: "chat")
    static let team         = Logger(subsystem: subsystem, category: "team")
    static let capabilities = Logger(subsystem: subsystem, category: "capabilities")
    static let persistence  = Logger(subsystem: subsystem, category: "persistence")
}
```

- [ ] **Step 2:** Create `Managers/CredentialStore.swift`

```swift
import Foundation

/// Abstracts `KeychainManager`'s statics so the socket and the view models can be
/// tested with an in-memory store. Reference type on purpose: one instance is
/// shared between a socket and the view model that owns it.
protocol CredentialStore: AnyObject {
    var token: String? { get set }
    var deviceId: String? { get set }
    var deviceName: String? { get set }
    var isPaired: Bool { get }
    func clearAll()
}

/// Production store. Stateless; every access hits the Keychain through `KeychainManager`.
final class KeychainCredentialStore: CredentialStore {
    init() {}

    var token: String? {
        get { KeychainManager.token }
        set { KeychainManager.token = newValue }
    }

    var deviceId: String? {
        get { KeychainManager.deviceId }
        set { KeychainManager.deviceId = newValue }
    }

    var deviceName: String? {
        get { KeychainManager.deviceName }
        set { KeychainManager.deviceName = newValue }
    }

    var isPaired: Bool { KeychainManager.isPaired }

    func clearAll() { KeychainManager.clearAll() }
}
```

- [ ] **Step 3:** Create `Managers/WebSocketTasking.swift`

```swift
import Foundation

/// The slice of `URLSessionWebSocketTask` that `BeekeeperSocket` uses, so tests can
/// drive the socket with a fake. Signatures match the real task exactly.
protocol WebSocketTasking: AnyObject {
    var closeCode: URLSessionWebSocketTask.CloseCode { get }
    func resume()
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
    func send(_ message: URLSessionWebSocketTask.Message,
              completionHandler: @escaping @Sendable (Error?) -> Void)
    func receive(completionHandler: @escaping @Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void)
    func sendPing(pongReceiveHandler: @escaping @Sendable (Error?) -> Void)
}

/// Production adapter. Owns the `URLSession` as well as the task so that
/// `cancel` can also invalidate the session (the old managers did both).
final class URLSessionWebSocketTaskAdapter: WebSocketTasking {
    private let session: URLSession
    private let task: URLSessionWebSocketTask

    init(url: URL) {
        session = URLSession(configuration: .default)
        task = session.webSocketTask(with: url)
    }

    /// Factory in the shape `BeekeeperSocket.init` expects.
    static func make(url: URL) -> WebSocketTasking {
        URLSessionWebSocketTaskAdapter(url: url)
    }

    var closeCode: URLSessionWebSocketTask.CloseCode { task.closeCode }

    func resume() { task.resume() }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        task.cancel(with: closeCode, reason: reason)
        session.invalidateAndCancel()
    }

    func send(_ message: URLSessionWebSocketTask.Message,
              completionHandler: @escaping @Sendable (Error?) -> Void) {
        task.send(message, completionHandler: completionHandler)
    }

    func receive(completionHandler: @escaping @Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void) {
        task.receive(completionHandler: completionHandler)
    }

    func sendPing(pongReceiveHandler: @escaping @Sendable (Error?) -> Void) {
        task.sendPing(pongReceiveHandler: pongReceiveHandler)
    }
}
```

- [ ] **Step 4:** Commit (no push yet)

```bash
git add Managers/Log.swift Managers/CredentialStore.swift Managers/WebSocketTasking.swift
git commit -m "feat(#90): Log, CredentialStore, WebSocketTasking seams for the unified socket"
```

---

### Task 2: `BeekeeperSocket`

**Files:**
- Create: `Managers/BeekeeperSocket.swift`

- [ ] **Step 1:** Create the file with this exact content

```swift
import Foundation
import Combine
import os   // required: the app target enables MemberImportVisibility, so every file that calls Logger methods must import os itself

/// One WebSocket transport for both the Beekeeper and Team ("Hive") layers.
///
/// - Emits raw `Data` frames on `frames`; callers decode with their own enum.
/// - Reports connected only after a protocol-level ping round-trips (the old
///   Beekeeper manager reported connected the moment the task resumed).
/// - Reconnects with exponential backoff (2^n s, capped) on any non-auth failure;
///   close code 4001 means the token is bad and routes to `onAuthFailure` instead.
/// - Keep-alive is the app-level `{"type":"ping"}` frame both servers expect,
///   sent from a `Task` loop (not a run-loop `Timer`, which stalls during scrolls).
/// - Never logs a URL, a token, or a frame body.
@MainActor
final class BeekeeperSocket: ObservableObject {

    enum State: Equatable {
        case disconnected
        case connecting
        case connected
        case reconnecting(attempt: Int)
    }

    struct Config {
        /// Sent every `pingInterval` while connected, and once right after the handshake.
        var keepAliveFrame: Data
        var pingInterval: Duration = .seconds(30)
        var maxReconnectDelay: TimeInterval = 30
        var tokenReadRetryDelay: Duration = .seconds(2)
        var maxTokenReadRetries: Int = 3

        /// Both servers expect the same bare frame (`WSOutgoing.ping` and
        /// `TeamWSOutgoing.ping` encode identically).
        static let standard = Config(keepAliveFrame: Data(#"{"type":"ping"}"#.utf8))
    }

    // MARK: - Public surface

    @Published private(set) var state: State = .disconnected
    var isConnected: Bool { state == .connected }

    /// Multicast: every subscriber gets every frame received after it subscribes.
    let frames = PassthroughSubject<Data, Never>()

    var onAuthFailure: (() -> Void)?
    var onConnected: (() -> Void)?

    /// Channel of the last `connect(channel:)`; `reconnect()` reuses it.
    private(set) var lastChannel: String?

    // MARK: - Dependencies

    private let config: Config
    private let credentials: CredentialStore
    private let endpoint: () throws -> URL
    private let taskFactory: (URL) -> WebSocketTasking

    // MARK: - Connection state

    private var task: WebSocketTasking?
    private var pingTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var tokenRetryTask: Task<Void, Never>?
    private var reconnectAttempts = 0
    private var tokenReadRetries = 0
    /// Bumped on every teardown; callbacks from an older task compare against it
    /// and drop themselves, so a cancelled task can never flip state.
    private var generation = 0

    init(
        config: Config = .standard,
        credentials: CredentialStore = KeychainCredentialStore(),
        endpoint: @escaping () throws -> URL = { try BeekeeperConfig.wssURL() },
        taskFactory: @escaping (URL) -> WebSocketTasking = { URLSessionWebSocketTaskAdapter.make(url: $0) }
    ) {
        self.config = config
        self.credentials = credentials
        self.endpoint = endpoint
        self.taskFactory = taskFactory
    }

    // MARK: - Connect / disconnect

    /// Semantics by current state (spec § Child A):
    /// - disconnected: connect.
    /// - connecting / connected, same channel: no-op; different channel: tear down, then connect.
    /// - reconnecting (in backoff), same channel: cancel the sleep and attempt now, keeping the
    ///   attempt count; different channel: cancel backoff, tear down, connect with a fresh count.
    func connect(channel: String) {
        // Same-channel no-ops apply only when nothing is pending. A pending token-read
        // retry (`tokenRetryTask != nil`) means no task is open yet, so a same-channel
        // connect must fall through and attempt now rather than return.
        switch state {
        case .connecting, .connected:
            if channel == lastChannel, tokenRetryTask == nil { return }
            if channel != lastChannel {
                Log.socket.info("switching channel; tearing down current connection")
                teardown()
            }
        case .reconnecting:
            // `reconnectTask == nil` while in .reconnecting means the backoff sleep already
            // ended and a retry handshake is in flight; a same-channel connect must not open
            // a second task on top of it (the old managers' `isConnecting` guard).
            if reconnectTask == nil, tokenRetryTask == nil, channel == lastChannel { return }
            reconnectTask?.cancel()
            reconnectTask = nil
            if channel != lastChannel {
                reconnectAttempts = 0
                teardown()
            }
        case .disconnected:
            break
        }
        tokenRetryTask?.cancel()
        tokenRetryTask = nil
        lastChannel = channel
        open(channel: channel)
    }

    /// `connect(channel:)` with the last channel. No-op if never connected.
    func reconnect() {
        guard let channel = lastChannel else { return }
        connect(channel: channel)
    }

    func disconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        tokenRetryTask?.cancel()
        tokenRetryTask = nil
        reconnectAttempts = 0
        tokenReadRetries = 0
        teardown()
        setState(.disconnected)
    }

    // MARK: - Send

    /// Returns `false` when not connected. The caller decides what to queue (child B).
    @discardableResult
    func send(_ frame: Data) -> Bool {
        guard state == .connected, let task else { return false }
        let type = Self.frameType(frame)   // computed outside the Logger autoclosure (isolation)
        Log.socket.debug("send type=\(type, privacy: .public)")
        let gen = generation
        task.send(.string(String(decoding: frame, as: UTF8.self))) { [weak self] error in
            guard error != nil else { return }
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                Log.socket.error("send failed; reconnecting")
                self.handleDisconnect()
            }
        }
        return true
    }

    // MARK: - Private: open + handshake

    private func open(channel: String) {
        // Reflect "an attempt is under way" before the token read, so a transient
        // Keychain failure never leaves a stale .connected/.disconnected on show.
        if reconnectAttempts == 0 { setState(.connecting) }
        guard let token = credentials.token else {
            if tokenReadRetries < config.maxTokenReadRetries {
                tokenReadRetries += 1
                Log.socket.notice("token unreadable; retry \(self.tokenReadRetries, privacy: .public)")
                let delay = config.tokenReadRetryDelay
                tokenRetryTask = Task { [weak self] in
                    try? await Task.sleep(for: delay)
                    guard !Task.isCancelled, let self else { return }
                    self.tokenRetryTask = nil
                    self.open(channel: channel)
                }
            } else {
                tokenReadRetries = 0
                Log.socket.error("token unreadable after retries")
                handleDisconnect()
            }
            return
        }
        tokenReadRetries = 0

        guard let base = try? endpoint(),
              let url = URL(string: "\(base.absoluteString)?token=\(token)&channel=\(channel)") else {
            Log.socket.error("host not configured; routing to auth gate")
            reconnectAttempts = 0
            setState(.disconnected)
            onAuthFailure?()
            return
        }

        generation += 1
        let gen = generation
        let newTask = taskFactory(url)
        task = newTask
        Log.socket.info("connecting channel=\(channel, privacy: .public) attempt=\(self.reconnectAttempts, privacy: .public)")
        newTask.resume()
        newTask.sendPing { [weak self] error in
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                if let error {
                    Log.socket.error("handshake failed: \(error.localizedDescription, privacy: .public)")
                    self.handleDisconnect()
                    return
                }
                Log.socket.info("connected channel=\(channel, privacy: .public)")
                self.reconnectAttempts = 0
                self.setState(.connected)
                self.startPing()
                self.receive()
                // Spec order: keep-alive once, then the layer's onConnected work (e.g. list_sessions).
                self.send(self.config.keepAliveFrame)
                self.onConnected?()
            }
        }
    }

    // MARK: - Private: receive loop

    private func receive() {
        guard let task else { return }
        let gen = generation
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                switch result {
                case .success(let message):
                    let data: Data?
                    switch message {
                    case .string(let text): data = Data(text.utf8)
                    case .data(let d): data = d
                    @unknown default: data = nil
                    }
                    if let data {
                        let type = Self.frameType(data)
                        Log.socket.debug("recv type=\(type, privacy: .public)")
                        self.frames.send(data)
                    }
                    // A subscriber may have called disconnect()/connect(other) synchronously
                    // while handling that frame; only re-arm receive on the same generation.
                    guard gen == self.generation else { return }
                    self.receive()
                case .failure:
                    if task.closeCode.rawValue == 4001 {
                        Log.socket.notice("close code 4001; auth failure")
                        self.teardown()
                        self.reconnectAttempts = 0
                        self.setState(.disconnected)
                        self.onAuthFailure?()
                    } else {
                        Log.socket.notice("receive failed; reconnecting")
                        self.handleDisconnect()
                    }
                }
            }
        }
    }

    // MARK: - Private: failure + reconnect

    private func handleDisconnect() {
        teardown()
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard credentials.isPaired, let channel = lastChannel else {
            setState(.disconnected)
            return
        }
        reconnectAttempts += 1
        let attempt = reconnectAttempts
        setState(.reconnecting(attempt: attempt))
        let delay = min(pow(2.0, Double(attempt)), config.maxReconnectDelay)
        Log.socket.info("reconnect attempt=\(attempt, privacy: .public) in \(delay, privacy: .public)s")
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.reconnectTask = nil
            self.open(channel: channel)
        }
    }

    /// Cancels the task and the ping loop and invalidates their callbacks. Does not
    /// touch `state`; callers set it.
    private func teardown() {
        generation += 1
        pingTask?.cancel()
        pingTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    // MARK: - Private: keep-alive

    private func startPing() {
        pingTask?.cancel()
        let interval = config.pingInterval
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                self.send(self.config.keepAliveFrame)
            }
        }
    }

    // MARK: - Private: helpers

    private func setState(_ new: State) {
        if state != new { state = new }
    }

    /// The frame's `type` field, for logs. Never the body.
    private static func frameType(_ data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return "?" }
        return type
    }
}
```

- [ ] **Step 2:** Commit (no push yet)

```bash
git add Managers/BeekeeperSocket.swift
git commit -m "feat(#90): BeekeeperSocket — unified transport with handshake, Task ping, backoff, multicast frames"
```

---

### Task 3: Test doubles

**Files:**
- Create: `KeeperTests/FakeWebSocketTask.swift`
- Create: `KeeperTests/FakeCredentialStore.swift`

- [ ] **Step 1:** Create `KeeperTests/FakeWebSocketTask.swift`

```swift
import Foundation
@testable import Keepur

/// Records what the socket asks of it and lets a test drive the handshake and
/// the receive loop by hand. `WebSocketTasking` is declared in the app target,
/// whose default actor isolation is MainActor, so the protocol is @MainActor and
/// a conformer inherits that; the annotation here is explicit for clarity.
/// The test target has no default isolation, so anything that constructs a fake
/// must itself be @MainActor (the factory below, and the test classes).
@MainActor
final class FakeWebSocketTask: WebSocketTasking {
    let url: URL
    var closeCode: URLSessionWebSocketTask.CloseCode = .invalid
    private(set) var resumed = false
    private(set) var cancelled = false
    private(set) var sentTexts: [String] = []
    private var pingHandler: (@Sendable (Error?) -> Void)?
    private var receiveHandler: (@Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void)?

    init(url: URL) { self.url = url }

    // MARK: WebSocketTasking

    func resume() { resumed = true }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        cancelled = true
    }

    func send(_ message: URLSessionWebSocketTask.Message,
              completionHandler: @escaping @Sendable (Error?) -> Void) {
        if case .string(let text) = message { sentTexts.append(text) }
        completionHandler(nil)
    }

    func receive(completionHandler: @escaping @Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void) {
        receiveHandler = completionHandler
    }

    func sendPing(pongReceiveHandler: @escaping @Sendable (Error?) -> Void) {
        pingHandler = pongReceiveHandler
    }

    // MARK: Test controls

    var handshakeRequested: Bool { pingHandler != nil }

    func completeHandshake(error: Error? = nil) {
        let handler = pingHandler
        pingHandler = nil
        handler?(error)
    }

    func deliver(_ text: String) {
        let handler = receiveHandler
        receiveHandler = nil
        handler?(.success(.string(text)))
    }

    func failReceive(closeCode: URLSessionWebSocketTask.CloseCode) {
        self.closeCode = closeCode
        let handler = receiveHandler
        receiveHandler = nil
        handler?(.failure(URLError(.networkConnectionLost)))
    }
}

/// Creates a fresh fake per `connect` and keeps them all, so tests can inspect
/// the old one after a channel switch. @MainActor because it constructs a
/// MainActor-isolated fake. Pass it to the socket as a closure literal,
/// `{ factory.make(url: $0) }`, never as the bare `factory.make` reference
/// (converting an isolated method reference to the socket's closure type is an error).
@MainActor
final class FakeWebSocketTaskFactory {
    private(set) var made: [FakeWebSocketTask] = []

    func make(url: URL) -> WebSocketTasking {
        let task = FakeWebSocketTask(url: url)
        made.append(task)
        return task
    }

    var latest: FakeWebSocketTask? { made.last }
}
```

- [ ] **Step 2:** Create `KeeperTests/FakeCredentialStore.swift`

```swift
import Foundation
@testable import Keepur

/// `CredentialStore` is @MainActor (app-target default isolation); the conformer
/// inherits it. Only constructed from @MainActor test classes.
@MainActor
final class FakeCredentialStore: CredentialStore {
    var token: String?
    var deviceId: String?
    var deviceName: String?
    private(set) var clearAllCalls = 0

    init(token: String? = "test-token", deviceId: String? = "device-1", deviceName: String? = "Test Device") {
        self.token = token
        self.deviceId = deviceId
        self.deviceName = deviceName
    }

    var isPaired: Bool { token != nil }

    func clearAll() {
        clearAllCalls += 1
        token = nil
        deviceId = nil
        deviceName = nil
    }
}
```

- [ ] **Step 3:** Commit (no push yet)

```bash
git add KeeperTests/FakeWebSocketTask.swift KeeperTests/FakeCredentialStore.swift
git commit -m "test(#90): fakes for WebSocketTasking and CredentialStore"
```

---

### Task 4: `BeekeeperSocketTests` — **PUSH 1**

**Files:**
- Create: `KeeperTests/BeekeeperSocketTests.swift`

The socket's callbacks hop to the main actor through `Task { @MainActor in … }`, so after driving a fake the test must let those tasks run. `settle()` below yields a few times; every assertion after a fake action is preceded by it.

- [ ] **Step 1:** Create the file

```swift
import XCTest
import Combine
@testable import Keepur

@MainActor
final class BeekeeperSocketTests: XCTestCase {
    private var factory: FakeWebSocketTaskFactory!
    private var credentials: FakeCredentialStore!
    private var cancellables: Set<AnyCancellable>!

    override func setUp() async throws {
        factory = FakeWebSocketTaskFactory()
        credentials = FakeCredentialStore()
        cancellables = []
    }

    override func tearDown() async throws {
        cancellables = nil
        credentials = nil
        factory = nil
    }

    // MARK: - Helpers

    private func makeSocket(
        pingInterval: Duration = .seconds(30),
        tokenReadRetryDelay: Duration = .seconds(2),
        maxTokenReadRetries: Int = 3
    ) -> BeekeeperSocket {
        var config = BeekeeperSocket.Config.standard
        config.pingInterval = pingInterval
        config.tokenReadRetryDelay = tokenReadRetryDelay
        config.maxTokenReadRetries = maxTokenReadRetries
        let factory = self.factory!
        return BeekeeperSocket(
            config: config,
            credentials: credentials,
            endpoint: { URL(string: "wss://unit.test")! },
            taskFactory: { factory.make(url: $0) }   // closure literal, not `factory.make`
        )
    }

    /// Let the socket's `Task { @MainActor in … }` hops run.
    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
    }

    private func connectAndHandshake(_ socket: BeekeeperSocket, channel: String = "beekeeper") async -> FakeWebSocketTask {
        socket.connect(channel: channel)
        let task = try! XCTUnwrap(factory.latest)
        task.completeHandshake()
        await settle()
        return task
    }

    // MARK: - Tests

    func testHandshakeSuccessReachesConnectedAndFiresOnConnected() async throws {
        let socket = makeSocket()
        var connectedCalls = 0
        socket.onConnected = { connectedCalls += 1 }

        socket.connect(channel: "beekeeper")
        XCTAssertEqual(socket.state, .connecting)
        let task = try XCTUnwrap(factory.latest)
        XCTAssertTrue(task.resumed)
        XCTAssertTrue(task.handshakeRequested)
        XCTAssertTrue(task.url.absoluteString.hasSuffix("?token=test-token&channel=beekeeper"))
        XCTAssertFalse(socket.isConnected)

        task.completeHandshake()
        await settle()

        XCTAssertEqual(socket.state, .connected)
        XCTAssertEqual(connectedCalls, 1)
        XCTAssertEqual(task.sentTexts, [#"{"type":"ping"}"#], "keep-alive sent once right after the handshake")
    }

    func testHandshakeFailureSchedulesReconnectAttemptOne() async throws {
        let socket = makeSocket()
        socket.connect(channel: "beekeeper")
        let task = try XCTUnwrap(factory.latest)

        task.completeHandshake(error: URLError(.cannotConnectToHost))
        await settle()

        XCTAssertEqual(socket.state, .reconnecting(attempt: 1))
        XCTAssertTrue(task.cancelled)
        XCTAssertEqual(factory.made.count, 1, "backoff is 2 s; no second task yet")
    }

    func testCloseCode4001FiresAuthFailureAndDoesNotReconnect() async throws {
        let socket = makeSocket()
        var authFailures = 0
        socket.onAuthFailure = { authFailures += 1 }
        let task = await connectAndHandshake(socket)

        task.failReceive(closeCode: URLSessionWebSocketTask.CloseCode(rawValue: 4001)!)
        await settle()

        XCTAssertEqual(authFailures, 1)
        XCTAssertEqual(socket.state, .disconnected)
        XCTAssertEqual(factory.made.count, 1)
    }

    func testSendReturnsFalseWhileNotConnected() async throws {
        let socket = makeSocket()
        XCTAssertFalse(socket.send(Data("{}".utf8)))

        socket.connect(channel: "beekeeper")
        XCTAssertFalse(socket.send(Data("{}".utf8)), "still handshaking")

        let task = try XCTUnwrap(factory.latest)
        task.completeHandshake()
        await settle()
        XCTAssertTrue(socket.send(Data(#"{"type":"list_sessions"}"#.utf8)))
        XCTAssertEqual(task.sentTexts.last, #"{"type":"list_sessions"}"#)
    }

    func testFramesAreMulticastToEverySubscriber() async throws {
        let socket = makeSocket()
        var first: [String] = []
        var second: [String] = []
        socket.frames.sink { first.append(String(decoding: $0, as: UTF8.self)) }.store(in: &cancellables)
        socket.frames.sink { second.append(String(decoding: $0, as: UTF8.self)) }.store(in: &cancellables)
        let task = await connectAndHandshake(socket)

        task.deliver(#"{"type":"pong"}"#)
        await settle()

        XCTAssertEqual(first, [#"{"type":"pong"}"#])
        XCTAssertEqual(second, [#"{"type":"pong"}"#])
    }

    func testConnectToDifferentChannelTearsDownAndReconnects() async throws {
        let socket = makeSocket()
        let old = await connectAndHandshake(socket, channel: "hive-a")

        socket.connect(channel: "hive-b")

        XCTAssertTrue(old.cancelled)
        XCTAssertEqual(factory.made.count, 2)
        XCTAssertTrue(try XCTUnwrap(factory.latest).url.absoluteString.hasSuffix("&channel=hive-b"))
        XCTAssertEqual(socket.state, .connecting)
        XCTAssertEqual(socket.lastChannel, "hive-b")
    }

    func testConnectSameChannelWhileConnectedIsNoOp() async throws {
        let socket = makeSocket()
        let task = await connectAndHandshake(socket)

        socket.connect(channel: "beekeeper")

        XCTAssertFalse(task.cancelled)
        XCTAssertEqual(factory.made.count, 1)
        XCTAssertEqual(socket.state, .connected)
    }

    func testConnectSameChannelDuringBackoffAttemptsImmediately() async throws {
        let socket = makeSocket()
        socket.connect(channel: "beekeeper")
        try XCTUnwrap(factory.latest).completeHandshake(error: URLError(.cannotConnectToHost))
        await settle()
        XCTAssertEqual(socket.state, .reconnecting(attempt: 1))

        socket.connect(channel: "beekeeper")   // what foregrounding does via reconnect()

        XCTAssertEqual(factory.made.count, 2, "no 2 s wait")
        XCTAssertEqual(socket.state, .reconnecting(attempt: 1), "attempt count is kept while the retry is in flight")
        try XCTUnwrap(factory.latest).completeHandshake()
        await settle()
        XCTAssertEqual(socket.state, .connected)
    }

    func testPingLoopStopsAfterDisconnect() async throws {
        let socket = makeSocket(pingInterval: .milliseconds(20))
        let task = await connectAndHandshake(socket)

        try await Task.sleep(for: .milliseconds(200))
        let sentWhileConnected = task.sentTexts.count
        XCTAssertGreaterThanOrEqual(sentWhileConnected, 3, "handshake keep-alive plus at least two loop pings")

        socket.disconnect()
        XCTAssertEqual(socket.state, .disconnected)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(task.sentTexts.count, sentWhileConnected, "no pings after disconnect")
    }

    func testMissingTokenRetriesThenGivesUp() async throws {
        credentials.token = nil
        let socket = makeSocket(tokenReadRetryDelay: .milliseconds(10), maxTokenReadRetries: 2)

        socket.connect(channel: "beekeeper")
        try await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(factory.made.count, 0, "never opened a task without a token")
        XCTAssertEqual(socket.state, .disconnected, "not paired, so no backoff either")
    }
}
```

- [ ] **Step 2:** Commit and **PUSH 1**

```bash
git add KeeperTests/BeekeeperSocketTests.swift
git commit -m "test(#90): BeekeeperSocket state-machine tests against the fake task"
export GH_TOKEN="$(gh auth token --user may-keepur)"
git -c credential.helper= -c credential.helper='!f(){ echo "username=may-keepur"; echo "password=$GH_TOKEN"; }; f' push -u origin issue-90
```

- [ ] **Step 3:** Open a draft PR so the workflow runs on `pull_request` (shell state does not persist between blocks; export again)

```bash
export GH_TOKEN="$(gh auth token --user may-keepur)"
gh pr create -R keepur/keepur-ios --draft --base main --head issue-90 \
  --title "feat: BeekeeperSocket — one transport for both layers (#90)" \
  --body "Closes #90. Child A of epic #88. Spec: docs/specs/2026-09-04-cleanup-epic-design.md § Child A. Plan: docs/plans/2026-09-05-child-a-beekeeper-socket.md. Draft until all four push points are green."
```

- [ ] **Step 4:** Verify

Run: the `gh run list` / `gh run watch` / `gh run view --log` sequence from "Working constraints".
Expected: `Executed 184 tests, with 0 failures`. Ten new tests, all in `BeekeeperSocketTests`. The old managers still exist at this point, so nothing else changed.

If a compile error appears in `BeekeeperSocket.swift` or the tests, fix it, amend into the last commit, push, and re-run before continuing. The errors this plan has already been reviewed against are all actor-isolation ones (see "Build settings to know about"); read the `error:` line, apply the smallest isolation fix, and do not remove `@MainActor` from the fakes. `URLSessionWebSocketTask.CloseCode(rawValue: 4001)` is a failable init; the `!` in the test is intentional.

---

### Task 5: `ChatViewModel` adopts the socket; Beekeeper view sites

**Files:**
- Modify: `ViewModels/ChatViewModel.swift`
- Modify: `Views/BeekeeperRootView.swift:105,117,119,128`
- Modify: `Views/ContentView.swift:45`
- Modify: `Views/SettingsView.swift:100-103,187-191`
- Modify: `Views/WorkspacePickerView.swift:40,48`
- Modify: `Views/SessionListView.swift:95`

- [ ] **Step 0:** At the top of `ViewModels/ChatViewModel.swift`, after `import Combine`, add:

```swift
import os
```

- [ ] **Step 1:** In `ViewModels/ChatViewModel.swift`, replace the property block and `configure` (lines 32–69 today) with:

```swift
    static let channel = "beekeeper"

    let socket: BeekeeperSocket
    let speechManager = SpeechManager()
    private let credentials: CredentialStore
    private var frameSubscription: AnyCancellable?
    var autoReadAloud = false
    private var modelContext: ModelContext?
    private var streamingMessageIds: [String: String] = [:]
    private var lastCompletedMessageIds: [String: String] = [:]
    private var pendingMessages: [(text: String, messageId: String, sessionId: String, attachment: AttachmentData?)] = []
    private static let staleBusyTimeout: TimeInterval = 90
    private var busyTimers: [String: Task<Void, Never>] = [:]
    /// Pending `/clear` handoffs, keyed by workspace path. Populated when
    /// `context_cleared` arrives; consumed by the follow-up `session_info` for the
    /// same path which performs the atomic old→new swap (see HIVE-113).
    private struct ClearHandoff {
        let oldSessionId: String
        let oldName: String?
    }
    private var pendingClearHandoffs: [String: ClearHandoff] = [:]

    struct ToolApproval: Identifiable {
        let id: String  // toolUseId
        let tool: String
        let input: String
        let sessionId: String?
    }

    init(
        socket: BeekeeperSocket = BeekeeperSocket(config: .standard),
        credentials: CredentialStore = KeychainCredentialStore()
    ) {
        self.socket = socket
        self.credentials = credentials
    }

    func configure(context: ModelContext) {
        self.modelContext = context
        frameSubscription = socket.frames.sink { [weak self] data in
            self?.handleFrame(data)
        }
        socket.onAuthFailure = { [weak self] in
            self?.unpair()
        }
        socket.onConnected = { [weak self] in
            self?.listSessions()
        }
        socket.connect(channel: Self.channel)
    }

    // MARK: - Connection

    func reconnect() {
        socket.connect(channel: Self.channel)
    }

    func disconnect() {
        socket.disconnect()
    }

    /// Encodes and forwards. Returns `false` when the socket is not connected;
    /// child B queues on that signal.
    @discardableResult
    func send(_ outgoing: WSOutgoing) -> Bool {
        guard let data = try? outgoing.encode() else {
            Log.chat.error("failed to encode outgoing frame")
            return false
        }
        return socket.send(data)
    }

    private func handleFrame(_ data: Data) {
        let incoming = WSIncoming.decode(from: data)
            ?? .unknown(raw: String(decoding: data, as: UTF8.self))
        handleIncoming(incoming)
    }
```

Keep everything above line 32 (the `@Published` properties and `statusFor` / `toolNameFor`) as is. Delete the old `let ws = WebSocketManager()` and the old `configure`.

- [ ] **Step 2:** Replace every remaining `ws.send(` in the file with `send(` (lines 100, 105, 109, 114, 119, 123, 129, 133, 138, 159, 465, 470, 472 today). Sanity check afterwards:

```bash
grep -n 'ws\.' ViewModels/ChatViewModel.swift
```
Expected: no output.

- [ ] **Step 3:** Rewrite `unpair()`:

```swift
    func unpair() {
        socket.disconnect()
        credentials.clearAll()
        isAuthenticated = false
    }
```

- [ ] **Step 4:** In `Views/BeekeeperRootView.swift`, the doc comment above `ConciergeViewModel` (line 73) says "`WebSocketManager.onMessage` is single-consumer and already taken by `ChatViewModel`"; change that sentence to "`BeekeeperSocket.frames` is multicast, but this coordinator still observes `ChatViewModel`'s published state; child C switches it to the decoded-frame stream." Then change the four concierge sends:

```swift
// line 105
            viewModel.send(.resumeSession(sessionId: cached.sessionId, path: cached.path))
// line 117
        viewModel.send(.listSessions)
// line 119
            viewModel.send(.resumeSession(sessionId: match.sessionId, path: match.path))
// line 128
        viewModel.send(.newSessionConcierge)
```

- [ ] **Step 5:** In `Views/ContentView.swift:45` replace `chatViewModel.ws.connect()` with:

```swift
                chatViewModel.reconnect()
```

- [ ] **Step 6:** In `Views/SettingsView.swift` replace the three `viewModel.ws.isConnected` reads at lines 100–103 with `viewModel.socket.isConnected`, and the footer button (lines 187–191) with:

```swift
                Button(viewModel.socket.isConnected ? "Disconnect" : "Reconnect") {
                    if viewModel.socket.isConnected {
                        viewModel.disconnect()
                    } else {
                        viewModel.reconnect()
                    }
                }
```

- [ ] **Step 7:** In `Views/WorkspacePickerView.swift` line 40 `!viewModel.ws.isConnected` → `!viewModel.socket.isConnected`; line 48 `viewModel.ws.connect()` → `viewModel.reconnect()`.

- [ ] **Step 8:** In `Views/SessionListView.swift:95` `viewModel.ws.isConnected` → `viewModel.socket.isConnected`.

- [ ] **Step 9:** Check nothing in the Beekeeper layer references the old manager:

```bash
grep -rn 'viewModel\.ws\b\|chatViewModel\.ws\b' Views ViewModels
```
Expected: only `Views/Team/TeamRootView.swift:42` (Task 6).

- [ ] **Step 10:** Commit (no push yet)

```bash
git add ViewModels/ChatViewModel.swift Views/BeekeeperRootView.swift Views/ContentView.swift Views/SettingsView.swift Views/WorkspacePickerView.swift Views/SessionListView.swift
git commit -m "refactor(#90): ChatViewModel consumes BeekeeperSocket by injection; views use reconnect/disconnect/send"
```

---

### Task 6: `TeamViewModel` adopts the socket; Team view site — **PUSH 2**

**Files:**
- Modify: `ViewModels/TeamViewModel.swift`
- Modify: `Views/Team/TeamRootView.swift:42`

- [ ] **Step 0:** At the top of `ViewModels/TeamViewModel.swift`, after `import SwiftUI`, add:

```swift
import os
```

- [ ] **Step 1:** Replace the "Internal State" block and `configure` (lines 41–71 today) with:

```swift
    let socket: BeekeeperSocket
    private let credentials: CredentialStore
    private var subscriptions = Set<AnyCancellable>()
    private var previousSocketState: BeekeeperSocket.State = .disconnected
    private var modelContext: ModelContext?
    /// Read on every use so a re-pair (new device id) is picked up immediately.
    private var deviceId: String { credentials.deviceId ?? "" }
    private var pendingCommandChannels: [String: String] = [:]  // requestId -> channelId
    private var pendingMessageIds: [String: String] = [:]       // requestId -> local message id
    private var pendingNewCommands: Set<String> = []             // requestIds for /new commands
    private var pendingAgentDM: String?       // agent ID to auto-select after channel refresh
    private var pendingDMRequestId: String?   // request UUID of the /dm command

    init(
        socket: BeekeeperSocket = BeekeeperSocket(config: .standard),
        credentials: CredentialStore = KeychainCredentialStore()
    ) {
        self.socket = socket
        self.credentials = credentials
    }

    // MARK: - Setup

    func configure(context: ModelContext, capabilityManager: CapabilityManager) {
        guard modelContext == nil else { return }  // Idempotency guard
        self.modelContext = context
        self.capabilityManager = capabilityManager

        socket.frames
            .sink { [weak self] data in self?.handleFrame(data) }
            .store(in: &subscriptions)
        socket.$state
            .dropFirst()
            .sink { [weak self] state in self?.handleSocketState(state) }
            .store(in: &subscriptions)
        socket.onAuthFailure = { [weak self] in
            self?.handleAuthFailure()
        }
        socket.onConnected = { [weak self] in
            self?.onConnected()
        }
    }

    private func handleFrame(_ data: Data) {
        guard let incoming = TeamWSIncoming.decode(from: data) else {
            Log.team.debug("dropping undecodable frame")
            return
        }
        handleIncoming(incoming)
    }
```

Note the old `self.deviceId = KeychainManager.deviceId ?? ""` line is gone; `deviceId` is computed now. The `ws.onMessage` / `ws.onAuthFailure` / `ws.onConnect` / `ws.onReceiveFailure` assignments are gone.

- [ ] **Step 2:** Replace `connectIfPossible`, `retryConnect`, `handleReceiveFailure` (lines 72–105 today) with:

```swift
    func connectIfPossible() {
        guard let manager = capabilityManager,
              let channel = manager.selectedHive,
              manager.hives.contains(channel) else {
            Log.team.info("connectIfPossible: no valid selectedHive; disconnecting")
            socket.disconnect()
            return
        }
        Log.team.info("connectIfPossible: channel=\(channel, privacy: .public)")
        socket.connect(channel: channel)
    }

    /// Foregrounding and the Settings button call this; during backoff it attempts immediately.
    func reconnect() {
        connectIfPossible()
    }

    func retryConnect() {
        disconnectedBanner = nil
        reconnect()
    }

    /// Replaces the old `onReceiveFailure` hook. The socket now backs off on its own;
    /// this only keeps the hive-vanished check and the banner (child B replaces the banner).
    private func handleSocketState(_ state: BeekeeperSocket.State) {
        defer { previousSocketState = state }
        switch state {
        case .reconnecting(let attempt) where attempt == 1 && previousSocketState != state:
            handleConnectionLost()
        case .connected:
            disconnectedBanner = nil
        default:
            break
        }
    }

    private func handleConnectionLost() {
        guard let manager = capabilityManager else { return }
        let label = manager.selectedHive ?? "hive"
        disconnectedBanner = "\(label) is unavailable — tap to retry."
        Task { [weak self] in
            await manager.refresh()
            guard let self else { return }
            if let current = manager.selectedHive, manager.hives.contains(current) {
                // Hive still exists; the socket keeps backing off and the banner offers retry-now.
            } else {
                self.disconnectedBanner = nil
                self.socket.disconnect()
            }
        }
    }
```

- [ ] **Step 3:** `disconnect()` (line ~107) and `handleAuthFailure()` (line ~254): replace `ws.disconnect()` with `socket.disconnect()`.

- [ ] **Step 4:** Add the send helpers right after `disconnect()`:

```swift
    // MARK: - Sending

    @discardableResult
    private func send(_ outgoing: TeamWSOutgoing) -> Bool {
        guard let data = try? outgoing.encode() else {
            Log.team.error("failed to encode outgoing frame")
            return false
        }
        return socket.send(data)
    }

    /// Send and return the request UUID for correlation; nil when not connected.
    private func sendWithId(_ outgoing: TeamWSOutgoing) -> String? {
        guard socket.isConnected, let result = try? outgoing.encodeWithId() else { return nil }
        guard socket.send(result.data) else { return nil }
        return result.id
    }
```

- [ ] **Step 5:** Replace every `ws.send(` with `send(` and every `ws.sendWithId(` with `sendWithId(` (lines 144, 150, 152, 205, 209, 220, 224, 234, 235, 273, 296, 374 today). Then:

```bash
grep -n 'ws\.' ViewModels/TeamViewModel.swift
```
Expected: only the comment at line ~237 ("Use fetchHistory (not direct ws.send)…"); change that comment to say `send`.

- [ ] **Step 6:** Line ~137 `senderName: KeychainManager.deviceName ?? "Me"` → `senderName: credentials.deviceName ?? "Me"`. In `handleAuthFailure` (line ~256) reword the comment to "Don't clear credentials here — ContentView observes `isAuthenticated` and calls `chatViewModel.unpair()`, which owns that." Then:

```bash
grep -n 'KeychainManager' ViewModels/TeamViewModel.swift
```
Expected: no output.

- [ ] **Step 7:** Replace the three `print` calls (lines 76, 80 are gone with Step 2; line ~403 `print("[Team WS error] \(message)")`) with:

```swift
            Log.team.error("server error: \(message, privacy: .public)")
```

- [ ] **Step 8:** `Views/Team/TeamRootView.swift:42` `viewModel.ws.isConnected` → `viewModel.socket.isConnected`.

- [ ] **Step 9:** Check:

```bash
grep -rn '\bws\.' ViewModels Views | grep -v 'ws\.active\|ws\.sessionId\|ws\.preview\|ws\.lastActiveAt'
```
Expected: no output (the excluded matches are `WorkspaceSession` locals in `WorkspacePickerView`).

- [ ] **Step 10:** Commit and **PUSH 2**

```bash
git add ViewModels/TeamViewModel.swift Views/Team/TeamRootView.swift
git commit -m "refactor(#90): TeamViewModel consumes BeekeeperSocket; state observer replaces onReceiveFailure; computed deviceId"
export GH_TOKEN="$(gh auth token --user may-keepur)"
git -c credential.helper= -c credential.helper='!f(){ echo "username=may-keepur"; echo "password=$GH_TOKEN"; }; f' push origin issue-90
```

- [ ] **Step 11:** Verify

Expected: `Executed 184 tests, with 0 failures`. Both view models now run on the new socket; the old managers still compile but are unreferenced.

---

### Task 7: Delete the old managers; last `print` — **PUSH 3**

**Files:**
- Delete: `Managers/WebSocketManager.swift`
- Delete: `Managers/TeamWebSocketManager.swift`
- Modify: `Managers/CapabilityManager.swift:49`

- [ ] **Step 1:**

```bash
git rm -q Managers/WebSocketManager.swift Managers/TeamWebSocketManager.swift
```

- [ ] **Step 2:** In `Managers/CapabilityManager.swift` add `import os` after `import SwiftUI`, and replace line 49 `print("[Capabilities] raw: \(all)")` with:

```swift
            Log.capabilities.debug("capabilities: \(all.count, privacy: .public) entries")
```

- [ ] **Step 3:** Checks:

```bash
grep -rn 'WebSocketManager' --include='*.swift' . ; echo "---"; grep -rn 'print(' Managers ViewModels
```
Expected: both empty.

- [ ] **Step 4:** Commit and **PUSH 3**

```bash
git add -A Managers
git commit -m "chore(#90): delete WebSocketManager and TeamWebSocketManager; last print → Log"
export GH_TOKEN="$(gh auth token --user may-keepur)"
git -c credential.helper= -c credential.helper='!f(){ echo "username=may-keepur"; echo "password=$GH_TOKEN"; }; f' push origin issue-90
```

- [ ] **Step 5:** Verify. Expected: `Executed 184 tests, with 0 failures`.

---

### Task 8: `TeamViewModelTests` — **PUSH 4**

**Files:**
- Create: `KeeperTests/TeamViewModelTests.swift`

- [ ] **Step 1:** Create the file

```swift
import XCTest
import SwiftData
@testable import Keepur

@MainActor
final class TeamViewModelTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var credentials: FakeCredentialStore!
    private var factory: FakeWebSocketTaskFactory!
    private var capability: CapabilityManager!   // held here: TeamViewModel keeps it weak
    private var vm: TeamViewModel!

    override func setUp() async throws {
        let schema = Schema([TeamChannel.self, TeamMessage.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [config])
        context = ModelContext(container)
        credentials = FakeCredentialStore(deviceId: "device-old")
        factory = FakeWebSocketTaskFactory()
        capability = CapabilityManager()
        let factory = self.factory!
        let socket = BeekeeperSocket(
            config: .standard,
            credentials: credentials,
            endpoint: { URL(string: "wss://unit.test")! },
            taskFactory: { factory.make(url: $0) }   // closure literal, not `factory.make`
        )
        vm = TeamViewModel(socket: socket, credentials: credentials)
        vm.configure(context: context, capabilityManager: capability)
        vm.activeChannelId = "channel-1"
    }

    override func tearDown() async throws {
        vm = nil
        capability = nil
        context = nil
        container = nil
    }

    private func senderIdsByText() throws -> [String: String] {
        let rows = try context.fetch(FetchDescriptor<TeamMessage>())
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.text, $0.senderId) })
    }

    func testDeviceIdFollowsCredentialStore() throws {
        vm.sendMessage(text: "first")
        credentials.deviceId = "device-new"     // what a re-pair does
        vm.sendMessage(text: "second")

        let senders = try senderIdsByText()
        XCTAssertEqual(senders, ["first": "device-old", "second": "device-new"],
                       "sender id must be read at send time, not captured in configure")
        let rows = try context.fetch(FetchDescriptor<TeamMessage>())
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy(\.pending), "socket never connected, so nothing was acked")
    }
}
```

- [ ] **Step 2:** Commit and **PUSH 4**

```bash
git add KeeperTests/TeamViewModelTests.swift
git commit -m "test(#90): TeamViewModel sender id follows the credential store after re-pair"
export GH_TOKEN="$(gh auth token --user may-keepur)"
git -c credential.helper= -c credential.helper='!f(){ echo "username=may-keepur"; echo "password=$GH_TOKEN"; }; f' push origin issue-90
```

- [ ] **Step 3:** Verify. Expected: `Executed 185 tests, with 0 failures`.

---

### Task 9: Hand-off

- [ ] **Step 1:** Edit the PR body to list what changed (the file map above), the four green runs by id, and three behavior changes: Team reconnects with backoff instead of stopping at the retry banner; `deviceId` is read at send time; and a known interim in `WorkspacePickerView`, where "Reconnect" now calls `reconnect()` then `browse()` and the browse frame is dropped while the handshake is still in flight (the old manager claimed connected instantly). Child B's offline queue closes that gap; until then the user taps Retry once more. Keep it a draft; `/quality-gate`, `dodi-dev:review`, and `dodi-dev:submit` follow per CLAUDE.md. `/quality-gate`'s test step is the CI run.
- [ ] **Step 2:** Confirm the spec's Child A acceptance lines hold: `grep -rn 'WebSocketManager' --include='*.swift' .` empty; `grep -rn 'print(' Managers ViewModels` empty; no view reads `viewModel.ws`.
