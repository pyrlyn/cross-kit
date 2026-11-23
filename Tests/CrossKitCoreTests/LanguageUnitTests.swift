import XCTest
@testable import CrossKitCore

/// Unit tests for the C++, JavaScript/TypeScript and WebAssembly support (no tools needed).
final class LanguageUnitTests: XCTestCase {

    // MARK: Languages

    func testLanguageGuessForNewLanguages() {
        XCTAssertEqual(Language.guess(fromPath: "/p/a.cpp"), .cpp)
        XCTAssertEqual(Language.guess(fromPath: "/p/a.hpp"), .cpp)
        XCTAssertEqual(Language.guess(fromPath: "/p/a.mjs"), .javascript)
        XCTAssertEqual(Language.guess(fromPath: "/p/a.tsx"), .typescript)
        XCTAssertEqual(Language.guess(fromPath: "/p/a.wat"), .wasm)
        XCTAssertEqual(Language.guess(fromPath: "/p/a.wast"), .wasm)
        XCTAssertEqual(Language.wasm.lineCommentPrefix, ";;")
        XCTAssertEqual(Language.cpp.lineCommentPrefix, "//")
    }

    // MARK: File icons

    func testFileIconStyles() {
        XCTAssertEqual(FileIconStyle.forFile("/x/main.cpp").badge, "C++")
        XCTAssertEqual(FileIconStyle.forFile("/x/main.hpp").badge, "H++")
        XCTAssertEqual(FileIconStyle.forFile("a.js").badge, "JS")
        XCTAssertEqual(FileIconStyle.forFile("a.ts").badge, "TS")
        XCTAssertEqual(FileIconStyle.forFile("types.d.ts").badge, "D.TS")
        XCTAssertEqual(FileIconStyle.forFile("m.wat").badge, "WAT")
        XCTAssertEqual(FileIconStyle.forFile("m.wasm").badge, "WASM")
        XCTAssertEqual(FileIconStyle.forFile("Main.kt").badge, "KT")
        XCTAssertEqual(FileIconStyle.forFile("main.zig").badge, "ZIG")
        XCTAssertEqual(FileIconStyle.forFile("lib.rs").badge, "RS")
        XCTAssertEqual(FileIconStyle.forFile("App.swift").badge, "SWIFT")
        XCTAssertEqual(FileIconStyle.forFile("Main.java").badge, "JAVA")
        XCTAssertEqual(FileIconStyle.forFile("CMakeLists.txt").badge, "CMAKE")
        XCTAssertEqual(FileIconStyle.forFile("README.markdown").badge, "MARK")
        XCTAssertEqual(FileIconStyle.forFile("Makefile").badge, "")
        // JavaScript's yellow band needs dark text; every language has an icon.
        XCTAssertEqual(FileIconStyle.forExtension("js").textColor, 0x1F1F1F)
        for language in Language.allCases {
            XCTAssertFalse(FileIconStyle.forLanguage(language).badge.isEmpty, language.rawValue)
        }
        let c = FileIconStyle.components(0xFF8000)
        XCTAssertEqual(c.red, 1); XCTAssertEqual(c.green, 128.0 / 255, accuracy: 0.001); XCTAssertEqual(c.blue, 0)
    }

    // MARK: C++ tests

    func testCppDiscoversGoogleTestAndCatch2() {
        let lines = ["#include <gtest/gtest.h>", "TEST(Math, Adds) {", "}", "// TEST(Old, Gone) {}", "TEST_F(Fixture, Works) {}",
                     "TEST_CASE(\"vectors grow\", \"[vec]\") {}", "SCENARIO(\"login\") {}", "FRIEND_TEST(A, B);"]
        let tests = CppTesting.discover(lines)
        XCTAssertEqual(tests.map(\.name), ["Math.Adds", "Fixture.Works", "vectors grow", "Scenario: login"])
        XCTAssertEqual(tests.map(\.line), [1, 4, 5, 6])
        XCTAssertEqual(tests[0].className, "Math")
    }

