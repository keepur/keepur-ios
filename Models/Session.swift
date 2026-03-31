import Foundation
import SwiftData

@Model
final class Session {
    @Attribute(.unique) var id: String
    var path: String
    var createdAt: Date
    var isStale: Bool

    init(id: String, path: String, createdAt: Date = .now, isStale: Bool = false) {
        self.id = id
        self.path = path
        self.createdAt = createdAt
        self.isStale = isStale
    }

    var displayName: String {
        (path as NSString).lastPathComponent
    }
}
