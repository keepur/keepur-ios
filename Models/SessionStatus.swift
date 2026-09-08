import Foundation

enum SessionStatus: Equatable {
    case idle, thinking, toolStarting, toolRunning, busy, sessionEnded
    case unknown(String)

    init(wire: String) {
        switch wire {
        case "idle": self = .idle
        case "thinking": self = .thinking
        case "tool_starting": self = .toolStarting
        case "tool_running": self = .toolRunning
        case "busy": self = .busy
        case "session_ended": self = .sessionEnded
        default: self = .unknown(wire)
        }
    }

    var wireValue: String {
        switch self {
        case .idle: return "idle"
        case .thinking: return "thinking"
        case .toolStarting: return "tool_starting"
        case .toolRunning: return "tool_running"
        case .busy: return "busy"
        case .sessionEnded: return "session_ended"
        case .unknown(let raw): return raw
        }
    }

    var isActive: Bool {
        switch self {
        case .idle, .sessionEnded: return false
        case .thinking, .toolStarting, .toolRunning, .busy, .unknown: return true
        }
    }

    var headerText: String? {
        switch self {
        case .idle: return nil
        case .thinking: return "thinking"
        case .toolStarting: return "starting tool"
        case .toolRunning: return "running tool"
        case .busy: return "server busy"
        case .sessionEnded: return "session_ended"
        case .unknown(let raw): return raw
        }
    }
}
