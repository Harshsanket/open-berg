import AppKit
import SwiftUI

/// The control panel that hangs off the menu bar item.
///
/// Laid out as the dark card stack from the reference: a header with the power
/// button, a hero plate with state chips, a big speed readout with a sleep
/// pill, the gradient speed slider, then a grid of tiles. Every control is
/// gated on the device's own `supported_commands`, so a fan without a light
/// never shows one, and a series that rejects `brightness` is never offered it.
struct ControlPanelView: View {
    static let width: CGFloat = 372

    @Bindable var model: AppModel

    /// Reports the laid-out content height so the hosting panel can size
    /// itself exactly — there is no scroll view, the panel is as tall as
    /// what it shows.
    var onHeightChange: ((CGFloat) -> Void)?

    @State private var speedDraft: Double?
    @State private var brightnessDraft: Double?

    private let tileColumns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
    ]

    var body: some View {
        VStack(spacing: 0) {
            if let warning = model.quotaWarning {
                quotaPill(warning)
            }
            header
            VStack(alignment: .leading, spacing: 14) {
                content
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            footer
        }
        .frame(width: Self.width)
        .background(
            GeometryReader { geometry in
                Color.clear
                    .preference(key: PanelHeightKey.self, value: geometry.size.height)
            }
        )
        .onPreferenceChange(PanelHeightKey.self) { height in
            onHeightChange?(height)
        }
    }

    // MARK: - Header

    private func quotaPill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Palette.light)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background(Capsule().fill(Palette.light.opacity(0.15)))
            .overlay(Capsule().strokeBorder(Palette.light.opacity(0.5)))
            .padding(.horizontal, 14)
            .padding(.top, 10)
    }

    private var header: some View {
        HStack(spacing: 10) {
            iconChip
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if hasSelectedFan {
                    StatusLine(online: model.deviceState?.isOnline, local: model.isLocalReady)
                }
            }
            Spacer(minLength: 4)
            if hasSelectedFan {
                CircleButton(
                    systemName: model.isLocalReady ? "wifi" : "wifi.slash",
                    size: 32,
                    tint: model.isLocalReady ? Palette.fanBright : Palette.textSecondary,
                    filled: model.isLocalReady,
                    glow: model.isLocalReady
                ) {
                    model.lanEnabled.toggle()
                }
                .help(lanHelp)
            }

            CircleButton(systemName: "slider.horizontal.3", size: 32) {
                model.onRequestSetup?()
            }
            .help("Setup")

            if model.supports("power") {
                CircleButton(
                    systemName: "power",
                    size: 44,
                    tint: Palette.fan,
                    filled: model.isPoweredOn,
                    glow: model.isPoweredOn
                ) {
                    Task { await model.togglePower() }
                }
                .help(model.isPoweredOn ? "Turn the fan off" : "Turn the fan on")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var iconChip: some View {
        Image(systemName: "fan.ceiling")
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(Palette.textSecondary)
            .frame(width: 36, height: 36)
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(Palette.stroke)
            }
    }

    // MARK: - Sections

    @ViewBuilder
    private var content: some View {
        if model.status.kind == .error {
            Notice(
                icon: "exclamationmark.triangle.fill",
                title: "Something went wrong",
                message: model.status.hint.map { "\(model.status.text) \($0)" } ?? model.status.text
            )
        }
        if !model.isConfigured {
            Notice(
                icon: "key",
                title: "Setup needed",
                message: "Add the API key and refresh token from Developer Mode in the Atomberg Home app.",
                actionTitle: "Open Setup",
                action: { model.onRequestSetup?() }
            )
        } else if !model.hasLoadedDevices {
            // Nothing has been paid for yet: say so rather than claiming the
            // account has no fan. Only the fan list is fetched here; Refresh
            // reads state and usage separately.
            Notice(
                icon: "arrow.clockwise",
                title: "Nothing loaded yet",
                message: "Fetch the fan list first, then use Refresh for its readings. Nothing is read until you ask for it.",
                actionTitle: "Fetch fan list",
                action: { Task { await model.refreshDevices(); await model.refreshEverything() } }
            )
        } else if model.fans.isEmpty {
            Notice(
                icon: "fan.slash",
                title: "No fan found",
                message: "This account has no Wi-Fi fan that the public API supports. Commands, state and analytics only work for the series listed in the reference."
            )
        } else {
            if model.fans.count > 1 { fanPicker }
            speedSection
            quickTiles
            lightSection
            usageSection
        }
    }

    private var fanPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.fans) { fan in
                    let selected = fan.id == model.selectedDevice?.id
                    Button {
                        Task { await model.selectDevice(fan.id) }
                    } label: {
                        Text(fan.displayName)
                            .font(.system(size: 12, weight: selected ? .semibold : .medium))
                            .foregroundStyle(selected ? Palette.text : Palette.textSecondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                Capsule().fill(selected ? Palette.fan.opacity(0.22) : Color.white.opacity(0.05))
                            )
                            .overlay(
                                Capsule().strokeBorder(
                                    selected ? Palette.fan.opacity(0.6) : Palette.stroke
                                )
                            )
                            .shadow(
                                color: selected ? Palette.fan.opacity(0.35) : .clear,
                                radius: 8, y: 2
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - Speed: readout with steppers, full-width slider

    @ViewBuilder
    private var speedSection: some View {
        if model.supports("speed") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center) {
                    Readout(value: speedText, unit: "of 6")
                        .opacity(model.isPoweredOn ? 1 : 0.4)
                    Spacer()
                    HStack(spacing: 8) {
                        CircleButton(
                            systemName: "minus",
                            size: 32,
                            tinted: true,
                            enabled: canNudge(-1),
                            action: { Task { await model.nudgeSpeed(by: -1) } }
                        )
                        CircleButton(
                            systemName: "plus",
                            size: 32,
                            tinted: true,
                            enabled: canNudge(1),
                            action: { Task { await model.nudgeSpeed(by: 1) } }
                        )
                    }
                }

                GradientSlider(
                    value: speedValue,
                    range: 1...6,
                    gradient: LinearGradient(
                        colors: [Palette.fan.opacity(0.25), Palette.fan],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                ) {
                    guard model.isPoweredOn else { return }
                    let level = Int(speedValue.wrappedValue.rounded())
                    speedDraft = nil
                    Task { await model.setSpeed(level) }
                }
                .frame(maxWidth: .infinity)
                .opacity(model.isPoweredOn ? 1 : 0.4)
                .allowsHitTesting(model.isPoweredOn)
                .help("Speed, 1 to 6")

                HStack {
                    Text("1").font(.system(size: 10)).foregroundStyle(Palette.textTertiary)
                    Spacer()
                    Text("6").font(.system(size: 10)).foregroundStyle(Palette.textTertiary)
                }
            }
            .card(radius: 16, padding: 14, tint: Palette.fan)
        }
    }

    // MARK: - Quick tiles: timer + extras

    @ViewBuilder
    private var quickTiles: some View {
        let extras: [(icon: String, title: String, value: String, active: Bool, enabled: Bool, run: () -> Void)] = [
            model.supports("timer")
                ? ("timer", "Timer", timerValue, timerHours > 0, model.isPoweredOn,
                   { Task { await model.setTimer(hours: nextTimerHours) } })
                : nil,
            model.supports("sleep")
                ? ("moon.zzz.fill", "Sleep", onOff(model.deviceState?.sleepMode == true), model.deviceState?.sleepMode == true, model.isPoweredOn,
                   { Task { await model.setSleep(!(model.deviceState?.sleepMode ?? false)) } })
                : nil,
            model.supports("led")
                ? ("lightbulb.fill", "Light", lightTileValue, model.deviceState?.led == true, true,
                   { Task { await model.setLED(!(model.deviceState?.led ?? false)) } })
                : nil,
            model.supports("rev_mode")
                ? ("arrow.triangle.2.circlepath", "Reverse", onOff(model.deviceState?.revMode == true), model.deviceState?.revMode == true, model.isPoweredOn,
                   { Task { await model.setReverse(!(model.deviceState?.revMode ?? false)) } })
                : nil,
            model.supports("buzzer_status")
                ? ("speaker.wave.2.fill", "Beep", onOff(model.deviceState?.buzzerStatus == true), model.deviceState?.buzzerStatus == true, true,
                   { Task { await model.setBuzzer(!(model.deviceState?.buzzerStatus ?? true)) } })
                : nil,
        ].compactMap { $0 }

        if !extras.isEmpty {
            LazyVGrid(columns: tileColumns, spacing: 8) {
                ForEach(extras.indices, id: \.self) { index in
                    let item = extras[index]
                    QuickTile(
                        icon: item.icon,
                        title: item.title,
                        value: item.value,
                        active: item.active,
                        enabled: item.enabled,
                        action: item.run
                    )
                }
            }
        }
    }

    // MARK: - Light

    @ViewBuilder
    private var lightSection: some View {
        if model.supports("brightness") || model.supports("light_mode") {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "Light")

                if model.supports("brightness") {
                    HStack(spacing: 8) {
                        CircleButton(
                            systemName: "minus",
                            size: 30,
                            tint: Palette.light,
                            tinted: true,
                            enabled: canStepBrightness(-10),
                            action: { Task { await model.setBrightness((model.deviceState?.brightness ?? 50) - 10) } }
                        )
                        GradientSlider(
                            value: brightnessSliderValue,
                            range: 10...100,
                            gradient: LinearGradient(
                                colors: [Color.white.opacity(0.20), Palette.light],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        ) {
                            let percent = Int(brightnessSliderValue.wrappedValue.rounded())
                            brightnessDraft = nil
                            Task { await model.setBrightness(percent) }
                        }
                        CircleButton(
                            systemName: "plus",
                            size: 30,
                            tint: Palette.light,
                            tinted: true,
                            enabled: canStepBrightness(10),
                            action: { Task { await model.setBrightness((model.deviceState?.brightness ?? 50) + 10) } }
                        )
                    }
                    .help("Brightness, 10 to 100 percent")

                    HStack {
                        Text("10%").font(.system(size: 10)).foregroundStyle(Palette.textTertiary)
                        Spacer()
                        Text("100%").font(.system(size: 10)).foregroundStyle(Palette.textTertiary)
                    }
                }

                if model.supports("light_mode") {
                    HStack(spacing: 8) {
                        ForEach(lightModes, id: \.value) { mode in
                            QuickTile(
                                icon: mode.icon,
                                title: mode.title,
                                value: model.deviceState?.color == mode.value ? "Selected" : "Tap",
                                active: model.deviceState?.color == mode.value,
                                tint: Palette.light
                            ) {
                                Task { await model.setLightMode(mode.value) }
                            }
                        }
                    }
                }
            }
            .card(radius: 16, padding: 14, tint: Palette.light)
        }
    }

    /// Energy and runtime as two side-by-side stat cards, not a text row.
    private var usageSection: some View {
        HStack(spacing: 8) {
            StatCard(icon: "bolt.fill", tint: Palette.green, title: "Energy", value: energyText)
            StatCard(icon: "clock.fill", tint: Palette.orange, title: "Runtime", value: runtimeText)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                if let age = model.stateAge {
                    Text("Fan last reported \(age).")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.textTertiary)
                }
                if model.isOnline == false {
                    Text("The fan is offline, so commands are not sent right now.")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.light)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if model.isBusy {
                ProgressView().controlSize(.mini)
            }
            PillButton(title: "Refresh", enabled: !model.isBusy && model.isConfigured) {
                Task { await model.refreshEverything() }
            }
            PillButton(title: "Quit") { NSApplication.shared.terminate(nil) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Derived values

    private var title: String {
        model.selectedDevice?.displayName ?? "OpenBerg"
    }

    /// With no fan known — first run, setup needed, or nothing loaded yet —
    /// the header shows neither the status line nor the LAN button: there is
    /// no link that either could describe, and "Online · cloud" about nothing
    /// was exactly the kind of claim this panel should not make.
    private var hasSelectedFan: Bool { model.selectedDevice != nil }

    /// The wifi button's fill follows the live LAN link, not the preference,
    /// so it never claims "local" while the status line says "cloud". The
    /// tooltip says what is actually happening and what a click does.
    private var lanHelp: String {
        if model.isLocalReady {
            return "Local network control is on — commands cost no API calls"
        }
        if model.lanEnabled {
            return "Local network control is on, but this fan isn't reachable locally — commands use the cloud. Click to turn it off."
        }
        return "Turn on local network control"
    }

    private var speedText: String {
        if let draft = speedDraft { return "\(Int(draft.rounded()))" }
        guard let speed = model.deviceState?.speed else { return "—" }
        return "\(speed)"
    }

    private var speedValue: Binding<Double> {
        Binding(
            get: { speedDraft ?? Double(model.deviceState?.speed ?? 3) },
            set: { speedDraft = $0 }
        )
    }

    private var brightnessSliderValue: Binding<Double> {
        Binding(
            get: { brightnessDraft ?? Double(model.deviceState?.brightness ?? 50) },
            set: { brightnessDraft = $0 }
        )
    }

    private var timerHours: Int { model.deviceState?.timerHours ?? 0 }

    private var timerValue: String {
        timerHours > 0 ? "\(timerHours) h" : "Off"
    }

    /// Timer cycles off → 1 → 2 → 3 → 6 → off, so the tile is one tap to the
    /// next preset instead of opening a menu.
    private var nextTimerHours: Int {
        switch timerHours {
        case 0: return 1
        case 1: return 2
        case 2: return 3
        case 3: return 6
        default: return 0
        }
    }

    private var lightModes: [(icon: String, title: String, value: String)] {
        [("flame.fill", "Warm", "warm"), ("snowflake", "Cool", "cool"), ("sun.max.fill", "Daylight", "daylight")]
    }

    private var lightTileValue: String {
        guard model.deviceState?.led == true else { return "Off" }
        if model.supports("brightness"), let brightness = model.deviceState?.brightness {
            return "\(brightness)%"
        }
        return "On"
    }

    private func onOff(_ value: Bool) -> String { value ? "On" : "Off" }

    private func canNudge(_ delta: Int) -> Bool {
        guard model.isPoweredOn, model.supports("speedDelta"), let current = model.deviceState?.speed else { return false }
        return (1...6).contains(current + delta)
    }

    private func canStepBrightness(_ delta: Int) -> Bool {
        let current = model.deviceState?.brightness ?? 50
        return (10...100).contains(current + delta)
    }

    private var energyText: String {
        guard let value = model.analytics?.powerConsumption else { return "—" }
        return String(format: "%.1f kWh", value)
    }

    private var runtimeText: String {
        guard let value = model.analytics?.runtime else { return "—" }
        return String(format: "%.1f h", value)
    }
}

private struct PanelHeightKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// The panel has no scroll view: its height is measured from the laid-out
// content and applied by `PanelController`, so the menu is exactly as tall
// as what it shows.
