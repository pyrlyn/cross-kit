import Foundation

public enum LSPError: Error, LocalizedError {
    case timeout(String)
    case server(RPCError)
    case terminated(String)

    public var errorDescription: String? {
        switch self {
        case .timeout(let method): return "Language server did not answer \(method) in time"
        case .server(let error): return error.errorDescription
        case .terminated(let detail): return "Language server is not running" + (detail.isEmpty ? "" : ": \(detail)")
        }
    }
}

/// JSON-RPC client for one language-server process over stdio.
public final class LSPClient: @unchecked Sendable {
    public let language: Language
    public let root: URL
    public let startedAt = Date()
    public private(set) var process: ChildProcess!

    private let lock = NSLock()
    private var nextID = 1
    private var pending: [Int: (Result<JSONValue, Error>) -> Void] = [:]
    private var openDocuments: [String: Int] = [:]
    private var diagnostics: [String: [JSONValue]] = [:]
    private var diagnosticsSequence: [String: Int] = [:]
    private var stderrTail = ""
    private var terminated = false
    private var exitHandled = false
    private var _capabilities: JSONValue = .null
    private let decoder = FrameDecoder()
    private let onTerminate: @Sendable (LSPClient, Int32, String) -> Void
    public var logHandler: (@Sendable (String) -> Void)?

    public init(language: Language, executable: URL, arguments: [String], environment: [String: String], root: URL,
                onTerminate: @escaping @Sendable (LSPClient, Int32, String) -> Void) throws {
        self.language = language
        self.root = root
        self.onTerminate = onTerminate
        let box = WeakBox<LSPClient>()
        let pendingExit = PendingExit()
        process = try ChildProcess(
            executable: executable.path, arguments: arguments, environment: environment, currentDirectory: root.path,
            onStdout: { data in box.value?.receive(data) },
            onStderr: { data in box.value?.receiveStderr(data) },
            onExit: { code in
                if let client = box.value { client.handleExit(code) } else { pendingExit.set(code) }
            })
        box.value = self
        if let code = pendingExit.get() { handleExit(code) }
    }

