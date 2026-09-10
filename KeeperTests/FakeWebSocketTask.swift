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
    /// The code the socket cancelled this task with (`disconnect()` → `.normalClosure`,
    /// failure/channel-switch teardown → `.goingAway`).
    private(set) var lastCloseCode: URLSessionWebSocketTask.CloseCode?
    private(set) var sentTexts: [String] = []
    var onSend: ((String) -> Void)?
    private var pingHandler: (@Sendable (Error?) -> Void)?
    private var receiveHandler: (@Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void)?

    init(url: URL) { self.url = url }

    // MARK: WebSocketTasking

    func resume() { resumed = true }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        cancelled = true
        lastCloseCode = closeCode
    }

    func send(_ message: URLSessionWebSocketTask.Message,
              completionHandler: @escaping @Sendable (Error?) -> Void) {
        if case .string(let text) = message {
            sentTexts.append(text)
            onSend?(text)
        }
        completionHandler(nil)
    }

    func receive(completionHandler: @escaping @Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void) {
        receiveHandler = completionHandler
    }

    func performHandshake(pongReceiveHandler: @escaping @Sendable (Error?) -> Void) {
        pingHandler = pongReceiveHandler
    }

    func sendPing(pongReceiveHandler: @escaping @Sendable (Error?) -> Void) {
        pongReceiveHandler(nil)
    }

    // MARK: Test controls

    var handshakeRequested: Bool { pingHandler != nil }
    var receiveRequested: Bool { receiveHandler != nil }

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

    func savedHandshakeCompletion() -> () -> Void {
        let handler = pingHandler
        return { handler?(nil) }
    }

    func savedDelivery(_ text: String) -> () -> Void {
        let handler = receiveHandler
        return { handler?(.success(.string(text))) }
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
