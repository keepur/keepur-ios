import XCTest
import SwiftData
import Combine
@testable import Keepur

@MainActor
final class ChatViewModelTests: XCTestCase {
    func testStreamingAssemblySingleFinalAndRoundBoundary() async throws {
        let h = try ChatTestHarness(); defer { h.close() }; try await h.connect()
        try await h.chunk("one")
        let id = try XCTUnwrap(h.messages("a", role: "assistant").first?.id)
        try await h.chunk(" two"); try await h.chunk(" three"); try await h.chunk("!", final: true)
        let rows = try h.messages("a", role: "assistant")
        XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows.first?.id, id)
        XCTAssertEqual(rows.first?.text, "one two three!")
        try await h.chunk("single", id: "b", final: true)
        XCTAssertEqual(try h.messages("b", role: "assistant").map(\.text), ["single"])
        try await h.chunk("before", id: "c")
        let before = try XCTUnwrap(h.messages("c").first?.id)
        try await h.status("thinking", id: "c"); try await h.chunk("after", id: "c")
        let split = try h.messages("c", role: "assistant")
        XCTAssertEqual(Set(split.map(\.text)), ["before", "after"])
        XCTAssertEqual(split.count, 2); XCTAssertEqual(split.filter { $0.id == before }.count, 1)
    }
    func testBusyQueueCancelAndOtherSessionIsolation() async throws {
        let h = try ChatTestHarness(); defer { h.close() }; try await h.connect()
        try await h.list([("a", "idle", "sessions"), ("b", "idle", "sessions")])
        try await h.status("busy"); try await h.status("busy", id: "b")
        let a = try h.send("A"), tail = try h.send("A2")
        let bytes = Data([1, 2, 3])
        let b = try h.send("B", id: "b", attachment: AttachmentData(data: bytes, name: "b.bin", mimeType: "application/octet-stream"))
        XCTAssertEqual(h.vm.pendingReasons, [a: .busy, tail: .busy, b: .busy])
        XCTAssertTrue(try h.frames("message").isEmpty)
        h.vm.cancelCurrentOperation(for: "b")
        XCTAssertEqual(h.vm.pendingReasons, [a: .busy, tail: .busy])
        XCTAssertEqual(h.vm.queuedAttachmentCountForTesting, 0)
        try await h.status("idle"); XCTAssertEqual(try h.frames("message").compactMap { $0["text"] as? String }, ["A"])
        try await h.status("idle"); XCTAssertEqual(try h.frames("message").compactMap { $0["text"] as? String }, ["A", "A2"])
    }
    func testSessionEndedCleansSeededStateWithoutTouchingOtherSession() async throws {
        let h = try ChatTestHarness(watchdog: .milliseconds(50)); defer { h.close() }; try await h.connect()
        try await h.list([("a", "idle", "sessions"), ("b", "idle", "sessions")])
        try await h.status("tool_running", tool: "shell")
        try await h.chunk("old-stream"); try await h.approval("ua"); try await h.approval("ub", id: "b")
        let queued = try h.send("never", attachment: AttachmentData(data: Data([4]), name: "a.bin", mimeType: "application/octet-stream"))
        XCTAssertEqual(h.vm.pendingReasons[queued], .busy); XCTAssertEqual(h.vm.queuedAttachmentCountForTesting, 1)
        XCTAssertEqual(h.vm.sessionToolNames["a"], "shell"); XCTAssertNotNil(h.vm.pendingApprovals["a"])
        let old = try XCTUnwrap(h.messages("a", role: "assistant").first?.id)
        try await h.status("session_ended")
        XCTAssertNil(h.vm.sessionStatuses["a"]); XCTAssertNil(h.vm.sessionToolNames["a"])
        XCTAssertNil(h.vm.pendingApprovals["a"]); XCTAssertNotNil(h.vm.pendingApprovals["b"])
        XCTAssertNil(h.vm.pendingReasons[queued]); XCTAssertEqual(h.vm.queuedAttachmentCountForTesting, 0)
        let queries = try h.frames("list_sessions").count
        try await Task.sleep(for: .milliseconds(140))
        XCTAssertEqual(try h.frames("list_sessions").count, queries); XCTAssertTrue(try h.frames("message").isEmpty)
        try await h.chunk("fresh-stream")
        let rows = try h.messages("a", role: "assistant")
        XCTAssertEqual(rows.count, 2); XCTAssertNotEqual(rows.first { $0.text == "fresh-stream" }?.id, old)
    }
    func testOfflineHandshakeRequiresIdleListAndBusyListHolds() async throws {
        for busy in [false, true] {
            let h = try ChatTestHarness(); defer { h.close() }
            let a = try h.send("A"), b = try h.send("B")
            XCTAssertEqual(h.vm.pendingReasons, [a: .offline, b: .offline])
            try await h.connect(); XCTAssertTrue(try h.frames("message").isEmpty)
            try await h.list([("a", busy ? "busy" : "idle", "sessions")])
            XCTAssertEqual(try h.frames("message").count, busy ? 0 : 1)
            XCTAssertEqual(h.vm.pendingReasons[b], .busy)
            XCTAssertEqual(h.vm.pendingReasons[a], busy ? .busy : nil)
        }
    }
    func testClearHandoffKeepsOldUntilMatchingPathHasReplacementRow() async throws {
        let h = try ChatTestHarness(); defer { h.close() }; try await h.connect()
        h.context.insert(Session(id: "a", path: "/work", name: "Named")); try h.context.save()
        h.vm.currentSessionId = "a"; h.vm.currentPath = "/work"
        try await h.status("busy"); try await h.chunk("old"); try await h.approval("u")
        let pending = try h.send("queued")
        try await h.receive(["type": "context_cleared", "oldSessionId": "a", "sessionId": "a"])
        XCTAssertEqual(h.vm.currentSessionId, "a"); XCTAssertEqual(try h.sessions().map(\.id), ["a"])
        XCTAssertTrue(try h.messages("a").isEmpty); XCTAssertNil(h.vm.pendingReasons[pending])
        XCTAssertNil(h.vm.pendingApprovals["a"]); XCTAssertNil(h.vm.sessionStatuses["a"])
        try await h.receive(["type": "session_info", "sessionId": "unrelated", "path": "/elsewhere"])
        XCTAssertNotNil(try h.sessions().first { $0.id == "a" })
        var observed = false
        let observer = h.vm.incoming.sink { frame in
            if case .sessionInfo("new", "/work", _) = frame {
                observed = true
                XCTAssertEqual(h.vm.currentSessionId, "new")
                XCTAssertEqual(try? h.sessions().first { $0.id == "new" }?.name, "Named")
                XCTAssertNil(try? h.sessions().first { $0.id == "a" })
            }
        }
        defer { observer.cancel() }
        try await h.receive(["type": "session_info", "sessionId": "new", "path": "/work"])
        XCTAssertTrue(observed); XCTAssertEqual(h.vm.currentPath, "/work")
    }
    func testReplacementMigratesHistoryStreamApprovalQueueAndWatchdog() async throws {
        let h = try ChatTestHarness(watchdog: .milliseconds(50)); defer { h.close() }; try await h.connect()
        h.context.insert(Session(id: "a", path: "/work", name: "Named")); try h.context.save()
        try await h.list([("a", "idle", "sessions")])
        try await h.status("tool_running", tool: "shell"); try await h.chunk("before")
        try await h.approval("u"); let queued = try h.send("queued")
        let streamId = try XCTUnwrap(h.messages("a", role: "assistant").first?.id)
        try await h.receive(["type": "session_replaced", "oldSessionId": "a", "newSessionId": "new", "path": "/work"])
        XCTAssertEqual(h.vm.currentSessionId, "new"); XCTAssertNil(h.vm.sessionStatuses["a"])
        XCTAssertEqual(h.vm.sessionStatuses["new"], .toolRunning); XCTAssertEqual(h.vm.sessionToolNames["new"], "shell")
        XCTAssertNotNil(h.vm.pendingApprovals["new"]); XCTAssertNil(h.vm.pendingApprovals["a"])
        XCTAssertEqual(try h.sessions().map(\.id), ["new"]); XCTAssertEqual(try h.sessions().first?.name, "Named")
        let migrated = try h.messages("new"); XCTAssertFalse(migrated.isEmpty)
        XCTAssertTrue(try h.messages("a").isEmpty); XCTAssertEqual(h.vm.pendingReasons[queued], .busy)
        try await h.chunk(" after", id: "new")
        XCTAssertEqual(try h.messages("new", role: "assistant").first?.id, streamId)
        XCTAssertEqual(try h.messages("new", role: "assistant").first?.text, "before after")
        let queries = try h.frames("list_sessions").count
        try await eventually("replacement remains watched") { try h.frames("list_sessions").count > queries }
        try await h.status("idle", id: "new")
        XCTAssertEqual(try h.frames("message").compactMap { $0["sessionId"] as? String }, ["new"])
    }
    func testFullListFiltersOnlyTableAndKeepsConciergeSelection() async throws {
        for legacy in [false, true] {
            let h = try ChatTestHarness(); defer { h.close() }; try await h.connect()
            h.context.insert(Session(id: "old", path: "/old"))
            h.context.insert(Session(id: "c", path: "/c")); try h.context.save()
            if legacy { h.vm.registerConciergeSession("c") }
            h.vm.currentSessionId = "c"; h.vm.currentPath = "/c"
            try await h.status("tool_running", id: "c", tool: "shell")
            let queued = try h.send("held", id: "c")
            try await h.list([("normal", "idle", "sessions"), ("c", "busy", legacy ? "sessions" : "concierge")])
            XCTAssertEqual(h.vm.serverSessions.count, 2); XCTAssertEqual(h.vm.currentSessionId, "c")
            XCTAssertEqual(h.vm.sessionStatuses["c"], .toolRunning); XCTAssertEqual(h.vm.pendingReasons[queued], .busy)
            let rows = try h.sessions(); XCTAssertEqual(Set(rows.map(\.id)), ["old", "normal"])
            XCTAssertEqual(rows.first { $0.id == "old" }?.isStale, true)
            XCTAssertTrue(try h.workspaces().isEmpty)
            h.vm.currentSessionId = "old"
            try await h.list([("normal", "idle", "sessions"), ("c", "busy", legacy ? "sessions" : "concierge")])
            XCTAssertNil(h.vm.currentSessionId); XCTAssertTrue(try h.frames("message").isEmpty)
        }
    }
    func testErrorRoutingKeepsUnscopedBannerAndScopedBubbleSeparate() async throws {
        let h = try ChatTestHarness(); defer { h.close() }; try await h.connect()
        h.vm.currentSessionId = "a"; h.vm.currentPath = "/a"
        try await h.receive(["type": "error", "message": "unscoped"])
        XCTAssertNotNil(h.vm.lastError); XCTAssertTrue(try h.messages(role: "system").isEmpty)
        h.vm.lastError = nil
        try await h.receive(["type": "error", "message": "scoped", "sessionId": "b"])
        XCTAssertNil(h.vm.lastError); XCTAssertEqual(try h.messages("b", role: "system").map(\.text), ["Error: scoped"])
        XCTAssertEqual(h.vm.currentSessionId, "a"); XCTAssertTrue(try h.messages("a").isEmpty)
    }
    func testApprovalIsolationFallbackAndAddressedRemoval() async throws {
        let h = try ChatTestHarness(); defer { h.close() }; try await h.connect()
        h.vm.currentSessionId = "a"; h.vm.currentPath = "/a"
        try await h.approval("ua"); try await h.approval("ub", id: "b")
        XCTAssertEqual(h.vm.currentSessionId, "a"); XCTAssertEqual(h.vm.currentPath, "/a")
        XCTAssertEqual(h.vm.pendingApprovals["a"]?.id, "ua"); XCTAssertEqual(h.vm.pendingApprovals["b"]?.id, "ub")
        h.vm.approve(toolUseId: "ub", sessionId: "b")
        XCTAssertNil(h.vm.pendingApprovals["b"]); XCTAssertNotNil(h.vm.pendingApprovals["a"])
        try await h.approval("fallback", id: nil); XCTAssertEqual(h.vm.pendingApprovals["a"]?.id, "fallback")
        h.vm.deny(toolUseId: "fallback", sessionId: "a"); XCTAssertTrue(h.vm.pendingApprovals.isEmpty)
        h.vm.currentSessionId = nil
        let before = try h.frames("deny").count
        try await h.approval("unscoped", id: nil)
        XCTAssertEqual(try h.frames("deny").count, before + 1); XCTAssertTrue(h.vm.pendingApprovals.isEmpty)
        XCTAssertEqual(try h.frames("deny").last?["toolUseId"] as? String, "unscoped")
    }
    func testWatchdogQueriesRearmsAndOnlyIdleReplyReleases() async throws {
        let h = try ChatTestHarness(watchdog: .milliseconds(50)); defer { h.close() }; try await h.connect()
        h.vm.registerConciergeSession("c")
        try await h.list([("c", "idle", "concierge")])
        try await h.status("tool_running", id: "c", tool: "shell"); try await h.approval("u", id: "c")
        let a = try h.send("A", id: "c"), b = try h.send("B", id: "c")
        let initial = try h.frames("list_sessions").count
        try await eventually("first watchdog query") { try h.frames("list_sessions").count > initial }
        XCTAssertEqual(h.vm.sessionStatuses["c"], .toolRunning); XCTAssertEqual(h.vm.sessionToolNames["c"], "shell")
        XCTAssertNotNil(h.vm.pendingApprovals["c"]); XCTAssertEqual(h.vm.pendingReasons, [a: .busy, b: .busy])
        XCTAssertTrue(try h.frames("message").isEmpty)
        let first = try h.frames("list_sessions").count
        try await eventually("no-reply watch remains armed") { try h.frames("list_sessions").count > first }
        try await h.list([("c", "busy", "concierge")])
        let reset = try h.frames("list_sessions").count
        XCTAssertEqual(h.vm.sessionStatuses["c"], .toolRunning)
        try await eventually("busy reply rearms") { try h.frames("list_sessions").count > reset }
        try await h.list([("c", "idle", "concierge")])
        XCTAssertEqual(h.vm.sessionStatuses["c"], .idle); XCTAssertNil(h.vm.sessionToolNames["c"])
        XCTAssertEqual(try h.frames("message").compactMap { $0["text"] as? String }, ["A"])
        XCTAssertEqual(h.vm.pendingReasons, [b: .busy])
        try await h.list([("c", "idle", "concierge")])
        let idleQueries = try h.frames("list_sessions").count
        try await Task.sleep(for: .milliseconds(140))
        XCTAssertEqual(try h.frames("list_sessions").count, idleQueries)
        XCTAssertEqual(try h.frames("message").count, 1)
    }
}

