import Foundation
import ServiceManagement

/// The login item, via `SMAppService`. The app is its own login item (no
/// helper bundle), which is the normal menu bar extra flow: at login the
/// agent starts and the status item appears. Nothing else runs at launch,
/// so an auto-started OpenBerg is idle until its panel is opened.
enum LaunchAtLogin {
    /// Whether the system currently lists the app as a login item.
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Makes the system match `enabled`. Failures are returned rather than
    /// thrown at the caller, because the preference is kept either way and
    /// the Setup page shows a note when the system refused.
    @discardableResult
    static func set(_ enabled: Bool) -> String? {
        let service = SMAppService.mainApp
        do {
            if enabled {
                // `.requiresApproval` means a registration already exists
                // and is waiting in System Settings; leave it pending.
                let status = service.status
                if status == .notRegistered || status == .notFound {
                    try service.register()
                }
            } else if service.status != .notRegistered {
                try service.unregister()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
