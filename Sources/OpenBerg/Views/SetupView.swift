import AppKit
import SwiftUI

/// The Setup window's content.
///
/// Credentials live in a real, activatable window rather than the menu bar
/// panel: an accessory app's status-bar panel cannot reliably take keyboard
/// focus, which is why a text field inside one silently refuses to be typed
/// into. This window also gets opened automatically on first launch.
struct SetupView: View {
    @Bindable var model: AppModel

    /// Reports the laid-out content height so the window sizes itself to
    /// exactly what it shows, instead of clipping or leaving dead space.
    var onHeightChange: ((CGFloat) -> Void)?

    private static let repoURL = URL(string: "https://github.com/Harshsanket/open-berg")!
    private static let issuesURL = URL(string: "https://github.com/Harshsanket/open-berg/issues")!

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                credentials
                if !model.fans.isEmpty { deviceSection }
                refreshSection
                usageSection
                updatesSection
                aboutSection
                footer
            }
            .padding(18)
            .frame(width: 460, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .background(
                GeometryReader { geometry in
                    Color.clear
                        .preference(key: SetupHeightKey.self, value: geometry.size.height)
                }
            )
        }
        .frame(width: 460)
        .onPreferenceChange(SetupHeightKey.self) { height in
            onHeightChange?(height)
        }
    }

    // MARK: - Credentials

    private var credentials: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Credentials")
            Text("""
                Open Atomberg Home → Settings → Developer Mode and enable it. \
                Copy the API key and refresh token into their respective fields below. \
                Both credentials are securely stored in your macOS Keychain.
                """)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            CredentialField(
                title: "API key",
                prompt: "paste your API key",
                text: $model.apiKey
            )

            CredentialField(
                title: "Refresh token",
                prompt: "paste your refresh token",
                text: $model.refreshToken
            )

            HStack(spacing: 10) {
                // Nothing to save while the stored credentials are already in
                // use; the button returns the moment a field is edited.
                if !model.isConfigured || model.hasUnsavedCredentials {
                    Button {
                        Task { await model.saveCredentials() }
                    } label: {
                        Text("Save & connect")
                            .frame(minWidth: 96)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(model.isBusy || model.apiKey.isEmpty || model.refreshToken.isEmpty)
                }

                if model.isConfigured {
                    Button("Forget credentials") { model.forgetCredentials() }
                }

                Spacer()

                if model.isBusy {
                    ProgressView().controlSize(.small)
                } else if model.hasUnsavedCredentials {
                    Label("Not saved yet", systemImage: "circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.light)
                }
            }

            if model.apiKey.isEmpty || model.refreshToken.isEmpty {
                Text("Both fields are needed before the fan can be reached.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .card(radius: 16, padding: 14)
    }

    // MARK: - Device

    private var deviceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Fan")
            Picker("", selection: Binding(
                get: { model.selectedDevice?.id ?? "" },
                set: { value in Task { await model.selectDevice(value) } }
            )) {
                ForEach(model.fans) { fan in
                    Text(fan.displayName).tag(fan.id)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()

            if let device = model.selectedDevice {
                Text("device_id \(device.deviceID)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
        }
        .card(radius: 16, padding: 14)
    }

    // MARK: - Refresh policy

    private var refreshSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Behaviour")

            HStack {
                Text("Auto-refresh").font(.system(size: 12))
                Spacer()
                Picker("", selection: $model.refreshIntervalHours) {
                    Text("Manual").tag(0)
                    Text("Hourly").tag(1)
                    Text("Every 2 hours").tag(2)
                    Text("Every 6 hours").tag(6)
                    Text("Every 12 hours").tag(12)
                    Text("Every 24 hours").tag(24)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
            Text("Re-reads status and usage on this schedule while the panel is open. Usage totals are read at most once a day.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text("Refresh Status & Usage").font(.system(size: 12))
                Spacer()
                Button {
                    Task { await model.refreshEverything() }
                } label: {
                    Text("Refresh")
                        .frame(minWidth: 76)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isBusy || !model.isConfigured)
            }
            Text("Fetches the latest status and usage data.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text("Update Device list").font(.system(size: 12))
                Spacer()
                Button {
                    Task { await model.refreshDevices() }
                } label: {
                    Text("Update")
                        .frame(minWidth: 110)
                }
                .buttonStyle(.bordered)
                .disabled(model.isBusy || !model.isConfigured)
            }
            Text("Updates the device list. Only needed after adding or renaming a device.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Read the state back after every command", isOn: $model.confirmAfterCommand)
                .font(.system(size: 12))
            Toggle("Show speed beside the menu bar icon", isOn: $model.showSpeedInMenuBar)
                .font(.system(size: 12))
            Toggle("Start OpenBerg at login", isOn: $model.launchAtLogin)
                .font(.system(size: 12))
            if let note = model.loginItemNote {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .card(radius: 16, padding: 14)
    }

    // MARK: - API usage

    private var usageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "API usage")

            HStack {
                Text("Used today").font(.system(size: 12))
                Spacer()
                Text("\(model.usedToday) of \(CallBudget.dailyLimit)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("Last sync").font(.system(size: 12))
                Spacer()
                Text(model.stateAge.map { "State updated \($0)" } ?? "No state read yet")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Text("The free plan allows 100 calls a day at 5 a second, resetting at 00:00 UTC.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .card(radius: 16, padding: 14)
    }

    // MARK: - Updates

    private var updatesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Updates")

            HStack {
                Text("OpenBerg \(model.updater.currentVersion)")
                    .font(.system(size: 12))
                Spacer()
                switch model.updater.state {
                case .checking, .installing:
                    ProgressView().controlSize(.small)
                case .available(let version):
                    Button {
                        Task { await model.updater.install() }
                    } label: {
                        Text("Update to \(version)")
                            .frame(minWidth: 110)
                    }
                    .buttonStyle(.borderedProminent)
                default:
                    Button {
                        Task { await model.updater.check() }
                    } label: {
                        Text("Check now")
                            .frame(minWidth: 110)
                    }
                    .buttonStyle(.bordered)
                }
            }

            Text(updateNote)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Check for updates automatically", isOn: Bindable(model.updater).autoCheckEnabled)
                .font(.system(size: 12))
        }
        .card(radius: 16, padding: 14)
    }

    private var updateNote: String {
        switch model.updater.state {
        case .idle:
            return "Checks run when OpenBerg is started and once a month; installing reopens the app in place."
        case .checking:
            return "Checking GitHub for the latest release…"
        case .upToDate:
            return "You're on the latest version."
        case .available(let version):
            return "Version \(version) is available."
        case .installing:
            return "Downloading and installing — OpenBerg will relaunch."
        case .failed(let message):
            return message
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "About")

            Text("""
                Made proudly in Mumbai by Harsh Sanket. \
                Enjoying OpenBerg? Consider giving it a star on GitHub. \
                Found a bug or have a suggestion? Open an issue on GitHub. \
                OpenBerg is an independent, open-source project.
                """)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Link(destination: Self.repoURL) {
                    Label("Star on GitHub", systemImage: "star.fill")
                }
                .buttonStyle(.bordered)

                Link(destination: Self.issuesURL) {
                    Label("Create an issue", systemImage: "exclamationmark.bubble")
                }
                .buttonStyle(.bordered)
            }

            Text("github.com/Harshsanket/open-berg")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
        .card(radius: 16, padding: 14)
    }

    private var footer: some View {
        Text("a \(Text("Harsh Sanket").fontWeight(.bold)) production")
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}



/// A titled credential field.
///
/// Masked by default, with two affordances that make it obvious the field is
/// editable: the eye reveals what was pasted so it can be checked against the
/// Atomberg app, and the clipboard button fills it from the pasteboard without
/// needing a keyboard shortcut.
private struct CredentialField: View {
    let title: String
    let prompt: String
    @Binding var text: String

    @State private var revealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if !text.isEmpty {
                    Text("\(text.count) characters")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }

            HStack(spacing: 6) {
                Group {
                    if revealed {
                        TextField("", text: $text, prompt: Text(prompt))
                    } else {
                        SecureField("", text: $text, prompt: Text(prompt))
                    }
                }
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .frame(minWidth: 180)

                Button {
                    revealed.toggle()
                } label: {
                    Image(systemName: revealed ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .help(revealed ? "Hide" : "Show what you entered")

                Button {
                    if let value = NSPasteboard.general.string(forType: .string) {
                        text = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                } label: {
                    Image(systemName: "doc.on.clipboard")
                }
                .buttonStyle(.borderless)
                .help("Paste from the clipboard")

                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .disabled(text.isEmpty)
                .help("Clear")
            }
        }
    }
}

private struct SetupHeightKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
