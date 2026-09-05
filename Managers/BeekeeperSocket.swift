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
