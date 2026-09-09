import Foundation
import SwiftData

@main
struct KPR445MigrationCheck {
    @MainActor static func main() throws {
        let mode = CommandLine.arguments[1]
        let url = URL(fileURLWithPath: CommandLine.arguments[2])
        let schema = Schema([Session.self, Message.self, Workspace.self, TeamChannel.self, TeamMessage.self])
        let container = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        ])
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        if mode == "seed" {
            let initialRows = try context.fetch(FetchDescriptor<TeamMessage>())
            precondition(initialRows.isEmpty)
            context.insert(Session(id: "sentinel-session", path: "/fixture", createdAt: date))
            context.insert(Workspace(path: "/fixture", lastUsed: date))
            context.insert(Message(id: "sentinel-message", sessionId: "sentinel-session", text: "retained", role: "user", timestamp: date))
            context.insert(TeamChannel(id: "c", type: "future-channel", name: "Retained", members: ["device", "agent"], updatedAt: date))
            for (id, sender, pending) in [("own", "device", true), ("live", "agent", false), ("history", "system", false)] {
                context.insert(TeamMessage(id: id, channelId: "c", threadId: "thread", senderId: sender,
                    senderType: "future-sender", senderName: "Retained", text: id, createdAt: date, pending: pending))
            }
            try context.save()
            print("PRE_E_SEEDED three Team rows and five-model sentinels")
            return
        }
        let rows = try context.fetch(FetchDescriptor<TeamMessage>())
        let channels = try context.fetch(FetchDescriptor<TeamChannel>())
        let sessions = try context.fetch(FetchDescriptor<Session>())
        let messages = try context.fetch(FetchDescriptor<Message>())
        let workspaces = try context.fetch(FetchDescriptor<Workspace>())
        precondition(Set(rows.map(\.id)) == ["own", "live", "history"])
        precondition(channels.count == 1 && channels[0].id == "c" && channels[0].type == "future-channel")
        precondition(channels[0].members == ["device", "agent"] && channels[0].updatedAt == date)
        precondition(sessions.count == 1 && sessions[0].id == "sentinel-session")
        precondition(messages.count == 1 && messages[0].id == "sentinel-message" && messages[0].text == "retained")
        precondition(workspaces.count == 1 && workspaces[0].path == "/fixture")
        precondition(rows.allSatisfy { $0.senderType == "future-sender" && $0.createdAt == date && $0.threadId == "thread" && $0.text == $0.id })
        #if PRE_E
        precondition(mode == "baseline-reopen")
        print("PRE_E_REOPENED original rows intact")
        #else
        if mode == "migrate" {
            precondition(rows.allSatisfy { $0.serverId == nil })
            precondition(rows.first { $0.id == "own" }?.pending == true)
            let snapshots = rows.map { row in
                TeamMessageSnapshot(id: row.id, serverId: row.serverId, channelId: row.channelId,
                    senderId: row.senderId, senderType: row.typedSenderType, senderName: row.senderName,
                    text: row.text, threadId: row.threadId, createdAt: row.createdAt, pending: row.pending)
            }
            let page = rows.map { row in
                TeamHistoryMessage(id: row.id == "history" ? "history" : "server-" + row.id,
                    channelId: row.channelId, senderId: row.senderId, senderType: .unknown("future-wire"),
                    senderName: "Wire", text: row.text, createdAt: row.createdAt, threadId: nil)
            }
            let result = HistoryMerger.merge(existing: snapshots, incoming: page, ownDeviceId: "device", now: .now)
            precondition(result.inserts.isEmpty && result.serverIdStamps.count == 3)
            for row in rows {
                row.serverId = result.serverIdStamps[row.id]
                if result.unpendIds.contains(row.id) { row.pending = false }
            }
            try context.save()
            print("E_MIGRATED nil defaults, stable rows reconciled, no recovery path linked")
        } else {
            precondition(mode == "verify")
            precondition(rows.allSatisfy { $0.serverId == ($0.id == "history" ? "history" : "server-" + $0.id) && !$0.pending })
            print("E_REOPENED stable local IDs, stamps and five-model sentinels intact")
        }
        #endif
    }
}
