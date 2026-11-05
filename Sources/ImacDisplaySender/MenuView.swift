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
            if let error = session.lastSpeedTestError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            ActionsSection(session: session, preferences: preferences, showingConnect: $panel.showingConnect)
            if panel.showingConnect {
                ConnectView(
                    preferences: preferences,
                    onConnect: { address, label in
                        panel.showingConnect = false
                        // Naming the receiver already on screen should not drop the stream.
                        if session.isLive(to: address), preferences.receivers.all.contains(where: { $0.address == address }) {
                            if let label { preferences.rename(address.description, to: label) }
                        } else {
                            session.connect(to: address, label: label)
                        }
                    },
                    onCancel: { panel.showingConnect = false })
            }

            Divider()
            SettingsSection(preferences: preferences, panel: panel)

            Divider()
            Button("Quit iMac Display Sender") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(14)
        .frame(width: 360)
        // The panel keeps its view between openings: start each one without
        // a half-filled form.
        .onDisappear { panel.showingConnect = false }
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
                .fixedSize(horizontal: false, vertical: true)
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
        // Re-rendered on a clock: nothing else changes while the panel stays open.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Text(String(format: "Speed test: %.0f Mbit/s", report.mbps) + link + ", " + age(at: context.date))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// `.named` says "now" for the first minute, which reads oddly here.
    private func age(at now: Date) -> String {
        now.timeIntervalSince(report.date) < 60
            ? "just now" : report.date.formatted(.relative(presentation: .named, unitsStyle: .wide))
    }
}

private struct ActionsSection: View {
    @ObservedObject var session: SenderSession
    @ObservedObject var preferences: Preferences
    @Binding var showingConnect: Bool

    var body: some View {
        HStack {
            ConnectMenu(session: session, preferences: preferences, showingConnect: $showingConnect)
                .disabled(showingConnect)
            Button("Disconnect") { session.disconnect() }
                .disabled(!session.isActive)
            Spacer()
            Button(session.speedTestRunning ? "Testing…" : "Run Speed Test") { session.runSpeedTest() }
                .disabled(!session.canRunSpeedTest)
                .help("Measures sender → receiver throughput for 1 s")
        }
    }
}

/// "Connect…" until something has connected; then a menu of the saved and
/// recent receivers, with the live one ticked. Choosing a receiver that is
/// not live (including one waiting to reconnect) connects to it now.
private struct ConnectMenu: View {
    @ObservedObject var session: SenderSession
    @ObservedObject var preferences: Preferences
    @Binding var showingConnect: Bool

    var body: some View {
        let receivers = preferences.receivers
        if receivers.all.isEmpty {
            Button("Connect…") { showingConnect = true }
        } else {
            Menu("Connect") {
                if !receivers.named.isEmpty {
                    Section("Saved") { ForEach(receivers.named, content: item) }
                }
                if !receivers.recent.isEmpty {
                    Section("Recent") { ForEach(receivers.recent, content: item) }
                }
                Divider()
                Button("Other Receiver…") { showingConnect = true }
            }
            .fixedSize()
        }
    }

    private func item(_ receiver: SavedReceiver) -> some View {
        Toggle(isOn: Binding(
            get: { session.isLive(to: receiver.address) },
            set: { _ in
                if !session.isLive(to: receiver.address) { session.connect(to: receiver.address) }
            })
        ) {
            Text("\(receiver.title)  —  \(receiver.detail)")
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
