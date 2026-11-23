import Foundation

/// WebAssembly tests.
///
/// * WebAssembly text (`.wat`): every exported function whose export name starts with `test` is a test. It passes
///   when it returns without trapping (and, if it returns a value, the value is not zero).
///   Run with `wasmtime run --invoke` or the Node.js harness (`WasmHarness`, needed for coverage).
/// * Spec scripts (`.wast`): every top-level `assert_*` command is a test, run by `wasmtime wast`.
public enum WasmTesting {
    public static func isScript(_ path: String) -> Bool { path.lowercased().hasSuffix(".wast") }

    public static func discover(text: String, filePath: String) -> [DiscoveredTest] {
        isScript(filePath) ? WatSource.wastAssertions(text) : WatSource.testExports(text)
    }

    static let testMarker = "CROSSKIT_TEST "
    static let exitMarker = "CROSSKIT_EXIT "

    /// One `wasmtime run --invoke` per test, framed by markers so each test's output and exit code can be told apart.
    public static func invokeScript(wasmtime: String, file: String, tests: [String]) -> String {
        let q = DebugService.shellQuote
        var lines: [String] = []
        for test in tests {
            lines.append("echo \(q(testMarker + test))")
            lines.append("\(q(wasmtime)) run --invoke \(q(test)) \(q(file)) 2>&1")
            lines.append("echo \"\(exitMarker)$?\"")
        }
        return lines.joined(separator: "\n")
    }

    /// Converts the text module to a binary (wasm-tools or wat2wasm), then runs the harness.
    public static func harnessScript(converter: [String], node: String, harness: String, file: String, output: String, tests: [String]) -> String {
        let q = DebugService.shellQuote
        return [
            "set -e",
            (converter + [file, "-o", output]).map(q).joined(separator: " "),
            "set +e",
            ([node, harness, output, "test"] + tests).map(q).joined(separator: " "),
        ].joined(separator: "\n")
    }

    /// Converter command prefix (`wasm-tools parse -g` or `wat2wasm --debug-names`); the input path and `-o out` follow.
    public static func converter(tools: ToolFinder) -> [String]? {
        if let wasmTools = tools.wasmTools() { return [wasmTools.path, "parse", "-g"] }
        if let wat2wasm = tools.wabt("wat2wasm") { return [wat2wasm.path, "--debug-names", "--enable-all"] }
        return nil
    }

    public static func parseInvoke(_ output: String) -> [TestCaseResult] {
        var results: [TestCaseResult] = []
        var name: String?
        var lines: [String] = []
        for line in output.components(separatedBy: "\n") {
            if line.hasPrefix(testMarker) {
                name = String(line.dropFirst(testMarker.count)); lines = []
            } else if line.hasPrefix(exitMarker), let current = name {
                let code = Int(line.dropFirst(exitMarker.count).trimmingCharacters(in: .whitespaces)) ?? 1
                let text = lines.filter { !$0.hasPrefix("warning: using `--invoke`") }.joined(separator: "\n")
                let last = lines.last { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("warning:") }
                let returnedZero = code == 0 && last.map { ["0", "0.0", "-0"].contains($0.trimmingCharacters(in: .whitespaces)) } == true
                let passed = code == 0 && !returnedZero
                results.append(TestCaseResult(name: current, status: passed ? .passed : .failed,
                                              output: passed ? nil : (returnedZero ? "returned 0" : text)))
                name = nil
            } else if name != nil {
                lines.append(line)
            }
        }
        return results
    }

    /// `wasmtime wast` stops at the first failing directive (`failed directive on file.wast:LINE`): assertions
    /// before it passed, it failed and later ones did not run. Exit code 0 means all passed.
    public static func parseWast(_ output: String, exitCode: Int32?, tests: [DiscoveredTest]) -> [TestCaseResult] {
        var failingLine: Int?
        if let m = output.range(of: #"failed directive on [^\n]*?:(\d+)"#, options: .regularExpression) {
            let text = String(output[m])
            failingLine = Int(text.split(separator: ":").last.map(String.init) ?? "")
        }
        guard exitCode == 0 || failingLine != nil else {
            // The module failed to parse/validate: nothing ran.
            return tests.map { TestCaseResult(name: $0.name, status: .failed, output: output) }
        }
        return tests.map { test in
            let line = test.line + 1
            guard let failing = failingLine else { return TestCaseResult(name: test.name, status: .passed) }
            if line < failing { return TestCaseResult(name: test.name, status: .passed) }
            if line == failing { return TestCaseResult(name: test.name, status: .failed, output: output) }
            return TestCaseResult(name: test.name, status: .skipped, output: "Not run: wasmtime wast stops at the first failing directive.")
        }
    }
}
