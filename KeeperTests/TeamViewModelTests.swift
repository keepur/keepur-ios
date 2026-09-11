import XCTest
import SwiftData
@testable import Keepur

/// `TeamViewModel` on an injected `BeekeeperSocket` driven by the fake task: the
/// stale-`deviceId` fix from child A, and child B's `connectionState` forwarding,
/// `lastError`, and hive-scoped offline queue.
///
/// Every case that connects inherits the cross-suite `KeychainManager.token` ordering
/// dependency (#102) through `refreshCapabilitiesAfterConnectionLost`'s real
/// `manager.refresh()`; B does not fix it and must not add a second one. Seeding a hive
/// with `_setHivesForTesting` is required, not incidental: `connectIfPossible()` needs a
/// valid `selectedHive`, and on the first `.reconnecting` the refresh fails in tests (no
/// token) leaving `hives`/`selectedHive` untouched, so it takes the harmless "hive still
/// exists" path instead of the hive-vanished branch.
@MainActor
final class TeamViewModelTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var credentials: FakeCredentialStore!
    private var factory: FakeWebSocketTaskFactory!
    private var capability: CapabilityManager!   // held here: TeamViewModel keeps it weak
    private var vm: TeamViewModel!
    private var savedHive: String?

    override func setUp() async throws {
        savedHive = UserDefaults.standard.string(forKey: "selectedHive")
        UserDefaults.standard.removeObject(forKey: "selectedHive")
        let schema = Schema([TeamChannel.self, TeamMessage.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [config])
        context = ModelContext(container)
        credentials = FakeCredentialStore(deviceId: "device-old")
        factory = FakeWebSocketTaskFactory()
        capability = CapabilityManager()
        makeViewModel()
    }

    override func tearDown() async throws {
        vm = nil
        capability = nil
        context = nil
        container = nil
        if let savedHive { UserDefaults.standard.set(savedHive, forKey: "selectedHive") }
        else { UserDefaults.standard.removeObject(forKey: "selectedHive") }
    }

    // MARK: - Helpers

    /// (Re)build `vm` on a fresh socket; `setUp` uses the default auto-clear.
    private func makeViewModel(
        lastErrorAutoClear: Duration = .seconds(6),
        saveOperation: @escaping (ModelContext) throws -> Void = { try $0.save() }
    ) {
        let factory = self.factory!
        let socket = BeekeeperSocket(
            config: .standard,
            credentials: credentials,
            endpoint: { URL(string: "wss://unit.test")! },
            taskFactory: { factory.make(url: $0) }   // closure literal, not `factory.make`
        )
        vm = TeamViewModel(
            socket: socket,
            credentials: credentials,
            lastErrorAutoClear: lastErrorAutoClear,
            saveOperation: saveOperation
        )
        vm.configure(context: context, capabilityManager: capability)
        vm.activeChannelId = "channel-1"
    }

    private func senderIdsByText() throws -> [String: String] {
        let rows = try context.fetch(FetchDescriptor<TeamMessage>())
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.text, $0.senderId) })
    }

    private func rows() throws -> [TeamMessage] {
        try context.fetch(FetchDescriptor<TeamMessage>())
    }

    /// Let the socket's `Task { @MainActor in … }` hops run.
    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
    }

    private func sentFrames(_ task: FakeWebSocketTask) throws -> [[String: Any]] {
        try task.sentTexts.map { text in
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        }
    }

    /// `(id, text)` of every `message` frame on the task, in order.
    private func messageFrames(_ task: FakeWebSocketTask) throws -> [(id: String, text: String)] {
        try sentFrames(task)
            .filter { $0["type"] as? String == "message" }
            .map { (id: try XCTUnwrap($0["id"] as? String), text: try XCTUnwrap($0["text"] as? String)) }
    }

    /// Seed one hive, connect, complete the handshake on the first task.
    private func connectHive1() async throws -> FakeWebSocketTask {
        capability._setHivesForTesting(["hive-1"])
        XCTAssertEqual(capability.selectedHive, "hive-1")
        vm.connectIfPossible()
        let task = try XCTUnwrap(factory.latest)
        task.completeHandshake()
        await settle()
        XCTAssertEqual(vm.connectionState, .connected)
        return task
    }

    private func receivePersistenceFrame(_ object: [String: Any], on task: FakeWebSocketTask) async throws {
        try await eventually("Team receive armed") { task.receiveRequested }
        let data = try JSONSerialization.data(withJSONObject: object)
        task.deliver(String(decoding: data, as: UTF8.self))
        try await eventually("Team handler completed and receive rearmed") { task.receiveRequested }
    }

    // MARK: - Child A

    /// Sends before any `connectIfPossible()`: the rows are stamped `""`, stay queued
    /// and `pending: true` by design (§7) — exactly what this asserts; unchanged by B.
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

    // MARK: - Child B: connection state

    /// 9 (replaces testBannerReturnsAfterFailedManualRetry): the banner is now
    /// state-driven, and `reconnect()` during backoff opens a fresh task at once.
    func testConnectionStateFollowsSocketAndRetryOpensFreshTask() async throws {
        capability._setHivesForTesting(["hive-1"])
        vm.connectIfPossible()
        let firstTask = try XCTUnwrap(factory.latest)
        XCTAssertTrue(firstTask.url.absoluteString.hasSuffix("&channel=hive-1"))
        XCTAssertEqual(vm.connectionState, .connecting)
        firstTask.completeHandshake(error: URLError(.networkConnectionLost))
        await settle()
        XCTAssertEqual(vm.connectionState, .reconnecting(attempt: 1))

        vm.reconnect()
        XCTAssertEqual(factory.made.count, 2, "retry must open a fresh task immediately, during backoff")
        let secondTask = try XCTUnwrap(factory.latest)
        XCTAssertFalse(secondTask === firstTask)
        secondTask.completeHandshake(error: URLError(.networkConnectionLost))
        await settle()
        XCTAssertEqual(vm.connectionState, .reconnecting(attempt: 2))
    }

    /// 10
    func testSlashCommandWhileOfflineSetsLastError() throws {
        vm.messageText = "/new x"
        vm.sendMessage(text: "/new x")

        XCTAssertEqual(vm.lastError?.text, "Not connected. Try again when reconnected.")
        XCTAssertTrue(try rows().isEmpty, "slash commands insert no row")
        XCTAssertEqual(vm.messageText, "")
    }

    /// 11
    func testErrorFrameSetsLastError() async throws {
        let task = try await connectHive1()
        task.deliver(#"{"type":"error","message":"nope"}"#)
        await settle()
        XCTAssertEqual(vm.lastError?.text, "nope")
    }

    /// 11b
    func testLastErrorAutoClears() async throws {
        makeViewModel(lastErrorAutoClear: .milliseconds(50))
        let task = try await connectHive1()

        task.deliver(#"{"type":"error","message":"nope"}"#)
        await settle()
        XCTAssertNotNil(vm.lastError)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(vm.lastError, "auto-cleared after the injected delay")

        task.deliver(#"{"type":"error","message":"again"}"#)
        await settle()
        XCTAssertEqual(vm.lastError?.text, "again")
        vm.lastError = nil                           // banner tap before the deadline
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(vm.lastError, "a manual dismiss must not crash or resurrect the value")
    }

    // MARK: - Child B: offline queue

    /// 7: the real cold-start route — connect first (stamps `activeHive`), send during
    /// `.connecting`, re-send after the handshake's bookkeeping frames, ack flips pending.
    func testOfflineSendIsQueuedAndResentOnReconnect() async throws {
        capability._setHivesForTesting(["hive-1"])
        vm.connectIfPossible()
        let task = try XCTUnwrap(factory.latest)
        XCTAssertEqual(factory.made.count, 1)
        XCTAssertEqual(vm.connectionState, .connecting)

        vm.sendMessage(text: "hello")
        let row = try XCTUnwrap(rows().first)
        XCTAssertTrue(row.pending)
        XCTAssertEqual(vm.offlineMessageIds, [row.id])
        XCTAssertTrue(try messageFrames(task).isEmpty, "nothing is sent before the handshake")

        task.completeHandshake()
        await settle()
        let frames = try messageFrames(task)
        XCTAssertEqual(frames.map(\.text), ["hello"])
        XCTAssertTrue(vm.offlineMessageIds.isEmpty)
        let types = try sentFrames(task).compactMap { $0["type"] as? String }
        XCTAssertEqual(types.last, "message", "the re-send comes after the bookkeeping frames")

        task.deliver(#"{"type":"ack","id":"\#(frames[0].id)"}"#)
        await settle()
        XCTAssertFalse(try XCTUnwrap(rows().first).pending)
    }

    /// 8: same-hive reconnect re-sends what was un-acked when the link dropped.
    func testUnackedMessagesMoveToOfflineOnDisconnect() async throws {
        let first = try await connectHive1()
        vm.sendMessage(text: "a")
        let row = try XCTUnwrap(rows().first)
        let firstFrames = try messageFrames(first)
        XCTAssertEqual(firstFrames.map(\.text), ["a"])
        XCTAssertTrue(row.pending)
        XCTAssertTrue(vm.offlineMessageIds.isEmpty)

        first.failReceive(closeCode: .abnormalClosure)
        await settle()
        XCTAssertEqual(vm.connectionState, .reconnecting(attempt: 1))
        XCTAssertEqual(vm.offlineMessageIds, [row.id], "un-acked moves to offline on leaving .connected")

        vm.reconnect()                               // same selectedHive, during backoff
        let second = try XCTUnwrap(factory.latest)
        XCTAssertFalse(second === first)
        second.completeHandshake()
        await settle()
        let resent = try messageFrames(second)
        XCTAssertEqual(resent.map(\.text), ["a"])
        XCTAssertNotEqual(resent[0].id, firstFrames[0].id, "a fresh request id")
        XCTAssertTrue(vm.offlineMessageIds.isEmpty)

        second.deliver(#"{"type":"ack","id":"\#(resent[0].id)"}"#)
        await settle()
        XCTAssertFalse(try XCTUnwrap(rows().first).pending)
    }

    /// 8a: a hive switch never delivers a queued message into another hive; returning
    /// to the original hive delivers it.
    func testQueuedEntriesAreNotResentIntoAnotherHive() async throws {
        capability._setHivesForTesting(["hive-1", "hive-2"])
        capability.selectedHive = "hive-1"
        vm.connectIfPossible()
        let first = try XCTUnwrap(factory.latest)
        XCTAssertTrue(first.url.absoluteString.hasSuffix("&channel=hive-1"))
        first.completeHandshake()
        await settle()
        vm.sendMessage(text: "a")                    // sent, never acked
        let row = try XCTUnwrap(rows().first)

        vm.disconnect()                              // what the hive-grid pop does
        XCTAssertEqual(vm.connectionState, .disconnected)
        XCTAssertEqual(vm.offlineMessageIds, [row.id])

        capability.selectedHive = "hive-2"
        vm.connectIfPossible()
        let second = try XCTUnwrap(factory.latest)
        XCTAssertTrue(second.url.absoluteString.hasSuffix("&channel=hive-2"))
        second.completeHandshake()
        await settle()
        XCTAssertTrue(try messageFrames(second).isEmpty, "written for hive-1: must not go into hive-2")
        XCTAssertEqual(vm.offlineMessageIds, [row.id])
        XCTAssertTrue(try XCTUnwrap(rows().first).pending)

        vm.sendMessage(text: "b")                    // sent to hive-2, never acked
        let otherRow = try XCTUnwrap(rows().first { $0.text == "b" })
        let secondFrames = try messageFrames(second)
        XCTAssertEqual(secondFrames.map(\.text), ["b"])
        XCTAssertTrue(otherRow.pending)
        XCTAssertEqual(vm.offlineMessageIds, [row.id])
        XCTAssertEqual(vm.connectionState, .connected)

        capability.selectedHive = "hive-1"
        vm.connectIfPossible()                       // direct switch: no preceding disconnect
        let third = try XCTUnwrap(factory.latest)
        XCTAssertEqual(factory.made.count, 3)
        XCTAssertTrue(third.url.absoluteString.hasSuffix("&channel=hive-1"))
        XCTAssertEqual(vm.connectionState, .connecting)
        XCTAssertEqual(vm.offlineMessageIds, [row.id, otherRow.id], "the switch captures unacked sends from the departing hive")
        third.completeHandshake()
        await settle()
        let thirdFrames = try messageFrames(third)
        XCTAssertEqual(thirdFrames.map(\.text), ["a"], "hive-2's unacked send must not reach hive-1")
        XCTAssertEqual(vm.offlineMessageIds, [otherRow.id])
        XCTAssertTrue(otherRow.pending)
        third.deliver(#"{"type":"ack","id":"\#(thirdFrames[0].id)"}"#)
        await settle()
        XCTAssertFalse(row.pending)

        capability.selectedHive = "hive-2"
        vm.connectIfPossible()
        let fourth = try XCTUnwrap(factory.latest)
        XCTAssertEqual(factory.made.count, 4)
        XCTAssertTrue(fourth.url.absoluteString.hasSuffix("&channel=hive-2"))
        fourth.completeHandshake()
        await settle()
        let resent = try messageFrames(fourth)
        XCTAssertEqual(resent.map(\.text), ["b"], "returning to hive-2 delivers its queued send")
        XCTAssertNotEqual(resent[0].id, secondFrames[0].id, "the resend uses a fresh request id")
        XCTAssertTrue(vm.offlineMessageIds.isEmpty)
        fourth.deliver(#"{"type":"ack","id":"\#(resent[0].id)"}"#)
        await settle()
        XCTAssertFalse(otherRow.pending)
    }

    /// 11a (⚠6): auth failure clears both the offline queue and the un-acked map.
    /// Asserts `offlineMessageIds` (the queue), not the private request-id map;
    /// the second connect proves the latter was cleared too.
    func testAuthFailureClearsOfflineQueues() async throws {
        let first = try await connectHive1()
        vm.sendMessage(text: "a")
        XCTAssertEqual(try messageFrames(first).map(\.text), ["a"])

        first.failReceive(closeCode: URLSessionWebSocketTask.CloseCode(rawValue: 4001)!)
        await settle()
        XCTAssertFalse(vm.isAuthenticated)
        XCTAssertEqual(vm.connectionState, .disconnected)
        XCTAssertTrue(vm.offlineMessageIds.isEmpty, "the transition-out move ran, then the auth-failure clear")

        vm.connectIfPossible()                       // a re-pair reconnects the same VM
        let second = try XCTUnwrap(factory.latest)
        XCTAssertEqual(factory.made.count, 2)
        second.completeHandshake()
        await settle()
        XCTAssertTrue(try messageFrames(second).isEmpty, "nothing from the old pairing is re-sent")
    }

    func testFailedOptimisticSaveRetainsOfflineAttachmentAndResendsNormally() async throws {
        let sentinel = NSError(domain: "TeamPersistenceTests", code: 1)
        var fail = true, attempts = 0
        makeViewModel(saveOperation: { context in
            attempts += 1
            if fail { throw sentinel }
            try context.save()
        })
        context.autosaveEnabled = false
        capability._setHivesForTesting(["hive-1"])
        vm.connectIfPossible()
        let task = try XCTUnwrap(factory.latest)
        let bytes = Data([4, 4, 4])
        vm.pendingAttachment = AttachmentData(data: bytes, name: "a.bin", mimeType: "application/octet-stream")
        vm.messageText = "draft"
        vm.sendMessage(text: "queued")
        let row = try XCTUnwrap(rows().first)
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(vm.lastError?.text, "Couldn't save. Your last change may not be kept.")
        let errorID = try XCTUnwrap(vm.lastError?.id)
        XCTAssertEqual(vm.messageText, ""); XCTAssertNil(vm.pendingAttachment)
        XCTAssertTrue(row.pending); XCTAssertEqual(row.typedSenderType, .person)
        XCTAssertEqual(vm.offlineEntries, [.init(localId: row.id, hive: "hive-1")])
        XCTAssertEqual(vm.queuedAttachmentCountForTesting, 1)
        XCTAssertEqual(vm.pendingMessageRequestCountForTesting, 0)
        XCTAssertTrue(task.sentTexts.isEmpty)
        fail = false
        task.completeHandshake()
        try await eventually("Team queued payload resent") { try self.messageFrames(task).count == 1 }
        XCTAssertEqual(try messageFrames(task).map(\.text), ["queued"])
        let file = try XCTUnwrap(sentFrames(task).first { $0["type"] as? String == "file" })
        XCTAssertEqual(file["data"] as? String, bytes.base64EncodedString())
        XCTAssertTrue(vm.offlineEntries.isEmpty); XCTAssertEqual(vm.queuedAttachmentCountForTesting, 0)
        XCTAssertTrue(row.pending, "socket acceptance is not ack")
        XCTAssertEqual(vm.pendingMessageRequestCountForTesting, 1)
        let request = try XCTUnwrap(messageFrames(task).first?.id)
        try await receivePersistenceFrame(["type": "ack", "id": request], on: task)
        XCTAssertFalse(row.pending); XCTAssertEqual(vm.pendingMessageRequestCountForTesting, 0)
        XCTAssertEqual(vm.lastError?.id, errorID, "successful ack save leaves error timer/identity alone")
        vm.disconnect()
    }

    func testFailedSaveKeepsConnectedSendAndConditionalAckContinuation() async throws {
        let sentinel = NSError(domain: "TeamPersistenceTests", code: 2)
        var fail = true, attempts = 0
        makeViewModel(saveOperation: { context in
            attempts += 1
            if fail { throw sentinel }
            try context.save()
        })
        context.autosaveEnabled = false
        let task = try await connectHive1()
        vm.messageText = "direct"; vm.sendMessage(text: "direct")
        let row = try XCTUnwrap(rows().first), request = try XCTUnwrap(messageFrames(task).first?.id)
        XCTAssertEqual(attempts, 1); XCTAssertEqual(vm.messageText, "")
        XCTAssertTrue(row.pending); XCTAssertTrue(vm.offlineEntries.isEmpty)
        XCTAssertEqual(try messageFrames(task).map(\.text), ["direct"])
        XCTAssertEqual(vm.pendingMessageRequestCountForTesting, 1)
        XCTAssertEqual(vm.lastError?.text, "Couldn't save. Your last change may not be kept.")
        vm.lastError = nil // normal supported dismissal; subsequent error comes from actual ack save.
        try await receivePersistenceFrame(["type": "ack", "id": request], on: task)
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(vm.lastError?.text, "Couldn't save. Your last change may not be kept.")
        XCTAssertFalse(row.pending); XCTAssertEqual(vm.pendingMessageRequestCountForTesting, 0)
        XCTAssertEqual(vm.activeMessages.first { $0.id == row.id }?.pending, false)
        fail = false
        let previous = try XCTUnwrap(vm.lastError?.id)
        vm.sendMessage(text: "later")
        XCTAssertEqual(vm.lastError?.id, previous)
        vm.disconnect()
    }

    func testMissingOfflineRowDropsOnlyThatEntryAndPreservesResendOrder() async throws {
        context.autosaveEnabled = false
        capability._setHivesForTesting(["hive-1"]); vm.connectIfPossible()
        let task = try XCTUnwrap(factory.latest)
        vm.sendMessage(text: "first")
        vm.pendingAttachment = AttachmentData(data: Data([9]), name: "gone.bin", mimeType: "application/octet-stream")
        vm.sendMessage(text: "missing")
        vm.sendMessage(text: "last")
        let missing = try XCTUnwrap(rows().first { $0.text == "missing" })
        let first = try XCTUnwrap(rows().first { $0.text == "first" })
        let last = try XCTUnwrap(rows().first { $0.text == "last" })
        XCTAssertEqual(vm.offlineMessageIds, [first.id, missing.id, last.id])
        context.delete(missing); try context.save()
        task.completeHandshake()
        try await eventually("remaining rows resent") { try self.messageFrames(task).count == 2 }
        XCTAssertEqual(try messageFrames(task).map(\.text), ["first", "last"])
        XCTAssertTrue(vm.offlineEntries.isEmpty); XCTAssertEqual(vm.queuedAttachmentCountForTesting, 0)
        XCTAssertEqual(vm.pendingMessageRequestCountForTesting, 2)
        XCTAssertTrue(first.pending); XCTAssertTrue(last.pending)
        XCTAssertTrue(try sentFrames(task).filter { $0["type"] as? String == "file" }.isEmpty)
        vm.disconnect()
    }

    func testMissingChannelEventsRetainSelectionAndMessagesButJoinStillSends() async throws {
        let task = try await connectHive1()
        vm.sendMessage(text: "retained")
        let id = try XCTUnwrap(rows().first?.id)
        XCTAssertTrue(try context.fetch(FetchDescriptor<TeamChannel>()).isEmpty)
        for event in ["left", "archived"] {
            try await receivePersistenceFrame([
                "type": "channel_event", "channelId": "channel-1", "event": event,
                "detail": ["memberId": "device-old"], "id": "event-\(event)"
            ], on: task)
            XCTAssertEqual(vm.activeChannelId, "channel-1")
            XCTAssertEqual(vm.activeMessages.map(\.id), [id])
        }
        let before = try sentFrames(task).filter { $0["type"] as? String == "join" }.count
        vm.joinChannel(channelId: "missing")
        XCTAssertEqual(try sentFrames(task).filter { $0["type"] as? String == "join" }.count, before + 1)
        vm.disconnect()
    }

    func testUnknownTeamKindsAndSendersPersistWithoutKnownTypeMembership() async throws {
        let task = try await connectHive1()
        let historyRequest = try XCTUnwrap(sentFrames(task).last {
            $0["type"] as? String == "history" && $0["channelId"] as? String == "channel-1"
                && $0["limit"] as? Int == 50
        }?["id"] as? String)
        vm.agents = [TeamAgentInfo(id: "agent-1", name: "Agent", icon: "", title: nil,
                                  model: "", status: .idle, tools: [], schedule: [], channels: [],
                                  messagesProcessed: 0, lastActivity: nil)]
        try await receivePersistenceFrame([
            "type": "channel_list", "id": "channels", "channels": [
                ["id": "channel-1", "type": "future-kind", "name": "Raw name", "members": ["agent-1"]]
            ]
        ], on: task)
        let channel = try XCTUnwrap(vm.channels.first)
        XCTAssertEqual(channel.type, "future-kind"); XCTAssertEqual(channel.kind, .unknown("future-kind"))
        XCTAssertEqual(vm.displayName(for: channel), "Raw name")
        XCTAssertEqual(vm.sortedAgents.count, 1); XCTAssertNil(vm.sortedAgents.first?.dmChannel)
        context.insert(TeamMessage(id: "live", channelId: "channel-1", senderId: "other",
                                   senderType: SenderType.agent.wireValue, senderName: "Other", text: "same"))
        try context.save()
        let history: [[String: Any]] = ["one", "two"].map { id in
            ["id": id, "senderId": "other", "senderType": "future-sender", "senderName": "Other",
             "text": "same", "createdAt": "2026-09-07T12:00:00.000Z"]
        }
        try await receivePersistenceFrame([
            "type": "history", "channelId": "channel-1", "hasMore": false, "id": historyRequest, "messages": history
        ], on: task)
        let inserted = try rows().filter { $0.id == "one" || $0.id == "two" }
        XCTAssertEqual(inserted.count, 2, "out-of-window unknown-sender history preserves distinct IDs and raw types")
        XCTAssertTrue(inserted.allSatisfy { $0.senderType == "future-sender" && $0.typedSenderType == .unknown("future-sender") })
        XCTAssertFalse(vm.isLoadingHistory); XCTAssertFalse(vm.hasMoreHistory)
        XCTAssertEqual(channel.lastMessageText, "same"); XCTAssertEqual(vm.activeMessages.count, 3)
        vm.disconnect()
    }
}
