import Foundation

/// Why a launch plan is made.
public enum LaunchPurpose: String, Codable, Sendable {
    /// Build, then start under a debugger with a breakpoint.
    case debug
    /// Build, then run without a debugger.
    case run
    /// Only build (Build Project).
    case build
}

/// Turns "debug this file / this test" into a concrete LaunchPlan, creating and saving the
/// project's LaunchConfiguration the first time.
public struct LaunchPlanner: Sendable {
    public var settings: SettingsStore
    public var resolver: TestRunnerResolver
    public var debuggers: DebuggerLocator
    /// Where loose-file debug builds and session files go.
    public var workDirectory: URL

    public init(settings: SettingsStore, resolver: TestRunnerResolver, debuggers: DebuggerLocator = DebuggerLocator(),
                workDirectory: URL = SharedPaths.debugDirectory) {
        self.settings = settings
        self.resolver = resolver
        self.debuggers = debuggers
        self.workDirectory = workDirectory
    }

    public func debuggerKind(for language: Language) -> DebuggerKind {
        settings.debugger(for: language) ?? debuggers.autoKind(for: language)
    }

    public func debuggerPath(for kind: DebuggerKind) throws -> URL {
        if let custom = settings.debuggerPath(for: kind), FileManager.default.isExecutableFile(atPath: custom) {
            return URL(fileURLWithPath: custom)
        }
        guard let found = debuggers.find(kind) else {
            throw DebugError.debuggerNotFound(kind.toolName, hint: DebuggerLocator.installHint(kind))
        }
        return found
    }

    /// Loads the saved configuration or creates (and saves) the default one.
    public func configuration(language: Language, projectRoot: URL) -> LaunchConfiguration {
        if let saved = settings.launchConfiguration(for: language, projectRoot: projectRoot.path) { return saved }
        let created = LaunchConfiguration(language: language, projectRoot: projectRoot.path)
        settings.saveLaunchConfiguration(created)
        return created
    }

    public func plan(language: Language, file original: URL, text: String, cursorLine: Int, target: DebugTarget,
                     purpose: LaunchPurpose = .debug) throws -> LaunchPlan {
        // Compilers record the path they were given in the debug info; build and set breakpoints with the
        // canonical path (/private/tmp/…, which `resolvingSymlinksInPath` would strip) so they always match.
        let file = URL(fileURLWithPath: Self.canonicalPath(original.path))
        let root = resolver.projectRoot(for: file, language: language)
        let config = configuration(language: language, projectRoot: root)

        // Kotlin: the target (JVM or Kotlin/Native) decides the debugger family.
        var kotlinTarget: (project: KotlinProject, target: KotlinTargetInfo)?
        if language == .kotlin {
            kotlinTarget = try resolveKotlinTarget(file: file, root: root, config: config)
        }
        let native = kotlinTarget.map { $0.target.platform == .native } ?? (language != .kotlin)
        let kind = native && language == .kotlin
            ? (settings.kotlinNativeDebugger ?? debuggers.autoKind(for: .zig))
            : debuggerKind(for: language)
        // Running and building need no debugger.
        let debugger = purpose == .debug ? try debuggerPath(for: kind).path : ""
        let breakpoint = Breakpoint(file: file.path, line: cursorLine)
        var plan = LaunchPlan(language: language, target: target, debugger: kind, debuggerPath: debugger,
                              projectRoot: root.path, build: [], programSource: .path(config.program), arguments: config.arguments,
                              environment: config.environment, workingDirectory: config.effectiveWorkingDirectory,
                              breakpoints: purpose == .debug ? [breakpoint] : [], title: file.lastPathComponent, jdwpPort: settings.jdwpPort)
        plan.kotlinTarget = kotlinTarget?.target

        var test: DiscoveredTest?
        if target == .test {
            let tests = TestDiscovery.discover(language, text: text, filePath: file.path, root: root)
            guard let found = TestDiscovery.test(at: cursorLine, in: tests) else { throw DebugError.noTestAtCursor }
            test = found
            plan.title = found.name.isEmpty ? "unnamed test" : found.name
            plan.arguments = config.testArguments
        } else if !config.program.isEmpty, language != .kotlin, purpose != .build {
            // A user-chosen program: launch it as is.
            return plan
        } else if purpose != .build, config.program.isEmpty, !TestDiscovery.hasMain(language, text: text),
                  language != .wasm, !(language == .cpp && CppTesting.projectRoot(for: file) != nil),
                  !(language == .rust && rustHasBinary(root)), !(kotlinTarget?.target.platform == .native) {
            throw DebugError.noMain(file.lastPathComponent)
        }

        switch language {
        case .zig: try planZig(&plan, file: file, root: root, test: test, config: config, purpose: purpose, text: text)
        case .rust: try planRust(&plan, file: file, root: root, test: test, config: config, text: text, purpose: purpose)
        case .kotlin:
            try planKotlin(&plan, file: file, root: root, test: test, config: config, text: text, cursorLine: cursorLine,
                           project: kotlinTarget!.project, kotlinTarget: kotlinTarget!.target, purpose: purpose)
        case .cpp: try planCpp(&plan, file: file, root: root, test: test, config: config, text: text, purpose: purpose)
        case .javascript, .typescript: try planScript(&plan, file: file, root: root, test: test, config: config, text: text, purpose: purpose)
        case .wasm: try planWasm(&plan, file: file, root: root, test: test, config: config, text: text, purpose: purpose)
        }
        return plan
    }

