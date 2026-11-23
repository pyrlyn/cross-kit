import Foundation

/// Line hits of one function.
public struct FunctionCoverage: Codable, Equatable, Sendable {
    public var name: String
    /// 1-based line.
    public var line: Int
    public var hits: Int

    public init(name: String, line: Int, hits: Int) {
        self.name = name
        self.line = line
        self.hits = hits
    }
}

/// Coverage of one source file. Lines are 1-based (as in LCOV).
public struct FileCoverage: Codable, Equatable, Identifiable, Sendable {
    public var path: String
    /// Executable lines and how often each ran.
    public var lines: [Int: Int]
    public var functions: [FunctionCoverage]
    public var branchesFound: Int
    public var branchesHit: Int

    public var id: String { path }

    public init(path: String, lines: [Int: Int] = [:], functions: [FunctionCoverage] = [], branchesFound: Int = 0, branchesHit: Int = 0) {
        self.path = path
        self.lines = lines
        self.functions = functions
        self.branchesFound = branchesFound
        self.branchesHit = branchesHit
    }

    public var linesFound: Int { lines.count }
    public var linesHit: Int { lines.values.filter { $0 > 0 }.count }
    public var functionsHit: Int { functions.filter { $0.hits > 0 }.count }
    /// Line coverage in percent (100 for files without executable lines).
    public var percent: Double { linesFound == 0 ? 100 : Double(linesHit) * 100 / Double(linesFound) }

    /// Uncovered executable lines merged into ranges, e.g. [5...9, 14...14].
    public var uncoveredRanges: [ClosedRange<Int>] {
        let missed = lines.filter { $0.value == 0 }.keys.sorted()
        var ranges: [ClosedRange<Int>] = []
        for line in missed {
            if let last = ranges.last, last.upperBound + 1 == line || isGap(between: last.upperBound, and: line) {
                ranges[ranges.count - 1] = last.lowerBound...line
            } else {
                ranges.append(line...line)
            }
        }
        return ranges
    }

    /// Two missed lines separated only by non-executable lines belong to one range.
    private func isGap(between a: Int, and b: Int) -> Bool {
        guard b > a + 1 else { return false }
        return (a + 1..<b).allSatisfy { lines[$0] == nil }
    }

    /// Adds another report of the same file (hits are summed).
    public mutating func merge(_ other: FileCoverage) {
        for (line, hits) in other.lines { lines[line, default: 0] += hits }
        for function in other.functions {
            if let i = functions.firstIndex(where: { $0.name == function.name && $0.line == function.line }) {
                functions[i].hits += function.hits
            } else {
                functions.append(function)
            }
        }
        branchesFound = max(branchesFound, other.branchesFound)
        branchesHit = max(branchesHit, other.branchesHit)
    }
}

public struct CoverageReport: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var language: Language
    public var tool: String
    public var createdAt: Date
    /// The project the paths are relative to in the UI.
    public var projectRoot: String
    public var files: [FileCoverage]
    public var testRun: TestRunResult?
    public var warning: String?

    public init(id: UUID = UUID(), language: Language, tool: String, createdAt: Date = Date(), projectRoot: String,
                files: [FileCoverage], testRun: TestRunResult? = nil, warning: String? = nil) {
        self.id = id
        self.language = language
        self.tool = tool
        self.createdAt = createdAt
        self.projectRoot = projectRoot
        self.files = files.sorted { $0.path < $1.path }
        self.testRun = testRun
        self.warning = warning
    }

    public var linesFound: Int { files.reduce(0) { $0 + $1.linesFound } }
    public var linesHit: Int { files.reduce(0) { $0 + $1.linesHit } }
    public var percent: Double { linesFound == 0 ? 100 : Double(linesHit) * 100 / Double(linesFound) }

    public func file(_ path: String) -> FileCoverage? {
        let target = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return files.first { $0.path == path || URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == target }
    }

    public var summary: String {
        String(format: "%.1f%% of lines covered (%d/%d) in %d file%@", percent, linesHit, linesFound, files.count, files.count == 1 ? "" : "s")
    }
}

