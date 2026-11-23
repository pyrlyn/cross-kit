import Foundation

public enum CoverageError: Error, LocalizedError, Equatable {
    case notSupported(String)
    case noData(String)
    case toolFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notSupported(let detail), .noData(let detail), .toolFailed(let detail): return detail
        }
    }
}

/// Runs a file's tests with coverage and turns the raw data into a `CoverageReport`:
/// llvm-profdata + llvm-cov for C++ (CMake), LCOV from node:test / Vitest / Jest / bun for JavaScript and
/// TypeScript, and counters of an instrumented module for WebAssembly text.
public struct CoverageService: Sendable {
    public var tests: TestService

    public init(tests: TestService) {
        self.tests = tests
    }

    public var tools: ToolFinder { tests.resolver.tools }

    public static func supports(_ language: Language) -> Bool { Feature.coverage.applies(to: language) }

    public func run(_ language: Language, file: URL, text: String, scope: TestScope, cursorLine: Int) async throws -> CoverageReport {
        guard Self.supports(language) else {
            throw CoverageError.notSupported("Coverage is available for C++, JavaScript, TypeScript and WebAssembly.")
        }
        let discovered = tests.discover(language, file: file, text: text)
        let (run, command) = try await tests.execute(language, file: file, text: text, scope: scope, cursorLine: cursorLine,
                                                     tests: discovered, coverage: true)
        guard let artifacts = command.coverage else {
            throw CoverageError.notSupported("\(command.kind.displayName) does not collect coverage.")
        }
        defer {
            // Raw data of this run only (CrossKit's own scratch directory).
            if let scratch = artifacts.scratchDirectory { try? FileManager.default.removeItem(atPath: scratch) }
        }
        var files: [FileCoverage]
        var warning: String?
        do {
            files = try await collect(artifacts, output: run.output)
        } catch let error as CoverageError {
            if case .noData(let detail) = error, !run.succeeded {
                throw CoverageError.noData(detail + " The test run failed: \(run.summary)\n\n" + String(run.output.suffix(2000)))
            }
            throw error
        }
        let root = URL(fileURLWithPath: artifacts.baseDirectory).standardizedFileURL.path
        let canonicalRoot = LaunchPlanner.canonicalPath(root)
        files = files.filter { file in
            let path = file.path
            return path.hasPrefix(root + "/") || path.hasPrefix(canonicalRoot + "/")
        }
        if files.isEmpty { warning = "No covered source files inside \(root)." }
        if !run.succeeded { warning = [warning, "Some tests failed: \(run.summary)"].compactMap { $0 }.joined(separator: " ") }
        return CoverageReport(language: language, tool: command.kind.displayName, projectRoot: root, files: files,
                              testRun: run, warning: warning)
    }

    func collect(_ artifacts: CoverageArtifacts, output: String) async throws -> [FileCoverage] {
        switch artifacts.format {
        case .lcov:
            guard let text = try? String(contentsOfFile: artifacts.path, encoding: .utf8) else {
                throw CoverageError.noData("The test runner wrote no LCOV report (\(artifacts.path)).")
            }
            return LCOVParser.parse(text, baseDirectory: artifacts.baseDirectory)
        case .watCounters:
            guard let data = FileManager.default.contents(atPath: artifacts.path),
                  let probes = try? JSONDecoder().decode([WatProbe].self, from: data), let source = artifacts.sourceFile else {
                throw CoverageError.noData("Missing WebAssembly coverage probes.")
            }
            let counters = WasmHarness.parse(output).counters
            guard !counters.isEmpty || probes.isEmpty else {
                throw CoverageError.noData("The WebAssembly harness reported no coverage counters.")
            }
            let text = (try? String(contentsOfFile: source, encoding: .utf8)) ?? ""
            return [WatCoverage.fileCoverage(path: source, text: text, probes: probes, counters: counters)]
        case .llvmProfiles:
            return try await collectLLVM(artifacts)
        }
    }

    // MARK: LLVM

