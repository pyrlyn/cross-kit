import Foundation

public enum BridgeOperation: String, Codable, Sendable {
    case ping, completion, definition, references, hover, diagnostics, discoverTests, runTests, debugFile, debugTest
    case build, run, preview, inlineAnnotations
    /// Runs the file's tests with coverage.
    case coverage

    public var feature: Feature? {
        switch self {
        case .ping: return nil
        case .completion: return .completion
        case .definition: return .definition
        case .references: return .references
        case .hover: return .hover
        case .diagnostics: return .diagnostics
        case .discoverTests, .runTests: return .tests
        case .debugFile, .debugTest: return .debug
        case .build, .run: return .run
        case .preview: return .preview
        // Checked per requested kind (CodeLens, inlay hints, ErrorLens).
        case .inlineAnnotations: return nil
        case .coverage: return .coverage
        }
    }
}

public struct BridgeRange: Codable, Equatable, Sendable {
    public var startLine: Int
    public var startCharacter: Int
    public var endLine: Int
    public var endCharacter: Int

    public init(startLine: Int, startCharacter: Int, endLine: Int, endCharacter: Int) {
        self.startLine = startLine
        self.startCharacter = startCharacter
        self.endLine = endLine
        self.endCharacter = endCharacter
    }
}

public struct BridgeLocation: Codable, Equatable, Sendable {
    public var path: String
    public var range: BridgeRange
    public var preview: String?

    public init(path: String, range: BridgeRange, preview: String? = nil) {
        self.path = path
        self.range = range
        self.preview = preview
    }
}

public struct BridgeCompletion: Codable, Equatable, Sendable {
    public var label: String
    public var insertText: String
    public var detail: String?
    public var sortText: String?
    public var filterText: String?
    public var editRange: BridgeRange?

    public init(label: String, insertText: String, detail: String? = nil, sortText: String? = nil,
                filterText: String? = nil, editRange: BridgeRange? = nil) {
        self.label = label
        self.insertText = insertText
        self.detail = detail
        self.sortText = sortText
        self.filterText = filterText
        self.editRange = editRange
    }
}

public struct BridgeDiagnostic: Codable, Equatable, Sendable {
    public var range: BridgeRange
    public var severity: Int
    public var message: String
    public var source: String?

    public init(range: BridgeRange, severity: Int, message: String, source: String? = nil) {
        self.range = range
        self.severity = severity
        self.message = message
        self.source = source
    }

    public var severityName: String {
        switch severity {
        case 1: return "error"
        case 2: return "warning"
        case 3: return "info"
        default: return "hint"
        }
    }
}

/// Extension → host request. Positions are 0-based; `character` is in UTF-16 code units.
public struct BridgeRequest: Codable, Equatable, Sendable {
    public var operation: BridgeOperation
    public var text: String
    public var line: Int
    public var character: Int
    public var contentUTI: String
    public var filePath: String?
    public var testScope: TestScope?
    /// inlineAnnotations: which kinds to compute; nil = every kind enabled in settings.
    public var inlineKinds: [InlineKind]?

    public init(operation: BridgeOperation, text: String = "", line: Int = 0, character: Int = 0,
                contentUTI: String = "", filePath: String? = nil, testScope: TestScope? = nil, inlineKinds: [InlineKind]? = nil) {
        self.testScope = testScope
        self.inlineKinds = inlineKinds
        self.operation = operation
        self.text = text
        self.line = line
        self.character = character
        self.contentUTI = contentUTI
        self.filePath = filePath
    }
}

public struct BridgeResponse: Codable, Equatable, Sendable {
    public var ok: Bool
    public var error: String?
    public var language: Language?
    public var filePath: String?
    public var rootPath: String?
    public var completions: [BridgeCompletion]?
    public var locations: [BridgeLocation]?
    public var hover: String?
    public var diagnostics: [BridgeDiagnostic]?
    public var diagnosticsReceived: Bool?
    public var tests: [DiscoveredTest]?
    public var testRun: TestRunResult?
    public var debugLaunch: DebugLaunchInfo?
    public var programRun: ProgramRun?
    public var preview: PreviewResult?
    /// Non-Kotlin "previews": assembly, symbols, emitted JavaScript, WebAssembly sections, …
    public var inspection: InspectionResult?
    public var coverage: CoverageReport?
    public var codeLenses: [BridgeCodeLens]?
    public var inlayHints: [BridgeInlayHint]?
    /// Kinds the host computed for an inlineAnnotations request.
    public var inlineKinds: [InlineKind]?
    public var inlineOptions: InlineAnnotationOptions?

    public init(ok: Bool = true, error: String? = nil) {
        self.ok = ok
        self.error = error
    }

    public static func failure(_ message: String) -> BridgeResponse { BridgeResponse(ok: false, error: message) }
}

/// Converts raw LSP results into bridge models.
public enum LSPConvert {
    public static func range(_ value: JSONValue?) -> BridgeRange? {
        guard let value, let start = value["start"], let end = value["end"],
              let sl = start["line"]?.intValue, let sc = start["character"]?.intValue,
              let el = end["line"]?.intValue, let ec = end["character"]?.intValue else { return nil }
        return BridgeRange(startLine: sl, startCharacter: sc, endLine: el, endCharacter: ec)
    }

