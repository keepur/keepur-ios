import Foundation
import Combine
import SwiftUI

@MainActor
final class WebSocketManager: ObservableObject {
    @Published var isConnected = false

    var onMessage: ((WSIncoming) -> Void)?
    var onAuthFailure: (() -> Void)?
    var onConnect: (() -> Void)?

    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var pingTimer: Timer?
    private var reconnectAttempts = 0
    private var isReconnecting = false
    private let maxReconnectDelay: TimeInterval = 30
    private var tokenReadRetries = 0
    private let maxTokenReadRetries = 3
    func connect() {
        guard !isConnected else { return }
        guard let token = KeychainManager.token else {
            // Token unreadable — may be transient Keychain failure.
            // Retry a few times, then fall through to reconnect backoff.
            if tokenReadRetries < maxTokenReadRetries {
                tokenReadRetries += 1
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    self?.connect()
                }
            } else {
                // Retries exhausted — reset counter and schedule reconnect
                // so the next cycle gets a fresh set of retries.
                tokenReadRetries = 0
                handleDisconnect()
            }
            return
        }
        tokenReadRetries = 0

        cleanupConnection()

        guard let baseURL = try? BeekeeperConfig.wssURL(),
              let url = URL(string: "\(baseURL.absoluteString)?token=\(token)") else {
            print("[WS] host not configured — routing to auth gate")
            onAuthFailure?()
            return
        }
        let config = URLSessionConfiguration.default
        session = URLSession(configuration: config)
        webSocketTask = session?.webSocketTask(with: url)
        webSocketTask?.resume()

        isConnected = true
        reconnectAttempts = 0
        isReconnecting = false
        startPing()
        receiveMessage()
        onConnect?()
    }

    func disconnect() {
        isReconnecting = false
        tokenReadRetries = 0
        pingTimer?.invalidate()
        pingTimer = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        session?.invalidateAndCancel()
        session = nil
        isConnected = false
    }

    func send(_ outgoing: WSOutgoing) {
        guard isConnected,
              let data = try? outgoing.encode(),
              let string = String(data: data, encoding: .utf8) else { return }
        print("[WS send] \(string.prefix(200))")
        webSocketTask?.send(.string(string)) { [weak self] error in
            if error != nil {
                Task { @MainActor in
                    self?.handleDisconnect()
                }
            }
        }
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
    }

    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let message):
                    switch message {
                    case .string(let text):
                        print("[WS recv] \(text.prefix(200))")
                        if let data = text.data(using: .utf8) {
                            let incoming = WSIncoming.decode(from: data)
                                ?? .unknown(raw: text)
                            self.onMessage?(incoming)
                        }
                    case .data(let data):
                        let incoming = WSIncoming.decode(from: data)
                            ?? .unknown(raw: String(data: data, encoding: .utf8) ?? "")
                        self.onMessage?(incoming)
                    @unknown default:
                        break
                    }
                    self.receiveMessage()
                case .failure:
                    let closeCode = self.webSocketTask?.closeCode ?? .invalid
                    if closeCode.rawValue == 4001 {
                        self.onAuthFailure?()
                    } else {
                        self.handleDisconnect()
                    }
                }
            }
        }
    }

    private func handleDisconnect() {
        guard isConnected else { return }
        isConnected = false
        pingTimer?.invalidate()
        pingTimer = nil
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard KeychainManager.isPaired, !isReconnecting else { return }
        isReconnecting = true
        reconnectAttempts += 1
        let delay = min(pow(2.0, Double(reconnectAttempts)), maxReconnectDelay)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, self.isReconnecting else { return }
            self.isConnected = false
            self.connect()
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