    func collectLLVM(_ artifacts: CoverageArtifacts) async throws -> [FileCoverage] {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: artifacts.path)
        let profiles = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".profraw") }.sorted()
            .map { dir.appendingPathComponent($0).path }
        guard !profiles.isEmpty else {
            throw CoverageError.noData("The tests wrote no .profraw files (\(dir.path)).")
        }
        let compiler = artifacts.compiler.map { URL(fileURLWithPath: $0) }
        guard let profdata = tools.llvmTool("llvm-profdata", matching: compiler),
              let cov = tools.llvmTool("llvm-cov", matching: compiler) else {
            throw CoverageError.toolFailed("llvm-profdata/llvm-cov were not found. They ship with Xcode (`xcrun llvm-cov`) and LLVM (`mise use -g llvm`).")
        }
        let merged = dir.appendingPathComponent("merged.profdata")
        try await runTool(profdata.path, ["merge", "-sparse"] + profiles + ["-o", merged.path], in: dir)
        let objects = artifacts.buildDirectory.map { Self.instrumentedObjects(in: URL(fileURLWithPath: $0)) } ?? []
        guard let first = objects.first else {
            throw CoverageError.noData("No binaries found in the coverage build (\(artifacts.buildDirectory ?? "?")).")
        }
        let lcov = dir.appendingPathComponent("coverage.lcov")
        var args = ["export", "-format=lcov", "-instr-profile=\(merged.path)", first]
        for object in objects.dropFirst() { args += ["-object", object] }
        try await runTool(cov.path, args, in: dir, stdout: lcov)
        let text = (try? String(contentsOf: lcov, encoding: .utf8)) ?? ""
        return LCOVParser.parse(text, baseDirectory: artifacts.baseDirectory)
    }

    /// Mach-O executables and libraries of a CMake build tree (CMake's own probe binaries excluded).
    static func instrumentedObjects(in build: URL) -> [String] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: build, includingPropertiesForKeys: [.isRegularFileKey, .isExecutableKey],
                                             options: [.skipsHiddenFiles]) else { return [] }
        var objects: [String] = []
        for case let url as URL in enumerator {
            if url.lastPathComponent == "CMakeFiles" { enumerator.skipDescendants(); continue }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]), values.isRegularFile == true else { continue }
            let name = url.lastPathComponent
            let isLibrary = name.hasSuffix(".dylib") || name.hasSuffix(".so")
            guard isLibrary || fm.isExecutableFile(atPath: url.path) else { continue }
            if isMachO(url) { objects.append(url.path) }
        }
        return objects.sorted()
    }

    static func isMachO(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let magic = handle.readData(ofLength: 4)
        guard magic.count == 4 else { return false }
        let bytes = [UInt8](magic)
        let known: [[UInt8]] = [[0xcf, 0xfa, 0xed, 0xfe], [0xce, 0xfa, 0xed, 0xfe], [0xca, 0xfe, 0xba, 0xbe], [0x7f, 0x45, 0x4c, 0x46]]
        return known.contains(bytes)
    }

    @discardableResult
    func runTool(_ executable: String, _ arguments: [String], in directory: URL, stdout: URL? = nil) async throws -> String {
        var exe = executable
        var args = arguments
        if let stdout {
            let q = DebugService.shellQuote
            args = ["-c", ([executable] + arguments).map(q).joined(separator: " ") + " > " + q(stdout.path)]
            exe = "/bin/sh"
        }
        let outcome = try await TestExecutor.run(executable: exe, arguments: args, workingDirectory: directory.path, timeout: 300)
        guard outcome.exitCode == 0 else {
            throw CoverageError.toolFailed("\((executable as NSString).lastPathComponent) failed:\n\(outcome.output.suffix(3000))")
        }
        return outcome.output
    }
}

/// Maps WebAssembly probe counters onto source lines: a function's lines get its entry count; lines of an
/// `if` branch get the branch's count (until the next branch or the end of the function).
public enum WatCoverage {
    public static func fileCoverage(path: String, text: String, probes: [WatProbe], counters: [String: Int]) -> FileCoverage {
        let functions = WatSource.functions(text).filter { !$0.isImport }
        var lines: [Int: Int] = [:]
        var functionCoverage: [FunctionCoverage] = []
        let sourceLines = text.components(separatedBy: "\n")
        func isCode(_ line: Int) -> Bool {
            guard line < sourceLines.count else { return false }
            let trimmed = sourceLines[line].trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && !trimmed.hasPrefix(";;") && trimmed != ")"
        }
        for function in functions {
            guard let entry = probes.first(where: { $0.kind == .function && $0.line == function.startLine }) else { continue }
            let hits = counters[entry.globalName] ?? 0
            functionCoverage.append(FunctionCoverage(name: function.name ?? function.exports.first ?? "func[\(function.index)]",
                                                     line: function.startLine + 1, hits: hits))
            for line in function.startLine...function.endLine where isCode(line) { lines[line + 1] = hits }
            // Branches override the lines they start, up to the next probe inside the function.
            let branches = probes.filter { $0.kind != .function && $0.line >= function.startLine && $0.line <= function.endLine }
                .sorted { $0.line < $1.line }
            for (i, branch) in branches.enumerated() {
                var end = branchEnd(start: branch.line, function: function, lines: sourceLines)
                if i + 1 < branches.count { end = min(end, max(branch.line, branches[i + 1].line - 1)) }
                let count = counters[branch.globalName] ?? 0
                for line in branch.line...max(branch.line, end) where isCode(line) { lines[line + 1] = count }
            }
        }
        return FileCoverage(path: path, lines: lines, functions: functionCoverage)
    }

    /// Last line of a branch: folded `(then …)`/`(else …)` end where their parenthesis closes; flat branches end
    /// before the matching `else`/`end`.
    static func branchEnd(start: Int, function: WatSource.Function, lines: [String]) -> Int {
        let last = min(function.endLine, lines.count - 1)
        guard start <= last else { return start }
        let first = lines[start]
        if first.contains("(then") || first.contains("(else") {
            var depth = 0
            var opened = false
            for line in start...last {
                for ch in lines[line] {
                    if ch == "(" { depth += 1; opened = true } else if ch == ")" { depth -= 1 }
                }
                if opened && depth <= 0 { return line }
            }
            return last
        }
        var nesting = 0
        for line in start...last {
            let code = lines[line].components(separatedBy: ";;").first ?? ""
            var tokens = code.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "(" || $0 == ")" }).map(String.init)
            if line == start, let i = tokens.firstIndex(where: { $0 == "if" || $0 == "else" }) { tokens = Array(tokens[(i + 1)...]) }
            for token in tokens {
                switch token {
                case "block", "loop", "if": nesting += 1
                case "else" where nesting == 0: return max(start, line - 1)
                case "end":
                    if nesting == 0 { return line == start ? start : line - 1 }
                    nesting -= 1
                default: break
                }
            }
        }
        return last
    }
}
