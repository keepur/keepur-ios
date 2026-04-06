import Foundation
import SwiftData

@Model
final class TeamChannel {
    @Attribute(.unique) var id: String
    var type: String
    var name: String
    var members: [String]
    var lastMessageText: String?
    var lastMessageAt: Date?
    var lastServerMessageId: String?
    var updatedAt: Date

    init(
        id: String,
        type: String,
        name: String,
        members: [String] = [],
        lastMessageText: String? = nil,
        lastMessageAt: Date? = nil,
        lastServerMessageId: String? = nil,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.type = type
        self.name = name
        self.members = members
        self.lastMessageText = lastMessageText
        self.lastMessageAt = lastMessageAt
        self.lastServerMessageId = lastServerMessageId
        self.updatedAt = updatedAt
    }

    var displayName: String {
        type == "channel" ? "#\(name)" : name
    }
}
