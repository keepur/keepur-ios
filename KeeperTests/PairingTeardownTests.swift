import XCTest
import SwiftData
@testable import Keepur

@MainActor
final class PairingTeardownTests: XCTestCase {
    private var savedHive: String?
    override func setUp() async throws {
        savedHive = UserDefaults.standard.string(forKey: "selectedHive")
        UserDefaults.standard.removeObject(forKey: "selectedHive")
    }
    override func tearDown() async throws {
        if let savedHive { UserDefaults.standard.set(savedHive, forKey: "selectedHive") }
        else { UserDefaults.standard.removeObject(forKey: "selectedHive") }
    }

    @MainActor
    private final class Fixture {
        final class Endpoint { var host = "old.unit.test" }
        let endpoint: Endpoint
        let credentials: FakeCredentialStore
        let chatFactory: FakeWebSocketTaskFactory
        let teamFactory: FakeWebSocketTaskFactory
        let capabilities: CapabilityManager
        let container: ModelContainer
        let context: ModelContext
        let chat: ChatViewModel
        let team: TeamViewModel
        init(bound: Bool = true) throws {
            let endpoint = Endpoint()
            let credentials = FakeCredentialStore(deviceId: "old-device")
            let chatFactory = FakeWebSocketTaskFactory(), teamFactory = FakeWebSocketTaskFactory()
            let capabilities = CapabilityManager()
            let schema = Schema([Session.self, Message.self, Workspace.self,
                                 TeamChannel.self, TeamMessage.self])
            let container = try ModelContainer(for: schema, configurations: [
                ModelConfiguration(isStoredInMemoryOnly: true)
            ])
            let context = ModelContext(container)
            let chat = ChatViewModel(socket: BeekeeperSocket(credentials: credentials,
                endpoint: { URL(string: "wss://\(endpoint.host)")! },
                taskFactory: { chatFactory.make(url: $0) }), credentials: credentials)
            let team = TeamViewModel(socket: BeekeeperSocket(credentials: credentials,
                endpoint: { URL(string: "wss://\(endpoint.host)")! },
                taskFactory: { teamFactory.make(url: $0) }), credentials: credentials)
            self.endpoint = endpoint
            self.credentials = credentials
            self.chatFactory = chatFactory
            self.teamFactory = teamFactory
            self.capabilities = capabilities
            self.container = container
            self.context = context
            self.chat = chat
            self.team = team
            if bound {
                ContentView.bindPairingTeardown(chat: chat, team: team,
                                               capabilities: capabilities)
            }
            capabilities._setHivesForTesting(["hive-1", "hive-2"])
            chat.configure(context: context)
            team.configure(context: context, capabilityManager: capabilities)
            chat.currentSessionId = "s1"
            chat.sessionStatuses["s1"] = .idle
            team.activeChannelId = "channel-1"
        }
        func close() { chat.disconnect(); team.disconnect() }
    }
    private let bytes = Data([1, 7, 42])
    private func settle() async { for _ in 0..<8 { await Task.yield() } }
    private func frames(_ task: FakeWebSocketTask) throws -> [[String: Any]] {
        try task.sentTexts.map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }
    private func payloads(_ task: FakeWebSocketTask) throws -> [[String: Any]] {
        try frames(task).filter { ["message", "image", "file"].contains($0["type"] as? String ?? "") }
    }
    private func rows(_ f: Fixture) throws -> [TeamMessage] {
        try f.context.fetch(FetchDescriptor<TeamMessage>())
    }
    private func syncChat(_ task: FakeWebSocketTask) async {
        task.deliver(#"{"type":"session_list","sessions":[{"sessionId":"s1","path":"/tmp/p","state":"idle","mode":"sessions"}]}"#)
        await settle()
    }
    private func populate(_ f: Fixture) async throws
        -> (chat: FakeWebSocketTask, team: FakeWebSocketTask,
            oldHandshake: () -> Void, oldAck: () -> Void) {
        f.chat.messageText = "old-chat"
        f.chat.pendingAttachment = AttachmentData(data: bytes, name: "old-chat.png", mimeType: "image/png")
        f.chat.sendText()
        let chatTask = try XCTUnwrap(f.chatFactory.latest)
        let savedHandshake = chatTask.savedHandshakeCompletion()
        chatTask.completeHandshake()
        await settle() // Do not send the list: the Chat attachment remains queued.
        f.capabilities.selectedHive = "hive-1"
        f.team.connectIfPossible()
        f.team.pendingAttachment = AttachmentData(data: bytes, name: "old-team.bin", mimeType: "application/octet-stream")
        f.team.sendMessage(text: "old-team-queued")
        // Keep hive-1's never-sent attachment queued while hive-2 has a live request map.
        f.capabilities.selectedHive = "hive-2"
        f.team.connectIfPossible()
        let teamTask = try XCTUnwrap(f.teamFactory.latest)
        teamTask.completeHandshake()
        await settle()
        f.team.sendMessage(text: "old-team-unacked")
        let request = try XCTUnwrap(try payloads(teamTask).first?["id"] as? String)
        let savedAck = teamTask.savedDelivery(#"{"type":"ack","id":"\#(request)"}"#)
        XCTAssertEqual(f.chat.pendingReasons.count, 1)
        XCTAssertEqual(f.chat.queuedAttachmentCountForTesting, 1)
        XCTAssertEqual(f.team.offlineMessageIds.count, 1)
        XCTAssertEqual(f.team.queuedAttachmentCountForTesting, 1)
        XCTAssertEqual(f.team.pendingMessageRequestCountForTesting, 1)
        return (chatTask, teamTask, savedHandshake, savedAck)
    }
    private func assertReset(_ f: Fixture) {
        XCTAssertEqual(f.chat.connectionState, .disconnected)
        XCTAssertEqual(f.team.connectionState, .disconnected)
        XCTAssertFalse(f.chat.isAuthenticated)
        XCTAssertFalse(f.team.isAuthenticated)
        XCTAssertFalse(f.credentials.isPaired)
        XCTAssertNil(f.credentials.deviceId)
        XCTAssertNil(f.credentials.deviceName)
        XCTAssertTrue(f.chat.pendingReasons.isEmpty)
        XCTAssertEqual(f.chat.queuedAttachmentCountForTesting, 0)
        XCTAssertTrue(f.team.offlineEntries.isEmpty)
        XCTAssertEqual(f.team.queuedAttachmentCountForTesting, 0)
        XCTAssertEqual(f.team.pendingMessageRequestCountForTesting, 0)
    }
    private func lifecycle(_ origin: String) async throws {
        let f = try Fixture()
        defer { f.close() }
        let old = try await populate(f)
        let oldRows = try rows(f)
        switch origin {
        case "manual": f.chat.unpair()
        case "capability": try XCTUnwrap(f.capabilities.onAuthFailure)()
        case "chat":
            old.chat.failReceive(closeCode: URLSessionWebSocketTask.CloseCode(rawValue: 4001)!)
            await settle()
        default:
            old.team.failReceive(closeCode: URLSessionWebSocketTask.CloseCode(rawValue: 4001)!)
            await settle()
        }
        // Manual/capability routes reach these assertions without a yield/view observer.
        assertReset(f)
        XCTAssertEqual(f.credentials.clearAllCalls, 1)
        old.oldHandshake(); old.oldAck()
        await settle()
        assertReset(f)
        XCTAssertTrue(oldRows.allSatisfy(\.pending), "stale ack must not mutate persisted rows")
        f.chat.unpair()
        f.team.resetForPairingTeardown()
        assertReset(f)
        XCTAssertEqual(f.credentials.clearAllCalls, 2, "Team reset must not notify recursively")

        f.credentials.token = "new-test-token"
        f.credentials.deviceId = "new-device"
        f.credentials.deviceName = "New Device"
        f.endpoint.host = "new.unit.test"
        ContentView.bindPairingTeardown(chat: f.chat, team: f.team, capabilities: f.capabilities)
        f.chat.isAuthenticated = true
        f.team.isAuthenticated = true
        f.chat.configure(context: f.context)
        f.team.configure(context: f.context, capabilityManager: f.capabilities)
        f.chat.currentSessionId = "s1"
        f.capabilities.selectedHive = "hive-2"
        f.team.connectIfPossible()
        let chatTask = try XCTUnwrap(f.chatFactory.latest)
        let teamTask = try XCTUnwrap(f.teamFactory.latest)
        for task in [chatTask, teamTask] {
            XCTAssertEqual(task.url.host, "new.unit.test")
            let query = URLComponents(url: task.url, resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(query?.first(where: { $0.name == "token" })?.value, "new-test-token")
            task.completeHandshake()
        }
        await settle()
        old.oldHandshake(); old.oldAck()
        await settle()
        await syncChat(chatTask)
        XCTAssertTrue(try payloads(chatTask).isEmpty)
        XCTAssertTrue(try payloads(teamTask).isEmpty)
        XCTAssertTrue(f.chat.isAuthenticated)
        XCTAssertTrue(f.team.isAuthenticated)
        XCTAssertEqual(f.credentials.clearAllCalls, 2)
        // Return to the same hive string that owned the old retained attachment too.
        f.capabilities.selectedHive = "hive-1"
        f.team.connectIfPossible()
        let returnedTeamTask = try XCTUnwrap(f.teamFactory.latest)
        returnedTeamTask.completeHandshake()
        await settle()
        XCTAssertTrue(try payloads(returnedTeamTask).isEmpty)
        f.chat.messageText = "fresh-chat"
        f.chat.sendText()
        f.team.sendMessage(text: "fresh-team")
        XCTAssertEqual(try payloads(chatTask).compactMap { $0["text"] as? String }, ["fresh-chat"])
        let fresh = try XCTUnwrap(try payloads(returnedTeamTask).first)
        XCTAssertEqual(fresh["text"] as? String, "fresh-team")
        XCTAssertEqual(try rows(f).first(where: { $0.text == "fresh-team" })?.senderId, "new-device")
        let freshId = try XCTUnwrap(fresh["id"] as? String)
        returnedTeamTask.deliver(#"{"type":"ack","id":"\#(freshId)"}"#)
        await settle()
        XCTAssertEqual(try rows(f).first(where: { $0.text == "fresh-team" })?.pending, false)
        XCTAssertEqual(f.team.pendingMessageRequestCountForTesting, 0)
        XCTAssertEqual(try rows(f).count, oldRows.count + 1, "history is retained")
        let freshRow = try XCTUnwrap(try rows(f).first { $0.text == "fresh-team" })
        let stableID = freshRow.id
        let oldDevice = TeamMessage(id: "same-text-old-device", channelId: "channel-1",
            senderId: "old-device", senderType: "person", senderName: "Old Device",
            text: "fresh-team", createdAt: freshRow.createdAt, pending: false)
        f.context.insert(oldDevice)
        try f.context.save()
        let historyRequest = try XCTUnwrap(try frames(returnedTeamTask).last {
            $0["type"] as? String == "history" && $0["channelId"] as? String == "channel-1"
                && $0["limit"] as? Int == 50
        }?["id"] as? String)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let reply: [String: Any] = ["type": "history", "id": historyRequest,
            "channelId": "channel-1", "hasMore": false, "messages": [[
                "id": "fresh-server", "senderId": "new-device", "senderType": "person",
                "senderName": "New Device", "text": "fresh-team",
                "createdAt": formatter.string(from: freshRow.createdAt)
            ]]]
        try await eventually("re-paired Team receiver armed") { returnedTeamTask.receiveRequested }
        let data = try JSONSerialization.data(withJSONObject: reply)
        returnedTeamTask.deliver(String(decoding: data, as: UTF8.self))
        try await eventually("re-paired history handled") { freshRow.serverId == "fresh-server" }
        XCTAssertEqual(freshRow.id, stableID)
        XCTAssertEqual(freshRow.senderId, "new-device")
        XCTAssertNil(oldDevice.serverId)
        XCTAssertEqual(oldDevice.senderId, "old-device")
        XCTAssertEqual(try rows(f).count, oldRows.count + 2)
        XCTAssertEqual(f.team.pendingMessageRequestCountForTesting, 0)
    }
    func testManualUnpairClearsBothVMsBeforeReturning() async throws { try await lifecycle("manual") }
    func testChat4001ClearsBothVMs() async throws { try await lifecycle("chat") }
    func testCapabilityUnauthorizedClearsBothVMsBeforeReturning() async throws { try await lifecycle("capability") }
    func testTeam4001ClearsBothVMsWithoutCallbackCycle() async throws { try await lifecycle("team") }

    func testUnboundTeam4001ReleasesAttachmentsAndMappingsIdempotently() async throws {
        let f = try Fixture(bound: false)
        defer { f.close() }
        let old = try await populate(f)
        old.team.failReceive(closeCode: URLSessionWebSocketTask.CloseCode(rawValue: 4001)!)
        await settle()
        XCTAssertEqual(f.team.connectionState, .disconnected)
        XCTAssertFalse(f.team.isAuthenticated)
        XCTAssertTrue(f.team.offlineEntries.isEmpty)
        XCTAssertEqual(f.team.queuedAttachmentCountForTesting, 0)
        XCTAssertEqual(f.team.pendingMessageRequestCountForTesting, 0)
        f.team.resetForPairingTeardown()
        XCTAssertEqual(f.credentials.clearAllCalls, 0)
        f.team.isAuthenticated = true
        for hive in ["hive-2", "hive-1"] {
            f.capabilities.selectedHive = hive
            f.team.connectIfPossible()
            let task = try XCTUnwrap(f.teamFactory.latest)
            task.completeHandshake()
            await settle()
            XCTAssertTrue(try payloads(task).isEmpty)
        }
    }
    func testOrdinaryAndDirectHiveSwitchPreserveQueuedAttachment() async throws {
        for explicitDisconnect in [true, false] {
            let f = try Fixture()
            defer { f.close() }
            f.context.insert(TeamChannel(id: "channel-1", type: "channel", name: "Original"))
            try f.context.save()
            f.capabilities.selectedHive = "hive-1"
            f.team.connectIfPossible()
            f.team.pendingAttachment = AttachmentData(data: bytes, name: "keep.bin", mimeType: "application/octet-stream")
            f.team.sendMessage(text: "keep")
            let original = f.team.offlineEntries
            XCTAssertEqual(original.count, 1)
            if explicitDisconnect { f.team.disconnect() }
            f.capabilities.selectedHive = "hive-2"
            f.team.connectIfPossible()
            let other = try XCTUnwrap(f.teamFactory.latest)
            other.completeHandshake()
            await settle()
            try await eventually("other hive receive armed") { other.receiveRequested }
            other.deliver(#"{"type":"channel_list","id":"b-list","channels":[{"id":"b-channel","type":"channel","name":"B","members":[]}]}"#)
            try await eventually("other hive list cleanup") { f.team.channels.map(\.id) == ["b-channel"] }
            XCTAssertEqual(try rows(f).map(\.id), original.map(\.localId))
            XCTAssertEqual(try rows(f).first?.channelId, "channel-1")
            XCTAssertNil(f.team.activeChannelId)
            XCTAssertEqual(f.team.offlineEntries, original)
            XCTAssertEqual(f.team.queuedAttachmentCountForTesting, 1)
            XCTAssertTrue(try payloads(other).isEmpty)
            f.capabilities.selectedHive = "hive-1"
            f.team.connectIfPossible()
            let returned = try XCTUnwrap(f.teamFactory.latest)
            returned.completeHandshake()
            await settle()
            let sent = try payloads(returned)
            XCTAssertEqual(sent.compactMap { $0["type"] as? String }, ["message", "file"])
            XCTAssertEqual(sent.last?["filename"] as? String, "keep.bin")
            XCTAssertEqual(sent.last?["data"] as? String, bytes.base64EncodedString())
            XCTAssertTrue(sent.allSatisfy { $0["channelId"] as? String == "channel-1" })
            XCTAssertTrue(f.team.offlineEntries.isEmpty)
            XCTAssertEqual(f.team.queuedAttachmentCountForTesting, 0)
            XCTAssertEqual(f.credentials.clearAllCalls, 0)
            XCTAssertTrue(f.chat.isAuthenticated)
            XCTAssertTrue(f.team.isAuthenticated)
        }
    }
}
