import XCTest
@testable import CrossKitCore

/// Runs real test toolchains through the extension path:
/// EditorCommandEngine → BridgeClient → BridgeServer → BridgeHandler → TestService → zig / cargo / gradle.
/// Each project has one passing and one failing test. Tests skip when the toolchain is missing.
final class TestRunEndToEndTests: XCTestCase {
    struct Project {
        var files: [String: String]
        var testFile: String
        var passing: String          // result name fragment of the passing test
        var failing: String          // result name fragment of the failing test
        var failureText: String      // must appear in the failing test's output
        var cursorLine: Int          // a line inside the passing test
        var arguments: [String] = []
        var runner: TestRunnerKind? = nil
        var passedCount = 1
        var failedCount = 1
        /// Test markers expected after the file run (defaults to passed + failed).
        var markers: Int? = nil
        var skippedCount = 0
    }

    func testZigRunsTests() async throws {
        guard TestToolchain().zig() != nil else { throw XCTSkip("zig not found; install with `mise use -g zig@latest`") }
        let source = """
        const std = @import("std");

        fn add(a: i32, b: i32) i32 {
            return a + b;
        }

        test "add works" {
            try std.testing.expectEqual(@as(i32, 3), add(1, 2));
        }

        test "add fails on purpose" {
            try std.testing.expectEqual(@as(i32, 4), add(1, 2));
        }
        """
        // Single-file project: no build.zig, so the runner uses `zig test <file>`.
        try await run(.zig, Project(files: ["main.zig": source], testFile: "main.zig",
                                    passing: "add works", failing: "add fails on purpose",
                                    failureText: "expected 4, found 3", cursorLine: 7))
    }

    func testRustRunsTests() async throws {
        guard TestToolchain().cargo() != nil else { throw XCTSkip("cargo not found; install Rust with rustup") }
        let source = """
        pub fn add(a: i32, b: i32) -> i32 {
            a + b
        }

        #[cfg(test)]
        mod tests {
            use super::*;

            #[test]
            fn adds() {
                assert_eq!(add(1, 2), 3);
            }

            #[test]
            fn fails_on_purpose() {
                assert_eq!(add(1, 2), 4, "math is hard");
            }
        }
        """
        try await run(.rust, Project(
            files: ["Cargo.toml": "[package]\nname = \"sample\"\nversion = \"0.1.0\"\nedition = \"2021\"\n\n[dependencies]\n",
                    "src/lib.rs": source],
            testFile: "src/lib.rs", passing: "tests::adds", failing: "tests::fails_on_purpose",
            failureText: "math is hard", cursorLine: 10))
    }

    func testKotlinRunsJUnit5Tests() async throws {
        guard TestToolchain().gradle() != nil else { throw XCTSkip("gradle not found; install with `mise use -g gradle@latest`") }
        guard ServerLocator().javaHome() != nil else { throw XCTSkip("no JDK found") }
        let test = """
        package demo

        import org.junit.jupiter.api.Assertions.assertEquals
        import org.junit.jupiter.api.Test

        class CalcTest {
            @Test
            fun adds() {
                assertEquals(3, add(1, 2))
            }

            @Test
            fun `fails on purpose`() {
                assertEquals(4, add(1, 2), "math is hard")
            }
        }
        """
        // Uses --offline when the dependencies are already in ~/.gradle (CI without network); otherwise Gradle downloads them.
        let offline = FileManager.default.fileExists(atPath: ServerLocator().home.appendingPathComponent(".gradle/caches/modules-2/files-2.1/org.junit/junit-bom/5.13.4").path)
        try await run(.kotlin, Project(
            files: ["settings.gradle.kts": "rootProject.name = \"sample\"\n",
                    "build.gradle.kts": """
                    plugins { kotlin("jvm") version "2.4.21" }
                    repositories { mavenCentral() }
                    dependencies {
                        testImplementation(platform("org.junit:junit-bom:5.13.4"))
                        testImplementation("org.junit.jupiter:junit-jupiter")
                        testRuntimeOnly("org.junit.platform:junit-platform-launcher")
                    }
                    tasks.test { useJUnitPlatform() }

                    """,
                    "src/main/kotlin/demo/Calc.kt": "package demo\n\nfun add(a: Int, b: Int) = a + b\n",
                    "src/test/kotlin/demo/CalcTest.kt": test],
            testFile: "src/test/kotlin/demo/CalcTest.kt", passing: "demo.CalcTest.adds", failing: "demo.CalcTest.fails on purpose",
            failureText: "math is hard", cursorLine: 8,
            // No daemons, so the test leaves no processes behind.
            arguments: ["--no-daemon", "-Pkotlin.compiler.execution.strategy=in-process"] + (offline ? ["--offline"] : [])))
    }

