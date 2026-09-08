import XCTest
import SwiftData
@testable import Keepur

@MainActor
final class PersistenceTests: XCTestCase {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Session.self, Message.self, Workspace.self,
                           TeamChannel.self, TeamMessage.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    func testRealFetchSaveAndSuccessfulEmptyFetch() throws {
        let store = try container(), context = ModelContext(store)
        context.autosaveEnabled = false
        var failure: Error? = NSError(domain: "old", code: 1)
        XCTAssertTrue(context.fetchOrEmpty(FetchDescriptor<Session>(), "test.empty", failure: &failure).isEmpty)
        XCTAssertNil(failure)
        context.insert(Session(id: "one", path: "/one"))
        XCTAssertNil(context.saveReporting("test.realSave"))
        let fresh = ModelContext(store)
        let rows = fresh.fetchOrEmpty(FetchDescriptor<Session>(), "test.realFetch")
        XCTAssertEqual(rows.map(\.id), ["one"]); XCTAssertEqual(rows.first?.path, "/one")
    }

    func testFetchFailureReturnsOriginalAndNextSuccessResetsOutput() throws {
        let store = try container(), context = ModelContext(store)
        let sentinel = NSError(domain: "PersistenceTests", code: 444,
                               userInfo: [NSLocalizedDescriptionKey: "do not log stored data"])
        var failure: Error?, attempts = 0
        let failed = context.fetchOrEmpty(FetchDescriptor<Session>(), "test.throwFetch", failure: &failure) { _ in
            attempts += 1
            throw sentinel
        }
        XCTAssertTrue(failed.isEmpty); XCTAssertTrue((failure as NSError?) === sentinel)
        XCTAssertEqual(attempts, 1)
        let empty = context.fetchOrEmpty(FetchDescriptor<Session>(), "test.emptyAfterError", failure: &failure) { _ in
            attempts += 1
            return []
        }
        XCTAssertTrue(empty.isEmpty); XCTAssertNil(failure); XCTAssertEqual(attempts, 2)
        let row = Session(id: "row", path: "/row")
        let result = context.fetchOrEmpty(FetchDescriptor<Session>(), "test.rows", failure: &failure) { _ in
            attempts += 1
            return [row]
        }
        XCTAssertEqual(result.map(\.id), ["row"]); XCTAssertNil(failure); XCTAssertEqual(attempts, 3)
    }

    func testSaveAttemptsOnceAndReturnsOriginalWithoutThrowing() throws {
        let store = try container(), context = ModelContext(store)
        let sentinel = NSError(domain: "PersistenceTests", code: 445)
        var attempts = 0
        let failure = context.saveReporting("test.throwSave") {
            attempts += 1
            throw sentinel
        }
        XCTAssertTrue((failure as NSError?) === sentinel); XCTAssertEqual(attempts, 1)
        XCTAssertNil(context.saveReporting("test.successSave") { attempts += 1 })
        XCTAssertEqual(attempts, 2)
    }

    func testUniqueSessionIDIsSuccessfulUpsertOnSupportedRuntime() throws {
        let store = try container(), context = ModelContext(store)
        context.autosaveEnabled = false
        context.insert(Session(id: "unique", path: "/first", name: "First"))
        XCTAssertNil(context.saveReporting("test.insertUnique"))
        context.insert(Session(id: "unique", path: "/second", name: "Second"))
        XCTAssertNil(context.saveReporting("test.upsertUnique"))
        let rows = ModelContext(store).fetchOrEmpty(FetchDescriptor<Session>(), "test.fetchUpsert")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.id, "unique")
        XCTAssertEqual(rows.first?.path, "/second")
        XCTAssertEqual(rows.first?.name, "Second")
    }

    func testStoredAccessorsRoundTripWithoutRewritingUnknownValues() throws {
        let store = try container(), context = ModelContext(store)
        context.autosaveEnabled = false
        let roles: [MessageRole] = [.user, .assistant, .system, .tool, .unknown]
        for role in roles {
            context.insert(Message(id: role.rawValue, sessionId: "s", text: "text", role: role.rawValue))
        }
        context.insert(Message(id: "legacy", sessionId: "s", text: "text", role: "future-role"))
        let senders: [SenderType] = [.person, .agent, .system, .unknown("future-sender"), .unknown("")]
        for (index, sender) in senders.enumerated() {
            context.insert(TeamMessage(id: "sender-\(index)", channelId: "c", senderId: "other",
                                       senderType: sender.wireValue, senderName: "Other", text: "text"))
        }
        let kinds: [ChannelKind] = [.channel, .dm, .unknown("future-kind"), .unknown("")]
        for (index, kind) in kinds.enumerated() {
            context.insert(TeamChannel(id: "kind-\(index)", type: kind.wireValue, name: "raw"))
        }
        XCTAssertNil(context.saveReporting("test.accessors"))
        let fresh = ModelContext(store)
        let messages = fresh.fetchOrEmpty(FetchDescriptor<Message>(), "test.roles")
        for role in roles {
            let row = try XCTUnwrap(messages.first { $0.id == role.rawValue })
            XCTAssertEqual(row.typedRole, role); XCTAssertEqual(row.role, role.rawValue)
        }
        let legacy = try XCTUnwrap(messages.first { $0.id == "legacy" })
        XCTAssertNil(legacy.typedRole); XCTAssertEqual(legacy.role, "future-role")
        XCTAssertEqual(messages.first { $0.id == "unknown" }?.typedRole, .unknown)
        let team = fresh.fetchOrEmpty(FetchDescriptor<TeamMessage>(), "test.senders")
        for (index, expected) in senders.enumerated() {
            let row = try XCTUnwrap(team.first { $0.id == "sender-\(index)" })
            XCTAssertEqual(row.typedSenderType, expected); XCTAssertEqual(row.senderType, expected.wireValue)
        }
        let channels = fresh.fetchOrEmpty(FetchDescriptor<TeamChannel>(), "test.kinds")
        for (index, expected) in kinds.enumerated() {
            let row = try XCTUnwrap(channels.first { $0.id == "kind-\(index)" })
            XCTAssertEqual(row.kind, expected); XCTAssertEqual(row.type, expected.wireValue)
            XCTAssertEqual(row.displayName, expected == .channel ? "#raw" : "raw")
        }
    }
}
