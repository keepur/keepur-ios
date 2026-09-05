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
