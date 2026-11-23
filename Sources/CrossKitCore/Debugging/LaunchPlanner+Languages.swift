import Foundation

/// Launch plans for C++ (CMake or a single file), JavaScript/TypeScript (Node.js) and WebAssembly text.
extension LaunchPlanner {
    var tools: ToolFinder { resolver.tools }

    // MARK: C++

    func planCpp(_ plan: inout LaunchPlan, file: URL, root: URL, test: DiscoveredTest?, config: LaunchConfiguration,
                 text: String, purpose: LaunchPurpose) throws {
        guard let cmakeRoot = CppTesting.projectRoot(for: file) else {
            // A loose file: compile it with debug info.
            guard test == nil else {
                throw DebugError.noProgram("C++ tests are debugged through CMake + CTest: add a CMakeLists.txt that registers them (gtest_discover_tests, catch_discover_tests or add_test).")
            }
            guard let clang = tools.clangxx() else { throw DebugError.toolNotFound("clang++", hint: ToolFinder.clangHint) }
            let output = Self.looseBuildPath(file: file, workDirectory: workDirectory)
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            let flags = InspectService(tools: tools, workDirectory: workDirectory).cppFlags(file: file)
            plan.build = [[clang.path, "-g", "-O0"] + flags + [file.path, "-o", output.path]]
            plan.programSource = .path(output.path)
            plan.title = file.lastPathComponent
            return
        }
        guard let cmake = tools.cmake() else { throw DebugError.toolNotFound("cmake", hint: ToolFinder.cmakeHint) }
        let build = CppTesting.buildDirectory(root: cmakeRoot, variant: "debug", workDirectory: workDirectory)
        CMakeFileAPI.writeQuery(buildDirectory: build)
        plan.build = [
            [cmake.path, "-S", cmakeRoot.path, "-B", build.path, "-DCMAKE_BUILD_TYPE=Debug", "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON"],
            [cmake.path, "--build", build.path, "--parallel"],
        ]
        if let test {
            plan.programSource = .ctestCommand(buildDirectory: build.path, namePattern: test.matchPattern ?? "^" + NSRegularExpression.escapedPattern(for: test.filter) + "$")
        } else if config.program.isEmpty {
            plan.programSource = .cmakeTarget(buildDirectory: build.path, sourceFile: file.path)
        }
    }

    static func looseBuildPath(file: URL, workDirectory: URL) -> URL {
        var h: UInt64 = 1469598103934665603
        for b in file.path.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return workDirectory.appendingPathComponent("builds/single/\(file.deletingPathExtension().lastPathComponent)-\(String(h, radix: 36))")
    }

    // MARK: JavaScript / TypeScript

    func planScript(_ plan: inout LaunchPlan, file: URL, root: URL, test: DiscoveredTest?, config: LaunchConfiguration,
                    text: String, purpose: LaunchPurpose) throws {
        let language = plan.language
        if purpose == .build {
            plan.build = [try scriptCheckCommand(language: language, file: file, root: root)]
            plan.programSource = .command([])
            return
        }
        let node = try nodeExecutable(for: plan)
        if language == .typescript, !tools.nodeRunsTypeScript(URL(fileURLWithPath: node)) {
            throw DebugError.toolNotFound("Node.js 23.6 or newer", hint: "Node.js runs TypeScript natively from 23.6 (`mise use -g node@lts`).")
        }
        let placeholder = LaunchPlan.inspectPlaceholder
        guard let test else {
            plan.programSource = .command([node, placeholder, file.path])
            plan.title = file.lastPathComponent
            return
        }
        let kind = resolver.kind(for: language, projectRoot: root, file: file, text: text)
        let pattern = JSTesting.namePattern(for: test)
        let relative = TestRunnerResolver.relativePath(file, to: root)
        switch kind {
        case .vitest:
            guard let vitest = tools.nodePackageBinary("vitest", projectRoot: root) else {
                throw DebugError.toolNotFound("vitest", hint: "Add it to the project (`npm install -D vitest`).")
            }
            // Vitest's own --inspect-brk opens the inspector in the test worker.
            plan.programSource = .command([vitest.path, "run", relative, "-t", pattern, "--no-file-parallelism", "--testTimeout=0", placeholder]
                                          + config.testArguments + resolver.settings.testArguments(for: language))
        case .jest:
            guard let jest = tools.nodePackageBinary("jest", projectRoot: root) else {
                throw DebugError.toolNotFound("jest", hint: "Add it to the project (`npm install -D jest`).")
            }
            plan.programSource = .command([node, placeholder, jest.resolvingSymlinksInPath().path, "--runInBand", "--runTestsByPath", relative,
                                           "-t", pattern] + config.testArguments)
        case .bunTest:
            throw DebugError.noProgram("bun test speaks WebKit's inspector protocol, not the Node.js one. Debug the test with node:test, Vitest or Jest, or run `bun test --inspect-wait` and attach from https://debug.bun.sh.")
        default:
            plan.programSource = .command([node, placeholder, "--test", "--test-isolation=none", "--test-name-pattern=\(pattern)", file.path]
                                          + config.testArguments)
        }
        plan.arguments = []
    }

