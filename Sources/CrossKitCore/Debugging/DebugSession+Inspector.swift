import Foundation

/// Mutable state of a Node.js inspector session.
final class InspectorState: @unchecked Sendable {
    private let lock = NSLock()
    private var _startPauseHandled = false
    private var _wasmScripts: [String: String] = [:]      // scriptId → url
    private var _scripts: [String: String] = [:]          // scriptId → url (all scripts)
    private var _wasmBreakpointsSet = false
    private var _callFrames: [JSONValue] = []
    var breakpoints: [Breakpoint] = []
    var wasmMap: WasmSourceMap?
    var harnessPath: String?

    func withLock<T>(_ body: (InspectorState) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(self) }

    var startPauseHandled: Bool {
        get { lock.withLock { _startPauseHandled } }
        set { lock.withLock { _startPauseHandled = newValue } }
    }
    var wasmBreakpointsSet: Bool {
        get { lock.withLock { _wasmBreakpointsSet } }
        set { lock.withLock { _wasmBreakpointsSet = newValue } }
    }
    var callFrames: [JSONValue] {
        get { lock.withLock { _callFrames } }
        set { lock.withLock { _callFrames = newValue } }
    }
    func addWasmScript(id: String, url: String) { lock.withLock { _wasmScripts[id] = url } }
    func addScript(id: String, url: String) { lock.withLock { _scripts[id] = url } }
    func url(ofScript id: String?) -> String? { id.flatMap { id in lock.withLock { _scripts[id] } } }
    var wasmScriptIDs: [String] { lock.withLock { Array(_wasmScripts.keys) } }
}

extension DebugSession {
    /// Connects to a Node.js process started with `--inspect-brk`, sets the breakpoints and lets it run.
    func startInspector(webSocket: URL, plan: LaunchPlan, harness: String?) async throws {
        let client = CDPClient(url: webSocket)
        cdp = client
        inspector.breakpoints = plan.breakpoints
        inspector.harnessPath = harness
        if let binary = plan.wasmBinary, let source = plan.wasmSource {
            inspector.wasmMap = WasmSourceMap.build(binary: URL(fileURLWithPath: binary), source: URL(fileURLWithPath: source))
        }
        client.onEvent { [weak self] method, params in self?.handleInspector(method: method, params: params) }
        try await client.waitUntilOpen()
        try await client.request("Runtime.enable")
        try await client.request("Debugger.enable")
        if plan.wasmBinary == nil {
            for bp in plan.breakpoints {
                let result = try await client.request("Debugger.setBreakpointByUrl", [
                    "lineNumber": .int(bp.line), "urlRegex": .string(CDPClient.urlRegex(forFile: bp.file)), "columnNumber": 0,
                ])
                let resolved = !(result["locations"]?.arrayValue ?? []).isEmpty
                appendOutput("CrossKit: breakpoint at \((bp.file as NSString).lastPathComponent):\(bp.line + 1) (\(resolved ? "resolved" : "pending until the script loads"))\n")
            }
        }
        try await client.request("Runtime.runIfWaitingForDebugger")
        update { if $0.state == .starting { $0.state = .running } }
    }

    func handleInspector(method: String, params: JSONValue) {
        switch method {
        case "Debugger.scriptParsed":
            if let url = params["url"]?.stringValue, let id = params["scriptId"]?.stringValue { inspector.addScript(id: id, url: url) }
            if let url = params["url"]?.stringValue, url.hasPrefix("wasm://"), let id = params["scriptId"]?.stringValue {
                inspector.addWasmScript(id: id, url: url)
            }
        case "Debugger.paused":
            Task { await self.inspectorPaused(params) }
        case "Debugger.resumed":
            update { $0.state = .running; $0.frames = []; $0.variables = [] }
        case "Runtime.consoleAPICalled":
            let args = params["args"]?.arrayValue ?? []
            let text = args.map { $0["value"].map(Self.describeValue) ?? $0["description"]?.stringValue ?? "" }.joined(separator: " ")
            appendOutput(text + "\n")
        case "Runtime.exceptionThrown":
            if let text = params["exceptionDetails"]?["exception"]?["description"]?.stringValue { appendOutput(text + "\n") }
        case "CrossKit.disconnected":
            update { s in if s.state.isActive { s.state = .exited }; s.frames = []; s.variables = [] }
        default:
            break
        }
    }