@MainActor
extension ChatViewModelTests {
    private func reflectedSpeechStorage(_ vm: ChatViewModel,
                                        file: StaticString = #filePath,
                                        line: UInt = #line) throws -> SpeechManager? {
        let child = try XCTUnwrap(
            Mirror(reflecting: vm).children.first { $0.label == "storedSpeech" },
            "storedSpeech reflection field is missing", file: file, line: line
        )
        return try XCTUnwrap(
            child.value as? Optional<SpeechManager>,
            "storedSpeech reflection field has unexpected type", file: file, line: line
        )
    }

    private func reflectedStringSet(_ field: String, in vm: ChatViewModel,
                                    file: StaticString = #filePath,
                                    line: UInt = #line) -> Set<String> {
        guard let value = Mirror(reflecting: vm).descendant(field) as? Set<String> else {
            XCTFail("\(field) reflection field is missing", file: file, line: line)
            return []
        }
        return value
    }

    func testDecodedMulticastReadsPostHandlerStateOncePerFrame() async throws {
        let h = try ChatTestHarness(); defer { h.close() }; try await h.connect()
        h.vm.currentSessionId = "a"; h.vm.currentPath = "/a"
        var firstEvents: [String] = [], secondEvents: [String] = []
        let inspect: (WSIncoming) -> String = { frame in
            switch frame {
            case .sessionInfo(let id, let path, _):
                XCTAssertEqual(id, "n"); XCTAssertEqual(path, "/n")
                XCTAssertEqual(h.vm.currentSessionId, "n"); XCTAssertEqual(h.vm.currentPath, "/n")
                XCTAssertNotNil(try? h.sessions().first { $0.id == "n" })
                return "info"
            case .toolApproval(let use, _, _, let id):
                XCTAssertEqual(use, "ub"); XCTAssertEqual(id, "b")
                XCTAssertEqual(h.vm.currentSessionId, "a"); XCTAssertEqual(h.vm.currentPath, "/a")
                XCTAssertEqual(h.vm.pendingApprovals["b"]?.id, "ub")
                return "approval"
            case .sessionList(let sessions):
                XCTAssertEqual(Set(sessions.map(\.sessionId)), ["n", "c"])
                XCTAssertEqual(h.vm.serverSessions.count, 2)
                XCTAssertEqual(h.vm.sessionStatuses["n"], .idle)
                XCTAssertEqual(h.vm.sessionStatuses["c"], .busy)
                XCTAssertNil(try? h.sessions().first { $0.id == "c" })
                return "list"
            case .unknown(let raw):
                XCTAssertEqual(raw, "mystery")
                XCTAssertEqual(try? h.messages(role: "unknown").map(\.text), ["mystery"])
                return "unknown"
            default:
                XCTFail("unexpected decoded frame")
                return "unexpected"
            }
        }
        let first = h.vm.incoming.sink { firstEvents.append(inspect($0)) }
        let second = h.vm.incoming.sink { secondEvents.append(inspect($0)) }
        defer { first.cancel(); second.cancel() }

        try await h.receive(["type": "session_info", "sessionId": "n", "path": "/n"])
        h.vm.currentSessionId = "a"; h.vm.currentPath = "/a"
        try await h.approval("ub", id: "b")
        try await h.list([("n", "idle", "sessions"), ("c", "busy", "concierge")])
        try await h.receive(["type": "future_type", "text": "mystery"])

        let expected = ["info", "approval", "list", "unknown"]
        XCTAssertEqual(firstEvents, expected)
        XCTAssertEqual(secondEvents, expected)
    }

