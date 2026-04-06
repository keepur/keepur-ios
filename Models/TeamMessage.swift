import Foundation
import SwiftData

@Model
final class TeamMessage {
    @Attribute(.unique) var id: String
    var channelId: String
    var threadId: String?
    var senderId: String
    var senderType: String
    var senderName: String
    var text: String
    var createdAt: Date
    var pending: Bool

    init(
        id: String = UUID().uuidString,
        channelId: String,
        threadId: String? = nil,
        senderId: String,
        senderType: String,
        senderName: String,
        text: String,
        createdAt: Date = .now,
        pending: Bool = false
    ) {
        self.id = id
        self.channelId = channelId
        self.threadId = threadId
        self.senderId = senderId
        self.senderType = senderType
        self.senderName = senderName
        self.text = text
        self.createdAt = createdAt
        self.pending = pending
    }
}
