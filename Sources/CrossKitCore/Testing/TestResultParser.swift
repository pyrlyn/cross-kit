import Foundation

/// Parses runner output (or JUnit XML) into per-test results.
public enum TestResultParser {
    public static func parse(kind: TestRunnerKind, output: String, reportsDirectory: String? = nil, since: Date? = nil,
                             reportFile: String? = nil) -> [TestCaseResult] {
        let report = reportFile.flatMap { FileManager.default.contents(atPath: $0) }
        switch kind {
        case .ctest:
            let xml = report.map(CppTesting.parseJUnit) ?? []
            return xml.isEmpty ? CppTesting.parseConsole(output) : xml
        case .vitest, .nodeTest, .bunTest:
            return report.map(JSTesting.parseJUnit) ?? []
        case .jest:
            return report.map(JSTesting.parseJestJSON) ?? []
        case .wasmtimeInvoke:
            return WasmTesting.parseInvoke(output)
        case .nodeWasm:
            return WasmHarness.parse(output).results
        case .wasmtimeWast:
            return []   // needs the discovered assertions: see WasmTesting.parseWast

        case .zigTest: return zigTest(output)
        case .zigBuild: return zigBuild(output)
        case .cargoTest: return libtest(output)
        case .cargoNextest: return nextest(output)
        case .gradle, .gradleWrapper:
            var xml = reportsDirectory.map { junitReports(in: $0, modifiedSince: since) } ?? []
            if xml.isEmpty, let reportsDirectory, gradleTestTaskSkipped(output) {
                // The test task was UP-TO-DATE (or restored from the build cache): it ran no tests and the
                // reports of its last execution, with the same filter, are still current.
                xml = junitReports(in: reportsDirectory, modifiedSince: nil)
            }
            return xml.isEmpty ? gradleConsole(output) : xml
        }
    }

    // MARK: zig test — `1/3 main.test.add works...OK`, `2/3 main.test.x...FAIL (Err)`, `...SKIP`

