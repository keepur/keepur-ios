import XCTest
import SwiftData
@testable import Keepur

@MainActor
final class TeamMessagePersistenceTests: XCTestCase {
    func testDefaultsHistoryIdentityAndReopenedStableStamp() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "messages.store")
        func open() throws -> ModelContainer {
            let schema = Schema([TeamChannel.self, TeamMessage.self])
            return try ModelContainer(for: schema, configurations: [
                ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
            ])
        }
        do {
            let container = try open(), context = ModelContext(container)
            let live = TeamMessage(id: "local", channelId: "c", senderId: "agent",
                                   senderType: "future", senderName: "A", text: "same", pending: true)
            XCTAssertNil(live.serverId)
            let inserted = TeamMessage(id: "history", serverId: "history", channelId: "c",
                senderId: "agent", senderType: "agent", senderName: "A", text: "older")
            context.insert(live); context.insert(inserted)
            live.serverId = "server"; live.pending = false
            try context.save()
        }
        do {
            let container = try open(), context = ModelContext(container)
            let rows = try context.fetch(FetchDescriptor<TeamMessage>())
            XCTAssertEqual(rows.count, 2)
            let live = try XCTUnwrap(rows.first { $0.id == "local" })
            XCTAssertEqual(live.serverId, "server"); XCTAssertFalse(live.pending)
            XCTAssertEqual(live.senderType, "future"); XCTAssertEqual(live.text, "same")
            XCTAssertEqual(rows.first { $0.id == "history" }?.serverId, "history")
        }
    }
}
