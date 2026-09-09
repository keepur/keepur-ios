import XCTest
import SwiftData
import Combine
@testable import Keepur

@MainActor
final class ChatPersistenceTests: XCTestCase {
    private let copy = "Couldn't save. Your last change may not be kept."

    func testFailedOptimisticSaveKeepsOfflinePayloadAndInputContinuation() async throws {
        let sentinel = NSError(domain: "ChatPersistenceTests", code: 1)
        var attempts = 0, fail = true
        let h = try ChatTestHarness(saveOperation: { context in
            attempts += 1
            if fail { throw sentinel }
            try context.save()
        })
        defer { h.close() }; h.context.autosaveEnabled = false
        let attachment = AttachmentData(data: Data([4, 4, 4]), name: "a.bin", mimeType: "application/octet-stream")
        let id = try h.send("", attachment: attachment)
        XCTAssertEqual(attempts, 1); XCTAssertEqual(h.vm.lastError?.text, copy)
        let errorID = try XCTUnwrap(h.vm.lastError?.id)
        XCTAssertEqual(h.vm.messageText, ""); XCTAssertNil(h.vm.pendingAttachment)
        XCTAssertEqual(h.vm.pendingReasons[id], .offline); XCTAssertEqual(h.vm.queuedAttachmentCountForTesting, 1)
        XCTAssertTrue(try h.frames("message").isEmpty); XCTAssertTrue(try h.frames("file").isEmpty)
        let row = try XCTUnwrap(h.messages().first { $0.id == id })
        XCTAssertEqual(row.text, "a.bin"); XCTAssertEqual(row.attachmentData, attachment.data)
        fail = false
        try await h.connect()
        try await h.list([("a", "idle", "sessions")])
        XCTAssertEqual(h.vm.lastError?.id, errorID, "successful sync save must not replace or clear error")
        XCTAssertEqual(try h.frames("file").count, 1); XCTAssertTrue(try h.frames("message").isEmpty)
        XCTAssertEqual(try h.frames("file").first?["data"] as? String, attachment.data.base64EncodedString())
        XCTAssertNil(h.vm.pendingReasons[id]); XCTAssertEqual(h.vm.queuedAttachmentCountForTesting, 0)
    }

