import Foundation

/// JavaScript/TypeScript tests: `describe`/`test`/`it` discovery, runner detection (Vitest, Jest, node:test,
/// bun test), name patterns and result parsing.
public enum JSTesting {
    // MARK: Discovery

    private static let suiteCall = try! NSRegularExpression(
        pattern: #"(?<![\w.$])(describe|suite|context)(?:\.(?:only|skip|todo|concurrent|sequential|shuffle))*\s*\(\s*(['"`])((?:\\.|(?!\2)[^\\])*)\2"#)
    private static let testCall = try! NSRegularExpression(
        pattern: #"(?<![\w.$])(test|it|specify)(?:\.(?:only|skip|todo|concurrent|sequential|failing|fails))*\s*\(\s*(['"`])((?:\\.|(?!\2)[^\\])*)\2"#)

    public static func discover(_ lines: [String]) -> [DiscoveredTest] {
        var result: [DiscoveredTest] = []
        var suites: [(name: String, depth: Int)] = []
        var depth = 0
        var inBlockComment = false
        for (index, line) in lines.enumerated() {
            let code = codeOnly(line, inBlockComment: &inBlockComment)
            let range = NSRange(line.startIndex..., in: line)
            if let m = suiteCall.firstMatch(in: line, range: range), let r = Range(m.range(at: 3), in: line), isCode(m.range, in: line, code: code) {
                suites.append((unescape(String(line[r])), depth + 1))
            } else if let m = testCall.firstMatch(in: line, range: range), let r = Range(m.range(at: 3), in: line), isCode(m.range, in: line, code: code) {
                let name = unescape(String(line[r]))
                let path = suites.map(\.name) + [name]
                result.append(DiscoveredTest(name: name, filter: path.joined(separator: " "), line: index,
                                             className: suites.isEmpty ? nil : suites.map(\.name).joined(separator: " "),
                                             matchPattern: resultPattern(path)))
            }
            depth += code.filter { $0 == "{" || $0 == "(" }.count - code.filter { $0 == "}" || $0 == ")" }.count
            while let last = suites.last, depth < last.depth { suites.removeLast() }
        }
        return result
    }

    /// The line with string contents and comments blanked out by spaces (same length up to a `//` comment),
    /// so braces in strings do not count and calls inside comments are ignored.
    static func codeOnly(_ line: String, inBlockComment: inout Bool) -> String {
        let chars = Array(line)
        var out = ""
        var quote: Character?
        var escaping = false
        var i = 0
        while i < chars.count {
            let c = chars[i]
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            if inBlockComment {
                if c == "*", next == "/" { inBlockComment = false; out += "  "; i += 2; continue }
                out.append(" "); i += 1; continue
            }
            if let q = quote {
                if escaping { escaping = false } else if c == "\\" { escaping = true } else if c == q { quote = nil; out.append(c); i += 1; continue }
                out.append(" "); i += 1; continue
            }
            if c == "/", next == "/" { break }
            if c == "/", next == "*" { inBlockComment = true; out += "  "; i += 2; continue }
            if c == "'" || c == "\"" || c == "`" { quote = c }
            out.append(c)
            i += 1
        }
        return out
    }

    private static func isCode(_ range: NSRange, in line: String, code: String) -> Bool {
        // The call keyword itself must survive comment stripping.
        guard let r = Range(range, in: line) else { return false }
        let offset = line.distance(from: line.startIndex, to: r.lowerBound)
        return offset < code.count && !code.dropFirst(offset).hasPrefix(" ")
    }

    static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\'", with: "'").replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\`", with: "`").replacingOccurrences(of: "\\\\", with: "\\")
    }

