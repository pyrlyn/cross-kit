import XCTest
@testable import CrossKitCore

/// Drives real language servers through the same path the Xcode extension uses:
/// EditorCommandEngine → BridgeClient (CFMessagePort) → BridgeServer → BridgeHandler → ServerManager → server.
/// Each test skips when its server is not installed.
final class EndToEndTests: XCTestCase {
    struct Sample {
        var files: [String: String]       // relative path → contents
        var mainFile: String
        var source: [String]              // correct program
        var brokenLine: String            // inserted after `insertAfter` to seed a syntax error
        var insertAfter: Int
        var partialLine: String           // replaces the error line; cursor at its end
        var expectedCompletion: String
        var usageLine: Int                // line with a call of the function
        var usageColumn: Int
        var definitionLine: Int
        var hoverMustContain: String
    }

    func testRustAnalyzer() async throws {
        try await runEndToEnd(.rust, Sample(
            files: ["Cargo.toml": "[package]\nname = \"sample\"\nversion = \"0.1.0\"\nedition = \"2021\"\n\n[dependencies]\n"],
            mainFile: "src/main.rs",
            source: ["fn compute_answer(value: i32) -> i32 {", "    value * 2", "}", "", "fn main() {",
                     "    let result = compute_answer(21);", "    println!(\"{}\", result);", "}"],
            brokenLine: "    let oops = ;", insertAfter: 5,
            partialLine: "    let again = compute_ans",
            expectedCompletion: "compute_answer", usageLine: 5, usageColumn: 18, definitionLine: 0,
            hoverMustContain: "compute_answer"))
    }

    func testZLS() async throws {
        try await runEndToEnd(.zig, Sample(
            files: ["build.zig": "const std = @import(\"std\");\n\npub fn build(b: *std.Build) void {\n    _ = b;\n}\n"],
            mainFile: "src/main.zig",
            source: ["const std = @import(\"std\");", "", "fn computeAnswer(value: i32) i32 {", "    return value * 2;", "}", "",
                     "pub fn main() void {", "    const result = computeAnswer(21);", "    std.debug.print(\"{d}\\n\", .{result});", "}"],
            brokenLine: "    const oops = ;", insertAfter: 7,
            partialLine: "    const again = computeAns",
            expectedCompletion: "computeAnswer", usageLine: 7, usageColumn: 20, definitionLine: 2,
            hoverMustContain: "computeAnswer"))
    }

    func testKotlinLanguageServer() async throws {
        try await runEndToEnd(.kotlin, Sample(
            files: [:],
            mainFile: "Main.kt",
            source: ["fun computeAnswer(value: Int): Int {", "    return value * 2", "}", "", "fun main() {",
                     "    val result = computeAnswer(21)", "    println(result)", "}"],
            brokenLine: "    val oops = )", insertAfter: 5,
            partialLine: "    val again = computeAns",
            expectedCompletion: "computeAnswer", usageLine: 5, usageColumn: 18, definitionLine: 0,
            hoverMustContain: "computeAnswer"))
    }

    func testClangd() async throws {
        try await runEndToEnd(.cpp, Sample(
            files: ["compile_flags.txt": "-std=c++20\n"],
            mainFile: "main.cpp",
            source: ["// sample", "", "int computeAnswer(int value) {", "    return value * 2;", "}", "",
                     "int main() {", "    int result = computeAnswer(21);", "    return result == 42 ? 0 : 1;", "}"],
            brokenLine: "    int oops = ;", insertAfter: 7,
            partialLine: "    int again = computeAns",
            expectedCompletion: "computeAnswer", usageLine: 7, usageColumn: 18, definitionLine: 2,
            hoverMustContain: "computeAnswer"))
    }

