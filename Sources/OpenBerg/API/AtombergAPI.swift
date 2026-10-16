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
///
/// Every request is single-shot: a failed attempt still counts against the
/// daily quota, so nothing is ever retried automatically.
struct AtombergAPI: Sendable {
    /// There is one backend and no environment switch.
    static let baseURL = URL(string: "https://api.developer.atomberg-iot.com/v2")!

    let apiKey: String

    /// Invoked once per request, right before it is sent. A transport failure
    /// is a real request against the daily quota, so the count lives at the
    /// transport rather than at each call site. Defaults to doing nothing;
    /// `AppModel` injects the tally.
    var recordCall: @Sendable () -> Void = {}

    /// One ephemeral session for every request. Nothing here is worth
    /// caching: reads are already sent with a no-cache policy, so a disk
    /// cache would only leave `Cache.db`/`HTTPStorages` files behind and map
    /// them into the process. Ephemeral keeps response storage in memory
    /// only, and `urlCache = nil` drops even that.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

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
            url: Self.baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )!
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else {
            throw AtombergError(status: 0, message: "Could not build the request URL.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = jsonBody
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        if jsonBody != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        recordCall()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch {
            // Transport failure (offline, DNS, timeout). Still a call spent.
            throw AtombergError(status: 0, message: error.localizedDescription)
        }
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
        throw AtombergError(
            status: http.statusCode,
            message: described ?? "HTTP \(http.statusCode)"
        )
    }
}
