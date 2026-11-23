import Foundation

public enum TestStatus: String, Codable, Sendable {
    case passed, failed, skipped
}

public enum TestScope: String, Codable, Sendable {
    case file, cursor
}

/// A test found in a source file (by CrossKit's own discovery or rust-analyzer runnables).
public struct DiscoveredTest: Codable, Equatable, Sendable {
    /// Display name, e.g. `adds`, `add works`, `computes answer`.
    public var name: String
    /// Identifier the runner filters on: `tests::adds` (Rust), `add works` (Zig), `pkg.CalcTest.adds` (Kotlin).
    public var filter: String
    /// 0-based line of the test declaration (the `fn`/`test`/`fun` line).
    public var line: Int
    /// Rust: runner arguments supplied by rust-analyzer (`experimental/runnables`).
    public var cargoArgs: [String]?
    public var executableArgs: [String]?
    /// Kotlin: fully qualified class containing the test.
    public var className: String?
    /// Regular expression (ICU) matching the runner's result names for this test, when they are not simply
    /// `filter` (C++ parameterized/typed tests, JavaScript names with `%s` placeholders).
    public var matchPattern: String?

    public init(name: String, filter: String, line: Int, cargoArgs: [String]? = nil, executableArgs: [String]? = nil,
                className: String? = nil, matchPattern: String? = nil) {
        self.name = name
        self.filter = filter
        self.line = line
        self.cargoArgs = cargoArgs
        self.executableArgs = executableArgs
        self.className = className
        self.matchPattern = matchPattern
    }
}

public struct TestCaseResult: Codable, Equatable, Identifiable, Sendable {
    public var name: String
    public var status: TestStatus
    public var duration: TimeInterval?
    public var output: String?
    public var file: String?
    public var line: Int?

    public var id: String { name }

    public init(name: String, status: TestStatus, duration: TimeInterval? = nil, output: String? = nil,
                file: String? = nil, line: Int? = nil) {
        self.name = name
        self.status = status
        self.duration = duration
        self.output = output
        self.file = file
        self.line = line
    }
}

public struct TestRunResult: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var language: Language
    public var runner: TestRunnerKind
    public var scope: TestScope
    public var command: String
    public var workingDirectory: String
    public var filePath: String?
    public var startedAt: Date
    public var duration: TimeInterval
    public var exitCode: Int32?
    public var timedOut: Bool
    public var tests: [TestCaseResult]
    public var output: String
    public var warning: String?

    public init(id: UUID = UUID(), language: Language, runner: TestRunnerKind, scope: TestScope, command: String,
                workingDirectory: String, filePath: String? = nil, startedAt: Date = Date(), duration: TimeInterval = 0,
                exitCode: Int32? = nil, timedOut: Bool = false, tests: [TestCaseResult] = [], output: String = "",
                warning: String? = nil) {
        self.id = id
        self.language = language
        self.runner = runner
        self.scope = scope
        self.command = command
        self.workingDirectory = workingDirectory
        self.filePath = filePath
        self.startedAt = startedAt
        self.duration = duration
        self.exitCode = exitCode
        self.timedOut = timedOut
        self.tests = tests
        self.output = output
        self.warning = warning
    }

    public var passed: Int { tests.filter { $0.status == .passed }.count }
    public var failed: Int { tests.filter { $0.status == .failed }.count }
    public var skipped: Int { tests.filter { $0.status == .skipped }.count }

    /// True when the runner exited 0 and no test failed.
    public var succeeded: Bool { !timedOut && exitCode == 0 && failed == 0 }

    public var summary: String {
        var text: String
        if tests.isEmpty {
            text = succeeded ? "run succeeded (no per-test results)" : "run failed (exit code \(exitCode.map(String.init) ?? "?"))"
        } else {
            text = "\(passed) passed, \(failed) failed"
            if skipped > 0 { text += ", \(skipped) skipped" }
            if failed == 0 && !succeeded { text += " — runner exited with code \(exitCode.map(String.init) ?? "?")" }
        }
        if timedOut { text += " — timed out" }
        return text + String(format: " in %.1fs", duration)
    }
}

