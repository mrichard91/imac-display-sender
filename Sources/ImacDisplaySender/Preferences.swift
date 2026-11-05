import Foundation
import IDPCore
import IDPProtocol
import ServiceManagement

/// User settings in UserDefaults.
@MainActor
final class Preferences: ObservableObject {
    private enum Key {
        static let recentReceivers = "recentReceivers"
        static let bitrateMbps = "bitrateMbps"  // 0 = auto
        static let customBitrateMbps = "customBitrateMbps"
        static let autoReconnect = "autoReconnect"
    }

    private let defaults: UserDefaults

    /// Stored under the old "recent receivers" key, as a plain array.
    @Published private(set) var receivers: ReceiverList {
        didSet { save(receivers.all, forKey: Key.recentReceivers) }
    }

    @Published var bitrateMode: BitrateMode {
        didSet {
            if case .fixed(let mbps) = bitrateMode {
                defaults.set(mbps, forKey: Key.bitrateMbps)
            } else {
                defaults.set(0, forKey: Key.bitrateMbps)
            }
        }
    }

    /// Last value typed in the custom field, so switching presets does not lose it.
    @Published var customBitrateMbps: Int {
        didSet { defaults.set(customBitrateMbps, forKey: Key.customBitrateMbps) }
    }

    @Published var autoReconnect: Bool {
        didSet { defaults.set(autoReconnect, forKey: Key.autoReconnect) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        receivers = ReceiverList(Self.load([SavedReceiver].self, from: defaults, forKey: Key.recentReceivers) ?? [])
        let mbps = defaults.integer(forKey: Key.bitrateMbps)
        bitrateMode = mbps > 0 ? .fixed(mbps: mbps) : .auto
        let custom = defaults.integer(forKey: Key.customBitrateMbps)
        customBitrateMbps = custom > 0 ? custom : 100
        autoReconnect = defaults.object(forKey: Key.autoReconnect) as? Bool ?? true
    }

    var lastReceiver: SavedReceiver? { receivers.last }

    /// After a successful HELLO; `label` names the receiver (nil keeps its name).
    func remember(_ address: ReceiverAddress, name: String, label: String?) {
        receivers.remember(address, name: name, label: label)
    }

    func rename(_ id: SavedReceiver.ID, to label: String?) {
        receivers.rename(id, to: label)
    }

    func forget(_ receiver: SavedReceiver) {
        receivers.forget(receiver.id)
    }

    private func save<T: Encodable>(_ value: T, forKey key: String) {
        do {
            defaults.set(try JSONEncoder().encode(value), forKey: key)
        } catch {
            Log.error(.ui, "could not save \(key): \(error)")
        }
    }

    private static func load<T: Decodable>(_ type: T.Type, from defaults: UserDefaults, forKey key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

/// Launch at login through SMAppService. Only works when running from the
/// .app bundle (scripts/make-app-bundle.sh), not from `swift run`.
enum LaunchAtLogin {
    static var isAvailable: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
        Log.info(.ui, "launch at login \(enabled ? "enabled" : "disabled")")
    }
}
