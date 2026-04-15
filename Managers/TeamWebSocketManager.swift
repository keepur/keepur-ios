import Foundation
import Combine
import SwiftUI

@MainActor
final class TeamWebSocketManager: ObservableObject {
    @Published var isConnected = false

    var onMessage: ((TeamWSIncoming) -> Void)?
    var onAuthFailure: (() -> Void)?
    var onConnect: (() -> Void)?
    var onReceiveFailure: (() -> Void)?

    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var pingTimer: Timer?
    private var reconnectAttempts = 0
    private var isReconnecting = false
    private var isConnecting = false
    private let maxReconnectDelay: TimeInterval = 30
    private var tokenReadRetries = 0
    private let maxTokenReadRetries = 3
    private var currentChannel: String?

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

    func disconnect() {
        isReconnecting = false
        isConnecting = false
        tokenReadRetries = 0
        currentChannel = nil
        pingTimer?.invalidate()
        pingTimer = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        session?.invalidateAndCancel()
        session = nil
        isConnected = false
    }

    func send(_ outgoing: TeamWSOutgoing) {
        guard isConnected,
              let data = try? outgoing.encode(),
              let string = String(data: data, encoding: .utf8) else { return }
        print("[Team WS send] \(string.prefix(200))")
        webSocketTask?.send(.string(string)) { [weak self] error in
            if error != nil {
                Task { @MainActor in
                    self?.handleDisconnect()
                }
            }
        }
    }

    /// Send and return the request UUID for correlation.
    func sendWithId(_ outgoing: TeamWSOutgoing) -> String? {
        guard isConnected,
              let result = try? outgoing.encodeWithId(),
              let string = String(data: result.data, encoding: .utf8) else { return nil }
        print("[Team WS send] \(string.prefix(200))")
        webSocketTask?.send(.string(string)) { [weak self] error in
            if error != nil {
                Task { @MainActor in
                    self?.handleDisconnect()
                }
            }
        }
        return result.id
    }

    // MARK: - Private

    private func cleanupConnection() {
        pingTimer?.invalidate()
        pingTimer = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        session?.invalidateAndCancel()
        session = nil
        isConnected = false
        isConnecting = false
    }

    private func receiveMessage() {
        guard let task = webSocketTask else { return }
        task.receive { [weak self, weak task] result in
            Task { @MainActor in
                guard let self, let task, self.webSocketTask === task else { return }
                switch result {
                case .success(let message):
                    switch message {
                    case .string(let text):
                        print("[Team WS recv] \(text.prefix(200))")
                        if let data = text.data(using: .utf8),
                           let incoming = TeamWSIncoming.decode(from: data) {
                            self.onMessage?(incoming)
                        }
                    case .data(let data):
                        if let incoming = TeamWSIncoming.decode(from: data) {
                            self.onMessage?(incoming)
                        }
                    @unknown default:
                        break
                    }
                    self.receiveMessage()
                case .failure:
                    let closeCode = task.closeCode
                    if closeCode.rawValue == 4001 {
                        self.onAuthFailure?()
                    } else {
                        self.onReceiveFailure?()
                        self.handleDisconnect()
                    }
                }
            }
        }
    }

    private func handleDisconnect() {
        guard isConnected || isConnecting else { return }
        cleanupConnection()
        scheduleReconnect()
    }

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

    private func startPing() {
        pingTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.send(.ping)
            }
        }
    }
}
