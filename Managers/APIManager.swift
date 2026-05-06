import Foundation

enum APIManager {
    struct PairResponse {
        let token: String
        let deviceId: String
        let deviceName: String
    }

    enum PairError: Error {
        case invalidCode
    }

    enum APIError: Error {
        case requestFailed
        case unauthorized
    }

    static func pair(code: String, name: String) async throws -> PairResponse {
        let baseURL = try BeekeeperConfig.httpsURL()
        let url = baseURL.appendingPathComponent("pair")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "code": code,
            "name": name
        ])

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["token"] as? String,
              let deviceId = json["deviceId"] as? String,
              let deviceName = json["deviceName"] as? String else {
            throw PairError.invalidCode
        }

        return PairResponse(token: token, deviceId: deviceId, deviceName: deviceName)
    }

    static func fetchCapabilities() async throws -> [String] {
        guard let token = KeychainManager.token else { throw APIError.unauthorized }

        let baseURL = try BeekeeperConfig.httpsURL()
        let url = baseURL.appendingPathComponent("capabilities")
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw APIError.requestFailed
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIError.requestFailed
        }
        if http.statusCode == 401 {
            throw APIError.unauthorized
        }
        guard http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let caps = json["capabilities"] as? [String] else {
            throw APIError.requestFailed
        }
        return caps
    }

    struct MeResponse {
        let deviceId: String
        let label: String
        let name: String
        let user: String
        let role: String
    }

    static func fetchMe() async throws -> MeResponse {
        guard let token = KeychainManager.token else { throw APIError.unauthorized }

        let baseURL = try BeekeeperConfig.httpsURL()
        let url = baseURL.appendingPathComponent("me")
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse, http.statusCode == 401 {
            throw APIError.unauthorized
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.requestFailed
        }
        let deviceId = json["deviceId"] as? String ?? ""
        let label = json["label"] as? String ?? ""
        let name = json["name"] as? String ?? label
        let user = json["user"] as? String ?? ""
        let role = json["role"] as? String ?? "member"
        return MeResponse(deviceId: deviceId, label: label, name: name, user: user, role: role)
    }
}
