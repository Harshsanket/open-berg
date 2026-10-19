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

    /// The auto-refresh rule: how often sources set to "Auto" read, in hours.
    /// 0 = never (manual only); the fan list is never read on a timer. When
    /// both status and usage ride their own cadences instead, nothing
    /// consumes this rule and Setup greys the picker out.
    var refreshIntervalHours: Int {
        didSet {
            defaults.set(refreshIntervalHours, forKey: Key.refreshIntervalHours)
            restartAutoRefresh()
        }
    }

    /// Status cadence in hours. 0 (the default) follows the auto-refresh
    /// rule; any other value is the source's own fixed cadence.
    var statusRefreshHours: Int {
        didSet {
            defaults.set(statusRefreshHours, forKey: Key.statusRefreshHours)
            restartAutoRefresh()
        }
    }

    /// Usage cadence in hours, same shape as `statusRefreshHours`. The
    /// default is 12.
    var usageRefreshHours: Int {
        didSet {
            defaults.set(usageRefreshHours, forKey: Key.usageRefreshHours)
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

    /// While on, the LAN listener keeps running with the panel closed, so the
    /// fan's own broadcasts keep the state current in the background. This is
    /// the local path only — beacons and state packets cost nothing — so no
    /// cloud call is ever made for background refresh, not even a failed one.
    var backgroundRefresh: Bool {
        didSet {
            defaults.set(backgroundRefresh, forKey: Key.backgroundRefresh)
            updateLAN()
        }
    }

    /// Starts the app at login. On by default: OpenBerg is a menu bar extra,
    /// and the login item is what puts the icon back after a restart.
    var launchAtLogin: Bool {
        didSet {
            defaults.set(launchAtLogin, forKey: Key.launchAtLogin)
            loginItemNote = LaunchAtLogin.set(launchAtLogin)
        }
    }

    /// Set when the system refused a login-item change, so Setup can say so.
    private(set) var loginItemNote: String?

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
            lanStateHeardAt = nil
            persistSoon()
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

    private(set) var devices: [Device] = [] {
        didSet { persistSoon() }
    }
    private(set) var deviceState: FanState? {
        didSet { persistSoon() }
    }
    private(set) var analytics: FanAnalytics? {
        didSet { persistSoon() }
    }
    /// True once the device list has been read this session. Until then the
    /// panel says "nothing loaded yet" rather than claiming there is no fan.
    private(set) var hasLoadedDevices = false
    private(set) var status: Status = .idle
    private(set) var isBusy = false
    private(set) var usedToday = 0

    // MARK: - Local network

    private(set) var localHosts: [String: LocalHost] = [:]   // device_id -> host

    /// Where a fan was last heard on the LAN, and when. The timestamp keeps
    /// the host trustworthy only while beacons keep arriving: a fan that has
    /// not been heard for a while falls back to the cloud path.
    struct LocalHost: Sendable {
        var address: String
        var seenAt: Date
    }

    // MARK: - Private

    // Plain storage: none of this is drawn, so it stays out of the
    // observation graph rather than waking SwiftUI on every change.
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let budget = CallBudget()
    @ObservationIgnored private var cachedToken: (value: String, expiry: Date)?
    @ObservationIgnored private var lanLink: LANLink?
    /// Stops overlapping reads from each spending a call.
    @ObservationIgnored private var isRefreshing = false
    /// The cadence chosen in Setup; nil unless it is running. Ticks happen
    /// only while the panel is open, so this is normally nil in the
    /// background.
    @ObservationIgnored private var autoRefreshTask: Task<Void, Never>?
    /// True from `panelDidShow()` until `panelDidHide()`.
    @ObservationIgnored private var panelIsOpen = false
    /// True while the Setup window is open; the LAN listener runs for this
    /// session too, so the moments right after setup — when the system's
    /// Local Network prompt appears and the first beacons arrive — already
    /// have the local path warming up.
    @ObservationIgnored private var setupIsOpen = false
    /// Coalesces cache writes: LAN packets and slider edits can change the
    /// readings in bursts, and the cache only needs to be roughly current.
    @ObservationIgnored private var persistTask: Task<Void, Never>?
    /// When the LAN last carried a state packet for the selected fan. While
    /// this is recent, cloud state reads are skipped.
    @ObservationIgnored private var lanStateHeardAt: Date?
    /// When usage figures were last read; automatic ticks read them at most
    /// once a day regardless of how short the cadence is.
    @ObservationIgnored private var lastAnalyticsReadAt: Date?
    /// Concurrent commands are allowed, so the spinner counts them.
    @ObservationIgnored private var activeRequests = 0
    /// One token mint at a time: each one costs a call.
    @ObservationIgnored private var mintTask: Task<String, Error>?
    /// Coalesces the read-back that follows a burst of commands into one call.
    @ObservationIgnored private var commandGeneration = 0
    /// Set by `PanelController` so the views can ask for the Setup window
    /// without reaching for a global.
    @ObservationIgnored var onRequestSetup: (@MainActor () -> Void)?
    /// Update checks and one-click installs; see `Updater`.
    @ObservationIgnored let updater = Updater()
    /// Built once; `stateAge` is read on every panel render.
    @ObservationIgnored private lazy var ageFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    /// A LAN host is trusted for this long after the last beacon; past it
    /// the cloud is used instead of firing at a possibly stale address.
    private static let lanHostFreshness: TimeInterval = 180
    /// A LAN state packet is trusted for this long before cloud reads resume.
    private static let lanStateFreshness: TimeInterval = 600

    private enum Key {
        static let showSpeed = "settings.showSpeedInMenuBar"
        static let confirm = "settings.confirmAfterCommand"
        static let lan = "settings.lanEnabled"
        static let backgroundRefresh = "settings.backgroundRefresh"
        static let launchAtLogin = "settings.launchAtLogin"
        static let deviceID = "settings.selectedDeviceID"
        static let refreshIntervalHours = "settings.refreshIntervalHours"
        static let statusRefreshHours = "settings.statusRefreshHours"
        static let usageRefreshHours = "settings.usageRefreshHours"
        static let cachedState = "cache.state"
    }

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        showSpeedInMenuBar = defaults.bool(forKey: Key.showSpeed)
        refreshIntervalHours = defaults.object(forKey: Key.refreshIntervalHours) as? Int ?? 0
        // Status follows the auto-refresh rule; usage starts on its own 12 h
        // cadence, as chosen when the two became independent.
        statusRefreshHours = defaults.object(forKey: Key.statusRefreshHours) as? Int ?? 0
        usageRefreshHours = defaults.object(forKey: Key.usageRefreshHours) as? Int ?? 12
        confirmAfterCommand = defaults.object(forKey: Key.confirm) as? Bool ?? true
        lanEnabled = defaults.object(forKey: Key.lan) as? Bool ?? true
        backgroundRefresh = defaults.object(forKey: Key.backgroundRefresh) as? Bool ?? false
        launchAtLogin = defaults.object(forKey: Key.launchAtLogin) as? Bool ?? true
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

        // Last known readings are restored so a fresh launch — including the
        // login one — shows the fan exactly as it was left, without a single
        // API call. Direct assignment (not didSet) keeps this from being
        // written straight back to the cache.
        if let data = defaults.data(forKey: Key.cachedState),
           let cache = try? JSONDecoder().decode(CachedState.self, from: data) {
            devices = cache.devices
            hasLoadedDevices = cache.hasLoadedDevices
            // Readings from a different fan are dropped rather than shown
            // against the wrong row.
            if cache.deviceID == selectedDeviceID {
                deviceState = cache.deviceState
                analytics = cache.analytics
            }
        }
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
        guard let entry = localHosts[LANLink.normalise(device.deviceID)] else { return nil }
        guard Date().timeIntervalSince(entry.seenAt) < Self.lanHostFreshness else { return nil }
        return entry.address
    }

    var isLocalReady: Bool { localHost != nil }

    /// Non-nil once the day's quota is close to gone; the panel shows it as
    /// a warning pill.
    var quotaWarning: String? {
        usedToday > 80 ? "⚠ \(usedToday) of \(CallBudget.dailyLimit) calls used today" : nil
    }

    var stateAge: String? {
        guard let reported = deviceState?.reportedAt else { return nil }
        return ageFormatter.localizedString(for: reported, relativeTo: Date())
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

    /// Nothing is fetched on launch. The login item is reconciled (on by
    /// default), the readings come back from the saved-state cache, a
    /// due update check may run, and the panel's session drives the live
    /// work — the LAN listener and the chosen cadence. With the panel closed
    /// the app is idle.
    func bootstrap() {
        loginItemNote = LaunchAtLogin.set(launchAtLogin)
        updateLAN()
        restartAutoRefresh()
        updater.checkIfDue(.launch)
    }

    /// Called by `PanelController` when the menu bar panel opens: start
    /// listening on the LAN, resume the chosen cadence, and let the updater
    /// take its monthly window.
    func panelDidShow() {
        panelIsOpen = true
        updateLAN()
        restartAutoRefresh()
        updater.checkIfDue(.session)
    }

    /// Called when the panel closes. The cadence stops and the state cache
    /// is written out; the LAN listener only stops when "background refresh"
    /// is off, otherwise it keeps the local feed running for free.
    func panelDidHide() {
        panelIsOpen = false
        updateLAN()
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
        flushPersist()
    }

    /// Called by `PanelController` when the Setup window opens and closes.
    /// The LAN listener runs for that session too, which is what makes the
    /// app "try the LAN first" from the moment setup is done.
    func setupDidShow() {
        setupIsOpen = true
        updateLAN()
        updater.checkIfDue(.session)
    }

    func setupDidHide() {
        setupIsOpen = false
        updateLAN()
        flushPersist()
    }

    // MARK: - Saved state
    //
    // The fan list and the last readings are persisted as JSON in
    // UserDefaults so a fresh launch shows them without spending a single
    // call. Writes are coalesced because LAN packets and slider edits can
    // change the readings in bursts.

    /// The shape written under `Key.cachedState`.
    private struct CachedState: Codable {
        var deviceID: String?
        var hasLoadedDevices: Bool
        var devices: [Device]
        var deviceState: FanState?
        var analytics: FanAnalytics?
    }

    private func persistSoon() {
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.persistNow()
        }
    }

    /// Writes the cache now instead of waiting out the coalescing delay;
    /// called when a session ends and at termination.
    func flushPersist() {
        persistTask?.cancel()
        persistTask = nil
        persistNow()
    }

    private func persistNow() {
        guard hasLoadedDevices || deviceState != nil || analytics != nil else { return }
        let cache = CachedState(
            deviceID: selectedDeviceID,
            hasLoadedDevices: hasLoadedDevices,
            devices: devices,
            deviceState: deviceState,
            analytics: analytics
        )
        // `FanState` decodes `reportedAt` from epoch seconds, so dates must
        // be written the same way for the round trip to work.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(cache) else { return }
        defaults.set(data, forKey: Key.cachedState)
    }

    // MARK: - Scheduled reads

    /// (Re)starts the cadence after a cadence changes or the panel opens.
    /// Status and usage are separate sources: each either follows the
    /// auto-refresh rule (`refreshIntervalHours`) or rides its own fixed
    /// number of hours, and the loop wakes only for the soonest due source
    /// and reads exactly that source. Ticks never read the device list,
    /// which costs a call the user did not ask for, and run only while the
    /// panel is open.
    private func restartAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
        guard panelIsOpen, isConfigured else { return }
        let statusHours = statusRefreshHours > 0 ? statusRefreshHours : refreshIntervalHours
        let usageHours = usageRefreshHours > 0 ? usageRefreshHours : refreshIntervalHours
        // Usage that follows the auto-refresh rule stays capped at one read
        // a day, so a short rule cannot multiply the calls the slow-moving
        // lifetime figures need. A usage cadence the user fixed himself
        // ticks on schedule.
        let usageIsCapped = usageRefreshHours == 0
        guard statusHours > 0 || usageHours > 0 else { return }
        autoRefreshTask = Task { [weak self] in
            var statusDue = Date().addingTimeInterval(Double(statusHours) * 3600)
            var usageDue = Date().addingTimeInterval(Double(usageHours) * 3600)
            while true {
                var wakes: [Date] = []
                if statusHours > 0 { wakes.append(statusDue) }
                if usageHours > 0 { wakes.append(usageDue) }
                guard let wake = wakes.min() else { return }
                // A source that came due while reads were still running is
                // serviced right away; a short sleep also yields to
                // cancellation checks.
                let now = Date()
                let lead = max(wake.timeIntervalSince(now), 0.05)
                do { try await Task.sleep(for: .seconds(lead)) } catch { return }
                guard !Task.isCancelled else { return }
                guard let self, self.isConfigured, self.panelIsOpen else { return }
                // Without the fan list there is no selected device to read,
                // so a timed read would attach to an arbitrary row.
                guard self.hasLoadedDevices else { continue }
                let tick = Date()
                if statusHours > 0, tick >= statusDue {
                    statusDue = tick.addingTimeInterval(Double(statusHours) * 3600)
                    // While the LAN is feeding the state, the cloud read
                    // would only repeat it.
                    if !self.lanStateIsFresh {
                        await self.refreshState()
                    }
                }
                if usageHours > 0, tick >= usageDue {
                    usageDue = tick.addingTimeInterval(Double(usageHours) * 3600)
                    let stale = self.lastAnalyticsReadAt.map { tick.timeIntervalSince($0) >= 86_400 } ?? true
                    if !usageIsCapped || stale {
                        await self.refreshAnalytics()
                    }
                }
            }
        }
    }

    /// True when a state packet heard on the LAN is recent enough that a
    /// cloud read would return the same picture. The fan broadcasts after
    /// every change, so while it is being heard the read is worth skipping.
    private var lanStateIsFresh: Bool {
        guard lanEnabled, let heard = lanStateHeardAt else { return false }
        return Date().timeIntervalSince(heard) < Self.lanStateFreshness
    }

    // MARK: - Credentials

    /// The fresh-install connect, deliberately the cheapest path that can
    /// work:
    ///
    /// 1. one call for the fan list — identity and `supported_commands`. The
    ///    list is fetched here and then never again; it heals by itself if a
    ///    fan is added or renamed via the explicit "Update Device list"
    ///    button in Setup;
    /// 2. the LAN is given a short window to deliver the fan's state, which
    ///    costs nothing;
    /// 3. only if no state packet arrives is one more call spent, and it is
    ///    `get_device_state`.
    ///
    /// Analytics are never fetched here: usage reads follow the user's own
    /// settings — the refresh cadence and the Refresh button in Setup.
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
        updateLAN()
        restartAutoRefresh()
        await waitForLANThenStateFallback()
    }

    /// Gives the LAN a short window to deliver state before spending the one
    /// fallback call; see `saveCredentials`.
    private func waitForLANThenStateFallback() async {
        guard isConfigured else { return }
        if lanEnabled {
            let deadline = ContinuousClock.now + .seconds(5)
            while ContinuousClock.now < deadline {
                if lanStateIsFresh { return }
                try? await Task.sleep(for: .milliseconds(400))
                if Task.isCancelled { return }
            }
        }
        await refreshState()
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
        updateLAN()
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
    // The fan list is read only when the user asks for it. State and usage
    // additionally run on their own cadences while the panel is open; each
    // manual button below spends exactly its one call.

    /// Switches the fan the panel is showing, then reads the new one's state.
    func selectDevice(_ id: String) async {
        guard id != selectedDeviceID else { return }
        selectedDeviceID = id
        await refreshState()
        await refreshAnalytics()
    }

    /// What the panel's Refresh reads: the current state and the usage
    /// figures — two calls, or one when the LAN has just carried the state.
    /// The device list is deliberately not part of it; it is fetched once at
    /// setup and only re-read by the explicit "Update Device list" button.
    func refreshEverything() async {
        if lanStateIsFresh {
            await refreshAnalytics()
        } else {
            await refreshState()
            await refreshAnalytics()
        }
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
                self.lastAnalyticsReadAt = Date()
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

    /// Runs the listener while a window (the panel or Setup) is open and
    /// normally stops it when everything closes. With "background refresh"
    /// chosen, and only while the fan is reachable on the LAN, the listener
    /// keeps running with the panel closed so the fan's broadcasts keep the
    /// state current; this costs no cloud calls.
    ///
    /// Configuration comes first because a fan is matched on the LAN by its
    /// `device_id`, which the beacon carries as a MAC; that id is only known
    /// from the account's device list. Before Setup there is nothing to
    /// match, so listening would be pointless.
    private func updateLAN() {
        let shouldListen = lanEnabled && (panelIsOpen || setupIsOpen || backgroundRefresh) && isConfigured
        guard shouldListen else {
            lanLink?.stop()
            lanLink = nil
            if !lanEnabled || !isConfigured { localHosts = [:] }
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
        // Beacons arrive from any peer on the subnet, so a host is only
        // registered for a fan whose device_id the account lists. Nothing
        // here authenticates the broadcaster — that the protocol does not
        // offer — but random or malicious noise can no longer create hosts
        // that would silently absorb the selected fan's commands.
        guard devices.contains(where: { LANLink.normalise($0.deviceID) == beacon.mac }) else { return }
        localHosts[beacon.mac] = LocalHost(address: beacon.host, seenAt: Date())
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
            lanStateHeardAt = Date()
        }
    }
}