    func testTypeScriptLanguageServer() async throws {
        try await runEndToEnd(.typescript, Sample(
            files: ["tsconfig.json": "{ \"compilerOptions\": { \"strict\": true, \"target\": \"es2022\" } }\n"],
            mainFile: "src/main.ts",
            source: ["function computeAnswer(value: number): number {", "    return value * 2;", "}", "",
                     "function main(): void {", "    const result = computeAnswer(21);", "    console.log(result);", "}", "main();"],
            brokenLine: "    const oops = ;", insertAfter: 5,
            partialLine: "    const again = computeAns",
            expectedCompletion: "computeAnswer", usageLine: 5, usageColumn: 20, definitionLine: 0,
            hoverMustContain: "computeAnswer"))
    }

    func testTypeScriptLanguageServerForJavaScript() async throws {
        try await runEndToEnd(.javascript, Sample(
            files: ["package.json": "{ \"type\": \"module\" }\n"],
            mainFile: "main.js",
            source: ["function computeAnswer(value) {", "    return value * 2;", "}", "",
                     "function main() {", "    const result = computeAnswer(21);", "    console.log(result);", "}", "main();"],
            brokenLine: "    const oops = ;", insertAfter: 5,
            partialLine: "    const again = computeAns",
            expectedCompletion: "computeAnswer", usageLine: 5, usageColumn: 20, definitionLine: 0,
            hoverMustContain: "computeAnswer"))
    }

    func testWatServer() async throws {
        try await runEndToEnd(.wasm, Sample(
            files: [:],
            mainFile: "main.wat",
            source: ["(module", "  (func $computeAnswer (param $value i32) (result i32)", "    local.get $value", "    i32.const 2", "    i32.mul)",
                     "  (func $main (export \"main\") (result i32)", "    i32.const 21", "    call $computeAnswer))"],
            brokenLine: "    i32.const oops", insertAfter: 6,
            partialLine: "    call $computeAns",
            expectedCompletion: "computeAnswer", usageLine: 7, usageColumn: 12, definitionLine: 1,
            hoverMustContain: "computeAnswer"))
    }

    // MARK: Driver

