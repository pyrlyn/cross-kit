import Foundation

public enum BridgeError: Error, LocalizedError {
    case languageDisabled(Language)
    case featureDisabled(Feature, Language)
    case serverNotFound(Language)
    case unknownLanguage(String)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .languageDisabled(let l): return "\(l.displayName) support is turned off in CrossKit settings."
        case .featureDisabled(let f, let l): return "\(f.displayName) is turned off for \(l.displayName) in CrossKit settings."
        case .serverNotFound(let l):
            return "\(l.serverBinaryName) was not found. Install it (\(l.installHint)) or choose the binary in CrossKit settings."
        case .unknownLanguage(let uti): return "CrossKit does not know the language of this file (\(uti))."
        case .unsupported(let detail): return detail
        }
    }
}

public struct ServerKey: Hashable, Sendable {
    public let language: Language
    public let root: String
}

/// Owns language-server processes: lazy start, initialize handshake, crash restart with backoff,
/// idle shutdown and clean shutdown. One server per (language, workspace root).
public actor ServerManager {
    public typealias StatusHandler = @Sendable (Language, ServerStatus) -> Void

    private let settings: SettingsStore
    private let locator: ServerLocator
    private var clients: [ServerKey: LSPClient] = [:]
    private var starting: [ServerKey: Task<LSPClient, Error>] = [:]
    private var lastUsed: [ServerKey: Date] = [:]
    private var crashes: [ServerKey: [Date]] = [:]
    private var statuses: [Language: ServerStatus] = [:]
    private var statusHandler: StatusHandler?
    private var idleMonitor: Task<Void, Never>?

    public var maxRestarts = 5
    public var restartWindow: TimeInterval = 300
    public var idleCheckInterval: TimeInterval = 30

    public init(settings: SettingsStore, locator: ServerLocator = ServerLocator(), statusHandler: StatusHandler? = nil) {
        self.settings = settings
        self.locator = locator
        self.statusHandler = statusHandler
    }

    public func setStatusHandler(_ handler: StatusHandler?) { statusHandler = handler }

    public func status(for language: Language) -> ServerStatus { statuses[language] ?? ServerStatus() }

    public func resolveBinary(for language: Language) -> URL? {
        if let custom = settings.customServerPath(for: language) {
            return FileManager.default.isExecutableFile(atPath: custom) ? URL(fileURLWithPath: custom) : nil
        }
        return locator.detect(language)
    }

    /// Running process-group ids (for leak checks).
    public func processGroups() -> [Int32] { clients.values.map(\.pid) }

    public func client(for language: Language, root: URL) async throws -> LSPClient {
        guard settings.isEnabled(language) else { throw BridgeError.languageDisabled(language) }
        let key = ServerKey(language: language, root: root.path)
        lastUsed[key] = Date()
        startIdleMonitorIfNeeded()
        if let client = clients[key], client.isRunning { return client }
        if let task = starting[key] { return try await task.value }
        let task = Task { try await self.launch(key) }
        starting[key] = task
        do {
            let client = try await task.value
            starting[key] = nil
            return client
        } catch {
            starting[key] = nil
            throw error
        }
    }

    private func launch(_ key: ServerKey) async throws -> LSPClient {
        let language = key.language
        guard let binary = resolveBinary(for: language) else {
            update(language) { $0 = ServerStatus(state: .notFound, lastError: BridgeError.serverNotFound(language).errorDescription) }
            throw BridgeError.serverNotFound(language)
        }
        update(language) {
            $0.state = .starting; $0.binaryPath = binary.path; $0.rootPath = key.root; $0.pid = nil
        }
        let serverLaunch: ServerLaunch
        do {
            serverLaunch = try ServerLaunch.resolve(language: language, binary: binary, userArguments: settings.arguments(for: language),
                                                    root: URL(fileURLWithPath: key.root, isDirectory: true), tools: ToolFinder(locator: locator))
        } catch {
            update(language) { $0.state = .error; $0.lastError = error.localizedDescription }
            throw error
        }
        let environment = ServerEnvironment.make(language: language, binary: serverLaunch.executable, locator: locator)
        update(language) { $0.binaryPath = serverLaunch.executable.path }
        let client: LSPClient
        do {
            client = try LSPClient(language: language, executable: serverLaunch.executable, arguments: serverLaunch.arguments,
                                   environment: environment, root: URL(fileURLWithPath: key.root, isDirectory: true),
                                   onTerminate: { [weak self] client, code, detail in
                                       Task { await self?.handleExit(key, client: client, code: code, detail: detail) }
                                   })
        } catch {
            update(language) { $0.state = .error; $0.lastError = error.localizedDescription }
            throw error
        }
        update(language) { $0.pid = client.pid }
        do {
            try await client.initialize(timeout: language.initializeTimeout, initializationOptions: serverLaunch.initializationOptions)
        } catch {
            let detail = client.recentStderr
            await client.shutdown(timeout: 1)
            update(language) {
                $0.state = .error
                $0.pid = nil
                $0.lastError = "initialize failed: \(error.localizedDescription)" + (detail.isEmpty ? "" : "\n" + LSPClient.lastLines(detail))
            }
            throw error
        }
        clients[key] = client
        update(language) { $0.state = .running; $0.pid = client.pid; $0.lastError = nil }
        return client
    }

    private func handleExit(_ key: ServerKey, client: LSPClient, code: Int32, detail: String) async {
        if client.wasStoppedIntentionally { return }
        if let current = clients[key], current === client { clients[key] = nil } else if clients[key] != nil { return }
        let message = "Server exited unexpectedly (status \(code))" + (detail.isEmpty ? "" : ": \(detail)")
        let now = Date()
        var history = crashes[key, default: []].filter { now.timeIntervalSince($0) < restartWindow }
        history.append(now)
        crashes[key] = history
        guard history.count <= maxRestarts, settings.isEnabled(key.language) else {
            update(key.language) { $0.state = .error; $0.pid = nil; $0.lastError = message + " — not restarting (\(history.count) crashes in \(Int(restartWindow))s). Use Restart in settings." }
            return
        }
        let delay = min(30, pow(2, Double(history.count - 1)))
        update(key.language) { $0.state = .restarting; $0.pid = nil; $0.lastError = message; $0.restartCount += 1 }
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        guard clients[key] == nil, starting[key] == nil else { return }
        _ = try? await self.client(for: key.language, root: URL(fileURLWithPath: key.root, isDirectory: true))
    }

    public func stop(_ language: Language) async {
        for key in clients.keys.filter({ $0.language == language }) {
            await stop(key)
        }
        update(language) { $0.state = settings.isEnabled(language) ? .stopped : .disabled; $0.pid = nil }
    }

    private func stop(_ key: ServerKey) async {
        guard let client = clients.removeValue(forKey: key) else { return }
        lastUsed[key] = nil
        await client.shutdown()
    }

    /// Stops all servers of the language and starts a fresh one for the most recently used root.
    public func restart(_ language: Language) async {
        let recent = lastUsed.filter { $0.key.language == language }.max { $0.value < $1.value }?.key
        for key in crashes.keys where key.language == language { crashes[key] = nil }
        await stop(language)
        update(language) { $0.lastError = nil; $0.restartCount = 0 }
        if let recent {
            _ = try? await client(for: language, root: URL(fileURLWithPath: recent.root, isDirectory: true))
        }
    }

    public func shutdownAll() async {
        idleMonitor?.cancel()
        idleMonitor = nil
        for task in starting.values { task.cancel() }
        for language in Language.allCases { await stop(language) }
    }

    public func touch(_ language: Language, root: URL) {
        lastUsed[ServerKey(language: language, root: root.path)] = Date()
    }

    private func startIdleMonitorIfNeeded() {
        guard idleMonitor == nil else { return }
        let interval = idleCheckInterval
        idleMonitor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                await self?.stopIdleServers()
            }
        }
    }

    private func stopIdleServers() async {
        let timeout = settings.idleTimeout
        guard timeout > 0 else { return }
        let now = Date()
        for (key, _) in clients where now.timeIntervalSince(lastUsed[key] ?? .distantPast) > timeout {
            await stop(key)
            if !clients.keys.contains(where: { $0.language == key.language }) {
                update(key.language) { $0.state = .stopped; $0.pid = nil; $0.lastError = nil }
            }
        }
    }

    private func update(_ language: Language, _ change: (inout ServerStatus) -> Void) {
        var status = statuses[language] ?? ServerStatus()
        change(&status)
        status.updatedAt = Date()
        statuses[language] = status
        settings.writeStatus(status, for: language)
        statusHandler?(language, status)
    }
}
