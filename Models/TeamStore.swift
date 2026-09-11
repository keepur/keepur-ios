import Foundation
import SwiftData

@MainActor
enum TeamStore {
    static func deleteChannel(_ channel: TeamChannel, in context: ModelContext,
                              protecting protectedIds: Set<String>,
                              fetchOperation: (ModelContext, FetchDescriptor<TeamMessage>) throws -> [TeamMessage] = { try $0.fetch($1) }) {
        let cid = channel.id
        let descriptor = FetchDescriptor<TeamMessage>(predicate: #Predicate { $0.channelId == cid })
        var failure: Error?
        let messages = context.fetchOrEmpty(descriptor, "team.deleteChannel.messages.fetch", failure: &failure,
                                           operation: { try fetchOperation(context, $0) })
        for message in messages where !protectedIds.contains(message.id) { context.delete(message) }
        context.delete(channel)
    }

    static func deleteOrphans(in context: ModelContext, validChannelIds: Set<String>,
                              protecting protectedIds: Set<String>,
                              fetchOperation: (ModelContext, FetchDescriptor<TeamMessage>) throws -> [TeamMessage] = { try $0.fetch($1) }) {
        var failure: Error?
        let messages = context.fetchOrEmpty(FetchDescriptor<TeamMessage>(), "team.orphans.messages.fetch",
            failure: &failure, operation: { try fetchOperation(context, $0) })
        guard failure == nil else { return }
        for message in messages where !validChannelIds.contains(message.channelId)
            && !protectedIds.contains(message.id) {
            context.delete(message)
        }
    }
}
