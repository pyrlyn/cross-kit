import SwiftUI
import AppKit
import CrossKitCore

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let settings = SettingsStore.shared()
    let locator = ServerLocator()
    let manager: ServerManager
    let handler: BridgeHandler
    private var server: BridgeServer?

    @Published var statuses: [Language: ServerStatus] = [:]
    @Published var detectedPaths: [Language: [String]] = [:]
    @Published var bridgeError: String?
    @Published var testRuns: [TestRunResult] = []
    @Published var testTools: [Language: [(tool: String, path: String?)]] = [:]
    let toolchain = TestToolchain()
    let debuggers = DebuggerLocator()
    @Published var debugSessions: [DebugSessionSnapshot] = []
    @Published var debugTools: [Language: [(tool: String, path: String?)]] = [:]
    @Published var launchConfigurations: [LaunchConfiguration] = []
    @Published var programRuns: [ProgramRun] = []
    @Published var preview: PreviewResult?
    @Published var previewImages: [String: NSImage] = [:]
    @Published var previewRendering = false
    @Published var previewError: String?
    var previewFileDate: Date?
    @Published var inspection: InspectionResult?
    @Published var inspectionError: String?
    @Published var inspecting = false
    /// The Preview window shows the latest of a Compose preview and a file inspection.
    @Published var previewShowsInspection = false
    @Published var coverageReports: [CoverageReport] = []

    private init() {
        manager = ServerManager(settings: settings, locator: locator)
        handler = BridgeHandler(manager: manager, settings: settings)
        handler.documentResolver = { request, language in XcodeDocumentLocator.resolve(request, language: language) }
        handler.openLocation = { location in XcodeDocumentLocator.open(location) }
        handler.onTestRun = { run in
            Task { @MainActor in AppModel.shared.record(run) }
        }
        handler.debugService.onChange = { snapshot in
            Task { @MainActor in AppModel.shared.updateDebugSession(snapshot) }
        }
        handler.runService.onChange = { run in
            Task { @MainActor in AppModel.shared.updateProgramRun(run) }
        }
        handler.onPreview = { result in
            Task { @MainActor in AppModel.shared.showPreview(result) }
        }
        handler.onInspection = { result in
            Task { @MainActor in AppModel.shared.showInspection(result) }
        }
        handler.onCoverage = { report in
            Task { @MainActor in AppModel.shared.showCoverage(report) }
        }
        for language in Language.allCases {
            var status = ServerStatus(state: settings.isEnabled(language) ? .stopped : .disabled)
            status.binaryPath = nil
            statuses[language] = status
            settings.writeStatus(status, for: language)
        }
        refreshDetection()
        let manager = self.manager
        Task {
            await manager.setStatusHandler { language, status in
                Task { @MainActor in AppModel.shared.statuses[language] = status }
            }
        }
        startBridge()
    }

    private func startBridge() {
        let handler = self.handler
        let server = BridgeServer { request in await handler.handle(request) }
        do {
            try server.start()
            self.server = server
            bridgeError = nil
            NSLog("CrossKit bridge listening on %@", server.portName)
        } catch {
            bridgeError = error.localizedDescription
            NSLog("CrossKit bridge failed: %@", error.localizedDescription)
        }
    }

    func refreshDetection() {
        for language in Language.allCases {
            detectedPaths[language] = locator.candidates(for: language).map(\.path)
            testTools[language] = toolchain.describe(language)
            debugTools[language] = debuggers.describe(language)
        }
        launchConfigurations = settings.launchConfigurations().sorted { $0.id < $1.id }
    }

    // MARK: Tests

    func record(_ run: TestRunResult) {
        testRuns.insert(run, at: 0)
        if testRuns.count > 50 { testRuns.removeLast(testRuns.count - 50) }
    }

    func testRunnerBinding(_ language: Language) -> Binding<String> {
        Binding(
            get: { self.settings.testRunner(for: language)?.rawValue ?? "auto" },
            set: { value in
                self.objectWillChange.send()
                self.settings.setTestRunner(TestRunnerKind(rawValue: value), for: language)
            })
    }

    func testArgumentsBinding(_ language: Language) -> Binding<String> {
        Binding(
            get: { self.settings.testArguments(for: language).joined(separator: " ") },
            set: { value in
                self.objectWillChange.send()
                self.settings.setTestArguments(value.split(separator: " ").map(String.init), for: language)
            })
    }

    var testTimeoutMinutes: Binding<Double> {
        Binding(
            get: { self.settings.testTimeout / 60 },
            set: { minutes in
                self.objectWillChange.send()
                self.settings.testTimeout = max(1, minutes) * 60
            })
    }

    func chooseTestExecutable(for language: Language) {
        let panel = NSOpenPanel()
        panel.title = "Choose test tool for \(language.displayName)"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = true
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            objectWillChange.send()
            settings.setTestExecutablePath(url.path, for: language)
        }
    }

    func resetTestExecutable(for language: Language) {
        objectWillChange.send()
        settings.setTestExecutablePath(nil, for: language)
    }

    /// Path that will be used: custom if set, otherwise the first auto-detected one.
    func effectivePath(_ language: Language) -> String? {
        settings.customServerPath(for: language) ?? detectedPaths[language]?.first
    }

    func isCustomPath(_ language: Language) -> Bool { settings.customServerPath(for: language) != nil }

    // MARK: Bindings (write-through to the shared App Group UserDefaults)

    func enabledBinding(_ language: Language) -> Binding<Bool> {
        Binding(
            get: { self.settings.isEnabled(language) },
            set: { enabled in
                self.objectWillChange.send()
                self.settings.setEnabled(enabled, for: language)
                let manager = self.manager
                Task { await manager.stop(language) }
            })
    }

    func featureBinding(_ feature: Feature, _ language: Language) -> Binding<Bool> {
        Binding(
            get: { self.settings.isFeatureEnabled(feature, for: language) },
            set: { enabled in
                self.objectWillChange.send()
                self.settings.setFeature(feature, enabled: enabled, for: language)
            })
    }

    var idleMinutes: Binding<Double> {
        Binding(
            get: { self.settings.idleTimeout / 60 },
            set: { minutes in
                self.objectWillChange.send()
                self.settings.idleTimeout = minutes * 60
            })
    }

    func setCustomPath(_ path: String?, for language: Language) {
        objectWillChange.send()
        settings.setCustomServerPath(path, for: language)
        restart(language)
    }

    func chooseBinary(for language: Language) {
        let panel = NSOpenPanel()
        panel.title = "Choose \(language.serverBinaryName)"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.showsHiddenFiles = true
        if let current = effectivePath(language) {
            panel.directoryURL = URL(fileURLWithPath: current).deletingLastPathComponent()
        }
        if panel.runModal() == .OK, let url = panel.url {
            setCustomPath(url.path, for: language)
        }
    }

    func restart(_ language: Language) {
        let manager = self.manager
        Task { await manager.restart(language) }
    }

    func stop(_ language: Language) {
        let manager = self.manager
        Task { await manager.stop(language) }
    }

    func openExtensionsSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences") {
            NSWorkspace.shared.open(url)
        }
    }

    func shutdownBlocking(timeout: TimeInterval) {
        server?.stop()
        let manager = self.manager
        let done = DispatchSemaphore(value: 0)
        let debugService = handler.debugService
        let runService = handler.runService
        Task.detached {
            runService.stopAll()
            await debugService.stopAll()
            await manager.shutdownAll()
            done.signal()
        }
        // Spin the run loop so main-actor hops can complete while we wait.
        let deadline = Date().addingTimeInterval(timeout)
        while done.wait(timeout: .now()) == .timedOut && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        ProcessRegistry.killAll()
    }

    // MARK: Debugging

    func updateDebugSession(_ snapshot: DebugSessionSnapshot) {
        let isNew = !debugSessions.contains { $0.id == snapshot.id }
        if let index = debugSessions.firstIndex(where: { $0.id == snapshot.id }) {
            debugSessions[index] = snapshot
        } else {
            debugSessions.insert(snapshot, at: 0)
            if debugSessions.count > 30 { debugSessions.removeLast(debugSessions.count - 30) }
        }
        launchConfigurations = settings.launchConfigurations().sorted { $0.id < $1.id }
        if isNew || snapshot.state == .stopped || snapshot.state == .waitingForDebugger {
            DebuggerWindow.show(model: self, select: snapshot.id)
        }
    }

    enum DebugAction { case resume, stepOver, stepIn, stepOut, pause, stop }

    func perform(_ action: DebugAction, on id: String) {
        guard let session = handler.debugService.session(id) else { return }
        Task {
            do {
                switch action {
                case .resume: try await session.resume()
                case .stepOver: try await session.stepOver()
                case .stepIn: try await session.stepIn()
                case .stepOut: try await session.stepOut()
                case .pause: try await session.pause()
                case .stop: await session.stop()
                }
            } catch {
                session.appendOutput("CrossKit: \(error.localizedDescription)\n")
            }
        }
    }

    func clearFinishedSessions() {
        debugSessions.removeAll { !$0.state.isActive && $0.state != .waitingForDebugger }
    }

    func openInXcode(file: String, line: Int) {
        XcodeDocumentLocator.open(BridgeLocation(path: file, range: BridgeRange(startLine: max(line - 1, 0), startCharacter: 0,
                                                                              endLine: max(line - 1, 0), endCharacter: 0)))
    }

    func debuggerBinding(_ language: Language) -> Binding<String> {
        Binding(
            get: { self.settings.debugger(for: language)?.rawValue ?? "auto" },
            set: { value in
                self.objectWillChange.send()
                self.settings.setDebugger(DebuggerKind(rawValue: value), for: language)
            })
    }

    func effectiveDebugger(_ language: Language) -> DebuggerKind {
        settings.debugger(for: language) ?? debuggers.autoKind(for: language)
    }

    func chooseDebuggerPath(for kind: DebuggerKind) {
        let panel = NSOpenPanel()
        panel.title = "Choose \(kind.toolName)"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = true
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            objectWillChange.send()
            settings.setDebuggerPath(url.path, for: kind)
        }
    }

    func resetDebuggerPath(for kind: DebuggerKind) {
        objectWillChange.send()
        settings.setDebuggerPath(nil, for: kind)
    }

    var jdwpPortBinding: Binding<String> {
        Binding(
            get: { String(self.settings.jdwpPort) },
            set: { value in
                guard let port = Int(value.trimmingCharacters(in: .whitespaces)), (0...65535).contains(port) else { return }
                self.objectWillChange.send()
                self.settings.jdwpPort = port
            })
    }

    func save(_ configuration: LaunchConfiguration) {
        var updated = configuration
        updated.updatedAt = Date()
        settings.saveLaunchConfiguration(updated)
        launchConfigurations = settings.launchConfigurations().sorted { $0.id < $1.id }
    }

    func delete(_ configuration: LaunchConfiguration) {
        settings.deleteLaunchConfiguration(id: configuration.id)
        launchConfigurations = settings.launchConfigurations().sorted { $0.id < $1.id }
    }
}
