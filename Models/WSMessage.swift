import Foundation

// MARK: - Client -> Server

enum WSOutgoing {
    case message(text: String, sessionId: String? = nil)
    case newSession(workspace: String? = nil)
    case approve(toolUseId: String)
    case deny(toolUseId: String)
    case ping

    func encode() throws -> Data {
        let dict: [String: Any]
        switch self {
        case .message(let text, let sessionId):
            var d: [String: Any] = ["type": "message", "text": text]
            if let sessionId { d["sessionId"] = sessionId }
            dict = d
        case .newSession(let workspace):
            var d: [String: Any] = ["type": "new_session"]
            if let workspace { d["workspace"] = workspace }
            dict = d
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
    case toolApproval(toolUseId: String, tool: String, input: String)
    case status(state: String)
    case sessionInfo(sessionId: String, workspace: String, workspaces: [String])
    case error(message: String)
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
            return .toolApproval(toolUseId: toolUseId, tool: tool, input: input)
        case "status":
            guard let state = json["state"] as? String else { return nil }
            return .status(state: state)
        case "session_info":
            guard let sessionId = json["sessionId"] as? String,
                  let workspace = json["workspace"] as? String else { return nil }
            let workspaces = json["workspaces"] as? [String] ?? []
            return .sessionInfo(sessionId: sessionId, workspace: workspace, workspaces: workspaces)
        case "error":
            guard let message = json["message"] as? String else { return nil }
            return .error(message: message)
        case "pong":
            return .pong
        default:
            return nil
        }
    }
}