    // MARK: C++ (CMake + CTest)

    /// A tiny GoogleTest-compatible header (`TEST(Suite, Name)`, `EXPECT_EQ`) so the test needs no network.
    static let miniTestHeader = """
    #pragma once
    #include <cstdio>
    #include <cstring>
    #include <functional>
    #include <string>
    #include <vector>

    struct MiniTest { std::string name; std::function<void(bool&)> body; };
    inline std::vector<MiniTest>& miniTests() { static std::vector<MiniTest> tests; return tests; }
    struct MiniRegister { MiniRegister(const char* n, std::function<void(bool&)> b) { miniTests().push_back({n, b}); } };
    #define TEST(suite, name) \\
        static void suite##_##name(bool&); \\
        static MiniRegister suite##_##name##_reg(#suite "." #name, suite##_##name); \\
        static void suite##_##name(bool& ok_)
    #define EXPECT_EQ(a, b) do { auto x_ = (a); auto y_ = (b); if (!(x_ == y_)) { \\
        std::printf("%s:%d: expected %s == %s\\n", __FILE__, __LINE__, #a, #b); ok_ = false; } } while (0)
    #define EXPECT_EQ_MSG(a, b, msg) do { if (!((a) == (b))) { std::printf("failure: %s\\n", msg); ok_ = false; } } while (0)
    inline int miniMain(int argc, char** argv) {
        int failed = 0;
        for (auto& t : miniTests()) {
            if (argc > 1 && t.name != argv[1]) continue;
            bool ok = true; t.body(ok);
            std::printf("[%s] %s\\n", ok ? "PASS" : "FAIL", t.name.c_str());
            if (!ok) failed++;
        }
        return failed ? 1 : 0;
    }
    """

    func testCppRunsCTestTests() async throws {
        guard ToolFinder().cmake() != nil, ToolFinder().ctest() != nil else { throw XCTSkip("cmake/ctest not found; install with `mise use -g cmake`") }
        guard ToolFinder().clangxx() != nil else { throw XCTSkip("clang++ not found; install the Xcode Command Line Tools") }
        let source = """
        #include "mini_test.h"

        static int add(int a, int b) { return a + b; }

        TEST(Math, adds) {
            EXPECT_EQ(add(1, 2), 3);
        }

        TEST(Math, fails_on_purpose) {
            EXPECT_EQ_MSG(add(1, 2), 4, "math is hard");
        }

        int main(int argc, char** argv) { return miniMain(argc, argv); }
        """
        let cmake = """
        cmake_minimum_required(VERSION 3.16)
        project(sample CXX)
        set(CMAKE_CXX_STANDARD 17)
        enable_testing()
        add_executable(math_test math_test.cpp)
        foreach(t Math.adds Math.fails_on_purpose)
          add_test(NAME ${t} COMMAND math_test ${t})
        endforeach()

        """
        try await run(.cpp, Project(files: ["CMakeLists.txt": cmake, "mini_test.h": Self.miniTestHeader, "math_test.cpp": source],
                                    testFile: "math_test.cpp", passing: "Math.adds", failing: "Math.fails_on_purpose",
                                    failureText: "math is hard", cursorLine: 5))
    }

    // MARK: JavaScript / TypeScript

    func testJavaScriptRunsNodeTests() async throws {
        guard ToolFinder().node() != nil else { throw XCTSkip("node not found; install with `mise use -g node@lts`") }
        let source = """
        import { describe, test } from "node:test";
        import assert from "node:assert/strict";

        const add = (a, b) => a + b;

        describe("math", () => {
          test("adds", () => {
            assert.equal(add(1, 2), 3);
          });

          test("fails on purpose", () => {
            assert.equal(add(1, 2), 4, "math is hard");
          });
        });
        """
        try await run(.javascript, Project(files: ["package.json": "{ \"type\": \"module\" }\n", "math.test.js": source],
                                           testFile: "math.test.js", passing: "math adds", failing: "math fails on purpose",
                                           failureText: "math is hard", cursorLine: 7))
    }

