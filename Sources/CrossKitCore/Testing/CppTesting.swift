import Foundation

/// C++ tests: discovery of GoogleTest / Catch2 / doctest declarations, CMake + CTest commands and CTest results.
public enum CppTesting {
    // MARK: Discovery

    private static let gtest = try! NSRegularExpression(
        pattern: #"^\s*(TEST|TEST_F|TEST_P|TYPED_TEST|TYPED_TEST_P|FRIEND_TEST)\s*\(\s*([A-Za-z_]\w*)\s*,\s*([A-Za-z_]\w*)\s*\)"#)
    private static let catchCase = try! NSRegularExpression(
        pattern: #"^\s*(TEST_CASE|SCENARIO|TEST_CASE_METHOD|TEMPLATE_TEST_CASE|TEST_CASE_FIXTURE)\s*\(\s*(?:[A-Za-z_][\w:<>]*\s*,\s*)?"((?:[^"\\]|\\.)*)""#)

    public static func discover(_ lines: [String]) -> [DiscoveredTest] {
        var result: [DiscoveredTest] = []
        var inBlockComment = false
        for (index, raw) in lines.enumerated() {
            var line = raw
            if inBlockComment {
                guard let end = line.range(of: "*/") else { continue }
                line = String(line[end.upperBound...]); inBlockComment = false
            }
            if let start = line.range(of: "/*"), line.range(of: "*/", range: start.upperBound..<line.endIndex) == nil {
                line = String(line[..<start.lowerBound]); inBlockComment = true
            }
            if let comment = line.range(of: "//") { line = String(line[..<comment.lowerBound]) }
            let range = NSRange(line.startIndex..., in: line)
            if let m = gtest.firstMatch(in: line, range: range),
               let macro = Range(m.range(at: 1), in: line), let suite = Range(m.range(at: 2), in: line), let name = Range(m.range(at: 3), in: line) {
                let macroName = String(line[macro])
                guard macroName != "FRIEND_TEST" else { continue }
                let s = String(line[suite]), n = String(line[name])
                // Parameterized and typed tests are registered as Prefix/Suite.Name/0 and Suite/0.Name.
                let pattern = "(^|/)" + NSRegularExpression.escapedPattern(for: s) + "(/[0-9]+)?\\." + NSRegularExpression.escapedPattern(for: n) + "(/.*)?$"
                result.append(DiscoveredTest(name: "\(s).\(n)", filter: "\(s).\(n)", line: index, className: s, matchPattern: pattern))
            } else if let m = catchCase.firstMatch(in: line, range: range),
                      let macro = Range(m.range(at: 1), in: line), let nameRange = Range(m.range(at: 2), in: line) {
                var name = unescape(String(line[nameRange]))
                if line[macro] == "SCENARIO" { name = "Scenario: " + name }
                // Template test cases are registered as "name - int", "name - float", …
                let pattern = "^" + NSRegularExpression.escapedPattern(for: name) + "( - .*)?$"
                result.append(DiscoveredTest(name: name, filter: name, line: index, matchPattern: pattern))
            }
        }
        return result
    }

    static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
    }

    // MARK: Project

    /// The outermost directory with a CMakeLists.txt (the one with `project()`), else the file's directory.
    public static func projectRoot(for file: URL) -> URL? {
        let fm = FileManager.default
        var current = file.deletingLastPathComponent()
        var found: URL?
        let stop = SharedPaths.realHomeDirectory.path
        while true {
            if fm.fileExists(atPath: current.appendingPathComponent("CMakeLists.txt").path) { found = current } else if found != nil { break }
            let parent = current.deletingLastPathComponent()
            if current.path == "/" || parent.path == current.path || current.path == stop { break }
            current = parent
        }
        return found
    }

    /// CrossKit's own CMake build tree for a project (outside the source tree), per variant (debug, coverage).
    public static func buildDirectory(root: URL, variant: String, workDirectory: URL) -> URL {
        var h: UInt64 = 1469598103934665603
        for b in root.path.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        let dir = workDirectory.appendingPathComponent("builds/\(root.lastPathComponent)-\(String(h, radix: 36))/cmake-\(variant)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// CMake's regex dialect has no `\d` or non-capturing groups; escape everything special.
    public static func cmakeRegexEscape(_ s: String) -> String {
        var out = ""
        for ch in s {
            if "^$.*+?[]()|\\".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    /// CTest `-R` expression selecting tests (parameterized variants included).
    public static func ctestRegex(for tests: [DiscoveredTest]) -> String {
        tests.map { test -> String in
            let escaped = cmakeRegexEscape(test.filter)
            if test.className != nil, let dot = test.filter.firstIndex(of: ".") {
                let suite = cmakeRegexEscape(String(test.filter[..<dot]))
                let name = cmakeRegexEscape(String(test.filter[test.filter.index(after: dot)...]))
                // CMake's regex dialect: `^` only anchors at the start, no `\d`.
                return "^([^/]*/)?\(suite)(/[0-9]+)?\\.\(name)(/.*)?$"
            }
            return "^\(escaped)( - .*)?$"
        }.joined(separator: "|")
    }

    /// `cmake` configure + build, then the given commands, as one `/bin/sh` script (stops when the build fails).
    public static func buildScript(cmake: String, root: URL, buildDirectory: URL, configureArguments: [String], then commands: [[String]]) -> String {
        let q = DebugService.shellQuote
        var lines = ["set -e"]
        lines.append(([cmake, "-S", root.path, "-B", buildDirectory.path, "-DCMAKE_BUILD_TYPE=Debug", "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON"]
                      + configureArguments).map(q).joined(separator: " "))
        lines.append([cmake, "--build", buildDirectory.path, "--parallel"].map(q).joined(separator: " "))
        lines.append("set +e")
        for command in commands { lines.append(command.map(q).joined(separator: " ")) }
        return lines.joined(separator: "\n")
    }

    // MARK: Results

    private static let consoleLine = try! NSRegularExpression(
        pattern: #"^\s*\d+/\d+\s+Test\s+#\d+:\s+(.+?)\s+\.+\s*(\*\*\*)?\s*(Passed|Failed|Not Run|Exception|Timeout|Disabled|Skipped|SegFault|Subprocess aborted|[A-Za-z ]+?)\s+[\d.]+\s+sec"#)

    /// CTest console summary lines: ` 1/3 Test #1: Math.adds ........   Passed    0.01 sec`.
    public static func parseConsole(_ output: String) -> [TestCaseResult] {
        output.components(separatedBy: "\n").compactMap { line in
            let range = NSRange(line.startIndex..., in: line)
            guard let m = consoleLine.firstMatch(in: line, range: range),
                  let name = Range(m.range(at: 1), in: line), let status = Range(m.range(at: 3), in: line) else { return nil }
            let word = String(line[status])
            let state: TestStatus = word == "Passed" ? .passed : (["Not Run", "Disabled", "Skipped"].contains(word) ? .skipped : .failed)
            return TestCaseResult(name: String(line[name]), status: state, output: state == .failed ? word : nil)
        }
    }

    /// CTest's JUnit report (`--output-junit`): one testcase per CTest test, `status="run|fail|notrun|disabled"`.
    public static func parseJUnit(_ data: Data) -> [TestCaseResult] {
        let delegate = CTestJUnitDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.results
    }
}

private final class CTestJUnitDelegate: NSObject, XMLParserDelegate {
    var results: [TestCaseResult] = []
    private var current: TestCaseResult?
    private var text = ""
    private var capturing = false

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        switch element {
        case "testcase":
            let status = attributes["status"] ?? "run"
            let state: TestStatus = status == "fail" ? .failed : (status == "run" ? .passed : .skipped)
            current = TestCaseResult(name: attributes["name"] ?? "?", status: state, duration: attributes["time"].flatMap(Double.init))
        case "failure", "error":
            current?.status = .failed
            if let message = attributes["message"], !message.isEmpty { current?.output = message }
        case "skipped":
            if current?.status != .failed { current?.status = .skipped }
        case "system-out", "system-err":
            text = ""; capturing = current != nil
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { if capturing { text += string } }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { if capturing { text += String(decoding: CDATABlock, as: UTF8.self) } }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        switch element {
        case "system-out", "system-err":
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if capturing, !trimmed.isEmpty {
                let existing = current?.output ?? ""
                current?.output = existing.isEmpty ? trimmed : existing + "\n" + trimmed
            }
            capturing = false
        case "testcase":
            if let current { results.append(current) }
            current = nil
        default: break
        }
    }
}
