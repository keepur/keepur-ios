import Foundation
import SwiftData

@Model
final class Session {
    @Attribute(.unique) var id: String
    var workspace: String
    var createdAt: Date

    init(id: String, workspace: String, createdAt: Date = .now) {
        self.id = id
        self.workspace = workspace
        self.createdAt = createdAt
    }
}