    /// Regex for one name part: printf placeholders (`%s`, `%i`, `$var`) of `test.each` match anything.
    static func partPattern(_ part: String) -> String {
        var escaped = NSRegularExpression.escapedPattern(for: part)
        escaped = escaped.replacingOccurrences(of: #"%[sdifjoOp#]"#, with: ".*", options: .regularExpression)
        escaped = escaped.replacingOccurrences(of: #"\\\$[A-Za-z_][\w.]*|\\\$\\\{[^}]*\\\}"#, with: ".*", options: .regularExpression)
        return escaped
    }

    /// Full-name pattern; parts are joined by a space (Jest, node:test, bun, Vitest ≤ 3) or " > " (Vitest 4+).
    static func resultPattern(_ path: [String]) -> String {
        "^" + path.map(partPattern).joined(separator: "(?: > | )") + "$"
    }

    /// The `-t` / `--test-name-pattern` argument selecting one test.
    public static func namePattern(for test: DiscoveredTest) -> String {
        test.matchPattern ?? ("^" + NSRegularExpression.escapedPattern(for: test.filter) + "$")
    }

    // MARK: Runner detection

    /// Picks the runner from the project's package.json and the file's imports.
    public static func autoKind(file: URL, text: String, projectRoot: URL) -> TestRunnerKind {
        if text.contains("from \"bun:test\"") || text.contains("from 'bun:test'") { return .bunTest }
        if text.contains("node:test") { return .nodeTest }
        if text.contains("from \"vitest\"") || text.contains("from 'vitest'") { return .vitest }
        if text.contains("@jest/globals") { return .jest }
        let deps = packageDependencies(projectRoot)
        if deps.contains("vitest") { return .vitest }
        if deps.contains("jest") || deps.contains("ts-jest") || deps.contains("babel-jest") { return .jest }
        let fm = FileManager.default
        if fm.fileExists(atPath: projectRoot.appendingPathComponent("bun.lockb").path)
            || fm.fileExists(atPath: projectRoot.appendingPathComponent("bun.lock").path) { return .bunTest }
        if fm.fileExists(atPath: projectRoot.appendingPathComponent("vitest.config.ts").path)
            || fm.fileExists(atPath: projectRoot.appendingPathComponent("vitest.config.js").path) { return .vitest }
        return .nodeTest
    }

    static func packageDependencies(_ root: URL) -> Set<String> {
        guard let data = FileManager.default.contents(atPath: root.appendingPathComponent("package.json").path),
              let json = try? JSONDecoder().decode(JSONValue.self, from: data) else { return [] }
        var names = Set<String>()
        for key in ["dependencies", "devDependencies", "peerDependencies"] {
            if case .object(let deps)? = json[key] { names.formUnion(deps.keys) }
        }
        return names
    }

    /// Nearest directory with package.json (else tsconfig/jsconfig, else the file's directory).
    public static func projectRoot(for file: URL) -> URL {
        let fm = FileManager.default
        var current = file.deletingLastPathComponent()
        let stop = SharedPaths.realHomeDirectory.path
        var fallback: URL?
        while true {
            if fm.fileExists(atPath: current.appendingPathComponent("package.json").path) { return current }
            if fallback == nil, ["tsconfig.json", "jsconfig.json", "deno.json"].contains(where: { fm.fileExists(atPath: current.appendingPathComponent($0).path) }) {
                fallback = current
            }
            let parent = current.deletingLastPathComponent()
            if current.path == "/" || parent.path == current.path || current.path == stop { break }
            current = parent
        }
        return fallback ?? file.deletingLastPathComponent()
    }

    // MARK: Results

    /// JUnit XML of Vitest, node:test and bun: names are nested suite names plus the test name; suites named
    /// after files (Vitest, bun) are dropped and Vitest's " > " separators become spaces.
    public static func parseJUnit(_ data: Data) -> [TestCaseResult] {
        let delegate = NestedJUnitDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.results
    }

    /// Jest `--json` output.
    public static func parseJestJSON(_ data: Data) -> [TestCaseResult] {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data) else { return [] }
        var results: [TestCaseResult] = []
        for file in json["testResults"]?.arrayValue ?? [] {
            for assertion in file["assertionResults"]?.arrayValue ?? [] {
                let status: TestStatus
                switch assertion["status"]?.stringValue {
                case "passed": status = .passed
                case "failed": status = .failed
                default: status = .skipped
                }
                let messages = (assertion["failureMessages"]?.arrayValue ?? []).compactMap(\.stringValue).joined(separator: "\n")
                let name = assertion["fullName"]?.stringValue
                    ?? ((assertion["ancestorTitles"]?.arrayValue ?? []).compactMap(\.stringValue) + [assertion["title"]?.stringValue ?? "?"]).joined(separator: " ")
                results.append(TestCaseResult(name: name, status: status, duration: assertion["duration"]?.doubleValue.map { $0 / 1000 },
                                              output: messages.isEmpty ? nil : stripANSI(messages)))
            }
        }
        return results
    }

    static func stripANSI(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
    }

    static func isFileSuite(_ name: String) -> Bool {
        name.contains("/") || [".js", ".mjs", ".cjs", ".jsx", ".ts", ".mts", ".cts", ".tsx"].contains { name.hasSuffix($0) }
    }
}

private final class NestedJUnitDelegate: NSObject, XMLParserDelegate {
    var results: [TestCaseResult] = []
    private var suites: [String] = []
    private var current: TestCaseResult?
    private var text = ""
    private var capturing = false

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        switch element {
        case "testsuite":
            suites.append(attributes["name"] ?? "")
        case "testcase":
            let leaf = (attributes["name"] ?? "?").replacingOccurrences(of: " > ", with: " ")
            let path = suites.filter { !$0.isEmpty && !JSTesting.isFileSuite($0) } + [leaf]
            current = TestCaseResult(name: path.joined(separator: " "), status: .passed, duration: attributes["time"].flatMap(Double.init))
        case "failure", "error":
            current?.status = .failed
            if let message = attributes["message"], !message.isEmpty { current?.output = JSTesting.stripANSI(message) }
            text = ""; capturing = current != nil
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
        case "testsuite":
            if !suites.isEmpty { suites.removeLast() }
        case "failure", "error", "system-out", "system-err":
            let trimmed = JSTesting.stripANSI(text.trimmingCharacters(in: .whitespacesAndNewlines))
            if capturing, !trimmed.isEmpty {
                let existing = current?.output ?? ""
                current?.output = existing.isEmpty || trimmed.hasPrefix(existing) ? trimmed : existing + "\n" + trimmed
            }
            capturing = false
        case "testcase":
            if let current { results.append(current) }
            current = nil
        default: break
        }
    }
}