    public static func path(fromURI uri: String) -> String {
        guard let url = URL(string: uri), url.isFileURL else { return uri }
        return URL(fileURLWithPath: url.path).resolvingSymlinksInPath().path
    }

    /// Location | Location[] | LocationLink[] | null
    public static func locations(_ result: JSONValue) -> [BridgeLocation] {
        let items: [JSONValue]
        switch result {
        case .array(let array): items = array
        case .object: items = [result]
        default: items = []
        }
        return items.compactMap { item in
            if let uri = item["uri"]?.stringValue, let r = range(item["range"]) {
                return BridgeLocation(path: path(fromURI: uri), range: r)
            }
            if let uri = item["targetUri"]?.stringValue,
               let r = range(item["targetSelectionRange"]) ?? range(item["targetRange"]) {
                return BridgeLocation(path: path(fromURI: uri), range: r)
            }
            return nil
        }
    }

    /// CompletionItem[] | CompletionList | null
    public static func completions(_ result: JSONValue) -> [BridgeCompletion] {
        let items = result.arrayValue ?? result["items"]?.arrayValue ?? []
        return items.compactMap { item in
            guard let label = item["label"]?.stringValue else { return nil }
            let edit = item["textEdit"]
            let snippet = item["insertTextFormat"]?.intValue == 2
            var text = edit?["newText"]?.stringValue ?? item["insertText"]?.stringValue ?? label
            if snippet { text = stripSnippet(text) }
            let editRange = range(edit?["range"]) ?? range(edit?["replace"]) ?? range(edit?["insert"])
            return BridgeCompletion(label: label, insertText: text, detail: item["detail"]?.stringValue,
                                    sortText: item["sortText"]?.stringValue, filterText: item["filterText"]?.stringValue,
                                    editRange: editRange)
        }
    }

    /// Hover.contents: MarkupContent | MarkedString | MarkedString[]
    public static func hoverText(_ result: JSONValue) -> String? {
        guard let contents = result["contents"] else { return nil }
        func text(_ value: JSONValue) -> String? {
            if let s = value.stringValue { return s }
            if let v = value["value"]?.stringValue { return v }
            return nil
        }
        let parts: [String]
        if let array = contents.arrayValue { parts = array.compactMap(text) } else { parts = [text(contents)].compactMap { $0 } }
        let joined = parts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    public static func diagnostics(_ items: [JSONValue]) -> [BridgeDiagnostic] {
        items.compactMap { item in
            guard let r = range(item["range"]), let message = item["message"]?.stringValue else { return nil }
            return BridgeDiagnostic(range: r, severity: item["severity"]?.intValue ?? 1, message: message,
                                    source: item["source"]?.stringValue)
        }
    }

    /// InlayHint[]: label is a string or InlayHintLabelPart[].
    public static func inlayHints(_ result: JSONValue) -> [BridgeInlayHint] {
        (result.arrayValue ?? []).compactMap { item in
            guard let line = item["position"]?["line"]?.intValue, let character = item["position"]?["character"]?.intValue else { return nil }
            let label: String
            if let text = item["label"]?.stringValue { label = text } else {
                label = (item["label"]?.arrayValue ?? []).compactMap { $0["value"]?.stringValue }.joined()
            }
            guard !label.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            let kind = BridgeInlayHint.Kind(rawValue: item["kind"]?.intValue ?? 0) ?? .other
            return BridgeInlayHint(line: line, character: character, label: label, kind: kind,
                                   paddingLeft: item["paddingLeft"]?.boolValue ?? false, paddingRight: item["paddingRight"]?.boolValue ?? false)
        }
    }

    /// A declaration from textDocument/documentSymbol.
    public struct Symbol: Equatable, Sendable {
        public var name: String
        public var kind: Int
        /// Where the name is (references are asked for here).
        public var selection: BridgeRange
        public var range: BridgeRange
    }

    /// DocumentSymbol[] (nested) or SymbolInformation[] (flat), flattened.
    public static func symbols(_ result: JSONValue) -> [Symbol] {
        var out: [Symbol] = []
        func walk(_ items: [JSONValue]) {
            for item in items {
                guard let name = item["name"]?.stringValue, let kind = item["kind"]?.intValue else { continue }
                if let r = range(item["range"]) {
                    out.append(Symbol(name: name, kind: kind, selection: range(item["selectionRange"]) ?? r, range: r))
                } else if let r = range(item["location"]?["range"]) {
                    out.append(Symbol(name: name, kind: kind, selection: r, range: r))
                }
                if let children = item["children"]?.arrayValue { walk(children) }
            }
        }
        walk(result.arrayValue ?? [])
        return out
    }

    /// Turns `foo(${1:x}, $2)$0` into `foo(x, )`.
    public static func stripSnippet(_ snippet: String) -> String {
        var text = snippet
        let patterns: [(String, String)] = [
            (#"\$\{\d+:([^}]*)\}"#, "$1"),
            (#"\$\{\d+\|([^,}]*)[^}]*\}"#, "$1"),
            (#"\$\{\d+\}"#, ""),
            (#"\$\d+"#, ""),
        ]
        for (pattern, template) in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
            }
        }
        return text.replacingOccurrences(of: "\\$", with: "$").replacingOccurrences(of: "\\}", with: "}")
    }
}