    func testReconfigureAndRepairKeepOneDecodedPublication() async throws {
        let h = try ChatTestHarness(configure: false); defer { h.close() }
        var firstEvents = 0, secondEvents = 0
        let first = h.vm.incoming.sink { _ in firstEvents += 1 }
        let second = h.vm.incoming.sink { _ in secondEvents += 1 }
        defer { first.cancel(); second.cancel() }

        h.vm.configure(context: h.context)
        h.vm.configure(context: h.context)
        try await h.connect()
        try await h.status("busy")
        XCTAssertEqual(firstEvents, 1); XCTAssertEqual(secondEvents, 1)

        let staleDelivery = h.task.savedDelivery(#"{"type":"status","state":"idle","sessionId":"a"}"#)
        h.vm.unpair()
        h.credentials.token = "repaired-token"
        h.credentials.deviceId = "repaired-device"
        h.credentials.deviceName = "Repaired Device"
        h.vm.isAuthenticated = true
        h.vm.configure(context: h.context)
        try await h.connect()
        staleDelivery()
        for _ in 0..<8 { await Task.yield() }
        XCTAssertEqual(firstEvents, 1); XCTAssertEqual(secondEvents, 1)
        try await h.status("idle")
        XCTAssertEqual(firstEvents, 2); XCTAssertEqual(secondEvents, 2)
    }

    func testNamedRequestsAndHeadlessSpeechStorage() async throws {
        let h = try ChatTestHarness(configure: false); defer { h.close() }
        XCTAssertFalse(h.vm.listSessions())
        XCTAssertFalse(h.vm.resumeSession(sessionId: "c", path: "/c"))
        XCTAssertFalse(h.vm.newConciergeSession())
        XCTAssertNil(try reflectedSpeechStorage(h.vm))

        h.vm.configure(context: h.context)
        XCTAssertFalse(h.vm.listSessions())
        XCTAssertFalse(h.vm.resumeSession(sessionId: "c", path: "/c"))
        XCTAssertFalse(h.vm.newConciergeSession())
        XCTAssertTrue(h.task.sentTexts.isEmpty)
        try await h.connect()

        let before = try h.frames().count
        XCTAssertTrue(h.vm.listSessions())
        XCTAssertTrue(h.vm.resumeSession(sessionId: "c", path: "/c"))
        XCTAssertTrue(h.vm.newConciergeSession())
        let requests = Array(try h.frames().dropFirst(before))
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests[0] as NSDictionary, ["type": "list_sessions"] as NSDictionary)
        XCTAssertEqual(requests[1] as NSDictionary,
                       ["type": "resume_session", "sessionId": "c", "path": "/c"] as NSDictionary)
        XCTAssertEqual(requests[2] as NSDictionary,
                       ["type": "new_session", "mode": "concierge"] as NSDictionary)

        h.vm.autoReadAloud = false
        _ = try h.send("hello")
        try await h.chunk("one")
        try await h.chunk(" two", final: true)
        try await h.status("tool_running", tool: "shell")
        try await h.approval("u")
        try await h.list([("a", "busy", "sessions")])
        XCTAssertNil(try reflectedSpeechStorage(h.vm))

        let speech = SpeechManager()
        speech.liveText = "dictated"
        let injected = try ChatTestHarness(speech: speech); defer { injected.close() }
        XCTAssertTrue(injected.vm.speechManager === speech)
        injected.vm.currentSessionId = "a"
        injected.vm.messageText = "sent"
        injected.vm.sendText()
        XCTAssertEqual(speech.liveText, "")
        XCTAssertTrue(injected.vm.speechManager === speech)
    }

