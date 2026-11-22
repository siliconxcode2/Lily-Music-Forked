import SwiftUI
import YTMCore

/// The user's own proxy. Every session takes the one saved as it is made, so a change
/// applies from Lily's next start.
struct ProxySection: View {
    /// Nil while the Keychain is read.
    @State private var saved: (address: String?, pending: Bool)?
    @State private var text = ""
    /// Why the address typed won't do, kept until it is edited.
    @State private var failure = ""

    var body: some View {
        Section {
            TextField("Proxy Address", text: $text, prompt: Text(saved?.address ?? "http://host:port"))
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                // A mistyped address stays to be corrected. Done on an empty field only puts the keyboard
                // away, as the field looks filled in by the saved address: clearing is the Clear button's.
                .onSubmit {
                    guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                    Task { if await save(text) { text = "" } }
                }
            if saved?.address != nil {
                Button("Clear Proxy", role: .destructive) { Task { await save("") } }
            }
        } header: {
            Text("Proxy")
        } footer: {
            Text(failure.isEmpty ? detail : failure)
                .foregroundStyle(failure.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
        }
        .task { saved = await Proxy.saved() }
        .onChange(of: text) { failure = "" }
    }

    private var detail: String {
        switch (saved?.address != nil, saved?.pending ?? false) {
        case (true, false): "Connects through this proxy."
        case (true, true): "Connects through this proxy from Lily's next start."
        case (false, false): "Follows the proxy set in iOS. Enter an http:// or socks5:// address to use another."
        case (false, true): "Follows the proxy set in iOS from Lily's next start."
        }
    }

    private func save(_ address: String) async -> Bool {
        do {
            saved = try await Proxy.save(address)
            failure = ""
            return true
        } catch {
            failure = error.message
            return false
        }
    }
}
