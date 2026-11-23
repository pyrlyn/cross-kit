import Foundation

/// A Build Project or Run File invocation, shown in the host's Run window.
public struct ProgramRun: Codable, Equatable, Identifiable, Sendable {
    public enum Mode: String, Codable, Sendable { case build, run }
    public enum State: String, Codable, Sendable {
        case building, running, succeeded, failed, stopped

        public var isActive: Bool { self == .building || self == .running }
    }

    public var id: String
    public var mode: Mode
    public var title: String
    public var language: Language
    /// Kotlin target display name, e.g. "JVM" or "Native macosArm64".
    public var target: String?
    public var projectRoot: String
    /// Build commands and the program command line, as run.
    public var commands: [String]
    public var program: String?
    public var startedAt: Date
    public var finishedAt: Date?
    public var state: State
    public var exitCode: Int?
    public var output: String
    public var error: String?

    public var duration: TimeInterval { (finishedAt ?? Date()).timeIntervalSince(startedAt) }

    /// Alert text for the extension.
    public var summary: String {
        let what = mode == .build ? "Build" : "Run"
        let head: String
        switch state {
        case .building: head = "⋯ \(title): building"
        case .running: head = "▶ \(title) is still running (output in CrossKit › Run)"
        case .succeeded: head = "✓ \(what) succeeded: \(title) (\(String(format: "%.1f", duration))s)"
        case .stopped: head = "■ \(title) was stopped"
        case .failed:
            if let exitCode, mode == .run, error == nil { head = "✗ \(title) exited with code \(exitCode) (\(String(format: "%.1f", duration))s)" }
            else { head = "✗ \(what) failed: \(title)" }
        }
        var lines = [head]
        if let error { lines.append(error) }
        let tail = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.suffix(mode == .run ? 12 : 8)
        if !tail.isEmpty, error == nil { lines.append(""); lines += tail }
        return lines.joined(separator: "\n")
    }
}

/// Builds projects and runs programs without a debugger (Build Project, Run File at Cursor),
/// using the same plans as debugging, including the Kotlin target.
public final class RunService: @unchecked Sendable {
    public let planner: LaunchPlanner
    public var onChange: (@Sendable (ProgramRun) -> Void)?
    private let lock = NSLock()
    private var runs: [String: ProgramRun] = [:]
    private var processes: [String: ChildProcess] = [:]

    public init(planner: LaunchPlanner) {
        self.planner = planner
    }

    public func run(_ id: String) -> ProgramRun? { lock.withLock { runs[id] } }

    /// Every run this service knows about, oldest first.
    public var allRuns: [ProgramRun] { lock.withLock { runs.values.sorted { $0.startedAt < $1.startedAt } } }
    public var activeCount: Int { lock.withLock { runs.values.filter { $0.state.isActive }.count } }

    /// Builds the project (or the file's target) and reports the result.
    public func build(language: Language, file: URL, text: String) async throws -> ProgramRun {
        let (clean, line) = DebugService.matchSavedFile(file: file, text: text, line: 0)
        let plan = try planner.plan(language: language, file: file, text: clean, cursorLine: line, target: .file, purpose: .build)
        var run = start(plan: plan, mode: .build, language: language)
        let built = await executeBuild(plan: plan, run: &run)
        if built { update(run.id) { $0.state = .succeeded; $0.finishedAt = Date() } }
        return self.run(run.id) ?? run
    }

