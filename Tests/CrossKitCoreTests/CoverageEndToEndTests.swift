import XCTest
@testable import CrossKitCore

/// Coverage and inspection through the extension path (EditorCommandEngine → bridge → BridgeHandler):
/// C++ (CMake + llvm-cov), JavaScript/TypeScript (node:test LCOV) and WebAssembly (instrumented WAT).
/// Each project has a covered and an uncovered function. Tests skip when a toolchain is missing.
final class CoverageEndToEndTests: XCTestCase {
    struct Fixture {
        var files: [String: String]
        var testFile: String
        /// File whose coverage is checked, its covered and uncovered 1-based lines.
        var sourceFile: String
        var coveredLine: Int
        var uncoveredLine: Int
        var runner: TestRunnerKind? = nil
        /// Whether the test file itself gets `░ not covered` markers.
        var marksTestFile = false
    }

    func testCppCoverage() async throws {
        let tools = ToolFinder()
        guard tools.cmake() != nil, tools.ctest() != nil, let clang = tools.clangxx() else { throw XCTSkip("cmake/ctest/clang++ not found") }
        guard tools.llvmTool("llvm-cov", matching: clang) != nil else { throw XCTSkip("llvm-cov not found") }
        let source = """
        #include "mini_test.h"

        static int add(int a, int b) { return a + b; }

        static int unused(int x) {
            return x * 2;
        }

        TEST(Math, adds) {
            EXPECT_EQ(add(1, 2), 3);
        }

        int main(int argc, char** argv) { return miniMain(argc, argv); }
        """
        let cmake = """
        cmake_minimum_required(VERSION 3.16)
        project(sample CXX)
        enable_testing()
        add_executable(math_test math_test.cpp)
        add_test(NAME Math.adds COMMAND math_test Math.adds)

        """
        try await run(.cpp, Fixture(files: ["CMakeLists.txt": cmake, "mini_test.h": TestRunEndToEndTests.miniTestHeader, "math_test.cpp": source],
                                    testFile: "math_test.cpp", sourceFile: "math_test.cpp", coveredLine: 3, uncoveredLine: 6,
                                    marksTestFile: true))
    }

    func testTypeScriptCoverageWithNodeTest() async throws {
        let tools = ToolFinder()
        guard let node = tools.node(), tools.nodeRunsTypeScript(node) else { throw XCTSkip("Node.js 23.6+ not found") }
        let lib = """
        export function add(a: number, b: number): number {
          return a + b;
        }

        export function unused(x: number): number {
          return x * 2;
        }
        """
        let test = """
        import { test } from "node:test";
        import assert from "node:assert/strict";
        import { add } from "./lib.ts";

        test("adds", () => {
          assert.equal(add(1, 2), 3);
        });
        """
        try await run(.typescript, Fixture(files: ["package.json": "{ \"type\": \"module\" }\n", "lib.ts": lib, "lib.test.ts": test],
                                           testFile: "lib.test.ts", sourceFile: "lib.ts", coveredLine: 2, uncoveredLine: 6, runner: .nodeTest))
    }

    func testJavaScriptCoverageWithNodeTest() async throws {
        guard ToolFinder().node() != nil else { throw XCTSkip("node not found") }
        let lib = "export function add(a, b) {\n  return a + b;\n}\n\nexport function unused(x) {\n  return x * 2;\n}\n"
        let test = "import { test } from \"node:test\";\nimport assert from \"node:assert/strict\";\nimport { add } from \"./lib.js\";\n\ntest(\"adds\", () => {\n  assert.equal(add(1, 2), 3);\n});\n"
        try await run(.javascript, Fixture(files: ["package.json": "{ \"type\": \"module\" }\n", "lib.js": lib, "lib.test.js": test],
                                           testFile: "lib.test.js", sourceFile: "lib.js", coveredLine: 2, uncoveredLine: 6))
    }

    func testWasmCoverage() async throws {
        let tools = ToolFinder()
        guard tools.node() != nil, WasmTesting.converter(tools: tools) != nil else { throw XCTSkip("node and wasm-tools/wat2wasm needed") }
        let wat = """
        (module
          (func $add (param $a i32) (param $b i32) (result i32)
            local.get $a
            local.get $b
            i32.add)

          (func $unused (result i32)
            i32.const 7)

          (func (export "test_adds")
            (if (i32.ne (call $add (i32.const 1) (i32.const 2)) (i32.const 3))
              (then unreachable)))
        )
        """
        try await run(.wasm, Fixture(files: ["math.wat": wat], testFile: "math.wat", sourceFile: "math.wat",
                                     coveredLine: 3, uncoveredLine: 8, marksTestFile: true))
    }

    // MARK: Inspection

