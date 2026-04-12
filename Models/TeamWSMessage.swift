import Foundation

// MARK: - Supporting Types

struct TeamChannelInfo {
    let id: String
    let type: String        // "channel" or "dm"
    let name: String
    let members: [String]
}

struct TeamCommandInfo {
    let name: String
    let description: String
}

struct TeamAgentInfo {
    let id: String
    let name: String
    let icon: String
    let title: String?
    let model: String
    let status: String      // "idle", "processing", "error", "stopped"
    let tools: [String]
    let schedule: [[String: String]]   // [{ "cron": "...", "task": "..." }]
    let channels: [String]
    let messagesProcessed: Int
    let lastActivity: String?          // ISO 8601, nil if agent never messaged
}

struct TeamHistoryMessage {
    let id: String          // Server ObjectId
    let channelId: String
    let senderId: String
    let senderType: String  // "agent" or "person"
    let senderName: String
    let text: String
    let createdAt: Date
    let threadId: String?
}

// MARK: - Client -> Server

enum TeamWSOutgoing {
    case teamMessage(channelId: String, text: String, threadId: String?)
    case teamImage(channelId: String, data: String, filename: String)
    case teamFile(channelId: String, data: String, filename: String, mimetype: String)
    case join(channelId: String)
    case leave(channelId: String)
    case command(channelId: String, name: String, args: [String])
    case commandList
    case channelList
    case agentList
    case history(channelId: String, before: String?, limit: Int?)
    case ping

    /// Encode without returning the request ID (fire-and-forget).
    func encode() throws -> Data {
        try encodeWithId().data
    }

    /// Encode and return both the Data and the request UUID for correlation.
    func encodeWithId() throws -> (data: Data, id: String) {
        let id = UUID().uuidString
        var dict: [String: Any] = ["id": id]
        switch self {
        case .teamMessage(let channelId, let text, let threadId):
            dict["type"] = "message"
            dict["channelId"] = channelId
            dict["text"] = text
            if let threadId { dict["threadId"] = threadId }
        case .teamImage(let channelId, let data, let filename):
            dict["type"] = "image"
            dict["channelId"] = channelId
            dict["data"] = data
            dict["filename"] = filename
        case .teamFile(let channelId, let data, let filename, let mimetype):
            dict["type"] = "file"
            dict["channelId"] = channelId
            dict["data"] = data
            dict["filename"] = filename
            dict["mimetype"] = mimetype
        case .join(let channelId):
            dict["type"] = "join"
            dict["channelId"] = channelId
        case .leave(let channelId):
            dict["type"] = "leave"
            dict["channelId"] = channelId
        case .command(let channelId, let name, let args):
            dict["type"] = "command"
            dict["channelId"] = channelId
            dict["name"] = name
            dict["args"] = args
        case .commandList:
            dict["type"] = "command_list"
        case .channelList:
            dict["type"] = "channel_list"
        case .agentList:
            dict["type"] = "agent_list"
        case .history(let channelId, let before, let limit):
            dict["type"] = "history"
            dict["channelId"] = channelId
            if let before { dict["before"] = before }
            if let limit { dict["limit"] = limit }
        case .ping:
            // Server's ClientPing has no id field — send bare { "type": "ping" }
            let pingData = try JSONSerialization.data(withJSONObject: ["type": "ping"])
            return (data: pingData, id: id)
        }
        let data = try JSONSerialization.data(withJSONObject: dict)
        return (data: data, id: id)
    }
}

// MARK: - Server -> Client

enum TeamWSIncoming {
    case teamMessage(text: String, channelId: String, agentId: String, agentName: String, replyTo: String?)
    case systemMessage(text: String, agentId: String, agentName: String, replyTo: String?)
    case channelList(channels: [TeamChannelInfo], id: String)
    case commandList(commands: [TeamCommandInfo], id: String)
    case agentList(agents: [TeamAgentInfo], id: String)
    case history(channelId: String, messages: [TeamHistoryMessage], hasMore: Bool, id: String)
    case channelEvent(channelId: String, event: String, memberId: String?, id: String)
    case ack(id: String)
    case typing(agentId: String)
    case error(message: String)
    case pong

