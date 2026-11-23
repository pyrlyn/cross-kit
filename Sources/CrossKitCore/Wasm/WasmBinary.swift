import Foundation

/// A minimal WebAssembly binary reader: sections, types, imports, functions, exports, names and code offsets.
/// Used by the Preview window (module summary) and by WebAssembly debugging (function body offsets).
public struct WasmBinary: Equatable, Sendable {
    public struct Section: Equatable, Sendable {
        public var id: UInt8
        public var name: String
        /// Offset of the section contents and their size.
        public var offset: Int
        public var size: Int
    }

    public struct FuncType: Equatable, Sendable {
        public var params: [String]
        public var results: [String]
        public var description: String { "(\(params.joined(separator: ", "))) -> (\(results.joined(separator: ", ")))" }
    }

    public struct Import: Equatable, Sendable {
        public var module: String
        public var name: String
        public var kind: String
        /// Function imports: type index.
        public var typeIndex: Int?
    }

    public struct Export: Equatable, Sendable {
        public var name: String
        public var kind: String
        public var index: Int
    }

    public struct Function: Equatable, Sendable {
        /// Index in the function index space (imports first).
        public var index: Int
        public var typeIndex: Int
        /// Offset of the body (its size LEB), of the first instruction (after locals) and the body end.
        public var bodyOffset: Int
        public var codeOffset: Int
        public var endOffset: Int
        public var name: String?
    }

    public var version: UInt32
    public var sections: [Section] = []
    public var types: [FuncType] = []
    public var imports: [Import] = []
    public var functions: [Function] = []
    public var exports: [Export] = []
    public var memories: [String] = []
    public var tables: [String] = []
    public var globals: Int = 0
    public var dataSegments: Int = 0
    public var start: Int?
    public var moduleName: String?

    public var importedFunctionCount: Int { imports.filter { $0.kind == "func" }.count }

    public enum ParseError: Error, LocalizedError, Equatable {
        case notWasm, truncated(Int), malformed(String)
        public var errorDescription: String? {
            switch self {
            case .notWasm: return "Not a WebAssembly binary (missing \\0asm header)."
            case .truncated(let offset): return "Truncated WebAssembly binary at offset \(offset)."
            case .malformed(let detail): return "Malformed WebAssembly binary: \(detail)"
            }
        }
    }

    static let sectionNames: [UInt8: String] = [
        0: "custom", 1: "type", 2: "import", 3: "function", 4: "table", 5: "memory", 6: "global", 7: "export",
        8: "start", 9: "element", 10: "code", 11: "data", 12: "datacount", 13: "tag",
    ]

    static func valueType(_ byte: UInt8) -> String {
        switch byte {
        case 0x7f: return "i32"
        case 0x7e: return "i64"
        case 0x7d: return "f32"
        case 0x7c: return "f64"
        case 0x7b: return "v128"
        case 0x70: return "funcref"
        case 0x6f: return "externref"
        default: return String(format: "0x%02x", byte)
        }
    }

    struct Reader {
        let bytes: [UInt8]
        var pos: Int
        let end: Int

        mutating func byte() throws -> UInt8 {
            guard pos < end else { throw ParseError.truncated(pos) }
            defer { pos += 1 }
            return bytes[pos]
        }

        mutating func u32() throws -> Int {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while true {
                let b = try byte()
                result |= UInt64(b & 0x7f) << shift
                if b & 0x80 == 0 { break }
                shift += 7
                if shift > 35 { throw ParseError.malformed("LEB128 too long at \(pos)") }
            }
            return Int(result)
        }

        mutating func skipSigned() throws {
            while try byte() & 0x80 != 0 {}
        }

        mutating func name() throws -> String {
            let length = try u32()
            guard pos + length <= end else { throw ParseError.truncated(pos) }
            defer { pos += length }
            return String(decoding: bytes[pos..<pos + length], as: UTF8.self)
        }

        mutating func limits() throws -> String {
            let flags = try byte()
            let min = try u32()
            if flags & 1 != 0 { return "\(min)..\(try u32())" }
            return "\(min).."
        }

        /// Skips a constant expression (up to and including `end`).
        mutating func skipConstExpr() throws {
            while true {
                let op = try byte()
                switch op {
                case 0x0b: return
                case 0x41, 0x42: try skipSigned()
                case 0x43: pos += 4
                case 0x44: pos += 8
                case 0x23, 0xd2: _ = try u32()
                case 0xd0: _ = try byte()
                case 0xfd: _ = try u32(); pos += 16
                default: break
                }
                guard pos <= end else { throw ParseError.truncated(pos) }
            }
        }
    }

