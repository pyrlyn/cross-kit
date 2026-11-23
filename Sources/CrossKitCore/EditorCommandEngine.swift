import Foundation

public protocol BridgeTransport: Sendable {
    func send(_ request: BridgeRequest) async throws -> BridgeResponse
}

extension BridgeClient: BridgeTransport {}

public struct EditorPosition: Codable, Equatable, Sendable {
    public var line: Int
    public var column: Int
    public init(line: Int, column: Int) { self.line = line; self.column = column }
}

public struct EditorRange: Codable, Equatable, Sendable {
    public var start: EditorPosition
    public var end: EditorPosition
    public init(start: EditorPosition, end: EditorPosition) { self.start = start; self.end = end }
    public static func caret(_ line: Int, _ column: Int) -> EditorRange {
        EditorRange(start: EditorPosition(line: line, column: column), end: EditorPosition(line: line, column: column))
    }
}

/// Buffer mutations, applied in order. Lines include their trailing "\n" like XcodeKit's `lines`.
public enum BufferOperation: Equatable, Sendable {
    case replaceLines(start: Int, count: Int, with: [String])
    case select(EditorRange)
}

public struct EditorBuffer: Sendable {
    public var lines: [String]
    public var selection: EditorRange
    public var contentUTI: String
    public var filePath: String?

    public init(lines: [String], selection: EditorRange, contentUTI: String, filePath: String? = nil) {
        self.lines = lines
        self.selection = selection
        self.contentUTI = contentUTI
        self.filePath = filePath
    }

    public var text: String { lines.joined() }
}

public struct EditorOutcome: Sendable {
    public var operations: [BufferOperation]
    /// Shown to the user (XcodeKit can only surface it as an alert).
    public var message: String?

    public init(operations: [BufferOperation] = [], message: String? = nil) {
        self.operations = operations
        self.message = message
    }
}

public enum EditorCommand: String, CaseIterable, Codable, Sendable {
    case complete
    case listCompletions
    case goToDefinition
    case findReferences
    case hover
    case diagnostics
    case clearAnnotations
    case showTests
    case runTestsInFile
    case runTestAtCursor
    case debugFileAtCursor
    case debugTestAtCursor
    case buildProject
    case runFile
    case showPreview
    case runTestsWithCoverage
    case showCodeLenses
    case showInlayHints
    case showErrorLens
    case refreshInlineAnnotations
    case clearInlineAnnotations
    case openSettings

    public var displayName: String {
        switch self {
        case .complete: return "Complete at Cursor"
        case .listCompletions: return "List Completions"
        case .goToDefinition: return "Go to Definition"
        case .findReferences: return "Find References"
        case .hover: return "Show Hover Info"
        case .diagnostics: return "Show Diagnostics"
        case .clearAnnotations: return "Clear CrossKit Annotations"
        case .showTests: return "Show Test Markers"
        case .runTestsInFile: return "Run Tests in File"
        case .runTestAtCursor: return "Run Test at Cursor"
        case .debugFileAtCursor: return "Debug File at Cursor"
        case .debugTestAtCursor: return "Debug Test at Cursor"
        case .buildProject: return "Build Project"
        case .runFile: return "Run File"
        case .showPreview: return "Show Preview"
        case .runTestsWithCoverage: return "Run Tests with Coverage"
        case .showCodeLenses: return "Show Code Lenses"
        case .showInlayHints: return "Show Inlay Hints"
        case .showErrorLens: return "Show ErrorLens Diagnostics"
        case .refreshInlineAnnotations: return "Refresh Inline Annotations"
        case .clearInlineAnnotations: return "Clear Inline Annotations"
        case .openSettings: return "Open CrossKit Settings"
        }
    }
}

public enum EditorCommandError: Error, LocalizedError {
    case bridge(String)
    case nothing(String)

    public var errorDescription: String? {
        switch self {
        case .bridge(let message): return message
        case .nothing(let message): return message
        }
    }
}

/// Maps LSP features onto what XcodeKit can do: edit lines and set the selection.
/// Information that has no native UI is inserted as removable `// [CrossKit]` comment lines.
public struct EditorCommandEngine: Sendable {
    public static let marker = "// [CrossKit]"
    public var maxAnnotationLines = 40

