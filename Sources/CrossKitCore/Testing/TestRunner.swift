import Foundation

/// Finds test toolchains (zig, cargo, cargo-nextest, gradle) in the same places as language servers.
public struct TestToolchain: Sendable {
    public var locator: ServerLocator

    public init(locator: ServerLocator = ServerLocator()) {
        self.locator = locator
    }

    public func zig() -> URL? {
        locator.findTools(named: "zig", miseToolDirectories: ["zig", "aqua-ziglang-zig"]).first
    }

    public func cargo() -> URL? {
        let home = locator.home
        var preferred = [home.appendingPathComponent(".cargo/bin")]
        preferred += locator.sortedChildren(of: home.appendingPathComponent(".rustup/toolchains")).map { $0.appendingPathComponent("bin") }
        return locator.findTools(named: "cargo", miseToolDirectories: ["rust"], preferredDirectories: preferred).first
    }

    public func cargoNextest() -> URL? {
        locator.findTools(named: "cargo-nextest",
                          miseToolDirectories: ["cargo-cargo-nextest", "cargo-nextest", "aqua-nextest-rs-nextest", "ubi-nextest-rs-nextest"],
                          preferredDirectories: [locator.home.appendingPathComponent(".cargo/bin")]).first
    }

    public func gradle() -> URL? {
        locator.findTools(named: "gradle", miseToolDirectories: ["gradle", "aqua-gradle-gradle"]).first
    }

    /// Human-readable tool availability for the settings window.
    public func describe(_ language: Language) -> [(tool: String, path: String?)] {
        switch language {
        case .zig: return [("zig", zig()?.path)]
        case .rust: return [("cargo", cargo()?.path), ("cargo-nextest", cargoNextest()?.path)]
        case .kotlin: return [("gradle", gradle()?.path), ("java", locator.javaHome()?.appendingPathComponent("bin/java").path)]
        case .cpp:
            let tools = ToolFinder(locator: locator)
            let clang = tools.clangxx()
            return [("cmake", tools.cmake()?.path), ("ctest", tools.ctest()?.path), ("clang++", clang?.path),
                    ("llvm-cov", tools.llvmTool("llvm-cov", matching: clang)?.path)]
        case .javascript, .typescript:
            let tools = ToolFinder(locator: locator)
            return [("node", tools.node()?.path), ("vitest", tools.nodePackageBinary("vitest", projectRoot: nil)?.path),
                    ("jest", tools.nodePackageBinary("jest", projectRoot: nil)?.path), ("bun", tools.bun()?.path)]
        case .wasm:
            let tools = ToolFinder(locator: locator)
            return [("wasmtime", tools.wasmtime()?.path), ("wasm-tools", tools.wasmTools()?.path),
                    ("wat2wasm", tools.wabt("wat2wasm")?.path), ("node", tools.node()?.path)]
        }
    }
}

/// Picks the runner and builds the exact command for a file/test.
public struct TestRunnerResolver: Sendable {
    public var settings: SettingsStore
    public var toolchain: TestToolchain
    /// CrossKit's own build trees (CMake), test reports and coverage data live here.
    public var workDirectory: URL

    public init(settings: SettingsStore, toolchain: TestToolchain = TestToolchain(), workDirectory: URL = SharedPaths.debugDirectory) {
        self.settings = settings
        self.toolchain = toolchain
        self.workDirectory = workDirectory
    }

    public var tools: ToolFinder { ToolFinder(locator: toolchain.locator) }

    // MARK: Project roots

    public func projectRoot(for file: URL, language: Language) -> URL {
        let start = file.deletingLastPathComponent()
        switch language {
        case .zig: return nearest(["build.zig"], from: start) ?? start
        case .rust: return nearest(["Cargo.toml"], from: start) ?? start
        case .kotlin:
            return nearest(["gradlew"], from: start)
                ?? nearest(["settings.gradle.kts", "settings.gradle"], from: start)
                ?? nearest(["build.gradle.kts", "build.gradle"], from: start)
                ?? start
        case .cpp: return CppTesting.projectRoot(for: file) ?? start
        case .javascript, .typescript: return JSTesting.projectRoot(for: file)
        case .wasm: return start
        }
    }

    func nearest(_ markers: [String], from start: URL) -> URL? {
        let fm = FileManager.default
        var current = start
        while true {
            if markers.contains(where: { fm.fileExists(atPath: current.appendingPathComponent($0).path) }) { return current }
            let parent = current.deletingLastPathComponent()
            if current.path == "/" || parent.path == current.path || current.path == SharedPaths.realHomeDirectory.path { return nil }
            current = parent
        }
    }