    public static func parse(_ data: Data) throws -> WasmBinary {
        let bytes = [UInt8](data)
        guard bytes.count >= 8, bytes[0] == 0, bytes[1] == 0x61, bytes[2] == 0x73, bytes[3] == 0x6d else { throw ParseError.notWasm }
        let version = UInt32(bytes[4]) | UInt32(bytes[5]) << 8 | UInt32(bytes[6]) << 16 | UInt32(bytes[7]) << 24
        var module = WasmBinary(version: version)
        var r = Reader(bytes: bytes, pos: 8, end: bytes.count)
        var functionTypes: [Int] = []
        var names: [Int: String] = [:]
        while r.pos < r.end {
            let id = try r.byte()
            let size = try r.u32()
            let start = r.pos
            guard start + size <= bytes.count else { throw ParseError.truncated(start) }
            var s = Reader(bytes: bytes, pos: start, end: start + size)
            var name = sectionNames[id] ?? "unknown(\(id))"
            switch id {
            case 0:
                let custom = try s.name()
                name = "custom \"\(custom)\""
                if custom == "name" { parseNames(&s, into: &names, moduleName: &module.moduleName) }
            case 1:
                for _ in 0..<(try s.u32()) {
                    let form = try s.byte()
                    guard form == 0x60 else {
                        // GC proposal types (rec/sub/struct/array): summary only.
                        module.types.append(FuncType(params: ["<type form 0x\(String(form, radix: 16))>"], results: []))
                        s.pos = s.end
                        break
                    }
                    let params = try (0..<s.u32()).map { _ in valueType(try s.byte()) }
                    let results = try (0..<s.u32()).map { _ in valueType(try s.byte()) }
                    module.types.append(FuncType(params: params, results: results))
                }
            case 2:
                for _ in 0..<(try s.u32()) {
                    let m = try s.name(), n = try s.name()
                    let kind = try s.byte()
                    switch kind {
                    case 0: module.imports.append(Import(module: m, name: n, kind: "func", typeIndex: try s.u32()))
                    case 1: _ = try s.byte(); module.imports.append(Import(module: m, name: n, kind: "table: \(try s.limits())"))
                    case 2: module.imports.append(Import(module: m, name: n, kind: "memory: \(try s.limits())"))
                    case 3:
                        let type = valueType(try s.byte())
                        let mutable = try s.byte() == 1
                        module.imports.append(Import(module: m, name: n, kind: "global: \(mutable ? "mut " : "")\(type)"))
                    case 4: _ = try s.byte(); _ = try s.u32(); module.imports.append(Import(module: m, name: n, kind: "tag"))
                    default: throw ParseError.malformed("import kind \(kind)")
                    }
                }
            case 3:
                functionTypes = try (0..<s.u32()).map { _ in try s.u32() }
            case 4:
                for _ in 0..<(try s.u32()) { let t = valueType(try s.byte()); module.tables.append("\(t) \(try s.limits())") }
            case 5:
                for _ in 0..<(try s.u32()) { module.memories.append(try s.limits()) }
            case 6:
                module.globals = try s.u32()
            case 7:
                for _ in 0..<(try s.u32()) {
                    let n = try s.name()
                    let kind = try s.byte()
                    let index = try s.u32()
                    let kindName = ["func", "table", "memory", "global", "tag"][Int(min(kind, 4))]
                    module.exports.append(Export(name: n, kind: kindName, index: index))
                }
            case 8:
                module.start = try s.u32()
            case 10:
                let count = try s.u32()
                let imported = module.importedFunctionCount
                for i in 0..<count {
                    let bodyOffset = s.pos
                    let bodySize = try s.u32()
                    let bodyStart = s.pos
                    var b = Reader(bytes: bytes, pos: bodyStart, end: bodyStart + bodySize)
                    for _ in 0..<(try b.u32()) { _ = try b.u32(); _ = try b.byte() }
                    let typeIndex = i < functionTypes.count ? functionTypes[i] : 0
                    module.functions.append(Function(index: imported + i, typeIndex: typeIndex, bodyOffset: bodyOffset,
                                                     codeOffset: b.pos, endOffset: bodyStart + bodySize))
                    s.pos = bodyStart + bodySize
                }
            case 11:
                module.dataSegments = try s.u32()
            default:
                break
            }
            module.sections.append(Section(id: id, name: name, offset: start, size: size))
            r.pos = start + size
        }
        for i in module.functions.indices { module.functions[i].name = names[module.functions[i].index] }
        return module
    }