    static func decode(from data: Data) -> TeamWSIncoming? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return nil }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        switch type {
        case "message":
            guard let text = json["text"] as? String,
                  let agentId = json["agentId"] as? String,
                  let agentName = json["agentName"] as? String else { return nil }
            let replyTo = json["replyTo"] as? String
            // Messages with channelId are channel messages; without are system/command responses
            if let channelId = json["channelId"] as? String {
                return .teamMessage(text: text, channelId: channelId, agentId: agentId, agentName: agentName, replyTo: replyTo)
            } else {
                return .systemMessage(text: text, agentId: agentId, agentName: agentName, replyTo: replyTo)
            }
        case "channel_list":
            guard let channelsArray = json["channels"] as? [[String: Any]],
                  let id = json["id"] as? String else { return nil }
            let channels = channelsArray.compactMap { dict -> TeamChannelInfo? in
                guard let channelId = dict["id"] as? String,
                      let channelType = dict["type"] as? String,
                      let name = dict["name"] as? String else { return nil }
                let members = dict["members"] as? [String] ?? []
                return TeamChannelInfo(id: channelId, type: channelType, name: name, members: members)
            }
            return .channelList(channels: channels, id: id)
        case "command_list":
            guard let commandsArray = json["commands"] as? [[String: Any]],
                  let id = json["id"] as? String else { return nil }
            let commands = commandsArray.compactMap { dict -> TeamCommandInfo? in
                guard let name = dict["name"] as? String,
                      let desc = dict["description"] as? String else { return nil }
                return TeamCommandInfo(name: name, description: desc)
            }
            return .commandList(commands: commands, id: id)
        case "agent_list":
            guard let agentsArray = json["agents"] as? [[String: Any]],
                  let id = json["id"] as? String else { return nil }
            let agents = agentsArray.compactMap { dict -> TeamAgentInfo? in
                guard let agentId = dict["id"] as? String,
                      let name = dict["name"] as? String else { return nil }
                let icon = dict["icon"] as? String ?? ""
                let title = dict["title"] as? String
                let model = dict["model"] as? String ?? ""
                let status = dict["status"] as? String ?? "idle"
                let tools = dict["tools"] as? [String] ?? []
                let schedule = (dict["schedule"] as? [[String: String]]) ?? []
                let channels = dict["channels"] as? [String] ?? []
                let messagesProcessed = dict["messagesProcessed"] as? Int ?? 0
                let lastActivity = dict["lastActivity"] as? String
                return TeamAgentInfo(
                    id: agentId, name: name, icon: icon, title: title,
                    model: model, status: status, tools: tools,
                    schedule: schedule, channels: channels,
                    messagesProcessed: messagesProcessed, lastActivity: lastActivity
                )
            }
            return .agentList(agents: agents, id: id)
        case "history":
            guard let channelId = json["channelId"] as? String,
                  let messagesArray = json["messages"] as? [[String: Any]],
                  let hasMore = json["hasMore"] as? Bool,
                  let id = json["id"] as? String else { return nil }
            let messages = messagesArray.compactMap { dict -> TeamHistoryMessage? in
                guard let msgId = dict["id"] as? String,
                      let senderId = dict["senderId"] as? String,
                      let senderType = dict["senderType"] as? String,
                      let senderName = dict["senderName"] as? String,
                      let text = dict["text"] as? String,
                      let createdAtStr = dict["createdAt"] as? String,
                      let createdAt = iso.date(from: createdAtStr) else { return nil }
                let threadId = dict["threadId"] as? String
                return TeamHistoryMessage(
                    id: msgId, channelId: channelId, senderId: senderId,
                    senderType: senderType, senderName: senderName,
                    text: text, createdAt: createdAt, threadId: threadId
                )
            }
            return .history(channelId: channelId, messages: messages, hasMore: hasMore, id: id)
        case "channel_event":
            guard let channelId = json["channelId"] as? String,
                  let event = json["event"] as? String,
                  let id = json["id"] as? String else { return nil }
            var memberId: String?
            if let detail = json["detail"] as? [String: Any] {
                memberId = detail["memberId"] as? String
            }
            return .channelEvent(channelId: channelId, event: event, memberId: memberId, id: id)
        case "ack":
            guard let id = json["id"] as? String else { return nil }
            return .ack(id: id)
        case "typing":
            guard let agentId = json["agentId"] as? String else { return nil }
            return .typing(agentId: agentId)
        case "error":
            let message = json["message"] as? String ?? "Unknown error"
            return .error(message: message)
        case "pong":
            return .pong
        default:
            return nil
        }
    }
}