    func testWatchdogAbsenceUsesTerminationCleanup() async throws {
        for concierge in [false, true] {
            let h = try ChatTestHarness(watchdog: .milliseconds(50)); defer { h.close() }
            try await h.connect()
            if concierge { h.vm.registerConciergeSession("watched") }
            try await h.list([
                ("watched", "idle", concierge ? "concierge" : "sessions"),
                ("other", "idle", "sessions")
            ])
            try await h.status("tool_running", id: "watched", tool: "shell")
            try await h.chunk("old-stream", id: "watched")
            try await h.approval("use", id: "watched")
            let queued = try h.send("held", id: "watched", attachment: AttachmentData(
                data: Data([4, 5]), name: "held.bin", mimeType: "application/octet-stream"))
            let oldStream = try XCTUnwrap(h.messages("watched", role: "assistant").first?.id)
            XCTAssertEqual(h.vm.sessionStatuses["watched"], .toolRunning)
            XCTAssertEqual(h.vm.sessionToolNames["watched"], "shell")
            XCTAssertEqual(h.vm.pendingApprovals["watched"]?.id, "use")
            XCTAssertEqual(h.vm.pendingReasons[queued], .busy)
            XCTAssertEqual(h.vm.queuedAttachmentCountForTesting, 1)
            XCTAssertEqual(h.vm.sessionStatuses["other"], .idle)
            XCTAssertNotNil(try h.sessions().first { $0.id == "other" })

            try await h.list([("other", "idle", "sessions")])
            XCTAssertNil(h.vm.sessionStatuses["watched"])
            XCTAssertNil(h.vm.sessionToolNames["watched"])
            XCTAssertNil(h.vm.pendingApprovals["watched"])
            XCTAssertNil(h.vm.pendingReasons[queued])
            XCTAssertEqual(h.vm.queuedAttachmentCountForTesting, 0)
            XCTAssertEqual(h.vm.sessionStatuses["other"], .idle)
            XCTAssertNotNil(try h.sessions().first { $0.id == "other" })
            XCTAssertTrue(try h.frames("message").isEmpty)
            let queries = try h.frames("list_sessions").count
            try await Task.sleep(for: .milliseconds(140))
            XCTAssertEqual(try h.frames("list_sessions").count, queries)

            try await h.chunk("fresh-stream", id: "watched")
            let fresh = try XCTUnwrap(h.messages("watched", role: "assistant")
                .first { $0.text == "fresh-stream" }?.id)
            XCTAssertNotEqual(fresh, oldStream)
        }
    }