    public init() {}

    public func run(_ command: EditorCommand, buffer: EditorBuffer, transport: BridgeTransport) async throws -> EditorOutcome {
        // Languages without `//` comments (WebAssembly text uses `;;`): work on `// [CrossKit]` internally and
        // write the language's own comment marker into the buffer.
        let prefix = Self.commentPrefix(for: buffer)
        guard prefix != "//" else { return try await runCommand(command, buffer: buffer, transport: transport) }
        var mapped = buffer
        mapped.lines = buffer.lines.map { Self.toCanonicalMarker($0, prefix: prefix) }
        var outcome = try await runCommand(command, buffer: mapped, transport: transport)
        outcome.operations = outcome.operations.map { operation in
            guard case .replaceLines(let start, let count, let lines) = operation else { return operation }
            return .replaceLines(start: start, count: count, with: lines.map { Self.fromCanonicalMarker($0, prefix: prefix) })
        }
        return outcome
    }

    /// The line comment of the buffer's language (`//` unless known otherwise).
    public static func commentPrefix(for buffer: EditorBuffer) -> String {
        let language = buffer.filePath.flatMap(Language.guess(fromPath:)) ?? Language.guess(fromUTI: buffer.contentUTI)
        return language?.lineCommentPrefix ?? "//"
    }

    static func toCanonicalMarker(_ line: String, prefix: String) -> String {
        guard line.contains("\(prefix) [CrossKit]") else { return line }
        return line.replacingOccurrences(of: "\(prefix) [CrossKit]", with: marker)
    }

    static func fromCanonicalMarker(_ line: String, prefix: String) -> String {
        guard line.contains(marker) else { return line }
        return line.replacingOccurrences(of: marker, with: "\(prefix) [CrossKit]")
    }

    func runCommand(_ command: EditorCommand, buffer: EditorBuffer, transport: BridgeTransport) async throws -> EditorOutcome {
        switch command {
        case .clearAnnotations: return clearAnnotations(buffer)
        case .openSettings: return EditorOutcome()
        case .complete: return completeAtCursor(buffer, try await call(.completion, buffer, transport))
        case .listCompletions: return listCompletions(buffer, try await call(.completion, buffer, transport))
        case .goToDefinition: return goToDefinition(buffer, try await call(.definition, buffer, transport))
        case .findReferences: return findReferences(buffer, try await call(.references, buffer, transport))
        case .hover: return hover(buffer, try await call(.hover, buffer, transport))
        case .diagnostics: return diagnostics(buffer, try await call(.diagnostics, buffer, transport))
        case .showTests: return try await tests(buffer, operation: .discoverTests, scope: nil, transport: transport)
        case .runTestsInFile: return try await tests(buffer, operation: .runTests, scope: .file, transport: transport)
        case .runTestAtCursor: return try await tests(buffer, operation: .runTests, scope: .cursor, transport: transport)
        case .runTestsWithCoverage: return try await tests(buffer, operation: .coverage, scope: .file, transport: transport)
        case .debugFileAtCursor: return try await debug(buffer, operation: .debugFile, transport: transport)
        case .debugTestAtCursor: return try await debug(buffer, operation: .debugTest, transport: transport)
        case .buildProject: return try await program(buffer, operation: .build, transport: transport)
        case .runFile: return try await program(buffer, operation: .run, transport: transport)
        case .showPreview: return try await preview(buffer, transport: transport)
        case .showCodeLenses: return try await inline(buffer, kinds: [.codeLens], transport: transport)
        case .showInlayHints: return try await inline(buffer, kinds: [.inlayHints], transport: transport)
        case .showErrorLens: return try await inline(buffer, kinds: [.errorLens], transport: transport)
        case .refreshInlineAnnotations: return try await inline(buffer, kinds: nil, transport: transport)
        case .clearInlineAnnotations: return clearInline(buffer)
        }
    }

    /// Whether a command may run for minutes (the extension uses a longer bridge timeout).
    public static func isLongRunning(_ command: EditorCommand) -> Bool {
        [.runTestsInFile, .runTestAtCursor, .runTestsWithCoverage, .debugFileAtCursor, .debugTestAtCursor, .buildProject, .runFile,
         .showPreview].contains(command)
    }

