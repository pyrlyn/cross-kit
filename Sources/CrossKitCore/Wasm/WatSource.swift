import Foundation

/// A probe inserted by `WatInstrumenter`: an execution counter at a function entry or an `if` branch.
public struct WatProbe: Codable, Equatable, Sendable {
    public var id: Int
    /// 0-based line of the function / branch in the original text.
    public var line: Int
    public var kind: Kind

    public enum Kind: String, Codable, Sendable { case function, then, `else` }

    public var globalName: String { "__ck_\(id)" }
}

/// Small structural helpers for WebAssembly text: test exports, functions by line, and coverage instrumentation.
public enum WatSource {
    public struct Function: Equatable, Sendable {
        /// Index in the function index space of the module text (imported functions first).
        public var index: Int
        public var name: String?
        public var exports: [String]
        /// 0-based lines of `(func` and its closing paren.
        public var startLine: Int
        public var endLine: Int
        public var isImport: Bool
    }

    /// Module-level functions (in index order) and top-level `(export "x" (func $f))` fields.
    public static func functions(_ text: String) -> [Function] {
        var functions: [Function] = []
        var exportFields: [(name: String, target: String, line: Int)] = []
        let scanner = Scanner(text)
        var stack: [(keyword: String, line: Int, funcIndex: Int?)] = []
        var moduleLevel = 0
        var pendingExportName: String?
        scanner.scan { event in
            switch event {
            case .open(let keyword, let line, _, _):
                if stack.isEmpty, keyword == "module" { moduleLevel = 1 }
                let atModule = stack.count == moduleLevel
                var funcIndex: Int?
                if atModule, keyword == "func" {
                    funcIndex = functions.count
                    functions.append(Function(index: functions.count, name: nil, exports: [], startLine: line, endLine: line, isImport: false))
                } else if atModule, keyword == "import" {
                    funcIndex = -1
                } else if keyword == "import", stack.count == moduleLevel + 1, stack.last?.keyword == "func",
                          let index = stack.last?.funcIndex, index >= 0 {
                    functions[index].isImport = true
                }
                stack.append((keyword, line, funcIndex))
            case .close(let line, _):
                guard let frame = stack.popLast() else { return }
                if let index = frame.funcIndex, index >= 0 { functions[index].endLine = line }
            case .atom(let token, let line, _):
                guard let top = stack.last else { return }
                let depth = stack.count
                if top.keyword == "func", let index = top.funcIndex, index >= 0, depth == moduleLevel + 1,
                   token.hasPrefix("$"), functions[index].name == nil, functions[index].exports.isEmpty {
                    functions[index].name = token
                } else if top.keyword == "export", token.hasPrefix("\"") {
                    let name = Scanner.unquote(token)
                    if depth >= 2, stack[depth - 2].keyword == "func", let index = stack[depth - 2].funcIndex, index >= 0 {
                        functions[index].exports.append(name)
                    } else if depth == moduleLevel + 1 {
                        pendingExportName = name
                        exportFields.append((name, "", line))
                    }
                } else if top.keyword == "func", depth >= 2, stack[depth - 2].keyword == "export", pendingExportName != nil {
                    exportFields[exportFields.count - 1].target = token
                    pendingExportName = nil
                }
            }
        }
        // Imported functions declared as (import "m" "n" (func …)) come first in the index space.
        let imports = importedFunctionCount(text)
        if imports > 0 { for i in functions.indices { functions[i].index += imports } }
        for field in exportFields where !field.target.isEmpty {
            if field.target.hasPrefix("$"), let i = functions.firstIndex(where: { $0.name == field.target }) {
                functions[i].exports.append(field.name)
            } else if let n = Int(field.target), let i = functions.firstIndex(where: { $0.index == n }) {
                functions[i].exports.append(field.name)
            }
        }
        return functions
    }