    func testWatchdogCancelsOnIdleClearDisconnectAndUnpair() async throws {
        for action in ["idle", "context", "local-clear", "server-clear", "disconnect"] {
            let h = try ChatTestHarness(watchdog: .milliseconds(150)); defer { h.close() }
            try await h.connect()
            try await h.list([("a", "idle", "sessions"), ("other", "idle", "sessions")])
            try await h.status("tool_running", tool: "shell")
            try await h.chunk("stream")
            try await h.approval("use")
            let queued = try h.send("held", attachment: AttachmentData(
                data: Data([7]), name: "held.bin", mimeType: "application/octet-stream"))
            XCTAssertEqual(h.vm.sessionStatuses["a"], .toolRunning)
            XCTAssertEqual(h.vm.sessionToolNames["a"], "shell")
            XCTAssertEqual(h.vm.pendingApprovals["a"]?.id, "use")
            XCTAssertEqual(h.vm.pendingReasons[queued], .busy)
            XCTAssertEqual(h.vm.queuedAttachmentCountForTesting, 1)
            XCTAssertFalse(try h.messages("a").isEmpty)

            let oldTask = h.task
            switch action {
            case "idle": try await h.status("idle")
            case "context":
                try await h.receive(["type": "context_cleared", "oldSessionId": "a", "sessionId": "a"])
            case "local-clear": h.vm.clearSession(sessionId: "a")
            case "server-clear": try await h.receive(["type": "session_cleared", "sessionId": "a"])
            default: h.vm.disconnect()
            }
            let countAfterAction = oldTask.sentTexts.filter { $0.contains("\"type\":\"list_sessions\"") }.count
            try await Task.sleep(for: .milliseconds(350))
            XCTAssertEqual(oldTask.sentTexts.filter { $0.contains("\"type\":\"list_sessions\"") }.count,
                           countAfterAction, "obsolete watchdog fired after \(action)")

            if action == "disconnect" {
                XCTAssertEqual(h.vm.sessionStatuses["a"], .toolRunning)
                XCTAssertEqual(h.vm.pendingReasons[queued], .busy)
                XCTAssertEqual(h.vm.queuedAttachmentCountForTesting, 1)
                h.vm.reconnect()
                try await h.connect()
                let immediate = try h.frames("list_sessions").count
                XCTAssertGreaterThanOrEqual(immediate, 1)
                try await eventually("reconnected busy watchdog queries") {
                    try h.frames("list_sessions").count > immediate
                }
            }
        }

        let h = try ChatTestHarness(watchdog: .milliseconds(150)); defer { h.close() }
        let first = try h.send("first", attachment: AttachmentData(
            data: Data([1]), name: "first.bin", mimeType: "application/octet-stream"))
        let second = try h.send("second", attachment: AttachmentData(
            data: Data([2]), name: "second.bin", mimeType: "application/octet-stream"))
        XCTAssertEqual(h.vm.pendingReasons, [first: .offline, second: .offline])
        try await h.connect()
        try await h.status("idle")
        try await h.status("busy")
        XCTAssertEqual(h.vm.pendingReasons[second], .busy)
        XCTAssertEqual(h.vm.queuedAttachmentCountForTesting, 1)
        XCTAssertEqual(reflectedStringSet("queueReleasePendingIdle", in: h.vm), ["a"])
        XCTAssertEqual(reflectedStringSet("releasedBeforeReconnectSync", in: h.vm), ["a"])
        h.vm.unpair()
        XCTAssertTrue(h.vm.pendingReasons.isEmpty)
        XCTAssertEqual(h.vm.queuedAttachmentCountForTesting, 0)
        XCTAssertTrue(reflectedStringSet("queueReleasePendingIdle", in: h.vm).isEmpty)
        XCTAssertTrue(reflectedStringSet("releasedBeforeReconnectSync", in: h.vm).isEmpty)
        let queries = h.task.sentTexts.filter { $0.contains("\"type\":\"list_sessions\"") }.count
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(h.task.sentTexts.filter { $0.contains("\"type\":\"list_sessions\"") }.count, queries)
    }