    public var pid: Int32 { process.pid }

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return !terminated
    }

    public var capabilities: JSONValue {
        lock.lock(); defer { lock.unlock() }
        return _capabilities
    }

    public var recentStderr: String {
        lock.lock(); defer { lock.unlock() }
        return stderrTail
    }

    // MARK: Lifecycle

    public func initialize(timeout: TimeInterval, initializationOptions: JSONValue? = nil) async throws {
        let rootURI = root.absoluteString
        var params: JSONValue = [
            "processId": .int(Int(getpid())),
            "clientInfo": ["name": "CrossKit", "version": "1.0"],
            "rootUri": .string(rootURI),
            "rootPath": .string(root.path),
            "workspaceFolders": [["uri": .string(rootURI), "name": .string(root.lastPathComponent)]],
            "capabilities": [
                "general": ["positionEncodings": ["utf-16"]],
                "workspace": ["configuration": true, "workspaceFolders": true],
                "window": ["workDoneProgress": true],
                "textDocument": [
                    "synchronization": ["dynamicRegistration": false, "didSave": false, "willSave": false],
                    "completion": [
                        "completionItem": ["snippetSupport": false, "documentationFormat": ["plaintext", "markdown"]],
                        "contextSupport": true,
                    ],
                    "hover": ["contentFormat": ["plaintext", "markdown"]],
                    "definition": ["linkSupport": true],
                    "references": [:],
                    // Nested DocumentSymbol results carry selectionRange (the name), where code lenses ask for
                    // references; flat SymbolInformation only has the full range (doc comments, attributes).
                    "documentSymbol": ["hierarchicalDocumentSymbolSupport": true],
                    "inlayHint": [:],
                    "publishDiagnostics": ["relatedInformation": false, "versionSupport": true],
                ],
            ],
        ]
        if let initializationOptions, case .object(var object) = params {
            object["initializationOptions"] = initializationOptions
            params = .object(object)
        }
        let result = try await request("initialize", params, timeout: timeout)
        setCapabilities(result["capabilities"] ?? .null)
        try notify("initialized", [:])
    }

    private func setCapabilities(_ value: JSONValue) {
        lock.lock(); _capabilities = value; lock.unlock()
    }

    /// shutdown → exit → wait; escalates to SIGTERM/SIGKILL of the whole process group.
    public func shutdown(timeout: TimeInterval = 5) async {
        markTerminatingIntentionally()
        if process.isRunning {
            _ = try? await request("shutdown", nil, timeout: timeout, allowWhenTerminating: true)
            try? send(.notification(method: "exit", params: nil))
        }
        if !(await waitForExit(2)) {
            process.terminateGroup()
            if !(await waitForExit(3)) {
                process.killGroup()
                _ = await waitForExit(2)
            }
        }
        // Helpers in the same process group (e.g. `zig build` runners, proc-macro servers) must be gone too.
        let group = process.pid
        for _ in 0..<50 where ProcessRegistry.groupIsAlive(group) {
            kill(-group, SIGKILL)
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private var intentional = false
    private func markTerminatingIntentionally() {
        lock.lock(); intentional = true; lock.unlock()
    }

    public var wasStoppedIntentionally: Bool {
        lock.lock(); defer { lock.unlock() }
        return intentional
    }

    private func waitForExit(_ seconds: TimeInterval) async -> Bool {
        let process = self.process!
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: process.waitForExit(timeout: seconds)) }
        }
    }

    // MARK: Requests

    public func request(_ method: String, _ params: JSONValue?, timeout: TimeInterval,
                        allowWhenTerminating: Bool = false) async throws -> JSONValue {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, Error>) in
            lock.lock()
            if terminated {
                let tail = stderrTail
                lock.unlock()
                continuation.resume(throwing: LSPError.terminated(Self.lastLines(tail)))
                return
            }
            let id = nextID
            nextID += 1
            pending[id] = { continuation.resume(with: $0) }
            lock.unlock()
            do {
                try send(.request(id: .int(id), method: method, params: params))
            } catch {
                takePending(id)?(.failure(error))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, let callback = self.takePending(id) else { return }
                try? self.send(.notification(method: "$/cancelRequest", params: ["id": .int(id)]))
                callback(.failure(LSPError.timeout(method)))
            }
        }
    }

    public func notify(_ method: String, _ params: JSONValue?) throws {
        try send(.notification(method: method, params: params))
    }

    private func send(_ message: RPCMessage) throws {
        try process.write(try message.framed())
    }

    private func takePending(_ id: Int) -> ((Result<JSONValue, Error>) -> Void)? {
        lock.lock(); defer { lock.unlock() }
        return pending.removeValue(forKey: id)
    }

    // MARK: Documents

    /// Opens the document or replaces its full text; returns the new version.
    @discardableResult
    public func syncDocument(uri: String, text: String) throws -> Int {
        lock.lock()
        let previous = openDocuments[uri]
        let version = (previous ?? 0) + 1
        openDocuments[uri] = version
        lock.unlock()
        if previous == nil {
            try notify("textDocument/didOpen", ["textDocument": [
                "uri": .string(uri), "languageId": .string(language.languageID(forPath: URL(string: uri)?.path)), "version": .int(version), "text": .string(text),
            ]])
        } else {
            try notify("textDocument/didChange", [
                "textDocument": ["uri": .string(uri), "version": .int(version)],
                "contentChanges": [["text": .string(text)]],
            ])
        }
        return version
    }

    public func diagnosticsState(uri: String) -> (sequence: Int, items: [JSONValue]) {
        lock.lock(); defer { lock.unlock() }
        return (diagnosticsSequence[uri] ?? 0, diagnostics[uri] ?? [])
    }

    /// Waits for a publishDiagnostics newer than `afterSequence`, then lets updates settle.
    /// Returns nil if nothing was published before the deadline.
    public func waitForDiagnostics(uri: String, afterSequence: Int, timeout: TimeInterval,
                                   settle: TimeInterval = 1.5) async -> [JSONValue]? {
        let deadline = Date().addingTimeInterval(timeout)
        var lastSequence = afterSequence
        var lastChange: Date?
        while Date() < deadline {
            let state = diagnosticsState(uri: uri)
            if state.sequence != lastSequence {
                lastSequence = state.sequence
                lastChange = Date()
            }
            if let lastChange, Date().timeIntervalSince(lastChange) >= settle {
                return state.items
            }
            if !isRunning { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return lastChange == nil ? nil : diagnosticsState(uri: uri).items
    }

    // MARK: Incoming

    private func receive(_ data: Data) {
        if data.isEmpty { return }
        decoder.append(data)
        while true {
            let frame: Data?
            do { frame = try decoder.nextFrame() } catch {
                logHandler?("framing error: \(error)")
                return
            }
            guard let frame else { return }
            guard let message = try? RPCMessage.parse(frame) else { continue }
            handle(message)
        }
    }

    private func handle(_ message: RPCMessage) {
        switch message {
        case .response(let id, let result, let error):
            guard let intID = id.intValue, let callback = takePending(intID) else { return }
            if let error { callback(.failure(LSPError.server(error))) } else { callback(.success(result ?? .null)) }
        case .request(let id, let method, let params):
            let result: JSONValue
            switch method {
            case "workspace/configuration":
                let count = params?["items"]?.arrayValue?.count ?? 0
                result = .array(Array(repeating: .null, count: count))
            case "workspace/workspaceFolders":
                result = [["uri": .string(root.absoluteString), "name": .string(root.lastPathComponent)]]
            case "window/workDoneProgress/create", "client/registerCapability", "client/unregisterCapability",
                 "window/showMessageRequest", "workspace/diagnostic/refresh", "workspace/semanticTokens/refresh",
                 "workspace/inlayHint/refresh", "workspace/codeLens/refresh":
                result = .null
            default:
                try? send(.response(id: id, result: nil, error: RPCError(code: RPCError.methodNotFound, message: "Unsupported: \(method)")))
                return
            }
            try? send(.response(id: id, result: result, error: nil))
        case .notification(let method, let params):
            if method == "textDocument/publishDiagnostics", let uri = params?["uri"]?.stringValue {
                let items = params?["diagnostics"]?.arrayValue ?? []
                let key = Self.normalizeURI(uri)
                lock.lock()
                diagnostics[key] = items
                diagnosticsSequence[key, default: 0] += 1
                lock.unlock()
            } else if method == "window/logMessage" || method == "window/showMessage" {
                if let text = params?["message"]?.stringValue { logHandler?(text) }
            }
        }
    }

    private func receiveStderr(_ data: Data) {
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
        lock.lock()
        stderrTail = String((stderrTail + text).suffix(4096))
        lock.unlock()
    }

    private func handleExit(_ code: Int32) {
        lock.lock()
        if exitHandled { lock.unlock(); return }
        exitHandled = true
        terminated = true
        let callbacks = pending
        pending.removeAll()
        let tail = stderrTail
        lock.unlock()
        let detail = Self.lastLines(tail)
        for callback in callbacks.values { callback(.failure(LSPError.terminated(detail))) }
        onTerminate(self, code, detail)
    }

    /// URIs from servers may differ in percent-encoding or symlinks (/var vs /private/var).
    public static func normalizeURI(_ uri: String) -> String {
        guard let url = URL(string: uri), url.isFileURL else { return uri }
        return URL(fileURLWithPath: url.path).resolvingSymlinksInPath().absoluteString
    }

    static func lastLines(_ text: String, count: Int = 5) -> String {
        text.split(separator: "\n").suffix(count).joined(separator: "\n")
    }
}

final class WeakBox<T: AnyObject>: @unchecked Sendable {
    private let lock = NSLock()
    private weak var _value: T?
    var value: T? {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}

final class PendingExit: @unchecked Sendable {
    private let lock = NSLock()
    private var code: Int32?
    func set(_ value: Int32) { lock.lock(); code = value; lock.unlock() }
    func get() -> Int32? { lock.lock(); defer { lock.unlock() }; return code }
}
