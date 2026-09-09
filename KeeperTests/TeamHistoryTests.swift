import XCTest
import SwiftData
@testable import Keepur

@MainActor
final class TeamHistoryTests: XCTestCase {
    func testSeedAndFullBothOrdersKeepTheirOwnState() async throws {
        for seedFirst in [true, false] {
            let h = try TeamTestHarness(); defer { h.close() }
            try await h.connect(); try await h.list(["a", "b"])
            let seed = try h.request("a", limit: 1)
            h.vm.selectChannel("a")
            let full = try h.request("a")
            XCTAssertNotEqual(seed, full); XCTAssertTrue(h.vm.isLoadingHistory)
            let newest = h.wire("newest", text: "preview", date: h.date.addingTimeInterval(20))
            let page = [h.wire("oldest", text: "page"), h.wire("middle", text: "middle", date: h.date.addingTimeInterval(10))]
            if seedFirst {
                try await h.history(seed, channel: "a", rows: [newest], more: false)
                XCTAssertTrue(h.vm.isLoadingHistory); XCTAssertTrue(h.vm.hasMoreHistory)
                XCTAssertNil(try h.channel("a").lastServerMessageId); XCTAssertTrue(try h.rows().isEmpty)
            }
            try await h.history(full, channel: "a", rows: Array(page.reversed()), more: true)
            XCTAssertFalse(h.vm.isLoadingHistory); XCTAssertTrue(h.vm.hasMoreHistory)
            XCTAssertEqual(try h.channel("a").lastServerMessageId, "oldest")
            XCTAssertEqual(Set(try h.rows().map(\.id)), ["oldest", "middle"])
            if !seedFirst { try await h.history(seed, channel: "a", rows: [newest]) }
            XCTAssertEqual(try h.channel("a").lastMessageText, "preview")
            XCTAssertEqual(try h.channel("a").lastMessageAt, h.date.addingTimeInterval(20))
            XCTAssertNil(h.vm.lastLiveMessageId)
            XCTAssertFalse(h.vm.isLoadingHistory); XCTAssertTrue(h.vm.hasMoreHistory)
            XCTAssertEqual(try h.channel("a").lastServerMessageId, "oldest")
            XCTAssertEqual(try h.rows().count, 2)
        }
    }
    func testSelectionWrongChannelDuplicateAndRetiredResponses() async throws {
        let h = try TeamTestHarness(); defer { h.close() }
        try await h.connect(); try await h.list(["a", "b"])
        h.vm.selectChannel("a"); let old = try h.request("a")
        h.vm.selectChannel("b"); let current = try h.request("b")
        XCTAssertTrue(h.vm.isLoadingHistory)
        try await h.history(old, channel: "a", rows: [h.wire("old")])
        try await h.history(current, channel: "a", rows: [h.wire("wrong")])
        XCTAssertTrue(h.vm.isLoadingHistory); XCTAssertTrue(try h.rows().isEmpty)
        XCTAssertNil(try h.channel("a").lastMessageText)
        try await h.history(current, channel: "b", rows: [h.wire("valid")])
        XCTAssertFalse(h.vm.isLoadingHistory); XCTAssertEqual(try h.rows().map(\.id), ["valid"])
        try await h.history(current, channel: "b", rows: [h.wire("duplicate", text: "bad")], more: true)
        XCTAssertEqual(try h.rows().map(\.id), ["valid"]); XCTAssertFalse(h.vm.hasMoreHistory)
        XCTAssertEqual(try h.channel("b").lastMessageText, "same")
    }
    func testPreviewWrongChannelDoesNotConsumeSeed() async throws {
        let h = try TeamTestHarness(); defer { h.close() }
        try await h.connect(); try await h.list(["a", "b"])
        let seed = try h.request("a", limit: 1)
        try await h.history(seed, channel: "b", rows: [h.wire("wrong")])
        XCTAssertNil(try h.channel("a").lastMessageText); XCTAssertNil(try h.channel("b").lastMessageText)
        try await h.history(seed, channel: "a", rows: [h.wire("right", text: "right")])
        XCTAssertEqual(try h.channel("a").lastMessageText, "right"); XCTAssertTrue(try h.rows().isEmpty)
    }
    func testCursorOrderFullyDeduplicatedPageAndEmptyResponses() async throws {
        for reverse in [false, true] {
            let h = try TeamTestHarness(); defer { h.close() }
            try await h.connect(); try await h.list(["c", "seed"])
            h.vm.selectChannel("c")
            let page = [h.wire("b"), h.wire("a"), h.wire("z", date: h.date.addingTimeInterval(1))]
            try await h.history(h.request("c"), channel: "c", rows: reverse ? Array(page.reversed()) : page, more: true)
            XCTAssertEqual(try h.channel("c").lastServerMessageId, "a")
            XCTAssertEqual(try h.channel("c").lastMessageAt, h.date.addingTimeInterval(1))
            let channel = try h.channel("c")
            channel.lastServerMessageId = "stale"
            h.vm.fetchHistory(channelId: "c")
            XCTAssertEqual(try h.frames("history").last?["before"] as? String, "stale")
            try await h.history(h.request("c"), channel: "c", rows: page, more: true)
            XCTAssertEqual(try h.rows().count, 3); XCTAssertEqual(try h.channel("c").lastServerMessageId, "a")
            h.vm.fetchHistory(channelId: "c")
            try await h.history(h.request("c"), channel: "c", rows: [], more: false)
            XCTAssertFalse(h.vm.isLoadingHistory); XCTAssertFalse(h.vm.hasMoreHistory)
            XCTAssertEqual(try h.channel("c").lastServerMessageId, "a")
            try await h.history(h.request("seed", limit: 1), channel: "seed", rows: [])
            XCTAssertNil(try h.channel("seed").lastMessageText); XCTAssertNil(try h.channel("seed").lastMessageAt)
        }
    }
    func testOlderPreviewCannotReplaceLiveTextAndTruncatesTogether() async throws {
        let h = try TeamTestHarness(); defer { h.close() }
        try await h.connect(); try await h.list(["c"])
        let seed = try h.request("c", limit: 1)
        let liveText = String(repeating: "x", count: 120)
        try await h.receive(["type": "message", "channelId": "c", "agentId": "agent", "agentName": "A", "text": liveText])
        let timestamp = try XCTUnwrap(h.channel("c").lastMessageAt)
        h.vm.selectChannel("c")
        try await h.history(seed, channel: "c", rows: [h.wire("old-seed", text: "old seed")])
        try await h.history(h.request("c"), channel: "c", rows: [h.wire("old-page", text: "old page")])
        XCTAssertEqual(try h.channel("c").lastMessageText, String(repeating: "x", count: 100))
        XCTAssertEqual(try h.channel("c").lastMessageAt, timestamp)
    }
    func testOfflineMissingChannelErrorAndReconnectRetirement() async throws {
        let h = try TeamTestHarness(); defer { h.close() }
        h.vm.selectChannel("missing")
        XCTAssertFalse(h.vm.isLoadingHistory)
        try await h.connect()
        let first = try h.request("missing")
        XCTAssertNil(try h.frames("history").last?["before"])
        h.vm.fetchHistory(channelId: "other")
        XCTAssertEqual(try h.frames("history").count, 1)
        try await h.receive(["type": "error", "message": "server refused"])
        XCTAssertFalse(h.vm.isLoadingHistory); XCTAssertEqual(h.vm.lastError?.text, "server refused")
        try await h.history(first, channel: "missing", rows: [h.wire("late-error")])
        XCTAssertTrue(try h.rows().isEmpty)
        h.vm.fetchHistory(channelId: "missing")
        let second = try h.request("missing")
        h.vm.disconnect(); XCTAssertFalse(h.vm.isLoadingHistory)
        try await h.connect()
        let third = try h.request("missing")
        XCTAssertNotEqual(second, third); XCTAssertNil(try h.frames("history").last?["before"])
        try await h.history(second, channel: "missing", rows: [h.wire("late-connection")])
        XCTAssertTrue(h.vm.isLoadingHistory); XCTAssertTrue(try h.rows().isEmpty)
        try await h.history(third, channel: "missing", rows: [])
        XCTAssertFalse(h.vm.isLoadingHistory)
        try await h.connect("hive-b")
        try await h.history(third, channel: "missing", rows: [h.wire("late-hive")])
        XCTAssertTrue(try h.rows().isEmpty); XCTAssertTrue(h.vm.isLoadingHistory)

        // Establish real pagination before reconnecting; a missing channel cannot prove reset.
        try await h.connect()
        try await h.list(["c", "seed"]); h.vm.selectChannel("c")
        let completed = try h.request("c")
        try await h.history(completed, channel: "c", rows: [
            h.wire("a-page", text: "A preview")
        ], more: false)
        let channel = try h.channel("c"), seedChannel = try h.channel("seed")
        XCTAssertEqual(channel.lastServerMessageId, "a-page")
        XCTAssertFalse(h.vm.hasMoreHistory); XCTAssertFalse(h.vm.isLoadingHistory)
        h.vm.disconnect(); XCTAssertFalse(h.vm.isLoadingHistory)
        try await h.connect()
        let outstandingFull = try h.request("c")
        XCTAssertNotEqual(outstandingFull, completed)
        XCTAssertEqual(try h.frames("history").count, 1)
        XCTAssertEqual(try h.frames("history").last?["limit"] as? Int, 50)
        XCTAssertNil(try h.frames("history").last?["before"])
        XCTAssertNil(channel.lastServerMessageId)
        XCTAssertTrue(h.vm.hasMoreHistory); XCTAssertTrue(h.vm.isLoadingHistory)

        // Leave both A request kinds unanswered, then switch directly while connected.
        try await h.list(["c", "seed"])
        let outstandingSeed = try h.request("seed", limit: 1), departing = h.task
        XCTAssertNotEqual(outstandingFull, outstandingSeed)
        try await h.connect("hive-b")
        XCTAssertEqual(departing.lastCloseCode, .goingAway)
        let currentB = try h.request("c")
        XCTAssertNotEqual(currentB, outstandingFull); XCTAssertNotEqual(currentB, outstandingSeed)
        XCTAssertNil(try h.frames("history").last?["before"])
        let savedRows = Set(try h.rows().map(\.id))
        let savedActiveRows = h.vm.activeMessages.map(\.id)
        let savedText = channel.lastMessageText, savedDate = channel.lastMessageAt
        let savedCursor = channel.lastServerMessageId
        XCTAssertEqual(savedRows, ["a-page"])
        XCTAssertEqual(savedText, "A preview"); XCTAssertEqual(savedDate, h.date)
        XCTAssertNil(savedCursor); XCTAssertTrue(h.vm.hasMoreHistory)
        for (request, channelId) in [(outstandingFull, "c"), (outstandingSeed, "seed")] {
            try await h.history(request, channel: channelId, rows: [
                h.wire("late-" + channelId, text: "stale " + channelId,
                       date: h.date.addingTimeInterval(60))
            ], more: false)
            XCTAssertEqual(Set(try h.rows().map(\.id)), savedRows)
            XCTAssertEqual(h.vm.activeMessages.map(\.id), savedActiveRows)
            XCTAssertEqual(channel.lastMessageText, savedText)
            XCTAssertEqual(channel.lastMessageAt, savedDate)
            XCTAssertEqual(channel.lastServerMessageId, savedCursor)
            XCTAssertNil(seedChannel.lastMessageText); XCTAssertNil(seedChannel.lastMessageAt)
            XCTAssertNil(seedChannel.lastServerMessageId)
            XCTAssertTrue(h.vm.hasMoreHistory); XCTAssertTrue(h.vm.isLoadingHistory)
        }
        try await h.history(currentB, channel: "c", rows: [
            h.wire("b-page", text: "B accepted", date: h.date.addingTimeInterval(20))
        ], more: false)
        XCTAssertEqual(Set(try h.rows().map(\.id)), ["a-page", "b-page"])
        XCTAssertEqual(channel.lastMessageText, "B accepted")
        XCTAssertEqual(channel.lastMessageAt, h.date.addingTimeInterval(20))
        XCTAssertEqual(channel.lastServerMessageId, "b-page")
        XCTAssertFalse(h.vm.hasMoreHistory); XCTAssertFalse(h.vm.isLoadingHistory)
    }
    func testRealLiveOwnAndSystemMergeIsSilentAndKeepsUnackedOwnership() async throws {
        let h = try TeamTestHarness(); defer { h.close() }
        try await h.connect(); try await h.list(["c"]); h.vm.selectChannel("c")
        h.vm.sendMessage(text: "own")
        try await h.receive(["type": "message", "channelId": "c", "agentId": "agent", "agentName": "A", "text": "live"])
        try await h.receive(["type": "message", "agentId": "system", "agentName": "System", "text": "system"])
        let rows = try h.rows(), bubbleIds = Set(rows.map(\.id)), lastLive = h.vm.lastLiveMessageId
        XCTAssertEqual(rows.first { $0.text == "system" }?.senderType, "agent")
        let originalTypes = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.senderType) })
        let originalNames = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.senderName) })
        let originalDates = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.createdAt) })
        let originalThreads = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.threadId) })
        let page = rows.map { h.wire("server-" + $0.text, text: $0.text, sender: $0.senderId, type: "future-wire", date: $0.createdAt) }
        try await h.history(h.request("c"), channel: "c", rows: page)
        for row in rows {
            XCTAssertEqual(row.senderType, originalTypes[row.id])
            XCTAssertEqual(row.senderName, originalNames[row.id])
            XCTAssertEqual(row.createdAt, originalDates[row.id])
            XCTAssertEqual(row.threadId, originalThreads[row.id] ?? nil)
        }
        XCTAssertEqual(Set(try h.rows().map(\.id)), bubbleIds)
        XCTAssertTrue(rows.allSatisfy { $0.serverId == "server-" + $0.text && !$0.pending })
        XCTAssertEqual(h.vm.pendingMessageRequestCountForTesting, 1)
        XCTAssertEqual(h.vm.lastLiveMessageId, lastLive); XCTAssertNil(h.vm.speechManager)
        h.vm.disconnect()
        XCTAssertEqual(h.vm.offlineEntries.count, 1)
        XCTAssertEqual(h.vm.offlineEntries[0].hive, "hive-a")
        try await h.connect()
        XCTAssertEqual(try h.frames("message").map { $0["text"] as? String }, ["own"])
    }
    func testHistorySaveFailureKeepsStampLoadingAndErrorIdentity() async throws {
        var fail = false
        let h = try TeamTestHarness(saveOperation: { context in
            if fail { throw NSError(domain: "HistorySave", code: 1) }
            try context.save()
        }); defer { h.close() }
        try await h.connect(); try await h.list(["c"]); h.vm.selectChannel("c")
        let local = try h.insert("local", pending: true)
        fail = true
        try await h.history(h.request("c"), channel: "c", rows: [h.wire("server")])
        XCTAssertEqual(local.serverId, "server"); XCTAssertFalse(local.pending)
        XCTAssertFalse(h.vm.isLoadingHistory); XCTAssertFalse(h.vm.hasMoreHistory)
        XCTAssertEqual(h.vm.lastError?.text, "Couldn't save. Your last change may not be kept.")
        let error = h.vm.lastError?.id
        fail = false; h.vm.fetchHistory(channelId: "c")
        try await h.history(h.request("c"), channel: "c", rows: [])
        XCTAssertEqual(h.vm.lastError?.id, error)
        h.vm.joinChannel(channelId: "not-found")
        XCTAssertEqual(h.vm.lastError?.id, error)
    }
    func testHistoryFetchFailureUsesEmptyInputAndKeepsExistingError() async throws {
        var fail = true, calls = 0
        let h = try TeamTestHarness(historyMessageFetchOperation: { context, descriptor in
            calls += 1
            if fail { throw NSError(domain: "HistoryFetch", code: 1) }
            return try context.fetch(descriptor)
        }); defer { h.close() }
        try await h.connect(); try await h.list(["c"]); h.vm.selectChannel("c")
        h.vm.lastError = UserFacingError("retained error")
        let error = h.vm.lastError?.id
        try await h.history(h.request("c"), channel: "c", rows: [h.wire("server")])
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(try h.rows().map(\.id), ["server"])
        XCTAssertEqual(try h.rows().first?.serverId, "server")
        XCTAssertFalse(h.vm.isLoadingHistory); XCTAssertFalse(h.vm.hasMoreHistory)
        XCTAssertEqual(h.vm.lastError?.id, error)
        fail = false; h.vm.fetchHistory(channelId: "c")
        try await h.history(h.request("c"), channel: "c", rows: [h.wire("server")])
        XCTAssertEqual(calls, 2); XCTAssertEqual(try h.rows().count, 1)
        XCTAssertEqual(h.vm.lastError?.id, error)
    }
}
