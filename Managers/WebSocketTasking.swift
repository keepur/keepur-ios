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
    func performHandshake(pongReceiveHandler: @escaping @Sendable (Error?) -> Void)
    func sendPing(pongReceiveHandler: @escaping @Sendable (Error?) -> Void)
}

/// Production adapter. Owns the `URLSession` as well as the task so that
/// `cancel` can also invalidate the session (the old managers did both).
final class URLSessionWebSocketTaskAdapter: NSObject, WebSocketTasking, @unchecked Sendable {
    private final class DelegateProxy: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
        weak var owner: URLSessionWebSocketTaskAdapter?

        init(owner: URLSessionWebSocketTaskAdapter) {
            self.owner = owner
        }

        func urlSession(
            _ session: URLSession,
            webSocketTask: URLSessionWebSocketTask,
            didOpenWithProtocol protocol: String?
        ) {
            owner?.didOpen(webSocketTask)
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didCompleteWithError error: Error?
        ) {
            owner?.didComplete(error)
        }
    }

    private var session: URLSession!
    private var task: URLSessionWebSocketTask!
    private var delegateProxy: DelegateProxy!
    private let usesApplicationHandshake: Bool
    private let openLock = NSLock()
    private var isOpen = false
    private var terminalError: Error?
    private var pendingControlPingHandlers: [@Sendable (Error?) -> Void] = []
    private var pendingApplicationHandshakeHandlers: [@Sendable (Error?) -> Void] = []
    private var bufferedMessages: [URLSessionWebSocketTask.Message] = []

    init(url: URL) {
        usesApplicationHandshake = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "channel" })?.value == "beekeeper"
        super.init()
        delegateProxy = DelegateProxy(owner: self)
        session = URLSession(configuration: .default, delegate: delegateProxy, delegateQueue: nil)
        task = session.webSocketTask(with: url)
    }

    deinit {
        session.invalidateAndCancel()
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
        openLock.lock()
        if !bufferedMessages.isEmpty {
            let message = bufferedMessages.removeFirst()
            openLock.unlock()
            completionHandler(.success(message))
            return
        }
        openLock.unlock()
        task.receive(completionHandler: completionHandler)
    }

    func performHandshake(pongReceiveHandler: @escaping @Sendable (Error?) -> Void) {
        guard usesApplicationHandshake else {
            sendPing(pongReceiveHandler: pongReceiveHandler)
            return
        }
        openLock.lock()
        if let terminalError {
            openLock.unlock()
            pongReceiveHandler(terminalError)
            return
        }
        if !isOpen {
            pendingApplicationHandshakeHandlers.append(pongReceiveHandler)
            openLock.unlock()
            return
        }
        openLock.unlock()
        performApplicationHandshake(pongReceiveHandler)
    }

    func sendPing(pongReceiveHandler: @escaping @Sendable (Error?) -> Void) {
        openLock.lock()
        if let terminalError {
            openLock.unlock()
            pongReceiveHandler(terminalError)
            return
        }
        if !isOpen {
            pendingControlPingHandlers.append(pongReceiveHandler)
            openLock.unlock()
            return
        }
        openLock.unlock()
        task.sendPing(pongReceiveHandler: pongReceiveHandler)
    }

    private func didOpen(_ webSocketTask: URLSessionWebSocketTask) {
        openLock.lock()
        guard terminalError == nil else {
            openLock.unlock()
            return
        }
        isOpen = true
        let controlHandlers = pendingControlPingHandlers
        pendingControlPingHandlers.removeAll()
        let applicationHandlers = pendingApplicationHandshakeHandlers
        pendingApplicationHandshakeHandlers.removeAll()
        openLock.unlock()

        for handler in controlHandlers {
            webSocketTask.sendPing(pongReceiveHandler: handler)
        }
        for handler in applicationHandlers {
            performApplicationHandshake(handler)
        }
    }

    private func didComplete(_ error: Error?) {
        let failure = error ?? URLError(.networkConnectionLost)
        openLock.lock()
        isOpen = false
        terminalError = failure
        let controlHandlers = pendingControlPingHandlers
        pendingControlPingHandlers.removeAll()
        let applicationHandlers = pendingApplicationHandshakeHandlers
        pendingApplicationHandshakeHandlers.removeAll()
        openLock.unlock()

        for handler in controlHandlers {
            handler(failure)
        }
        for handler in applicationHandlers {
            handler(failure)
        }
    }

    /// URLSession's control-frame `sendPing` can remain pending indefinitely when
    /// issued through an HTTP proxy. Use Beekeeper's JSON ping/pong protocol for
    /// the opening round trip and preserve any eager server frames that arrive
    /// before the pong (notably the initial session list).
    private func performApplicationHandshake(_ completion: @escaping @Sendable (Error?) -> Void) {
        task.send(.string(#"{"type":"ping"}"#)) { [weak self] error in
            guard let self else { return }
            if let error {
                completion(error)
                return
            }
            self.receiveUntilApplicationPong(completion)
        }
    }

    private func receiveUntilApplicationPong(_ completion: @escaping @Sendable (Error?) -> Void) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                completion(error)
            case .success(let message):
                if Self.isApplicationPong(message) {
                    completion(nil)
                } else {
                    self.openLock.lock()
                    self.bufferedMessages.append(message)
                    self.openLock.unlock()
                    self.receiveUntilApplicationPong(completion)
                }
            }
        }
    }

    private static func isApplicationPong(_ message: URLSessionWebSocketTask.Message) -> Bool {
        let data: Data
        switch message {
        case .string(let text): data = Data(text.utf8)
        case .data(let value): data = value
        @unknown default: return false
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return object["type"] as? String == "pong"
    }
}
