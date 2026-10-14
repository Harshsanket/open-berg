import AppKit
import Foundation
import Observation

/// Everything the UI needs, in one main-actor object.
///
/// Two deliberate constraints shape this type:
///
/// * **Quota.** The free plan allows 100 calls a day at 5 calls/second, and
///   failed calls count. So the access token is cached for its full 24 hours,
///   `device_id=all` is used for state and analytics, and every request goes
///   through `CallBudget`, which the UI surfaces.
/// * **The spec is the interface.** Controls are only offered for commands the
///   device itself lists in `supported_commands`, and nothing outside the
///   published endpoints is invented.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    struct Status: Equatable {
        enum Kind: Equatable { case idle, info, error }
        var kind: Kind = .idle
        var text: String = ""
        var hint: String?

        static let idle = Status()
    }

    // MARK: - Settings
    //
    // Views mutate these directly; the `didSet` hooks keep UserDefaults, the
    // keychain and any running tasks in step.

    var environment: AtombergAPI.Environment {
        didSet {
            defaults.set(environment.rawValue, forKey: Key.environment)
            guard oldValue != environment else { return }
            // Tokens are issued per environment, so the cache is not reusable.
            forgetAccessToken()
        }
    }

    var autoRefreshSeconds: Int {
        didSet {
            defaults.set(autoRefreshSeconds, forKey: Key.autoRefresh)
            restartAutoRefresh()
        }
    }

    var showSpeedInMenuBar: Bool {
        didSet { defaults.set(showSpeedInMenuBar, forKey: Key.showSpeed) }
    }

    var confirmAfterCommand: Bool {
        didSet { defaults.set(confirmAfterCommand, forKey: Key.confirm) }
    }

    var lanEnabled: Bool {
        didSet {
            defaults.set(lanEnabled, forKey: Key.lan)
            updateLAN()
        }
    }

    /// Assigned when the value comes from the API. The UI goes through
    /// `selectDevice(_:)` instead, so a change driven by a refresh cannot start
    /// a second round trip and spend another call.
    var selectedDeviceID: String? {
        didSet {
            defaults.set(selectedDeviceID, forKey: Key.deviceID)
            guard oldValue != selectedDeviceID else { return }
            // The cached readings belong to the previous fan.
            deviceState = nil
            analytics = nil
            lastAnalyticsSync = nil
        }
    }

    // MARK: - Credentials
    //
    // Edited in the Setup page, committed by `saveCredentials()`.

    var apiKey = ""
    var refreshToken = ""
    private(set) var storedApiKey = ""
    private(set) var storedRefreshToken = ""

    // MARK: - Remote data

    private(set) var devices: [Device] = []
    private(set) var deviceState: FanState?
    private(set) var analytics: FanAnalytics?
    private(set) var lastSync: Date?
    /// When `/get_device_analytics` last succeeded; gates the once-an-hour cap.
    private(set) var lastAnalyticsSync: Date?
    private(set) var status: Status = .idle
    private(set) var isBusy = false
    private(set) var usedToday = 0

    // MARK: - Local network

    private(set) var localHosts: [String: String] = [:]   // device_id -> ip
    private(set) var lastLocalBeacon: Date?
    private(set) var lastLocalStateAt: Date?
    private(set) var lastLocalPacketPreview = ""
    private(set) var lanNote: String?

    // MARK: - Private

    // Plain storage: none of this is drawn, so it stays out of the
    // observation graph rather than waking SwiftUI on every change.
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let budget = CallBudget()
    @ObservationIgnored private var cachedToken: (value: String, expiry: Date)?
    @ObservationIgnored private var autoRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var lanLink: LANLink?
    /// Stops overlapping reads from each spending a call.
    @ObservationIgnored private var isRefreshing = false
    /// Concurrent commands are allowed, so the spinner counts them.
    @ObservationIgnored private var activeRequests = 0
    /// One token mint at a time: each one costs a call.
    @ObservationIgnored private var mintTask: Task<String, Error>?
    /// Coalesces the read-back that follows a burst of commands into one call.
    @ObservationIgnored private var commandGeneration = 0
    /// Set by `PanelController` so the views can ask for the Setup window
    /// without reaching for a global.
    @ObservationIgnored var onRequestSetup: (@MainActor () -> Void)?

    private enum Key {
        static let environment = "settings.environment"
        static let autoRefresh = "settings.autoRefreshSeconds"
        static let showSpeed = "settings.showSpeedInMenuBar"
        static let confirm = "settings.confirmAfterCommand"
        static let lan = "settings.lanEnabled"
        static let deviceID = "settings.selectedDeviceID"
    }

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let rawEnvironment = defaults.string(forKey: Key.environment) ?? ""
        environment = AtombergAPI.Environment(rawValue: rawEnvironment) ?? .production
        autoRefreshSeconds = defaults.object(forKey: Key.autoRefresh) as? Int ?? 0
        showSpeedInMenuBar = defaults.bool(forKey: Key.showSpeed)
        confirmAfterCommand = defaults.object(forKey: Key.confirm) as? Bool ?? true
        lanEnabled = defaults.bool(forKey: Key.lan)
        selectedDeviceID = defaults.string(forKey: Key.deviceID)

        apiKey = Keychain.value(for: .apiKey) ?? ""
        refreshToken = Keychain.value(for: .refreshToken) ?? ""
        storedApiKey = apiKey
        storedRefreshToken = refreshToken

        if let token = Keychain.value(for: .accessToken),
           let stamp = Keychain.value(for: .accessTokenExpiry),
           let interval = TimeInterval(stamp) {
            let expiry = Date(timeIntervalSince1970: interval)
            // Reuse the stored token for its remaining lifetime instead of
            // spending another call from the daily quota on a fresh one.
            if expiry > Date() { cachedToken = (token, expiry) }
        }
        usedToday = budget.usedToday
    }

    // MARK: - Derived state

    var fans: [Device] { devices.filter(\.isFan) }

    var selectedDevice: Device? {
        if let id = selectedDeviceID, let match = fans.first(where: { $0.id == id }) {
            return match
        }
        return fans.first
    }

    private var supportedCommands: Set<String> {
        selectedDevice?.supportedCommandNames ?? []
    }

    func supports(_ command: String) -> Bool { supportedCommands.contains(command) }

    var isConfigured: Bool { !storedApiKey.isEmpty && !storedRefreshToken.isEmpty }
    var hasUnsavedCredentials: Bool {
        apiKey != storedApiKey || refreshToken != storedRefreshToken
    }

    var isPoweredOn: Bool { deviceState?.power == true }
    var isOnline: Bool? { deviceState?.isOnline }
    var speed: Int? { deviceState?.speed }

    var localHost: String? {
        guard lanEnabled, let device = selectedDevice else { return nil }
        return localHosts[LANLink.normalise(device.deviceID)]
    }

    var isLocalReady: Bool { localHost != nil }

    var budgetSummary: String {
        "\(usedToday)/\(CallBudget.dailyLimit) calls today"
    }

    var stateAge: String? {
        guard let reported = deviceState?.reportedAt else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: reported, relativeTo: Date())
    }

    // MARK: - Menu bar presentation

    var menuBarImage: NSImage {
        if deviceState?.isOnline == false { return variant(0.3) }
        if isPoweredOn { return variant(1) }
        // Nothing reported yet: show it undimmed rather than inventing an
        // "off" reading we do not have.
        return deviceState == nil ? variant(1) : variant(0.5)
    }

    /// Dimmed copies are rendered once and cached — the label re-reads this on
    /// every SwiftUI update.
    private func variant(_ opacity: CGFloat) -> NSImage {
        if let cached = dimmedVariants[opacity] { return cached }
        let made = Assets.dimmed(menuBarIcon, opacity: opacity)
        dimmedVariants[opacity] = made
        return made
    }

    @ObservationIgnored private var dimmedVariants: [CGFloat: NSImage] = [:]

    /// `Resources/` no longer supplies the menu bar glyph — the same SF Symbol
    /// shown beside the fan name in the panel is used here, as a template
    /// image so macOS renders it black on light bars and white on dark ones.
    @ObservationIgnored private lazy var menuBarIcon: NSImage = {
        let image = NSImage(systemSymbolName: "fan.ceiling", accessibilityDescription: "OpenBerg")
            ?? NSImage(systemSymbolName: "fanblades", accessibilityDescription: "OpenBerg")
            ?? NSImage(size: NSSize(width: 20, height: 18))
        image.isTemplate = true
        return image
    }()

    @ObservationIgnored private(set) lazy var heroImage: NSImage? = Assets.heroImage()
    @ObservationIgnored private lazy var bannerLight: NSImage? = Assets.bannerImage(dark: false)
    @ObservationIgnored private lazy var bannerDark: NSImage? = Assets.bannerImage(dark: true)

    /// The header art, on the plate that suits the current appearance.
    func bannerImage(dark: Bool) -> NSImage? { dark ? bannerDark : bannerLight }

    // MARK: - Lifecycle

    func bootstrap() async {
        updateLAN()
        restartAutoRefresh()
        guard isConfigured else {
            status = Status(kind: .idle, text: "Add your Atomberg credentials to begin.")
            return
        }
        await refreshDevices()
        await refreshState()
        await refreshAnalyticsIfStale()
    }

    func panelOpened() async {
        // Opening the panel is a deliberate act, so a refresh here is worth one
        // call — but never more than one per 20 seconds.
        guard isConfigured else { return }
        if let last = lastSync, Date().timeIntervalSince(last) < 20 {
            await refreshAnalyticsIfStale()
            return
        }
        await refreshState(silent: true)
        await refreshAnalyticsIfStale()
    }

    // MARK: - Credentials

    func saveCredentials() async {
        Keychain.set(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), for: .apiKey)
        let trimmedRefresh = refreshToken.trimmingCharacters(in: .whitespacesAndNewlines)
        Keychain.set(trimmedRefresh, for: .refreshToken)
        apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        refreshToken = trimmedRefresh
        storedApiKey = apiKey
        storedRefreshToken = refreshToken

        // Credentials belong to one account, so nothing cached survives them.
        forgetAccessToken()
        devices = []
        deviceState = nil
        analytics = nil
        selectedDeviceID = nil
        status = Status(kind: .idle, text: "Connecting…")
        await refreshDevices()
        await refreshState()
    }

    func forgetCredentials() {
        Keychain.remove(.apiKey)
        Keychain.remove(.refreshToken)
        forgetAccessToken()
        apiKey = ""
        refreshToken = ""
        storedApiKey = ""
        storedRefreshToken = ""
        devices = []
        deviceState = nil
        analytics = nil
        selectedDeviceID = nil
        status = Status(kind: .idle, text: "Credentials removed.")
    }

    private func forgetAccessToken() {
        cachedToken = nil
        Keychain.clearAccessToken()
    }

    // MARK: - Reads

    /// Switches the fan the panel is showing, then reads the new one's state.
    func selectDevice(_ id: String) async {
        guard id != selectedDeviceID else { return }
        selectedDeviceID = id
        await refreshState()
        await refreshAnalyticsIfStale()
    }

    func refreshDevices() async {
        guard isConfigured else { return }
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await run { api, token in
            let list = try await api.devices(accessToken: token)
            self.devices = list
            if self.selectedDeviceID == nil || !list.contains(where: { $0.id == self.selectedDeviceID }) {
                self.selectedDeviceID = list.first(where: \.isFan)?.id ?? list.first?.id
            }
            if list.isEmpty {
                self.status = Status(kind: .info, text: "No Wi-Fi devices on this account yet.")
            }
        }
    }

    /// `device_id=all` means one call refreshes every supported device.
    func refreshState(silent: Bool = false) async {
        guard isConfigured else { return }
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await run(silent: silent) { api, token in
            let rows = try await api.deviceState(accessToken: token)
            let wanted = self.selectedDevice?.id
            if let row = rows.first(where: { $0.deviceID == wanted }) ?? rows.first {
                self.deviceState = row
            }
            self.lastSync = Date()
            if !silent || self.status.kind == .error {
                self.status = Status(kind: .info, text: "State updated.")
            }
        }
    }

    func refreshAnalytics() async {
        guard isConfigured else { return }
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await run { api, token in
            let rows = try await api.analytics(accessToken: token)
            let wanted = self.selectedDevice?.id
            if let row = rows.first(where: { $0.deviceID == wanted }) ?? rows.first {
                self.analytics = row
                self.lastAnalyticsSync = Date()
            }
        }
    }

    /// Analytics change slowly and each read costs quota, so they are fetched
    /// at most once an hour and only when the user is actually looking —
    /// opening the panel (or launching) reuses anything fetched within the
    /// last hour, and nothing is fetched in the background.
    private func refreshAnalyticsIfStale() async {
        if let last = lastAnalyticsSync, Date().timeIntervalSince(last) < 3600 { return }
        await refreshAnalytics()
    }

    // MARK: - Commands
    //
    // Every fan command in the reference goes through here. Keys are checked by
    // the API against the device's series, so a message is only ever built from
    // commands the device advertises.

    func togglePower() async {
        let target = !isPoweredOn
        await send(["power": .bool(target)], optimistic: { $0.power = target })
    }

    func setSpeed(_ level: Int) async {
        let clamped = min(6, max(1, level))
        await send(["speed": .int(clamped)], optimistic: { $0.speed = clamped })
    }

    func nudgeSpeed(by delta: Int) async {
        guard delta != 0 else { return }
        let current = speed ?? 0
        let target = min(6, max(1, current + delta))
        guard target != current else { return }
        await send(["speedDelta": .int(delta)], optimistic: { $0.speed = target })
    }

    func setSleep(_ enabled: Bool) async {
        await send(["sleep": .bool(enabled)], optimistic: { $0.sleepMode = enabled })
    }

    func setTimer(hours: Int) async {
        // 0 off, 1 → 1h, 2 → 2h, 3 → 3h, 4 → 6h
        let preset = min(4, max(0, hours))
        await send(["timer": .int(preset)], optimistic: { $0.timerHours = preset == 0 ? 0 : [1, 2, 3, 6][preset - 1] })
    }

    func setLED(_ enabled: Bool) async {
        await send(["led": .bool(enabled)], optimistic: { $0.led = enabled })
    }

    func setBrightness(_ percent: Int) async {
        let clamped = min(100, max(10, percent))
        await send(["brightness": .int(clamped)], optimistic: { $0.brightness = clamped })
    }

    func setLightMode(_ mode: String) async {
        await send(["light_mode": .string(mode)], optimistic: { $0.color = mode })
    }

    func setReverse(_ enabled: Bool) async {
        await send(["rev_mode": .bool(enabled)], optimistic: { $0.revMode = enabled })
    }

    func setBuzzer(_ enabled: Bool) async {
        await send(["buzzer_status": .bool(enabled)], optimistic: { $0.buzzerStatus = enabled })
    }

    /// Delivers a command, preferring the LAN when the fan is reachable there
    /// (which costs no quota) and falling back to `POST /send_command`.
    func send(
        _ command: [String: CommandValue],
        optimistic: ((inout FanState) -> Void)? = nil,
        silent: Bool = false
    ) async {
        guard let device = selectedDevice else {
            status = Status(kind: .error, text: "Choose a fan first.")
            return
        }
        guard !command.isEmpty else { return }

        if var copy = deviceState, let optimistic {
            optimistic(&copy)
            deviceState = copy
        }

        if let host = localHost, let payload = try? JSONEncoder().encode(command) {
            lanLink?.send(payload, to: host)
            if !silent {
                status = Status(kind: .info, text: "Sent over your local network — no API call used.")
            }
            return
        }

        guard isConfigured else {
            status = Status(kind: .error, text: "Add your Atomberg credentials first.")
            return
        }

        await run(silent: silent) { api, token in
            try await api.sendCommand(accessToken: token, deviceID: device.id, command: command)
        }

        // "Accepted" is not "applied", so the state is read back — one extra
        // call. A burst of taps supersedes the pending read-back rather than
        // paying for one per command.
        guard confirmAfterCommand else { return }
        commandGeneration += 1
        let generation = commandGeneration
        try? await Task.sleep(for: .seconds(2))
        guard generation == commandGeneration else { return }
        await refreshState(silent: true)
    }

    // MARK: - Request plumbing

    /// Runs `body` with a valid access token, minting one replacement on a 401
    /// and never on anything else, so a bad request cannot burn quota in a loop.
    private func run(
        silent: Bool = false,
        _ body: @escaping (AtombergAPI, String) async throws -> Void
    ) async {
        guard isConfigured else {
            status = Status(kind: .error, text: "Add your Atomberg credentials first.")
            return
        }
        activeRequests += 1
        isBusy = true
        defer {
            activeRequests -= 1
            isBusy = activeRequests > 0
        }

        let api = AtombergAPI(environment: environment, apiKey: apiKey)
        do {
            var token = try await validToken(api)
            do {
                try await body(api, token)
            } catch let error as AtombergError where error.status == 401 {
                forgetAccessToken()
                token = try await mintToken(api)
                try await body(api, token)
            }
            refreshBudget()
        } catch {
            present(error)
        }
    }

    private func validToken(_ api: AtombergAPI) async throws -> String {
        if let cached = cachedToken, cached.expiry > Date() { return cached.value }
        // Two callers racing here would each spend a call on a new token; they
        // share the one in flight instead.
        if let inFlight = mintTask { return try await inFlight.value }
        let task = Task { try await self.mintToken(api) }
        mintTask = task
        defer { mintTask = nil }
        return try await task.value
    }

    /// Each new token uses one call, so the result is reused for 24 hours.
    private func mintToken(_ api: AtombergAPI) async throws -> String {
        budget.record()
        let token = try await api.accessToken(refreshToken: refreshToken)
        let expiry = Date().addingTimeInterval(24 * 3600 - 300)
        cachedToken = (token, expiry)
        Keychain.set(token, for: .accessToken)
        Keychain.set(String(expiry.timeIntervalSince1970), for: .accessTokenExpiry)
        refreshBudget()
        return token
    }

    private func refreshBudget() {
        usedToday = budget.usedToday
    }

    private func present(_ error: Error) {
        if let atomberg = error as? AtombergError {
            status = Status(kind: .error, text: atomberg.message, hint: atomberg.hint)
        } else {
            status = Status(kind: .error, text: error.localizedDescription)
        }
    }

    // MARK: - Auto refresh

    private func restartAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil

        let interval = autoRefreshSeconds
        guard interval > 0 else { return }
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self else { return }
                // When the local link is delivering state, polling the cloud
                // would spend quota for nothing.
                if self.isLocalReady,
                   let last = self.lastLocalStateAt,
                   Date().timeIntervalSince(last) < Double(max(interval, 20)) {
                    continue
                }
                await self.refreshState(silent: true)
            }
        }
    }

    // MARK: - Local network

    private func updateLAN() {
        guard lanEnabled else {
            lanLink?.stop()
            lanLink = nil
            localHosts = [:]
            lastLocalBeacon = nil
            lastLocalStateAt = nil
            lanNote = nil
            return
        }
        guard lanLink == nil else { return }

        lanNote = "Listening for fans on your local network."
        lanLink = LANLink(
            onBeacon: { [weak self] beacon in
                Task { @MainActor in self?.register(beacon) }
            },
            onStatePacket: { [weak self] packet in
                Task { @MainActor in self?.ingest(packet) }
            },
            onFailure: { [weak self] message in
                Task { @MainActor in self?.lanNote = message }
            }
        )
        lanLink?.start()
    }

    private func register(_ beacon: LANLink.Beacon) {
        localHosts[beacon.mac] = beacon.host
        lastLocalBeacon = Date()
        if isLocalReady {
            lanNote = "Fan found on this network at \(localHost ?? beacon.host)."
        }
    }

    /// The reference documents that a fan broadcasts its state on the local
    /// network after every change, but not the packet format. A JSON payload is
    /// applied when it parses; anything else is kept as a diagnostic.
    private func ingest(_ packet: Data) {
        if let state = try? JSONDecoder().decode(FanState.self, from: packet) {
            let wanted = selectedDevice?.id
            if wanted == nil || state.deviceID == wanted || state.deviceID == nil {
                deviceState = state
                lastLocalStateAt = Date()
                return
            }
        }
        lastLocalPacketPreview = packet.prefix(48).map { byte in
            (byte >= 32 && byte < 127) ? String(UnicodeScalar(byte)) : "."
        }.joined()
    }
}