    func nodeExecutable(for plan: LaunchPlan) throws -> String {
        if plan.debugger.isNode, !plan.debuggerPath.isEmpty { return plan.debuggerPath }
        if let custom = resolver.settings.debuggerPath(for: .nodeInspector), FileManager.default.isExecutableFile(atPath: custom) { return custom }
        guard let node = tools.node() else { throw DebugError.toolNotFound("node", hint: ToolFinder.nodeHint) }
        return node.path
    }

    /// Build Project for scripts: `tsc --noEmit` (project tsconfig or the file), else Node.js's syntax check.
    func scriptCheckCommand(language: Language, file: URL, root: URL) throws -> [String] {
        let isTS = language == .typescript || file.pathExtension.lowercased() == "tsx"
        let hasConfig = FileManager.default.fileExists(atPath: root.appendingPathComponent("tsconfig.json").path)
        if let tsc = tools.nodePackageBinary("tsc", package: "typescript", projectRoot: root), isTS || hasConfig {
            return hasConfig ? [tsc.path, "--noEmit", "-p", root.path]
                : [tsc.path, "--noEmit", "--allowImportingTsExtensions", "--target", "es2022", "--module", "nodenext", "--skipLibCheck", file.path]
        }
        guard let node = tools.node() else { throw DebugError.toolNotFound("node", hint: ToolFinder.nodeHint) }
        if isTS {
            return [node.path, "-e", InspectService.stripScript, file.path]
        }
        return [node.path, "--check", file.path]
    }

    // MARK: WebAssembly

    func planWasm(_ plan: inout LaunchPlan, file: URL, root: URL, test: DiscoveredTest?, config: LaunchConfiguration,
                  text: String, purpose: LaunchPurpose) throws {
        if WasmTesting.isScript(file.path) {
            guard purpose != .debug else {
                throw DebugError.noProgram(".wast scripts are run with Run Tests in File (wasmtime wast). Debug the module in a .wat file instead.")
            }
            guard let wasmtime = tools.wasmtime() else { throw DebugError.toolNotFound("wasmtime", hint: ToolFinder.wasmtimeHint) }
            if purpose == .build { plan.build = [[wasmtime.path, "wast", file.path]]; plan.programSource = .command([]); return }
            plan.programSource = .command([wasmtime.path, "wast", file.path])
            return
        }
        let binary = Self.wasmBuildPath(file: file, workDirectory: workDirectory)
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        let converter = WasmTesting.converter(tools: tools)
        if purpose == .build {
            guard let converter else { throw DebugError.toolNotFound("wasm-tools", hint: ToolFinder.wasmToolsHint) }
            plan.build = [converter + [file.path, "-o", binary.path]]
            plan.programSource = .command([])
            return
        }
        let entry = test?.filter ?? Self.wasmEntry(text: text, cursorLine: plan.breakpoints.first?.line ?? 0)
        plan.title = entry.map { "\(file.lastPathComponent) · \($0)" } ?? file.lastPathComponent
        if purpose == .run, let wasmtime = tools.wasmtime() {
            var command = [wasmtime.path, "run"]
            if let entry, entry != "_start" { command += ["--invoke", entry] }
            plan.programSource = .command(command + [file.path])
            return
        }
        if purpose == .debug, plan.debugger == .lldb || plan.debugger == .lldbDAP {
            guard let wasmtime = tools.wasmtime() else { throw DebugError.toolNotFound("wasmtime", hint: ToolFinder.wasmtimeHint) }
            // Wasmtime registers JIT code with debug info; source breakpoints need a module compiled with DWARF.
            var command = [wasmtime.path, "run", "-D", "debug-info", "-O", "opt-level=0"]
            if let entry, entry != "_start" { command += ["--invoke", entry] }
            plan.programSource = .command(command + [file.path])
            return
        }
        guard let converter else { throw DebugError.toolNotFound("wasm-tools", hint: ToolFinder.wasmToolsHint) }
        let node = try nodeExecutable(for: plan)
        let harness = try WasmHarness.install(in: workDirectory)
        plan.build = [converter + [file.path, "-o", binary.path]]
        let mode = purpose == .debug ? "debug" : "run"
        plan.programSource = .command([node, LaunchPlan.inspectPlaceholder, harness.path, binary.path, mode, entry ?? "-"])
        plan.wasmBinary = binary.path
        plan.wasmSource = file.path
    }

