import AppKit
import SwiftUI

/// A borderless panel that is allowed to become the key window.
///
/// This is the crux of the fix for the unusable credential fields: a status-bar
/// panel in an `LSUIElement` app never becomes key on its own, so SwiftUI text
/// fields inside one accept no keystrokes. Overriding `canBecomeKey` and
/// activating the app before showing the panel makes it a normal, focusable
/// window.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns the menu bar item, the control panel it opens, and the Setup window.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    static let panelWidth: CGFloat = 372

    private let model: AppModel
    private let statusItem: NSStatusItem
    private let panel: KeyablePanel
    private var setupWindow: NSWindow?
    /// Last content height reported by the view; drives the window size.
    private var contentHeight: CGFloat = 360

    init(model: AppModel) {
        self.model = model
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // The height here only matters until the first layout, when
        // `applyContentHeight` picks the real one from the view's content.
        panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 360),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()

        configureStatusItem()
        configurePanel()
        model.onRequestSetup = { [weak self] in self?.showSetup() }
        observeModel()
    }

    // MARK: - Menu bar item

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(statusItemClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = "OpenBerg"
        updateStatusItem()
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        button.image = model.menuBarImage
        button.imagePosition = .imageLeading
        if model.showSpeedInMenuBar, model.isPoweredOn, let speed = model.speed {
            button.title = " \(speed)"
        } else {
            button.title = ""
        }
    }

    /// Keeps the glyph's opacity and the optional speed in step with the model
    /// without polling.
    private func observeModel() {
        withObservationTracking {
            _ = model.menuBarImage
            _ = model.showSpeedInMenuBar
            _ = model.speed
            _ = model.isPoweredOn
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.updateStatusItem()
                self?.observeModel()
            }
        }
    }

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showStatusMenu()
        } else {
            togglePanel()
        }
    }

    private func showStatusMenu() {
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open Control Panel", action: #selector(openPanel), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        let setup = NSMenuItem(title: "Setup…", action: #selector(openSetup), keyEquivalent: ",")
        setup.target = self
        menu.addItem(setup)

        menu.addItem(.separator())

        let refresh = NSMenuItem(title: "Refresh State", action: #selector(refreshState), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        let analytics = NSMenuItem(title: "Refresh Usage", action: #selector(refreshAnalytics), keyEquivalent: "")
        analytics.target = self
        menu.addItem(analytics)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit OpenBerg", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        // Attach the menu only long enough to pop it, so a left click keeps
        // opening the panel rather than the menu.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openPanel() { showPanel() }
    @objc private func openSetup() { showSetup() }
    @objc private func refreshState() { Task { await model.refreshState() } }
    @objc private func refreshAnalytics() { Task { await model.refreshAnalytics() } }
    @objc private func quit() { NSApplication.shared.terminate(nil) }

    // MARK: - Control panel

    private func configurePanel() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.isMovable = false
        panel.hidesOnDeactivate = true
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.delegate = self

        // Translucent material only — the panel picks up whatever is behind
        // it; the fixed dark palette inside keeps the look dark either way.
        var view = ControlPanelView(model: model)
        view.onHeightChange = { [weak self] height in
            MainActor.assumeIsolated {
                self?.applyContentHeight(height)
            }
        }
        let content = view
            .environment(\.colorScheme, .dark)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Palette.stroke)
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

        panel.contentView = NSHostingView(rootView: content)
    }

    func togglePanel() {
        panel.isVisible ? hidePanel() : showPanel()
    }

    func showPanel() {
        applyContentHeight(contentHeight)
        positionPanel()
        // An accessory app is not frontmost by default, and a non-frontmost
        // window receives no key events.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)

        // Re-check once the status item has a window, so the screen-height clamp
        // is applied to the display the item is actually on.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.isVisible else { return }
            self.applyContentHeight(self.contentHeight)
            self.positionPanel()
        }
    }

    func hidePanel() {
        panel.orderOut(nil)
    }

    /// Sizes the panel to exactly fit the content the view reports, clamped
    /// so it never grows taller than the screen it sits on.
    private func applyContentHeight(_ height: CGFloat) {
        contentHeight = height
        var fitted = max(200, height)
        let screen = statusItem.button?.window?.screen ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            fitted = min(fitted, max(280, visible.height - 40))
        }
        let changed = abs(panel.frame.height - fitted) > 1
        panel.setContentSize(NSSize(width: Self.panelWidth, height: fitted))
        if changed, panel.isVisible { positionPanel() }
    }

    private func positionPanel() {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        let size = panel.frame.size
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        var origin = NSPoint(
            x: anchor.midX - size.width / 2,
            y: anchor.minY - size.height - 6
        )
        let screen = buttonWindow.screen ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
            origin.y = max(origin.y, visible.minY + 8)
        }
        panel.setFrameOrigin(origin)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard (notification.object as? NSWindow) === panel else { return }
        hidePanel()
    }

    // MARK: - Setup window

    /// A real, titled window. Text fields here always work, which is the point.
    func showSetup() {
        if setupWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 560),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "OpenBerg Setup"
            window.isReleasedWhenClosed = false
            let setup = SetupView(model: model)
                .environment(\.colorScheme, .dark)
                .background(Palette.background)
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = NSHostingView(rootView: setup)
            window.center()
            setupWindow = window
        }
        hidePanel()
        NSApp.activate(ignoringOtherApps: true)
        setupWindow?.makeKeyAndOrderFront(nil)
    }

    /// Opens Setup by itself when there are no credentials yet, so a new user
    /// is never left hunting for where to paste them.
    func showSetupIfUnconfigured() {
        guard !model.isConfigured else { return }
        showSetup()
    }
}
