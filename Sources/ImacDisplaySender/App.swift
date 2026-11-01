import AppKit
import IDPCore
import SwiftUI

@main
struct ImacDisplaySenderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuView(session: appDelegate.session, preferences: appDelegate.preferences)
        } label: {
            MenuBarIcon(session: appDelegate.session)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarIcon: View {
    @ObservedObject var session: SenderSession

    var body: some View {
        Image(systemName: session.menuBarSymbol)
            .accessibilityLabel(session.statusText)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let preferences: Preferences
    let session: SenderSession
    private var signalSources: [DispatchSourceSignal] = []

    override init() {
        preferences = Preferences()
        session = SenderSession(preferences: preferences)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only, even when run unbundled (the bundle sets LSUIElement too).
        NSApp.setActivationPolicy(.accessory)
        installSignalHandlers()

        if let address = LaunchOptions.parse(CommandLine.arguments).address {
            Log.info(.ui, "auto-connecting to \(address) from launch arguments")
            session.connect(to: address)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard session.isActive else { return .terminateNow }
        session.shutdown { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    /// SIGINT/SIGTERM go through the normal quit path: GOODBYE, release display, exit 0.
    private func installSignalHandlers() {
        for signalNumber in [SIGINT, SIGTERM] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler {
                Log.info(.ui, "signal \(signalNumber), quitting")
                NSApp.terminate(nil)
            }
            source.resume()
            signalSources.append(source)
        }
    }
}
