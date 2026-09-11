import Foundation

struct TeamMessageSnapshot: Equatable {
    let id: String
    let serverId: String?
    let channelId: String
    let senderId: String
    let senderType: SenderType
    let senderName: String
    let text: String
    let threadId: String?
    let createdAt: Date
    let pending: Bool
}

struct MergeResult {
    let inserts: [TeamHistoryMessage]
    let serverIdStamps: [String: String]
    let unpendIds: Set<String>
}

enum HistoryMerger {
    static func chronological(_ lhs: TeamHistoryMessage, _ rhs: TeamHistoryMessage) -> Bool {
        lhs.createdAt == rhs.createdAt ? lhs.id < rhs.id : lhs.createdAt < rhs.createdAt
    }

    static func merge(existing: [TeamMessageSnapshot], incoming: [TeamHistoryMessage],
                      ownDeviceId: String, now: Date) -> MergeResult {
        // Call-time identity and clock are deliberately not additional match filters.
        _ = ownDeviceId
        _ = now
        var known = Set(existing.compactMap(\.serverId))
        let incomingIds = Set(incoming.map(\.id))
        let legacy = existing.filter { $0.serverId == nil && incomingIds.contains($0.id) }
        let reserved = Set(legacy.map(\.id))
        var consumed = Set<String>()
        var stamps: [String: String] = [:]
        var unpend = Set<String>()
        var inserts: [TeamHistoryMessage] = []
        for message in incoming.sorted(by: chronological) {
            guard !known.contains(message.id) else { continue }
            if let row = legacy.first(where: { $0.id == message.id }) {
                stamps[row.id] = message.id
                unpend.insert(row.id)
                consumed.insert(row.id)
            } else {
                let candidate = existing.filter {
                    $0.serverId == nil && !consumed.contains($0.id) && !reserved.contains($0.id)
                    && $0.channelId == message.channelId && $0.senderId == message.senderId
                    && $0.text == message.text
                    && abs($0.createdAt.timeIntervalSince(message.createdAt)) < 30
                }.min { lhs, rhs in
                    let l = abs(lhs.createdAt.timeIntervalSince(message.createdAt))
                    let r = abs(rhs.createdAt.timeIntervalSince(message.createdAt))
                    if l != r { return l < r }
                    if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                    return lhs.id < rhs.id
                }
                if let row = candidate {
                    stamps[row.id] = message.id
                    unpend.insert(row.id)
                    consumed.insert(row.id)
                } else {
                    inserts.append(message)
                }
            }
            known.insert(message.id)
        }
        return MergeResult(inserts: inserts, serverIdStamps: stamps, unpendIds: unpend)
    }
}
