import SwiftUI
import AppKit
import CrossKitCore

@main
struct CrossKitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Window("CrossKit Settings", id: "settings") {
            SettingsView()
                .environmentObject(model)
                .frame(minWidth: 640, minHeight: 560)
        }
        .windowResizability(.contentMinSize)

        Window("CrossKit Test Results", id: "tests") {
            TestResultsView()
                .environmentObject(model)
                .frame(minWidth: 760, minHeight: 480)
        }

        MenuBarExtra("CrossKit", systemImage: "chevron.left.forwardslash.chevron.right") {
            MenuBarContent()
                .environmentObject(model)
        }
    }
}

struct MenuBarContent: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ForEach(Language.allCases) { language in
            let status = model.statuses[language] ?? ServerStatus()
            Label {
                Text("\(language.displayName): \(status.state.rawValue)")
            } icon: {
                if let image = model.languageIcon(language) { Image(nsImage: image) }
            }
        }
        Divider()
        Button("Debugger…") { DebuggerWindow.show(model: model) }
        Button("Run…") { RunWindow.show(model: model) }
        Button("Preview…") { PreviewWindow.show(model: model) }
        Button("Inspect a File…") { model.chooseFileToInspect() }
        Button("Coverage…") { CoverageWindow.show(model: model) }
        Button("Test Results…") {
            openWindow(id: "tests")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Settings…") {
            openWindow(id: "settings")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Quit CrossKit") { NSApp.terminate(nil) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Start the bridge immediately, even when launched in the background by the extension.
        MainActor.assumeIsolated { _ = AppModel.shared }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.shutdownBlocking(timeout: 6) }
    }
}
