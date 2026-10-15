import Foundation

// MARK: - Server envelope
//
// Every Atomberg response is `{ "status": ..., "message": ... }`. On success
// `message` holds the payload; on failure it holds a description. The two are
// modelled separately so a failure can never be mistaken for an empty payload.

struct Envelope<Payload: Decodable>: Decodable {
    let message: Payload
}

struct FailureEnvelope: Decodable {
    let message: String?
}

// MARK: - Credentials

struct AccessTokenPayload: Decodable {
    let accessToken: String

    private enum CodingKeys: String, CodingKey { case accessToken = "access_token" }
}

// MARK: - Devices

/// One entry from `GET /get_list_of_devices`.
struct Device: Decodable, Identifiable, Sendable {
    let deviceID: String
    let name: String?
    let deviceType: String?
    let supportedCommands: [CommandSpec]

    /// `device_id` is the identifier every other endpoint expects.
    var id: String { deviceID }

    var displayName: String { name?.isEmpty == false ? name! : deviceID }
    var kind: String { deviceType ?? "device" }
    var isFan: Bool { kind == "fan" }

    /// The API is the authority on what this device accepts; the UI mirrors it.
    func supports(_ command: String) -> Bool {
        supportedCommands.contains { $0.command == command }
    }

    var supportedCommandNames: Set<String> {
        Set(supportedCommands.map(\.command))
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deviceID = c.tolerantString(.deviceID) ?? ""
        name = c.tolerantString(.name)
        deviceType = c.tolerantString(.deviceType)
        supportedCommands = c.tolerantArray(.supportedCommands, as: CommandSpec.self)
    }

    private enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case name
        case deviceType = "device_type"
        case supportedCommands = "supported_commands"
    }
}

/// One entry of a device's `supported_commands` list. The app only needs the
/// name; the rest of each entry is prose for humans.
struct CommandSpec: Decodable, Sendable {
    let command: String

    private enum CodingKeys: String, CodingKey { case command }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        command = c.tolerantString(.command) ?? ""
    }
}

struct DeviceListPayload: Decodable {
    let devicesList: [Device]

    private enum CodingKeys: String, CodingKey { case devicesList = "devices_list" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        devicesList = c.tolerantArray(.devicesList, as: Device.self)
    }
}

// MARK: - State

/// `GET /get_device_state`. Fan fields only — the endpoints listed in the spec
/// for purge and lock data are outside this app's scope.
///
/// Fields are optional on purpose: older firmware on the same series reports
/// fewer keys, and a key that has never been reported is missing rather than
/// `null`.
struct FanState: Decodable, Sendable {
    // Declared `var` so a command can be reflected locally the moment it is
    // sent, before the device confirms it.
    var deviceID: String?
    var power: Bool?
    /// Reported as `last_recorded_speed` (1...6).
    var speed: Int?
    var sleepMode: Bool?
    var led: Bool?
    var isOnline: Bool?
    var timerHours: Int?
    /// `ts_epoch_seconds` — when the device last reported this state.
    var reportedAt: Date?
    var brightness: Int?
    var color: String?
    var revMode: Bool?
    var buzzerStatus: Bool?

    private enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case power
        case speed = "last_recorded_speed"
        case sleepMode = "sleep_mode"
        case led
        case isOnline = "is_online"
        case timerHours = "timer_hours"
        case reportedAt = "ts_epoch_seconds"
        case brightness = "last_recorded_brightness"
        case color = "last_recorded_color"
        case revMode = "rev_mode"
        case buzzerStatus = "buzzer_status"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deviceID = c.tolerantString(.deviceID)
        power = c.tolerantBool(.power)
        speed = c.tolerantInt(.speed)
        sleepMode = c.tolerantBool(.sleepMode)
        led = c.tolerantBool(.led)
        isOnline = c.tolerantBool(.isOnline)
        timerHours = c.tolerantInt(.timerHours)
        brightness = c.tolerantInt(.brightness)
        color = c.tolerantString(.color)
        revMode = c.tolerantBool(.revMode)
        buzzerStatus = c.tolerantBool(.buzzerStatus)
        if let seconds = c.tolerantInt(.reportedAt), seconds > 0 {
            reportedAt = Date(timeIntervalSince1970: TimeInterval(seconds))
        } else {
            reportedAt = nil
        }
    }
}

