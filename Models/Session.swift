import Foundation
import SwiftData

@Model
final class Session {
    @Attribute(.unique) var id: String
    var path: String
    var isStale: Bool
    var createdAt: Date

    init(id: String, path: String, isStale: Bool = false, createdAt: Date = .now) {
        self.id = id
        self.path = path
        self.isStale = isStale
        self.createdAt = createdAt
    }
}
