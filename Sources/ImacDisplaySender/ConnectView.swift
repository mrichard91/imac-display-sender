import IDPCore
import IDPProtocol
import SwiftUI

/// Host, port and optional name entry, and the saved and recent receivers.
struct ConnectView: View {
    @ObservedObject var preferences: Preferences
    /// The address and the name typed for it (nil when left blank).
    let onConnect: (ReceiverAddress, String?) -> Void
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
            TextField("Name (optional), e.g. Thunderbolt", text: $form.label)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
                .help("Shown in the Connect menu once the receiver answers")

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Connect", action: submit)
                    // Not while renaming a row: Return there saves the name.
                    .keyboardShortcut(form.renaming == nil ? .defaultAction : nil)
                    .disabled(form.address == nil)
            }

            let receivers = preferences.receivers
            ReceiverSection(title: "Saved", receivers: receivers.named, preferences: preferences, form: form,
                            onConnect: { onConnect($0, nil) })
            ReceiverSection(title: "Recent", receivers: receivers.recent, preferences: preferences, form: form,
                            onConnect: { onConnect($0, nil) })
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
        // Blank means "no new name", never "remove the name".
        let label = form.label.trimmingCharacters(in: .whitespacesAndNewlines)
        onConnect(address, label.isEmpty ? nil : label)
    }
}

/// Text field contents. A model object rather than `@State`, which is a
/// SwiftUI macro in recent SDKs whose plugin ships only with Xcode.
@MainActor
private final class ConnectForm: ObservableObject {
    @Published var host = ""
    @Published var port = String(defaultPort)
    @Published var label = ""
    /// The row being renamed, and its text field.
    @Published var renaming: SavedReceiver.ID?
    @Published var renameText = ""

    var address: ReceiverAddress? {
        guard let portNumber = UInt16(port.trimmingCharacters(in: .whitespaces)), portNumber > 0 else { return nil }
        return ReceiverAddress.parse(host, defaultPort: portNumber)
    }
}

private struct ReceiverSection: View {
    let title: String
    let receivers: [SavedReceiver]
    @ObservedObject var preferences: Preferences
    @ObservedObject var form: ConnectForm
    let onConnect: (ReceiverAddress) -> Void

    var body: some View {
        if !receivers.isEmpty {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            ForEach(receivers) { receiver in
                if form.renaming == receiver.id {
                    RenameRow(form: form, onDone: commitRename, onCancel: { form.renaming = nil })
                } else {
                    ReceiverRow(receiver: receiver,
                                onConnect: {
                                    commitRename()
                                    onConnect(receiver.address)
                                },
                                onRename: {
                                    // Like Finder: moving to another row keeps what was typed.
                                    commitRename()
                                    form.renameText = receiver.label ?? ""
                                    form.renaming = receiver.id
                                },
                                onForget: {
                                    commitRename()
                                    preferences.forget(receiver)
                                })
                }
            }
        }
    }
}

extension ReceiverSection {
    /// Saves the row being renamed, if any.
    private func commitRename() {
        guard let id = form.renaming else { return }
        preferences.rename(id, to: form.renameText)
        form.renaming = nil
    }
}

private struct ReceiverRow: View {
    let receiver: SavedReceiver
    let onConnect: () -> Void
    let onRename: () -> Void
    let onForget: () -> Void

    var body: some View {
        HStack {
            Button(action: onConnect) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(receiver.title)
                    Text(receiver.detail).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button(action: onRename) {
                Image(systemName: "pencil.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(receiver.isNamed ? "Rename" : "Name this receiver")
            Button(action: onForget) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Forget this receiver")
        }
        .padding(.vertical, 2)
    }
}

/// Inline name editor: Return saves, Escape cancels, an empty name removes it.
private struct RenameRow: View {
    @ObservedObject var form: ConnectForm
    let onDone: () -> Void
    let onCancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack {
            TextField("Name, e.g. Thunderbolt", text: $form.renameText)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(onDone)
                .onExitCommand(perform: onCancel)
            Button("Save", action: onDone)
        }
        .onAppear { focused = true }
    }
}