    private func runEndToEnd(_ language: Language, _ sample: Sample) async throws {
        let locator = ServerLocator()
        guard let binary = locator.detect(language) else {
            throw XCTSkip("\(language.serverBinaryName) not found by auto-detection; install with: \(language.installHint)")
        }
        print("[e2e] \(language.displayName): using \(binary.path)")

        let fm = FileManager.default
        let project = URL(fileURLWithPath: "/tmp/ck-e2e-\(language.rawValue)-\(UUID().uuidString.prefix(6))").resolvingSymlinksInPath()
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: project) }
        for (path, contents) in sample.files {
            let url = project.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        let main = project.appendingPathComponent(sample.mainFile)
        try fm.createDirectory(at: main.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (sample.source.joined(separator: "\n") + "\n").write(to: main, atomically: true, encoding: .utf8)

        let suite = "dev.pyrlyn.CrossKit.e2e.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { removeDefaults(suite) }
        let settings = SettingsStore(defaults: defaults)
        let manager = ServerManager(settings: settings, locator: locator)
        let handler = BridgeHandler(manager: manager, settings: settings, scratchDirectory: project.appendingPathComponent(".scratch"))
        let server = BridgeServer(portName: "dev.pyrlyn.CrossKit.e2e.\(UUID().uuidString.prefix(6))") { await handler.handle($0) }
        try server.start()
        defer { server.stop() }
        let transport = BridgeClient(portName: server.portName, timeout: language.requestTimeout + 60)
        let engine = EditorCommandEngine()
        let uti = "public.\(language.rawValue)-source"
        func buffer(_ lines: [String], _ line: Int, _ column: Int) -> EditorBuffer {
            EditorBuffer(lines: lines.map { $0 + "\n" }, selection: .caret(line, column), contentUTI: uti, filePath: main.path)
        }
        let started = Date()
        func log(_ s: String) { print(String(format: "[e2e] %@ +%.1fs: %@", language.displayName, Date().timeIntervalSince(started), s)) }

        // 1. Diagnostics for a seeded syntax error (servers may need a few rounds while indexing).
        var broken = sample.source
        broken.insert(sample.brokenLine, at: sample.insertAfter + 1)
        var diagnosticLines: [String] = []
        for attempt in 1...12 {
            do {
                let outcome = try await engine.run(.diagnostics, buffer: buffer(broken, 0, 0), transport: transport)
                let after = EditorCommandEngine.apply(outcome.operations, to: buffer(broken, 0, 0).lines).lines
                diagnosticLines = after.filter(EditorCommandEngine.isAnnotation)
                if !diagnosticLines.isEmpty { break }
                log("diagnostics attempt \(attempt): \(outcome.message ?? "none")")
            } catch {
                log("diagnostics attempt \(attempt) failed: \(error.localizedDescription)")
                if attempt == 12 { throw error }
            }
            try await Task.sleep(nanoseconds: 3_000_000_000)
        }
        let status = await manager.status(for: language)
        XCTAssertEqual(status.state, .running, "server should be running after initialize: \(status.lastError ?? "")")
        XCTAssertFalse(diagnosticLines.isEmpty, "expected a diagnostic for the seeded error")
        log("diagnostics: \(diagnosticLines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })")

        // 2. Completion of a partial identifier.
        var partial = sample.source
        partial.insert(sample.partialLine, at: sample.insertAfter + 1)
        let partialRow = sample.insertAfter + 1
        var completed: String?
        for attempt in 1...10 {
            let b = buffer(partial, partialRow, (sample.partialLine as NSString).length)
            do {
                let outcome = try await engine.run(.complete, buffer: b, transport: transport)
                let line = EditorCommandEngine.apply(outcome.operations, to: b.lines).lines[partialRow]
                if line.contains(sample.expectedCompletion) { completed = line; break }
                log("completion attempt \(attempt): \(outcome.message ?? line)")
            } catch {
                log("completion attempt \(attempt) failed: \(error.localizedDescription)")
            }
            try await Task.sleep(nanoseconds: 3_000_000_000)
        }
        XCTAssertNotNil(completed, "expected completion to insert \(sample.expectedCompletion)")
        log("completion: \(completed?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "-")")

        // 3. Go to definition (same file → selection on the declaration line).
        var definitionSelection: EditorRange?
        for attempt in 1...5 {
            let outcome = try await engine.run(.goToDefinition, buffer: buffer(sample.source, sample.usageLine, sample.usageColumn), transport: transport)
            if case .select(let range)? = outcome.operations.last, outcome.operations.count == 1 { definitionSelection = range; break }
            log("definition attempt \(attempt): \(outcome.message ?? "\(outcome.operations)")")
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        XCTAssertEqual(definitionSelection?.start.line, sample.definitionLine)
        log("definition: \(String(describing: definitionSelection))")

        // 4. Hover.
        var hoverText: String?
        for attempt in 1...5 {
            let b = buffer(sample.source, sample.usageLine, sample.usageColumn)
            let outcome = try await engine.run(.hover, buffer: b, transport: transport)
            let annotations = EditorCommandEngine.apply(outcome.operations, to: b.lines).lines.filter(EditorCommandEngine.isAnnotation)
            if annotations.contains(where: { $0.contains(sample.hoverMustContain) }) { hoverText = annotations.joined(); break }
            log("hover attempt \(attempt): \(outcome.message ?? annotations.joined())")
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        XCTAssertNotNil(hoverText, "expected hover mentioning \(sample.hoverMustContain)")
        log("hover: \(hoverText?.replacingOccurrences(of: "\n", with: " | ") ?? "-")")

        // 5. Clean shutdown, no leftover processes.
        let groups = await manager.processGroups()
        XCTAssertFalse(groups.isEmpty)
        await manager.shutdownAll()
        for group in groups {
            XCTAssertFalse(ProcessRegistry.groupIsAlive(group), "process group \(group) still has processes")
            XCTAssertNotEqual(kill(group, 0), 0, "server pid \(group) still alive")
        }
        let final = await manager.status(for: language)
        XCTAssertEqual(final.state, .stopped)
        log("shutdown ok, groups \(groups) gone")
    }
}