    static func describeValue(_ value: JSONValue) -> String {
        switch value {
        case .string(let s): return s
        default: return (try? String(decoding: value.encoded(), as: UTF8.self)) ?? ""
        }
    }

    func inspectorPaused(_ params: JSONValue) async {
        guard let cdp else { return }
        let frames = params["callFrames"]?.arrayValue ?? []
        let hit = params["hitBreakpoints"]?.arrayValue ?? []
        let topURL = frameURL(frames.first)
        // 1. `--inspect-brk` stops before the first statement: continue to the breakpoints.
        if !inspector.startPauseHandled {
            inspector.startPauseHandled = true
            if hit.isEmpty && !isAtBreakpoint(frames.first) {
                _ = try? await cdp.request("Debugger.resume")
                return
            }
        }
        // 2. The WebAssembly harness stops at its `debugger;` once the module is compiled: set wasm breakpoints.
        if let harness = inspector.harnessPath, CDPClient.path(fromURL: topURL).map({ LaunchPlanner.canonicalPath($0) == LaunchPlanner.canonicalPath(harness) }) == true,
           !inspector.wasmBreakpointsSet {
            inspector.wasmBreakpointsSet = true
            await setWasmBreakpoints()
            _ = try? await cdp.request("Debugger.resume")
            return
        }
        inspector.callFrames = frames
        let mapped: [DebugFrame] = frames.enumerated().map { index, frame in
            let url = frameURL(frame)
            let location = frame["location"]
            let line0 = location?["lineNumber"]?.intValue ?? 0
            let column = location?["columnNumber"]?.intValue ?? 0
            var name = frame["functionName"]?.stringValue ?? ""
            if name.isEmpty { name = "(anonymous)" }
            if url.hasPrefix("wasm://"), let map = inspector.wasmMap {
                let line = map.sourceLine(forOffset: column)
                return DebugFrame(id: index, name: map.functionName(forOffset: column) ?? name, file: map.sourcePath, line: line.map { $0 + 1 })
            }
            return DebugFrame(id: index, name: name, file: CDPClient.path(fromURL: url) ?? (url.isEmpty ? nil : url), line: line0 + 1)
        }
        let reason = params["reason"]?.stringValue ?? "paused"
        update {
            $0.state = .stopped
            $0.stopReason = hit.isEmpty ? reason : "breakpoint"
            $0.frames = mapped
            $0.variables = []
        }
        await refreshInspectorVariables(frames.first)
    }

    /// A call frame's script URL (`url` is deprecated and empty in recent Node.js; the scriptId is not).
    func frameURL(_ frame: JSONValue?) -> String {
        guard let frame else { return "" }
        if let url = frame["url"]?.stringValue, !url.isEmpty { return url }
        return inspector.url(ofScript: frame["location"]?["scriptId"]?.stringValue) ?? ""
    }

    func isAtBreakpoint(_ frame: JSONValue?) -> Bool {
        let breakpoints = inspector.breakpoints
        guard let frame, let path = CDPClient.path(fromURL: frameURL(frame)),
              let line = frame["location"]?["lineNumber"]?.intValue else { return false }
        return breakpoints.contains { LaunchPlanner.canonicalPath($0.file) == LaunchPlanner.canonicalPath(path) && $0.line == line }
    }

    func setWasmBreakpoints() async {
        guard let cdp, let map = inspector.wasmMap else {
            appendOutput("CrossKit: no WebAssembly source map; breakpoints in .wat files are not set.\n")
            return
        }
        for scriptID in inspector.wasmScriptIDs {
            for bp in inspector.breakpoints {
                guard let offset = map.offset(forSourceLine: bp.line) else {
                    appendOutput("CrossKit: line \(bp.line + 1) is not inside a function; no breakpoint.\n")
                    continue
                }
                let result = try? await cdp.request("Debugger.setBreakpoint", [
                    "location": ["scriptId": .string(scriptID), "lineNumber": 0, "columnNumber": .int(offset)],
                ])
                let actual = result?["actualLocation"]?["columnNumber"]?.intValue
                appendOutput("CrossKit: breakpoint at \((map.sourcePath as NSString).lastPathComponent):\(bp.line + 1) → wasm offset 0x\(String(actual ?? offset, radix: 16))\(result == nil ? " (failed)" : "")\n")
            }
        }
    }

