import AppKit
import IDPCore
import IDPProtocol
import SwiftUI

/// The menu bar panel: status, link stats, actions and settings.
struct MenuView: View {
    @ObservedObject var session: SenderSession
    @ObservedObject var preferences: Preferences
    @StateObject private var panel = PanelState()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            StatusSection(session: session)

            if session.isConnected {
                Divider()
                StatsSection(session: session)
            }
            if let report = session.lastSpeedTest {
                SpeedTestLine(report: report)
            }

            Divider()
            if panel.showingConnect {
                ConnectView(
                    preferences: preferences,
                    onConnect: { address in
                        panel.showingConnect = false
                        session.connect(to: address)
                    },
                    onCancel: { panel.showingConnect = false })
            } else {
                ActionsSection(session: session, showingConnect: $panel.showingConnect)
            }

            Divider()
            SettingsSection(preferences: preferences, panel: panel)

            Divider()
            Button("Quit iMac Display Sender") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(14)
        .frame(width: 340)
    }
}

/// View-local state. Model objects rather than `@State`, which is a SwiftUI
/// macro in recent SDKs whose plugin ships only with Xcode, not the
/// Command Line Tools.
@MainActor
final class PanelState: ObservableObject {
    @Published var showingConnect = false
    @Published var launchAtLogin = LaunchAtLogin.isEnabled
    @Published var launchError: String?
}

// MARK: Sections

private struct StatusSection: View {
    @ObservedObject var session: SenderSession

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(session.statusText, systemImage: session.menuBarSymbol)
                .font(.headline)
                .lineLimit(2)
            if let error = session.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct StatsSection: View {
    @ObservedObject var session: SenderSession

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
            if let link = session.link {
                row("Link", link.summary + rttText)
            }
            if let size = session.streamSize {
                row("Stream", "\(size.width)×\(size.height)")
            }
            row("Bitrate", String(format: "%.1f / %.0f Mbit/s",
                                  session.effectiveBitsPerSecond / 1_000_000, Double(session.targetKbps) / 1_000))
            row("Frames", String(format: "%.0f fps · %d skipped", session.framesPerSecond, session.framesSkipped))
        }
        .font(.callout)
    }

    private var rttText: String {
        guard let rtt = session.rttMicroseconds else { return "" }
        return String(format: " · RTT %.1f ms", Double(rtt) / 1_000)
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
    }
}

private struct SpeedTestLine: View {
    let report: SpeedTestReport

    var body: some View {
        let link = report.link.map { " over \($0.summary)" } ?? ""
        let when = report.date.formatted(.relative(presentation: .named))
        Text(String(format: "Speed test: %.0f Mbit/s", report.mbps) + link + ", " + when)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

private struct ActionsSection: View {
    @ObservedObject var session: SenderSession
    @Binding var showingConnect: Bool

    var body: some View {
        HStack {
            Button("Connect…") { showingConnect = true }
            Button("Disconnect") { session.disconnect() }
                .disabled(!session.isActive)
            Spacer()
            Button(session.speedTestRunning ? "Testing…" : "Run Speed Test") { session.runSpeedTest() }
                .disabled(!session.canRunSpeedTest)
                .help("Measures sender → receiver throughput for 1 s")
        }
    }
}

private struct SettingsSection: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var panel: PanelState

    /// Picker tags: 0 = Auto, -1 = Custom, otherwise a preset in Mbit/s.
    private static let customTag = -1

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Bitrate", selection: bitrateSelection) {
                Text("Auto (speed test)").tag(0)
                ForEach(BitrateMode.presetsMbps, id: \.self) { Text("\($0) Mbit/s").tag($0) }
                Text("Custom").tag(Self.customTag)
            }
            if bitrateSelection.wrappedValue == Self.customTag {
                HStack {
                    Text("Custom")
                    TextField("Mbit/s", value: customBitrate, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                    Text("Mbit/s")
                }
            }
            Toggle("Reconnect automatically", isOn: $preferences.autoReconnect)
            Toggle("Launch at login", isOn: $panel.launchAtLogin)
                .disabled(!LaunchAtLogin.isAvailable)
                .help(LaunchAtLogin.isAvailable ? "" : "Available when running from the .app bundle")
                .onChange(of: panel.launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
            if let launchError = panel.launchError {
                Text(launchError).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var bitrateSelection: Binding<Int> {
        Binding(
            get: {
                switch preferences.bitrateMode {
                case .auto: return 0
                case .fixed(let mbps): return BitrateMode.presetsMbps.contains(mbps) ? mbps : Self.customTag
                }
            },
            set: { tag in
                switch tag {
                case 0: preferences.bitrateMode = .auto
                case Self.customTag: preferences.bitrateMode = .fixed(mbps: preferences.customBitrateMbps)
                default: preferences.bitrateMode = .fixed(mbps: tag)
                }
            })
    }

    private var customBitrate: Binding<Int> {
        Binding(
            get: { preferences.customBitrateMbps },
            set: { value in
                let mbps = min(1_000, max(1, value))
                preferences.customBitrateMbps = mbps
                preferences.bitrateMode = .fixed(mbps: mbps)
            })
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        guard enabled != LaunchAtLogin.isEnabled else { return }
        do {
            try LaunchAtLogin.set(enabled)
            panel.launchError = nil
        } catch {
            panel.launchError = "Launch at login: \(error.localizedDescription)"
            panel.launchAtLogin = LaunchAtLogin.isEnabled
        }
    }
}
