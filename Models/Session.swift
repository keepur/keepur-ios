import Foundation
import SwiftData

@Model
final class Session {
    @Attribute(.unique) var id: String
    var path: String
    var name: String?
    var isStale: Bool
    var createdAt: Date

    init(id: String, path: String, name: String? = nil, isStale: Bool = false, createdAt: Date = .now) {
        self.id = id
        self.path = path
        self.name = name
        self.isStale = isStale
        self.createdAt = createdAt
    }

    var displayName: String {
        name ?? URL(fileURLWithPath: path).lastPathComponent
    }
}