struct DeviceStatePayload: Decodable {
    let deviceState: [FanState]

    private enum CodingKeys: String, CodingKey { case deviceState = "device_state" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deviceState = c.tolerantArray(.deviceState, as: FanState.self)
    }
}

// MARK: - Analytics

/// `GET /get_device_analytics`. The response key is `device_state` here too —
/// the spec keeps that name for compatibility.
///
/// A counter the device has never reported comes back as `null`, which is not
/// the same thing as a real zero.
struct FanAnalytics: Decodable, Sendable {
    let deviceID: String?
    /// Lifetime energy in kWh.
    let powerConsumption: Double?
    /// Lifetime running time in hours.
    let runtime: Double?

    private enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case powerConsumption = "power_consumption"
        case runtime
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deviceID = c.tolerantString(.deviceID)
        powerConsumption = c.tolerantDouble(.powerConsumption)
        runtime = c.tolerantDouble(.runtime)
    }
}

struct DeviceAnalyticsPayload: Decodable {
    let deviceState: [FanAnalytics]

    private enum CodingKeys: String, CodingKey { case deviceState = "device_state" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deviceState = c.tolerantArray(.deviceState, as: FanAnalytics.self)
    }
}

// MARK: - Commands

/// Values accepted by `POST /send_command`.
enum CommandValue: Encodable, Sendable, Equatable {
    case bool(Bool)
    case int(Int)
    case string(String)

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .bool(let value): try c.encode(value)
        case .int(let value): try c.encode(value)
        case .string(let value): try c.encode(value)
        }
    }
}

struct CommandBody: Encodable {
    let deviceID: String
    let command: [String: CommandValue]

    private enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case command
    }
}

// MARK: - Errors

struct AtombergError: Error, Sendable, LocalizedError {
    let status: Int
    let message: String

    var errorDescription: String? { message }

    var hint: String? {
        switch status {
        case 401: return "Check the API key, or fetch a new access token."
        case 403: return "Developer Mode is off, or the URL/method is wrong."
        case 404: return "The device is not on this account, or has not reported state yet."
        case 429: return "Quota used up or more than 5 calls/second."
        case 501: return "This device series is not supported by the API."
        case 503: return "The fan is offline, so the command was not delivered."
        case 504: return "The request took longer than 29 seconds."
        default: return nil
        }
    }
}

// MARK: - Lenient decoding helpers
//
// Firmware versions differ in how they type a value (a boolean can arrive as
// `true`, `1` or `"1"`), and a field that was never reported is simply absent.
// These helpers keep decoding from failing on a shape the spec allows.

extension KeyedDecodingContainer {
    func tolerantString(_ key: Key) -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return String(value) }
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return String(value) }
        return nil
    }

    func tolerantBool(_ key: Key) -> Bool? {
        if let value = try? decodeIfPresent(Bool.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return value != 0 }
        if let text = try? decodeIfPresent(String.self, forKey: key) {
            switch text.lowercased() {
            case "true", "1", "on", "yes": return true
            case "false", "0", "off", "no": return false
            default: return nil
            }
        }
        return nil
    }

    func tolerantInt(_ key: Key) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return Int(value) }
        if let text = try? decodeIfPresent(String.self, forKey: key) { return Int(text) }
        return nil
    }

    func tolerantDouble(_ key: Key) -> Double? {
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return value }
        if let text = try? decodeIfPresent(String.self, forKey: key) { return Double(text) }
        return nil
    }

    func tolerantArray<T: Decodable>(_ key: Key, as type: T.Type) -> [T] {
        (try? decodeIfPresent([T].self, forKey: key)) ?? []
    }
}
