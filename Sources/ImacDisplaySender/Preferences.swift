import Foundation
import IDPCore
import IDPProtocol
import ServiceManagement

/// A receiver the user connected to successfully, with the name from its HELLO.
struct RecentReceiver: Codable, Hashable, Identifiable {
    var host: String
    var port: UInt16
    var name: String
    var lastConnected: Date

    var id: String { address.description }
    var address: ReceiverAddress { ReceiverAddress(host: host, port: port) }
}

/// User settings in UserDefaults.
@MainActor
final class Preferences: ObservableObject {
    static let maxRecentReceivers = 10

    private enum Key {
        static let recentReceivers = "recentReceivers"
        static let bitrateMbps = "bitrateMbps"  // 0 = auto
        static let customBitrateMbps = "customBitrateMbps"
        static let autoReconnect = "autoReconnect"
    }

    private let defaults: UserDefaults

    @Published private(set) var recentReceivers: [RecentReceiver] {
        didSet { save(recentReceivers, forKey: Key.recentReceivers) }
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
        recentReceivers = Self.load([RecentReceiver].self, from: defaults, forKey: Key.recentReceivers) ?? []
        let mbps = defaults.integer(forKey: Key.bitrateMbps)
        bitrateMode = mbps > 0 ? .fixed(mbps: mbps) : .auto
        let custom = defaults.integer(forKey: Key.customBitrateMbps)
        customBitrateMbps = custom > 0 ? custom : 100
        autoReconnect = defaults.object(forKey: Key.autoReconnect) as? Bool ?? true
    }

    var lastReceiver: RecentReceiver? { recentReceivers.first }

    /// Moves (or adds) the receiver to the top of the recent list.
    func remember(_ address: ReceiverAddress, name: String) {
        var list = recentReceivers.filter { $0.address != address }
        list.insert(RecentReceiver(host: address.host, port: address.port, name: name, lastConnected: Date()), at: 0)
        recentReceivers = Array(list.prefix(Self.maxRecentReceivers))
    }

    func forget(_ receiver: RecentReceiver) {
        recentReceivers.removeAll { $0.id == receiver.id }
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
