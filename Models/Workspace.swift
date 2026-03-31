import Foundation
import SwiftData

@Model
final class Workspace {
    @Attribute(.unique) var path: String
    var displayName: String
    var lastUsed: Date

    init(path: String, lastUsed: Date = .now) {
        self.path = path
        self.displayName = URL(fileURLWithPath: path).lastPathComponent
        self.lastUsed = lastUsed
    }
}
