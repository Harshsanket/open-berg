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
        enum Kind: Equatable { case idle, error }
        var kind: Kind = .idle
        var text: String = ""
        var hint: String?

        static let idle = Status()
    }

    // MARK: - Settings
    //
    // Views mutate these directly; the `didSet` hooks keep UserDefaults, the
    // keychain and any running tasks in step.

    var showSpeedInMenuBar: Bool {
        didSet { defaults.set(showSpeedInMenuBar, forKey: Key.showSpeed) }
    }

    /// How often state and usage are read in the background, in hours.
    /// 0 = never (manual only); the fan list is never read on a timer.
    var refreshIntervalHours: Int {
        didSet {
            defaults.set(refreshIntervalHours, forKey: Key.refreshIntervalHours)
            restartAutoRefresh()
        }
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
    /// True once the device list has been read this session. Until then the
    /// panel says "nothing loaded yet" rather than claiming there is no fan.
    private(set) var hasLoadedDevices = false
    private(set) var status: Status = .idle
    private(set) var isBusy = false
    private(set) var usedToday = 0

    // MARK: - Local network

    private(set) var localHosts: [String: String] = [:]   // device_id -> ip

    // MARK: - Private

    // Plain storage: none of this is drawn, so it stays out of the
    // observation graph rather than waking SwiftUI on every change.
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let budget = CallBudget()
    @ObservationIgnored private var cachedToken: (value: String, expiry: Date)?
    @ObservationIgnored private var lanLink: LANLink?
    /// Stops overlapping reads from each spending a call.
    @ObservationIgnored private var isRefreshing = false
    /// The background cadence chosen in Setup; nil when off.
    @ObservationIgnored private var autoRefreshTask: Task<Void, Never>?
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
        static let showSpeed = "settings.showSpeedInMenuBar"
        static let confirm = "settings.confirmAfterCommand"
        static let lan = "settings.lanEnabled"
        static let deviceID = "settings.selectedDeviceID"
        static let refreshIntervalHours = "settings.refreshIntervalHours"
    }

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        showSpeedInMenuBar = defaults.bool(forKey: Key.showSpeed)
        refreshIntervalHours = defaults.object(forKey: Key.refreshIntervalHours) as? Int ?? 1
        confirmAfterCommand = defaults.object(forKey: Key.confirm) as? Bool ?? true
        lanEnabled = defaults.bool(forKey: Key.lan)
        selectedDeviceID = defaults.string(forKey: Key.deviceID)

        // One keychain read for everything: credentials and the cached token.
        if let stored = Keychain.load() {
            apiKey = stored.apiKey
            refreshToken = stored.refreshToken
            // Reuse the stored token for its remaining lifetime instead of
            // spending another call from the daily quota on a fresh one.
            if let token = stored.accessToken,
               let expiry = stored.accessTokenExpiry,
               expiry > Date().timeIntervalSince1970 {
                cachedToken = (token, Date(timeIntervalSince1970: expiry))
            }
        }
        storedApiKey = apiKey
        storedRefreshToken = refreshToken
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

    /// Non-nil once the day's quota is close to gone; the panel shows it as
    /// a warning pill.
    var quotaWarning: String? {
        usedToday > 80 ? "⚠ \(usedToday) of \(CallBudget.dailyLimit) calls used today" : nil
    }

    var stateAge: String? {
        guard let reported = deviceState?.reportedAt else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: reported, relativeTo: Date())
    }

    // MARK: - Menu bar presentation

    /// One glyph at full opacity. The fan's state is carried by the status
    /// line in the panel and the optional speed label, not by fading the icon.
    var menuBarImage: NSImage { menuBarIcon }

    /// The same SF Symbol shown beside the fan name in the panel is used here
    /// as a template image, so macOS renders it black on light bars and white
    /// on dark ones.
    @ObservationIgnored private lazy var menuBarIcon: NSImage = {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .bold)
        let image = NSImage(systemSymbolName: "fan.ceiling.fill", accessibilityDescription: "OpenBerg")
            .flatMap { $0.withSymbolConfiguration(config) }
            ?? NSImage(systemSymbolName: "fanblades.fill", accessibilityDescription: "OpenBerg")
                .flatMap { $0.withSymbolConfiguration(config) }
            ?? NSImage(systemSymbolName: "fanblades", accessibilityDescription: "OpenBerg")
            ?? NSImage(size: NSSize(width: 18, height: 16))
        image.isTemplate = true
        return image
    }()

    // MARK: - Lifecycle

    /// Nothing is fetched on launch: state and usage are read on the schedule
    /// the user picks in Setup (`refreshIntervalHours`), and the fan list is
    /// only ever read when the user asks for it.
    func bootstrap() {
        updateLAN()
        restartAutoRefresh()
    }

    // MARK: - Scheduled reads

    /// Restarts the background cadence after the interval changes. The loop
    /// reads state and usage only — never the device list, which costs a call
    /// the user did not ask for every time it repeats.
    private func restartAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
        guard refreshIntervalHours > 0, isConfigured else { return }
        let period = TimeInterval(refreshIntervalHours) * 3600
        autoRefreshTask = Task { [weak self] in
            while true {
                do { try await Task.sleep(for: .seconds(period)) } catch { return }
                guard !Task.isCancelled else { return }
                guard let self, self.isConfigured else { return }
                // Without the fan list there is no selected device to read, so
                // a timed read would attach to an arbitrary row.
                guard self.hasLoadedDevices else { continue }
                await self.refreshState()
                await self.refreshAnalytics()
            }
        }
    }

    // MARK: - Credentials

    func saveCredentials() async {
        apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        refreshToken = refreshToken.trimmingCharacters(in: .whitespacesAndNewlines)
        storedApiKey = apiKey
        storedRefreshToken = refreshToken

        // Credentials belong to one account, so nothing cached survives them.
        forgetAccessToken()
        devices = []
        deviceState = nil
        analytics = nil
        hasLoadedDevices = false
        selectedDeviceID = nil
        status = .idle
        await refreshDevices()
        await refreshState()
        restartAutoRefresh()
    }

    func forgetCredentials() {
        cachedToken = nil
        Keychain.remove()
        apiKey = ""
        refreshToken = ""
        storedApiKey = ""
        storedRefreshToken = ""
        devices = []
        deviceState = nil
        analytics = nil
        hasLoadedDevices = false
        selectedDeviceID = nil
        status = .idle
        restartAutoRefresh()
    }

    /// Drops the cached access token, in memory and in the keychain item.
    /// The credentials themselves stay put.
    private func forgetAccessToken() {
        cachedToken = nil
        Keychain.save(Keychain.Credentials(apiKey: apiKey, refreshToken: refreshToken))
    }

    // MARK: - Reads
    //
    // The fan list is read only when the user asks for it; state and usage
    // are additionally read on the `refreshIntervalHours` cadence.

    /// Switches the fan the panel is showing, then reads the new one's state.
    func selectDevice(_ id: String) async {
        guard id != selectedDeviceID else { return }
        selectedDeviceID = id
        await refreshState()
        await refreshAnalytics()
    }

    /// What Refresh presses read: the current state and the usage figures —
    /// two calls. The device list is deliberately not part of it; see
    /// `refreshDevices()`.
    func refreshEverything() async {
        await refreshState()
        await refreshAnalytics()
    }

    /// Re-reads the device list — one call, only ever on an explicit press of
    /// the "Fetch fan list" button.
    func refreshDevices() async {
        guard isConfigured else { return }
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await run { api, token in
            let list = try await api.devices(accessToken: token)
            self.devices = list
            self.hasLoadedDevices = true
            if self.selectedDeviceID == nil || !list.contains(where: { $0.id == self.selectedDeviceID }) {
                self.selectedDeviceID = list.first(where: \.isFan)?.id ?? list.first?.id
            }
        }
    }

    /// `device_id=all` means one call refreshes every supported device.
    func refreshState() async {
        guard isConfigured else { return }
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await run { api, token in
            let rows = try await api.deviceState(accessToken: token)
            let wanted = self.selectedDevice?.id
            if let row = rows.first(where: { $0.deviceID == wanted }) ?? rows.first {
                self.deviceState = row
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
            }
        }
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
        optimistic: ((inout FanState) -> Void)? = nil
    ) async {
        guard let device = selectedDevice else {
            status = Status(kind: .error, text: "Choose a fan first.")
            return
        }
        guard !command.isEmpty else { return }

        // The LAN is free, so it is tried whenever the fan has been heard
        // there, whatever the cloud reports.
        if let host = localHost, let payload = try? JSONEncoder().encode(command) {
            if var copy = deviceState, let optimistic {
                optimistic(&copy)
                deviceState = copy
            }
            lanLink?.send(payload, to: host)
            return
        }

        guard isConfigured else {
            status = Status(kind: .error, text: "Add your Atomberg credentials first.")
            return
        }

        // A fan the cloud reports offline cannot accept a command; sending
        // anyway would spend one of the day's calls on a guaranteed failure.
        if deviceState?.isOnline == false {
            status = Status(
                kind: .error,
                text: "The fan is offline, so the command was not sent.",
                hint: "It should accept commands again once it reconnects."
            )
            return
        }

        // Only now is a delivery certain enough to show it on the controls.
        if var copy = deviceState, let optimistic {
            optimistic(&copy)
            deviceState = copy
        }

        await run { api, token in
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
        await refreshState()
    }

    // MARK: - Request plumbing

    /// Runs `body` with a valid access token, minting one replacement on a 401
    /// and never on anything else, so a bad request cannot burn quota in a loop.
    private func run(
        _ body: @escaping (AtombergAPI, String) async throws -> Void
    ) async {
        guard isConfigured else {
            status = Status(kind: .error, text: "Add your Atomberg credentials first.")
            return
        }
        // Once the local tally says the day is spent, the server would only
        // answer 429 — a failed call that still counts. Refuse instead of
        // spending it.
        guard budget.usedToday < CallBudget.dailyLimit else {
            status = Status(
                kind: .error,
                text: "All 100 calls for today are used up.",
                hint: "The quota resets at 00:00 UTC."
            )
            return
        }
        activeRequests += 1
        isBusy = true
        defer {
            activeRequests -= 1
            isBusy = activeRequests > 0
            // Failed calls spend quota too, so the tally is refreshed on every
            // exit path, not only on success.
            refreshBudget()
        }

        let budget = self.budget
        let api = AtombergAPI(
            apiKey: apiKey,
            recordCall: { budget.record() }
        )
        do {
            var token = try await validToken(api)
            do {
                try await body(api, token)
            } catch let error as AtombergError where error.status == 401 {
                forgetAccessToken()
                token = try await mintToken(api)
                try await body(api, token)
            }
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
    /// The call itself is tallied by the transport's `recordCall`.
    private func mintToken(_ api: AtombergAPI) async throws -> String {
        let token = try await api.accessToken(refreshToken: refreshToken)
        let expiry = Date().addingTimeInterval(24 * 3600 - 300)
        cachedToken = (token, expiry)
        Keychain.save(
            Keychain.Credentials(
                apiKey: apiKey,
                refreshToken: refreshToken,
                accessToken: token,
                accessTokenExpiry: expiry.timeIntervalSince1970
            )
        )
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

    // MARK: - Local network

    private func updateLAN() {
        guard lanEnabled else {
            lanLink?.stop()
            lanLink = nil
            localHosts = [:]
            return
        }
        guard lanLink == nil else { return }

        lanLink = LANLink(
            onBeacon: { [weak self] beacon in
                Task { @MainActor in self?.register(beacon) }
            },
            onStatePacket: { [weak self] packet in
                Task { @MainActor in self?.ingest(packet) }
            }
        )
        lanLink?.start()
    }

    private func register(_ beacon: LANLink.Beacon) {
        localHosts[beacon.mac] = beacon.host
    }

    /// The reference documents that a fan broadcasts its state on the local
    /// network after every change, but not the packet format. A JSON payload is
    /// applied when it parses; anything else is ignored and the cloud read
    /// stays authoritative.
    private func ingest(_ packet: Data) {
        guard let state = try? JSONDecoder().decode(FanState.self, from: packet) else { return }
        let wanted = selectedDevice?.id
        if wanted == nil || state.deviceID == wanted || state.deviceID == nil {
            deviceState = state
        }
    }
}
