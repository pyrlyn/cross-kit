import Foundation

public struct DebugFrame: Codable, Equatable, Identifiable, Sendable {
    public var id: Int
    public var name: String
    public var file: String?
    /// 1-based line, as the debugger reports it.
    public var line: Int?
}

public struct DebugVariable: Codable, Equatable, Identifiable, Sendable {
    public var id: String { name }
    public var name: String
    public var value: String
    public var type: String?
}

public enum DebugSessionState: String, Codable, Sendable {
    case building, starting, running, stopped
    /// JVM: the agent listens and the program waits for a debugger to attach.
    case waitingForDebugger
    /// lldb runs in Terminal; CrossKit does not control it.
    case external
    case exited, failed

    public var isActive: Bool { ![.exited, .failed, .external].contains(self) }
}

/// Everything the Debugger window shows about one session.
public struct DebugSessionSnapshot: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var language: Language
    public var debugger: DebuggerKind
    public var target: DebugTarget
    public var program: String
    public var projectRoot: String
    public var startedAt: Date
    public var state: DebugSessionState
    public var stopReason: String?
    public var threadID: Int?
    public var exitCode: Int?
    public var frames: [DebugFrame] = []
    public var variables: [DebugVariable] = []
    public var output: String = ""
    public var jdwpAddress: String?
    public var attachCommand: String?
    public var debuggeePID: Int?
    public var breakpoints: [Breakpoint]
    public var error: String?

    public var canStep: Bool { debugger.isControlled && state == .stopped }
    public var canContinue: Bool { debugger.isControlled && state == .stopped }
    public var canPause: Bool { debugger.isControlled && state == .running }
    public var canStop: Bool { state.isActive }
}

/// One running debug session (DAP adapter, JVM with JDWP agent, or lldb in Terminal).
public final class DebugSession: @unchecked Sendable {
    public let id: String
    private let lock = NSLock()
    private var current: DebugSessionSnapshot
    private let onChange: @Sendable (DebugSessionSnapshot) -> Void
    var dap: DAPClient?
    var jvm: ChildProcess?
    /// Node.js inspector session (JavaScript, TypeScript, WebAssembly).
    var cdp: CDPClient?
    let inspector = InspectorState()
    private var initializedEvent = false
    private let maxOutput = 256 * 1024

    init(snapshot: DebugSessionSnapshot, onChange: @escaping @Sendable (DebugSessionSnapshot) -> Void) {
        id = snapshot.id
        current = snapshot
        self.onChange = onChange
    }

    public var snapshot: DebugSessionSnapshot { lock.withLock { current } }

    func update(_ body: (inout DebugSessionSnapshot) -> Void) {
        let snap: DebugSessionSnapshot = lock.withLock { body(&current); return current }
        onChange(snap)
    }

    /// Appends text to the session's console.
    public func appendOutput(_ text: String) {
        update { s in
            s.output += text
            if s.output.utf8.count > maxOutput { s.output = String(s.output.suffix(maxOutput / 2)) }
        }
    }

    // MARK: DAP

