import Foundation

enum SessionMode: Equatable {
    case sessions, concierge
    case unknown(String)

    init(wire: String) {
        switch wire {
        case "sessions": self = .sessions
        case "concierge": self = .concierge
        default: self = .unknown(wire)
        }
    }

    var wireValue: String {
        switch self {
        case .sessions: return "sessions"
        case .concierge: return "concierge"
        case .unknown(let raw): return raw
        }
    }
}