/// Where a test run leaves its raw coverage data.
public struct CoverageArtifacts: Codable, Equatable, Sendable {
    public enum Format: String, Codable, Sendable {
        /// An LCOV tracefile (node:test, Vitest, Jest, bun).
        case lcov
        /// A directory of `.profraw` files (clang `-fprofile-instr-generate`), merged with llvm-profdata.
        case llvmProfiles
        /// Counters of a WebAssembly text module instrumented by `WatInstrumenter`, printed by the harness.
        case watCounters
    }

    public var format: Format
    /// LCOV file, profile directory, or the JSON file with the WAT probes.
    public var path: String
    /// Directory relative LCOV paths are resolved against.
    public var baseDirectory: String
    /// C++: CrossKit's CMake build tree with the instrumented binaries.
    public var buildDirectory: String?
    /// C++: the compiler, to pick a matching llvm-profdata/llvm-cov.
    public var compiler: String?
    /// WebAssembly: the original source file the probes refer to.
    public var sourceFile: String?
    /// Scratch directory of this run (removed after the report is built).
    public var scratchDirectory: String?

    public init(format: Format, path: String, baseDirectory: String, buildDirectory: String? = nil, compiler: String? = nil,
                sourceFile: String? = nil, scratchDirectory: String? = nil) {
        self.format = format
        self.path = path
        self.baseDirectory = baseDirectory
        self.buildDirectory = buildDirectory
        self.compiler = compiler
        self.sourceFile = sourceFile
        self.scratchDirectory = scratchDirectory
    }
}

/// LCOV tracefile parser (`SF:`, `FN:`, `FNDA:`, `DA:`, `BRF:`, `BRH:`, `end_of_record`).
public enum LCOVParser {
    public static func parse(_ text: String, baseDirectory: String) -> [FileCoverage] {
        var files: [String: FileCoverage] = [:]
        var order: [String] = []
        var current: FileCoverage?
        func finish() {
            guard let file = current else { return }
            if files[file.path] == nil { order.append(file.path); files[file.path] = file } else { files[file.path]?.merge(file) }
            current = nil
        }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let colon = line.firstIndex(of: ":") else {
                if line == "end_of_record" { finish() }
                continue
            }
            let key = String(line[..<colon])
            let value = String(line[line.index(after: colon)...])
            switch key {
            case "SF":
                finish()
                let path = value.hasPrefix("/") ? value : URL(fileURLWithPath: baseDirectory).appendingPathComponent(value).standardizedFileURL.path
                current = FileCoverage(path: path)
            case "DA":
                let parts = value.split(separator: ",")
                if parts.count >= 2, let n = Int(parts[0]) {
                    current?.lines[n, default: 0] += Int(min(Double(parts[1]) ?? 0, Double(Int32.max)))
                }
            case "FN":
                let parts = value.split(separator: ",", maxSplits: 2)
                if parts.count >= 2, let n = Int(parts[0]) {
                    // LCOV 2: FN:start,end,name
                    let name = parts.count == 3 && Int(parts[1]) != nil ? String(parts[2]) : String(parts[1...].joined(separator: ","))
                    current?.functions.append(FunctionCoverage(name: name, line: n, hits: 0))
                }
            case "FNDA":
                let parts = value.split(separator: ",", maxSplits: 1)
                if parts.count == 2, let hits = Int(parts[0]) {
                    let name = String(parts[1])
                    if let i = current?.functions.firstIndex(where: { $0.name == name }) { current?.functions[i].hits += hits }
                }
            case "BRF": current?.branchesFound += Int(value) ?? 0
            case "BRH": current?.branchesHit += Int(value) ?? 0
            default: break
            }
        }
        finish()
        return order.compactMap { files[$0] }
    }
}