    func testInspectionSections() async throws {
        let tools = ToolFinder()
        let root = try makeRoot("inspect")
        defer { try? FileManager.default.removeItem(at: root) }
        let service = InspectService(tools: tools, workDirectory: root.appendingPathComponent(".work"))
        if tools.clangxx() != nil {
            let file = root.appendingPathComponent("square.cpp")
            try "int square(int x) { return x * x; }\n".write(to: file, atomically: true, encoding: .utf8)
            let result = try await service.inspect(language: .cpp, file: file, text: "")
            let asm = try XCTUnwrap(result.sections.first { $0.id == "asm-O2" })
            XCTAssertFalse(asm.failed, asm.text)
            XCTAssertTrue(asm.text.contains("square"), asm.text)
            XCTAssertTrue(result.sections.first { $0.id == "symbols" }?.text.contains("square(int)") == true)
        }
        if let node = tools.node(), tools.nodeRunsTypeScript(node) {
            let file = root.appendingPathComponent("greet.ts")
            let text = "export function greet(name: string): string {\n  return `hi ${name}`;\n}\nclass A {\n  run(): void {}\n}\n"
            try text.write(to: file, atomically: true, encoding: .utf8)
            let result = try await service.inspect(language: .typescript, file: file, text: text)
            let emitted = try XCTUnwrap(result.sections.first { $0.id == "emitted" })
            XCTAssertFalse(emitted.text.contains(": string"), emitted.text)
            XCTAssertTrue(emitted.text.contains("function greet(name"), emitted.text)
            XCTAssertTrue(result.sections.first { $0.id == "outline" }?.text.contains("method run") == true)
        }
        if WasmTesting.converter(tools: tools) != nil {
            let file = root.appendingPathComponent("m.wat")
            try "(module (func $f (export \"f\") (result i32) i32.const 1))".write(to: file, atomically: true, encoding: .utf8)
            let result = try await service.inspect(language: .wasm, file: file, text: "")
            let module = try XCTUnwrap(result.sections.first { $0.id == "module" })
            XCTAssertTrue(module.text.contains("\"f\"  func"), module.text)
            XCTAssertFalse(result.sections.first { $0.id == "validate" }?.failed ?? true)
        }
    }

    // MARK: Driver

    func makeRoot(_ name: String) throws -> URL {
        let root = URL(fileURLWithPath: "/tmp/ck-coverage-\(name)-\(UUID().uuidString.prefix(6))").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func run(_ language: Language, _ fixture: Fixture) async throws {
        let fm = FileManager.default
        let root = try makeRoot(language.rawValue)
        defer { try? fm.removeItem(at: root) }
        for (path, contents) in fixture.files {
            let url = root.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        let file = root.appendingPathComponent(fixture.testFile)
        let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n").map { $0 + "\n" }
        let suite = "dev.pyrlyn.CrossKit.e2e-coverage.\(UUID().uuidString)"
        defer { removeDefaults(suite) }
        let settings = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
        settings.testTimeout = 600
        if let runner = fixture.runner { settings.setTestRunner(runner, for: language) }
        let manager = ServerManager(settings: settings)
        let handler = BridgeHandler(manager: manager, settings: settings, scratchDirectory: root.appendingPathComponent(".scratch"))
        let reports = ReportCollector()
        handler.onCoverage = { reports.add($0) }
        let server = BridgeServer(portName: "dev.pyrlyn.CrossKit.e2e-coverage.\(UUID().uuidString.prefix(6))") { await handler.handle($0) }
        try server.start()
        defer { server.stop() }
        let transport = BridgeClient(portName: server.portName, timeout: 660)
        let buffer = EditorBuffer(lines: lines, selection: .caret(0, 0), contentUTI: "public.\(language.rawValue)-source", filePath: file.path)
        let outcome = try await EditorCommandEngine().run(.runTestsWithCoverage, buffer: buffer, transport: transport)
        let message = outcome.message ?? ""
        print("[e2e-coverage] \(language.displayName):\n\(message)")
        XCTAssertTrue(message.contains("Coverage:"), message)
        let report = try XCTUnwrap(reports.last)
        let source = try XCTUnwrap(report.file(root.appendingPathComponent(fixture.sourceFile).path), "\(report.files.map(\.path))")
        XCTAssertGreaterThan(source.lines[fixture.coveredLine] ?? 0, 0, "line \(fixture.coveredLine) should be covered: \(source.lines.sorted { $0.key < $1.key })")
        XCTAssertEqual(source.lines[fixture.uncoveredLine], 0, "line \(fixture.uncoveredLine) should be uncovered: \(source.lines.sorted { $0.key < $1.key })")
        XCTAssertTrue(source.percent > 0 && source.percent < 100, "\(source.percent)")
        let annotated = EditorCommandEngine.apply(outcome.operations, to: lines).lines
        if fixture.marksTestFile {
            XCTAssertTrue(annotated.contains { $0.contains("[CrossKit] ░ not covered") }, annotated.joined())
            if language == .wasm { XCTAssertTrue(annotated.contains { $0.contains(";; [CrossKit]") }, annotated.joined()) }
        }
        // Raw data is removed after the report.
        let coverageDir = handler.testService.resolver.workDirectory.appendingPathComponent("coverage")
        let leftovers = (try? fm.contentsOfDirectory(atPath: coverageDir.path)) ?? []
        XCTAssertFalse(leftovers.contains { $0 == report.id.uuidString })
        await manager.shutdownAll()
        XCTAssertTrue(ProcessRegistry.activeGroups().isEmpty)
    }
}

private final class ReportCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var reports: [CoverageReport] = []
    func add(_ report: CoverageReport) { lock.lock(); reports.append(report); lock.unlock() }
    var last: CoverageReport? { lock.lock(); defer { lock.unlock() }; return reports.last }
}
