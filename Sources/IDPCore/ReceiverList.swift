import Foundation

/// A receiver the sender has connected to successfully, with an optional name
/// the user gave it (e.g. "Thunderbolt" for 10.99.0.2).
public struct SavedReceiver: Codable, Hashable, Identifiable, Sendable {
    public var host: String
    public var port: UInt16
    /// What the receiver calls itself in HELLO (§6.1); may be empty.
    public var name: String
    /// The user's name for this address; nil when there is none. Missing in
    /// lists saved before names existed, which still decode.
    public var label: String?
    public var lastConnected: Date

    public init(host: String, port: UInt16, name: String, label: String? = nil, lastConnected: Date) {
        self.host = host
        self.port = port
        self.name = name
        self.label = label
        self.lastConnected = lastConnected
    }

    public var id: String { address.description }
    public var address: ReceiverAddress { ReceiverAddress(host: host, port: port) }
    public var isNamed: Bool { label != nil }

    /// The user's name, else the receiver's, else the host.
    public var title: String { label ?? (name.isEmpty ? host : name) }

    /// The address, after the receiver's name when the title is the user's.
    public var detail: String {
        isNamed && !name.isEmpty ? "\(name) · \(address)" : address.description
    }
}

/// Receivers to offer in the Connect menu, most recently connected first.
/// Named ones stay until the user forgets them; the unnamed ones are a recent
/// list capped at `maxUnnamed`.
public struct ReceiverList: Equatable, Sendable {
    public static let maxUnnamed = 10

    public private(set) var all: [SavedReceiver]

    public init(_ receivers: [SavedReceiver] = []) {
        all = []
        // Through `remember`'s rules, so stored lists get the same dedup,
        // label cleanup and cap.
        for receiver in receivers.sorted(by: { $0.lastConnected > $1.lastConnected }).reversed() {
            remember(receiver.address, name: receiver.name, label: receiver.label, at: receiver.lastConnected)
        }
    }

    /// Named receivers in title order, for a stable menu.
    public var named: [SavedReceiver] {
        all.filter(\.isNamed).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Unnamed receivers, most recent first.
    public var recent: [SavedReceiver] { all.filter { !$0.isNamed } }

    public var last: SavedReceiver? { all.first }

    /// Records a successful connection. `label` names the receiver; nil (or
    /// blank) keeps whatever name it already has.
    public mutating func remember(_ address: ReceiverAddress, name: String, label: String? = nil, at date: Date = Date()) {
        let existing = all.first { $0.address == address }
        all.removeAll { $0.address == address }
        let receiver = SavedReceiver(
            host: address.host, port: address.port, name: name,
            label: Self.cleaned(label) ?? existing?.label, lastConnected: date)
        all.insert(receiver, at: 0)
        trim()
    }

    /// Sets or, with nil or blank, removes the user's name.
    public mutating func rename(_ id: SavedReceiver.ID, to label: String?) {
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        all[index].label = Self.cleaned(label)
        trim()
    }

    public mutating func forget(_ id: SavedReceiver.ID) {
        all.removeAll { $0.id == id }
    }

    /// Drops the oldest unnamed receivers beyond the cap.
    private mutating func trim() {
        var unnamed = 0
        all.removeAll { receiver in
            guard !receiver.isNamed else { return false }
            unnamed += 1
            return unnamed > Self.maxUnnamed
        }
    }

    static func cleaned(_ label: String?) -> String? {
        guard let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