    func testTypeScriptRunsNodeTests() async throws {
        let tools = ToolFinder()
        guard let node = tools.node() else { throw XCTSkip("node not found; install with `mise use -g node@lts`") }
        guard tools.nodeRunsTypeScript(node) else { throw XCTSkip("Node.js 23.6+ is needed to run TypeScript natively") }
        let source = """
        import { test } from "node:test";
        import assert from "node:assert/strict";

        function add(a: number, b: number): number {
          return a + b;
        }

        test("adds", () => {
          assert.equal(add(1, 2), 3);
        });

        test("fails on purpose", () => {
          assert.equal(add(1, 2), 4, "math is hard");
        });
        """
        try await run(.typescript, Project(files: ["package.json": "{ \"type\": \"module\" }\n", "math.test.ts": source],
                                           testFile: "math.test.ts", passing: "adds", failing: "fails on purpose",
                                           failureText: "math is hard", cursorLine: 8, runner: .nodeTest))
    }

    func testTypeScriptRunsVitestTests() async throws {
        guard ToolFinder().nodePackageBinary("vitest", projectRoot: nil) != nil, ToolFinder().node() != nil else {
            throw XCTSkip("vitest not found; install with `mise use -g npm:vitest` or add it to the project")
        }
        // Globals mode: the file needs no `import … from "vitest"`, so a globally installed Vitest works.
        let source = """
        function add(a: number, b: number): number {
          return a + b;
        }

        describe("math", () => {
          it("adds", () => {
            expect(add(1, 2)).toBe(3);
          });

          it("fails on purpose", () => {
            expect(add(1, 2), "math is hard").toBe(4);
          });
        });
        """
        try await run(.typescript, Project(files: ["package.json": "{ \"type\": \"module\" }\n", "math.test.ts": source],
                                           testFile: "math.test.ts", passing: "math adds", failing: "math fails on purpose",
                                           failureText: "math is hard", cursorLine: 6, arguments: ["--globals"], runner: .vitest))
    }

    // MARK: WebAssembly

    static let watTests = """
    (module
      (func $add (param $a i32) (param $b i32) (result i32)
        local.get $a
        local.get $b
        i32.add)

      (func (export "test_adds")
        (if (i32.ne (call $add (i32.const 1) (i32.const 2)) (i32.const 3))
          (then unreachable)))

      (func (export "test_fails_on_purpose")
        (if (i32.ne (call $add (i32.const 1) (i32.const 2)) (i32.const 4))
          (then unreachable)))
    )
    """

    func testWasmRunsTestsWithWasmtime() async throws {
        guard ToolFinder().wasmtime() != nil else { throw XCTSkip("wasmtime not found; install with `mise use -g wasmtime`") }
        try await run(.wasm, Project(files: ["math.wat": Self.watTests], testFile: "math.wat",
                                     passing: "test_adds", failing: "test_fails_on_purpose",
                                     failureText: "unreachable", cursorLine: 7, runner: .wasmtimeInvoke))
    }

    func testWasmRunsTestsWithNodeHarness() async throws {
        let tools = ToolFinder()
        guard tools.node() != nil else { throw XCTSkip("node not found; install with `mise use -g node@lts`") }
        guard WasmTesting.converter(tools: tools) != nil else { throw XCTSkip("wasm-tools/wat2wasm not found; install with `mise use -g wasm-tools`") }
        try await run(.wasm, Project(files: ["math.wat": Self.watTests], testFile: "math.wat",
                                     passing: "test_adds", failing: "test_fails_on_purpose",
                                     failureText: "unreachable", cursorLine: 7, runner: .nodeWasm))
    }

    func testWasmRunsWastScripts() async throws {
        guard ToolFinder().wasmtime() != nil else { throw XCTSkip("wasmtime not found; install with `mise use -g wasmtime`") }
        let script = """
        (module
          (func (export "add") (param i32 i32) (result i32)
            local.get 0
            local.get 1
            i32.add))

        (assert_return (invoke "add" (i32.const 1) (i32.const 2)) (i32.const 3))
        (assert_return (invoke "add" (i32.const 1) (i32.const 2)) (i32.const 4))
        (assert_return (invoke "add" (i32.const 2) (i32.const 2)) (i32.const 4))
        """
        try await run(.wasm, Project(files: ["math.wast": script], testFile: "math.wast",
                                     passing: "line 7", failing: "line 8", failureText: "didn't match", cursorLine: 6,
                                     skippedCount: 1))
    }

