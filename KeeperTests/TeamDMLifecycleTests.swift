import XCTest
import SwiftData
@testable import Keepur

@MainActor
final class TeamDMLifecycleTests: XCTestCase {
    func testOfflineAndRapidTapsThenTimeoutAndRetry() async throws {
        let h = try TeamTestHarness(dmTimeout: .milliseconds(150)); defer { h.close() }
        h.vm.openAgentDM(agent: h.agent("a"))
        XCTAssertEqual(h.vm.lastError?.text, "Not connected. Try again when reconnected.")
        try await h.connect(); h.vm.lastError = nil
        h.vm.openAgentDM(agent: h.agent("a")); let first = try h.dmRequest("a")
        h.vm.openAgentDM(agent: h.agent("a")); h.vm.openAgentDM(agent: h.agent("b"))
        XCTAssertEqual(try h.frames("command").count, 1)
        try await eventually("DM deadline") { h.vm.lastError?.text == "Couldn't open a direct message. Try again." }
        let count = try h.frames("channel_list").count
        try await h.systemReply(first, text: "late expired")
        XCTAssertEqual(try h.frames("channel_list").count, count)
        h.vm.lastError = nil; h.vm.openAgentDM(agent: h.agent("b"))
        XCTAssertEqual(try h.frames("command").count, 2)
        XCTAssertNotEqual(try h.dmRequest("b"), first)
    }
    func testSystemResponseAndMissingDMDoNotRestartOrReleaseDeadline() async throws {
        let h = try TeamTestHarness(dmTimeout: .milliseconds(300)); defer { h.close() }
        try await h.connect(); h.vm.activeChannelId = "c"
        h.vm.openAgentDM(agent: h.agent("a"))
        let request = try h.dmRequest("a")
        let start = ContinuousClock.now
        try await Task.sleep(for: .milliseconds(150))
        try await h.systemReply(request)
        XCTAssertTrue(try h.rows().isEmpty, "matching command response is suppressed")
        try await h.list([])
        h.vm.openAgentDM(agent: h.agent("b"))
        XCTAssertEqual(try h.frames("command").count, 1)
        try await eventually("original DM budget", timeout: .milliseconds(250)) { h.vm.lastError != nil }
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(550))
        XCTAssertEqual(h.vm.lastError?.text, "Couldn't open a direct message. Try again.")
    }
    func testExactDMArrivalAfterReplyCancelsDeadlineAndExistingDMSelectsImmediately() async throws {
        let h = try TeamTestHarness(dmTimeout: .milliseconds(150)); defer { h.close() }
        try await h.connect()
        h.vm.openAgentDM(agent: h.agent("a"))
        try await h.systemReply(h.dmRequest("a"))
        try await h.dmList("a")
        XCTAssertEqual(h.vm.activeChannelId, "dm-a")
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertNil(h.vm.lastError)
        let count = try h.frames("command").count
        h.vm.openAgentDM(agent: h.agent("a"))
        XCTAssertEqual(try h.frames("command").count, count)
        XCTAssertEqual(h.vm.activeChannelId, "dm-a")
    }
    func testUnknownChannelKindCannotCompleteDM() async throws {
        let h = try TeamTestHarness(dmTimeout: .milliseconds(150)); defer { h.close() }
        try await h.connect(); h.vm.openAgentDM(agent: h.agent("a"))
        try await h.dmList("a", kind: "future-dm")
        XCTAssertNotEqual(h.vm.activeChannelId, "dm-a")
        h.vm.openAgentDM(agent: h.agent("b"))
        XCTAssertEqual(try h.frames("command").count, 1)
        try await eventually("unknown kind keeps waiting to timeout") { h.vm.lastError != nil }
        XCTAssertEqual(h.vm.lastError?.text, "Couldn't open a direct message. Try again.")
    }
    func testEarlyAChannelThenBThenLateAReplyPreservesBDeadlineAndSuppression() async throws {
        let h = try TeamTestHarness(dmTimeout: .milliseconds(400)); defer { h.close() }
        try await h.connect()
        h.vm.openAgentDM(agent: h.agent("a")); let a = try h.dmRequest("a")
        try await Task.sleep(for: .milliseconds(250))
        try await h.dmList("a")
        XCTAssertEqual(h.vm.activeChannelId, "dm-a")
        h.vm.openAgentDM(agent: h.agent("b")); let b = try h.dmRequest("b")
        let lists = try h.frames("channel_list").count
        try await h.systemReply(a, text: "A late success")
        XCTAssertEqual(try h.frames("channel_list").count, lists, "A completion retired its refresh mapping")
        XCTAssertTrue(try h.rows().isEmpty, "A stays suppressed after B starts")
        try await Task.sleep(for: .milliseconds(200)) // A's original deadline passed; B's did not.
        XCTAssertNil(h.vm.lastError)
        h.vm.openAgentDM(agent: h.agent("c"))
        XCTAssertEqual(try h.frames("command").count, 2, "A timer/reply cannot release B's lock")
        try await h.systemReply(b)
        XCTAssertTrue(try h.rows().isEmpty, "A reply did not clear B's suppression slot")
        try await eventually("B expires on its own deadline") { h.vm.lastError != nil }
        XCTAssertEqual(h.vm.lastError?.text, "Couldn't open a direct message. Try again.")
        h.vm.lastError = nil; h.vm.openAgentDM(agent: h.agent("c"))
        XCTAssertEqual(try h.frames("command").count, 3)
    }
    func testErrorDisconnectHiveChangeAndPairingCancelOldAttempt() async throws {
        for exit in ["error", "disconnect", "switch", "pairing"] {
            let h = try TeamTestHarness(dmTimeout: .milliseconds(120)); defer { h.close() }
            try await h.connect(); h.vm.openAgentDM(agent: h.agent("a"))
            let old = try h.dmRequest("a")
            switch exit {
            case "error": try await h.receive(["type": "error", "message": "specific server error"])
            case "disconnect": h.vm.disconnect()
            case "switch": try await h.connect("hive-b")
            default: h.vm.resetForPairingTeardown()
            }
            try await Task.sleep(for: .milliseconds(180))
            XCTAssertEqual(h.vm.lastError?.text, exit == "error" ? "specific server error" : nil)
            if h.vm.connectionState != .connected {
                h.vm.isAuthenticated = true; try await h.connect()
            }
            h.vm.lastError = nil; h.vm.activeChannelId = "c"
            h.vm.openAgentDM(agent: h.agent("b"))
            let before = try h.frames("channel_list").count
            try await h.systemReply(old, text: "late old")
            XCTAssertEqual(try h.frames("channel_list").count, before)
            XCTAssertEqual(try h.rows().first { $0.text == "late old" }?.channelId, "c")
            h.vm.openAgentDM(agent: h.agent("c"))
            XCTAssertEqual(try h.frames("command").filter { $0["args"] as? [String] == ["c"] }.count, 0)
            try await h.systemReply(h.dmRequest("b"), text: "B suppressed")
            XCTAssertFalse(try h.rows().contains { $0.text == "B suppressed" })
        }
    }
    func testSleepingDMTaskDoesNotRetainViewModel() async throws {
        let h = try TeamTestHarness(dmTimeout: .milliseconds(500)); defer { h.close() }
        try await h.connect()
        let armedAt = ContinuousClock.now
        h.vm.openAgentDM(agent: h.agent("a"))
        try await Task.sleep(for: .milliseconds(20)) // Let the task enter its sleep before releasing the VM.
        XCTAssertLessThan(armedAt.duration(to: .now), .milliseconds(250),
                          "the release assertion must begin before the DM deadline")
        XCTAssertNil(h.vm.lastError)
        let sentBeforeRelease = h.task.sentTexts
        weak var released = h.vm
        let releasedAt = ContinuousClock.now
        h.vm = nil
        try await eventually("VM deallocated while DM task sleeping", timeout: .milliseconds(100)) {
            released == nil
        }
        XCTAssertLessThan(releasedAt.duration(to: .now), .milliseconds(150),
                          "retention until the 500 ms deadline must fail even after a delayed poll")
        try await Task.sleep(for: .milliseconds(550))
        XCTAssertNil(released)
        XCTAssertEqual(h.task.sentTexts, sentBeforeRelease)
    }
    func testCommandMapsRetireAfterUnackedMovementIncludingEmptyMap() async throws {
        for departure in ["disconnect", "switch"] {
            for withMessage in [false, true] {
                let h = try TeamTestHarness(); defer { h.close() }
                try await h.connect(); h.vm.activeChannelId = "old-channel"
                if withMessage { h.vm.sendMessage(text: "queued old") }
                h.vm.sendMessage(text: "/new room")
                h.vm.sendMessage(text: "/dm agent")
                h.vm.openAgentDM(agent: h.agent("button-agent"))
                let requests = try h.frames("command").compactMap { $0["id"] as? String }
                let departing = h.task
                if departure == "disconnect" {
                    h.vm.disconnect()
                    XCTAssertEqual(h.vm.connectionState, .disconnected)
                    XCTAssertEqual(h.vm.offlineEntries.count, withMessage ? 1 : 0)
                    XCTAssertTrue(h.vm.offlineEntries.allSatisfy { $0.hive == "hive-a" })
                    XCTAssertEqual(h.vm.pendingMessageRequestCountForTesting, 0)
                    let queued = h.vm.offlineEntries
                    h.vm.disconnect() // Already-disconnected retirement remains idempotent.
                    XCTAssertEqual(h.vm.offlineEntries, queued)
                }
                try await h.connect("hive-b")
                XCTAssertEqual(departing.lastCloseCode, departure == "disconnect" ? .normalClosure : .goingAway)
                h.vm.activeChannelId = "new-channel"
                XCTAssertEqual(h.vm.offlineEntries.count, withMessage ? 1 : 0)
                XCTAssertTrue(h.vm.offlineEntries.allSatisfy { $0.hive == "hive-a" })
                XCTAssertTrue(try h.frames("message").isEmpty)
                let lists = try h.frames("channel_list").count
                for request in requests { try await h.systemReply(request, text: request) }
                XCTAssertEqual(try h.frames("channel_list").count, lists)
                let routed = try h.rows().filter { requests.contains($0.text) }
                XCTAssertEqual(routed.count, requests.count)
                XCTAssertTrue(routed.allSatisfy { $0.channelId == "new-channel" })
            }
        }
    }
    func testVanishedHiveRefreshPreservesQueueBytesAndDoesNotSendFromStateSink() async throws {
        var refreshes = 0
        let h = try TeamTestHarness(capabilityRefreshOperation: { manager in
            refreshes += 1
            manager._setHivesForTesting([])
        }); defer { h.close() }
        h.vm.activeChannelId = "c"; h.begin()
        h.vm.pendingAttachment = AttachmentData(data: Data([1, 8]), name: "stay.bin", mimeType: "application/octet-stream")
        h.vm.sendMessage(text: "keep")
        let original = h.vm.offlineEntries
        let current = h.task
        current.completeHandshake(error: URLError(.networkConnectionLost))
        try await eventually("vanished hive refresh finished") { h.vm.lastError != nil }
        XCTAssertEqual(refreshes, 1)
        XCTAssertEqual(h.vm.lastError?.text, "This hive is no longer available.")
        XCTAssertEqual(h.vm.connectionState, .disconnected)
        XCTAssertEqual(h.vm.offlineEntries, original)
        XCTAssertEqual(h.vm.queuedAttachmentCountForTesting, 1)
        XCTAssertTrue(current.sentTexts.isEmpty)
        XCTAssertEqual(try h.rows().count, 1)
        h.capability._setHivesForTesting(["hive-a"])
        try await h.connect()
        XCTAssertEqual(try h.frames("message").last?["text"] as? String, "keep")
        XCTAssertEqual(try h.frames("file").last?["data"] as? String, Data([1, 8]).base64EncodedString())
    }
    func testValidHiveRefreshRunsOnlyAtFirstReconnectAttempt() async throws {
        var refreshes = 0
        let h = try TeamTestHarness(capabilityRefreshOperation: { _ in refreshes += 1 }); defer { h.close() }
        h.begin(); let first = h.task
        first.completeHandshake(error: URLError(.networkConnectionLost))
        try await eventually("first refresh") { refreshes == 1 }
        XCTAssertEqual(h.vm.connectionState, .reconnecting(attempt: 1)); XCTAssertNil(h.vm.lastError)
        XCTAssertTrue(first.sentTexts.isEmpty)
        h.vm.reconnect(); let second = h.task
        second.completeHandshake(error: URLError(.networkConnectionLost))
        try await eventually("second attempt") { h.vm.connectionState == .reconnecting(attempt: 2) }
        XCTAssertEqual(refreshes, 1); XCTAssertNil(h.vm.lastError)
        XCTAssertTrue(second.sentTexts.isEmpty)
    }
}