    /// The launch configuration's Kotlin target, else the one in settings.
    public func kotlinTargetChoice(config: LaunchConfiguration) -> KotlinTargetChoice {
        if let raw = config.kotlinTarget { return KotlinTargetChoice(raw) }
        return settings.kotlinTarget
    }

    public func resolveKotlinTarget(file: URL, root: URL, config: LaunchConfiguration) throws -> (project: KotlinProject, target: KotlinTargetInfo) {
        guard let project = KotlinProject.load(file: file, root: root) else {
            throw DebugError.noProgram("Kotlin needs a Gradle project (build.gradle(.kts)) so CrossKit can compile it.")
        }
        let target = try project.target(for: file, choice: kotlinTargetChoice(config: config))
        return (project, target)
    }

    /// realpath(3): resolves every symlink, keeping /private.
    public static func canonicalPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    // MARK: Zig

    private func planZig(_ plan: inout LaunchPlan, file: URL, root: URL, test: DiscoveredTest?, config: LaunchConfiguration,
                         purpose: LaunchPurpose, text: String) throws {
        // A zig binary chosen in settings wins over detection, as for tests and cargo.
        guard let zig = settings.testExecutablePath(for: .zig) ?? resolver.toolchain.zig().map(\.path) else {
            throw DebugError.toolNotFound("zig", hint: "Install Zig (e.g. `mise use -g zig@latest`) or choose the zig binary in CrossKit settings.")
        }
        let stem = file.deletingPathExtension().lastPathComponent
        let out = buildDirectory(for: root)
        if let test {
            // A dedicated test binary containing only the selected test.
            let binary = out.appendingPathComponent("\(stem)-test").path
            var args = [zig, "test", file.path]
            if !test.filter.isEmpty { args += ["--test-filter", test.filter] }
            args += ["--test-no-exec", "-femit-bin=\(binary)"]
            plan.build = [args]
            plan.programSource = .path(binary)
        } else if FileManager.default.fileExists(atPath: root.appendingPathComponent("build.zig").path) {
            if config.buildBeforeLaunch || purpose == .build { plan.build = [[zig, "build", "install"]] }
            plan.programSource = .zigInstall(preferredName: root.lastPathComponent)
        } else if purpose == .build, !TestDiscovery.hasMain(.zig, text: text) {
            // A library file: compile it to an object to check it builds.
            let object = out.appendingPathComponent("\(stem).o").path
            plan.build = [[zig, "build-obj", file.path, "-femit-bin=\(object)"]]
            plan.programSource = .path(object)
        } else {
            let binary = out.appendingPathComponent(stem).path
            plan.build = [[zig, "build-exe", file.path, "-femit-bin=\(binary)"]]
            plan.programSource = .path(binary)
        }
    }

    // MARK: Rust

