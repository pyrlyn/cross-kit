import Foundation

/// How a debug session is run.
public enum DebuggerKind: String, Codable, CaseIterable, Identifiable, Sendable {
    /// `lldb` in a Terminal window (full lldb command line).
    case lldb
    /// `lldb-dap` (Debug Adapter Protocol) managed by the host app, shown in its Debugger window.
    case lldbDAP
    /// CodeLLDB's adapter (`codelldb`, from the VS Code extension) managed by the host app.
    case codelldb
    /// JVM started with a JDWP agent; `jdb` attaches in a Terminal window.
    case jdb
    /// JVM started with a JDWP agent that waits for an IDE (IntelliJ IDEA, VS Code, …) to attach.
    case jdwpAttach
    /// Node.js started with `--inspect-brk`; CrossKit drives it over the Chrome DevTools Protocol in its Debugger window.
    /// JavaScript, TypeScript and WebAssembly (run by CrossKit's Node.js harness).
    case nodeInspector
    /// `node inspect` (Node.js's command-line debugger) in a Terminal window.
    case nodeInspect
    /// Node.js started with `--inspect-brk` that waits for Chrome DevTools or VS Code to attach.
    case nodeAttach

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .lldb: return "lldb in Terminal"
        case .lldbDAP: return "lldb-dap (CrossKit Debugger window)"
        case .codelldb: return "CodeLLDB (CrossKit Debugger window)"
        case .jdb: return "JDWP + jdb in Terminal"
        case .jdwpAttach: return "JDWP, wait for IDE to attach"
        case .nodeInspector: return "Node.js inspector (CrossKit Debugger window)"
        case .nodeInspect: return "node inspect in Terminal"
        case .nodeAttach: return "Node.js inspector, wait for Chrome DevTools / VS Code to attach"
        }
    }

    /// The executable a custom path overrides.
    public var toolName: String {
        switch self {
        case .lldb: return "lldb"
        case .lldbDAP: return "lldb-dap"
        case .codelldb: return "codelldb"
        case .jdb, .jdwpAttach: return "java"
        case .nodeInspector, .nodeInspect, .nodeAttach: return "node"
        }
    }

    public var usesDAP: Bool { self == .lldbDAP || self == .codelldb }
    /// Driven over the Chrome DevTools Protocol (Node.js inspector).
    public var usesCDP: Bool { self == .nodeInspector }
    public var isNode: Bool { [.nodeInspector, .nodeInspect, .nodeAttach].contains(self) }
    /// CrossKit's Debugger window can step, continue and pause.
    public var isControlled: Bool { usesDAP || usesCDP }
    public var isJVM: Bool { self == .jdb || self == .jdwpAttach }

    public static func choices(for language: Language) -> [DebuggerKind] {
        switch language {
        case .kotlin: return [.jdb, .jdwpAttach]
        case .javascript, .typescript: return nodeChoices
        // WebAssembly: Node.js (V8 understands wasm) or lldb with Wasmtime's JIT debug info (modules with DWARF).
        case .wasm: return nodeChoices + [.lldb, .lldbDAP]
        case .zig, .rust, .cpp: return nativeChoices
        }
    }

    public static let nodeChoices: [DebuggerKind] = [.nodeInspector, .nodeInspect, .nodeAttach]

    /// Debuggers for native code: Zig, Rust, C++ and Kotlin/Native binaries.
    public static let nativeChoices: [DebuggerKind] = [.lldbDAP, .lldb, .codelldb]
}

public enum DebugTarget: String, Codable, Sendable {
    /// The program the file belongs to (its `main`).
    case file
    /// The test function enclosing the cursor.
    case test
}