    /// Number of `(import … (func …))` fields.
    static func importedFunctionCount(_ text: String) -> Int {
        var count = 0
        var stack: [String] = []
        var moduleLevel = 0
        Scanner(text).scan { event in
            switch event {
            case .open(let keyword, _, _, _):
                if stack.isEmpty, keyword == "module" { moduleLevel = 1 }
                if keyword == "func", stack.count == moduleLevel + 1, stack.last == "import" { count += 1 }
                stack.append(keyword)
            case .close: _ = stack.popLast()
            case .atom: break
            }
        }
        return count
    }

    /// Exported functions whose export name starts with `test` (the WebAssembly test convention CrossKit uses).
    public static func testExports(_ text: String) -> [DiscoveredTest] {
        functions(text).flatMap { function in
            function.exports.filter { $0.lowercased().hasPrefix("test") }.map {
                DiscoveredTest(name: $0, filter: $0, line: function.startLine)
            }
        }.sorted { $0.line < $1.line }
    }

    /// Top-level assertions of a `.wast` script; the filter is the 1-based line wasmtime reports.
    public static func wastAssertions(_ text: String) -> [DiscoveredTest] {
        var tests: [DiscoveredTest] = []
        var depth = 0
        Scanner(text).scan { event in
            switch event {
            case .open(let keyword, let line, _, _):
                if depth == 0, keyword.hasPrefix("assert_") {
                    tests.append(DiscoveredTest(name: "\(keyword) (line \(line + 1))", filter: "\(line + 1)", line: line))
                }
                depth += 1
            case .close: depth -= 1
            case .atom: break
            }
        }
        return tests
    }

    /// The function containing a 0-based line.
    public static func function(atLine line: Int, in text: String) -> Function? {
        functions(text).last { !$0.isImport && $0.startLine <= line && line <= $0.endLine }
    }

    // MARK: Scanner

    /// Tokenizes WAT: `(keyword`, `)`, atoms (instructions, `$ids`, numbers, strings); skips comments.
    struct Scanner {
        enum Event {
            /// `(keyword`: keyword, line, offset of "(", offset just after the keyword.
            case open(String, Int, Int, Int)
            /// `)`: line, offset.
            case close(Int, Int)
            /// token, line, offset.
            case atom(String, Int, Int)
        }

        let chars: [Character]
        init(_ text: String) { chars = Array(text) }

        static func unquote(_ token: String) -> String {
            guard token.count >= 2, token.hasPrefix("\""), token.hasSuffix("\"") else { return token }
            return String(token.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
        }

        func scan(_ handle: (Event) -> Void) {
            var i = 0
            var line = 0
            let n = chars.count
            while i < n {
                let c = chars[i]
                if c == "\n" { line += 1; i += 1; continue }
                if c.isWhitespace { i += 1; continue }
                if c == ";", i + 1 < n, chars[i + 1] == ";" {
                    while i < n, chars[i] != "\n" { i += 1 }
                    continue
                }
                if c == "(", i + 1 < n, chars[i + 1] == ";" {
                    var nesting = 1
                    i += 2
                    while i < n, nesting > 0 {
                        if chars[i] == "\n" { line += 1 }
                        if chars[i] == "(", i + 1 < n, chars[i + 1] == ";" { nesting += 1; i += 2; continue }
                        if chars[i] == ";", i + 1 < n, chars[i + 1] == ")" { nesting -= 1; i += 2; continue }
                        i += 1
                    }
                    continue
                }
                if c == "(" {
                    let open = i
                    i += 1
                    while i < n, chars[i] == " " || chars[i] == "\t" { i += 1 }
                    var keyword = ""
                    while i < n, !chars[i].isWhitespace, chars[i] != "(", chars[i] != ")", chars[i] != "\"" { keyword.append(chars[i]); i += 1 }
                    handle(.open(keyword, line, open, i))
                    continue
                }
                if c == ")" { handle(.close(line, i)); i += 1; continue }
                if c == "\"" {
                    let start = i
                    var token = "\""
                    i += 1
                    while i < n {
                        let d = chars[i]
                        token.append(d)
                        i += 1
                        if d == "\\", i < n { token.append(chars[i]); i += 1; continue }
                        if d == "\"" { break }
                    }
                    handle(.atom(token, line, start))
                    continue
                }
                let start = i
                var token = ""
                while i < n, !chars[i].isWhitespace, chars[i] != "(", chars[i] != ")" { token.append(chars[i]); i += 1 }
                handle(.atom(token, line, start))
            }
        }
    }
}

/// Inserts execution counters into WebAssembly text for coverage: one mutable exported global per function
/// entry and per `if` branch (folded `(then …)` / `(else …)` and flat `if … else … end`). Counters are globals
/// appended at the end of the module, so existing function, global and type indices do not move.
public enum WatInstrumenter {
    static let headerGroups: Set<String> = ["type", "export", "import", "param", "result", "local"]
    static let ifImmediates: Set<String> = ["type", "param", "result"]