    func testFailedSaveStillSendsWhenConnectedAndConditionalAppendReports() async throws {
        let sentinel = NSError(domain: "ChatPersistenceTests", code: 2)
        var fail = false, attempts = 0
        let h = try ChatTestHarness(saveOperation: { context in
            attempts += 1
            if fail { throw sentinel }
            try context.save()
        })
        defer { h.close() }; h.context.autosaveEnabled = false
        try await h.connect(); try await h.list([("a", "idle", "sessions")])
        fail = true
        let start = attempts, id = try h.send("direct")
        XCTAssertEqual(attempts, start + 1); XCTAssertEqual(h.vm.lastError?.text, copy)
        XCTAssertNil(h.vm.pendingReasons[id]); XCTAssertEqual(h.vm.messageText, "")
        XCTAssertEqual(try h.frames("message").compactMap { $0["text"] as? String }, ["direct"])
        fail = false
        try await h.chunk("first")
        let streamID = try XCTUnwrap(h.messages("a", role: "assistant").first?.id)
        let before = attempts
        let previousErrorID = try XCTUnwrap(h.vm.lastError?.id)
        fail = true
        try await h.chunk(" second")
        XCTAssertEqual(attempts, before + 1)
        XCTAssertEqual(h.vm.lastError?.text, copy)
        XCTAssertNotEqual(try XCTUnwrap(h.vm.lastError?.id), previousErrorID,
                          "conditional append must assign a new persistence error")
        let rows = try h.messages("a", role: "assistant")
        XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows.first?.id, streamID)
        XCTAssertEqual(rows.first?.text, "first second")
    }

    func testSuccessfulSaveLeavesExistingErrorTimerIdentityAndDeadline() async throws {
        let h = try ChatTestHarness(lastErrorAutoClear: .seconds(2))
        defer { h.close() }; try await h.connect()
        try await h.receive(["type": "error", "message": "server error"])
        let original = try XCTUnwrap(h.vm.lastError?.id)
        try await Task.sleep(for: .seconds(1))
        _ = try h.send("saved")
        XCTAssertEqual(h.vm.lastError?.id, original)
        try await eventually("original error deadline", timeout: .milliseconds(1500)) { h.vm.lastError == nil }
    }

    func testFailedFullListPublishesWithoutSyncMutationAndFallbackStillWins() async throws {
        let sentinel = NSError(domain: "ChatPersistenceTests", code: 3)
        var saves = 0, fetches = 0
        let h = try ChatTestHarness(saveOperation: { context in saves += 1; try context.save() },
                                   sessionFetchOperation: { _, _ in fetches += 1; throw sentinel })
        defer { h.close() }; h.context.autosaveEnabled = false
        h.context.insert(Session(id: "kept", path: "/kept", name: "Kept")); try h.context.save()
        h.vm.sessionStatuses["a"] = .idle
        h.vm.sessionStatuses["busy"] = .toolRunning
        h.vm.sessionToolNames["busy"] = "Read"
        let first = try h.send("head"), tail = try h.send("tail")
        let held = try h.send("held", id: "busy")
        h.vm.currentSessionId = "kept"; h.vm.currentPath = "/kept"
        let beforeReasons = h.vm.pendingReasons, beforeStatuses = h.vm.sessionStatuses
        try await h.connect()
        let beforeSave = saves, beforeReceived = h.received
        var published = 0
        let observer = h.vm.incoming.sink { frame in
            if case .sessionList = frame {
                published += 1
                XCTAssertEqual(h.vm.serverSessions.map(\.sessionId), ["new", "a", "busy"])
                XCTAssertEqual(h.vm.sessionStatuses, beforeStatuses)
            }
        }
        defer { observer.cancel() }
        try await h.list([("new", "idle", "sessions"), ("a", "idle", "sessions"), ("busy", "session_ended", "sessions")])
        XCTAssertEqual(fetches, 1); XCTAssertEqual(saves, beforeSave)
        XCTAssertEqual(published, 1); XCTAssertEqual(h.received, beforeReceived + 1)
        XCTAssertEqual(h.vm.pendingReasons, beforeReasons); XCTAssertEqual(h.vm.sessionStatuses, beforeStatuses)
        XCTAssertEqual(h.vm.sessionToolNames["busy"], "Read"); XCTAssertNil(h.vm.lastError)
        XCTAssertEqual(h.vm.currentSessionId, "kept"); XCTAssertEqual(h.vm.currentPath, "/kept")
        XCTAssertEqual(try h.sessions().map(\.id), ["kept"])
        XCTAssertEqual(try h.sessions().first?.isStale, false)
        XCTAssertTrue(try h.frames("message").isEmpty)
        try await eventually("five-second fallback retains eligibility", timeout: .seconds(6)) {
            try h.frames("message").count == 1
        }
        XCTAssertEqual(try h.frames("message").first?["text"] as? String, "head")
        XCTAssertNil(h.vm.pendingReasons[first]); XCTAssertEqual(h.vm.pendingReasons[tail], .busy)
        XCTAssertEqual(h.vm.pendingReasons[held], .busy)
        XCTAssertEqual(h.vm.sessionStatuses["busy"], .toolRunning)
        XCTAssertEqual(saves, beforeSave, "fallback is not a new persistence path")
    }

    func testSuccessfulEmptyFullListFetchOwnsReconnectAndInsertsOnlyExactSessions() async throws {
        var fetches = 0
        let h = try ChatTestHarness(sessionFetchOperation: { context, descriptor in
            fetches += 1
            return try context.fetch(descriptor)
        })
        defer { h.close() }; h.context.autosaveEnabled = false
        let first = try h.send("head"), tail = try h.send("tail")
        XCTAssertTrue(try h.sessions().isEmpty)
        try await h.connect()
        try await h.list([("a", "idle", "sessions"), ("c", "busy", "concierge"), ("future", "idle", "new-mode")])
        XCTAssertEqual(fetches, 1); XCTAssertEqual(try h.sessions().map(\.id), ["a"])
        let awaiting = try XCTUnwrap(Mirror(reflecting: h.vm).children.first {
            $0.label == "awaitingPostReconnectSync"
        }?.value as? Bool)
        XCTAssertFalse(awaiting, "successful empty fetch consumes the reconnect pass")
        let fallback = try XCTUnwrap(Mirror(reflecting: h.vm).children.first {
            $0.label == "postReconnectFlushFallback"
        }?.value)
        XCTAssertEqual(Mirror(reflecting: fallback).displayStyle, .optional)
        XCTAssertTrue(Mirror(reflecting: fallback).children.isEmpty,
                      "successful empty fetch cancels and clears fallback ownership")
        XCTAssertEqual(h.vm.serverSessions.count, 3); XCTAssertEqual(h.vm.sessionStatuses["c"], .busy)
        XCTAssertNil(h.vm.pendingReasons[first]); XCTAssertEqual(h.vm.pendingReasons[tail], .busy)
        XCTAssertEqual(try h.frames("message").count, 1)
        try await Task.sleep(for: .milliseconds(5200))
        XCTAssertEqual(try h.frames("message").count, 1, "consumed fallback cannot release a second head")
        try await h.list([("a", "idle", "sessions"), ("c", "busy", "concierge"), ("future", "idle", "new-mode")])
        XCTAssertEqual(try h.frames("message").count, 1, "repeated idle list gives no additional release")
        try await h.status("idle")
        XCTAssertEqual(try h.frames("message").compactMap { $0["text"] as? String }, ["head", "tail"])
        try await h.receive(["type": "session_info", "sessionId": "future", "path": "/future", "mode": "new-mode"])
        XCTAssertTrue(try h.sessions().contains { $0.id == "future" }, "unknown info keeps ordinary path")
    }

    func testSuccessfulEmptyClearAndReplacementKeepNestedSaveBoundaries() async throws {
        var saves = 0
        let h = try ChatTestHarness(saveOperation: { context in saves += 1; try context.save() })
        defer { h.close() }; h.context.autosaveEnabled = false
        try await h.connect()
        h.context.insert(Session(id: "a", path: "/work", name: "Named")); try h.context.save()
        h.vm.currentSessionId = "a"
        try await h.status("busy"); try await h.approval("approval")
        let beforeClear = saves
        try await h.receive(["type": "context_cleared", "oldSessionId": "a", "sessionId": "a"])
        XCTAssertEqual(saves, beforeClear + 1, "successful empty Message fetch still saves")
        XCTAssertEqual(h.vm.currentSessionId, "a"); XCTAssertEqual(try h.sessions().first?.name, "Named")
        XCTAssertNil(h.vm.sessionStatuses["a"]); XCTAssertNil(h.vm.pendingApprovals["a"])
        let beforeReplace = saves
        try await h.receive(["type": "session_replaced", "oldSessionId": "a", "newSessionId": "b", "path": "/work"])
        XCTAssertEqual(saves, beforeReplace + 4, "upsert, empty migration, old delete, workspace")
        XCTAssertEqual(try h.sessions().map(\.id), ["b"]); XCTAssertEqual(try h.sessions().first?.name, "Named")
        XCTAssertEqual(h.vm.currentSessionId, "b"); XCTAssertEqual(h.vm.currentPath, "/work")
        XCTAssertTrue(try h.messages().isEmpty)
    }

    func testListedTerminalClearsBusyRuntimeWithoutIdleReleaseOrRowDeletion() async throws {
        let h = try ChatTestHarness(watchdog: .milliseconds(100))
        defer { h.close() }; try await h.connect()
        try await h.list([("a", "idle", "sessions"), ("other", "idle", "sessions")])
        h.vm.currentSessionId = "a"; h.vm.currentPath = "/a"
        try await h.status("tool_running", tool: "Read")
        try await h.chunk("completed", final: true); try await h.chunk("partial")
        try await h.approval("ua"); try await h.approval("uo", id: "other")
        let oldIDs = Set(try h.messages("a", role: "assistant").map(\.id))
        let queued = try h.send("never", attachment: AttachmentData(data: Data([9]), name: "a.bin", mimeType: "application/octet-stream"))
        try await h.list([("a", "session_ended", "sessions"), ("other", "idle", "sessions")])
        XCTAssertNil(h.vm.sessionStatuses["a"]); XCTAssertNil(h.vm.sessionToolNames["a"])
        XCTAssertNil(h.vm.pendingApprovals["a"]); XCTAssertNotNil(h.vm.pendingApprovals["other"])
        let completed = try XCTUnwrap(Mirror(reflecting: h.vm).children.first {
            $0.label == "lastCompletedMessageIds"
        }?.value as? [String: String])
        XCTAssertNil(completed["a"], "terminal also clears completed-message speech bookkeeping")
        XCTAssertNil(h.vm.pendingReasons[queued]); XCTAssertEqual(h.vm.queuedAttachmentCountForTesting, 0)
        XCTAssertEqual(h.vm.currentSessionId, "a"); XCTAssertEqual(h.vm.currentPath, "/a")
        XCTAssertEqual(try h.sessions().first { $0.id == "a" }?.isStale, false)
        XCTAssertTrue(try h.frames("message").isEmpty); XCTAssertTrue(try h.frames("file").isEmpty)
        let queries = try h.frames("list_sessions").count
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(try h.frames("list_sessions").count, queries, "terminal does not re-arm watch")
        try await h.status("idle")
        XCTAssertTrue(try h.frames("message").isEmpty, "no retained queued terminal payload")
        try await h.chunk("fresh")
        let fresh = try XCTUnwrap(h.messages("a", role: "assistant").first { $0.text == "fresh" })
        XCTAssertFalse(oldIDs.contains(fresh.id))
        // A fresh direct send remains eligible after the terminated queue was cleared.
        _ = try h.send("after")
        XCTAssertEqual(try h.frames("message").compactMap { $0["text"] as? String }, ["after"])
    }

    func testListedTerminalDuringReconnectCannotFlushAndClearsReleaseOnlyState() async throws {
        let h = try ChatTestHarness(); defer { h.close() }
        _ = try h.send("first"); let tail = try h.send("never")
        try await h.connect()
        try await h.status("idle") // releases first before the initial list; both release sets now contain a.
        try await h.status("thinking")
        try await h.list([("a", "session_ended", "sessions")])
        XCTAssertNil(h.vm.pendingReasons[tail]); XCTAssertNil(h.vm.sessionStatuses["a"])
        XCTAssertEqual(try h.frames("message").compactMap { $0["text"] as? String }, ["first"])
        _ = try h.send("fresh")
        XCTAssertEqual(try h.frames("message").compactMap { $0["text"] as? String }, ["first", "fresh"])
        XCTAssertTrue(h.vm.pendingReasons.isEmpty)
    }

    func testUnknownNonIdleStatusIsActiveWatchedAndNeverReleasesPendingWork() async throws {
        let h = try ChatTestHarness(watchdog: .milliseconds(80))
        defer { h.close() }; try await h.connect()
        try await h.list([("a", "mystery", "sessions")])
        XCTAssertEqual(h.vm.statusFor("a"), .unknown("mystery")); XCTAssertTrue(h.vm.statusFor("a").isActive)
        let pending = try h.send("held")
        XCTAssertEqual(h.vm.pendingReasons[pending], .busy)
        let count = try h.frames("list_sessions").count
        try await eventually("unknown status is watched") { try h.frames("list_sessions").count > count }
        XCTAssertEqual(h.vm.statusFor("a"), .unknown("mystery"))
        XCTAssertTrue(try h.frames("message").isEmpty); XCTAssertEqual(h.vm.pendingReasons[pending], .busy)
        try await h.list([("a", "another-mystery", "sessions")])
        XCTAssertEqual(h.vm.statusFor("a"), .unknown("mystery"), "busy/busy preserves detail")
        XCTAssertTrue(try h.frames("message").isEmpty)
    }
}