    // MARK: Runner selection

    /// The runner auto-detection would pick for a project (ignores the user's choice).
    public func autoKind(for language: Language, projectRoot: URL, file: URL? = nil, text: String? = nil) -> TestRunnerKind {
        let fm = FileManager.default
        switch language {
        case .zig:
            return fm.fileExists(atPath: projectRoot.appendingPathComponent("build.zig").path) ? .zigBuild : .zigTest
        case .rust:
            return toolchain.cargoNextest() != nil ? .cargoNextest : .cargoTest
        case .kotlin:
            return fm.isExecutableFile(atPath: projectRoot.appendingPathComponent("gradlew").path) ? .gradleWrapper : .gradle
        case .cpp:
            return .ctest
        case .javascript, .typescript:
            let source = text ?? file.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
            return JSTesting.autoKind(file: file ?? projectRoot, text: source, projectRoot: projectRoot)
        case .wasm:
            if let file, WasmTesting.isScript(file.path) { return .wasmtimeWast }
            return tools.wasmtime() == nil ? .nodeWasm : .wasmtimeInvoke
        }
    }

    public func kind(for language: Language, projectRoot: URL, file: URL? = nil, text: String? = nil) -> TestRunnerKind {
        if language == .wasm, let file {
            // .wast scripts only run with `wasmtime wast`; text modules never do.
            let script = WasmTesting.isScript(file.path)
            if script { return .wasmtimeWast }
            if settings.testRunner(for: language) == .wasmtimeWast { return autoKind(for: language, projectRoot: projectRoot, file: file, text: text) }
        }
        if let chosen = settings.testRunner(for: language), chosen.supports(language) { return chosen }
        return autoKind(for: language, projectRoot: projectRoot, file: file, text: text)
    }

    public func executable(for kind: TestRunnerKind, projectRoot: URL) throws -> URL {
        if kind == .gradleWrapper {
            let wrapper = projectRoot.appendingPathComponent("gradlew")
            guard FileManager.default.isExecutableFile(atPath: wrapper.path) else {
                throw TestRunnerError.noProject("No executable ./gradlew in \(projectRoot.path). Choose “Gradle” as the runner or add the wrapper.")
            }
            return wrapper
        }
        if let custom = settings.testExecutablePath(for: kind.language), FileManager.default.isExecutableFile(atPath: custom),
           kind.isClassic || URL(fileURLWithPath: custom).lastPathComponent.hasPrefix(kind.toolName) {
            return URL(fileURLWithPath: custom)
        }
        let found: URL?
        let hint: String
        switch kind {
        case .zigBuild, .zigTest:
            found = toolchain.zig(); hint = "Install Zig (e.g. `mise use -g zig@latest`) or choose the zig binary in CrossKit settings."
        case .cargoTest, .cargoNextest:
            found = toolchain.cargo(); hint = "Install Rust with rustup (https://rustup.rs) or choose cargo in CrossKit settings."
        case .gradle:
            found = toolchain.gradle(); hint = "Install Gradle (e.g. `mise use -g gradle@latest`), add ./gradlew to the project, or choose gradle in CrossKit settings."
        case .gradleWrapper:
            found = nil; hint = ""
        case .ctest:
            found = tools.cmake(); hint = ToolFinder.cmakeHint + " CTest ships with CMake."
        case .vitest:
            found = tools.nodePackageBinary("vitest", projectRoot: projectRoot)
            hint = "Add it to the project (`npm install -D vitest`) or install it globally (`mise use -g npm:vitest`)."
        case .jest:
            found = tools.nodePackageBinary("jest", projectRoot: projectRoot)
            hint = "Add it to the project (`npm install -D jest`) or install it globally (`mise use -g npm:jest`)."
        case .nodeTest, .nodeWasm:
            found = tools.node(); hint = ToolFinder.nodeHint
        case .bunTest:
            found = tools.bun(); hint = "Install Bun (https://bun.sh or `mise use -g bun`)."
        case .wasmtimeInvoke, .wasmtimeWast:
            found = tools.wasmtime(); hint = ToolFinder.wasmtimeHint + " Or pick the Node.js harness runner in CrossKit settings."
        }
        guard let found else { throw TestRunnerError.toolNotFound(kind.toolName, hint: hint) }
        if kind == .cargoNextest, toolchain.cargoNextest() == nil {
            throw TestRunnerError.toolNotFound("cargo-nextest", hint: "Install it (`cargo install cargo-nextest` or `mise use -g cargo:cargo-nextest`) or pick “cargo test” in CrossKit settings.")
        }
        return found
    }

