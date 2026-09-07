import XCTest
import SwiftData
@testable import Keepur

/// `ChatViewModel` on an injected `BeekeeperSocket` driven by the fake task:
/// cold-start frame order, inbound routing, send gating, 4001 → unpair, and the child-B offline queue.
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

    /// Every frame the fake task was asked to send, decoded, in order.
    private func sentFrames(_ task: FakeWebSocketTask) throws -> [[String: Any]] {
        try task.sentTexts.map { text in
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        }
    }

    /// `text` of every `message` frame, in order.
    private func messageTexts(_ task: FakeWebSocketTask) throws -> [String] {
        try sentFrames(task)
            .filter { $0["type"] as? String == "message" }
            .compactMap { $0["text"] as? String }
    }

    private func rows(role: String) throws -> [Message] {
        try context.fetch(FetchDescriptor<Message>()).filter { $0.role == role }
    }

    /// Minimal decodable `session_list`: the decoder requires sessionId/path/state and
    /// `mode` must be "sessions" (or omitted) to survive the Sessions-tab filter.
    private static let s1Idle = #"{"type":"session_list","sessions":[{"sessionId":"s1","path":"/tmp/p","state":"idle","mode":"sessions"}]}"#
    private static let s1Busy = #"{"type":"session_list","sessions":[{"sessionId":"s1","path":"/tmp/p","state":"busy","mode":"sessions"}]}"#

    /// `configure`, select `s1` idle, and queue "hi" while still handshaking.
    private func queueOfflineHi() throws -> (task: FakeWebSocketTask, rowId: String) {
        vm.configure(context: context)
        let task = try XCTUnwrap(factory.latest)
        vm.currentSessionId = "s1"
        vm.sessionStatuses["s1"] = "idle"
        vm.messageText = "hi"
        vm.sendText()
        let rowId = try XCTUnwrap(rows(role: "user").first?.id)
        XCTAssertEqual(vm.pendingReasons[rowId], .offline)
        XCTAssertTrue(task.sentTexts.isEmpty, "nothing goes out before the handshake")
        return (task, rowId)
    }

    // MARK: - Tests

    func testConfigureConnectsOnBeekeeperChannelAndListsSessionsAfterHandshake() async throws {
        vm.configure(context: context)

        let task = try XCTUnwrap(factory.latest)
        XCTAssertTrue(task.url.absoluteString.hasSuffix("&channel=beekeeper"))
        XCTAssertTrue(task.sentTexts.isEmpty, "nothing goes out before the handshake completes")

        task.completeHandshake()
        await settle()

        XCTAssertEqual(vm.connectionState, .connected)
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
        XCTAssertEqual(vm.connectionState, .disconnected)
        XCTAssertEqual(factory.made.count, 1, "auth failure must not schedule a reconnect")
    }

    // MARK: - Child B: offline queue (⚠3 — C re-homes these into ChatViewModelTests)

    func testSendWhileConnectingQueuesOfflineAndFlushesAfterSessionList() async throws {
        let (task, _) = try queueOfflineHi()

        task.completeHandshake()
        await settle()
        XCTAssertEqual(vm.connectionState, .connected)
        XCTAssertEqual(try messageTexts(task), [], "no flush before the post-reconnect session_list")

        task.deliver(Self.s1Idle)
        await settle()

        XCTAssertEqual(try messageTexts(task), ["hi"])
        XCTAssertTrue(vm.pendingReasons.isEmpty)
    }

    func testOfflineEntryReclassifiedBusyWhenServerBusy() async throws {
        let (task, rowId) = try queueOfflineHi()
        task.completeHandshake()
        await settle()

        task.deliver(Self.s1Busy)
        await settle()
        XCTAssertEqual(vm.pendingReasons[rowId], .busy)
        XCTAssertEqual(try messageTexts(task), [], "busy session: nothing flushed")

        task.deliver(#"{"type":"status","state":"idle","sessionId":"s1"}"#)
        await settle()
        XCTAssertEqual(try messageTexts(task), ["hi"])
        XCTAssertNil(vm.pendingReasons[rowId])
    }

    /// 13a: the queue carries the trimmed text (empty here), not `effectiveText`, so an
    /// attachment-only send flushed from the queue emits no `message` frame.
    func testAttachmentOnlyOfflineSendEmitsNoTextFrame() async throws {
        vm.configure(context: context)
        let task = try XCTUnwrap(factory.latest)
        vm.currentSessionId = "s1"
        vm.sessionStatuses["s1"] = "idle"
        vm.pendingAttachment = AttachmentData(data: Data([0x89, 0x50, 0x4E, 0x47]), name: "pic.png", mimeType: "image/png")
        vm.sendText()
        let row = try XCTUnwrap(rows(role: "user").first)
        XCTAssertEqual(row.text, "pic.png", "the row keeps effectiveText for display")
        XCTAssertEqual(vm.pendingReasons[row.id], .offline)

        task.completeHandshake()
        await settle()
        task.deliver(Self.s1Idle)
        await settle()

        XCTAssertEqual(try sentTypes(task), ["ping", "list_sessions", "image"],
                       "no spurious message frame carrying the attachment name")
        XCTAssertTrue(vm.pendingReasons.isEmpty)
    }

    func testErrorWithNilSessionIdSetsLastErrorNotBubble() async throws {
        vm.configure(context: context)
        let task = try XCTUnwrap(factory.latest)
        task.completeHandshake()
        await settle()

        task.deliver(#"{"type":"error","message":"bad"}"#)
        await settle()
        XCTAssertEqual(vm.lastError?.text, "bad")
        XCTAssertEqual(try rows(role: "system").count, 0, "no bubble in whichever session is current")

        vm.lastError = nil
        task.deliver(#"{"type":"error","message":"scoped","sessionId":"s1"}"#)
        await settle()
        XCTAssertNil(vm.lastError, "a session-scoped error stays a bubble")
        XCTAssertEqual(try rows(role: "system").count, 1)
        XCTAssertEqual(try rows(role: "system").first?.sessionId, "s1")
    }

    func testAbsentBusySessionGetsSessionEndedCleanup() async throws {
        vm.configure(context: context)
        let task = try XCTUnwrap(factory.latest)
        vm.currentSessionId = "gone"
        vm.sessionStatuses["gone"] = "thinking"
        vm.messageText = "late"
        vm.sendText()
        let rowId = try XCTUnwrap(rows(role: "user").first?.id)
        XCTAssertEqual(vm.pendingReasons[rowId], .offline)

        task.completeHandshake()
        await settle()
        task.deliver(Self.s1Idle)   // `gone` is absent from the full reply
        await settle()

        XCTAssertNil(vm.sessionStatuses["gone"], "non-idle absent session gets the session_ended cleanup")
        XCTAssertTrue(vm.pendingReasons.isEmpty)
        XCTAssertEqual(try messageTexts(task), [], "dropped, not sent")
    }

    /// 15a (⚠6): `unpair()` drops the queue so nothing flushes into the next pairing.
    func testUnpairClearsOfflineQueue() async throws {
        _ = try queueOfflineHi()

        vm.unpair()
        XCTAssertTrue(vm.pendingReasons.isEmpty)
        XCTAssertFalse(vm.isAuthenticated)
        XCTAssertEqual(vm.connectionState, .disconnected)

        credentials.token = "test-token"   // a re-pair
        vm.reconnect()
        let task = try XCTUnwrap(factory.latest)
        XCTAssertEqual(factory.made.count, 2)
        task.completeHandshake()
        await settle()
        task.deliver(Self.s1Idle)
        await settle()
        XCTAssertEqual(try messageTexts(task), [], "nothing queued before the unpair reaches the new pairing")
    }
}
