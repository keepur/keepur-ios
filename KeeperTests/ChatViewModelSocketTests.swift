import XCTest
import SwiftData
@testable import Keepur

/// `ChatViewModel` on an injected `BeekeeperSocket` driven by the fake task:
/// the cold-start frame order, inbound routing into `handleIncoming`, send
/// gating before the handshake, and the 4001 → `unpair()` path.
@MainActor
final class ChatViewModelSocketTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var credentials: FakeCredentialStore!
    private var factory: FakeWebSocketTaskFactory!
    private var vm: ChatViewModel!

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: Session.self, Message.self, configurations: config)
        context = ModelContext(container)
        credentials = FakeCredentialStore()
        factory = FakeWebSocketTaskFactory()
        let factory = self.factory!
        let socket = BeekeeperSocket(
            config: .standard,
            credentials: credentials,
            endpoint: { URL(string: "wss://unit.test")! },
            taskFactory: { factory.make(url: $0) }   // closure literal, not `factory.make`
        )
        vm = ChatViewModel(socket: socket, credentials: credentials)
    }

    override func tearDown() async throws {
        vm = nil
        factory = nil
        credentials = nil
        context = nil
        container = nil
    }

    // MARK: - Helpers

    /// Let the socket's `Task { @MainActor in … }` hops run.
    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
    }

    /// The `type` field of each frame the fake task was asked to send, in order.
    private func sentTypes(_ task: FakeWebSocketTask) throws -> [String] {
        try task.sentTexts.map { text in
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            return try XCTUnwrap(json["type"] as? String)
        }
    }

    // MARK: - Tests

    func testConfigureConnectsOnBeekeeperChannelAndListsSessionsAfterHandshake() async throws {
        vm.configure(context: context)

        let task = try XCTUnwrap(factory.latest)
        XCTAssertTrue(task.url.absoluteString.hasSuffix("&channel=beekeeper"))
        XCTAssertTrue(task.sentTexts.isEmpty, "nothing goes out before the handshake completes")

        task.completeHandshake()
        await settle()

        XCTAssertTrue(vm.socket.isConnected)
        XCTAssertEqual(try sentTypes(task), ["ping", "list_sessions"],
                       "keep-alive first, then onConnected's list_sessions")
    }

    func testInboundFrameIsDecodedAndDispatchedToHandleIncoming() async throws {
        vm.configure(context: context)
        let task = try XCTUnwrap(factory.latest)
        task.completeHandshake()
        await settle()

        task.deliver(#"{"type":"status","state":"busy","sessionId":"s1"}"#)
        await settle()

        XCTAssertEqual(vm.sessionStatuses["s1"], "busy")
    }

    func testSendIsGatedOnConnectionAndForwardsEncodedFrame() async throws {
        XCTAssertFalse(vm.send(.listSessions), "no socket task yet")

        vm.configure(context: context)
        let task = try XCTUnwrap(factory.latest)
        XCTAssertFalse(vm.send(.listSessions), "still handshaking")
        XCTAssertTrue(task.sentTexts.isEmpty)

        task.completeHandshake()
        await settle()

        XCTAssertTrue(vm.send(.cancel(sessionId: "s1")))
        XCTAssertEqual(try sentTypes(task).last, "cancel")
    }

    func testCloseCode4001UnpairsAndClearsCredentials() async throws {
        vm.configure(context: context)
        let task = try XCTUnwrap(factory.latest)
        task.completeHandshake()
        await settle()
        XCTAssertTrue(vm.isAuthenticated)

        task.failReceive(closeCode: URLSessionWebSocketTask.CloseCode(rawValue: 4001)!)
        await settle()

        XCTAssertFalse(vm.isAuthenticated)
        XCTAssertEqual(credentials.clearAllCalls, 1)
        XCTAssertFalse(vm.socket.isConnected)
        XCTAssertEqual(factory.made.count, 1, "auth failure must not schedule a reconnect")
    }
}
