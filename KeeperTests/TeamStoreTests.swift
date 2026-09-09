import XCTest
import SwiftData
@testable import Keepur

@MainActor
final class TeamStoreTests: XCTestCase {
    func testDeleteChannelProtectsIdsNotPendingAndDoesNotSave() async throws {
        let h = try TeamTestHarness(); defer { h.close() }
        let channel = TeamChannel(id: "c", type: "channel", name: "C")
        h.context.insert(channel)
        try h.insert("unowned-pending", pending: true)
        try h.insert("owned-unpended", pending: false)
        try h.insert("other", channel: "other")
        TeamStore.deleteChannel(channel, in: h.context, protecting: ["owned-unpended"])
        XCTAssertTrue(h.context.hasChanges)
        try h.context.save()
        XCTAssertEqual(Set(try h.rows().map(\.id)), ["owned-unpended", "other"])
        XCTAssertTrue(try h.context.fetch(FetchDescriptor<TeamChannel>()).isEmpty)
    }
    func testDeletionFetchFailureStillDeletesChannelWithoutDeletingMessages() async throws {
        let h = try TeamTestHarness(); defer { h.close() }
        let channel = TeamChannel(id: "c", type: "channel", name: "C")
        h.context.insert(channel); try h.insert("retained")
        var calls = 0
        TeamStore.deleteChannel(channel, in: h.context, protecting: [], fetchOperation: { _, _ in
            calls += 1; throw NSError(domain: "CleanupFetch", code: 1)
        })
        XCTAssertEqual(calls, 1); try h.context.save()
        XCTAssertEqual(try h.rows().map(\.id), ["retained"])
        XCTAssertTrue(try h.context.fetch(FetchDescriptor<TeamChannel>()).isEmpty)
        XCTAssertNil(h.vm.lastError)
    }
    func testOrphanSweepProtectsOnlyOwnedRowsAndFetchFailureDoesNothing() async throws {
        let h = try TeamTestHarness(); defer { h.close() }
        try h.insert("valid", channel: "valid")
        try h.insert("orphan", pending: true)
        try h.insert("owned", pending: false)
        TeamStore.deleteOrphans(in: h.context, validChannelIds: ["valid"], protecting: ["owned"],
            fetchOperation: { _, _ in throw NSError(domain: "OrphanFetch", code: 2) })
        XCTAssertEqual(try h.rows().count, 3)
        TeamStore.deleteOrphans(in: h.context, validChannelIds: ["valid"], protecting: ["owned"])
        try h.context.save()
        XCTAssertEqual(Set(try h.rows().map(\.id)), ["valid", "owned"])
        TeamStore.deleteOrphans(in: h.context, validChannelIds: ["valid"], protecting: [])
        try h.context.save()
        XCTAssertEqual(try h.rows().map(\.id), ["valid"])
    }
}
