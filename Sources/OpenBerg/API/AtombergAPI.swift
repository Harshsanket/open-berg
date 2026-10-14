import Foundation

/// Thin, typed wrapper over the five published endpoints this app uses:
///
///   GET  /get_access_token      – refresh token  -> 24h access token
///   GET  /get_list_of_devices   – devices plus the commands each one accepts
///   GET  /get_device_state      – last state the device reported
///   GET  /get_device_analytics  – lifetime energy and runtime
///   POST /send_command          – deliver a command
///
/// `POST /get_lock_dynamic_pin` belongs to smart locks, so it is deliberately
/// not implemented here.
struct AtombergAPI: Sendable {
    enum Environment: String, CaseIterable, Identifiable, Sendable {
        case production
        case development

        var id: String { rawValue }

        var title: String {
            switch self {
            case .production: return "Production"
            case .development: return "Development"
            }
        }

        var baseURL: URL {
            switch self {
            case .production:
                return URL(string: "https://api.developer.atomberg-iot.com/v2")!
            case .development:
                return URL(string: "https://6yrk5x4p32.execute-ap-south-1.amazonaws.com/dev")!
            }
        }
    }

    let environment: Environment
    let apiKey: String

    // MARK: Requests

    /// The only endpoint that takes the refresh token.
    func accessToken(refreshToken: String) async throws -> String {
        let payload: AccessTokenPayload = try await perform(
            path: "/get_access_token",
            query: [],
            bearer: refreshToken
        )
        return payload.accessToken
    }

    func devices(accessToken: String) async throws -> [Device] {
        let payload: DeviceListPayload = try await perform(
            path: "/get_list_of_devices",
            query: [],
            bearer: accessToken
        )
        return payload.devicesList.filter { !$0.deviceID.isEmpty }
    }

    /// `device_id=all` returns every supported device in a single call, which
    /// counts as one request against the quota.
    func deviceState(accessToken: String, deviceID: String = "all") async throws -> [FanState] {
        let payload: DeviceStatePayload = try await perform(
            path: "/get_device_state",
            query: [URLQueryItem(name: "device_id", value: deviceID)],
            bearer: accessToken
        )
        return payload.deviceState
    }

    func analytics(accessToken: String, deviceID: String = "all") async throws -> [FanAnalytics] {
        let payload: DeviceAnalyticsPayload = try await perform(
            path: "/get_device_analytics",
            query: [URLQueryItem(name: "device_id", value: deviceID)],
            bearer: accessToken
        )
        return payload.deviceState
    }

    /// A success here means the command was *accepted*, not applied.
    func sendCommand(
        accessToken: String,
        deviceID: String,
        command: [String: CommandValue]
    ) async throws {
        let body = try JSONEncoder().encode(CommandBody(deviceID: deviceID, command: command))
        let _: String = try await perform(
            path: "/send_command",
            method: "POST",
            query: [],
            bearer: accessToken,
            jsonBody: body
        )
    }

    // MARK: Transport

    private func perform<Payload: Decodable>(
        path: String,
        method: String = "GET",
        query: [URLQueryItem],
        bearer: String,
        jsonBody: Data? = nil
    ) async throws -> Payload {
        guard !apiKey.isEmpty else {
            throw AtombergError(status: 0, message: "No API key saved yet.")
        }
        var components = URLComponents(
            url: environment.baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )!
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else {
            throw AtombergError(status: 0, message: "Could not build the request URL.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = jsonBody
        request.timeoutInterval = 35
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        if jsonBody != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        var attempt = 0
        while true {
            attempt += 1
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw AtombergError(status: 0, message: "Unexpected response from the server.")
                }

                if (200...299).contains(http.statusCode) {
                    do {
                        let envelope = try JSONDecoder().decode(Envelope<Payload>.self, from: data)
                        return envelope.message
                    } catch {
                        throw AtombergError(
                            status: http.statusCode,
                            message: "Could not read the response: \(error.localizedDescription)"
                        )
                    }
                }

                let described = (try? JSONDecoder().decode(FailureEnvelope.self, from: data))?.message
                let error = AtombergError(
                    status: http.statusCode,
                    message: described ?? "HTTP \(http.statusCode)"
                )
                if attempt < Self.maxAttempts, AtombergError.isRetryable(http.statusCode) {
                    try await Self.backoff(attempt: attempt, response: http)
                    continue
                }
                throw error
            } catch let error as AtombergError {
                throw error
            } catch {
                // Transport failure (offline, DNS, timeout).
                let wrapped = AtombergError(
                    status: 0,
                    message: error.localizedDescription
                )
                if attempt < Self.maxAttempts {
                    try await Self.backoff(attempt: attempt, response: nil)
                    continue
                }
                throw wrapped
            }
        }
    }

    private static let maxAttempts = 3

    /// Only 429/500/502/503/504 are retried, and never faster than the
    /// documented 5 requests/second ceiling.
    private static func backoff(attempt: Int, response: HTTPURLResponse?) async throws {
        if let header = response?.value(forHTTPHeaderField: "Retry-After"),
           let seconds = Double(header), seconds > 0 {
            try await Task.sleep(for: .seconds(min(seconds, 10)))
            return
        }
        let base = attempt == 1 ? 0.6 : 1.8
        try await Task.sleep(for: .seconds(base))
    }
}
