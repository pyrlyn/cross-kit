import Foundation

/// One tab of a file inspection (assembly, symbols, emitted JavaScript, WebAssembly sections, …).
public struct InspectionSection: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var text: String
    /// The command that produced it (shown under the text), if any.
    public var command: String?
    /// True when the tool failed; `text` then holds its output.
    public var failed: Bool

    public init(id: String, title: String, text: String, command: String? = nil, failed: Bool = false) {
        self.id = id
        self.title = title
        self.text = text
        self.command = command
        self.failed = failed
    }
}

/// The Preview window's content for C++, JavaScript, TypeScript and WebAssembly files.
public struct InspectionResult: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var language: Language
    public var filePath: String
    public var createdAt: Date
    public var duration: TimeInterval
    public var sections: [InspectionSection]
    public var warning: String?

    public init(id: UUID = UUID(), language: Language, filePath: String, createdAt: Date = Date(), duration: TimeInterval = 0,
                sections: [InspectionSection], warning: String? = nil) {
        self.id = id
        self.language = language
        self.filePath = filePath
        self.createdAt = createdAt
        self.duration = duration
        self.sections = sections
        self.warning = warning
    }

    public var fileName: String { (filePath as NSString).lastPathComponent }

    public var summary: String {
        let failed = sections.filter(\.failed).map(\.title)
        var text = "\(fileName): " + sections.map(\.title).joined(separator: ", ")
        if !failed.isEmpty { text += " (failed: \(failed.joined(separator: ", ")))" }
        return text
    }
}

/// Builds inspections with the toolchains found on the Mac (nothing is installed by CrossKit):
/// * C++: assembly at -O0 and -O2 (clang++ -S, demangled), symbols (nm -C), included headers (-H).
/// * JavaScript/TypeScript: outline, emitted JavaScript (tsc, else Node.js type stripping), syntax/type check, imports.
/// * WebAssembly: module summary from CrossKit's own binary reader, canonical WAT (wasm-tools print / wasm2wat)
///   and a hex dump. `.wat` files are assembled first; `.wasm` binaries can be opened directly.
public struct InspectService: Sendable {
    public var tools: ToolFinder
    public var workDirectory: URL

    public init(tools: ToolFinder = ToolFinder(), workDirectory: URL = SharedPaths.debugDirectory) {
        self.tools = tools
        self.workDirectory = workDirectory
    }

    public static func supports(_ language: Language) -> Bool { [.cpp, .javascript, .typescript, .wasm].contains(language) }

    public func inspect(language: Language, file: URL, text: String) async throws -> InspectionResult {
        let started = Date()
        let sections: [InspectionSection]
        switch language {
        case .cpp: sections = try await inspectCpp(file: file)
        case .javascript, .typescript: sections = try await inspectScript(language: language, file: file, text: text)
        case .wasm: sections = try await inspectWat(file: file)
        default:
            throw PreviewError.noPreviews("CrossKit previews \(language.displayName) files only with Compose (Kotlin) or the inspector (C++, JavaScript, TypeScript, WebAssembly).")
        }
        return InspectionResult(language: language, filePath: file.path, duration: Date().timeIntervalSince(started), sections: sections)
    }

