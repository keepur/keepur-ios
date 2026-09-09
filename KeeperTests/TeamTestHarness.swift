import XCTest
import SwiftData
@testable import Keepur

@MainActor
final class TeamTestHarness {
    let container: ModelContainer
    let context: ModelContext
    let credentials = FakeCredentialStore(deviceId: "device-old")
    let factory = FakeWebSocketTaskFactory()
    let capability = CapabilityManager()
    let socket: BeekeeperSocket
    var vm: TeamViewModel!
    let savedHive: String?
    var task: FakeWebSocketTask { factory.latest! }
    let date = Date(timeIntervalSince1970: 1_700_000_000)

    init(saveOperation: @escaping (ModelContext) throws -> Void = { try $0.save() }) throws {
        savedHive = UserDefaults.standard.string(forKey: "selectedHive")
        UserDefaults.standard.removeObject(forKey: "selectedHive")
        let schema = Schema([Session.self, Message.self, Workspace.self, TeamChannel.self, TeamMessage.self])
        container = try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        context = ModelContext(container)
        context.autosaveEnabled = false
        let factory = self.factory
        socket = BeekeeperSocket(credentials: credentials, endpoint: { URL(string: "wss://unit.test")! },
                                 taskFactory: { factory.make(url: $0) })
        vm = TeamViewModel(socket: socket, credentials: credentials, lastErrorAutoClear: .seconds(30),
                           saveOperation: saveOperation)
        vm.configure(context: context, capabilityManager: capability)
        capability._setHivesForTesting(["hive-a", "hive-b"])
        capability.selectedHive = "hive-a"
    }
    func close() {
        factory.made.forEach { $0.onSend = nil }
        vm?.disconnect()
        socket.disconnect()
        vm = nil
        if let savedHive { UserDefaults.standard.set(savedHive, forKey: "selectedHive") }
        else { UserDefaults.standard.removeObject(forKey: "selectedHive") }
    }
    func begin(_ hive: String = "hive-a") {
        capability.selectedHive = hive
        vm.connectIfPossible()
    }
    func finish() async throws {
        let current = task
        try await eventually("handshake armed") { current.handshakeRequested }
        current.completeHandshake()
        try await eventually("Team connected and receiving") {
            self.vm.connectionState == .connected && current.receiveRequested
        }
    }
    func connect(_ hive: String = "hive-a") async throws { begin(hive); try await finish() }
    func receive(_ object: [String: Any], on selected: FakeWebSocketTask? = nil) async throws {
        let current = selected ?? task
        try await eventually("Team receive armed") { current.receiveRequested }
        let data = try JSONSerialization.data(withJSONObject: object)
        current.deliver(String(decoding: data, as: UTF8.self))
        try await eventually("Team receive rearmed after synchronous handler") { current.receiveRequested }
    }
    func frames(_ type: String? = nil, on selected: FakeWebSocketTask? = nil) throws -> [[String: Any]] {
        try (selected ?? task).sentTexts.map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }.filter { type == nil || $0["type"] as? String == type }
    }
    func request(_ channel: String, limit: Int = 50, on selected: FakeWebSocketTask? = nil) throws -> String {
        try XCTUnwrap(frames("history", on: selected).last {
            $0["channelId"] as? String == channel && $0["limit"] as? Int == limit
        }?["id"] as? String)
    }
    func list(_ ids: [String]) async throws {
        try await receive(["type": "channel_list", "id": UUID().uuidString,
            "channels": ids.map { ["id": $0, "type": "channel", "name": $0, "members": ["device-old"]] }])
    }
    func history(_ request: String, channel: String, rows: [[String: Any]], more: Bool = false) async throws {
        try await receive(["type": "history", "id": request, "channelId": channel, "messages": rows, "hasMore": more])
    }
    func wire(_ id: String, text: String = "same", sender: String = "agent",
              type: String = "agent", date: Date? = nil) -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return ["id": id, "senderId": sender, "senderType": type, "senderName": "Wire",
                "text": text, "createdAt": formatter.string(from: date ?? self.date), "threadId": "wire-thread"]
    }
    func rows() throws -> [TeamMessage] { try context.fetch(FetchDescriptor<TeamMessage>()) }
    func channel(_ id: String) throws -> TeamChannel {
        try XCTUnwrap(context.fetch(FetchDescriptor<TeamChannel>()).first { $0.id == id })
    }
    @discardableResult
    func insert(_ id: String, channel: String = "c", text: String = "same", sender: String = "agent",
                pending: Bool = false, server: String? = nil, date: Date? = nil) throws -> TeamMessage {
        let row = TeamMessage(id: id, serverId: server, channelId: channel, threadId: "local-thread",
            senderId: sender, senderType: "future-local", senderName: "Local", text: text,
            createdAt: date ?? self.date, pending: pending)
        context.insert(row); try context.save()
        return row
    }
}
