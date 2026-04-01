import Foundation

// MARK: - Supporting Types

struct ServerSession {
    let sessionId: String
    let path: String
    let state: String
}

struct BrowseEntry {
    let name: String
    let isDirectory: Bool
}

struct WorkspaceSession {
    let sessionId: String
    let lastActiveAt: Date
    let preview: String
    let active: Bool
}

// MARK: - Client -> Server

enum WSOutgoing {
    case message(text: String, sessionId: String)
    case newSession(path: String)
    case clearSession(sessionId: String)
    case listSessions
    case browse(path: String? = nil)
    case listWorkspaceSessions(path: String)
    case resumeSession(sessionId: String, path: String)
    case approve(toolUseId: String)
    case deny(toolUseId: String)
    case ping

    func encode() throws -> Data {
        let dict: [String: Any]
        switch self {
        case .message(let text, let sessionId):
            dict = ["type": "message", "text": text, "sessionId": sessionId]
        case .newSession(let path):
            dict = ["type": "new_session", "path": path]
        case .clearSession(let sessionId):
            dict = ["type": "clear_session", "sessionId": sessionId]
        case .listSessions:
            dict = ["type": "list_sessions"]
        case .browse(let path):
            var d: [String: Any] = ["type": "browse"]
            if let path { d["path"] = path }
            dict = d
        case .listWorkspaceSessions(let path):
            dict = ["type": "list_workspace_sessions", "path": path]
        case .resumeSession(let sessionId, let path):
            dict = ["type": "resume_session", "sessionId": sessionId, "path": path]
        case .approve(let toolUseId):
            dict = ["type": "approve", "toolUseId": toolUseId]
        case .deny(let toolUseId):
            dict = ["type": "deny", "toolUseId": toolUseId]
        case .ping:
            dict = ["type": "ping"]
        }
        return try JSONSerialization.data(withJSONObject: dict)
    }
}

// MARK: - Server -> Client

enum WSIncoming {
    case message(text: String, sessionId: String, final: Bool)
    case toolApproval(toolUseId: String, tool: String, input: String, sessionId: String?)
    case status(state: String, sessionId: String?)
    case sessionInfo(sessionId: String, path: String)
    case sessionList(sessions: [ServerSession])
    case sessionCleared(sessionId: String)
    case browseResult(path: String, entries: [BrowseEntry])
    case workspaceSessionList(path: String, sessions: [WorkspaceSession])
    case error(message: String, sessionId: String?)
    case pong

    static func decode(from data: Data) -> WSIncoming? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return nil }

        switch type {
        case "message":
            guard let text = json["text"] as? String,
                  let sessionId = json["sessionId"] as? String,
                  let final = json["final"] as? Bool else { return nil }
            return .message(text: text, sessionId: sessionId, final: final)
        case "tool_approval":
            guard let toolUseId = json["toolUseId"] as? String,
                  let tool = json["tool"] as? String,
                  let input = json["input"] as? String else { return nil }
            let sessionId = json["sessionId"] as? String
            return .toolApproval(toolUseId: toolUseId, tool: tool, input: input, sessionId: sessionId)
        case "status":
            guard let state = json["state"] as? String else { return nil }
            let sessionId = json["sessionId"] as? String
            return .status(state: state, sessionId: sessionId)
        case "session_info":
            guard let sessionId = json["sessionId"] as? String,
                  let path = json["path"] as? String else { return nil }
            return .sessionInfo(sessionId: sessionId, path: path)
        case "session_list":
            guard let sessionsArray = json["sessions"] as? [[String: Any]] else { return nil }
            let sessions = sessionsArray.compactMap { dict -> ServerSession? in
                guard let sessionId = dict["sessionId"] as? String,
                      let path = dict["path"] as? String,
                      let state = dict["state"] as? String else { return nil }
                return ServerSession(sessionId: sessionId, path: path, state: state)
            }
            return .sessionList(sessions: sessions)
        case "session_cleared":
            guard let sessionId = json["sessionId"] as? String else { return nil }
            return .sessionCleared(sessionId: sessionId)
        case "browse_result":
            guard let path = json["path"] as? String,
                  let entriesArray = json["entries"] as? [[String: Any]] else { return nil }
            let entries = entriesArray.compactMap { dict -> BrowseEntry? in
                guard let name = dict["name"] as? String,
                      let isDirectory = dict["isDirectory"] as? Bool else { return nil }
                return BrowseEntry(name: name, isDirectory: isDirectory)
            }
            return .browseResult(path: path, entries: entries)
        case "workspace_session_list":
            guard let path = json["path"] as? String,
                  let sessionsArray = json["sessions"] as? [[String: Any]] else { return nil }
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let sessions = sessionsArray.compactMap { dict -> WorkspaceSession? in
                guard let sessionId = dict["sessionId"] as? String,
                      let lastActiveStr = dict["lastActiveAt"] as? String,
                      let preview = dict["preview"] as? String,
                      let active = dict["active"] as? Bool,
                      let lastActive = iso.date(from: lastActiveStr) else { return nil }
                return WorkspaceSession(sessionId: sessionId, lastActiveAt: lastActive, preview: preview, active: active)
            }
            return .workspaceSessionList(path: path, sessions: sessions)
        case "error":
            guard let message = json["message"] as? String else { return nil }
            let sessionId = json["sessionId"] as? String
            return .error(message: message, sessionId: sessionId)
        case "pong":
            return .pong
        default:
            return nil
        }
    }
}