    private static let zigLine = try! NSRegularExpression(
        pattern: #"^\d+/\d+ (?:[\w.]+?\.)?(?:test|decltest)\.(.*?)\.\.\.(.*)$"#)

    public static func zigTest(_ output: String) -> [TestCaseResult] {
        // Each test starts with `i/n name...`; whatever follows (prints, `OK`, `FAIL (...)`, traces)
        // belongs to it until the next test line or the final summary.
        var blocks: [(name: String, lines: [String])] = []
        for line in output.components(separatedBy: "\n") {
            let range = NSRange(line.startIndex..., in: line)
            if let m = zigLine.firstMatch(in: line, range: range),
               let nameRange = Range(m.range(at: 1), in: line), let restRange = Range(m.range(at: 2), in: line) {
                blocks.append((String(line[nameRange]), [String(line[restRange])]))
            } else if (line.hasPrefix("All ") && line.hasSuffix("tests passed."))
                        || line.range(of: #"^\d+ passed; \d+ skipped; \d+ failed\."#, options: .regularExpression) != nil
                        || line.hasPrefix("error: the following test command") {
                blocks.append(("", []))   // terminator: stop attaching lines to the last test
            } else if !blocks.isEmpty {
                blocks[blocks.count - 1].lines.append(line)
            }
        }
        return blocks.filter { !$0.name.isEmpty }.map { block in
            let trimmed = block.lines.map { $0.trimmingCharacters(in: .whitespaces) }
            let status: TestStatus
            if trimmed.contains(where: { $0.hasPrefix("FAIL") || $0.hasSuffix("FAIL") }) {
                status = .failed
            } else if trimmed.contains(where: { $0 == "SKIP" || $0.hasSuffix("SKIP") }) {
                status = .skipped
            } else if trimmed.contains(where: { $0 == "OK" || $0.hasSuffix("OK") }) {
                status = .passed
            } else {
                status = .failed  // crashed before reporting
            }
            let text = block.lines.filter { !["OK", "SKIP"].contains($0.trimmingCharacters(in: .whitespaces)) }
                .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return TestCaseResult(name: block.name, status: status, output: text.isEmpty ? nil : text)
        }
    }

    // MARK: zig build test — per-test lines only for failures: `error: 'main.test.x' failed:`

    private static let zigBuildFailure = try! NSRegularExpression(
        pattern: #"^error: '(?:[\w.]+?\.)?(?:test|decltest)\.(.*)' failed:?$"#)

    public static func zigBuild(_ output: String) -> [TestCaseResult] {
        var results: [TestCaseResult] = []
        var current: [String] = []
        func flush() {
            if !results.isEmpty, !current.isEmpty {
                results[results.count - 1].output = current.map { $0.hasPrefix("       ") ? String($0.dropFirst(7)) : $0 }
                    .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            }
            current = []
        }
        for line in output.components(separatedBy: "\n") {
            if let m = zigBuildFailure.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               let r = Range(m.range(at: 1), in: line) {
                flush()
                results.append(TestCaseResult(name: String(line[r]), status: .failed))
            } else if !results.isEmpty, line.hasPrefix("       ") {
                current.append(line)
            } else if !current.isEmpty {
                flush()
            }
        }
        flush()
        return results
    }

    /// `Build Summary: …; 2/3 tests passed (1 failed)` → (passed, total)
    public static func zigBuildCounts(_ output: String) -> (passed: Int, total: Int)? {
        guard let match = output.range(of: #"(\d+)/(\d+) tests passed"#, options: .regularExpression) else { return nil }
        let numbers = output[match].split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        return numbers.count >= 2 ? (numbers[0], numbers[1]) : nil
    }

    // MARK: cargo test (libtest) — `test path ... ok|FAILED|ignored`, failure output in `---- path stdout ----`

    private static let libtestLine = try! NSRegularExpression(pattern: #"^test (\S+)(?: - .*)? \.\.\. (ok|FAILED|ignored(?:, .*)?)$"#)

    public static func libtest(_ output: String) -> [TestCaseResult] {
        var results: [TestCaseResult] = []
        var index: [String: Int] = [:]
        var sections: [String: [String]] = [:]
        var currentSection: String?
        for line in output.components(separatedBy: "\n") {
            if let m = libtestLine.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               let n = Range(m.range(at: 1), in: line), let s = Range(m.range(at: 2), in: line) {
                currentSection = nil
                let name = String(line[n])
                let raw = String(line[s])
                let status: TestStatus = raw == "ok" ? .passed : raw == "FAILED" ? .failed : .skipped
                if let existing = index[name] { results[existing].status = status } else {
                    index[name] = results.count
                    results.append(TestCaseResult(name: name, status: status))
                }
                continue
            }
            if line.hasPrefix("---- "), line.hasSuffix(" ----") {
                let inner = line.dropFirst(5).dropLast(5)
                currentSection = inner.components(separatedBy: " ").first
                continue
            }
            if line == "failures:" || line == "successes:" || line.hasPrefix("test result:") { currentSection = nil; continue }
            if let section = currentSection { sections[section, default: []].append(line) }
        }
        for (name, lines) in sections {
            if let i = index[name] {
                results[i].output = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return results
    }

    // MARK: cargo nextest — `PASS [   0.010s] (1/2) crate tests::adds`

    private static let nextestLine = try! NSRegularExpression(
        pattern: #"^\s*(PASS|FAIL|SKIP|SIGSEGV|SIGABRT|TIMEOUT|LEAK|FLAKY|TRY \d+ FAIL)\s+\[\s*([\d.]+)s\s*\]\s+(?:\(\d+/\d+\)\s+)?(\S+)\s+(\S+)\s*$"#)

    public static func nextest(_ output: String) -> [TestCaseResult] {
        var results: [TestCaseResult] = []
        var index: [String: Int] = [:]
        var collecting: Int?
        var buffer: [String] = []
        func flush() {
            if let i = collecting, !buffer.isEmpty {
                let text = buffer.map { $0.hasPrefix("    ") ? String($0.dropFirst(4)) : $0 }
                    .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                results[i].output = [results[i].output, text].compactMap { $0 }.joined(separator: "\n")
            }
            buffer = []
        }
        for line in output.components(separatedBy: "\n") {
            if let m = nextestLine.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               let s = Range(m.range(at: 1), in: line), let t = Range(m.range(at: 2), in: line),
               let n = Range(m.range(at: 4), in: line) {
                flush()
                collecting = nil
                let name = String(line[n])
                let raw = String(line[s])
                let status: TestStatus = raw == "PASS" || raw == "FLAKY" ? .passed : raw == "SKIP" ? .skipped : .failed
                if index[name] == nil {
                    index[name] = results.count
                    results.append(TestCaseResult(name: name, status: status, duration: Double(line[t])))
                    if status == .failed { collecting = results.count - 1 }
                }
                continue
            }
            if line.hasPrefix("────") || line.trimmingCharacters(in: .whitespaces).hasPrefix("Summary [") {
                flush(); collecting = nil; continue
            }
            if collecting != nil {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("stdout ───") || trimmed.hasPrefix("stderr ───") { continue }
                buffer.append(line)
            }
        }
        flush()
        return results
    }

    // MARK: Gradle / JUnit XML reports (build/test-results/test/TEST-*.xml)

    public static func junitReports(in directory: String, modifiedSince: Date?) -> [TestCaseResult] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: directory) else { return [] }
        var results: [TestCaseResult] = []
        for file in files.sorted() where file.hasSuffix(".xml") {
            let path = (directory as NSString).appendingPathComponent(file)
            if let since = modifiedSince,
               let modified = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
               modified < since.addingTimeInterval(-1) { continue }
            if let data = fm.contents(atPath: path) { results += junitXML(data) }
        }
        return results
    }

    public static func junitXML(_ data: Data) -> [TestCaseResult] {
        let delegate = JUnitXMLDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.results
    }

    /// Whether Gradle skipped a test task because its outputs were current (`> Task :lib:test UP-TO-DATE`).
    static func gradleTestTaskSkipped(_ output: String) -> Bool {
        output.range(of: #"(?m)^> Task (?:\S*:)?\w*[tT]est (?:UP-TO-DATE|FROM-CACHE)\s*$"#, options: .regularExpression) != nil
    }

    /// Fallback when no XML exists: Gradle console `Class > method() FAILED|PASSED|SKIPPED`.
    public static func gradleConsole(_ output: String) -> [TestCaseResult] {
        output.components(separatedBy: "\n").compactMap { line in
            guard let match = line.range(of: #"^(\S+) > (.+?) (PASSED|FAILED|SKIPPED)$"#, options: .regularExpression) else { return nil }
            let text = String(line[match])
            let parts = text.components(separatedBy: " > ")
            guard parts.count == 2 else { return nil }
            let statusWord = parts[1].components(separatedBy: " ").last ?? ""
            let method = String(parts[1].dropLast(statusWord.count + 1)).replacingOccurrences(of: "()", with: "")
            let status: TestStatus = statusWord == "PASSED" ? .passed : statusWord == "FAILED" ? .failed : .skipped
            return TestCaseResult(name: "\(parts[0]).\(method)", status: status)
        }
    }
}

private final class JUnitXMLDelegate: NSObject, XMLParserDelegate {
    var results: [TestCaseResult] = []
    private var current: TestCaseResult?
    private var text = ""
    private var capturing = false

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        switch element {
        case "testcase":
            var method = attributes["name"] ?? "?"
            if method.hasSuffix("()") { method = String(method.dropLast(2)) }
            let className = attributes["classname"] ?? ""
            current = TestCaseResult(name: className.isEmpty ? method : "\(className).\(method)", status: .passed,
                                     duration: attributes["time"].flatMap(Double.init))
        case "failure", "error":
            current?.status = .failed
            let message = attributes["message"] ?? ""
            current?.output = message
            text = ""
            capturing = true
        case "skipped":
            current?.status = .skipped
        case "system-out", "system-err":
            text = ""
            capturing = current != nil
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturing { text += string }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if capturing, let s = String(data: CDATABlock, encoding: .utf8) { text += s }
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        switch element {
        case "failure", "error", "system-out", "system-err":
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if capturing, !trimmed.isEmpty {
                let existing = current?.output ?? ""
                current?.output = existing.isEmpty || trimmed.hasPrefix(existing) ? trimmed : existing + "\n" + trimmed
            }
            capturing = false
            text = ""
        case "testcase":
            if let current { results.append(current) }
            current = nil
        default:
            break
        }
    }
}