public enum TestRunnerKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case zigBuild
    case zigTest
    case cargoTest
    case cargoNextest
    case gradleWrapper
    case gradle
    /// CMake + CTest (GoogleTest, Catch2 or doctest tests registered with *_discover_tests).
    case ctest
    case vitest
    case jest
    /// Node.js's built-in runner (`node --test`), also for TypeScript on Node.js 23.6+.
    case nodeTest
    case bunTest
    /// WebAssembly text: exported `test*` functions invoked with `wasmtime run --invoke`.
    case wasmtimeInvoke
    /// WebAssembly text: exported `test*` functions called by a small Node.js harness (supports coverage).
    case nodeWasm
    /// WebAssembly spec scripts (`.wast` with assert_return, assert_trap, …) run by `wasmtime wast`.
    case wasmtimeWast

    public var id: String { rawValue }

    /// The language whose settings own the runner choice (JavaScript runners serve TypeScript too).
    public var language: Language {
        switch self {
        case .zigBuild, .zigTest: return .zig
        case .cargoTest, .cargoNextest: return .rust
        case .gradleWrapper, .gradle: return .kotlin
        case .ctest: return .cpp
        case .vitest, .jest, .nodeTest, .bunTest: return .javascript
        case .wasmtimeInvoke, .nodeWasm, .wasmtimeWast: return .wasm
        }
    }

    public func supports(_ language: Language) -> Bool {
        language == self.language || (language == .typescript && self.language == .javascript)
    }

    public var displayName: String {
        switch self {
        case .zigBuild: return "zig build test"
        case .zigTest: return "zig test"
        case .cargoTest: return "cargo test"
        case .cargoNextest: return "cargo nextest"
        case .gradleWrapper: return "Gradle wrapper (./gradlew test)"
        case .gradle: return "Gradle (gradle test)"
        case .ctest: return "CMake + CTest (GoogleTest, Catch2, doctest)"
        case .vitest: return "Vitest"
        case .jest: return "Jest"
        case .nodeTest: return "node:test (node --test)"
        case .bunTest: return "bun test"
        case .wasmtimeInvoke: return "Wasmtime (exported test* functions)"
        case .nodeWasm: return "Node.js harness (exported test* functions)"
        case .wasmtimeWast: return "wasmtime wast (.wast scripts)"
        }
    }

    /// Name of the executable a custom path override replaces.
    public var toolName: String {
        switch self {
        case .zigBuild, .zigTest: return "zig"
        case .cargoTest, .cargoNextest: return "cargo"
        case .gradleWrapper: return "gradlew"
        case .gradle: return "gradle"
        case .ctest: return "cmake"
        case .vitest: return "vitest"
        case .jest: return "jest"
        case .nodeTest, .nodeWasm: return "node"
        case .bunTest: return "bun"
        case .wasmtimeInvoke, .wasmtimeWast: return "wasmtime"
        }
    }

    /// Runners that existed before C++/JavaScript/TypeScript/WebAssembly support (custom paths apply unconditionally).
    public var isClassic: Bool { [.zigBuild, .zigTest, .cargoTest, .cargoNextest, .gradleWrapper, .gradle].contains(self) }

    /// Runners that can collect code coverage.
    public var supportsCoverage: Bool { [.ctest, .vitest, .jest, .nodeTest, .bunTest, .wasmtimeInvoke, .nodeWasm].contains(self) }

    public static func kinds(for language: Language) -> [TestRunnerKind] {
        allCases.filter { $0.supports(language) }
    }
}

public enum TestRunnerError: Error, LocalizedError, Equatable {
    case toolNotFound(String, hint: String)
    case noProject(String)
    case noTests(String)
    case noTestAtCursor
    case needsSavedFile

    public var errorDescription: String? {
        switch self {
        case .toolNotFound(let tool, let hint): return "\(tool) was not found. \(hint)"
        case .noProject(let detail): return detail
        case .noTests(let file): return "No tests found in \(file)."
        case .noTestAtCursor: return "No test function at or above the cursor."
        case .needsSavedFile: return "Save the file inside a project before running tests (CrossKit could not determine its path)."
        }
    }
}

public struct TestCommand: Equatable, Sendable {
    public var kind: TestRunnerKind
    public var executable: String
    public var arguments: [String]
    public var workingDirectory: String
    public var environment: [String: String]
    /// Kotlin: directory whose build/test-results/test contains JUnit XML reports.
    public var reportsDirectory: String?
    /// A report file the runner writes (CTest/Vitest/node:test/bun JUnit XML, Jest JSON).
    public var reportFile: String?
    /// Where the run leaves coverage data, when it collects coverage.
    public var coverage: CoverageArtifacts?

    public init(kind: TestRunnerKind, executable: String, arguments: [String], workingDirectory: String,
                environment: [String: String], reportsDirectory: String? = nil, reportFile: String? = nil,
                coverage: CoverageArtifacts? = nil) {
        self.coverage = coverage
        self.kind = kind
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.reportsDirectory = reportsDirectory
        self.reportFile = reportFile
    }

    public var display: String {
        ([executable] + arguments).map { arg in
            arg.contains(where: { " \"'$`\\*?()<>|&;".contains($0) }) ? "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'" : arg
        }.joined(separator: " ")
    }
}