    func refreshInspectorVariables(_ frame: JSONValue?) async {
        guard let cdp, let frame else { return }
        var variables: [DebugVariable] = []
        for scope in frame["scopeChain"]?.arrayValue ?? [] {
            let type = scope["type"]?.stringValue ?? ""
            guard ["local", "block", "catch"].contains(type), let objectID = scope["object"]?["objectId"]?.stringValue else { continue }
            guard let result = try? await cdp.request("Runtime.getProperties", ["objectId": .string(objectID), "ownProperties": true]) else { continue }
            for property in result["result"]?.arrayValue ?? [] {
                guard let name = property["name"]?.stringValue, let value = property["value"] else { continue }
                if value["subtype"]?.stringValue == "wasmvalue" {
                    // A WebAssembly value is an object: its description is the type (`i32`), its `value` property the number.
                    let wasmType = value["description"]?.stringValue
                    var text = value["value"].map(Self.describeValue) ?? wasmType ?? ""
                    if let id = value["objectId"]?.stringValue,
                       let inner = try? await cdp.request("Runtime.getProperties", ["objectId": .string(id), "ownProperties": true]),
                       let number = inner["result"]?.arrayValue?.first(where: { $0["name"]?.stringValue == "value" })?["value"] {
                        text = number["description"]?.stringValue ?? number["value"].map(Self.describeValue) ?? text
                    }
                    variables.append(DebugVariable(name: name, value: text, type: wasmType))
                    continue
                }
                let text = value["description"]?.stringValue ?? value["value"].map(Self.describeValue) ?? value["type"]?.stringValue ?? ""
                variables.append(DebugVariable(name: name, value: text, type: value["subtype"]?.stringValue ?? value["type"]?.stringValue))
            }
            if variables.count > 200 { break }
        }
        update { $0.variables = Array(variables.prefix(200)) }
    }

    func inspectorCommand(_ command: String) async throws {
        guard let cdp else { return }
        let method: String
        switch command {
        case "continue": method = "Debugger.resume"
        case "next": method = "Debugger.stepOver"
        case "stepIn": method = "Debugger.stepInto"
        case "stepOut": method = "Debugger.stepOut"
        case "pause": method = "Debugger.pause"
        default: return
        }
        if command != "pause" { update { $0.state = .running; $0.frames = []; $0.variables = [] } }
        try await cdp.request(method)
    }
}

/// Maps between lines of a WebAssembly text file and byte offsets of the binary it was assembled into.
/// Functions map exactly (CrossKit's binary reader); lines inside a function are matched by instruction
/// order, using the offsets `wasm-tools print --print-offsets` reports, so folded expressions map approximately.
public struct WasmSourceMap: Sendable {
    public struct FunctionInfo: Sendable {
        public var name: String?
        public var startLine: Int
        public var endLine: Int
        public var codeOffset: Int
        public var endOffset: Int
        /// Source lines holding instructions, in order.
        public var instructionLines: [Int]
        /// Binary offsets of instructions, in order.
        public var instructionOffsets: [Int]
    }

    public var sourcePath: String
    public var functions: [FunctionInfo]

    public static func build(binary: URL, source: URL, tools: ToolFinder = ToolFinder()) -> WasmSourceMap? {
        guard let data = try? Data(contentsOf: binary), let module = try? WasmBinary.parse(data),
              let text = try? String(contentsOf: source, encoding: .utf8) else { return nil }
        var printedOffsets: [[Int]] = []
        if let wasmTools = tools.wasmTools() {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = wasmTools
            process.arguments = ["print", "--print-offsets", binary.path]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            if (try? process.run()) != nil {
                let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                process.waitUntilExit()
                printedOffsets = parsePrintedOffsets(output)
            }
        }
        return make(module: module, text: text, sourcePath: source.path, printedOffsets: printedOffsets)
    }

