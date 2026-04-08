import Foundation
import SwiftData

@Model
final class Message {
    @Attribute(.unique) var id: String
    var sessionId: String
    var text: String
    var role: String  // "user", "assistant", "system", "tool"
    var timestamp: Date

    init(
        id: String = UUID().uuidString,
        sessionId: String,
        text: String,
        role: String,
        timestamp: Date = .now
    ) {
        self.id = id
        self.sessionId = sessionId
        self.text = text
        self.role = role
        self.timestamp = timestamp
    }
}
