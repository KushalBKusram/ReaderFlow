import SwiftUI

enum ReaderFlowPalette {
    static let ink = Color(red: 0.06, green: 0.08, blue: 0.13)
    static let canvas = Color(red: 0.95, green: 0.94, blue: 0.91)
    static let accent = Color(red: 0.92, green: 0.25, blue: 0.17)
    static let moss = Color(red: 0.19, green: 0.34, blue: 0.29)
}

struct ReaderFlowRootView: View {
    @EnvironmentObject private var model: ReaderFlowAppModel

    var body: some View {
        TabView(selection: $model.selectedTab) {
            ListenHomeView()
                .tabItem { Label("Listen", systemImage: "headphones") }
                .tag(0)
            StudioView()
                .tabItem { Label("Create", systemImage: "sparkles") }
                .tag(1)
            LibraryView()
                .tabItem { Label("Library", systemImage: "rectangle.stack") }
                .tag(2)
            NearbySyncReceiverView()
                .tabItem { Label("Sync", systemImage: "wifi") }
                .tag(3)
        }
        .toolbarBackground(ReaderFlowPalette.canvas, for: .tabBar)
    }
}

private struct ListenHomeView: View {
    @EnvironmentObject private var model: ReaderFlowAppModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    if let episode = model.selectedEpisode { nowPlaying(episode) }
                    connectionCard
                    Text("Your queue").font(.title2.bold())
                    if model.episodes.isEmpty {
                        ContentUnavailableView {
                            Label("Ready for your first episode", systemImage: "headphones")
                        } description: {
                            Text("Create a script on this iPhone, or pair a desktop later to receive private, offline episodes.")
                        } actions: {
                            Button("Create an episode") { model.selectedTab = 1 }
                                .buttonStyle(.borderedProminent)
                                .tint(ReaderFlowPalette.accent)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 18)
                    } else {
                        ForEach(model.episodes) { episode in episodeRow(episode) }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 28)
            }
            .background(ReaderFlowPalette.canvas.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("GOOD MORNING").font(.caption.weight(.bold)).tracking(1.4).foregroundStyle(ReaderFlowPalette.accent)
                Text("Make room to think.").font(.largeTitle.bold()).foregroundStyle(ReaderFlowPalette.ink)
            }
            Spacer()
            Image(systemName: "waveform.circle.fill").font(.system(size: 34)).foregroundStyle(ReaderFlowPalette.moss)
        }
    }

    private func nowPlaying(_ episode: ListenerEpisode) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                coverArt
                VStack(alignment: .leading, spacing: 8) {
                    Text("NOW LISTENING").font(.caption2.weight(.bold)).tracking(1).foregroundStyle(.white.opacity(0.7))
                    Text(episode.title).font(.title2.bold()).foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
                    Text(episode.source).font(.subheadline).foregroundStyle(.white.opacity(0.78))
                }
            }
            ProgressView(value: episode.progress).tint(.white)
            HStack {
                Text(time(episode.duration * episode.progress)).monospacedDigit()
                Spacer()
                Text("−\(time(episode.duration * (1 - episode.progress)))").monospacedDigit()
            }
            .font(.caption).foregroundStyle(.white.opacity(0.72))
            Slider(value: Binding(get: { episode.progress }, set: { model.seek(to: $0) }), in: 0...1)
                .tint(.white)
            HStack(spacing: 22) {
                Image(systemName: "gobackward.15").font(.title3)
                Spacer()
                Button(action: { model.togglePlayback() }) {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2.bold()).frame(width: 56, height: 56).background(.white, in: Circle()).foregroundStyle(ReaderFlowPalette.ink)
                }
                Spacer()
                Image(systemName: "goforward.15").font(.title3)
            }
            .foregroundStyle(.white)
            Picker("Speed", selection: Binding(get: { model.playbackRate }, set: { model.setPlaybackRate($0) })) {
                Text("1×").tag(Float(1))
                Text("1.25×").tag(Float(1.25))
                Text("1.5×").tag(Float(1.5))
                Text("2×").tag(Float(2))
            }
            .pickerStyle(.segmented)
            .tint(.white)
        }
        .padding(22)
        .background(LinearGradient(colors: [ReaderFlowPalette.ink, ReaderFlowPalette.moss], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 30, style: .continuous))
    }

    private var coverArt: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(ReaderFlowPalette.accent)
            Image(systemName: "quote.opening").font(.system(size: 36, weight: .black)).foregroundStyle(.white)
        }
        .frame(width: 88, height: 88)
    }

    private var connectionCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "lock.wifi").font(.title3).foregroundStyle(ReaderFlowPalette.moss)
            VStack(alignment: .leading, spacing: 3) {
                Text("Private listening, by design").font(.subheadline.weight(.semibold))
                Text("Pair a desktop later to receive offline episodes.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16).background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func episodeRow(_ episode: ListenerEpisode) -> some View {
        Button { model.setSelected(episode) } label: {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(ReaderFlowPalette.moss.opacity(0.15)).frame(width: 52, height: 52).overlay(Image(systemName: "waveform").foregroundStyle(ReaderFlowPalette.moss))
                VStack(alignment: .leading, spacing: 4) {
                    Text(episode.title).font(.headline).foregroundStyle(ReaderFlowPalette.ink)
                    Text("\(episode.source) · \(time(episode.duration))").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
            }
        }.buttonStyle(.plain)
    }
}

