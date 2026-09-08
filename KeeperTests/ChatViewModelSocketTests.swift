import XCTest
import SwiftData
import Combine
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
        XCTAssertFalse(vm.listSessions(), "no socket task yet")

        vm.configure(context: context)
        let task = try XCTUnwrap(factory.latest)
        XCTAssertFalse(vm.listSessions(), "still handshaking")
        XCTAssertTrue(task.sentTexts.isEmpty)

        task.completeHandshake()
        await settle()

        XCTAssertTrue(vm.listSessions())
        XCTAssertEqual(try sentFrames(task).last as NSDictionary?, ["type": "list_sessions"] as NSDictionary)
        vm.cancelCurrentOperation(for: "s1")
        XCTAssertEqual(try sentTypes(task).last, "cancel")
        XCTAssertEqual(try sentFrames(task).last?["sessionId"] as? String, "s1")
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

    func testReconnectFallbackFlushesOneHeadPerIdleSessionAndLateListDoesNotFlushAgain() async throws {
        vm.configure(context: context)
        let task = try XCTUnwrap(factory.latest)
        for (sessionId, texts) in [("s1", ["s1-first", "s1-second"]), ("s2", ["s2-first", "s2-second"])] {
            vm.currentSessionId = sessionId
            vm.sessionStatuses[sessionId] = "idle"
            for text in texts {
                vm.messageText = text
                vm.sendText()
            }
        }
        let queuedRows = try rows(role: "user")
        XCTAssertEqual(queuedRows.count, 4)
        XCTAssertEqual(vm.pendingReasons, Dictionary(uniqueKeysWithValues: queuedRows.map { ($0.id, .offline) }))
        XCTAssertTrue(task.sentTexts.isEmpty)

        task.completeHandshake()
        await settle()
        XCTAssertEqual(vm.connectionState, .connected)
        XCTAssertEqual(try messageTexts(task), [], "the handshake alone does not flush")

        // Exercise the real five-second fallback; polling gives a loaded simulator
        // time to run it without adding a production timer seam.
        let deadline = ContinuousClock.now.advanced(by: .seconds(7))
        while try messageTexts(task).count < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(try messageTexts(task), ["s1-first", "s2-first"])
        let remainingRows = queuedRows.filter { $0.text.hasSuffix("-second") }
        let remainingReasons = Dictionary(uniqueKeysWithValues: remainingRows.map { ($0.id, ChatViewModel.PendingReason.busy) })
        XCTAssertEqual(vm.pendingReasons, remainingReasons, "only one head per idle session is sent")

        task.deliver(#"{"type":"session_list","sessions":[{"sessionId":"s1","path":"/tmp/p1","state":"idle","mode":"sessions"},{"sessionId":"s2","path":"/tmp/p2","state":"idle","mode":"sessions"}]}"#)
        await settle()
        XCTAssertEqual(try messageTexts(task), ["s1-first", "s2-first"], "the late list must not run a second reconnect flush")
        XCTAssertEqual(vm.pendingReasons, remainingReasons)

        task.deliver(#"{"type":"status","state":"idle","sessionId":"s1"}"#)
        await settle()
        XCTAssertEqual(try messageTexts(task), ["s1-first", "s2-first", "s1-second"])
        task.deliver(#"{"type":"status","state":"idle","sessionId":"s2"}"#)
        await settle()
        XCTAssertEqual(try messageTexts(task), ["s1-first", "s2-first", "s1-second", "s2-second"])
        XCTAssertTrue(vm.pendingReasons.isEmpty, "later idle statuses drain the preserved queue")
    }

    func testConnectionLossCancelsReconnectFallbackAndPreservesOfflineQueue() async throws {
        let (first, firstRowId) = try queueOfflineHi()
        vm.messageText = "later"
        vm.sendText()
        let secondRowId = try XCTUnwrap(rows(role: "user").first { $0.text == "later" }?.id)
        let offlineReasons: [String: ChatViewModel.PendingReason] = [firstRowId: .offline, secondRowId: .offline]
        XCTAssertEqual(vm.pendingReasons, offlineReasons)

        first.completeHandshake()
        await settle()
        XCTAssertEqual(vm.connectionState, .connected)
        XCTAssertTrue(try messageTexts(first).isEmpty)
        first.failReceive(closeCode: .abnormalClosure)
        await settle()
        XCTAssertEqual(vm.connectionState, .reconnecting(attempt: 1))

        vm.reconnect()
        let second = try XCTUnwrap(factory.latest)
        XCTAssertFalse(second === first)
        XCTAssertEqual(factory.made.count, 2)
        // Leave the retry handshake pending past the old fallback's deadline. Two
        // rows expose an uncancelled pass even if its head is requeued as offline.
        try await Task.sleep(for: .milliseconds(5200))
        XCTAssertEqual(vm.connectionState, .reconnecting(attempt: 1))
        XCTAssertEqual(vm.pendingReasons, offlineReasons, "loss must cancel reclassification as well as sends")
        XCTAssertTrue(try messageTexts(first).isEmpty)
        XCTAssertTrue(second.sentTexts.isEmpty, "nothing goes out while the retry is handshaking")

        second.completeHandshake()
        await settle()
        XCTAssertEqual(vm.connectionState, .connected)
        XCTAssertEqual(vm.pendingReasons, offlineReasons)
        XCTAssertTrue(try messageTexts(second).isEmpty, "the new connection waits for its own session list")
        second.deliver(Self.s1Idle)
        await settle()
        XCTAssertEqual(try messageTexts(second), ["hi"])
        XCTAssertEqual(vm.pendingReasons, [secondRowId: .busy])

        second.deliver(#"{"type":"status","state":"idle","sessionId":"s1"}"#)
        await settle()
        XCTAssertEqual(try messageTexts(second), ["hi", "later"])
        XCTAssertTrue(vm.pendingReasons.isEmpty)
        XCTAssertTrue(try messageTexts(first).isEmpty)
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
        vm.currentSessionId = "s1"
        let task = try XCTUnwrap(factory.latest)
        task.completeHandshake()
        await settle()

        task.deliver(#"{"type":"error","message":"bad"}"#)
        await settle()
        XCTAssertEqual(vm.lastError?.text, "bad")
        XCTAssertNil(vm.browseError)
        XCTAssertEqual(try rows(role: "system").count, 0, "no bubble in whichever session is current")

        vm.lastError = nil
        vm.browse(path: "/tmp/denied")
        XCTAssertEqual(try sentTypes(task).last, "browse", "the browse request must be pending")
        task.deliver(#"{"type":"error","message":"browse denied"}"#)
        await settle()
        XCTAssertEqual(vm.browseError, "browse denied")
        XCTAssertNil(vm.lastError, "a pending browse error belongs only in the picker")
        XCTAssertEqual(try rows(role: "system").count, 0)

        task.deliver(#"{"type":"error","message":"unrelated"}"#)
        await settle()
        XCTAssertEqual(vm.lastError?.text, "unrelated", "the browse error must clear the pending request")
        XCTAssertEqual(vm.browseError, "browse denied", "a later error must not replace the browse error")
        XCTAssertEqual(try rows(role: "system").count, 0)

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

@MainActor
private final class QueueReleaseHarness {
    let credentials: FakeCredentialStore
    let factory: FakeWebSocketTaskFactory
    let socket: BeekeeperSocket
    let container: ModelContainer
    let context: ModelContext
    let vm: ChatViewModel
    var task: FakeWebSocketTask
    let bytes = Data([9, 4, 2])
    init() throws {
        let credentials = FakeCredentialStore(), factory = FakeWebSocketTaskFactory()
        let container = try ModelContainer(for: Session.self, Message.self, Workspace.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let socket = BeekeeperSocket(credentials: credentials,
            endpoint: { URL(string: "wss://queue.unit.test")! },
            taskFactory: { factory.make(url: $0) })
        let vm = ChatViewModel(socket: socket, credentials: credentials)
        vm.configure(context: context)
        self.credentials = credentials
        self.factory = factory
        self.socket = socket
        self.container = container
        self.context = context
        self.vm = vm
        task = try XCTUnwrap(factory.latest)
        vm.currentSessionId = "s1"
        vm.sessionStatuses["s1"] = "idle"
    }
    func settle() async { for _ in 0..<8 { await Task.yield() } }
    func handshake() async { task.completeHandshake(); await settle() }
    func reconnectHandshake() async throws {
        vm.reconnect()
        task = try XCTUnwrap(factory.latest)
        await handshake()
    }
    func deliver(_ object: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        task.deliver(String(decoding: data, as: UTF8.self))
        await settle()
    }
    func list(_ sessions: [(String, String)] = [("s1", "idle")]) async throws {
        try await deliver(["type": "session_list", "sessions": sessions.map {
            ["sessionId": $0.0, "path": "/tmp/\($0.0)", "state": $0.1, "mode": "sessions"]
        }])
    }
    func status(_ state: String, _ id: String = "s1") async throws {
        try await deliver(["type": "status", "state": state, "sessionId": id])
    }
    @discardableResult
    func send(_ text: String, _ id: String = "s1", attachment: AttachmentData? = nil) throws -> String {
        vm.currentSessionId = id
        vm.messageText = text
        vm.pendingAttachment = attachment
        vm.sendText()
        let display = text.isEmpty ? (attachment?.name ?? "") : text
        let rows = try context.fetch(FetchDescriptor<Message>())
        return try XCTUnwrap(rows.first { $0.sessionId == id && $0.text == display }?.id)
    }
    func attachment(_ mime: String = "application/octet-stream") -> AttachmentData {
        AttachmentData(data: bytes, name: mime.hasPrefix("image/") ? "a.png" : "a.bin", mimeType: mime)
    }
    func payloads(_ id: String? = nil) throws -> [[String: Any]] {
        try task.sentTexts.map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }.filter {
            ["message", "image", "file"].contains($0["type"] as? String ?? "")
                && (id == nil || $0["sessionId"] as? String == id)
        }
    }
    func messages(_ id: String = "s1") throws -> [String] {
        try payloads(id).filter { $0["type"] as? String == "message" }.compactMap { $0["text"] as? String }
    }
    func waitForFallback(messageCount: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(7))
        while try payloads().filter({ $0["type"] as? String == "message" }).count < messageCount,
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(try payloads().filter { $0["type"] as? String == "message" }.count, messageCount)
    }
}

extension ChatViewModelSocketTests {
    func testSendAfterReconnectHandshakeJoinsEarlierOfflineEntries() async throws {
        for mixedBusy in [false, true] {
            let h = try QueueReleaseHarness()
            defer { h.vm.disconnect() }
            await h.handshake()
            try await h.list()
            var expected: [String] = []
            if mixedBusy {
                try await h.status("thinking")
                let older = try h.send("older-busy")
                XCTAssertEqual(h.vm.pendingReasons[older], .busy)
                expected.append("older-busy")
            }
            h.vm.disconnect()
            let a = try h.send("A")
            try await h.reconnectHandshake()
            let b = try h.send("B")
            XCTAssertTrue(try h.payloads().isEmpty)
            XCTAssertEqual(h.vm.pendingReasons[a], .offline)
            XCTAssertEqual(h.vm.pendingReasons[b], .offline)
            expected += ["A", "B", "C"]
            try await h.list()
            XCTAssertEqual(try h.messages(), Array(expected.prefix(1)))
            XCTAssertEqual(h.vm.pendingReasons[b], .busy)
            let c = try h.send("C")
            XCTAssertEqual(h.vm.pendingReasons[c], .busy)
            for count in 2...expected.count {
                try await h.status("idle")
                XCTAssertEqual(try h.messages(), Array(expected.prefix(count)))
            }
            XCTAssertTrue(h.vm.pendingReasons.isEmpty)
        }
    }

    func testReconnectBacklogDoesNotBlockUnrelatedSession() async throws {
        let h = try QueueReleaseHarness()
        defer { h.vm.disconnect() }
        let a = try h.send("A")
        await h.handshake()
        let b = try h.send("B")
        try h.send("X", "s2")
        XCTAssertEqual(try h.messages("s2"), ["X"])
        XCTAssertEqual(try h.messages(), [])
        XCTAssertEqual(h.vm.pendingReasons, [a: .offline, b: .offline])
        try await h.list([("s1", "idle"), ("s2", "idle")])
        XCTAssertEqual(try h.messages(), ["A"])
        XCTAssertEqual(try h.messages("s2"), ["X"])
    }

    func testAttachmentEntryCannotBeOvertakenDuringReconnect() async throws {
        for mime in ["image/png", "application/octet-stream"] {
            for text in ["", "A"] {
                let h = try QueueReleaseHarness()
                defer { h.vm.disconnect() }
                let attachment = h.attachment(mime)
                let a = try h.send(text, attachment: attachment)
                await h.handshake()
                let b = try h.send("B")
                XCTAssertEqual(h.vm.pendingReasons, [a: .offline, b: .offline])
                XCTAssertTrue(try h.payloads().isEmpty)
                try await h.list()
                let types = (text.isEmpty ? [] : ["message"]) + [mime.hasPrefix("image/") ? "image" : "file"]
                let sent = try h.payloads()
                XCTAssertEqual(sent.compactMap { $0["type"] as? String }, types)
                XCTAssertEqual(sent.last?["data"] as? String, h.bytes.base64EncodedString())
                XCTAssertEqual(sent.last?["filename"] as? String, attachment.name)
                XCTAssertEqual(try h.messages(), text.isEmpty ? [] : ["A"])
                XCTAssertEqual(h.vm.pendingReasons, [b: .busy])
                try await h.status("idle")
                XCTAssertEqual(try h.payloads().compactMap { $0["type"] as? String }, types + ["message"])
                XCTAssertEqual(try h.messages(), text.isEmpty ? ["B"] : ["A", "B"])
                XCTAssertTrue(h.vm.pendingReasons.isEmpty)
            }
        }
    }

    func testNewSendWaitsForIdleAfterQueueHeadEmptiesQueue() async throws {
        let h = try QueueReleaseHarness()
        defer { h.vm.disconnect() }
        try h.send("A")
        await h.handshake()
        try await h.list()
        XCTAssertTrue(h.vm.pendingReasons.isEmpty)
        let b = try h.send("B")
        XCTAssertEqual(h.vm.pendingReasons[b], .busy)
        XCTAssertEqual(try h.messages(), ["A"])
        try await h.status("thinking")
        let c = try h.send("C")
        XCTAssertEqual(h.vm.pendingReasons, [b: .busy, c: .busy])
        XCTAssertEqual(try h.messages(), ["A"])
        try await h.status("idle")
        XCTAssertEqual(try h.messages(), ["A", "B"])
        try await h.status("idle")
        XCTAssertEqual(try h.messages(), ["A", "B", "C"])
    }

    func testBusyReconnectListHoldsBothNewAndEarlierEntries() async throws {
        let h = try QueueReleaseHarness()
        defer { h.vm.disconnect() }
        let a = try h.send("A")
        await h.handshake()
        let b = try h.send("B")
        try await h.list([("s1", "busy")])
        XCTAssertEqual(h.vm.pendingReasons, [a: .busy, b: .busy])
        XCTAssertTrue(try h.payloads().isEmpty)
        try await h.status("idle")
        XCTAssertEqual(try h.messages(), ["A"])
        try await h.status("idle")
        XCTAssertEqual(try h.messages(), ["A", "B"])
    }

    func testLiveBusyBeforeListReclassifiesOnlyItsSession() async throws {
        let h = try QueueReleaseHarness()
        defer { h.vm.disconnect() }
        let a = try h.send("A")
        let x = try h.send("X", "s2")
        await h.handshake()
        try await h.status("thinking")
        let b = try h.send("B")
        XCTAssertEqual(h.vm.pendingReasons, [a: .busy, b: .busy, x: .offline])
        XCTAssertTrue(try h.payloads().isEmpty)
        try await h.list([("s1", "busy"), ("s2", "idle")])
        XCTAssertEqual(try h.messages(), [])
        XCTAssertEqual(try h.messages("s2"), ["X"])
        try await h.status("idle")
        XCTAssertEqual(try h.messages(), ["A"])
        try await h.status("idle")
        XCTAssertEqual(try h.messages(), ["A", "B"])
    }

    func testEarlyIdleReleaseIsNotRepeatedByInitialSync() async throws {
        for busyBeforeList in [false, true] {
            let h = try QueueReleaseHarness()
            defer { h.vm.disconnect() }
            try h.send("A")
            let b = try h.send("B")
            try h.send("X", "s2")
            await h.handshake()
            try await h.status("idle")
            XCTAssertEqual(try h.messages(), ["A"])
            XCTAssertEqual(h.vm.pendingReasons[b], .busy)
            let c = try h.send("C")
            if busyBeforeList { try await h.status("thinking") }
            try await h.list([("s1", "idle"), ("s2", "idle")])
            XCTAssertEqual(try h.messages(), ["A"], "initial busy-to-idle reconciliation cannot grant a second release")
            XCTAssertEqual(try h.messages("s2"), ["X"])
            XCTAssertEqual(h.vm.pendingReasons, [b: .busy, c: .busy])
            try await h.status("idle")
            XCTAssertEqual(try h.messages(), ["A", "B"])
            try await h.status("idle")
            XCTAssertEqual(try h.messages(), ["A", "B", "C"])
        }
    }

    func testEarlyIdleReleaseIsNotRepeatedByFallback() async throws {
        let h = try QueueReleaseHarness()
        defer { h.vm.disconnect() }
        try h.send("A")
        let b = try h.send("B")
        try h.send("X", "s2")
        await h.handshake()
        try await h.status("idle")
        let c = try h.send("C")
        XCTAssertEqual(try h.messages(), ["A"])
        try await h.waitForFallback(messageCount: 2) // A already sent; fallback must send only s2's X.
        XCTAssertEqual(try h.messages(), ["A"])
        XCTAssertEqual(try h.messages("s2"), ["X"])
        XCTAssertEqual(h.vm.pendingReasons, [b: .busy, c: .busy])
        try await h.list([("s1", "idle"), ("s2", "idle")])
        XCTAssertEqual(try h.messages(), ["A"])
        try await h.status("idle")
        XCTAssertEqual(try h.messages(), ["A", "B"])
        try await h.status("idle")
        XCTAssertEqual(try h.messages(), ["A", "B", "C"])
    }

    func testSendAfterHandshakeWaitsForFallbackAndLateListDoesNotDoubleFlush() async throws {
        let h = try QueueReleaseHarness()
        defer { h.vm.disconnect() }
        let a = try h.send("A")
        await h.handshake()
        let b = try h.send("B")
        XCTAssertEqual(h.vm.pendingReasons, [a: .offline, b: .offline])
        XCTAssertTrue(try h.payloads().isEmpty)
        try await h.waitForFallback(messageCount: 1)
        XCTAssertEqual(try h.messages(), ["A"])
        XCTAssertEqual(h.vm.pendingReasons, [b: .busy])
        try await h.list()
        XCTAssertEqual(try h.messages(), ["A"])
        try await h.status("idle")
        XCTAssertEqual(try h.messages(), ["A", "B"])
    }

    func testSessionReplacementMigratesReleaseAndInitialSyncSkip() async throws {
        for queuedBeforeReplacement in [false, true] {
            let h = try QueueReleaseHarness()
            defer { h.vm.disconnect() }
            try h.send("A")
            var b: String?
            if queuedBeforeReplacement { b = try h.send("B") }
            await h.handshake()
            try await h.status("idle")
            try await h.deliver(["type": "session_replaced", "oldSessionId": "s1",
                                 "newSessionId": "s-new", "path": "/tmp/s1"])
            XCTAssertEqual(h.vm.currentSessionId, "s-new")
            if !queuedBeforeReplacement { b = try h.send("B", "s-new") }
            let bID = try XCTUnwrap(b)
            let c = try h.send("C", "s-new")
            XCTAssertEqual(try h.messages("s-new"), [], "even an emptied queue must retain its migrated release gate")
            XCTAssertEqual(h.vm.pendingReasons, [bID: .busy, c: .busy])
            try await h.status("thinking", "s-new")
            try await h.list([("s-new", "idle")])
            XCTAssertEqual(try h.messages("s-new"), [], "migrated skip survives the initial busy-to-idle list")
            try await h.status("idle", "s-new")
            XCTAssertEqual(try h.messages("s-new"), ["B"])
            try await h.status("idle", "s-new")
            XCTAssertEqual(try h.messages("s-new"), ["B", "C"])
            XCTAssertEqual(try h.messages("s1"), ["A"])
            XCTAssertTrue(h.vm.pendingReasons.isEmpty)
        }
    }

    func testSessionCleanupRemovesReleaseOnlyAndQueuedBookkeeping() async throws {
        for cleanup in ["cancel", "ended", "absent", "clear", "server-clear", "context-clear"] {
            for queuedTail in [false, true] {
                let h = try QueueReleaseHarness()
                defer { h.vm.disconnect() }
                try h.send("A")
                await h.handshake()
                try await h.status("idle") // Last queue head sent before initial sync.
                if queuedTail { try h.send("B", attachment: h.attachment()) }
                switch cleanup {
                case "cancel": h.vm.cancelCurrentOperation(for: "s1")
                case "ended": try await h.status("session_ended")
                case "absent": try await h.list([])
                case "clear": h.vm.clearSession(sessionId: "s1")
                case "server-clear": try await h.deliver(["type": "session_cleared", "sessionId": "s1"])
                default:
                    try await h.deliver(["type": "context_cleared", "oldSessionId": "s1", "sessionId": "s1"])
                }
                XCTAssertTrue(h.vm.pendingReasons.isEmpty)
                XCTAssertEqual(h.vm.queuedAttachmentCountForTesting, 0)
                h.vm.sessionStatuses["s1"] = "idle"
                try h.send("fresh")
                XCTAssertEqual(try h.messages(), ["A", "fresh"], "release-only admission gate must be cleared")
                // For cleanup paths that did not consume initial sync, prove the old skip ID is gone too.
                if cleanup != "absent" {
                    h.vm.sessionStatuses["s1"] = "busy"
                    let next = try h.send("new-queued")
                    XCTAssertEqual(h.vm.pendingReasons[next], .busy)
                    h.vm.sessionStatuses["s1"] = "idle"
                    try await h.list()
                    XCTAssertEqual(try h.messages(), ["A", "fresh", "new-queued"])
                }
            }
        }
    }

    func testDisconnectClearsReleaseGateAndCancelsEarlierFallback() async throws {
        let h = try QueueReleaseHarness()
        defer { h.vm.disconnect() }
        try h.send("A")
        let b = try h.send("B")
        await h.handshake()
        try await h.status("idle")
        XCTAssertEqual(try h.messages(), ["A"])
        let old = h.task
        h.vm.disconnect()
        let c = try h.send("C", attachment: h.attachment())
        h.vm.reconnect()
        h.task = try XCTUnwrap(h.factory.latest)
        let reasons: [String: ChatViewModel.PendingReason] = [b: .busy, c: .offline]
        XCTAssertEqual(h.vm.pendingReasons, reasons)
        try await Task.sleep(for: .milliseconds(5200))
        XCTAssertEqual(h.vm.pendingReasons, reasons, "cancelled fallback must not reclassify C")
        XCTAssertTrue(h.task.sentTexts.isEmpty)
        await h.handshake()
        try await h.list()
        XCTAssertEqual(try h.messages(), ["B"], "old submitted A is not resent; stale release cannot block B")
        XCTAssertEqual(h.vm.pendingReasons, [c: .busy])
        try await h.status("idle")
        XCTAssertEqual(try h.messages(), ["B", "C"])
        XCTAssertEqual(try h.payloads().last?["data"] as? String, h.bytes.base64EncodedString())
        let oldMessages = try old.sentTexts.map {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }.compactMap { $0?["text"] as? String }
        XCTAssertEqual(oldMessages, ["A"])
    }

    func testRejectedDirectSendKeepsAttachmentAheadOfLaterSubmission() async throws {
        let h = try QueueReleaseHarness()
        // State forwarding is deliberately frozen below, so unpair also cancels
        // the VM's fallback directly rather than relying on its state subscriber.
        defer { h.vm.unpair() }
        await h.handshake()
        XCTAssertEqual(h.vm.connectionState, .connected)
        XCTAssertEqual(h.socket.state, .connected)
        // Test-only fault injection: detach the existing state subscription, then
        // disconnect the real socket. Reflection avoids a production test seam;
        // unwrap both the reflected optional and its value so renames fail loudly.
        // This does not depend on Combine subscriber order or willSet timing.
        let stateSubscription = try XCTUnwrap(
            Mirror(reflecting: h.vm).descendant("stateSubscription") as? Optional<AnyCancellable>
        )
        try XCTUnwrap(stateSubscription).cancel()
        h.socket.disconnect()
        XCTAssertTrue(h.vm.pendingReasons.isEmpty)
        XCTAssertEqual(h.vm.statusFor("s1"), "idle")
        XCTAssertEqual(h.vm.connectionState, .connected)
        XCTAssertEqual(h.socket.state, .disconnected)
        let aID = try h.send("A", attachment: h.attachment())
        let bID = try h.send("B")
        XCTAssertEqual(h.vm.pendingReasons, [aID: .offline, bID: .offline])
        XCTAssertEqual(h.vm.queuedAttachmentCountForTesting, 1)
        XCTAssertTrue(try h.payloads().isEmpty)
        // The first handshake's initial-sync flag is still armed in the frozen VM.
        // Reconnect the transport before delivering that sync to release rejected A.
        try await h.reconnectHandshake()
        try await h.list()
        XCTAssertEqual(try h.payloads().compactMap { $0["type"] as? String }, ["message", "file"])
        XCTAssertEqual(try h.payloads().last?["data"] as? String, h.bytes.base64EncodedString())
        XCTAssertEqual(h.vm.pendingReasons, [bID: .busy])
        try await h.status("idle")
        XCTAssertEqual(try h.messages(), ["A", "B"])
    }

    func testOrdinaryBusyToIdleSyncReleasesHeldQueueHead() async throws {
        let h = try QueueReleaseHarness()
        defer { h.vm.disconnect() }
        try h.send("A")
        await h.handshake()
        try await h.list()
        let b = try h.send("B")
        try await h.status("thinking")
        XCTAssertEqual(h.vm.pendingReasons[b], .busy)
        try await h.list() // Ordinary sync after initial sync has already completed.
        XCTAssertEqual(try h.messages(), ["A", "B"])
        let c = try h.send("C")
        XCTAssertEqual(h.vm.pendingReasons[c], .busy)
        XCTAssertEqual(try h.messages(), ["A", "B"])
        try await h.status("idle")
        XCTAssertEqual(try h.messages(), ["A", "B", "C"])
    }
}