    private func rustHasBinary(_ root: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: root.appendingPathComponent("src/main.rs").path)
            || fm.fileExists(atPath: root.appendingPathComponent("src/bin").path)
    }

    private func planRust(_ plan: inout LaunchPlan, file: URL, root: URL, test: DiscoveredTest?, config: LaunchConfiguration, text: String,
                          purpose: LaunchPurpose) throws {
        guard let cargo = settings.testExecutablePath(for: .rust) ?? resolver.toolchain.cargo()?.path else {
            throw DebugError.toolNotFound("cargo", hint: "Install Rust with rustup (https://rustup.rs) or choose cargo in CrossKit settings.")
        }
        var targetArgs = TestDiscovery.rustTargetArguments(filePath: file.path, crateRoot: root)
        if purpose == .build, test == nil {
            // Build Project: every target of the crate (library and binaries).
            plan.build = [[cargo, "build", "--message-format=json-render-diagnostics"]]
            plan.programSource = .cargoArtifact(target: nil, test: false)
            return
        }
        if let test {
            plan.build = [[cargo, "test", "--no-run", "--message-format=json-render-diagnostics"] + targetArgs]
            plan.programSource = .cargoArtifact(target: nil, test: true)
            plan.arguments = [test.filter, "--exact", "--nocapture", "--test-threads=1"] + config.testArguments
        } else {
            if targetArgs.first == "--lib" || targetArgs.isEmpty || !TestDiscovery.hasMain(.rust, text: text) {
                // A library file: debug the crate's binary with a breakpoint in this file.
                targetArgs = ["--bins"]
            }
            // Always built: the executable path comes from cargo's JSON output.
            plan.build = [[cargo, "build", "--message-format=json-render-diagnostics"] + targetArgs]
            plan.programSource = .cargoArtifact(target: targetArgs.count == 2 ? targetArgs[1] : nil, test: false)
        }
    }

    /// Picks the executable from `cargo build/test --message-format=json` output.
    public static func cargoExecutable(fromJSONLines output: String, target: String?, test: Bool, sourceFile: String?) -> String? {
        var candidates: [(path: String, name: String, srcPath: String)] = []
        for line in output.split(separator: "\n") where line.hasPrefix("{") && line.contains("\"compiler-artifact\"") {
            guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)),
                  let executable = value["executable"]?.stringValue,
                  (value["profile"]?["test"]?.boolValue ?? false) == test else { continue }
            candidates.append((executable, value["target"]?["name"]?.stringValue ?? "", value["target"]?["src_path"]?.stringValue ?? ""))
        }
        if let target, let match = candidates.last(where: { $0.name == target }) { return match.path }
        if let sourceFile, let match = candidates.last(where: { $0.srcPath == sourceFile }) { return match.path }
        return candidates.last?.path
    }

    // MARK: Kotlin

    private func planKotlin(_ plan: inout LaunchPlan, file: URL, root: URL, test: DiscoveredTest?, config: LaunchConfiguration,
                            text: String, cursorLine: Int, project: KotlinProject, kotlinTarget: KotlinTargetInfo,
                            purpose: LaunchPurpose) throws {
        let gradle = try gradleExecutable(root: root)
        let prefix = gradleProjectPath(module: project.moduleDirectory, root: root)
        let initScript = try writeGradleInitScript()
        // Debug sessions use no Gradle or Kotlin compiler daemons, so nothing outlives them.
        let daemon = purpose == .debug ? ["--no-daemon", "-Pkotlin.compiler.execution.strategy=in-process"] : settings.gradleDaemonArguments
        let extra = daemon + settings.testArguments(for: .kotlin)
        let targetProperty = project.isMultiplatform ? ["-Pcrosskit.target=\(kotlinTarget.name)"] : []
        plan.title += " · \(kotlinTarget.displayName)"

        switch kotlinTarget.platform {
        case .other:
            if purpose == .build {
                plan.build = [[gradle, "\(prefix)\(kotlinTarget.name)MainClasses", "--console=plain"] + extra]
                plan.programSource = .path("")
                return
            }
            throw KotlinTargetError.notRunnable("CrossKit cannot run or debug the \(kotlinTarget.name) target. Pick the JVM or a Kotlin/Native target for this Mac in CrossKit settings or the launch configuration.")
        case .native:
            if purpose != .build, !kotlinTarget.runsOnHost {
                throw KotlinTargetError.notRunnable("\(kotlinTarget.name) binaries do not run on this Mac. Pick \(KotlinProject.hostNativePreset) or the JVM target in CrossKit settings or the launch configuration.")
            }
            if let test {
                plan.build = [[gradle, "\(prefix)\(project.linkTestTask(for: kotlinTarget))", "--console=plain"] + extra]
                plan.programSource = .path(project.nativeTestBinary(for: kotlinTarget).path)
                // The Kotlin/Native test runner filters with `--ktest_filter=<package.Class.method>`.
                plan.arguments = ["--ktest_filter=\(test.filter)"] + config.testArguments
            } else if purpose == .build && !project.declaresNativeExecutable {
                plan.build = [[gradle, "\(prefix)compileKotlin\(kotlinTarget.taskSuffix)", "--console=plain"] + extra]
                plan.programSource = .path("")
            } else {
                guard project.declaresNativeExecutable else {
                    throw DebugError.noProgram("\(project.moduleDirectory.lastPathComponent) declares no Kotlin/Native executable. Add `binaries { executable { entryPoint = \"<package>.main\" } }` to the \(kotlinTarget.name) target.")
                }
                plan.build = [[gradle, "\(prefix)\(project.linkExecutableTask(for: kotlinTarget))", "--console=plain"] + extra]
                plan.programSource = config.program.isEmpty
                    ? .nativeExecutable(directory: project.nativeExecutableDirectory(for: kotlinTarget).path)
                    : .path(config.program)
            }
            if let konan = KotlinProject.konanLLDBScript(home: resolver.toolchain.locator.home) {
                plan.lldbInitCommands = ["command script import \(DebugService.lldbQuote(konan.path))"]
            }
        case .jvm:
            // Breakpoint class: the innermost class/object around the cursor, or the file facade class.
            plan.jvmBreakpointClass = TestDiscovery.kotlinClass(atLine: cursorLine, text: text, fileName: file.lastPathComponent)
            if let test {
                plan.build = []
                plan.programSource = .gradleTest(command: [gradle, "\(prefix)\(project.testTask(for: kotlinTarget))", "--tests", test.filter,
                                                           "--rerun", "--console=plain", "-I", initScript.path] + extra)
                plan.arguments = []
            } else {
                plan.build = [[gradle, "\(prefix)crossKitClasspath", "-q", "--console=plain", "-I", initScript.path] + targetProperty + extra]
                // The configuration's "program" overrides the main class for Kotlin.
                let mainClass = config.program.isEmpty ? TestDiscovery.kotlinFileClass(text: text, fileName: file.lastPathComponent) : config.program
                plan.programSource = .jvmMain(mainClass: mainClass)
            }
        }
    }

    func gradleExecutable(root: URL) throws -> String {
        let fm = FileManager.default
        let hasGradle = ["settings.gradle.kts", "settings.gradle", "build.gradle.kts", "build.gradle"]
            .contains { fm.fileExists(atPath: root.appendingPathComponent($0).path) }
        guard hasGradle else {
            throw DebugError.noProgram("Kotlin needs a Gradle project (settings.gradle(.kts) or build.gradle(.kts)) so CrossKit can compile it and get the classpath.")
        }
        let runner = resolver.kind(for: .kotlin, projectRoot: root)
        do { return try resolver.executable(for: runner, projectRoot: root).path } catch {
            throw DebugError.toolNotFound("gradle", hint: "Install Gradle (e.g. `mise use -g gradle@latest`), add ./gradlew to the project, or choose gradle in CrossKit settings.")
        }
    }

    func gradleProjectPath(module: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let modulePath = module.standardizedFileURL.path
        guard modulePath.hasPrefix(rootPath + "/") else { return "" }
        return ":" + modulePath.dropFirst(rootPath.count + 1).split(separator: "/").joined(separator: ":") + ":"
    }

    public static let gradleInitScript = """
    // Written by CrossKit. Adds `crossKitClasspath`, which compiles a JVM target and prints its runtime
    // classpath (-Pcrosskit.target=<name> picks the Kotlin Multiplatform target), and puts a JDWP agent
    // into test JVMs when -Pcrosskit.jdwp=<host:port> is given. Build files are not changed.
    allprojects {
        afterEvaluate { p ->
            def targets = null
            if (p.plugins.hasPlugin('org.jetbrains.kotlin.multiplatform')) {
                try { targets = p.extensions.getByName('kotlin').targets } catch (ignored) { }
            }
            if (targets != null) {
                def wanted = p.findProperty('crosskit.target')
                def target = wanted != null ? targets.findByName(wanted) : targets.find { it.platformType.name() == 'jvm' }
                if (target != null && target.platformType.name() == 'jvm') {
                    def main = target.compilations.getByName('main')
                    p.tasks.register('crossKitClasspath') {
                        dependsOn main.compileAllTaskName
                        doLast { println 'CROSSKIT_CLASSPATH=' + (main.output.allOutputs + main.runtimeDependencyFiles).asPath }
                    }
                }
            } else {
                def sets = p.extensions.findByName('sourceSets')
                if (sets != null && sets.findByName('main') != null) {
                    p.tasks.register('crossKitClasspath') {
                        dependsOn 'classes'
                        doLast { println 'CROSSKIT_CLASSPATH=' + sets.main.runtimeClasspath.asPath }
                    }
                }
            }
            def address = p.findProperty('crosskit.jdwp')
            if (address != null) {
                p.tasks.withType(Test).configureEach {
                    jvmArgs "-agentlib:jdwp=transport=dt_socket,server=y,suspend=y,address=${address}"
                    maxParallelForks = 1
                    forkEvery = 0
                }
            }
        }
    }

    """

    func writeGradleInitScript() throws -> URL {
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        let url = workDirectory.appendingPathComponent("crosskit-init.gradle")
        if (try? String(contentsOf: url, encoding: .utf8)) != Self.gradleInitScript {
            try Self.gradleInitScript.write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }

    func buildDirectory(for root: URL) -> URL {
        let name = "\(root.lastPathComponent)-\(String(UInt(bitPattern: stableHash(root.path)), radix: 36))"
        let dir = workDirectory.appendingPathComponent("builds/\(name)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func stableHash(_ s: String) -> Int {
        var h: UInt64 = 1469598103934665603
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return Int(truncatingIfNeeded: h)
    }
}