    static func parseNames(_ s: inout Reader, into names: inout [Int: String], moduleName: inout String?) {
        while s.pos < s.end {
            guard let sub = try? s.byte(), let size = try? s.u32() else { return }
            let next = s.pos + size
            if sub == 0 { moduleName = try? s.name() }
            if sub == 1, let count = try? s.u32() {
                for _ in 0..<count {
                    guard let index = try? s.u32(), let name = try? s.name() else { return }
                    names[index] = name
                }
            }
            s.pos = next
        }
    }

    /// The function name as WAT would show it (`$name` or `func[3]`).
    public func displayName(ofFunction index: Int) -> String {
        if index < importedFunctionCount {
            let imp = imports.filter { $0.kind == "func" }[index]
            return "\(imp.module).\(imp.name)"
        }
        if let name = functions.first(where: { $0.index == index })?.name { return "$" + name }
        if let export = exports.first(where: { $0.kind == "func" && $0.index == index }) { return "\"\(export.name)\"" }
        return "func[\(index)]"
    }

    /// Human-readable module summary for the Preview window.
    public var summary: String {
        var lines: [String] = ["WebAssembly binary, version \(version)" + (moduleName.map { " — module $\($0)" } ?? "")]
        lines.append("")
        lines.append("Sections:")
        for section in sections {
            lines.append(String(format: "  %-18@ offset 0x%06x  %8d bytes", section.name as NSString, section.offset, section.size))
        }
        if !types.isEmpty {
            lines.append("")
            lines.append("Types (\(types.count)):")
            for (i, type) in types.enumerated() { lines.append("  type[\(i)] \(type.description)") }
        }
        if !imports.isEmpty {
            lines.append("")
            lines.append("Imports (\(imports.count)):")
            for imp in imports {
                let sig = imp.typeIndex.flatMap { $0 < types.count ? types[$0].description : nil } ?? ""
                lines.append("  \(imp.module).\(imp.name)  \(imp.kind)\(sig.isEmpty ? "" : " " + sig)")
            }
        }
        if !functions.isEmpty {
            lines.append("")
            lines.append("Functions (\(functions.count) defined):")
            for function in functions {
                let sig = function.typeIndex < types.count ? types[function.typeIndex].description : "type[\(function.typeIndex)]"
                let size = function.endOffset - function.bodyOffset
                lines.append(String(format: "  %@  %@  body 0x%06x, %d bytes", displayName(ofFunction: function.index) as NSString,
                                    sig as NSString, function.bodyOffset, size))
            }
        }
        if !exports.isEmpty {
            lines.append("")
            lines.append("Exports (\(exports.count)):")
            for export in exports {
                let target = export.kind == "func" ? displayName(ofFunction: export.index) : "\(export.kind)[\(export.index)]"
                lines.append("  \"\(export.name)\"  \(export.kind) → \(target)")
            }
        }
        var other: [String] = []
        if !memories.isEmpty { other.append("memories: " + memories.joined(separator: ", ") + " pages") }
        if !tables.isEmpty { other.append("tables: " + tables.joined(separator: ", ")) }
        if globals > 0 { other.append("globals: \(globals)") }
        if dataSegments > 0 { other.append("data segments: \(dataSegments)") }
        if let start { other.append("start: \(displayName(ofFunction: start))") }
        if !other.isEmpty { lines.append(""); lines += other }
        return lines.joined(separator: "\n")
    }

    /// Classic hex dump (offset, 16 bytes, ASCII) of the first `limit` bytes.
    public static func hexDump(_ data: Data, limit: Int = 1024) -> String {
        let bytes = [UInt8](data.prefix(limit))
        var lines: [String] = []
        for row in stride(from: 0, to: bytes.count, by: 16) {
            let chunk = bytes[row..<min(row + 16, bytes.count)]
            let hex = chunk.map { String(format: "%02x", $0) }.joined(separator: " ")
            let ascii = String(chunk.map { (32...126).contains($0) ? Character(UnicodeScalar($0)) : "." })
            lines.append(String(format: "%08x  %-47@  %@", row, hex as NSString, ascii as NSString))
        }
        if data.count > limit { lines.append("… \(data.count - limit) more bytes") }
        return lines.joined(separator: "\n")
    }
}