/// Per-project launch settings. Created automatically the first time a project is debugged
/// (and saved), then editable in the settings window.
public struct LaunchConfiguration: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(language.rawValue):\(projectRoot)" }
    public var language: Language
    public var projectRoot: String
    /// Program to debug instead of the one CrossKit builds (Debug File only). Empty = build automatically.
    public var program: String
    public var arguments: [String]
    public var environment: [String: String]
    /// Working directory; empty = project root.
    public var workingDirectory: String
    /// Build before launching (zig build / cargo build / gradle classes).
    public var buildBeforeLaunch: Bool
    /// Extra arguments for the test binary (Debug Test only), e.g. `--nocapture`.
    public var testArguments: [String]
    /// Kotlin only: target to build, run and debug (`auto`, `jvm`, `native` or a Gradle target name);
    /// nil follows the Kotlin target in CrossKit settings.
    public var kotlinTarget: String?
    public var updatedAt: Date

    public init(language: Language, projectRoot: String, program: String = "", arguments: [String] = [],
                environment: [String: String] = [:], workingDirectory: String = "", buildBeforeLaunch: Bool = true,
                testArguments: [String] = [], kotlinTarget: String? = nil, updatedAt: Date = Date()) {
        self.kotlinTarget = kotlinTarget
        self.language = language
        self.projectRoot = projectRoot
        self.program = program
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.buildBeforeLaunch = buildBeforeLaunch
        self.testArguments = testArguments
        self.updatedAt = updatedAt
    }

    public var effectiveWorkingDirectory: String { workingDirectory.isEmpty ? projectRoot : workingDirectory }

    public var projectName: String { (projectRoot as NSString).lastPathComponent }

    /// Splits a command line into arguments: whitespace separates, '…' and "…" group, \ escapes.
    public static func splitArguments(_ line: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character?
        var escaping = false
        var inArgument = false
        for ch in line {
            if escaping { current.append(ch); escaping = false; continue }
            if ch == "\\" && quote != "'" { escaping = true; inArgument = true; continue }
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
                continue
            }
            if ch == "'" || ch == "\"" { quote = ch; inArgument = true; continue }
            if ch.isWhitespace {
                if inArgument { result.append(current); current = ""; inArgument = false }
                continue
            }
            current.append(ch)
            inArgument = true
        }
        if inArgument { result.append(current) }
        return result
    }

    /// Inverse of `splitArguments` for display.
    public static func joinArguments(_ arguments: [String]) -> String {
        arguments.map { arg in
            if !arg.isEmpty, !arg.contains(where: { $0.isWhitespace || "'\"\\".contains($0) }) { return arg }
            return "\"" + arg.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }.joined(separator: " ")
    }

    /// `KEY=VALUE` per line ↔ dictionary.
    public static func parseEnvironment(_ text: String) -> [String: String] {
        var env: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "="), eq != trimmed.startIndex else { continue }
            env[String(trimmed[..<eq])] = String(trimmed[trimmed.index(after: eq)...])
        }
        return env
    }

    public static func formatEnvironment(_ env: [String: String]) -> String {
        env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
    }
}

public struct Breakpoint: Codable, Equatable, Sendable {
    public var file: String
    /// 0-based, like the editor.
    public var line: Int

    public init(file: String, line: Int) {
        self.file = file
        self.line = line
    }
}

/// A fully resolved launch: what to build, what to run, where to stop.
public struct LaunchPlan: Codable, Equatable, Sendable {
    public var language: Language
    public var target: DebugTarget
    public var debugger: DebuggerKind
    public var debuggerPath: String
    public var projectRoot: String
    /// Build commands run in order before launching (each is executable + arguments).
    public var build: [[String]]
    /// How to find the program after building.
    public var programSource: ProgramSource
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: String
    public var breakpoints: [Breakpoint]
    /// Human-readable test or main name.
    public var title: String
    /// JVM only: JDWP port (0 = choose a free port).
    public var jdwpPort: Int
    /// JVM only: class for the jdb breakpoint (`stop at <class>:<line>`).
    public var jvmBreakpointClass: String?
    /// Kotlin only: the target being built (JVM or Kotlin/Native).
    public var kotlinTarget: KotlinTargetInfo?
    /// lldb commands run before the target is created (e.g. Kotlin/Native's pretty printers).
    public var lldbInitCommands: [String] = []