    static func wasmBuildPath(file: URL, workDirectory: URL) -> URL {
        var h: UInt64 = 1469598103934665603
        for b in file.path.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return workDirectory.appendingPathComponent("wasm/\(file.deletingPathExtension().lastPathComponent)-\(String(h, radix: 36)).wasm")
    }

    /// The export to run: the exported function at the cursor (without parameters), else `_start`, `main` or `run`.
    static func wasmEntry(text: String, cursorLine: Int) -> String? {
        let functions = WatSource.functions(text).filter { !$0.isImport }
        let lines = text.components(separatedBy: "\n")
        func takesParameters(_ function: WatSource.Function) -> Bool {
            let header = lines[function.startLine...min(function.endLine, function.startLine + 2, lines.count - 1)].joined(separator: " ")
            return header.contains("(param")
        }
        if let atCursor = functions.last(where: { $0.startLine <= cursorLine && cursorLine <= $0.endLine }),
           let export = atCursor.exports.first, !takesParameters(atCursor) {
            return export
        }
        let exports = functions.flatMap(\.exports)
        return exports.first { ["_start", "main", "run"].contains($0) }
    }

    // MARK: Program resolution

    /// Executable and arguments for the program sources of these languages, after the build ran.
    /// `inspector` replaces `LaunchPlan.inspectPlaceholder` (nil drops it).
    static func resolveCommand(_ source: LaunchPlan.ProgramSource, plan: LaunchPlan, inspector: String?) throws -> (executable: String, arguments: [String])? {
        switch source {
        case .command(let argv):
            guard let first = argv.first else { return nil }
            var rest = Array(argv.dropFirst())
            if let index = rest.firstIndex(of: LaunchPlan.inspectPlaceholder) {
                if let inspector { rest[index] = inspector } else { rest.remove(at: index) }
            }
            return (first, rest + plan.arguments)
        case .cmakeTarget(let build, let sourceFile):
            let executable = try CMakeFileAPI.executable(for: sourceFile, buildDirectory: URL(fileURLWithPath: build))
            return (executable, plan.arguments)
        case .ctestCommand(let build, let pattern):
            let command = try CMakeFileAPI.testCommand(matching: pattern, buildDirectory: URL(fileURLWithPath: build))
            return (command[0], Array(command.dropFirst()) + plan.arguments)
        default:
            return nil
        }
    }
}

/// CMake's File API (codemodel v2) and CTest's JSON test list.
public enum CMakeFileAPI {
    /// Asks CMake to write the codemodel on the next configure.
    public static func writeQuery(buildDirectory: URL) {
        let query = buildDirectory.appendingPathComponent(".cmake/api/v1/query/codemodel-v2")
        try? FileManager.default.createDirectory(at: query.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: query.path) { FileManager.default.createFile(atPath: query.path, contents: Data()) }
    }

    public struct Target: Equatable, Sendable {
        public var name: String
        public var type: String
        public var artifacts: [String]
        public var sources: [String]
    }

