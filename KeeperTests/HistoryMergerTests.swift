import XCTest
@testable import Keepur

@MainActor
final class HistoryMergerTests: XCTestCase {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    func local(_ id: String = "local", server: String? = nil, offset: Double = 0,
               channel: String = "c", sender: String = "agent", text: String = "same",
               pending: Bool = false, type: SenderType = .agent) -> TeamMessageSnapshot {
        TeamMessageSnapshot(id: id, serverId: server, channelId: channel, senderId: sender,
            senderType: type, senderName: "Local name", text: text, threadId: "local-thread",
            createdAt: date.addingTimeInterval(offset), pending: pending)
    }
    func history(_ id: String = "server", offset: Double = 0, channel: String = "c",
                 sender: String = "agent", text: String = "same",
                 type: SenderType = .agent) -> TeamHistoryMessage {
        TeamHistoryMessage(id: id, channelId: channel, senderId: sender, senderType: type,
            senderName: "Server name", text: text, createdAt: date.addingTimeInterval(offset),
            threadId: "server-thread")
    }
    func merge(_ local: [TeamMessageSnapshot], _ page: [TeamHistoryMessage],
               now: Date? = nil) -> MergeResult {
        HistoryMerger.merge(existing: local, incoming: page, ownDeviceId: "device", now: now ?? date)
    }
    func apply(_ result: MergeResult, to existing: [TeamMessageSnapshot]) -> [TeamMessageSnapshot] {
        existing.map { row in
            TeamMessageSnapshot(id: row.id, serverId: result.serverIdStamps[row.id] ?? row.serverId,
                channelId: row.channelId, senderId: row.senderId, senderType: row.senderType,
                senderName: row.senderName, text: row.text, threadId: row.threadId,
                createdAt: row.createdAt, pending: result.unpendIds.contains(row.id) ? false : row.pending)
        } + result.inserts.map {
            TeamMessageSnapshot(id: $0.id, serverId: $0.id, channelId: $0.channelId,
                senderId: $0.senderId, senderType: $0.senderType, senderName: $0.senderName,
                text: $0.text, threadId: $0.threadId, createdAt: $0.createdAt, pending: false)
        }
    }
    func assertReplay(_ rows: [TeamMessageSnapshot], _ page: [TeamHistoryMessage],
                      file: StaticString = #filePath, line: UInt = #line) {
        let next = merge(apply(merge(rows, page), to: rows), page)
        XCTAssertTrue(next.inserts.isEmpty, file: file, line: line)
        XCTAssertTrue(next.serverIdStamps.isEmpty, file: file, line: line)
        XCTAssertTrue(next.unpendIds.isEmpty, file: file, line: line)
    }
    func testKnownLegacyReservationAndOverlappingIds() {
        let rows = [local("known", server: "k"), local("z", pending: true)]
        let page = [history("z"), history("a", offset: -1), history("k"), history("a", offset: -1)]
        let result = merge(rows, page)
        XCTAssertEqual(result.inserts.map(\.id), ["a"])
        XCTAssertEqual(result.serverIdStamps, ["z": "z"])
        XCTAssertEqual(result.unpendIds, ["z"])
        assertReplay(rows, page)
        let overlap = merge(apply(result, to: rows), [history("a"), history("new")])
        XCTAssertEqual(overlap.inserts.map(\.id), ["new"])
        XCTAssertTrue(overlap.serverIdStamps.isEmpty)
        let legacy = local("exact-legacy", offset: -600, sender: "local-sender",
                           text: "local contents", pending: true, type: .unknown("legacy-type"))
        let exactPage = [history("exact-legacy", offset: 600, sender: "server-sender",
                                 text: "different server contents", type: .person)]
        let exact = merge([legacy], exactPage)
        XCTAssertTrue(exact.inserts.isEmpty, "exact identity bypasses date/content/sender heuristics")
        XCTAssertEqual(exact.serverIdStamps, [legacy.id: legacy.id])
        XCTAssertEqual(exact.unpendIds, [legacy.id])
        let adopted = apply(exact, to: [legacy])
        XCTAssertEqual(adopted, [TeamMessageSnapshot(id: legacy.id, serverId: legacy.id,
            channelId: legacy.channelId, senderId: legacy.senderId, senderType: legacy.senderType,
            senderName: legacy.senderName, text: legacy.text, threadId: legacy.threadId,
            createdAt: legacy.createdAt, pending: false)])
        assertReplay([legacy], exactPage)
    }
    func testAgentSystemAndOwnRowsStampWithoutChangingLocalFields() {
        for sender in ["agent", "system", "device"] {
            for pending in [false, true] {
                let row = local(sender: sender, pending: pending, type: .unknown("future-local"))
                let page = [history(sender: sender)]
                let result = merge([row], page)
                XCTAssertTrue(result.inserts.isEmpty)
                XCTAssertEqual(result.serverIdStamps, ["local": "server"])
                let applied = apply(result, to: [row])[0]
                XCTAssertEqual(applied.id, row.id); XCTAssertEqual(applied.createdAt, row.createdAt)
                XCTAssertEqual(applied.text, row.text); XCTAssertEqual(applied.threadId, row.threadId)
                XCTAssertEqual(applied.senderType, .unknown("future-local"))
                XCTAssertEqual(applied.senderName, "Local name"); XCTAssertFalse(applied.pending)
                assertReplay([row], page)
            }
        }
    }
    func testDistinctRepeatsConsumeEachLocalOnlyOnce() {
        let page = [history("b"), history("a")]
        XCTAssertEqual(merge([], page).inserts.map(\.id), ["a", "b"])
        let one = merge([local()], page)
        XCTAssertEqual(one.serverIdStamps, ["local": "a"])
        XCTAssertEqual(one.inserts.map(\.id), ["b"])
        let rows = [local("l2"), local("l1")]
        let two = merge(rows, page)
        XCTAssertEqual(two.serverIdStamps, ["l1": "a", "l2": "b"])
        XCTAssertTrue(two.inserts.isEmpty); assertReplay(rows, page)
        XCTAssertEqual(merge([local(server: "old")], page).inserts.count, 2)
    }
    func testFieldEqualityAndDelimiterCollision() {
        for row in [local(channel: "other"), local(sender: "other"), local(text: "different"),
                    local(sender: "a|b", text: "c")] {
            let page = row.senderId == "a|b" ? [history(sender: "a", text: "b|c")] : [history()]
            XCTAssertEqual(merge([row], page).inserts.count, 1)
        }
        XCTAssertEqual(merge([local(sender: "device-old")], [history(sender: "device")]).inserts.count, 1)
    }
    func testClosestDateAndLexicalTiesAreOrderIndependent() {
        let rows = [local("late", offset: 2), local("b", offset: -2), local("a", offset: -2),
                    local("far", offset: -10)]
        for candidates in [rows, Array(rows.reversed())] {
            XCTAssertEqual(merge(candidates, [history()]).serverIdStamps, ["a": "server"])
        }
        XCTAssertEqual(merge(rows + [local("closest", offset: 1)], [history()]).serverIdStamps,
                       ["closest": "server"])
        let page = [history("b", offset: 8), history("a", offset: -8)]
        XCTAssertEqual(merge([], page).inserts.map(\.id), merge([], Array(page.reversed())).inserts.map(\.id))
    }
    func testStrictWindowAndDistantNow() {
        for offset in [-30.0, 30.0, 30.001] {
            XCTAssertEqual(merge([local(offset: offset)], [history()]).inserts.count, 1)
        }
        for offset in [-29.999, 29.999] {
            let rows = [local(offset: offset)]
            XCTAssertEqual(merge(rows, [history()], now: .distantFuture).serverIdStamps, ["local": "server"])
            XCTAssertEqual(merge(rows, [history()], now: .distantPast).serverIdStamps, ["local": "server"])
        }
    }
    func testEmptyChronologicalAndUnknownThreadRetention() {
        XCTAssertTrue(merge([], []).inserts.isEmpty)
        XCTAssertTrue(merge([local()], []).serverIdStamps.isEmpty)
        let result = merge([], [history("z", offset: 2), history("b", type: .unknown("future")), history("a")])
        XCTAssertEqual(result.inserts.map(\.id), ["a", "b", "z"])
        XCTAssertEqual(result.inserts[1].senderType, .unknown("future"))
        XCTAssertEqual(result.inserts[1].threadId, "server-thread")
        assertReplay([], result.inserts)
    }
}