    func scratch() throws -> URL {
        let dir = workDirectory.appendingPathComponent("inspect/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func run(_ exe: String, _ args: [String], in dir: URL, env: [String: String]? = nil) async throws -> TestExecutor.Outcome {
        try await TestExecutor.run(executable: exe, arguments: args, workingDirectory: dir.path,
                                   environment: env ?? ProcessInfo.processInfo.environment, timeout: 120)
    }

    static func display(_ exe: String, _ args: [String]) -> String {
        TestCommand(kind: .ctest, executable: (exe as NSString).lastPathComponent, arguments: args, workingDirectory: "", environment: [:]).display
    }

    // MARK: C++

    /// Compile flags: the project's compile_commands.json (CrossKit's or the project's build tree), compile_flags.txt,
    /// else C++20 with the file's directory on the include path.
    func cppFlags(file: URL) -> [String] {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let root = CppTesting.projectRoot(for: file) {
            candidates.append(CppTesting.buildDirectory(root: root, variant: "debug", workDirectory: workDirectory).appendingPathComponent("compile_commands.json"))
            candidates += ["build", "out", "cmake-build-debug", "."].map { root.appendingPathComponent($0).appendingPathComponent("compile_commands.json") }
        }
        for url in candidates {
            guard let data = fm.contents(atPath: url.path), let json = try? JSONDecoder().decode(JSONValue.self, from: data),
                  let entries = json.arrayValue else { continue }
            let target = LaunchPlanner.canonicalPath(file.path)
            for entry in entries {
                guard let path = entry["file"]?.stringValue, LaunchPlanner.canonicalPath(path) == target else { continue }
                let args: [String] = entry["arguments"]?.arrayValue?.compactMap(\.stringValue)
                    ?? (entry["command"]?.stringValue ?? "").split(separator: " ").map(String.init)
                return Self.relevantFlags(Array(args.dropFirst()), directory: entry["directory"]?.stringValue)
            }
        }
        var dir = file.deletingLastPathComponent()
        for _ in 0..<6 {
            let flags = dir.appendingPathComponent("compile_flags.txt")
            if let text = try? String(contentsOf: flags, encoding: .utf8) {
                return text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
            dir = dir.deletingLastPathComponent()
        }
        return ["-std=c++20", "-I", file.deletingLastPathComponent().path]
    }

    /// Include paths, defines, standard and warnings of a compile command (no -o/-c/inputs).
    static func relevantFlags(_ args: [String], directory: String?) -> [String] {
        var out: [String] = []
        var i = 0
        while i < args.count {
            let arg = args[i]
            if ["-I", "-D", "-isystem", "-iquote", "-include"].contains(arg), i + 1 < args.count {
                var value = args[i + 1]
                if arg != "-D", !value.hasPrefix("/"), let directory { value = directory + "/" + value }
                out += [arg, value]; i += 2; continue
            }
            if arg.hasPrefix("-I") || arg.hasPrefix("-D") || arg.hasPrefix("-std=") || arg.hasPrefix("-isystem") || arg.hasPrefix("-f") && !arg.hasPrefix("-fprofile") && !arg.hasPrefix("-fcoverage") {
                if arg.hasPrefix("-I"), !arg.hasPrefix("-I/"), let directory { out.append("-I" + directory + "/" + arg.dropFirst(2)) } else { out.append(arg) }
            }
            i += 1
        }
        return out
    }

    func inspectCpp(file: URL) async throws -> [InspectionSection] {
        guard let clang = tools.clangxx() else { throw DebugError.toolNotFound("clang++", hint: ToolFinder.clangHint) }
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let flags = cppFlags(file: file)
        var sections: [InspectionSection] = []
        let filt = tools.developerBinDirectories.map { $0.appendingPathComponent("c++filt").path }.first { FileManager.default.isExecutableFile(atPath: $0) }
        for level in ["-O0", "-O2"] {
            let output = dir.appendingPathComponent("out\(level).s")
            let args = flags + [level, "-S", "-g0", "-fno-asynchronous-unwind-tables", "-fno-exceptions", "-o", output.path, file.path]
            let outcome = try await run(clang.path, args, in: file.deletingLastPathComponent())
            var text = outcome.exitCode == 0 ? ((try? String(contentsOf: output, encoding: .utf8)) ?? "") : outcome.output
            if outcome.exitCode == 0 { text = Self.cleanAssembly(text) }
            if outcome.exitCode == 0, let filt {
                let input = dir.appendingPathComponent("asm\(level).txt")
                try text.write(to: input, atomically: true, encoding: .utf8)
                let demangled = try await run("/bin/sh", ["-c", "\(DebugService.shellQuote(filt)) < \(DebugService.shellQuote(input.path))"], in: dir)
                if demangled.exitCode == 0 { text = demangled.output }
            }
            sections.append(InspectionSection(id: "asm\(level)", title: "Assembly \(level)", text: text,
                                              command: Self.display(clang.path, flags + [level, "-S", file.lastPathComponent]),
                                              failed: outcome.exitCode != 0))
        }
        let object = dir.appendingPathComponent("out.o")
        let compile = try await run(clang.path, flags + ["-c", "-o", object.path, file.path], in: file.deletingLastPathComponent())
        if compile.exitCode == 0, let nm = tools.developerBinDirectories.map({ $0.appendingPathComponent("nm").path }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            let symbols = try await run(nm, ["-C", "-n", object.path], in: dir)
            sections.append(InspectionSection(id: "symbols", title: "Symbols", text: symbols.output, command: "nm -C -n \(file.deletingPathExtension().lastPathComponent).o",
                                              failed: symbols.exitCode != 0))
        } else if compile.exitCode != 0 {
            sections.append(InspectionSection(id: "symbols", title: "Symbols", text: compile.output, failed: true))
        }
        let includes = try await run(clang.path, flags + ["-fsyntax-only", "-H", file.path], in: file.deletingLastPathComponent())
        let tree = includes.output.components(separatedBy: "\n").filter { $0.hasPrefix(".") }.joined(separator: "\n")
        sections.append(InspectionSection(id: "includes", title: "Includes", text: tree.isEmpty ? includes.output : tree,
                                          command: Self.display(clang.path, ["-fsyntax-only", "-H", file.lastPathComponent]),
                                          failed: includes.exitCode != 0))
        return sections
    }

    /// Drops assembler directives that are noise for reading (.loh, .cfi_*, .build_version, .section metadata).
    static func cleanAssembly(_ text: String) -> String {
        text.components(separatedBy: "\n").filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !(trimmed.hasPrefix(".loh") || trimmed.hasPrefix(".cfi_") || trimmed.hasPrefix(".build_version")
                     || trimmed.hasPrefix(".file") || trimmed.hasPrefix(".ident") || trimmed.hasPrefix("; -- End function")
                     || trimmed.hasPrefix(".addrsig"))
        }.joined(separator: "\n")
    }

    // MARK: JavaScript / TypeScript

    static let stripScript = """
    const m = require("node:module"); const fs = require("node:fs");
    const src = fs.readFileSync(process.argv[1], "utf8");
    try { process.stdout.write(m.stripTypeScriptTypes(src)); } catch (e) { console.error(e.message); process.exit(1); }
    """

    func inspectScript(language: Language, file: URL, text: String) async throws -> [InspectionSection] {
        var sections = [InspectionSection(id: "outline", title: "Outline", text: ScriptOutline.outline(text).joined(separator: "\n"))]
        let imports = ScriptOutline.imports(text)
        sections.append(InspectionSection(id: "imports", title: "Imports", text: imports.isEmpty ? "No imports." : imports.joined(separator: "\n")))
        let root = JSTesting.projectRoot(for: file)
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let node = tools.node()
        var env = ProcessInfo.processInfo.environment
        if let node { env["PATH"] = node.deletingLastPathComponent().path + ":" + (env["PATH"] ?? "/usr/bin:/bin") }
        let isTS = language == .typescript
        if isTS || ["jsx", "tsx"].contains(file.pathExtension.lowercased()) {
            if let tsc = tools.nodePackageBinary("tsc", package: "typescript", projectRoot: root) {
                let args = [file.path, "--outDir", dir.path, "--target", "es2022", "--module", "esnext", "--moduleResolution", "bundler",
                            "--skipLibCheck", "--allowJs", "--jsx", "preserve", "--pretty", "false", "--noEmitOnError", "false",
                            "--allowImportingTsExtensions", "--rewriteRelativeImportExtensions"]
                let outcome = try await run(tsc.path, args, in: root, env: env)
                let emitted = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
                    .first { ["js", "mjs", "cjs", "jsx"].contains($0.pathExtension) }
                if let emitted, let js = try? String(contentsOf: emitted, encoding: .utf8) {
                    sections.append(InspectionSection(id: "emitted", title: "Emitted JavaScript", text: js,
                                                      command: Self.display(tsc.path, [file.lastPathComponent, "--target", "es2022"])))
                }
                let diagnostics = outcome.output.trimmingCharacters(in: .whitespacesAndNewlines)
                sections.append(InspectionSection(id: "check", title: "Type Check", text: diagnostics.isEmpty ? "No type errors." : diagnostics,
                                                  command: Self.display(tsc.path, [file.lastPathComponent]), failed: outcome.exitCode != 0 && !diagnostics.isEmpty))
                return sections
            }
            guard let node, isTS else {
                sections.append(InspectionSection(id: "emitted", title: "Emitted JavaScript",
                                                  text: "TypeScript was not found. Install it in the project (`npm install -D typescript`) or globally (`mise use -g npm:typescript`).",
                                                  failed: true))
                return sections
            }
            let outcome = try await run(node.path, ["-e", Self.stripScript, file.path], in: root, env: env)
            sections.append(InspectionSection(id: "emitted", title: "Emitted JavaScript (types stripped)", text: outcome.output,
                                              command: "node: module.stripTypeScriptTypes(\(file.lastPathComponent))", failed: outcome.exitCode != 0))
            sections.append(InspectionSection(id: "check", title: "Type Check",
                                              text: "Install TypeScript (`npm install -D typescript` or `mise use -g npm:typescript`) for type checking.", failed: false))
            return sections
        }
        guard let node else {
            sections.append(InspectionSection(id: "check", title: "Syntax Check", text: "Node.js was not found. " + ToolFinder.nodeHint, failed: true))
            return sections
        }
        let check = try await run(node.path, ["--check", file.path], in: root, env: env)
        sections.append(InspectionSection(id: "check", title: "Syntax Check", text: check.exitCode == 0 ? "No syntax errors." : check.output,
                                          command: "node --check \(file.lastPathComponent)", failed: check.exitCode != 0))
        return sections
    }

    // MARK: WebAssembly

    func inspectWat(file: URL) async throws -> [InspectionSection] {
        if file.pathExtension.lowercased() == "wasm" { return try await inspectBinary(file: file, source: nil) }
        guard let converter = WasmTesting.converter(tools: tools) else {
            throw DebugError.toolNotFound("wasm-tools", hint: ToolFinder.wasmToolsHint)
        }
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        var source = file
        if WasmTesting.isScript(file.path) {
            // A .wast script: inspect its first module.
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            guard let module = WasmScript.firstModule(text) else { throw PreviewError.noPreviews("No (module …) in \(file.lastPathComponent).") }
            source = dir.appendingPathComponent("module.wat")
            try module.write(to: source, atomically: true, encoding: .utf8)
        }
        let binary = dir.appendingPathComponent("module.wasm")
        let outcome = try await run(converter[0], Array(converter.dropFirst()) + [source.path, "-o", binary.path], in: dir)
        guard outcome.exitCode == 0 else {
            return [InspectionSection(id: "validate", title: "Validation", text: outcome.output,
                                      command: Self.display(converter[0], Array(converter.dropFirst()) + [file.lastPathComponent]), failed: true)]
        }
        var sections = try await inspectBinary(file: binary, source: file)
        sections.insert(InspectionSection(id: "validate", title: "Validation", text: "Valid module (\(Self.byteCount(binary)) bytes).",
                                          command: Self.display(converter[0], Array(converter.dropFirst()) + [file.lastPathComponent])), at: 0)
        return sections
    }

    static func byteCount(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
    }

    public func inspectBinary(file: URL, source: URL?) async throws -> [InspectionSection] {
        let data = try Data(contentsOf: file)
        var sections: [InspectionSection] = []
        do {
            sections.append(InspectionSection(id: "module", title: "Module", text: try WasmBinary.parse(data).summary))
        } catch {
            sections.append(InspectionSection(id: "module", title: "Module", text: error.localizedDescription, failed: true))
        }
        if let wasmTools = tools.wasmTools() {
            let outcome = try await run(wasmTools.path, ["print", file.path], in: file.deletingLastPathComponent())
            sections.append(InspectionSection(id: "wat", title: "WAT", text: outcome.output, command: "wasm-tools print \(file.lastPathComponent)",
                                              failed: outcome.exitCode != 0))
            if source == nil {
                let validate = try await run(wasmTools.path, ["validate", file.path], in: file.deletingLastPathComponent())
                sections.insert(InspectionSection(id: "validate", title: "Validation", text: validate.exitCode == 0 ? "Valid module (\(data.count) bytes)." : validate.output,
                                                  command: "wasm-tools validate \(file.lastPathComponent)", failed: validate.exitCode != 0), at: 0)
            }
        } else if let wasm2wat = tools.wabt("wasm2wat") {
            let outcome = try await run(wasm2wat.path, ["--enable-all", file.path], in: file.deletingLastPathComponent())
            sections.append(InspectionSection(id: "wat", title: "WAT", text: outcome.output, command: "wasm2wat \(file.lastPathComponent)",
                                              failed: outcome.exitCode != 0))
        } else {
            sections.append(InspectionSection(id: "wat", title: "WAT", text: "Disassembly needs wasm-tools or wabt. " + ToolFinder.wasmToolsHint, failed: true))
        }
        sections.append(InspectionSection(id: "hex", title: "Hex", text: WasmBinary.hexDump(data)))
        return sections
    }
}

/// `.wast` helpers.
public enum WasmScript {
    /// Text of the first top-level `(module …)` that is not a binary/quoted module.
    public static func firstModule(_ text: String) -> String? {
        let chars = Array(text)
        var depth = 0
        var start: Int?
        var i = 0
        var inString = false
        while i < chars.count {
            let c = chars[i]
            if inString {
                if c == "\\" { i += 2; continue }
                if c == "\"" { inString = false }
            } else if c == "\"" {
                inString = true
            } else if c == ";", i + 1 < chars.count, chars[i + 1] == ";" {
                while i < chars.count, chars[i] != "\n" { i += 1 }
                continue
            } else if c == "(" {
                if depth == 0 {
                    let rest = String(chars[(i + 1)..<min(chars.count, i + 40)]).trimmingCharacters(in: .whitespaces)
                    if rest.hasPrefix("module"), !rest.hasPrefix("module binary"), !rest.hasPrefix("module quote") { start = i }
                }
                depth += 1
            } else if c == ")" {
                depth -= 1
                if depth == 0, let s = start { return String(chars[s...i]) }
            }
            i += 1
        }
        return nil
    }
}

/// Regex outline of JavaScript/TypeScript: functions, classes and their methods, interfaces, types, enums, exports.
public enum ScriptOutline {
    private static let declaration = try! NSRegularExpression(pattern:
        #"^(\s*)(export\s+)?(default\s+)?(declare\s+)?(abstract\s+)?(async\s+)?(function\*?|class|interface|type|enum|namespace|const|let|var)\s+([A-Za-z_$][\w$]*)"#)
    private static let method = try! NSRegularExpression(pattern:
        #"^(\s+)(?:(?:public|private|protected|static|readonly|async|override|get|set)\s+)*[#]?([A-Za-z_$][\w$]*)\s*(?:<[^>]*>)?\s*\([^)]*\)\s*(?::\s*[^{]+)?\{"#)
    private static let importLine = try! NSRegularExpression(pattern: #"^\s*(?:import|export)\s.*?from\s+['"]([^'"]+)['"]|^\s*import\s+['"]([^'"]+)['"]|require\(\s*['"]([^'"]+)['"]\s*\)"#)

    public static func outline(_ text: String) -> [String] {
        var items: [String] = []
        var inClass = false
        var classIndent = 0
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            let range = NSRange(line.startIndex..., in: line)
            if let m = declaration.firstMatch(in: line, range: range),
               let kindRange = Range(m.range(at: 7), in: line), let nameRange = Range(m.range(at: 8), in: line) {
                let indent = Range(m.range(at: 1), in: line).map { line[$0].count } ?? 0
                var kind = String(line[kindRange])
                if ["const", "let", "var"].contains(kind) {
                    guard indent == 0 else { continue }
                    if line.contains("=>") || line.contains("function") { kind = "function" }
                }
                let exported = m.range(at: 2).location != NSNotFound ? "export " : ""
                items.append("\(index + 1): \(String(repeating: "  ", count: min(indent / 2, 4)))\(exported)\(kind) \(line[nameRange])")
                inClass = kind == "class"
                classIndent = indent
                continue
            }
            if inClass, let m = method.firstMatch(in: line, range: range), let nameRange = Range(m.range(at: 2), in: line) {
                let indent = Range(m.range(at: 1), in: line).map { line[$0].count } ?? 0
                let name = String(line[nameRange])
                guard indent > classIndent, !["if", "for", "while", "switch", "catch", "return", "function"].contains(name) else { continue }
                items.append("\(index + 1):   method \(name)")
            }
        }
        return items.isEmpty ? ["No declarations found."] : items
    }

    public static func imports(_ text: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for line in text.components(separatedBy: "\n") {
            let range = NSRange(line.startIndex..., in: line)
            guard let m = importLine.firstMatch(in: line, range: range) else { continue }
            for group in 1...3 {
                if let r = Range(m.range(at: group), in: line) {
                    let module = String(line[r])
                    if seen.insert(module).inserted {
                        let kind = module.hasPrefix("node:") ? "built-in" : (module.hasPrefix(".") || module.hasPrefix("/") ? "relative" : "package")
                        out.append("\(module)  (\(kind))")
                    }
                }
            }
        }
        return out
    }
}
