import SwiftUI
#if !READERFLOW_APP
import ReaderFlowAudioPlayback
import ReaderFlowEpisodeLibrary
#endif

/// Pinned to the bottom of the whole window, outside the scrollable detail
/// content and independent of sidebar selection, so what's actually playing
/// stays visible while scrolling or browsing other episodes.
struct MiniPlayerBar: View {
    let episode: Episode
    let player: EpisodePlayer
    let onSelect: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        barContent
            .modifier(GlassPillBackground(shape: shape, tint: .indigo.opacity(0.06)))
            .shadow(color: .black.opacity(0.16), radius: 18, y: 6)
    }

    private var barContent: some View {
        HStack(spacing: 16) {
            Button(action: onSelect) {
                HStack(spacing: 9) {
                    Image(systemName: "waveform")
                        .font(.caption.weight(.bold)).foregroundStyle(.indigo)
                        .frame(width: 30, height: 30)
                        .background(.indigo.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(episode.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(player.isPlaying ? "Now playing" : "Paused").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
            .frame(maxWidth: 220, alignment: .leading)

            Spacer(minLength: 8)

            HStack(spacing: 18) {
                Button { Task { await player.skip(by: -15) } } label: {
                    Image(systemName: "gobackward.15")
                }
                .buttonStyle(.borderless)
                Button { Task { if player.isPlaying { await player.pause() } else { await player.play(episode) } } } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.borderedProminent).clipShape(Circle())
                Button { Task { await player.skip(by: 30) } } label: {
                    Image(systemName: "goforward.30")
                }
                .buttonStyle(.borderless)
            }

            Text(player.elapsed.readerFlowClockLabel).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            Slider(value: Binding(get: { player.elapsed }, set: { value in Task { await player.seek(to: value) } }), in: 0 ... max(player.duration, 1))
                .tint(.indigo).disabled(player.duration == 0)
                .frame(minWidth: 140, maxWidth: 320)
            Text("−\(max(0, player.duration - player.elapsed).readerFlowClockLabel)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

}

struct EpisodeDetailView: View {
    let episode: Episode
    let player: EpisodePlayer?
    let loadScript: () async -> String?
    @State private var scriptText: String?
    @State private var isScriptExpanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .top, spacing: 18) {
                    Image(systemName: "waveform")
                        .font(.system(size: 34, weight: .medium)).foregroundStyle(.white)
                        .frame(width: 82, height: 82).background(.indigo.gradient, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    VStack(alignment: .leading, spacing: 7) {
                        Text(episode.title).font(.system(size: 36, weight: .bold, design: .rounded)).fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            Label((episode.audioDuration ?? 0).readerFlowClockLabel, systemImage: "clock")
                            Text("Created \(episode.createdAt.formatted(date: .abbreviated, time: .shortened))")
                            Text("Private to this Mac")
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
                status
                if let player {
                    if player.episodeID == episode.id { playbackControls(player) }
                    else { playPrompt(player) }
                }
                scriptSection
                Divider()
                Label("Stored only on this Mac", systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 48).padding(.vertical, 44).frame(maxWidth: 960, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: episode.id) { scriptText = await loadScript() }
    }

    @ViewBuilder private var scriptSection: some View {
        ReaderFlowGlassSurface(tint: .indigo.opacity(0.08)) {
            DisclosureGroup(isExpanded: $isScriptExpanded) {
                Group {
                    if let scriptText {
                        ScrollView {
                            Text(scriptText)
                                .font(.body).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 320)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(.top, 8)
            } label: {
                Label("Episode script", systemImage: "text.alignleft").font(.headline)
            }
        }
    }

    // Only surfaces something when there's a problem to flag — the healthy
    // state is already conveyed by the play/transport card below, so a
    // "Ready to listen" line here would just repeat it.
    @ViewBuilder private var status: some View {
        if let error = episode.recoveryError { Label(error.message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
        else if player?.episodeID == episode.id, case .unavailable(let message) = player?.state { Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
    }

    /// Shown for an episode that isn't the one currently loaded in the
    /// player, so its duration isn't confused with another episode's live
    /// elapsed/remaining time.
    private func playPrompt(_ player: EpisodePlayer) -> some View {
        let unavailable = episode.lifecycle != .ready
        return ReaderFlowGlassSurface(tint: .indigo.opacity(0.08)) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Ready to listen").font(.headline)
                    Text((episode.audioDuration ?? 0).readerFlowClockLabel).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { Task { await player.play(episode) } } label: {
                    Label("Play", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(unavailable)
            }
        }
    }

    private func playbackControls(_ player: EpisodePlayer) -> some View {
        let unavailable: Bool
        if case .unavailable = player.state { unavailable = true } else { unavailable = episode.lifecycle != .ready }
        return ReaderFlowGlassSurface(tint: .indigo.opacity(0.08)) {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Label(player.isPlaying ? "Now playing" : "Ready to listen", systemImage: player.isPlaying ? "waveform" : "play.circle")
                        .font(.headline)
                    Spacer()
                    Menu {
                        Picker("Playback speed", selection: Binding(get: { player.playbackRate }, set: { player.setPlaybackRate($0) })) {
                            Text("1×").tag(Float(1)); Text("1.25×").tag(Float(1.25)); Text("1.5×").tag(Float(1.5)); Text("2×").tag(Float(2))
                        }
                    } label: {
                        Text(speedLabel(player.playbackRate))
                            .font(.subheadline.weight(.semibold))
                            .frame(minWidth: 38)
                    }
                    .menuStyle(.borderedButton)
                    .disabled(unavailable)
                }
                VStack(spacing: 16) {
                    HStack(spacing: 22) {
                        Button { Task { await player.skip(by: -15) } } label: {
                            Image(systemName: "gobackward.15").frame(width: 32, height: 32)
                        }
                        .buttonStyle(.borderless).disabled(unavailable)
                        Button { Task { if player.isPlaying { await player.pause() } else { await player.play(episode) } } } label: {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title3).frame(width: 48, height: 48)
                        }
                        .buttonStyle(.borderedProminent).clipShape(Circle()).disabled(unavailable)
                        Button { Task { await player.skip(by: 30) } } label: {
                            Image(systemName: "goforward.30").frame(width: 32, height: 32)
                        }
                        .buttonStyle(.borderless).disabled(unavailable)
                    }
                    VStack(spacing: 6) {
                        Slider(value: Binding(get: { player.elapsed }, set: { value in Task { await player.seek(to: value) } }), in: 0...max(player.duration, 1))
                            .tint(.indigo).disabled(unavailable || player.duration == 0)
                        HStack { Text(player.elapsed.readerFlowClockLabel); Spacer(); Text("−\(max(0, player.duration - player.elapsed).readerFlowClockLabel)") }
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: 460)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func speedLabel(_ rate: Float) -> String { rate == 1 ? "1×" : "\(rate.formatted())×" }
}