    static func make(module: WasmBinary, text: String, sourcePath: String, printedOffsets: [[Int]]) -> WasmSourceMap {
        let lines = text.components(separatedBy: "\n")
        let defined = WatSource.functions(text).filter { !$0.isImport }
        var infos: [FunctionInfo] = []
        for (i, function) in defined.enumerated() where i < module.functions.count {
            let body = module.functions[i]
            let instructionLines = (function.startLine...function.endLine).filter { isInstructionLine(lines, $0, isHeader: $0 == function.startLine) }
            infos.append(FunctionInfo(name: function.name ?? function.exports.first, startLine: function.startLine, endLine: function.endLine,
                                      codeOffset: body.codeOffset, endOffset: body.endOffset, instructionLines: instructionLines,
                                      instructionOffsets: i < printedOffsets.count ? printedOffsets[i] : []))
        }
        return WasmSourceMap(sourcePath: sourcePath, functions: infos)
    }

    static let nonInstructions: Set<String> = ["func", "param", "result", "local", "export", "import", "type", "then", "else", "module", "global", "memory", "table", "data", "elem"]

    static func isInstructionLine(_ lines: [String], _ index: Int, isHeader: Bool) -> Bool {
        guard index < lines.count, !isHeader else { return false }
        var trimmed = lines[index].trimmingCharacters(in: .whitespaces)
        if let comment = trimmed.range(of: ";;") { trimmed = String(trimmed[..<comment.lowerBound]) }
        while trimmed.hasPrefix("(") { trimmed.removeFirst() }
        let word = trimmed.split(whereSeparator: { $0 == " " || $0 == ")" || $0 == "(" }).first.map(String.init) ?? ""
        return !word.isEmpty && !word.hasPrefix("$") && !nonInstructions.contains(word) && word != "end"
    }

    /// Instruction offsets per defined function from `wasm-tools print --print-offsets`.
    static func parsePrintedOffsets(_ output: String) -> [[Int]] {
        var result: [[Int]] = []
        var inFunction = false
        for line in output.components(separatedBy: "\n") {
            guard let open = line.range(of: "(;@"), let close = line.range(of: ";)", range: open.upperBound..<line.endIndex),
                  let offset = Int(line[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces), radix: 16) else { continue }
            let rest = line[close.upperBound...].trimmingCharacters(in: .whitespaces)
            if rest.hasPrefix("(func") { result.append([]); inFunction = true; continue }
            if rest.hasPrefix("(") && !rest.hasPrefix("(local") { inFunction = false; continue }
            if inFunction, !rest.hasPrefix(")"), !rest.hasPrefix("(local"), !rest.isEmpty, !result.isEmpty {
                if rest == "end" { continue }
                result[result.count - 1].append(offset)
            }
        }
        return result
    }

    func function(forLine line: Int) -> FunctionInfo? { functions.first { $0.startLine <= line && line <= $0.endLine } }
    func function(forOffset offset: Int) -> FunctionInfo? { functions.first { $0.codeOffset <= offset && offset < $0.endOffset } }

    /// Breakpoint offset for a 0-based source line: the matching instruction, else the function's first instruction.
    public func offset(forSourceLine line: Int) -> Int? {
        guard let function = function(forLine: line) else { return nil }
        if let ordinal = function.instructionLines.firstIndex(where: { $0 >= line }), ordinal < function.instructionOffsets.count {
            return function.instructionOffsets[ordinal]
        }
        return function.codeOffset
    }

    /// 0-based source line for a byte offset.
    public func sourceLine(forOffset offset: Int) -> Int? {
        guard let function = function(forOffset: offset) else { return nil }
        if let ordinal = function.instructionOffsets.lastIndex(where: { $0 <= offset }), ordinal < function.instructionLines.count {
            return function.instructionLines[ordinal]
        }
        return function.startLine
    }

    public func functionName(forOffset offset: Int) -> String? {
        function(forOffset: offset).flatMap { $0.name.map { $0.hasPrefix("$") ? $0 : "\"\($0)\"" } }
    }
}