    // MARK: Commands

    public func command(language: Language, file: URL, scope: TestScope, tests: [DiscoveredTest],
                        cursorTest: DiscoveredTest?, text: String? = nil, coverage: Bool = false) throws -> TestCommand {
        let root = projectRoot(for: file, language: language)
        var kind = kind(for: language, projectRoot: root, file: file, text: text)
        if coverage, kind == .wasmtimeInvoke { kind = .nodeWasm }   // counters are read by the Node.js harness
        if coverage, !kind.supportsCoverage {
            throw TestRunnerError.noProject("Coverage is not available for \(kind.displayName). Choose another test runner in CrossKit settings.")
        }
        let exe = try executable(for: kind, projectRoot: root)
        var args: [String]
        var reports: String?
        switch kind {
        case .zigBuild:
            args = ["build", "test", "--summary", "all"]
        case .zigTest:
            args = ["test", file.path]
            if scope == .cursor, let test = cursorTest, !test.filter.isEmpty { args += ["--test-filter", test.filter] }
        case .cargoTest:
            if scope == .cursor, let test = cursorTest, let cargoArgs = test.cargoArgs, !cargoArgs.isEmpty {
                args = cargoArgs + ["--"] + (test.executableArgs ?? [test.filter, "--exact"])
            } else {
                args = ["test"] + TestDiscovery.rustTargetArguments(filePath: file.path, crateRoot: root)
                if scope == .cursor, let test = cursorTest {
                    args += ["--", test.filter, "--exact"]
                } else if let prefix = rustModulePrefix(file: file, root: root) {
                    args += ["--", prefix]
                }
            }
        case .cargoNextest:
            args = ["nextest", "run", "--no-fail-fast", "--status-level", "skip", "--final-status-level", "none"]
            if scope == .cursor, let test = cursorTest {
                if let package = test.cargoArgs.flatMap(packageArgument) { args += ["--package", package] }
                args += TestDiscovery.rustTargetArguments(filePath: file.path, crateRoot: root)
                args += ["-E", "test(=\(test.filter))"]
            } else {
                args += TestDiscovery.rustTargetArguments(filePath: file.path, crateRoot: root)
                if let prefix = rustModulePrefix(file: file, root: root) { args += [prefix] }
            }
        case .gradle, .gradleWrapper:
            let module = nearest(["build.gradle.kts", "build.gradle"], from: file.deletingLastPathComponent()) ?? root
            // Kotlin Multiplatform: the test task of the chosen target (jvmTest, macosArm64Test, …).
            var task = "test"
            var reportsDir = module.appendingPathComponent("build/test-results/test")
            if let project = KotlinProject.load(file: file, root: root), project.isMultiplatform {
                let target = try project.target(for: file, choice: kotlinTargetChoice(projectRoot: root))
                task = project.testTask(for: target)
                reportsDir = project.testReportsDirectory(for: target)
            }
            args = [gradleTask(module: module, root: root, task: task), "--console=plain"] + settings.gradleDaemonArguments
            if scope == .cursor, let test = cursorTest {
                args += ["--tests", test.filter]
            } else {
                let classes = Array(Set(tests.map { $0.className ?? $0.filter })).sorted()
                for name in classes { args += ["--tests", name] }
            }
            reports = reportsDir.path
        case .ctest, .vitest, .jest, .nodeTest, .bunTest, .wasmtimeInvoke, .nodeWasm, .wasmtimeWast:
            return try extendedCommand(kind: kind, executable: exe, language: language, file: file, root: root, scope: scope,
                                       tests: tests, cursorTest: cursorTest, coverage: coverage)
        }
        let extra = settings.testArguments(for: language)
        if kind == .cargoTest, let separator = args.firstIndex(of: "--") {
            // Extra arguments are for cargo (e.g. `--release`); everything after `--` goes to the test binary.
            args.insert(contentsOf: extra, at: separator)
        } else {
            args += extra
        }
        return TestCommand(kind: kind, executable: exe.path, arguments: args, workingDirectory: root.path,
                           environment: environment(language: language, executable: exe), reportsDirectory: reports)
    }

    private func rustModulePrefix(file: URL, root: URL) -> String? {
        let path = TestDiscovery.rustFileModulePath(filePath: file.path, crateRoot: root)
        return path.isEmpty ? nil : path.joined(separator: "::") + "::"
    }

    private func packageArgument(_ cargoArgs: [String]) -> String? {
        guard let i = cargoArgs.firstIndex(of: "--package"), i + 1 < cargoArgs.count else { return nil }
        return cargoArgs[i + 1]
    }

