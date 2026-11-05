import Foundation
import Testing
@testable import IDPCore

@Suite("Saved receivers")
struct ReceiverListTests {
    let thunderbolt = ReceiverAddress(host: "10.99.0.1")
    let lan = ReceiverAddress(host: "192.168.8.21")
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func rememberPutsTheLatestFirstWithoutDuplicates() {
        var list = ReceiverList()
        list.remember(thunderbolt, name: "imac-ubuntu", at: start)
        list.remember(lan, name: "imac-ubuntu", at: start + 1)
        list.remember(thunderbolt, name: "renamed-host", at: start + 2)

        #expect(list.all.map(\.address) == [thunderbolt, lan])
        #expect(list.last?.name == "renamed-host")
        #expect(list.last?.lastConnected == start + 2)
    }

    @Test func aLabelIsKeptAcrossReconnectsUntilReplaced() {
        var list = ReceiverList()
        list.remember(thunderbolt, name: "imac-ubuntu", label: "  Thunderbolt ", at: start)
        #expect(list.last?.label == "Thunderbolt")

        list.remember(thunderbolt, name: "imac-ubuntu", at: start + 1)
        list.remember(thunderbolt, name: "imac-ubuntu", label: "   ", at: start + 2)
        #expect(list.last?.label == "Thunderbolt")

        list.remember(thunderbolt, name: "imac-ubuntu", label: "Cable", at: start + 3)
        #expect(list.last?.label == "Cable")
    }

    @Test func titleAndDetail() {
        var list = ReceiverList()
        list.remember(thunderbolt, name: "imac-ubuntu", label: "Thunderbolt", at: start)
        list.remember(lan, name: "imac-ubuntu", at: start)
        list.remember(ReceiverAddress(host: "fd00::2", port: 9000), name: "", at: start)

        #expect(list.all.map(\.title) == ["fd00::2", "imac-ubuntu", "Thunderbolt"])
        #expect(list.all.map(\.detail) == ["[fd00::2]:9000", "192.168.8.21:7878", "imac-ubuntu · 10.99.0.1:7878"])
    }

    @Test func namedAreSortedByTitleAndRecentByTime() {
        var list = ReceiverList()
        list.remember(ReceiverAddress(host: "a"), name: "", label: "Wi-Fi", at: start)
        list.remember(ReceiverAddress(host: "b"), name: "", at: start + 1)
        list.remember(ReceiverAddress(host: "c"), name: "", label: "thunderbolt", at: start + 2)
        list.remember(ReceiverAddress(host: "d"), name: "", label: "Ethernet 10", at: start + 3)
        list.remember(ReceiverAddress(host: "e"), name: "", label: "Ethernet 9", at: start + 4)
        list.remember(ReceiverAddress(host: "f"), name: "", at: start + 5)

        #expect(list.named.map(\.title) == ["Ethernet 9", "Ethernet 10", "thunderbolt", "Wi-Fi"])
        #expect(list.recent.map(\.host) == ["f", "b"])
    }

    @Test func onlyUnnamedReceiversAreCapped() {
        var list = ReceiverList()
        for index in 0..<15 {
            list.remember(ReceiverAddress(host: "named-\(index)"), name: "", label: "N\(index)", at: start)
        }
        for index in 0..<(ReceiverList.maxUnnamed + 3) {
            list.remember(ReceiverAddress(host: "host-\(index)"), name: "", at: start + Double(index))
        }

        #expect(list.named.count == 15)
        #expect(list.recent.count == ReceiverList.maxUnnamed)
        #expect(list.recent.first?.host == "host-\(ReceiverList.maxUnnamed + 2)")
        #expect(!list.recent.contains { $0.host == "host-2" })
    }

    @Test func renameSetsClearsAndRecapsTheList() {
        var list = ReceiverList()
        list.remember(thunderbolt, name: "imac-ubuntu", label: "Thunderbolt", at: start)
        for index in 0..<ReceiverList.maxUnnamed {
            list.remember(ReceiverAddress(host: "host-\(index)"), name: "", at: start + 1 + Double(index))
        }

        list.rename(thunderbolt.description, to: " TB ")
        #expect(list.named.map(\.title) == ["TB"])

        // Unnamed again it is the oldest of 11, so the cap drops it.
        list.rename(thunderbolt.description, to: "")
        #expect(list.named.isEmpty)
        #expect(list.all.count == ReceiverList.maxUnnamed)
        #expect(!list.all.contains { $0.address == thunderbolt })

        list.rename("not-there:1", to: "x")
        #expect(list.named.isEmpty)
    }

    @Test func forget() {
        var list = ReceiverList()
        list.remember(thunderbolt, name: "", label: "Thunderbolt", at: start)
        list.remember(lan, name: "", at: start + 1)
        list.forget(thunderbolt.description)
        #expect(list.all.map(\.address) == [lan])
    }

    @Test func listsSavedBeforeNamesStillLoad() throws {
        // Shape written by earlier versions: no "label" key.
        let json = Data("""
        [{"host":"192.168.8.21","port":7878,"name":"imac-ubuntu","lastConnected":800000000},
         {"host":"10.99.0.1","port":7878,"name":"imac-ubuntu","lastConnected":800000100}]
        """.utf8)
        let list = ReceiverList(try JSONDecoder().decode([SavedReceiver].self, from: json))

        #expect(list.all.map(\.host) == ["10.99.0.1", "192.168.8.21"])
        #expect(list.named.isEmpty)
        #expect(list.recent.count == 2)
    }

    @Test func loadingCleansDuplicatesBlankLabelsAndTheCap() {
        var stored = [
            SavedReceiver(host: "10.99.0.1", port: 7878, name: "old", label: "Thunderbolt", lastConnected: start),
            SavedReceiver(host: "10.99.0.1", port: 7878, name: "new", label: nil, lastConnected: start + 1),
            SavedReceiver(host: "blank", port: 7878, name: "", label: "  ", lastConnected: start),
        ]
        for index in 0..<(ReceiverList.maxUnnamed + 2) {
            stored.append(SavedReceiver(host: "host-\(index)", port: 7878, name: "", lastConnected: start + 10 + Double(index)))
        }
        let list = ReceiverList(stored)

        #expect(list.named.map(\.title) == ["Thunderbolt"])
        #expect(list.named.first?.name == "new")
        #expect(list.recent.count == ReceiverList.maxUnnamed)
        #expect(!list.all.contains { $0.host == "blank" })
    }
}