    // MARK: Debugging

    /// Starts a session with a breakpoint on the caret line. The buffer is not modified.
    func debug(_ buffer: EditorBuffer, operation: BridgeOperation, transport: BridgeTransport) async throws -> EditorOutcome {
        let caret = buffer.selection.start
        let request = BridgeRequest(operation: operation, text: buffer.text, line: caret.line, character: caret.column,
                                    contentUTI: buffer.contentUTI, filePath: buffer.filePath)
        let response = try await transport.send(request)
        guard response.ok else { throw EditorCommandError.bridge(response.error ?? "CrossKit request failed") }
        guard let info = response.debugLaunch else { throw EditorCommandError.nothing("The debugger did not start.") }
        var message = "▶ " + info.message
        if let warning = info.warning { message += "\n\n⚠︎ " + warning }
        return EditorOutcome(message: message)
    }

    // MARK: Build & Run, Compose previews

    /// Build Project / Run File: the buffer is not modified; the result (or a still-running note) is the alert.
    func program(_ buffer: EditorBuffer, operation: BridgeOperation, transport: BridgeTransport) async throws -> EditorOutcome {
        let response = try await call(operation, buffer, transport)
        guard let run = response.programRun else { throw EditorCommandError.nothing("Nothing was built.") }
        // Kotlin titles carry the target ("Main.kt · Native macosArm64").
        return EditorOutcome(message: run.summary)
    }

    func preview(_ buffer: EditorBuffer, transport: BridgeTransport) async throws -> EditorOutcome {
        let caret = buffer.selection.start
        let request = BridgeRequest(operation: .preview, text: buffer.text, line: caret.line, character: caret.column,
                                    contentUTI: buffer.contentUTI, filePath: buffer.filePath)
        let response = try await transport.send(request)
        guard response.ok else { throw EditorCommandError.bridge(response.error ?? "CrossKit request failed") }
        if let inspection = response.inspection {
            var lines = ["◉ " + inspection.summary, "Showing it in CrossKit › Preview."]
            if let warning = inspection.warning { lines.append("⚠︎ " + warning) }
            return EditorOutcome(message: lines.joined(separator: "\n"))
        }
        guard let result = response.preview else { throw EditorCommandError.nothing("No previews were rendered.") }
        var lines = ["◉ " + result.summary]
        if let focused = result.previews.first(where: { $0.id == result.focusedID }) {
            lines.append(focused.error == nil ? "Showing \(focused.preview.name) in CrossKit › Preview." : "\(focused.preview.name) failed: \(focused.error ?? "")")
        }
        if let warning = result.warning { lines.append("⚠︎ " + warning) }
        return EditorOutcome(message: lines.joined(separator: "\n"))
    }

    // MARK: Inline annotations (CodeLens, inlay hints, ErrorLens)