    public static func instrument(_ text: String) -> (text: String, probes: [WatProbe]) {
        let chars = Array(text)
        var insertions: [(offset: Int, text: String)] = []
        var probes: [WatProbe] = []
        struct Frame { var keyword: String; var line: Int }
        var stack: [Frame] = []
        var moduleLevel = 0
        var moduleClose: Int?
        // Waiting for the first instruction after a header/immediates at this depth.
        struct Pending { var depth: Int; var line: Int; var kind: WatProbe.Kind; var groups: Set<String>; var allowID: Bool; var cancel: Bool }
        var pending: Pending?

        func counter(_ id: Int) -> String { " global.get $__ck_\(id) i32.const 1 i32.add global.set $__ck_\(id) " }
        func addProbe(_ kind: WatProbe.Kind, line: Int, at offset: Int) {
            let probe = WatProbe(id: probes.count, line: line, kind: kind)
            probes.append(probe)
            insertions.append((offset, counter(probe.id)))
        }
        func resolvePending(at offset: Int) {
            guard let p = pending else { return }
            pending = nil
            if !p.cancel { addProbe(p.kind, line: p.line, at: offset) }
        }

        WatSource.Scanner(text).scan { event in
            switch event {
            case .open(let keyword, let line, let open, let afterKeyword):
                if let p = pending, stack.count == p.depth {
                    if p.groups.contains(keyword) {
                        if keyword == "import", p.kind == .function { pending?.cancel = true }
                    } else {
                        resolvePending(at: open)
                    }
                }
                if stack.isEmpty, keyword == "module" { moduleLevel = 1 }
                let atModule = stack.count == moduleLevel
                stack.append(Frame(keyword: keyword, line: line))
                if atModule, keyword == "func" {
                    pending = Pending(depth: stack.count, line: line, kind: .function, groups: headerGroups, allowID: true, cancel: false)
                } else if keyword == "then" || keyword == "else", stack.count >= 2, stack[stack.count - 2].keyword == "if" {
                    addProbe(keyword == "then" ? .then : .else, line: line, at: afterKeyword)
                }
            case .close(_, let offset):
                if let p = pending, stack.count == p.depth { resolvePending(at: offset) }
                guard let frame = stack.popLast() else { return }
                if frame.keyword == "module", stack.isEmpty { moduleClose = offset }
            case .atom(let token, let line, let offset):
                if let p = pending, stack.count == p.depth {
                    if p.allowID, token.hasPrefix("$") { pending?.allowID = false; return }
                    resolvePending(at: offset)
                }
                guard stack.contains(where: { $0.keyword == "func" }) else { return }
                if token == "if" {
                    pending = Pending(depth: stack.count, line: line, kind: .then, groups: ifImmediates, allowID: true, cancel: false)
                } else if token == "else" {
                    addProbe(.else, line: line, at: offset + 4)
                }
            }
        }
        guard !probes.isEmpty else { return (text, []) }
        let globals = probes.map { "\n  (global $__ck_\($0.id) (export \"__ck_\($0.id)\") (mut i32) (i32.const 0))" }.joined() + "\n"
        insertions.append((moduleClose ?? chars.count, globals))
        var out = chars
        for insertion in insertions.sorted(by: { $0.offset > $1.offset }) {
            out.insert(contentsOf: Array(insertion.text), at: insertion.offset)
        }
        return (String(out), probes)
    }
}
