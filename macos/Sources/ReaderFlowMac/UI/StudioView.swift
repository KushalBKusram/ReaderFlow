import SwiftUI
#if !READERFLOW_APP
import ReaderFlowAudioPlayback
import ReaderFlowEpisodeLibrary
#endif

struct StudioView: View {
    let model: LibraryViewModel
    @Binding var isPresented: Bool
    @FocusState private var articleIsFocused: Bool
    @State private var isScriptExpanded = false
    @State private var showingLocalAISetup = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Make an episode").font(.system(size: 34, weight: .bold, design: .rounded))
                        Text("Paste a public article link, then turn it into a conversation.")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.bottom, 4)

                    studioCard(number: 1, title: "Bring an article") {
                        TextField("Title (auto-filled from the article)", text: Bindable(model).studioTitle)
                            .textFieldStyle(.roundedBorder)
                        HStack(alignment: .top, spacing: 8) {
                            TextField("Paste a public article URL, or the article text", text: Bindable(model).sourceText, axis: .vertical)
                                .textFieldStyle(.roundedBorder)
                                .lineLimit(1 ... 5)
                                .focused($articleIsFocused).onAppear { articleIsFocused = true }
                            Button(model.isImportingPDF ? "Reading…" : "Import PDF…", systemImage: "doc.richtext") { model.importPDF() }
                                .buttonStyle(.bordered)
                                .disabled(model.isImportingPDF)
                        }
                        Text("No browser cookies or sign-in, and no bypassing access restrictions. A long PDF is summarized section by section first, so the episode still covers the whole document.")
                            .font(.caption).foregroundStyle(.secondary)
                        Picker("Listening depth", selection: Bindable(model).detailLevel) {
                            ForEach(EpisodeDetailLevel.allCases) { level in
                                Text(level.title).tag(level)
                            }
                        }
                        .pickerStyle(.segmented)
                        Text(model.detailLevel.explanation)
                            .font(.caption).foregroundStyle(.secondary)
                        Picker("Content style", selection: Bindable(model).contentStyle) {
                            ForEach(EpisodeContentStyle.allCases) { style in
                                Text(style.title).tag(style)
                            }
                        }
                        .pickerStyle(.segmented)
                        Text(model.contentStyle.explanation)
                            .font(.caption).foregroundStyle(.secondary)
                        if !model.localAI.isReady { localAISetupPrompt }
                        Button(model.isGenerating ? "Creating draft…" : "Create draft", systemImage: "sparkles") { Task { await model.createDraft() } }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                            .disabled(model.isGenerating || model.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.localAI.isReady)
                    }

                    if !model.draftScript.isEmpty {
                        studioCard(number: 2, title: "Review & listen") {
                            DisclosureGroup("Review script (\(scriptWordCount) words)", isExpanded: $isScriptExpanded) {
                                TextEditor(text: Bindable(model).draftScript)
                                    .font(.body).frame(minHeight: 220)
                                    .padding(6).background(.background, in: RoundedRectangle(cornerRadius: 10))
                                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
                                    .padding(.top, 8)
                            }
                            Text("Optional: edit anything before it becomes audio. ReaderFlow uses Qwen and Kokoro locally; no Apple Foundation Models or API key.")
                                .font(.caption).foregroundStyle(.secondary)
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Local audio preview").font(.headline)
                                    Text("Two distinct Kokoro hosts, rendered privately on this Mac.").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Render audio", systemImage: "waveform") {
                                    model.startRendering()
                                    isPresented = false
                                }
                                    .buttonStyle(.borderedProminent).controlSize(.large)
                                    .disabled(model.pendingRender != nil || model.draftScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.localAI.isReady)
                            }
                        }
                    }

                    if let message = model.studioMessage {
                        Label(message, systemImage: "checkmark.circle").foregroundStyle(.secondary).padding(.horizontal, 4)
                    }
                }
                .padding(32).frame(maxWidth: 820, alignment: .leading)
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .navigationTitle("New episode")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { isPresented = false } } }
            .sheet(isPresented: $showingLocalAISetup) { LocalAISetupSheet(localAI: model.localAI, isPresented: $showingLocalAISetup) }
        }
        .frame(minWidth: 760, minHeight: 760)
    }

    private var scriptWordCount: Int {
        model.draftScript.split { $0.isWhitespace || $0.isNewline }.count
    }

    private var localAISetupPrompt: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle").foregroundStyle(.indigo)
            Text(model.localAI.isInstalling ? "Downloading local AI…" : "Local AI setup needed before creating episodes.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button(model.localAI.isInstalling ? "View progress" : "Set up") { showingLocalAISetup = true }
                .buttonStyle(.bordered).controlSize(.small)
        }
        .padding(10)
        .background(.indigo.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func studioCard<Content: View>(number: Int, title: String, @ViewBuilder content: () -> Content) -> some View {
        ReaderFlowGlassSurface(tint: .indigo.opacity(0.08)) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Text("\(number)").font(.caption.weight(.bold)).foregroundStyle(.white).frame(width: 26, height: 26).background(.indigo.gradient, in: Circle())
                    Text(title).font(.title3.weight(.semibold))
                }
                content()
            }
        }
    }
}

struct LocalAISetupSheet: View {
    let localAI: LocalAISetup
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Local AI setup", systemImage: "arrow.down.circle")
                .font(.title2.weight(.semibold))
            Text(localAI.generationStatus)
                .font(.callout).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                modelState(name: "Qwen — writes the conversation", state: localAI.qwenState)
                modelState(name: "Kokoro — renders the voices", state: localAI.kokoroState)
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Close") { isPresented = false }
                Button(localAI.isInstalling ? "Downloading…" : "Download local AI") {
                    Task { await localAI.installRecommendedModels() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(localAI.isInstalling || localAI.isReady)
            }
        }
        .padding(28)
        .frame(minWidth: 440, minHeight: 260)
        .onChange(of: localAI.isReady) { _, ready in if ready { isPresented = false } }
    }

    @ViewBuilder
    private func modelState(name: String, state: LocalAISetup.InstallState) -> some View {
        switch state {
        case .ready: Label(name, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .checking: Label("\(name) — checking…", systemImage: "clock")
        case .notInstalled: Label("\(name) — not installed", systemImage: "arrow.down.circle")
        case .downloading(_, let completed, let total): Label("\(name) — \(progressText(completed, total))", systemImage: "arrow.down.circle")
        case .failed: Label("\(name) — retry", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        }
    }

    private func progressText(_ completed: Int64, _ total: Int64?) -> String {
        guard completed > 0 else { return "downloading…" }
        guard let total, total > 0 else { return "downloading…" }
        return "\(Int((Double(completed) / Double(total) * 100).rounded()))%"
    }
}