    func startDAP(adapter: String, plan: LaunchPlan, program: String, environment: [String: String]) async throws {
        let client = try DAPClient(executable: adapter, environment: environment, currentDirectory: plan.workingDirectory)
        dap = client
        client.onEvent { [weak self] event, body in self?.handle(event: event, body: body) }
        update { $0.state = .starting; $0.debuggeePID = nil }
        let adapterID = plan.debugger == .codelldb ? "lldb" : "lldb-dap"
        try await client.request("initialize", [
            "clientID": "crosskit", "clientName": "CrossKit", "adapterID": .string(adapterID),
            "linesStartAt1": true, "columnsStartAt1": true, "pathFormat": "path",
            "supportsRunInTerminalRequest": false, "supportsVariableType": true,
        ])
        var launch: [String: JSONValue] = [
            "program": .string(program),
            "args": .array(plan.arguments.map(JSONValue.string)),
            "cwd": .string(plan.workingDirectory),
            "stopOnEntry": false,
        ]
        if !plan.lldbInitCommands.isEmpty { launch["initCommands"] = .array(plan.lldbInitCommands.map(JSONValue.string)) }
        if plan.debugger == .codelldb {
            launch["env"] = .object(plan.environment.mapValues(JSONValue.string))
            launch["terminal"] = "console"
        } else {
            launch["env"] = .array(plan.environment.sorted { $0.key < $1.key }.map { .string("\($0.key)=\($0.value)") })
        }
        let launchTask = Task { try await client.request("launch", .object(launch), timeout: 60) }
        let deadline = Date().addingTimeInterval(30)
        while !lock.withLock({ initializedEvent }) {
            if Date() > deadline { launchTask.cancel(); throw DebugError.launchFailed("the adapter never sent 'initialized'. \(client.stderrText)") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        for (file, lines) in Dictionary(grouping: plan.breakpoints, by: \.file) {
            // Like lldb's move-to-nearest-code: a line without code (e.g. a Rust tail expression or a
            // blank line) gets no location, so try the next few lines.
            var chosen = lines.map(\.line)
            var resolved = false
            for offset in 0...4 {
                chosen = lines.map { $0.line + offset }
                let result = try await client.request("setBreakpoints", [
                    "source": ["path": .string(file), "name": .string((file as NSString).lastPathComponent)],
                    "breakpoints": .array(chosen.map { ["line": .int($0 + 1)] }),
                    "lines": .array(chosen.map { .int($0 + 1) }),
                ])
                if result["breakpoints"]?.arrayValue?.contains(where: { $0["verified"]?.boolValue == true }) == true {
                    resolved = true
                    break
                }
            }
            if !resolved {
                chosen = lines.map(\.line)
                _ = try await client.request("setBreakpoints", [
                    "source": ["path": .string(file), "name": .string((file as NSString).lastPathComponent)],
                    "breakpoints": .array(chosen.map { ["line": .int($0 + 1)] }),
                ])
            }
            let name = (file as NSString).lastPathComponent
            appendOutput("CrossKit: breakpoint at \(name):\(chosen[0] + 1) (\(resolved ? "resolved" : "pending: no code at this line yet"))\n")
            if resolved, chosen != lines.map(\.line) {
                update { s in s.breakpoints = zip(lines, chosen).map { Breakpoint(file: $0.0.file, line: $0.1) } + s.breakpoints.filter { $0.file != file } }
            }
        }
        try await client.request("configurationDone")
        _ = try await launchTask.value
        update { if $0.state == .starting { $0.state = .running } }
    }

    private func handle(event: String, body: JSONValue) {
        switch event {
        case "initialized":
            lock.withLock { initializedEvent = true }
        case "stopped":
            let thread = body["threadId"]?.intValue
            update {
                $0.state = .stopped
                $0.stopReason = body["description"]?.stringValue ?? body["reason"]?.stringValue
                $0.threadID = thread ?? $0.threadID
            }
            Task { await self.refreshStack() }
        case "continued":
            update { $0.state = .running; $0.frames = []; $0.variables = [] }
        case "output":
            if body["category"]?.stringValue != "telemetry", let text = body["output"]?.stringValue { appendOutput(text) }
        case "process":
            if let pid = body["systemProcessId"]?.intValue { update { $0.debuggeePID = pid } }
        case "exited":
            update { $0.exitCode = body["exitCode"]?.intValue }
        case "terminated", "adapterExited":
            let wasActive = snapshot.state.isActive
            update {
                if $0.state.isActive { $0.state = .exited }
                $0.frames = []; $0.variables = []
            }
            if wasActive, event == "terminated" { Task { await self.shutdownAdapter() } }
        default:
            break
        }
    }

    func refreshStack() async {
        guard let dap, let thread = snapshot.threadID else { return }
        do {
            let trace = try await dap.request("stackTrace", ["threadId": .int(thread), "startFrame": 0, "levels": 30])
            let frames: [DebugFrame] = (trace["stackFrames"]?.arrayValue ?? []).compactMap { frame in
                guard let id = frame["id"]?.intValue else { return nil }
                return DebugFrame(id: id, name: frame["name"]?.stringValue ?? "?", file: frame["source"]?["path"]?.stringValue,
                                  line: frame["line"]?.intValue)
            }
            var variables: [DebugVariable] = []
            if let top = frames.first {
                let scopes = try await dap.request("scopes", ["frameId": .int(top.id)])["scopes"]?.arrayValue ?? []
                let locals = scopes.first { ($0["name"]?.stringValue ?? "").lowercased().contains("local") } ?? scopes.first
                if let ref = locals?["variablesReference"]?.intValue, ref > 0 {
                    let vars = try await dap.request("variables", ["variablesReference": .int(ref)])["variables"]?.arrayValue ?? []
                    variables = vars.prefix(200).map {
                        DebugVariable(name: $0["name"]?.stringValue ?? "?", value: $0["value"]?.stringValue ?? "",
                                      type: $0["type"]?.stringValue)
                    }
                }
            }
            update { $0.frames = frames; $0.variables = variables }
        } catch {
            appendOutput("CrossKit: could not read the stack: \(error.localizedDescription)\n")
        }
    }

    // MARK: Controls

    public func resume() async throws { try await threadCommand("continue") }
    public func stepOver() async throws { try await threadCommand("next") }
    public func stepIn() async throws { try await threadCommand("stepIn") }
    public func stepOut() async throws { try await threadCommand("stepOut") }
    public func pause() async throws { try await threadCommand("pause") }

    private func threadCommand(_ command: String) async throws {
        if cdp != nil { return try await inspectorCommand(command) }
        guard let dap else { return }
        let thread = snapshot.threadID ?? 1
        if command != "pause" { update { $0.state = .running; $0.frames = []; $0.variables = [] } }
        try await dap.request(command, ["threadId": .int(thread)])
    }

    /// Ends the session: terminates the debuggee and the adapter / JVM, then reaps leftovers.
    public func stop() async {
        if let dap {
            _ = try? await dap.request("disconnect", ["terminateDebuggee": true, "restart": false], timeout: 5)
            await shutdownAdapter()
        }
        if let cdp {
            cdp.close()
            self.cdp = nil
        }
        if let jvm {
            jvm.terminateGroup()
            if !jvm.waitForExit(timeout: 3) { jvm.killGroup(); _ = jvm.waitForExit(timeout: 3) }
        }
        if let pid = snapshot.debuggeePID { Self.killIfRunning(pid: pid, program: snapshot.program) }
        update { if $0.state.isActive { $0.state = .exited } }
    }

    private func shutdownAdapter() async {
        guard let dap else { return }
        await Task.detached { dap.terminate() }.value
        if let pid = snapshot.debuggeePID { Self.killIfRunning(pid: pid, program: snapshot.program) }
    }

    /// SIGKILLs a leftover debuggee, but only while that pid still runs the session's program: once the
    /// debuggee exited, its pid can be reused by any other process of the user.
    static func killIfRunning(pid: Int, program: String) {
        guard pid > 0, !program.isEmpty, kill(pid_t(pid), 0) == 0 else { return }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid_t(pid), &buffer, UInt32(buffer.count)) > 0 else { return }
        guard LaunchPlanner.canonicalPath(String(cString: buffer)) == LaunchPlanner.canonicalPath(program) else { return }
        kill(pid_t(pid), SIGKILL)
    }
}
