import Foundation
import SwiftData

@Model
final class Workspace {
    @Attribute(.unique) var path: String
    var lastUsed: Date

    init(path: String, lastUsed: Date = .now) {
        self.path = path
        self.lastUsed = lastUsed
    }

    var displayName: String {
        (path as NSString).lastPathComponent
    }
}
