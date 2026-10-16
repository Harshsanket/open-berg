import AppKit

/// Entry point.
///
/// This deliberately does not use a SwiftUI `MenuBarExtra` scene. A status-bar
/// panel belonging to an `LSUIElement` app cannot reliably take keyboard focus,
/// so the credential fields inside it could not be typed into. Owning the
/// `NSStatusItem` and presenting an activatable panel fixes that, and keeps the
/// app a pure accessory with no Dock icon.
@main
enum OpenBergMain {
    static func main() {
        MainActor.assumeIsolated {
            let application = NSApplication.shared
            let delegate = AppDelegate()
            application.delegate = delegate
            application.setActivationPolicy(.accessory)
            application.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panels: PanelController?
    private var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel.shared
        let controller = PanelController(model: model)
        self.model = model
        panels = controller

        Task { @MainActor in
            model.bootstrap()
            // Fresh install: open Setup straight away rather than leaving an
            // empty panel with no obvious way to add credentials.
            controller.showSetupIfUnconfigured()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.flushPersist()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