private struct StudioView: View {
    @EnvironmentObject private var model: ReaderFlowAppModel
    @State private var article = ""
    @State private var showReview = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("A private studio\nfor your reading.").font(.largeTitle.bold()).foregroundStyle(ReaderFlowPalette.ink)
                    Text("Paste a public article link or article text, shape a draft locally, then review it before it becomes an episode.").foregroundStyle(.secondary)
                    availabilityCard
                    TextEditor(text: $article).font(.body).scrollContentBackground(.hidden).frame(minHeight: 190).padding(14).background(.white, in: RoundedRectangle(cornerRadius: 22, style: .continuous)).overlay(alignment: .topLeading) {
                        if article.isEmpty { Text("Paste a public article link or article text…").foregroundStyle(.tertiary).padding(22).allowsHitTesting(false) }
                    }
                    Button { Task { await model.createDraft(from: article) } } label: {
                        Label(model.isGenerating ? "Creating draft…" : "Create local draft", systemImage: "sparkles")
                            .frame(maxWidth: .infinity).padding(.vertical, 16).font(.headline)
                    }
                    .buttonStyle(.borderedProminent).tint(ReaderFlowPalette.accent).disabled(model.isGenerating || article.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button { model.usePastedTextAsScript(article) } label: {
                        Label("Use pasted text as script", systemImage: "doc.badge.plus")
                            .frame(maxWidth: .infinity).padding(.vertical, 12).font(.headline)
                    }
                    .buttonStyle(.bordered)
                    .disabled(article.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Text("Use this if you already have a script, or if Apple Intelligence is unavailable. It stays on this iPhone.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let draft = model.scriptDraft {
                        HStack {
                            Button { showReview = true } label: { Label("Review", systemImage: "doc.text") }.buttonStyle(.bordered)
                            Button { Task { await model.reviseCurrentDraft() } } label: {
                                Label(draft.isRevised ? "Refine again" : "Refine locally", systemImage: "wand.and.stars")
                            }
                            .buttonStyle(.bordered)
                            .disabled(model.isGenerating)
                        }
                        if draft.isRevised {
                            Label("Second-pass edit complete", systemImage: "checkmark.circle.fill")
                                .font(.footnote).foregroundStyle(ReaderFlowPalette.moss)
                        }
                        Button { Task { await model.createAudioEpisode() } } label: {
                            Label(model.isRenderingAudio ? "Rendering audio…" : "Create local audio episode", systemImage: "waveform.badge.plus")
                                .frame(maxWidth: .infinity).padding(.vertical, 14).font(.headline)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(ReaderFlowPalette.moss)
                        .disabled(model.isRenderingAudio)
                    }
                    if let message = model.generationMessage { Text(message).font(.footnote).foregroundStyle(.orange) }
                }.padding(20).padding(.bottom, 24)
            }
            .background(ReaderFlowPalette.canvas.ignoresSafeArea())
            .navigationTitle("Studio")
            .sheet(isPresented: $showReview) { if let draft = model.scriptDraft { ScriptReviewView(draft: draft) } }
        }
    }

    @ViewBuilder private var availabilityCard: some View {
        switch model.generationAvailability {
        case .ready:
            Label("Apple Intelligence is ready on this device.", systemImage: "checkmark.seal.fill").foregroundStyle(ReaderFlowPalette.moss)
        case let .unavailable(message):
            HStack(alignment: .top, spacing: 10) { Image(systemName: "iphone.and.arrow.forward"); Text(message) }
                .font(.footnote).foregroundStyle(.secondary).padding(14).background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

private struct ScriptReviewView: View {
    let draft: ScriptDraft
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: ReaderFlowAppModel

    var body: some View {
        NavigationStack {
            ScrollView { Text(draft.body).font(.body).lineSpacing(5).padding(20).textSelection(.enabled) }
                .navigationTitle(draft.title).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(model.isRenderingAudio ? "Rendering…" : "Create audio") {
                            Task {
                                await model.createAudioEpisode()
                                if model.generationMessage == "Audio is ready in Listen." { dismiss() }
                            }
                        }
                        .disabled(model.isRenderingAudio)
                    }
                }
        }
    }
}

private struct LibraryView: View {
    @EnvironmentObject private var model: ReaderFlowAppModel
    var body: some View {
        NavigationStack {
            Group {
                if model.episodes.isEmpty {
                    ContentUnavailableView {
                        Label("No episodes yet", systemImage: "headphones")
                    } description: {
                        Text("Create an episode on this iPhone, or pair a desktop later.")
                    } actions: {
                        Button("Create an episode") { model.selectedTab = 1 }
                            .buttonStyle(.borderedProminent)
                            .tint(ReaderFlowPalette.accent)
                    }
                } else {
                    List(model.episodes) { episode in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(episode.title).font(.headline)
                            Text(episode.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            Label("Offline when synced", systemImage: "arrow.down.circle").font(.caption2).foregroundStyle(ReaderFlowPalette.moss)
                        }
                        .padding(.vertical, 5)
                        .swipeActions {
                            Button(role: .destructive) { model.delete(episode) } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden).background(ReaderFlowPalette.canvas)
            .navigationTitle("Your library")
        }
    }
}

private func time(_ seconds: TimeInterval) -> String {
    let value = max(0, Int(seconds.rounded()))
    return String(format: "%d:%02d", value / 60, value % 60)
}
