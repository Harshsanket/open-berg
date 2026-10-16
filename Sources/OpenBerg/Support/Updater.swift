import AppKit
import Foundation

/// Update checks against the project's GitHub releases, with a one-click
/// self-install.
///
/// Deliberately no third-party updater: one `GET` to the Releases API, the
/// ZIP asset downloaded over URLSession, `ditto` to unpack it, and a tiny
/// detached shell script to swap the bundle and relaunch. None of this
/// touches the Atomberg quota.
///
/// When checks run (deliberately stingy):
///   * on a normal app launch, at most once a calendar day — a login start
///     is indistinguishable from a user start on macOS, so the daily
///     dedupe bounds those too;
///   * on the first session (panel or Setup) on or after the 20th of a
///     month, at most once a month, which covers an app that stays running
///     for weeks; and
///   * any time the Check Now button is pressed.
@MainActor
@Observable
final class Updater {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(String)
        case installing
        case failed(String)
    }

    private(set) var state: State = .idle

    /// Mirrors Gmail's "check for updates automatically" style setting;
    /// manual checks work either way.
    var autoCheckEnabled: Bool {
        didSet { defaults.set(autoCheckEnabled, forKey: Key.autoCheck) }
    }

    /// Set by verification fixtures; the real value comes from the bundle.
    @ObservationIgnored var currentVersionOverride: String?

    var currentVersion: String {
        currentVersionOverride
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0"
    }

    var availableVersion: String? {
        if case .available(let version) = state { return version }
        return nil
    }

    private struct Release: Equatable {
        let version: String
        let zip: URL
        let page: URL
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var release: Release?

    private enum Key {
        static let autoCheck = "updater.autoCheck"
        static let lastCheck = "updater.lastCheck"
    }

    private enum Endpoints {
        static let latest = URL(string: "https://api.github.com/repos/Harshsanket/open-berg/releases/latest")!
    }

    /// Ephemeral like the API session: an update check is not worth a cache.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        autoCheckEnabled = defaults.object(forKey: Key.autoCheck) as? Bool ?? true
    }

    // MARK: - Triggers

    enum Trigger { case launch, session, manual }

    /// Runs `check()` only when the trigger's conditions allow it; the
    /// conditions exist so the app is not quietly calling GitHub.
    func checkIfDue(_ trigger: Trigger, at date: Date = Date()) {
        guard autoCheckEnabled || trigger == .manual else { return }
        guard state != .checking, state != .installing else { return }

        switch trigger {
        case .launch:
            if let last = defaults.object(forKey: Key.lastCheck) as? Date,
               Calendar.current.isDate(last, inSameDayAs: date) {
                return
            }
        case .session:
            // Nothing new to find when a release is already on the table.
            if availableVersion != nil { return }
            guard Calendar.current.component(.day, from: date) >= 20 else { return }
            if let last = defaults.object(forKey: Key.lastCheck) as? Date,
               Calendar.current.isDate(last, equalTo: date, toGranularity: .month) {
                return
            }
        case .manual:
            break
        }
        Task { await check() }
    }

    // MARK: - Checking

    func check() async {
        state = .checking
        // Recorded on every outcome: a failed check should not turn into a
        // retry loop on every launch of the day.
        defer { defaults.set(Date(), forKey: Key.lastCheck) }

        do {
            var request = URLRequest(url: Endpoints.latest)
            request.timeoutInterval = 10
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("OpenBerg/\(currentVersion)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await Self.session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let payload = try JSONDecoder().decode(ReleasePayload.self, from: data)
            let tag = payload.tagName.hasPrefix("v") ? String(payload.tagName.dropFirst()) : payload.tagName

            guard Self.isNewer(tag, than: currentVersion),
                  let zip = payload.assets.first(where: { $0.name.hasSuffix(".zip") })?.browserDownloadURL
            else {
                release = nil
                state = .upToDate
                return
            }
            release = Release(version: tag, zip: zip, page: payload.htmlURL)
            state = .available(tag)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: - Installing

    /// Downloads the release ZIP and, if this copy can replace itself,
    /// swaps the bundle and relaunches. Copies that cannot (translocated,
    /// or a location the user cannot write) fall back to the release page.
    func install() async {
        guard case .available = state, let release else { return }
        let target = Bundle.main.bundleURL

        guard Self.canSelfInstall(bundle: target) else {
            NSWorkspace.shared.open(release.page)
            state = .failed("This copy cannot update itself. The release page has been opened.")
            return
        }

        state = .installing
        do {
            let work = FileManager.default.temporaryDirectory
                .appendingPathComponent("OpenBergUpdate-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: work) }

            let (download, _) = try await Self.session.download(from: release.zip)
            let archive = work.appendingPathComponent("update.zip")
            try FileManager.default.moveItem(at: download, to: archive)
            try Self.runDitto(unzip: archive, into: work)

            let newBundle = work.appendingPathComponent("OpenBerg.app")
            try Self.validate(newBundle: newBundle, expectedVersion: release.version)
            try Self.spawnSwapScript(newBundle: newBundle, target: target)
            NSApp.terminate(nil)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// The processes replaces itself; the ZIP asset is expected to hold one
    /// top-level `OpenBerg.app`.
    private static func canSelfInstall(bundle: URL) -> Bool {
        // A quarantined app started straight from the DMG runs from a
        // read-only translocated copy; nothing there is replaceable.
        if bundle.path.contains("/AppTranslocation/") { return false }
        let parent = bundle.deletingLastPathComponent()
        return FileManager.default.isWritableFile(atPath: parent.path)
    }

    private static func runDitto(unzip archive: URL, into directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, directory.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "OpenBerg.Updater", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not unpack the update."]
            )
        }
    }

    private static func validate(newBundle: URL, expectedVersion: String) throws {
        func fail(_ reason: String) -> NSError {
            NSError(domain: "OpenBerg.Updater", code: 1, userInfo: [NSLocalizedDescriptionKey: reason])
        }
        let plistURL = newBundle.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else {
            throw fail("The update did not contain an app bundle.")
        }
        guard plist["CFBundleIdentifier"] as? String == "com.openberg.AtombergFan" else {
            throw fail("The update has an unexpected bundle identifier.")
        }
        guard plist["CFBundleShortVersionString"] as? String == expectedVersion else {
            throw fail("The update's version does not match the release.")
        }
    }

    /// Hands the swap to a detached shell that outlives this process: it
    /// waits for the app to exit, moves the old bundle aside, moves the new
    /// one in, relaunches, and cleans up after itself.
    private static func spawnSwapScript(newBundle: URL, target: URL) throws {
        let script = """
        #!/bin/sh
        sleep 1
        rm -rf "\(target.path).old"
        mv "\(target.path)" "\(target.path).old"
        mv "\(newBundle.path)" "\(target.path)"
        open "\(target.path)"
        rm -rf "\(target.path).old"
        """
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openberg-update-\(UUID().uuidString).sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptURL.path]
        try process.run()
    }

    // MARK: - Helpers

    private static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ value: String) -> [Int] {
            value.split(separator: ".").map { Int($0) ?? 0 }
        }
        let lhs = parts(candidate)
        let rhs = parts(current)
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    private struct ReleasePayload: Decodable {
        let tagName: String
        let htmlURL: URL
        let assets: [Asset]

        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: URL

            private enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }

        private enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case assets
        }
    }
}