    func testReplacementOldWatchCannotReapOrQueryNewLifecycle() async throws {
        do {
            let h = try ChatTestHarness(watchdog: .milliseconds(150)); defer { h.close() }
            try await h.connect()
            try await h.list([("old", "idle", "sessions")])
            try await h.status("busy", id: "old")
            try await h.receive(["type": "session_replaced", "oldSessionId": "old",
                                 "newSessionId": "new", "path": "/old"])
            try await h.status("idle", id: "new")
            try await h.status("busy", id: "old")
            try await Task.sleep(for: .milliseconds(50))
            try await h.status("idle", id: "old")
            let queries = try h.frames("list_sessions").count
            try await Task.sleep(for: .milliseconds(350))
            XCTAssertEqual(try h.frames("list_sessions").count, queries)
            XCTAssertTrue(try h.frames("message").isEmpty)
            XCTAssertEqual(h.vm.sessionStatuses["old"], .idle)
            XCTAssertEqual(h.vm.sessionStatuses["new"], .idle)
        }
        do {
            let h = try ChatTestHarness(watchdog: .milliseconds(150)); defer { h.close() }
            try await h.connect()
            try await h.list([("old", "idle", "sessions")])
            try await h.status("busy", id: "old")
            try await h.receive(["type": "session_replaced", "oldSessionId": "old",
                                 "newSessionId": "new", "path": "/old"])
            let queries = try h.frames("list_sessions").count
            try await eventually("replacement busy lifecycle remains watched") {
                try h.frames("list_sessions").count > queries
            }
            XCTAssertEqual(h.vm.sessionStatuses["new"], .busy)
        }
    }