    private func gradleTask(module: URL, root: URL, task: String) -> String {
        let rootPath = root.standardizedFileURL.path
        let modulePath = module.standardizedFileURL.path
        guard modulePath.hasPrefix(rootPath + "/") else { return task }
        let relative = modulePath.dropFirst(rootPath.count + 1).split(separator: "/").joined(separator: ":")
        return ":\(relative):\(task)"
    }

    /// The project's launch configuration target, else the Kotlin target in settings.
    public func kotlinTargetChoice(projectRoot: URL) -> KotlinTargetChoice {
        // Launch configurations are saved under the canonical root (/private/tmp/…, see LaunchPlanner.plan),
        // while test requests arrive with symlinks resolved the Foundation way (/tmp/…).
        let canonical = LaunchPlanner.canonicalPath(projectRoot.path)
        if let raw = (settings.launchConfiguration(for: .kotlin, projectRoot: canonical)
                      ?? settings.launchConfiguration(for: .kotlin, projectRoot: projectRoot.path))?.kotlinTarget {
            return KotlinTargetChoice(raw)
        }
        return settings.kotlinTarget
    }

    func environment(language: Language, executable: URL) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        var paths = [executable.deletingLastPathComponent().path]
        if language == .rust, let nextest = toolchain.cargoNextest() { paths.append(nextest.deletingLastPathComponent().path) }
        if [.javascript, .typescript, .wasm].contains(language), let node = tools.node() { paths.append(node.deletingLastPathComponent().path) }
        if language == .cpp {
            if let cmake = tools.cmake() { paths.append(cmake.deletingLastPathComponent().path) }
            paths += tools.developerBinDirectories.map(\.path)
        }
        if language == .kotlin, let javaHome = toolchain.locator.javaHome() {
            if env["JAVA_HOME"] == nil { env["JAVA_HOME"] = javaHome.path }
            paths.append(javaHome.appendingPathComponent("bin").path)
        }
        let home = toolchain.locator.home
        paths += [home.appendingPathComponent(".cargo/bin").path, toolchain.locator.miseDataDirectory.appendingPathComponent("shims").path,
                  "/opt/homebrew/bin", "/usr/local/bin"]
        paths += (env["PATH"] ?? "").split(separator: ":").map(String.init)
        paths += ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()
        env["PATH"] = paths.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
        env["CARGO_TERM_COLOR"] = "never"
        env["NO_COLOR"] = "1"
        env["TERM"] = "dumb"
        return env
    }
}

/// Runs a test command in its own process group with a timeout, capturing combined output.
public enum TestExecutor {
    public struct Outcome: Sendable {
        public var exitCode: Int32?
        public var output: String
        public var duration: TimeInterval
        public var timedOut: Bool
    }

    public static let maxOutputBytes = 4 * 1024 * 1024

    public static func run(_ command: TestCommand, timeout: TimeInterval) async throws -> Outcome {
        try await run(executable: command.executable, arguments: command.arguments, workingDirectory: command.workingDirectory,
                      environment: command.environment, timeout: timeout)
    }

    /// Runs any tool the same way (own process group, timeout, combined output).
    public static func run(executable: String, arguments: [String], workingDirectory: String,
                           environment: [String: String] = ProcessInfo.processInfo.environment,
                           timeout: TimeInterval) async throws -> Outcome {
        let command = (executable: executable, arguments: arguments, environment: environment, workingDirectory: workingDirectory)
        let buffer = OutputBuffer(limit: maxOutputBytes)
        let streamsClosed = DispatchGroup()
        streamsClosed.enter(); streamsClosed.enter()
        let started = Date()
        let process = try ChildProcess(
            executable: command.executable, arguments: command.arguments, environment: command.environment,
            currentDirectory: command.workingDirectory,
            onStdout: { data in if data.isEmpty { streamsClosed.leave() } else { buffer.append(data) } },
            onStderr: { data in if data.isEmpty { streamsClosed.leave() } else { buffer.append(data) } },
            onExit: { _ in })
        process.closeStdin()
        let finished: Bool = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let finished = process.waitForExit(timeout: timeout)
                if !finished {
                    process.terminateGroup()
                    if !process.waitForExit(timeout: 3) { process.killGroup(); _ = process.waitForExit(timeout: 3) }
                }
                _ = streamsClosed.wait(timeout: .now() + 3)
                continuation.resume(returning: finished)
            }
        }
        return Outcome(exitCode: process.terminationStatus, output: buffer.string,
                       duration: Date().timeIntervalSince(started), timedOut: !finished)
    }
}

