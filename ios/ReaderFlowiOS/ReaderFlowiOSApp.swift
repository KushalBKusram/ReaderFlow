import SwiftUI

@main
struct ReaderFlowiOSApp: App {
    @StateObject private var model = ReaderFlowAppModel()

    var body: some Scene {
        WindowGroup {
            ReaderFlowRootView()
                .environmentObject(model)
                .tint(ReaderFlowPalette.accent)
        }
    }
}
