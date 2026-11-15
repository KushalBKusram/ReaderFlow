import SwiftUI
#if !READERFLOW_APP
import ReaderFlowAudioPlayback
import ReaderFlowEpisodeLibrary
#endif

struct LibraryView: View {
    let model: LibraryViewModel
    @State private var selection: Episode.ID?
    @State private var showingStudio = false
    @State private var pendingDeletion: Episode?
    @State private var showingPrivacySettings = false
    @State private var showingHosts = false
    @State private var showingRaindropSettings = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 8) {
                    ReaderFlowLogo(size: 26)
                    Text("ReaderFlow").font(.headline)
                    Spacer()
                    Button { showingHosts = true } label: {
                        Image(systemName: "person.2")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Meet the hosts")
                    Button { showingRaindropSettings = true } label: {
                        Image(systemName: "link")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Raindrop")
                    Button { showingPrivacySettings = true } label: {
                        Image(systemName: "lock.shield")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Privacy & local usage log")
                }
                Button { showingStudio = true } label: {
                    Label("Create episode", systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }
                .readerFlowProminentButtonStyle()
                .controlSize(.large)

                if let pending = model.pendingRender {
                    PendingRenderRow(pending: pending)
                }

                HStack {
                    Text("LIBRARY").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(model.episodes.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }

                if model.episodes.isEmpty {
                    Spacer()
                    ContentUnavailableView("No episodes yet", systemImage: "headphones", description: Text("Turn an article into something worth listening to."))
                    Spacer()
                } else {
                    List(model.episodes, selection: $selection) { episode in
                        EpisodeRow(episode: episode)
                            .tag(episode.id)
                            .contextMenu {
                                Button("Delete Episode", systemImage: "trash", role: .destructive) { pendingDeletion = episode }
                            }
                    }
                    .listStyle(.sidebar)
                    .onDeleteCommand { if let episode = selectedEpisode { pendingDeletion = episode } }
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 16)
            .padding(.top, 36)
            .readerFlowSidebarSurface()
            .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 360)
        } detail: {
            Group {
                if let episode = selectedEpisode {
                    EpisodeDetailView(episode: episode, player: model.player, loadScript: { await model.scriptText(for: episode) })
                } else {
                    WelcomeView(onCreate: { showingStudio = true })
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let nowPlaying = nowPlayingEpisode, let player = model.player {
                    MiniPlayerBar(episode: nowPlaying, player: player) { selection = nowPlaying.id }
                        .padding(.horizontal, 14).padding(.bottom, 12).padding(.top, 6)
                }
            }
        }
        .tint(.indigo)
        .alert("Episode Library", isPresented: Binding(get: { model.loadError != nil }, set: { if !$0 { model.dismissError() } })) {
            Button("OK") { model.dismissError() }
        } message: { Text(model.loadError ?? "") }
        .confirmationDialog(
            "Delete “\(pendingDeletion?.title ?? "")”?",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            presenting: pendingDeletion
        ) { episode in
            Button("Delete Episode", role: .destructive) { Task { await model.delete(episode) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This removes the episode and its local audio from this Mac. This can’t be undone.")
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { Task { await model.persistPlaybackPosition() } } }
        .onDisappear { Task { await model.persistPlaybackPosition() } }
        .sheet(isPresented: $showingStudio) { StudioView(model: model, isPresented: $showingStudio) }
        .sheet(isPresented: $showingPrivacySettings) { PrivacySettingsView(model: model, isPresented: $showingPrivacySettings) }
        .sheet(isPresented: $showingHosts) { HostsView(model: model, isPresented: $showingHosts) }
        .sheet(isPresented: $showingRaindropSettings) { RaindropSettingsView(isPresented: $showingRaindropSettings) }
    }

    private var selectedEpisode: Episode? {
        model.episodes.first(where: { $0.id == selection }) ?? model.episodes.first
    }

    /// The episode actually loaded in the player, independent of which
    /// episode is selected in the sidebar — so switching selection while
    /// something plays doesn't make the transport controls lie about it.
    private var nowPlayingEpisode: Episode? {
        guard let id = model.player?.episodeID else { return nil }
        return model.episodes.first(where: { $0.id == id })
    }
}

struct ReaderFlowLogo: View {
    let size: CGFloat

    var body: some View {
        Group {
            if let url = Bundle.main.url(forResource: "ReaderFlowLogo", withExtension: "png"),
               let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: "waveform.path.ecg.rectangle.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.white)
                    .padding(size * 0.23)
                    .background(Color.indigo.gradient, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            }
        }
        .saturation(0.82)
        .brightness(-0.025)
        .frame(width: size, height: size)
        .accessibilityLabel("ReaderFlow")
    }
}

struct EpisodeRow: View {
    let episode: Episode

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "waveform")
                .font(.caption.weight(.bold))
                .foregroundStyle(.indigo)
                .frame(width: 30, height: 30)
                .background(.indigo.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(episode.title).lineLimit(1).font(.subheadline.weight(.semibold))
                Text("\((episode.audioDuration ?? 0).readerFlowMinutesLabel) · Local")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
    }

}

struct PendingRenderRow: View {
    let pending: PendingRender

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        rowContent
            .modifier(GlassPillBackground(shape: shape, tint: .indigo.opacity(0.1)))
    }

    private var rowContent: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 1) {
                Text(pending.title).font(.caption.weight(.semibold)).lineLimit(1)
                Text(pending.stage.userMessage).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
    }
}

struct WelcomeView: View {
    let onCreate: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "headphones.circle.fill")
                .font(.system(size: 76)).foregroundStyle(.indigo.gradient)
                .padding(16)
                .background(.regularMaterial, in: Circle())
            VStack(spacing: 8) {
                Text("Articles, made listenable.").font(.largeTitle.weight(.semibold))
                Text("ReaderFlow creates private, local episodes from the stories you choose.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 440)
            }
            Button("Create your first episode", systemImage: "arrow.right") { onCreate() }
                .buttonStyle(.borderedProminent).controlSize(.large)
            HStack(spacing: 18) {
                Label("Public URL", systemImage: "link")
                Label("Local processing", systemImage: "lock")
                Label("Yours to keep", systemImage: "arrow.down.circle")
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
