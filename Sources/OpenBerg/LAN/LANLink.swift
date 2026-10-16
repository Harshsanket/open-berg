import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// Local-network transport for fans, using the UDP behaviour described under
/// "Sending the command locally" in the API reference:
///
///   * every fan broadcasts a beacon on port **5625** roughly once a second,
///     carrying its MAC address followed by its series;
///   * a command can be delivered to `<device ip>:5600` as the same JSON body
///     `POST /send_command` would carry.
///
/// This is the preferred path while the panel is open — the cloud API is the
/// documented path and stays the fallback. It matters because the free plan
/// allows only 100 calls a day, which a state-refresh loop would exhaust in
/// minutes.
///
/// `device_id` values are 12 hexadecimal characters, the same shape as a MAC,
/// so a device is matched to a beacon by comparing normalised forms. If a
/// device cannot be matched, the app simply keeps using the cloud.
final class LANLink: @unchecked Sendable {
    struct Beacon: Sendable, Equatable {
        /// 12 lower-case hex characters, separators removed.
        let mac: String
        let series: String?
        let host: String
    }

    enum Ports {
        static let beacon: UInt16 = 5625
        static let command: UInt16 = 5600
    }

    private let queue = DispatchQueue(label: "com.openberg.OpenBerg.lan", qos: .utility)
    private var beaconFD: Int32 = -1
    private var beaconSource: DispatchSourceRead?
    private var stateFD: Int32 = -1
    private var stateSource: DispatchSourceRead?
    private var running = false

    /// Where each fan was last heard, and when that was last passed on.
    /// Beacons repeat about once a second; a repeat with an unchanged host is
    /// dropped until the heartbeat interval passes, so the main actor is not
    /// woken once a second for nothing. The heartbeat still keeps the
    /// recorded host fresh enough to trust.
    private struct Heard {
        var host: String
        var passedAt: Date
    }
    private var heardByMAC: [String: Heard] = [:]

    /// How often an unchanged beacon is still passed on.
    private static let beaconHeartbeat: TimeInterval = 60

    /// One receive buffer reused across packets, and one command socket
    /// opened on first use. Both are touched only on `queue`.
    private var receiveBuffer = [UInt8](repeating: 0, count: 2048)
    private var commandFD: Int32 = -1

    private let onBeacon: @Sendable (Beacon) -> Void
    private let onStatePacket: @Sendable (Data) -> Void

    init(
        onBeacon: @escaping @Sendable (Beacon) -> Void,
        onStatePacket: @escaping @Sendable (Data) -> Void
    ) {
        self.onBeacon = onBeacon
        self.onStatePacket = onStatePacket
    }

    deinit { stop() }

    // MARK: Lifecycle

    func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            heardByMAC.removeAll()
            let beacon = Self.openSocket(port: Ports.beacon)
            beaconFD = beacon
            if beacon >= 0 {
                // Weak capture: the source is owned by this object, so a strong
                // capture inside its handler would keep both alive forever.
                beaconSource = Self.readSource(for: beacon, queue: queue) { [weak self] in
                    self?.drain(beacon, isBeacon: true)
                }
            }
            // Failing to listen for beacons is not fatal: the cloud path stays.
            let state = Self.openSocket(port: Ports.command)
            stateFD = state
            if state >= 0 {
                stateSource = Self.readSource(for: state, queue: queue) { [weak self] in
                    self?.drain(state, isBeacon: false)
                }
            }
            // Port 5600 may already be held by another listener; that is not fatal.
        }
    }

    func stop() {
        let sources = [beaconSource, stateSource].compactMap { $0 }
        sources.forEach { $0.cancel() }
        beaconSource = nil
        stateSource = nil
        queue.sync { [self] in
            if beaconFD >= 0 { close(beaconFD); beaconFD = -1 }
            if stateFD >= 0 { close(stateFD); stateFD = -1 }
            if commandFD >= 0 { close(commandFD); commandFD = -1 }
            running = false
        }
    }

    // MARK: Sending

    /// Fire-and-forget delivery of a command body to a fan on the LAN.
    /// The socket is opened on first use and then reused; commands are rare,
    /// but a fresh socket per tap is still a syscall pair worth avoiding.
    func send(_ payload: Data, to host: String) {
        queue.async { [self] in
            if commandFD < 0 {
                commandFD = socket(AF_INET, SOCK_DGRAM, 0)
            }
            let fd = commandFD
            guard fd >= 0 else { return }

            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = Ports.command.bigEndian
            guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return }

            _ = withUnsafePointer(to: &address) { pointer -> Int in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    payload.withUnsafeBytes { buffer in
                        sendto(
                            fd, buffer.baseAddress, payload.count, 0,
                            socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size)
                        )
                    }
                }
            }
        }
    }

    // MARK: Socket plumbing

    private static func openSocket(port: UInt16) -> Int32 {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return -1 }

        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_ANY)

        let bound = withUnsafePointer(to: &address) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                bind(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            close(fd)
            return -1
        }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        return fd
    }

    private static func readSource(
        for fd: Int32,
        queue: DispatchQueue,
        handler: @escaping @Sendable () -> Void
    ) -> DispatchSourceRead {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler(handler: handler)
        source.resume()
        return source
    }

    private func drain(_ fd: Int32, isBeacon: Bool) {
        while true {
            var sender = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let received = withUnsafeMutablePointer(to: &sender) { pointer -> Int in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    recvfrom(fd, &receiveBuffer, receiveBuffer.count, 0, socketAddress, &length)
                }
            }
            guard received > 0 else { return }

            var host = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var address = sender.sin_addr
            inet_ntop(AF_INET, &address, &host, socklen_t(INET_ADDRSTRLEN))
            let hostString = Self.string(host)
            let packet = Data(receiveBuffer[0..<received])

            if isBeacon {
                guard let beacon = Self.parseBeacon(packet, host: hostString) else { continue }
                let now = Date()
                if let heard = heardByMAC[beacon.mac], heard.host == beacon.host,
                   now.timeIntervalSince(heard.passedAt) < Self.beaconHeartbeat {
                    continue
                }
                heardByMAC[beacon.mac] = Heard(host: beacon.host, passedAt: now)
                onBeacon(beacon)
            } else {
                onStatePacket(packet)
            }
        }
    }

    /// Reads a NUL-terminated C string produced by `inet_ntop`.
    private static func string(_ buffer: [CChar]) -> String {
        let end = buffer.firstIndex(of: 0) ?? buffer.count
        return String(decoding: buffer[..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Beacon layout: the device MAC followed by its series, e.g.
    /// `a1b2c3d4e5f6R1`.
    static func parseBeacon(_ packet: Data, host: String) -> Beacon? {
        guard let text = String(data: packet, encoding: .utf8) else { return nil }
        let mac = normalise(text)
        guard mac.count >= 12 else { return nil }
        let trimmed = String(mac.prefix(12))
        let remainder = String(text.dropFirst(12)).trimmingCharacters(in: .whitespacesAndNewlines)
        return Beacon(
            mac: trimmed,
            series: remainder.isEmpty ? nil : remainder,
            host: host
        )
    }

    /// Lower-cases and strips separators so `a1:b2:...` and `a1b2...` compare equal.
    static func normalise(_ value: String) -> String {
        value.lowercased().filter { $0.isHexDigit }
    }
}