    /// Replaces the requested kinds of inline annotations (all enabled kinds when `kinds` is nil).
    func inline(_ buffer: EditorBuffer, kinds: [InlineKind]?, transport: BridgeTransport) async throws -> EditorOutcome {
        let prepared = InlineAnnotations.prepare(buffer, removing: Set(kinds ?? InlineKind.allCases))
        let request = BridgeRequest(operation: .inlineAnnotations, text: prepared.cleanText, line: prepared.caretLine,
                                    character: prepared.caretColumn, contentUTI: buffer.contentUTI, filePath: buffer.filePath,
                                    inlineKinds: kinds)
        let response = try await transport.send(request)
        guard response.ok else { throw EditorCommandError.bridge(response.error ?? "CrossKit request failed") }
        let clean = prepared.clean
        let options = response.inlineOptions ?? InlineAnnotationOptions()
        let unsafe = InlineAnnotations.unsafeLineEnds(clean, language: response.language ?? .rust)
        var above: [Int: [String]] = [:]
        var trailing: [Int: [String]] = [:]
        var empty: [String] = []
        let computed = response.inlineKinds ?? kinds ?? []

        if computed.contains(.codeLens) {
            var count = 0
            // Lenses that land on the same line (a symbol's reference count and its test actions, whose
            // ranges may start at the attribute or at the name) become one line.
            var merged: [Int: BridgeCodeLens] = [:]
            var order: [Int] = []
            for lens in response.codeLenses ?? [] where clean.indices.contains(lens.line) {
                let anchor = Self.attributeStart(clean, lens.line)
                if var existing = merged[anchor] {
                    existing.references = existing.references ?? lens.references
                    existing.actions += lens.actions.filter { !existing.actions.contains($0) }
                    merged[anchor] = existing
                } else {
                    var lens = lens
                    lens.line = anchor
                    merged[anchor] = lens
                    order.append(anchor)
                }
            }
            for anchor in order {
                guard let lens = merged[anchor], let text = InlineAnnotations.lensText(lens) else { continue }
                above[anchor, default: []].append("\(Self.indentation(of: clean[anchor]))\(Self.marker) \(text)\n")
                count += 1
            }
            if count == 0 { empty.append("no code lenses") }
        }
        if computed.contains(.inlayHints) {
            let grouped = Dictionary(grouping: (response.inlayHints ?? []).filter { clean.indices.contains($0.line) }, by: \.line)
            for (line, hints) in grouped {
                let code = InlineAnnotations.splitTrailing(clean[line]).code
                if options.hintPlacement == .endOfLine, !unsafe.contains(line) {
                    trailing[line, default: []].append("» " + InlineAnnotations.summarizeHints(code, hints: hints))
                } else {
                    let rendered = InlineAnnotations.renderHints(code, hints: hints).trimmingCharacters(in: .whitespaces)
                    above[line, default: []].append("\(Self.indentation(of: code))\(Self.marker) » \(rendered)\n")
                }
            }
            if grouped.isEmpty { empty.append("no inlay hints") }
        }
        if computed.contains(.errorLens) {
            let grouped = Dictionary(grouping: (response.diagnostics ?? []).filter { clean.indices.contains($0.range.startLine) },
                                     by: \.range.startLine)
            for (line, items) in grouped {
                guard let text = InlineAnnotations.errorLensText(items, showSource: options.errorLensShowSource) else { continue }
                if unsafe.contains(line) {
                    above[line, default: []].append("\(Self.indentation(of: clean[line]))\(Self.marker) \(text)\n")
                } else {
                    trailing[line, default: []].append(text)
                }
            }
            if grouped.isEmpty {
                empty.append(response.diagnosticsReceived == false ? "no diagnostics reported yet (try again in a moment)" : "no problems")
            }
        }
        let operations = InlineAnnotations.operations(prepared, above: above, trailing: trailing)
        var message: String?
        if above.isEmpty && trailing.isEmpty {
            message = "CrossKit: " + (empty.isEmpty ? "nothing to show." : empty.joined(separator: ", ") + ".")
        }
        return EditorOutcome(operations: operations, message: message)
    }

    func clearInline(_ buffer: EditorBuffer) -> EditorOutcome {
        let prepared = InlineAnnotations.prepare(buffer, removing: Set(InlineKind.allCases))
        let changed = prepared.removed.count + zip(prepared.keptOriginalIndex, prepared.clean).filter { buffer.lines[$0.0] != $0.1 }.count
        guard changed > 0 else { return EditorOutcome(message: "No inline annotations to remove.") }
        return EditorOutcome(operations: InlineAnnotations.operations(prepared, above: [:], trailing: [:]))
    }

    // MARK: Tests (CodeLens substitute: `// [CrossKit] ▶ …` markers above test functions)

    /// `░` marks lines without coverage; it is replaced with the test markers on every run.
    static let testMarkerSymbols = ["▶", "✓", "✗", "○", "░"]

    public static func isTestMarker(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // `;; [CrossKit]` is the same marker in WebAssembly text.
        guard trimmed.hasPrefix(marker) || trimmed.hasPrefix(";; [CrossKit]") else { return false }
        let rest = trimmed.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
        return testMarkerSymbols.contains { rest.hasPrefix($0) }
    }

