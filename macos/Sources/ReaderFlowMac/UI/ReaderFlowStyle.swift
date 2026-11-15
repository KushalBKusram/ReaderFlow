import SwiftUI
#if !READERFLOW_APP
import ReaderFlowAudioPlayback
import ReaderFlowEpisodeLibrary
#endif

extension TimeInterval {
    /// Coarse label for a library row: "5 min".
    var readerFlowMinutesLabel: String { "\(max(0, Int(rounded())) / 60) min" }

    /// Transport clock label: "5:03".
    var readerFlowClockLabel: String {
        let seconds = max(0, Int(rounded()))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// Shared glass-pill background for compact rows (mini player, pending
/// render) that don't want `ReaderFlowGlassSurface`'s larger card padding.
struct GlassPillBackground: ViewModifier {
    let shape: RoundedRectangle
    var tint: Color = .clear

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.tint(tint), in: shape)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(.white.opacity(0.16)))
        }
    }
}

/// A small compatibility layer: macOS 26+ receives the system Liquid Glass
/// treatment, while older supported macOS releases retain a native material surface.
struct ReaderFlowGlassSurface<Content: View>: View {
    let tint: Color
    private let content: Content

    init(tint: Color = .clear, @ViewBuilder content: () -> Content) {
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        if #available(macOS 26.0, *) {
            content
                .padding(20)
                .glassEffect(.regular.tint(tint), in: shape)
        } else {
            content
                .padding(20)
                .background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(.white.opacity(0.16)))
        }
    }
}

extension View {
    @ViewBuilder
    func readerFlowSidebarSurface() -> some View {
        if #available(macOS 26.0, *) {
            background(.clear)
        } else {
            background(.ultraThinMaterial)
        }
    }

    @ViewBuilder
    func readerFlowProminentButtonStyle() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }
}
