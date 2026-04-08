import Foundation
import SwiftData

@Model
final class Message {
    @Attribute(.unique) var id: String
    var sessionId: String
    var text: String
    var role: String  // "user", "assistant", "system", "tool"
    var timestamp: Date
    var attachmentName: String?
    var attachmentType: String?
    @Attribute(.externalStorage) var attachmentData: Data?

    init(
        id: String = UUID().uuidString,
        sessionId: String,
        text: String,
        role: String,
        timestamp: Date = .now,
        attachmentName: String? = nil,
        attachmentType: String? = nil,
        attachmentData: Data? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.text = text
        self.role = role
        self.timestamp = timestamp
        self.attachmentName = attachmentName
        self.attachmentType = attachmentType
        self.attachmentData = attachmentData
    }
}