    public enum ProgramSource: Codable, Equatable, Sendable {
        case path(String)
        /// Newest executable produced by the last cargo build command (parsed from --message-format=json).
        case cargoArtifact(target: String?, test: Bool)
        /// First executable in zig-out/bin, preferring this name.
        case zigInstall(preferredName: String)
        /// JVM: run `java -cp <classpath from Gradle> mainClass`.
        case jvmMain(mainClass: String)
        /// JVM: run this Gradle test command; the init script puts the JDWP agent into the test JVM.
        case gradleTest(command: [String])
        /// Kotlin/Native: the newest `.kexe` a link task wrote into this directory.
        case nativeExecutable(directory: String)
        /// C++ (CMake): the executable target containing this source file (CMake File API codemodel).
        case cmakeTarget(buildDirectory: String, sourceFile: String)
        /// C++ (CTest): the command of the first test whose name matches the ICU regex (`ctest --show-only=json-v1`).
        case ctestCommand(buildDirectory: String, namePattern: String)
        /// A complete command line (Node.js, Wasmtime, the WebAssembly harness). `LaunchPlan.inspectPlaceholder`
        /// marks where the inspector flag goes when debugging (removed when running).
        case command([String])
    }

    /// Replaced by `--inspect-brk=…` when debugging with the Node.js inspector.
    public static let inspectPlaceholder = "{crosskit-inspect}"
    /// WebAssembly: the binary a `.wat` file was assembled into (the Node.js inspector maps breakpoints with it).
    public var wasmBinary: String?
    /// WebAssembly: the `.wat` source of `wasmBinary`.
    public var wasmSource: String?
}

/// What the extension shows after a debug command.
public struct DebugLaunchInfo: Codable, Equatable, Sendable {
    public var sessionID: String
    public var language: Language
    public var debugger: DebuggerKind
    public var program: String
    public var title: String
    public var breakpoint: Breakpoint?
    /// JVM only: where the JDWP agent listens.
    public var jdwpAddress: String?
    public var message: String
    public var warning: String?

    public init(sessionID: String, language: Language, debugger: DebuggerKind, program: String, title: String,
                breakpoint: Breakpoint?, jdwpAddress: String? = nil, message: String, warning: String? = nil) {
        self.sessionID = sessionID
        self.language = language
        self.debugger = debugger
        self.program = program
        self.title = title
        self.breakpoint = breakpoint
        self.jdwpAddress = jdwpAddress
        self.message = message
        self.warning = warning
    }
}

public enum DebugError: Error, LocalizedError, Equatable {
    case debuggerNotFound(String, hint: String)
    case toolNotFound(String, hint: String)
    case noMain(String)
    case noTestAtCursor
    case buildFailed(String, output: String)
    case noProgram(String)
    case launchFailed(String)
    case needsSavedFile

    public var errorDescription: String? {
        switch self {
        case .debuggerNotFound(let tool, let hint): return "\(tool) was not found. \(hint)"
        case .toolNotFound(let tool, let hint): return "\(tool) was not found. \(hint)"
        case .noMain(let file): return "\(file) has no main function. Open the file with `main`, or use Debug Test at Cursor inside a test."
        case .noTestAtCursor: return "No test function at or above the cursor."
        case .buildFailed(let command, let output):
            let tail = output.split(separator: "\n", omittingEmptySubsequences: false).suffix(25).joined(separator: "\n")
            return "Build failed: \(command)\n\n\(tail)"
        case .noProgram(let detail): return detail
        case .launchFailed(let detail): return "Could not start the debugger: \(detail)"
        case .needsSavedFile: return "Save the file inside a project before debugging (CrossKit could not determine its path)."
        }
    }
}

/// Finds debuggers: lldb / lldb-dap (Xcode, Command Line Tools, Homebrew LLVM, PATH), CodeLLDB
/// (VS Code / Cursor extensions), and java/jdb (same JDK lookup as the Kotlin server).
public struct DebuggerLocator: Sendable {
    public var locator: ServerLocator
    /// Developer directory (`xcode-select -p`); nil = query it.
    public var developerDirectory: String?

    public init(locator: ServerLocator = ServerLocator(), developerDirectory: String? = nil) {
        self.locator = locator
        self.developerDirectory = developerDirectory
    }

    func developerDirs() -> [URL] {
        // An explicit developer directory (tests) replaces the system lookup entirely.
        if let developerDirectory { return [URL(fileURLWithPath: developerDirectory).appendingPathComponent("usr/bin")] }
        var dirs: [String] = []
        if let selected = Self.selectedDeveloperDirectory { dirs.append(selected) }
        dirs += ["/Applications/Xcode.app/Contents/Developer", "/Library/Developer/CommandLineTools"]
        var seen = Set<String>()
        return dirs.filter { seen.insert($0).inserted }.map { URL(fileURLWithPath: $0).appendingPathComponent("usr/bin") }
    }