    func tests(_ buffer: EditorBuffer, operation: BridgeOperation, scope: TestScope?, transport: BridgeTransport) async throws -> EditorOutcome {
        // Old test markers are removed first; the request uses the buffer without them.
        let markerLines = buffer.lines.indices.filter { Self.isTestMarker(buffer.lines[$0]) }
        let markerSet = Set(markerLines)
        let clean = buffer.lines.enumerated().filter { !markerSet.contains($0.offset) }.map(\.element)
        let caret = buffer.selection.start
        let caretLine = max(0, caret.line - markerLines.filter { $0 < caret.line }.count)
        let request = BridgeRequest(operation: operation, text: clean.joined(), line: caretLine, character: caret.column,
                                    contentUTI: buffer.contentUTI, filePath: buffer.filePath, testScope: scope)
        let response = try await transport.send(request)
        guard response.ok else { throw EditorCommandError.bridge(response.error ?? "CrossKit request failed") }

        var operations: [BufferOperation] = markerLines.reversed().map { .replaceLines(start: $0, count: 1, with: []) }
        var markers: [Int: [String]] = [:]   // clean line → marker texts
        let tests = response.tests ?? []
        var message: String?
        if let run = response.testRun {
            for result in run.tests {
                guard let line = result.line, clean.indices.contains(line) else { continue }
                markers[line] = [Self.describe(result)]
            }
            message = Self.summary(run)
            if let report = response.coverage {
                message = Self.coverageSummary(report, run: run, file: buffer.filePath)
                if let path = buffer.filePath, let file = report.file(path) {
                    for range in file.uncoveredRanges {
                        let line = range.lowerBound - 1
                        guard clean.indices.contains(line) else { continue }
                        let text = range.count == 1 ? "░ not covered" : "░ not covered: lines \(range.lowerBound)–\(range.upperBound)"
                        markers[line, default: []].append(text)
                    }
                }
            }
        } else {
            if tests.isEmpty { message = "No tests found in this file." }
            for test in tests where clean.indices.contains(test.line) {
                markers[test.line] = ["▶ test \(test.name.isEmpty ? test.filter : test.name) — Editor › CrossKit › Run Test at Cursor"]
            }
        }
        var inserted = 0
        for line in markers.keys.sorted(by: >) {
            let anchor = Self.attributeStart(clean, line)
            let indent = Self.indentation(of: clean[line])
            let texts = markers[line]!
            operations.append(.replaceLines(start: anchor, count: 0, with: texts.map { "\(indent)\(Self.marker) \($0)\n" }))
            if anchor <= caretLine { inserted += texts.count }
        }
        operations.append(.select(.caret(caretLine + inserted, caret.column)))
        return EditorOutcome(operations: operations, message: message)
    }

    /// Markers go above attributes/annotations such as `#[test]` or `@Test`.
    static func attributeStart(_ lines: [String], _ line: Int) -> Int {
        var start = line
        while start > 0 {
            let previous = lines[start - 1].trimmingCharacters(in: .whitespaces)
            guard previous.hasPrefix("#[") || previous.hasPrefix("@") else { break }
            start -= 1
        }
        return start
    }