    // MARK: Driver

    private func run(_ language: Language, _ project: Project) async throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "/tmp/ck-tests-\(language.rawValue)-\(UUID().uuidString.prefix(6))").resolvingSymlinksInPath()
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        for (path, contents) in project.files {
            let url = root.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        let file = root.appendingPathComponent(project.testFile)
        let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n").map { $0 + "\n" }

        let suite = "dev.pyrlyn.CrossKit.e2e-tests.\(UUID().uuidString)"
        defer { removeDefaults(suite) }
        let settings = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
        settings.setTestArguments(project.arguments, for: language)
        if let runner = project.runner { settings.setTestRunner(runner, for: language) }
        settings.testTimeout = 600
        let manager = ServerManager(settings: settings)
        let handler = BridgeHandler(manager: manager, settings: settings, scratchDirectory: root.appendingPathComponent(".scratch"))
        let runs = RunCollector()
        handler.onTestRun = { runs.add($0) }
        let server = BridgeServer(portName: "dev.pyrlyn.CrossKit.e2e-tests.\(UUID().uuidString.prefix(6))") { await handler.handle($0) }
        try server.start()
        defer { server.stop() }
        let transport = BridgeClient(portName: server.portName, timeout: 660)
        let engine = EditorCommandEngine()
        func buffer(_ lines: [String], line: Int) -> EditorBuffer {
            EditorBuffer(lines: lines, selection: .caret(line, 4), contentUTI: "public.\(language.rawValue)-source", filePath: file.path)
        }

        // 1. Run every test in the file.
        let all = try await engine.run(.runTestsInFile, buffer: buffer(lines, line: 0), transport: transport)
        let message = all.message ?? ""
        print("[e2e-tests] \(language.displayName) file run:\n\(message)")
        var expected = "\(project.passedCount) passed, \(project.failedCount) failed"
        if project.skippedCount > 0 { expected += ", \(project.skippedCount) skipped" }
        XCTAssertTrue(message.contains(expected), message)
        let run = try XCTUnwrap(runs.last)
        let pass = try XCTUnwrap(run.tests.first { $0.name.contains(project.passing) }, "\(run.tests.map(\.name))")
        let fail = try XCTUnwrap(run.tests.first { $0.name.contains(project.failing) }, "\(run.tests.map(\.name))")
        XCTAssertEqual(pass.status, .passed)
        XCTAssertEqual(fail.status, .failed)
        XCTAssertTrue(fail.output?.contains(project.failureText) == true, fail.output ?? "no output")
        XCTAssertEqual(fail.file, file.path)
        XCTAssertNotNil(fail.line, "failing test should link to its line")
        let annotated = EditorCommandEngine.apply(all.operations, to: lines).lines
        XCTAssertEqual(annotated.filter(EditorCommandEngine.isTestMarker).count,
                       project.markers ?? (project.passedCount + project.failedCount + project.skippedCount), "one marker per test")
        XCTAssertTrue(annotated.contains { $0.contains("✗ failed") })

        // 2. Run only the test under the cursor (markers from step 1 must not confuse discovery).
        let cursorLine = project.cursorLine + annotated.prefix(project.cursorLine + 1).filter(EditorCommandEngine.isTestMarker).count
        let one = try await engine.run(.runTestAtCursor, buffer: buffer(annotated, line: cursorLine), transport: transport)
        print("[e2e-tests] \(language.displayName) cursor run:\n\(one.message ?? "")")
        let single = try XCTUnwrap(runs.last)
        XCTAssertEqual(single.scope, .cursor)
        XCTAssertEqual(single.tests.count, 1, "\(single.tests.map(\.name))")
        XCTAssertEqual(single.tests.first?.status, .passed)
        XCTAssertTrue(one.message?.contains("1 passed") == true, one.message ?? "")
        await manager.shutdownAll()
        XCTAssertTrue(ProcessRegistry.activeGroups().isEmpty, "test runner processes must not outlive the run")
    }
}

private final class RunCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var runs: [TestRunResult] = []
    func add(_ run: TestRunResult) { lock.lock(); runs.append(run); lock.unlock() }
    var last: TestRunResult? { lock.lock(); defer { lock.unlock() }; return runs.last }
}