    func testBusyReplyResetsDeadlineAndMaintainsOneWatch() async throws {
        let h = try ChatTestHarness(watchdog: .milliseconds(200)); defer { h.close() }
        try await h.connect()
        try await h.status("tool_running", tool: "shell")
        XCTAssertTrue(h.vm.pendingReasons.isEmpty)
        XCTAssertTrue(try h.frames("message").isEmpty)
        try await Task.sleep(for: .milliseconds(120))
        try await h.list([("a", "busy", "sessions")])
        let reset = try h.frames("list_sessions").count
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(try h.frames("list_sessions").count, reset)
        try await eventually("reset deadline eventually fires", timeout: .milliseconds(250)) {
            try h.frames("list_sessions").count == reset + 1
        }
        XCTAssertEqual(h.vm.sessionStatuses["a"], .toolRunning)
        XCTAssertEqual(h.vm.sessionToolNames["a"], "shell")
        XCTAssertTrue(h.vm.pendingReasons.isEmpty)
        XCTAssertTrue(try h.frames("message").isEmpty)

        try await h.status("busy")
        try await h.status("tool_running", tool: "shell")
        try await h.list([("a", "busy", "sessions")])
        try await h.status("idle")
        let idle = try h.frames("list_sessions").count
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(try h.frames("list_sessions").count, idle)
        XCTAssertTrue(h.vm.pendingReasons.isEmpty)
        XCTAssertTrue(try h.frames("message").isEmpty)
    }

    func testCachedLegacyResumeNeverCreatesWorkspaceHistory() async throws {
        let h = try ChatTestHarness(); defer { h.close() }; try await h.connect()
        h.store.cache(sessionId: "cached", path: "/cached")
        h.vm.registerConciergeSession(h.store.cachedSession?.sessionId)
        var observed = false
        let observer = h.vm.incoming.sink { frame in
            guard case .sessionInfo("cached", "/cached", .sessions) = frame else { return }
            observed = true
            XCTAssertEqual(h.vm.currentSessionId, "cached")
            XCTAssertEqual(h.vm.currentPath, "/cached")
            XCTAssertTrue((try? h.sessions().isEmpty) == true)
            XCTAssertTrue((try? h.workspaces().isEmpty) == true)
        }
        defer { observer.cancel() }
        try await h.receive(["type": "session_info", "sessionId": "cached", "path": "/cached"])
        XCTAssertTrue(observed)
        XCTAssertTrue(try h.sessions().isEmpty)
        XCTAssertTrue(try h.workspaces().isEmpty)
    }
}