    static func describe(_ result: TestCaseResult) -> String {
        let time = result.duration.map { String(format: " %.3fs", $0) } ?? ""
        switch result.status {
        case .passed: return "✓ passed\(time)"
        case .skipped: return "○ skipped"
        case .failed:
            let first = result.output?.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty }.map { " — " + String($0.prefix(140)) } ?? ""
            return "✗ failed\(time)\(first)"
        }
    }

    public static func summary(_ run: TestRunResult) -> String {
        var lines = ["\(run.succeeded ? "✓" : "✗") \(run.language.displayName) · \(run.runner.displayName): \(run.summary)"]
        let failures = run.tests.filter { $0.status == .failed }
        for failure in failures.prefix(8) {
            let location = failure.line.map { ":\($0 + 1)" } ?? ""
            lines.append("✗ \(failure.name)\(location)")
        }
        if failures.count > 8 { lines.append("… and \(failures.count - 8) more") }
        if run.tests.isEmpty, !run.succeeded {
            let tail = run.output.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.suffix(6)
            lines.append(contentsOf: tail)
        }
        if let warning = run.warning { lines.append("⚠︎ " + warning) }
        lines.append("Details: CrossKit › Test Results")
        return lines.joined(separator: "\n")
    }

    public static func coverageSummary(_ report: CoverageReport, run: TestRunResult, file: String?) -> String {
        var lines = ["\(run.succeeded ? "✓" : "✗") \(run.language.displayName) · \(run.runner.displayName): \(run.summary)",
                     String(format: "Coverage: %.1f%% of lines (%d/%d)", report.percent, report.linesHit, report.linesFound)]
        if let file, let this = report.file(file) {
            lines.append(String(format: "This file: %.1f%% (%d/%d), %d uncovered range%@ marked ░", this.percent, this.linesHit,
                                this.linesFound, this.uncoveredRanges.count, this.uncoveredRanges.count == 1 ? "" : "s"))
        }
        let root = report.projectRoot
        for item in report.files.sorted(by: { $0.percent < $1.percent }).prefix(6) {
            let name = item.path.hasPrefix(root + "/") ? String(item.path.dropFirst(root.count + 1)) : item.path
            lines.append(String(format: "  %5.1f%%  %@", item.percent, name))
        }
        if report.files.count > 6 { lines.append("  … \(report.files.count - 6) more files") }
        if let warning = report.warning { lines.append("⚠︎ " + warning) }
        lines.append("Details: CrossKit › Coverage")
        return lines.joined(separator: "\n")
    }

    private func call(_ operation: BridgeOperation, _ buffer: EditorBuffer, _ transport: BridgeTransport) async throws -> BridgeResponse {
        let caret = buffer.selection.start
        let request = BridgeRequest(operation: operation, text: buffer.text, line: caret.line, character: caret.column,
                                    contentUTI: buffer.contentUTI, filePath: buffer.filePath)
        let response = try await transport.send(request)
        guard response.ok else { throw EditorCommandError.bridge(response.error ?? "CrossKit request failed") }
        return response
    }

    // MARK: Commands

    func completeAtCursor(_ buffer: EditorBuffer, _ response: BridgeResponse) -> EditorOutcome {
        let caret = buffer.selection.start
        guard buffer.lines.indices.contains(caret.line) else { return EditorOutcome(message: "Cursor is outside the buffer.") }
        let (content, terminator) = Self.split(buffer.lines[caret.line])
        let ns = content as NSString
        let column = min(caret.column, ns.length)
        let prefix = Self.identifierPrefix(in: ns, before: column)
        guard let best = Self.bestCompletion(response.completions ?? [], prefix: prefix) else {
            return EditorOutcome(message: "No completions for \"\(prefix)\".")
        }
        var start = column - (prefix as NSString).length
        var end = column
        if let range = best.editRange, range.startLine == caret.line, range.endLine == caret.line {
            start = min(range.startCharacter, ns.length)
            end = max(start, min(max(range.endCharacter, column), ns.length))
        }
        let updated = ns.replacingCharacters(in: NSRange(location: start, length: end - start), with: best.insertText)
        let newLines = (updated + terminator).components(separatedBy: "\n")
        var lines = newLines.dropLast().map { $0 + "\n" }
        if let last = newLines.last, !last.isEmpty || terminator.isEmpty { lines.append(last) }
        let caretColumn = start + (best.insertText as NSString).length
        var operations: [BufferOperation] = [.replaceLines(start: caret.line, count: 1, with: lines)]
        if !best.insertText.contains("\n") { operations.append(.select(.caret(caret.line, caretColumn))) }
        return EditorOutcome(operations: operations)
    }

    func listCompletions(_ buffer: EditorBuffer, _ response: BridgeResponse) -> EditorOutcome {
        let caret = buffer.selection.start
        let content = buffer.lines.indices.contains(caret.line) ? Self.split(buffer.lines[caret.line]).0 : ""
        let ns = content as NSString
        let prefix = Self.identifierPrefix(in: ns, before: min(caret.column, ns.length))
        let ranked = Self.rankedCompletions(response.completions ?? [], prefix: prefix)
        guard !ranked.isEmpty else { return EditorOutcome(message: "No completions for \"\(prefix)\".") }
        var body = ["completions for \"\(prefix)\" (\(ranked.count)):"]
        body += ranked.prefix(maxAnnotationLines - 1).map { item in
            "  \(item.label)" + (item.detail.map { " — \($0)" } ?? "")
        }
        return annotate(buffer, aboveLine: caret.line, body)
    }

    func goToDefinition(_ buffer: EditorBuffer, _ response: BridgeResponse) -> EditorOutcome {
        let locations = response.locations ?? []
        guard let first = locations.first else { return EditorOutcome(message: "No definition found.") }
        if let current = response.filePath, first.path == current {
            let r = first.range
            return EditorOutcome(operations: [.select(EditorRange(start: EditorPosition(line: r.startLine, column: r.startCharacter),
                                                                end: EditorPosition(line: r.endLine, column: r.endCharacter)))])
        }
        let body = ["definition:"] + locations.prefix(maxAnnotationLines - 1).map { "  " + describe($0, root: response.rootPath) }
        var outcome = annotate(buffer, aboveLine: buffer.selection.start.line, body)
        outcome.message = "Definition is in \((first.path as NSString).lastPathComponent):\(first.range.startLine + 1) — CrossKit asked Xcode to open it."
        return outcome
    }

    func findReferences(_ buffer: EditorBuffer, _ response: BridgeResponse) -> EditorOutcome {
        let locations = response.locations ?? []
        guard !locations.isEmpty else { return EditorOutcome(message: "No references found.") }
        let body = ["\(locations.count) reference(s):"] + locations.prefix(maxAnnotationLines - 1).map {
            "  " + describe($0, root: response.rootPath)
        }
        return annotate(buffer, aboveLine: buffer.selection.start.line, body)
    }

    func hover(_ buffer: EditorBuffer, _ response: BridgeResponse) -> EditorOutcome {
        guard let text = response.hover else { return EditorOutcome(message: "No hover information here.") }
        let lines = text.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
            .map { String($0.prefix(200)) }
        let trimmed = Array(lines.drop { $0.trimmingCharacters(in: .whitespaces).isEmpty })
        guard !trimmed.isEmpty else { return EditorOutcome(message: "No hover information here.") }
        return annotate(buffer, aboveLine: buffer.selection.start.line, Array(trimmed.prefix(maxAnnotationLines)))
    }

    func diagnostics(_ buffer: EditorBuffer, _ response: BridgeResponse) -> EditorOutcome {
        let items = (response.diagnostics ?? []).filter { buffer.lines.indices.contains($0.range.startLine) }
        guard !items.isEmpty else {
            let received = response.diagnosticsReceived ?? true
            return EditorOutcome(message: received ? "No problems found." : "The language server has not reported diagnostics yet; try again in a moment.")
        }
        let grouped = Dictionary(grouping: items, by: { $0.range.startLine })
        var operations: [BufferOperation] = []
        var inserted = 0
        for line in grouped.keys.sorted(by: >) {
            let indent = Self.indentation(of: buffer.lines[line])
            let annotations = grouped[line]!.map { d -> String in
                let message = d.message.replacingOccurrences(of: "\n", with: " ")
                return "\(indent)\(Self.marker) \(d.severityName): \(message) [\(line + 1):\(d.range.startCharacter + 1)]"
                    + (d.source.map { " (\($0))" } ?? "") + "\n"
            }
            operations.append(.replaceLines(start: line, count: 0, with: annotations))
            if line <= buffer.selection.start.line { inserted += annotations.count }
        }
        let caret = buffer.selection.start
        operations.append(.select(.caret(caret.line + inserted, caret.column)))
        return EditorOutcome(operations: operations)
    }

    func clearAnnotations(_ buffer: EditorBuffer) -> EditorOutcome {
        let indices = buffer.lines.indices.filter { Self.isAnnotation(buffer.lines[$0]) }
        // Trailing `  // [CrossKit] …` segments (inlay hints, ErrorLens) are cut off their lines first.
        var operations: [BufferOperation] = buffer.lines.enumerated().compactMap { index, line in
            guard !Self.isAnnotation(line) else { return nil }
            let stripped = InlineAnnotations.stripTrailing(line)
            return stripped == line ? nil : .replaceLines(start: index, count: 1, with: [stripped])
        }
        guard !indices.isEmpty || !operations.isEmpty else { return EditorOutcome(message: "No CrossKit annotations to remove.") }
        operations += indices.reversed().map { .replaceLines(start: $0, count: 1, with: []) }
        let caret = buffer.selection.start
        let removedAbove = indices.filter { $0 < caret.line }.count
        operations.append(.select(.caret(max(0, caret.line - removedAbove), caret.column)))
        return EditorOutcome(operations: operations)
    }

    // MARK: Helpers

    func annotate(_ buffer: EditorBuffer, aboveLine line: Int, _ body: [String]) -> EditorOutcome {
        let target = min(max(line, 0), buffer.lines.count)
        let indent = buffer.lines.indices.contains(target) ? Self.indentation(of: buffer.lines[target]) : ""
        let lines = body.map { "\(indent)\(Self.marker) \($0)\n" }
        let caret = buffer.selection.start
        return EditorOutcome(operations: [
            .replaceLines(start: target, count: 0, with: lines),
            .select(.caret(caret.line + (target <= caret.line ? lines.count : 0), caret.column)),
        ])
    }

    func describe(_ location: BridgeLocation, root: String?) -> String {
        var path = location.path
        if let root, path.hasPrefix(root + "/") { path = String(path.dropFirst(root.count + 1)) }
        let position = "\(path):\(location.range.startLine + 1):\(location.range.startCharacter + 1)"
        guard let preview = location.preview, !preview.isEmpty else { return position }
        return "\(position)  \(preview.prefix(120))"
    }

    /// A CrossKit comment line (`// [CrossKit]`, or `;; [CrossKit]` in WebAssembly text).
    public static func isAnnotation(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix(marker) || trimmed.hasPrefix(";; [CrossKit]")
    }

    static func split(_ line: String) -> (String, String) {
        if line.hasSuffix("\r\n") { return (String(line.dropLast(2)), "\r\n") }
        if line.hasSuffix("\n") { return (String(line.dropLast()), "\n") }
        return (line, "")
    }

    static func indentation(of line: String) -> String {
        String(line.prefix { $0 == " " || $0 == "\t" })
    }

    static func identifierPrefix(in line: NSString, before column: Int) -> String {
        var start = column
        while start > 0 {
            let c = line.character(at: start - 1)
            guard let scalar = UnicodeScalar(c),
                  CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "@" else { break }
            start -= 1
        }
        return line.substring(with: NSRange(location: start, length: column - start))
    }

    public static func rankedCompletions(_ items: [BridgeCompletion], prefix: String) -> [BridgeCompletion] {
        let key = { (item: BridgeCompletion) in item.filterText ?? item.label }
        let order = { (a: BridgeCompletion, b: BridgeCompletion) in (a.sortText ?? a.label) < (b.sortText ?? b.label) }
        if prefix.isEmpty { return items.sorted(by: order) }
        let exact = items.filter { key($0).hasPrefix(prefix) }.sorted(by: order)
        if !exact.isEmpty { return exact }
        let lower = prefix.lowercased()
        let insensitive = items.filter { key($0).lowercased().hasPrefix(lower) }.sorted(by: order)
        if !insensitive.isEmpty { return insensitive }
        return items.filter { key($0).lowercased().contains(lower) }.sorted(by: order)
    }

    public static func bestCompletion(_ items: [BridgeCompletion], prefix: String) -> BridgeCompletion? {
        rankedCompletions(items, prefix: prefix).first
    }

    /// Applies operations to plain lines (mirrors what the extension does to XCSourceTextBuffer).
    public static func apply(_ operations: [BufferOperation], to lines: [String]) -> (lines: [String], selection: EditorRange?) {
        var lines = lines
        var selection: EditorRange?
        for operation in operations {
            switch operation {
            case .replaceLines(let start, let count, let newLines):
                let s = min(max(start, 0), lines.count)
                let e = min(s + count, lines.count)
                lines.replaceSubrange(s..<e, with: newLines)
            case .select(let range):
                selection = range
            }
        }
        return (lines, selection)
    }
}