    /// Targets of the newest codemodel reply (paths absolute).
    public static func targets(buildDirectory: URL) -> [Target] {
        let reply = buildDirectory.appendingPathComponent(".cmake/api/v1/reply")
        let fm = FileManager.default
        guard let index = ((try? fm.contentsOfDirectory(atPath: reply.path)) ?? []).filter({ $0.hasPrefix("index-") }).sorted().last,
              let indexJSON = load(reply.appendingPathComponent(index)) else { return [] }
        guard let objects = indexJSON["objects"]?.arrayValue,
              let codemodelFile = objects.first(where: { $0["kind"]?.stringValue == "codemodel" })?["jsonFile"]?.stringValue,
              let codemodel = load(reply.appendingPathComponent(codemodelFile)) else { return [] }
        let sourceRoot = codemodel["paths"]?["source"]?.stringValue ?? ""
        let buildRoot = codemodel["paths"]?["build"]?.stringValue ?? buildDirectory.path
        var targets: [Target] = []
        for configuration in codemodel["configurations"]?.arrayValue ?? [] {
            for entry in configuration["targets"]?.arrayValue ?? [] {
                guard let file = entry["jsonFile"]?.stringValue, let target = load(reply.appendingPathComponent(file)) else { continue }
                let artifacts = (target["artifacts"]?.arrayValue ?? []).compactMap { $0["path"]?.stringValue }
                    .map { $0.hasPrefix("/") ? $0 : buildRoot + "/" + $0 }
                let sources = (target["sources"]?.arrayValue ?? []).compactMap { $0["path"]?.stringValue }
                    .map { $0.hasPrefix("/") ? $0 : sourceRoot + "/" + $0 }
                targets.append(Target(name: target["name"]?.stringValue ?? "?", type: target["type"]?.stringValue ?? "",
                                      artifacts: artifacts, sources: sources))
            }
            break   // single-config generators have one configuration
        }
        return targets
    }

    static func load(_ url: URL) -> JSONValue? {
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// The executable whose target compiles the file; the only executable when the file belongs to none.
    public static func executable(for sourceFile: String, buildDirectory: URL) throws -> String {
        let executables = targets(buildDirectory: buildDirectory).filter { $0.type == "EXECUTABLE" }
        let canonical = LaunchPlanner.canonicalPath(sourceFile)
        if let target = executables.first(where: { $0.sources.contains { LaunchPlanner.canonicalPath($0) == canonical } }),
           let artifact = target.artifacts.first {
            return artifact
        }
        if executables.count == 1, let artifact = executables[0].artifacts.first { return artifact }
        if executables.isEmpty {
            throw DebugError.noProgram("The CMake project has no executable target (or CMake did not write its File API reply in \(buildDirectory.path)).")
        }
        throw DebugError.noProgram("\((sourceFile as NSString).lastPathComponent) is not part of an executable target. Targets: \(executables.map(\.name).joined(separator: ", ")). Set the program in the launch configuration.")
    }

    /// The command of the first CTest test whose name matches the ICU regex.
    public static func testCommand(matching pattern: String, buildDirectory: URL, ctest: URL? = ToolFinder().ctest()) throws -> [String] {
        guard let ctest else { throw DebugError.toolNotFound("ctest", hint: ToolFinder.cmakeHint) }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = ctest
        process.arguments = ["--test-dir", buildDirectory.path, "--show-only=json-v1"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let tests = parseTests(data)
        guard let match = tests.first(where: { $0.name.range(of: pattern, options: .regularExpression) != nil }) else {
            throw DebugError.noProgram("No CTest test matches \(pattern). Tests: \(tests.prefix(12).map(\.name).joined(separator: ", ")).")
        }
        guard !match.command.isEmpty else { throw DebugError.noProgram("CTest test \(match.name) has no command.") }
        return match.command
    }

    /// The path the compiler saw for a source file: CMake keeps the logical source directory (`/tmp/…`) while
    /// CrossKit plans with real paths (`/private/tmp/…`); breakpoints must use the compiler's spelling.
    public static func compiledPath(_ path: String, buildDirectory: URL) -> String {
        guard let cache = try? String(contentsOf: buildDirectory.appendingPathComponent("CMakeCache.txt"), encoding: .utf8),
              let line = cache.components(separatedBy: "\n").first(where: { $0.hasPrefix("CMAKE_HOME_DIRECTORY:") }),
              let eq = line.firstIndex(of: "=") else { return path }
        let home = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        let realHome = LaunchPlanner.canonicalPath(home)
        let realPath = LaunchPlanner.canonicalPath(path)
        guard realHome != home, realPath.hasPrefix(realHome + "/") else { return path }
        return home + realPath.dropFirst(realHome.count)
    }

    public static func parseTests(_ data: Data) -> [(name: String, command: [String])] {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data) else { return [] }
        return (json["tests"]?.arrayValue ?? []).compactMap { test in
            guard let name = test["name"]?.stringValue else { return nil }
            return (name, (test["command"]?.arrayValue ?? []).compactMap(\.stringValue))
        }
    }
}
