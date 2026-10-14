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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                credentials
                environmentSection
                if !model.fans.isEmpty { deviceSection }
                refreshSection
                localNetworkSection
                endpointsSection
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 460, height: 560)
    }

    // MARK: - Credentials

    private var credentials: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Developer credentials")
            Text("""
            In the Atomberg Home app, open Settings → Developer Mode and turn it on. \
            It shows one API key and one refresh token for this account; copy each into \
            the matching field below. They are stored in your login keychain, never in \
            a preferences file, log or build output.
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
                Button {
                    Task { await model.saveCredentials() }
                } label: {
                    Text(model.hasUnsavedCredentials ? "Save & connect" : "Reconnect")
                        .frame(minWidth: 96)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [])
                .disabled(model.isBusy || model.apiKey.isEmpty || model.refreshToken.isEmpty)

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

    // MARK: - Environment

    private var environmentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "API base")
            Picker("", selection: $model.environment) {
                ForEach(AtombergAPI.Environment.allCases) { environment in
                    Text(environment.title).tag(environment)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(model.environment.baseURL.absoluteString)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
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
                let commands = device.supportedCommands.map(\.command).sorted()
                Text(commands.isEmpty
                     ? "This device advertises no commands."
                     : "Accepts: \(commands.joined(separator: ", "))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
                Picker("", selection: $model.autoRefreshSeconds) {
                    Text("Manual").tag(0)
                    Text("5 min").tag(300)
                    Text("15 min").tag(900)
                    Text("30 min").tag(1800)
                    Text("1 hour").tag(3600)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 110)
            }

            if model.autoRefreshSeconds > 0 {
                let cost = CallBudget.dailyCost(forInterval: model.autoRefreshSeconds)
                Text(cost > CallBudget.dailyLimit
                     ? "About \(cost) calls a day, which is over the free plan's 100. Reads over the local network cost nothing, so enable that below if you pick this interval."
                     : "About \(cost) calls a day, against a 100 call limit.")
                    .font(.system(size: 10))
                    .foregroundStyle(cost > CallBudget.dailyLimit ? Palette.light : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle("Read the state back after every command", isOn: $model.confirmAfterCommand)
                .font(.system(size: 12))
            Toggle("Show speed beside the menu bar icon", isOn: $model.showSpeedInMenuBar)
                .font(.system(size: 12))

            Divider()

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
            Text("The free plan allows 100 calls a day at 5 a second, resetting at 00:00 UTC. Failed calls count too.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .card(radius: 16, padding: 14)
    }

    // MARK: - Local network

    private var localNetworkSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Local network")
            Toggle("Control the fan over your LAN", isOn: $model.lanEnabled)
                .font(.system(size: 12))
            Text("Fans broadcast a beacon on UDP 5625 and accept the same command JSON on UDP 5600, so local control costs no API calls. macOS asks for permission the first time this is switched on.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            if model.lanEnabled {
                VStack(alignment: .leading, spacing: 2) {
                    if let note = model.lanNote {
                        Text(note).textSelection(.enabled)
                    }
                    Text(model.isLocalReady ? "Matched to \(model.localHost ?? "—")" : "No matching fan beacon heard yet.")
                    if !model.lastLocalPacketPreview.isEmpty {
                        Text("Last packet on 5600: \(model.lastLocalPacketPreview)")
                            .textSelection(.enabled)
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .card(radius: 16, padding: 14)
    }

    // MARK: - Endpoints

    private var endpointsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "Endpoints used")
            Text("""
            GET  /get_access_token
            GET  /get_list_of_devices
            GET  /get_device_state
            GET  /get_device_analytics
            POST /send_command
            """)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)

            Link("Atomberg IoT API reference", destination: URL(string: "https://developer.atomberg-iot.com/reference")!)
                .font(.system(size: 11))
        }
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