    static let selectedDeveloperDirectory: String? = {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return process.terminationStatus == 0 && !out.isEmpty ? out : nil
    }()

    public func find(_ kind: DebuggerKind) -> URL? {
        let fm = FileManager.default
        let home = locator.home
        switch kind {
        case .lldb, .lldbDAP:
            let name = kind == .lldb ? "lldb" : "lldb-dap"
            var preferred = developerDirs()
            preferred += ["/opt/homebrew/opt/llvm/bin", "/usr/local/opt/llvm/bin"].map { URL(fileURLWithPath: $0) }
            if kind == .lldb, developerDirectory == nil { preferred.append(URL(fileURLWithPath: "/usr/bin")) }
            return locator.findTools(named: name, miseToolDirectories: ["llvm", "aqua-llvm-llvm-project"], preferredDirectories: preferred).first
        case .codelldb:
            for root in [".vscode/extensions", ".cursor/extensions", ".vscode-insiders/extensions", ".windsurf/extensions"] {
                let dir = home.appendingPathComponent(root)
                let candidates = locator.sortedChildren(of: dir).filter { $0.lastPathComponent.hasPrefix("vadimcn.vscode-lldb") }
                for candidate in candidates {
                    let adapter = candidate.appendingPathComponent("adapter/codelldb")
                    if fm.isExecutableFile(atPath: adapter.path) { return adapter }
                }
            }
            return locator.findTools(named: "codelldb", miseToolDirectories: []).first
        case .jdb, .jdwpAttach:
            guard let javaHome = locator.javaHome() else { return nil }
            let java = javaHome.appendingPathComponent("bin/java")
            return fm.isExecutableFile(atPath: java.path) ? java : nil
        case .nodeInspector, .nodeInspect, .nodeAttach:
            return ToolFinder(locator: locator).node()
        }
    }

    public func jdb() -> URL? {
        guard let java = find(.jdb) else { return nil }
        let jdb = java.deletingLastPathComponent().appendingPathComponent("jdb")
        return FileManager.default.isExecutableFile(atPath: jdb.path) ? jdb : nil
    }

    /// Auto-detection: lldb-dap (host-managed panel) if available, else lldb in Terminal; JVM: jdb in Terminal.
    public func autoKind(for language: Language) -> DebuggerKind {
        if language == .kotlin { return .jdb }
        if [.javascript, .typescript, .wasm].contains(language) { return .nodeInspector }
        return find(.lldbDAP) != nil ? .lldbDAP : .lldb
    }

    public static func installHint(_ kind: DebuggerKind) -> String {
        switch kind {
        case .lldb, .lldbDAP:
            return "Install Xcode or the Command Line Tools (`xcode-select --install`), or choose the binary in CrossKit settings."
        case .codelldb:
            return "Install the CodeLLDB extension (vadimcn.vscode-lldb) in VS Code or Cursor, choose its adapter/codelldb in CrossKit settings, or pick lldb-dap."
        case .jdb, .jdwpAttach:
            return "Install a JDK 17 or 21 (e.g. `mise use -g java@temurin-21`) or choose java in CrossKit settings."
        case .nodeInspector, .nodeInspect, .nodeAttach:
            return ToolFinder.nodeHint + " Or choose node in CrossKit settings."
        }
    }

    public func describe(_ language: Language) -> [(tool: String, path: String?)] {
        if language == .kotlin {
            return [("java", find(.jdb)?.path), ("jdb", jdb()?.path)]
        }
        if language == .javascript || language == .typescript {
            return [("node", find(.nodeInspector)?.path)]
        }
        if language == .wasm {
            let tools = ToolFinder(locator: locator)
            return [("node", find(.nodeInspector)?.path), ("wasmtime", tools.wasmtime()?.path), ("lldb", find(.lldb)?.path)]
        }
        return [("lldb-dap", find(.lldbDAP)?.path), ("lldb", find(.lldb)?.path), ("codelldb", find(.codelldb)?.path)]
    }
}
