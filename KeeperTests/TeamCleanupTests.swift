import XCTest
import SwiftData
@testable import Keepur

@MainActor
final class TeamCleanupTests: XCTestCase {
    func testEveryRemovalPathProtectsUnackedUnpendedRowsAndRetiresHistory() async throws {
        for removal in ["sync", "left", "archived"] {
            let h = try TeamTestHarness(); defer { h.close() }
            try await h.connect(); try await h.list(["c", "other"]); h.vm.selectChannel("c")
            let retired = try h.request("c")
            h.vm.sendMessage(text: "owned")
            let owned = try XCTUnwrap(h.rows().first { $0.text == "owned" })
            try await h.history(retired, channel: "c", rows: [h.wire("server-owned", text: "owned", sender: "device-old", date: owned.createdAt)])
            XCTAssertFalse(owned.pending); XCTAssertEqual(h.vm.pendingMessageRequestCountForTesting, 1)
            let ack = try XCTUnwrap(h.frames("message").last?["id"] as? String)
            try h.insert("unowned-pending", pending: true)
            try h.insert("unrelated", channel: "other")
            h.vm.fetchHistory(channelId: "c"); let oldFull = try h.request("c")
            let oldSeed = try h.request("c", limit: 1)
            if removal == "sync" { try await h.list(["other"]) }
            else {
                try await h.receive(["type": "channel_event", "channelId": "c", "event": removal,
                    "detail": ["memberId": "device-old"], "id": "event"])
            }
            XCTAssertNil(h.vm.activeChannelId); XCTAssertTrue(h.vm.activeMessages.isEmpty)
            XCTAssertFalse(h.vm.isLoadingHistory)
            XCTAssertEqual(Set(try h.rows().map(\.id)), [owned.id, "unrelated"])
            XCTAssertEqual(h.vm.channels.map(\.id), ["other"])
            try await h.history(oldFull, channel: "c", rows: [h.wire("late-full")])
            try await h.history(oldSeed, channel: "c", rows: [h.wire("late-seed")])
            XCTAssertEqual(try h.rows().count, 2)
            try await h.receive(["type": "ack", "id": ack])
            XCTAssertEqual(try h.rows().count, 2, "ack alone does not prune orphan history")
            try await h.list(["other"])
            XCTAssertEqual(try h.rows().map(\.id), ["unrelated"])
        }
    }
    func testForeignHiveCleanupPreservesAttachmentAndUnackedTextInOrder() async throws {
        let h = try TeamTestHarness(); defer { h.close() }
        h.context.insert(TeamChannel(id: "a-channel", type: "channel", name: "A"))
        try h.context.save(); h.vm.activeChannelId = "a-channel"
        h.begin()
        let bytes = Data([4, 5, 6])
        h.vm.pendingAttachment = AttachmentData(data: bytes, name: "keep.bin", mimeType: "application/octet-stream")
        h.vm.sendMessage(text: "first")
        let firstRow = try XCTUnwrap(h.rows().first)
        h.begin("hive-b"); try await h.finish()
        try await h.list(["b-channel"])
        XCTAssertEqual(h.vm.offlineEntries, [.init(localId: firstRow.id, hive: "hive-a")])
        XCTAssertEqual(h.vm.queuedAttachmentCountForTesting, 1)
        XCTAssertEqual(try h.rows().map(\.id), [firstRow.id])
        XCTAssertTrue(try h.frames().filter { ["message", "image", "file"].contains($0["type"] as? String ?? "") }.isEmpty)
        try await h.connect()
        let returnA = h.task
        XCTAssertEqual(try h.frames().suffix(2).compactMap { $0["type"] as? String }, ["message", "file"])
        XCTAssertEqual(try h.frames("file").last?["data"] as? String, bytes.base64EncodedString())
        XCTAssertEqual(try h.frames("file").last?["channelId"] as? String, "a-channel")
        let firstRequest = try XCTUnwrap(h.frames("message").last?["id"] as? String)
        try await h.list(["a-channel"]); h.vm.selectChannel("a-channel")
        h.vm.sendMessage(text: "second")
        let secondRow = try XCTUnwrap(h.rows().first { $0.text == "second" })
        XCTAssertGreaterThanOrEqual(secondRow.createdAt, firstRow.createdAt)
        try await h.history(h.request("a-channel"), channel: "a-channel", rows: [
            h.wire("server-first", text: "first", sender: "device-old", date: firstRow.createdAt)
        ])
        XCTAssertFalse(firstRow.pending)
        try await h.connect("hive-b") // connected switch: socket must emit goingAway, not manual normal close.
        XCTAssertEqual(returnA.lastCloseCode, .goingAway)
        try await h.list(["b-channel"])
        XCTAssertEqual(h.vm.offlineMessageIds, [firstRow.id, secondRow.id])
        XCTAssertTrue(h.vm.offlineEntries.allSatisfy { $0.hive == "hive-a" })
        XCTAssertEqual(Set(try h.rows().map(\.id)), [firstRow.id, secondRow.id])
        XCTAssertTrue(try h.frames("message").isEmpty)
        try await h.connect()
        XCTAssertEqual(try h.frames("message").compactMap { $0["text"] as? String }, ["first", "second"])
        XCTAssertTrue(try h.frames("message").allSatisfy { $0["channelId"] as? String == "a-channel" })
        XCTAssertNotEqual(try h.frames("message").first?["id"] as? String, firstRequest)
        XCTAssertTrue(try h.frames("file").isEmpty, "already-submitted attachments are not replayed")
        XCTAssertTrue(h.vm.offlineEntries.isEmpty)
    }
    func testForeignHiveSameChannelHistoryDoesNotStampOrUnpendQueuedRow() async throws {
        let h = try TeamTestHarness(); defer { h.close() }
        h.vm.activeChannelId = "shared"
        h.begin(); h.vm.sendMessage(text: "same")
        let row = try XCTUnwrap(h.rows().first)
        try await h.connect("hive-b")
        try await h.list(["shared"])
        try await h.history(h.request("shared"), channel: "shared", rows: [
            h.wire("b-server", sender: "device-old", date: row.createdAt)
        ])
        XCTAssertNil(row.serverId); XCTAssertTrue(row.pending)
        XCTAssertEqual(h.vm.offlineEntries, [.init(localId: row.id, hive: "hive-a")])
        XCTAssertEqual(try h.rows().count, 2)
        XCTAssertEqual(try h.rows().first { $0.id == "b-server" }?.serverId, "b-server")
    }
    func testInventoryAndMessageFetchFailuresSkipUnsafeSweepWithoutChangingBanner() async throws {
        var inventoryFails = false, messagesFail = false, inventoryCalls = 0, messageCalls = 0
        let h = try TeamTestHarness(channelInventoryOperation: { context, descriptor in
            inventoryCalls += 1
            if inventoryFails { throw NSError(domain: "Inventory", code: 1) }
            return try context.fetch(descriptor)
        }, cleanupMessageFetchOperation: { context, descriptor in
            messageCalls += 1
            if messagesFail { throw NSError(domain: "Messages", code: 2) }
            return try context.fetch(descriptor)
        }); defer { h.close() }
        try await h.connect(); try await h.list(["c"])
        try h.insert("orphan", channel: "absent")
        h.vm.lastError = UserFacingError("existing")
        let error = h.vm.lastError?.id, before = messageCalls
        inventoryFails = true
        try await h.list(["new"])
        XCTAssertEqual(messageCalls, before, "failed inventory cannot authorize deletion or sweep")
        XCTAssertEqual(try h.rows().map(\.id), ["orphan"])
        XCTAssertNotNil(h.vm.channels.first { $0.id == "new" })
        XCTAssertEqual(h.vm.lastError?.id, error)
        inventoryFails = false; messagesFail = true
        try await h.list(["new"])
        XCTAssertEqual(try h.rows().map(\.id), ["orphan"])
        XCTAssertEqual(h.vm.channels.map(\.id), ["new"])
        XCTAssertEqual(h.vm.lastError?.id, error)
        messagesFail = false
        try await h.list(["new"])
        XCTAssertTrue(try h.rows().isEmpty); XCTAssertEqual(inventoryCalls, 4)
        XCTAssertEqual(h.vm.lastError?.id, error)
    }
    func testCleanupSaveFailureKeepsDeletionAndLoadContinuation() async throws {
        var fail = false
        let h = try TeamTestHarness(saveOperation: { context in
            if fail { throw NSError(domain: "CleanupSave", code: 1) }
            try context.save()
        }); defer { h.close() }
        try await h.connect(); try await h.list(["c", "other"])
        try h.insert("delete"); h.vm.selectChannel("c")
        fail = true; try await h.list(["other"])
        XCTAssertTrue(try h.rows().isEmpty); XCTAssertEqual(h.vm.channels.map(\.id), ["other"])
        XCTAssertNil(h.vm.activeChannelId); XCTAssertFalse(h.vm.isLoadingHistory)
        XCTAssertEqual(h.vm.lastError?.text, "Couldn't save. Your last change may not be kept.")
    }
    func testRejectedResendStopsPassAndRetainsLaterAttachment() async throws {
        let h = try TeamTestHarness(); defer { h.close() }
        h.vm.activeChannelId = "c"; h.begin()
        h.vm.sendMessage(text: "first")
        h.vm.pendingAttachment = AttachmentData(data: Data([9]), name: "later.bin", mimeType: "application/octet-stream")
        h.vm.sendMessage(text: "later")
        let original = h.vm.offlineMessageIds
        let current = h.task
        current.onSend = { [weak h] text in
            guard let h, let data = text.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["type"] as? String == "history" else { return }
            h.vm.disconnect()
        }
        current.completeHandshake()
        try await eventually("bookkeeping disconnected before resend") { h.vm.connectionState == .disconnected }
        let retiredHistory = try h.request("c", on: current)
        XCTAssertFalse(h.vm.isLoadingHistory)
        XCTAssertEqual(h.vm.offlineMessageIds, original)
        XCTAssertEqual(h.vm.queuedAttachmentCountForTesting, 1)
        XCTAssertTrue(try h.frames("message").isEmpty)
        current.onSend = nil
        try await h.connect()
        XCTAssertNotEqual(try h.request("c"), retiredHistory)
        XCTAssertTrue(h.vm.isLoadingHistory)
        XCTAssertEqual(try h.frames("message").compactMap { $0["text"] as? String }, ["first", "later"])
        XCTAssertEqual(try h.frames("file").last?["data"] as? String, Data([9]).base64EncodedString())
    }
    func testAttachmentOwnershipSurvivesForeignHistoryThenOriginalHiveStampAndCleanup() async throws {
        let h = try TeamTestHarness(); defer { h.close() }
        h.vm.activeChannelId = "shared"; h.begin()
        let bytes = Data([7, 7, 1])
        h.vm.pendingAttachment = AttachmentData(data: bytes, name: "owned.bin", mimeType: "application/octet-stream")
        h.vm.sendMessage(text: "owned")
        let row = try XCTUnwrap(h.rows().first)
        let original = TeamMessageSnapshot(id: row.id, serverId: row.serverId, channelId: row.channelId,
            senderId: row.senderId, senderType: row.typedSenderType, senderName: row.senderName,
            text: row.text, threadId: row.threadId, createdAt: row.createdAt, pending: row.pending)
        try await h.connect("hive-b")
        try await h.list(["shared"])
        try await h.history(h.request("shared"), channel: "shared", rows: [
            h.wire("foreign", text: "owned", sender: "device-old", date: row.createdAt),
            h.wire(row.id, text: "foreign collision", sender: "different-device", type: "system",
                   date: row.createdAt.addingTimeInterval(60))
        ])
        XCTAssertNil(row.serverId); XCTAssertTrue(row.pending)
        let retained = try XCTUnwrap(h.rows().first { $0.id == original.id })
        XCTAssertEqual(TeamMessageSnapshot(id: retained.id, serverId: retained.serverId,
            channelId: retained.channelId, senderId: retained.senderId, senderType: retained.typedSenderType,
            senderName: retained.senderName, text: retained.text, threadId: retained.threadId,
            createdAt: retained.createdAt, pending: retained.pending), original)
        XCTAssertEqual(Set(try h.rows().map(\.id)), [original.id, "foreign"])
        XCTAssertEqual(retained.channelId, "shared")
        XCTAssertEqual(h.vm.queuedAttachmentCountForTesting, 1)
        XCTAssertEqual(h.vm.offlineEntries, [.init(localId: row.id, hive: "hive-a")])
        try await h.list([])
        XCTAssertEqual(try h.rows().map(\.id), [row.id])
        try await h.connect()
        XCTAssertEqual(try h.frames("file").last?["data"] as? String, bytes.base64EncodedString())
        XCTAssertEqual(h.vm.pendingMessageRequestCountForTesting, 1)
        try await h.list(["shared"]); h.vm.selectChannel("shared")
        try await h.history(h.request("shared"), channel: "shared", rows: [
            h.wire("own-server", text: "owned", sender: "device-old", date: row.createdAt)
        ])
        XCTAssertEqual(row.serverId, "own-server"); XCTAssertFalse(row.pending)
        try await h.list([])
        XCTAssertEqual(try h.rows().map(\.id), [row.id])
        XCTAssertEqual(h.vm.pendingMessageRequestCountForTesting, 1)
        h.vm.disconnect()
        XCTAssertEqual(h.vm.offlineEntries, [.init(localId: row.id, hive: "hive-a")])
    }
}
