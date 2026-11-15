import AppKit
import SwiftUI

/// Swift Package executables do not receive the normal app-bundle launch
/// plumbing. Own the AppKit lifecycle explicitly, then host our SwiftUI view.
@main
struct ReaderFlowMacApp {
    static func main() {
        if let url = commandLineValue(named: "--generate-url") {
            let title = commandLineValue(named: "--title") ?? "ReaderFlow local episode"
            let detail = commandLineValue(named: "--detail").flatMap(EpisodeDetailLevel.init(rawValue:)) ?? .depth
            Task {
                do {
                    let localAI = LocalAISetup()
                    localAI.refresh()
                    let result = try await EpisodeGenerationService.create(source: url, title: title, detail: detail, localAI: localAI) { stage in
                        writeStandardOutput("{\"stage\":\"\(stage.rawValue)\"}")
                    }
                    writeStandardOutput("{\"status\":\"completed\",\"script\":\"\(result.episode.scriptPath)\",\"audio\":\"\(result.audioURL.path)\"}")
                    exit(EXIT_SUCCESS)
                } catch {
                    writeStandardError("{\"status\":\"failed\",\"error\":\"\(error.localizedDescription.replacingOccurrences(of: "\\\"", with: "'"))\"}")
                    exit(EXIT_FAILURE)
                }
            }
            dispatchMain()
        }
        let application = NSApplication.shared
        let delegate = ReaderFlowApplicationDelegate()
        application.delegate = delegate
        application.mainMenu = ReaderFlowApplicationDelegate.makeMainMenu()
        application.setActivationPolicy(.regular)
        // NSApplication's delegate is weak; retain it for the application's
        // entire lifetime rather than letting this local go away at launch.
        withExtendedLifetime(delegate) { application.run() }
    }

    private static func commandLineValue(named name: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    private static func writeStandardOutput(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    private static func writeStandardError(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}

@MainActor
private final class ReaderFlowApplicationDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private let model = LibraryViewModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let hostingController = NSHostingController(rootView: LibraryView(model: model))
        let window = NSWindow(contentViewController: hostingController)
        window.title = "ReaderFlow"
        // Let the sidebar's own material extend up behind the traffic
        // lights instead of a separate opaque titlebar strip, matching the
        // unified, chrome-free look of apps like Music and Podcasts.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.setContentSize(NSSize(width: 1_100, height: 720))
        window.minSize = NSSize(width: 820, height: 560)
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    static func makeMainMenu() -> NSMenu {
        let menu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit ReaderFlow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        menu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        menu.addItem(editMenuItem)
        return menu
    }
}
