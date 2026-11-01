import IDPCore
import IDPProtocol
import SwiftUI

/// Host + port entry and the recent receivers list.
struct ConnectView: View {
    @ObservedObject var preferences: Preferences
    let onConnect: (ReceiverAddress) -> Void
    let onCancel: () -> Void

    @StateObject private var form = ConnectForm()
    @FocusState private var hostFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connect to receiver").font(.headline)
            HStack {
                TextField("Host or IP, e.g. 10.99.0.2", text: $form.host)
                    .focused($hostFocused)
                    .onSubmit(submit)
                TextField("Port", text: $form.port)
                    .frame(width: 60)
                    .onSubmit(submit)
            }
            .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Connect", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(form.address == nil)
            }

            if !preferences.recentReceivers.isEmpty {
                Text("Recent").font(.subheadline).foregroundStyle(.secondary)
                ForEach(preferences.recentReceivers) { receiver in
                    RecentRow(receiver: receiver,
                              onConnect: { onConnect(receiver.address) },
                              onForget: { preferences.forget(receiver) })
                }
            }
        }
        .onAppear {
            if form.host.isEmpty, let last = preferences.lastReceiver {
                form.host = last.host
                form.port = String(last.port)
            }
            hostFocused = true
        }
    }

    private func submit() {
        guard let address = form.address else { return }
        onConnect(address)
    }
}

/// Text field contents. A model object rather than `@State`, which is a
/// SwiftUI macro in recent SDKs whose plugin ships only with Xcode.
@MainActor
private final class ConnectForm: ObservableObject {
    @Published var host = ""
    @Published var port = String(defaultPort)

    var address: ReceiverAddress? {
        guard let portNumber = UInt16(port.trimmingCharacters(in: .whitespaces)), portNumber > 0 else { return nil }
        return ReceiverAddress.parse(host, defaultPort: portNumber)
    }
}

private struct RecentRow: View {
    let receiver: RecentReceiver
    let onConnect: () -> Void
    let onForget: () -> Void

    var body: some View {
        HStack {
            Button(action: onConnect) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(receiver.name.isEmpty ? receiver.host : receiver.name)
                    Text(receiver.address.description).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button(action: onForget) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Forget this receiver")
        }
        .padding(.vertical, 2)
    }
}