    /// Builds, then runs the file's program; waits up to `runWaitSeconds` for it to finish.
    public func runFile(language: Language, file: URL, text: String) async throws -> ProgramRun {
        let (clean, line) = DebugService.matchSavedFile(file: file, text: text, line: 0)
        var plan = try planner.plan(language: language, file: file, text: clean, cursorLine: line, target: .file, purpose: .run)
        plan.breakpoints = []
        var run = start(plan: plan, mode: .run, language: language)
        guard await executeBuild(plan: plan, run: &run) else { return self.run(run.id) ?? run }

        let program: String
        var arguments = plan.arguments
        var executable: String
        do {
            switch plan.programSource {
            case .path(let path):
                program = path
                executable = path
            case .cargoArtifact(let target, let test):
                guard let exe = LaunchPlanner.cargoExecutable(fromJSONLines: run.output, target: target, test: test, sourceFile: nil) else {
                    throw DebugError.noProgram("cargo built no executable for \(file.lastPathComponent). Add a binary target (src/main.rs) or set a program in the launch configuration.")
                }
                program = exe; executable = exe
            case .zigInstall(let preferred):
                let bin = URL(fileURLWithPath: plan.projectRoot).appendingPathComponent("zig-out/bin")
                let files = ((try? FileManager.default.contentsOfDirectory(atPath: bin.path)) ?? []).sorted()
                    .filter { FileManager.default.isExecutableFile(atPath: bin.appendingPathComponent($0).path) }
                guard let name = files.first(where: { $0 == preferred }) ?? files.first(where: { $0 == file.deletingPathExtension().lastPathComponent }) ?? files.first else {
                    throw DebugError.noProgram("`zig build install` produced no executable in zig-out/bin.")
                }
                program = bin.appendingPathComponent(name).path; executable = program
            case .nativeExecutable(let directory):
                guard let exe = KotlinProject.nativeExecutable(in: URL(fileURLWithPath: directory)) else {
                    throw DebugError.noProgram("The Kotlin/Native link task produced no .kexe in \(directory).")
                }
                program = exe.path; executable = exe.path
            case .jvmMain(let mainClass):
                guard let cpLine = run.output.split(separator: "\n").last(where: { $0.hasPrefix("CROSSKIT_CLASSPATH=") }) else {
                    throw DebugError.noProgram("Gradle did not report a runtime classpath. Is the Kotlin JVM or Multiplatform plugin applied in \(plan.projectRoot)?")
                }
                // The java chosen in settings (or detected), as for debugging.
                let java = try planner.debuggerPath(for: .jdb)
                program = mainClass
                executable = java.path
                arguments = ["-cp", String(cpLine.dropFirst("CROSSKIT_CLASSPATH=".count)), mainClass] + plan.arguments
                // The classpath line is noise in the program's output window.
                update(run.id) { r in r.output = r.output.split(separator: "\n", omittingEmptySubsequences: false)
                    .filter { !$0.hasPrefix("CROSSKIT_CLASSPATH=") }.joined(separator: "\n") }
            case .gradleTest, .ctestCommand:
                throw DebugError.noProgram("Run File runs programs, not tests. Use Run Test at Cursor.")
            case .cmakeTarget, .command:
                guard let resolved = try LaunchPlanner.resolveCommand(plan.programSource, plan: plan, inspector: nil) else {
                    throw DebugError.noProgram("Nothing to run in \(file.lastPathComponent).")
                }
                program = resolved.executable
                executable = resolved.executable
                arguments = resolved.arguments
            }
            guard FileManager.default.isExecutableFile(atPath: executable) else { throw DebugError.noProgram("Program not found: \(executable)") }
        } catch {
            update(run.id) { $0.state = .failed; $0.error = error.localizedDescription; $0.finishedAt = Date() }
            throw error
        }

        var env = planner.resolver.environment(language: language, executable: URL(fileURLWithPath: executable))
        for (k, v) in plan.environment { env[k] = v }
        let shown = ([executable] + arguments).map(DebugService.shellQuote).joined(separator: " ")
        update(run.id) { r in
            r.program = program
            r.commands.append(shown)
            r.state = .running
            r.output += "$ \(shown)\n"
        }
        let id = run.id
        let finished = DispatchSemaphore(value: 0)
        let process = try ChildProcess(
            executable: executable, arguments: arguments, environment: env, currentDirectory: plan.workingDirectory,
            onStdout: { [weak self] data in if !data.isEmpty { self?.append(id, data) } },
            onStderr: { [weak self] data in if !data.isEmpty { self?.append(id, data) } },
            onExit: { [weak self] code in
                self?.update(id) { r in
                    r.exitCode = Int(code)
                    r.finishedAt = Date()
                    if r.state == .running { r.state = code == 0 ? .succeeded : .failed }
                }
                self?.lock.withLock { _ = self?.processes.removeValue(forKey: id) }
                finished.signal()
            })
        process.closeStdin()
        // A quick program may already have exited (and its onExit run): registering it then would leave a
        // stale entry whose pid Stop / stopAll would later signal after it was reused.
        lock.withLock { if process.isRunning { processes[id] = process } }
        let wait = planner.settings.runWaitSeconds
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                _ = finished.wait(timeout: .now() + wait)
                // Give the output readers a moment to drain after exit.
                Thread.sleep(forTimeInterval: 0.2)
                continuation.resume()
            }
        }
        return self.run(id) ?? run
    }

    public func stop(_ id: String) {
        let process = lock.withLock { processes[id] }
        guard let process else { return }
        update(id) { if $0.state.isActive { $0.state = .stopped } }
        process.terminateGroup()
        DispatchQueue.global().async {
            if !process.waitForExit(timeout: 3) { process.killGroup() }
        }
    }

    public func stopAll() {
        let all = lock.withLock { Array(processes.keys) }
        for id in all { stop(id) }
        for id in all { _ = lock.withLock { processes[id] }?.waitForExit(timeout: 4) }
    }

    // MARK: Internals

    private func start(plan: LaunchPlan, mode: ProgramRun.Mode, language: Language) -> ProgramRun {
        let run = ProgramRun(id: UUID().uuidString, mode: mode, title: plan.title, language: language,
                             target: plan.kotlinTarget?.displayName, projectRoot: plan.projectRoot, commands: [], program: nil,
                             startedAt: Date(), finishedAt: nil, state: .building, exitCode: nil, output: "", error: nil)
        lock.withLock {
            runs[run.id] = run
            // Keep memory bounded (each run holds up to ~2 MB of output): drop the oldest finished runs.
            let finished = runs.values.filter { !$0.state.isActive }.sorted { $0.startedAt < $1.startedAt }
            for old in finished.prefix(max(0, finished.count - Self.maxFinishedRuns)) { runs.removeValue(forKey: old.id) }
        }
        onChange?(run)
        return run
    }

    /// Finished runs kept for `run(_:)` / `allRuns` (the host window shows at most 30).
    static let maxFinishedRuns = 30

    /// Runs the plan's build commands; on failure marks the run failed and returns false.
    private func executeBuild(plan: LaunchPlan, run: inout ProgramRun) async -> Bool {
        for command in plan.build {
            guard let exe = command.first else { continue }
            let shown = command.map(DebugService.shellQuote).joined(separator: " ")
            update(run.id) { r in r.commands.append(shown); r.output += "$ \(shown)\n" }
            let env = planner.resolver.environment(language: plan.language, executable: URL(fileURLWithPath: exe))
            do {
                let outcome = try await TestExecutor.run(
                    TestCommand(kind: .zigTest, executable: exe, arguments: Array(command.dropFirst()), workingDirectory: plan.projectRoot,
                                environment: env, reportsDirectory: nil),
                    timeout: planner.settings.testTimeout)
                update(run.id) { r in r.output += outcome.output + (outcome.output.hasSuffix("\n") ? "" : "\n") }
                if outcome.timedOut || outcome.exitCode != 0 {
                    let reason = outcome.timedOut ? "timed out" : "exited with \(outcome.exitCode.map(String.init) ?? "a signal")"
                    update(run.id) { r in
                        r.state = .failed
                        r.exitCode = outcome.exitCode.map(Int.init)
                        r.finishedAt = Date()
                        r.output += "Build command \(reason).\n"
                    }
                    run = self.run(run.id) ?? run
                    return false
                }
            } catch {
                update(run.id) { r in r.state = .failed; r.error = error.localizedDescription; r.finishedAt = Date() }
                run = self.run(run.id) ?? run
                return false
            }
        }
        run = self.run(run.id) ?? run
        return true
    }

    private func append(_ id: String, _ data: Data) {
        let text = String(decoding: data, as: UTF8.self)
        update(id) { r in
            r.output += text
            if r.output.utf8.count > 2_000_000 { r.output = String(r.output.suffix(1_000_000)) }
        }
    }

    private func update(_ id: String, _ change: (inout ProgramRun) -> Void) {
        let snapshot: ProgramRun? = lock.withLock {
            guard var run = runs[id] else { return nil }
            change(&run)
            runs[id] = run
            return run
        }
        if let snapshot { onChange?(snapshot) }
    }
}
