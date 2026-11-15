import SwiftUI
#if !READERFLOW_APP
import ReaderFlowAudioPlayback
import ReaderFlowEpisodeLibrary
#endif

/// Shows who the two hosts currently are — the same identities that shaped
/// the most recent episode and that continue to evolve, one small detail at
/// a time, from whatever gets narrated next.
struct HostsView: View {
    let model: LibraryViewModel
    @Binding var isPresented: Bool
    @State private var personas: HostPersonaProfile?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Meet the hosts", systemImage: "person.2")
                .font(.title2.weight(.semibold))
            Text("ReaderFlow's two hosts carry a personality across episodes. It evolves gradually — at most one small detail per episode — based on what they've narrated, and never resets.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let personas {
                hostCard(personas.hostA)
                hostCard(personas.hostB)
                Text("\(personas.episodeCount) episode\(personas.episodeCount == 1 ? "" : "s") have shaped who they are.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Done") { isPresented = false }.buttonStyle(.borderedProminent)
            }
        }
        .padding(28)
        .frame(minWidth: 440, minHeight: 340)
        .task { personas = await model.currentHostPersonas() }
    }

    private func hostCard(_ persona: HostPersona) -> some View {
        ReaderFlowGlassSurface(tint: .indigo.opacity(0.08)) {
            VStack(alignment: .leading, spacing: 4) {
                Text(persona.name).font(.headline)
                Text(persona.voice).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Lets the pilot user opt in to (or out of, or clear) the local dogfood
/// usage log. Off by default; nothing is ever written until this is on, and
/// nothing here ever leaves this Mac.
struct PrivacySettingsView: View {
    let model: LibraryViewModel
    @Binding var isPresented: Bool
    @State private var isEnabled = DogfoodMetricsSettings.isEnabled
    @State private var eventCount = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Privacy & local usage log", systemImage: "lock.shield")
                .font(.title2.weight(.semibold))
            Text("ReaderFlow can keep a local log of usage events — episodes created, playback started or finished, and failures — to help judge the local-first pilot. It never records article content, scripts, or titles, and nothing is ever sent off this Mac.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("Keep a local usage log", isOn: $isEnabled)
                .onChange(of: isEnabled) { _, newValue in DogfoodMetricsSettings.isEnabled = newValue }
            HStack {
                Text("\(eventCount) event\(eventCount == 1 ? "" : "s") logged on this Mac")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Clear Log", role: .destructive) {
                    Task { await model.clearMetricsLog(); eventCount = await model.metricsEventCount() }
                }
                .disabled(eventCount == 0)
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Done") { isPresented = false }.buttonStyle(.borderedProminent)
            }
        }
        .padding(28)
        .frame(minWidth: 440, minHeight: 260)
        .task { eventCount = await model.metricsEventCount() }
    }
}

/// Connects a Raindrop account once the user has registered ReaderFlow at
/// raindrop.io and deployed the token relay in `relay/` — see that
/// directory's README. Entering a client ID and relay URL is a one-time
/// setup step; this is the feasibility-gate UI for Raindrop OAuth, not a
/// claim that the gate itself is closed (that still needs one real sign-in
/// against a registered app — see docs/findings.md).
struct RaindropSettingsView: View {
    @Binding var isPresented: Bool
    @StateObject private var manager = RaindropConnectionManager()
    @State private var clientID = RaindropConnectionSettings.clientID
    @State private var relayBaseURLString = RaindropConnectionSettings.relayBaseURLString
    @State private var secretInput = ""
    @State private var selectedCollectionID = RaindropConnectionSettings.selectedCollectionID

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Raindrop", systemImage: "link")
                .font(.title2.weight(.semibold))
            Text("ReaderFlow signs in to Raindrop in your browser. The client ID is not secret. Personal mode: paste your own app's client secret below and it is kept in this Mac's Keychain only. For a build you give to other people, leave it empty and use a relay URL instead, so the secret never ships in the app.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                TextField("Raindrop client ID", text: $clientID)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: clientID) { _, newValue in
                        RaindropConnectionSettings.clientID = newValue
                        manager.refreshState()
                    }
                if manager.hasStoredSecret {
                    HStack {
                        Label("Personal-mode client secret stored in Keychain", systemImage: "key.fill")
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("Remove", role: .destructive) { manager.clearClientSecret() }
                    }
                } else {
                    HStack {
                        SecureField("Client secret (personal mode)", text: $secretInput)
                            .textFieldStyle(.roundedBorder)
                        Button("Save") {
                            manager.saveClientSecret(secretInput)
                            secretInput = ""
                        }
                        .disabled(secretInput.isEmpty)
                    }
                    TextField("Relay URL (https://…), if not using personal mode", text: $relayBaseURLString)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: relayBaseURLString) { _, newValue in
                            RaindropConnectionSettings.relayBaseURLString = newValue
                            manager.refreshState()
                        }
                }
            }

            connectionStatus

            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Done") { isPresented = false }.buttonStyle(.borderedProminent)
            }
        }
        .padding(28)
        .frame(minWidth: 460, minHeight: 360)
        .task { await manager.reloadCollections() }
    }

    @ViewBuilder
    private var connectionStatus: some View {
        switch manager.state {
        case .notConfigured:
            Text("Enter a client ID and either your client secret or a relay URL to connect.")
                .font(.caption).foregroundStyle(.secondary)
        case .disconnected:
            Button("Connect Raindrop") { Task { await manager.connect() } }
        case .connecting:
            HStack { ProgressView().controlSize(.small); Text("Opening Raindrop sign-in…") }
                .font(.callout).foregroundStyle(.secondary)
        case .connected(let collections):
            HStack {
                Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Spacer()
                Button("Disconnect", role: .destructive) { manager.disconnect() }
            }
            if !collections.isEmpty {
                Picker("Collection", selection: $selectedCollectionID) {
                    Text("None selected").tag(Int?.none)
                    ForEach(collections) { Text($0.title).tag(Int?.some($0.id)) }
                }
                .onChange(of: selectedCollectionID) { _, newValue in
                    RaindropConnectionSettings.selectedCollectionID = newValue
                }
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Text(message).font(.callout).foregroundStyle(.red)
                Button("Try Again") { Task { await manager.connect() } }
            }
        }
    }
}