final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let limit: Int
    private var truncated = false

    init(limit: Int) { self.limit = limit }

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        if data.count + chunk.count > limit {
            data.append(chunk.prefix(max(0, limit - data.count)))
            truncated = true
        } else {
            data.append(chunk)
        }
    }

    var string: String {
        lock.lock(); defer { lock.unlock() }
        let text = String(decoding: data, as: UTF8.self)
        return truncated ? text + "\n… output truncated …" : text
    }
}

/// Discovery + run orchestration used by the bridge handler.
public struct TestService: Sendable {
    public var resolver: TestRunnerResolver

    public init(resolver: TestRunnerResolver) {
        self.resolver = resolver
    }

    public func discover(_ language: Language, file: URL, text: String) -> [DiscoveredTest] {
        TestDiscovery.discover(language, text: text, filePath: file.path, root: resolver.projectRoot(for: file, language: language))
    }

    public func run(_ language: Language, file: URL, text: String, scope: TestScope, cursorLine: Int,
                    tests: [DiscoveredTest]) async throws -> TestRunResult {
        try await execute(language, file: file, text: text, scope: scope, cursorLine: cursorLine, tests: tests, coverage: false).run
    }

    /// Runs the tests and returns the command too (its coverage artifacts when `coverage` is set).
    public func execute(_ language: Language, file: URL, text: String, scope: TestScope, cursorLine: Int,
                        tests: [DiscoveredTest], coverage: Bool) async throws -> (run: TestRunResult, command: TestCommand) {
        guard !tests.isEmpty else { throw TestRunnerError.noTests(file.lastPathComponent) }
        var cursorTest: DiscoveredTest?
        if scope == .cursor {
            guard let test = TestDiscovery.test(at: cursorLine, in: tests) else { throw TestRunnerError.noTestAtCursor }
            cursorTest = test
        }
        let command = try resolver.command(language: language, file: file, scope: scope, tests: tests, cursorTest: cursorTest,
                                           text: text, coverage: coverage)
        let started = Date()
        let outcome = try await TestExecutor.run(command, timeout: resolver.settings.testTimeout)
        var results = TestResultParser.parse(kind: command.kind, output: outcome.output,
                                             reportsDirectory: command.reportsDirectory, since: started,
                                             reportFile: command.reportFile)
        if command.kind == .wasmtimeWast {
            results = WasmTesting.parseWast(outcome.output, exitCode: outcome.exitCode, tests: tests)
        }
        if command.kind == .zigBuild {
            // zig build only names failing tests; tests of this file that did not fail passed if the run executed.
            let ran = outcome.exitCode == 0 || !results.isEmpty || TestResultParser.zigBuildCounts(outcome.output) != nil
            if ran {
                let failed = Set(results.map(\.name))
                for test in tests where !failed.contains(test.filter) {
                    results.append(TestCaseResult(name: test.filter, status: .passed))
                }
            }
        }
        results = results.map { result in
            var result = result
            if let match = tests.first(where: { Self.matches(result.name, $0) }) {
                result.file = file.path
                result.line = match.line
            }
            return result
        }
        if let cursorTest {
            let only = results.filter { Self.matches($0.name, cursorTest) }
            if !only.isEmpty { results = only }
        }
        var run = TestRunResult(language: language, runner: command.kind, scope: scope, command: command.display,
                                workingDirectory: command.workingDirectory, filePath: file.path, startedAt: started,
                                duration: outcome.duration, exitCode: outcome.exitCode, timedOut: outcome.timedOut,
                                tests: results, output: outcome.output)
        let disk = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        // Compare without any CrossKit annotations (test markers, code lenses, inlay hints, ErrorLens).
        if disk.trimmingCharacters(in: .whitespacesAndNewlines) != InlineAnnotations.cleanText(text).trimmingCharacters(in: .whitespacesAndNewlines) {
            run.warning = "The editor buffer has unsaved changes; tests ran against the saved file."
        }
        return (run, command)
    }

    static func matches(_ resultName: String, _ test: DiscoveredTest) -> Bool {
        if let pattern = test.matchPattern, resultName.range(of: pattern, options: .regularExpression) != nil { return true }
        let filter = test.filter
        if resultName == filter || resultName == test.name && !test.name.isEmpty { return true }
        if !filter.isEmpty, resultName.hasSuffix("::" + filter) || resultName.hasSuffix("." + filter) { return true }
        return false
    }

    static func withoutTestMarkers(_ text: String) -> String {
        text.components(separatedBy: "\n").filter { !EditorCommandEngine.isTestMarker($0) }.joined(separator: "\n")
    }
}