    func testCTestRegexMatchesParameterizedNames() throws {
        let tests = CppTesting.discover(["TEST_P(Suite, Name) {}", "TEST_CASE(\"a+b\") {}"])
        let regex = CppTesting.ctestRegex(for: tests)
        XCTAssertEqual(regex, #"^([^/]*/)?Suite(/[0-9]+)?\.Name(/.*)?$|^a\+b( - .*)?$"#)
        for name in ["Suite.Name", "Inst/Suite.Name/0", "Suite/1.Name", "a+b", "a+b - int"] {
            XCTAssertNotNil(name.range(of: regex, options: .regularExpression), name)
        }
        XCTAssertNil("OtherSuite.Name".range(of: regex, options: .regularExpression))
    }

    func testCTestJUnitAndConsoleParsing() {
        let xml = """
        <?xml version="1.0"?><testsuite tests="2"><testcase name="Math.adds" time="0.01" status="run"/>\
        <testcase name="Math.fails" time="0.02" status="fail"><failure message="boom"/><system-out>expected 3</system-out></testcase></testsuite>
        """
        let results = CppTesting.parseJUnit(Data(xml.utf8))
        XCTAssertEqual(results.map(\.name), ["Math.adds", "Math.fails"])
        XCTAssertEqual(results.map(\.status), [.passed, .failed])
        let console = CppTesting.parseConsole("1/2 Test #1: Math.adds ........   Passed    0.01 sec\n2/2 Test #2: Math.fails .......***Failed    0.02 sec\n")
        XCTAssertEqual(console.map(\.status), [.passed, .failed])
    }

    func testCMakeFileAPIParsesCTestJSON() {
        let json = #"{"kind":"ctestInfo","tests":[{"name":"Math.adds","command":["/b/math_test","Math.adds"]},{"name":"noop"}]}"#
        let tests = CMakeFileAPI.parseTests(Data(json.utf8))
        XCTAssertEqual(tests.map(\.name), ["Math.adds", "noop"])
        XCTAssertEqual(tests[0].command, ["/b/math_test", "Math.adds"])
        XCTAssertEqual(tests[1].command, [])
    }

    func testCMakeCompiledPathUsesLogicalSourceDirectory() throws {
        let build = FileManager.default.temporaryDirectory.appendingPathComponent("ck-cmake-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: build) }
        try "CMAKE_HOME_DIRECTORY:INTERNAL=/tmp\n".write(to: build.appendingPathComponent("CMakeCache.txt"), atomically: true, encoding: .utf8)
        XCTAssertEqual(CMakeFileAPI.compiledPath("/private/tmp/x/main.cpp", buildDirectory: build), "/tmp/x/main.cpp")
        XCTAssertEqual(CMakeFileAPI.compiledPath("/Users/a/main.cpp", buildDirectory: build), "/Users/a/main.cpp")
        XCTAssertEqual(CMakeFileAPI.compiledPath("/p/a.cpp", buildDirectory: build.appendingPathComponent("missing")), "/p/a.cpp")
    }

    // MARK: JavaScript / TypeScript tests

    func testJSDiscoversNestedSuites() {
        let lines = ["import { describe, it } from 'vitest'", "describe('math', () => {", "  it('adds', () => {", "    expect(1 + 1).toBe(2)",
                     "  })", "  // it('commented', () => {})", "  test.skip(\"subtracts\", () => {})", "})", "test('top level', () => {})",
                     "const s = 'it(\"not a test\")'"]
        let tests = JSTesting.discover(lines)
        XCTAssertEqual(tests.map(\.name), ["adds", "subtracts", "top level"])
        XCTAssertEqual(tests.map(\.filter), ["math adds", "math subtracts", "top level"])
        XCTAssertEqual(tests[0].className, "math")
        XCTAssertNil(tests[2].className)
        let pattern = JSTesting.namePattern(for: tests[0])
        XCTAssertNotNil("math > adds".range(of: pattern, options: .regularExpression))
        XCTAssertNotNil("math adds".range(of: pattern, options: .regularExpression))
    }

    func testJSCodeOnlyBlanksStringsAndComments() {
        var block = false
        let code = JSTesting.codeOnly("f('{') // }", inBlockComment: &block)
        XCTAssertEqual(code.filter { $0 == "{" || $0 == "}" }.count, 0)
        _ = JSTesting.codeOnly("/* start", inBlockComment: &block)
        XCTAssertTrue(block)
        _ = JSTesting.codeOnly("end */ x", inBlockComment: &block)
        XCTAssertFalse(block)
    }

    func testJestJSONAndJUnitParsing() {
        let jest = #"{"testResults":[{"name":"/p/a.test.ts","assertionResults":[{"fullName":"math adds","title":"adds","status":"passed","duration":3},{"fullName":"math fails","title":"fails","status":"failed","failureMessages":["\u001b[31mexpected\u001b[39m"]},{"fullName":"later","title":"later","status":"pending"}]}]}"#
        let results = JSTesting.parseJestJSON(Data(jest.utf8))
        XCTAssertEqual(results.map(\.status), [.passed, .failed, .skipped])
        XCTAssertEqual(results[1].output?.contains("\u{1B}"), false)
        let xml = #"<testsuites><testsuite name="a.test.ts"><testcase classname="a.test.ts" name="math &gt; adds" time="0.001"/><testcase classname="a.test.ts" name="math &gt; fails"><failure message="x">trace</failure></testcase><testcase name="todo"><skipped/></testcase></testsuite></testsuites>"#
        let junit = JSTesting.parseJUnit(Data(xml.utf8))
        XCTAssertEqual(junit.map(\.status), [.passed, .failed, .skipped])
    }

    // MARK: WebAssembly

    static let wat = """
    (module
      (import "env" "log" (func $log (param i32)))
      (func $add (export "add") (param $a i32) (param $b i32) (result i32)
        local.get $a
        local.get $b
        i32.add)
      (func $test_add (export "test_add") (result i32)
        (if (result i32) (i32.eq (call $add (i32.const 1) (i32.const 2)) (i32.const 3))
          (then (i32.const 1))
          (else (i32.const 0))))
      (func $helper (result i32) i32.const 7)
      (export "testHelper" (func $helper)))
    """

    func testWatFunctionsAndTestExports() throws {
        // Inline imports only shift the index space (they are counted, not listed).
        let functions = WatSource.functions(Self.wat)
        XCTAssertEqual(WatSource.importedFunctionCount(Self.wat), 1)
        XCTAssertEqual(functions.map(\.name), ["$add", "$test_add", "$helper"])
        XCTAssertEqual(functions.map(\.index), [1, 2, 3])
        XCTAssertEqual(functions.map(\.isImport), [false, false, false])
        XCTAssertEqual(functions[0].exports, ["add"])
        XCTAssertEqual(functions[2].exports, ["testHelper"])
        XCTAssertEqual(functions[0].startLine, 2)
        XCTAssertEqual(functions[0].endLine, 5)
        XCTAssertEqual(WatSource.testExports(Self.wat).map(\.name), ["test_add", "testHelper"])
        XCTAssertEqual(WatSource.function(atLine: 4, in: Self.wat)?.name, "$add")
        XCTAssertNil(WatSource.function(atLine: 0, in: Self.wat))
    }

    func testWastAssertions() {
        let wast = "(module (func (export \"one\") (result i32) i32.const 1))\n(assert_return (invoke \"one\") (i32.const 1))\n;; (assert_trap (invoke \"x\") \"y\")\n(assert_trap (invoke \"one\") \"unreachable\")\n"
        let tests = WatSource.wastAssertions(wast)
        XCTAssertEqual(tests.map(\.filter), ["2", "4"])
        XCTAssertEqual(tests.map(\.name), ["assert_return (line 2)", "assert_trap (line 4)"])
    }

    func testWatInstrumenterAddsCountersPerFunctionAndBranch() {
        let (text, probes) = WatInstrumenter.instrument(Self.wat)
        XCTAssertEqual(probes.filter { $0.kind == .function }.map(\.line), [2, 6, 10])
        XCTAssertEqual(probes.filter { $0.kind == .then }.count, 1)
        XCTAssertEqual(probes.filter { $0.kind == .else }.count, 1)
        for probe in probes {
            XCTAssertTrue(text.contains("(global $\(probe.globalName) (export \"\(probe.globalName)\") (mut i32) (i32.const 0))"), probe.globalName)
            XCTAssertTrue(text.contains("global.get $\(probe.globalName)"))
        }
        // Imports are not instrumented and the structure stays balanced.
        XCTAssertEqual(text.filter { $0 == "(" }.count, text.filter { $0 == ")" }.count)
    }

    func testWasmBinaryParsesMinimalModule() throws {
        let bytes: [UInt8] = [0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00,
                              0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7F,
                              0x03, 0x02, 0x01, 0x00,
                              0x07, 0x0A, 0x01, 0x06, 0x61, 0x6E, 0x73, 0x77, 0x65, 0x72, 0x00, 0x00,
                              0x0A, 0x06, 0x01, 0x04, 0x00, 0x41, 0x2A, 0x0B]
        let module = try WasmBinary.parse(Data(bytes))
        XCTAssertEqual(module.version, 1)
        XCTAssertEqual(module.sections.map(\.name), ["type", "function", "export", "code"])
        XCTAssertEqual(module.types.first?.description, "() -> (i32)")
        XCTAssertEqual(module.exports.first?.name, "answer")
        XCTAssertEqual(module.exports.first?.kind, "func")
        XCTAssertEqual(module.functions.count, 1)
        XCTAssertEqual(module.functions[0].endOffset, bytes.count, "end offset is exclusive (after the `end` opcode)")
        XCTAssertEqual(module.displayName(ofFunction: 0), "\"answer\"", "unnamed functions are shown by their export name")
        XCTAssertThrowsError(try WasmBinary.parse(Data([0x00, 0x61, 0x73, 0x6E])))
        XCTAssertTrue(WasmBinary.hexDump(Data(bytes), limit: 16).hasPrefix("00000000"))
    }

    func testWasmInvokeOutputParsing() {
        let output = """
        CROSSKIT_TEST test_ok
        1
        CROSSKIT_EXIT 0
        CROSSKIT_TEST test_zero
        0
        CROSSKIT_EXIT 0
        CROSSKIT_TEST test_trap
        Error: wasm trap: unreachable
        CROSSKIT_EXIT 134
        """
        let results = WasmTesting.parseInvoke(output)
        XCTAssertEqual(results.map(\.name), ["test_ok", "test_zero", "test_trap"])
        XCTAssertEqual(results.map(\.status), [.passed, .failed, .failed])
        XCTAssertEqual(results[1].output, "returned 0")
        XCTAssertTrue(results[2].output?.contains("unreachable") == true)
    }

    func testWastOutputParsing() {
        let tests = [DiscoveredTest(name: "a", filter: "2", line: 1), DiscoveredTest(name: "b", filter: "4", line: 3),
                     DiscoveredTest(name: "c", filter: "6", line: 5)]
        let failing = WasmTesting.parseWast("Error: failed directive on m.wast:4:2\n", exitCode: 1, tests: tests)
        XCTAssertEqual(failing.map(\.status), [.passed, .failed, .skipped])
        XCTAssertEqual(WasmTesting.parseWast("", exitCode: 0, tests: tests).map(\.status), [.passed, .passed, .passed])
        XCTAssertEqual(WasmTesting.parseWast("parse error", exitCode: 1, tests: tests).map(\.status), [.failed, .failed, .failed])
    }

    // MARK: Coverage

    func testLCOVParsingAndUncoveredRanges() {
        let lcov = """
        TN:
        SF:src/math.ts
        FN:1,add
        FN:5,unused
        FNDA:3,add
        FNDA:0,unused
        DA:1,3
        DA:2,3
        DA:5,0
        DA:6,0
        DA:8,0
        DA:10,1
        BRF:2
        BRH:1
        end_of_record
        SF:/abs/other.ts
        DA:1,0
        end_of_record
        SF:src/math.ts
        DA:5,2
        end_of_record
        """
        let files = LCOVParser.parse(lcov, baseDirectory: "/proj")
        XCTAssertEqual(files.map(\.path), ["/proj/src/math.ts", "/abs/other.ts"])
        let math = files[0]
        XCTAssertEqual(math.lines[5], 2, "repeated records are merged")
        XCTAssertEqual(math.functions.map(\.hits), [3, 0])
        XCTAssertEqual(math.branchesFound, 2)
        XCTAssertEqual(math.linesFound, 6)
        XCTAssertEqual(math.linesHit, 4)
        XCTAssertEqual(math.uncoveredRanges, [6...8])
        let report = CoverageReport(language: .typescript, tool: "node --test", projectRoot: "/proj", files: files)
        XCTAssertEqual(report.linesFound, 7)
        XCTAssertEqual(report.percent, 400.0 / 7, accuracy: 0.01)
        XCTAssertNotNil(report.file("/proj/src/math.ts"))
    }

    func testCoverageSummaryAndMarkers() {
        var file = FileCoverage(path: "/p/a.cpp")
        file.lines = [1: 1, 2: 0, 3: 0, 5: 4]
        let run = TestRunResult(language: .cpp, runner: .ctest, scope: .file, command: "ctest", workingDirectory: "/p", filePath: "/p/a.cpp")
        let report = CoverageReport(language: .cpp, tool: "llvm-cov", projectRoot: "/p", files: [file], testRun: run)
        let summary = EditorCommandEngine.coverageSummary(report, run: run, file: "/p/a.cpp")
        XCTAssertTrue(summary.contains("50"), summary)
    }

    // MARK: Editor markers for WebAssembly

    func testWatMarkersUseSemicolonComments() {
        let buffer = EditorBuffer(lines: ["(module)\n"], selection: .caret(0, 0), contentUTI: "public.plain-text", filePath: "/p/a.wat")
        XCTAssertEqual(EditorCommandEngine.commentPrefix(for: buffer), ";;")
        let canonical = EditorCommandEngine.toCanonicalMarker("  ;; [CrossKit] ✓ passed\n", prefix: ";;")
        XCTAssertEqual(canonical, "  // [CrossKit] ✓ passed\n")
        XCTAssertEqual(EditorCommandEngine.fromCanonicalMarker(canonical, prefix: ";;"), "  ;; [CrossKit] ✓ passed\n")
        XCTAssertTrue(EditorCommandEngine.isTestMarker("  ;; [CrossKit] ▶ test_add"))
    }

    // MARK: Debugging helpers

    func testCDPHelpers() {
        let banner = "Debugger listening on ws://127.0.0.1:9229/7f0c1a2b-1111-2222-3333-444455556666\nFor help, see: https://nodejs.org/en/docs/inspector"
        XCTAssertEqual(CDPClient.webSocketURL(inBanner: banner)?.absoluteString, "ws://127.0.0.1:9229/7f0c1a2b-1111-2222-3333-444455556666")
        XCTAssertNil(CDPClient.webSocketURL(inBanner: "nothing"))
        let regex = CDPClient.urlRegex(forFile: "/Users/a/my app/x.test.ts")
        XCTAssertNotNil("file:///Users/a/my%20app/x.test.ts".removingPercentEncoding!.range(of: regex, options: .regularExpression))
        XCTAssertNil("file:///Users/a/my app/xxtest.ts".range(of: regex, options: .regularExpression))
        let tmp = CDPClient.urlRegex(forFile: "/private/tmp/a.js")
        XCTAssertNotNil("file:///tmp/a.js".range(of: tmp, options: .regularExpression))
        XCTAssertNotNil("file:///private/tmp/a.js".range(of: tmp, options: .regularExpression))
        XCTAssertEqual(CDPClient.path(fromURL: "file:///Users/a/my%20app/x.ts"), "/Users/a/my app/x.ts")
        XCTAssertNil(CDPClient.path(fromURL: "node:internal/main"))
    }

    func testDebuggerChoicesForNewLanguages() {
        XCTAssertTrue(DebuggerKind.choices(for: .javascript).contains(.nodeInspector))
        XCTAssertTrue(DebuggerKind.choices(for: .typescript).contains(.nodeAttach))
        XCTAssertTrue(DebuggerKind.choices(for: .cpp).contains(.lldbDAP))
        XCTAssertTrue(DebuggerKind.choices(for: .wasm).contains(.nodeInspector))
        XCTAssertTrue(DebuggerKind.nodeInspector.usesCDP)
        XCTAssertTrue(DebuggerKind.nodeInspector.isControlled)
        XCTAssertFalse(DebuggerKind.nodeInspect.isControlled)
    }
}
