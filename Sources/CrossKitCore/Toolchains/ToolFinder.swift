import Foundation

/// Finds the toolchains of the C++, JavaScript/TypeScript and WebAssembly support (compilers, runtimes,
/// test runners, coverage tools) in the same places as language servers: mise installs, Xcode and the
/// Command Line Tools, ~/.cargo/bin, ~/.bun/bin, Homebrew prefixes (never installed by CrossKit) and PATH.
public struct ToolFinder: Sendable {
    public var locator: ServerLocator
    /// Developer directory to search instead of the system one (tests).
    public var developerDirectory: String?

    public init(locator: ServerLocator = ServerLocator(), developerDirectory: String? = nil) {
        self.locator = locator
        self.developerDirectory = developerDirectory
    }

    var developerBinDirectories: [URL] {
        if let developerDirectory {
            let base = URL(fileURLWithPath: developerDirectory)
            return [base.appendingPathComponent("Toolchains/XcodeDefault.xctoolchain/usr/bin"), base.appendingPathComponent("usr/bin")]
        }
        var dirs: [String] = []
        if let selected = DebuggerLocator.selectedDeveloperDirectory { dirs.append(selected) }
        dirs += ["/Applications/Xcode.app/Contents/Developer", "/Library/Developer/CommandLineTools"]
        var seen = Set<String>()
        return dirs.filter { seen.insert($0).inserted }.flatMap {
            [URL(fileURLWithPath: $0).appendingPathComponent("Toolchains/XcodeDefault.xctoolchain/usr/bin"),
             URL(fileURLWithPath: $0).appendingPathComponent("usr/bin")]
        }
    }

    // MARK: C++

    /// Apple clang from Xcode / the Command Line Tools first (its llvm-cov matches its profile format), then mise LLVM.
    public func clangxx() -> URL? {
        // The /usr/bin shim (xcrun) adds the macOS SDK; the toolchain binary alone finds no standard headers.
        if developerDirectory == nil, FileManager.default.isExecutableFile(atPath: "/usr/bin/clang++"),
           developerBinDirectories.contains(where: { FileManager.default.isExecutableFile(atPath: $0.appendingPathComponent("clang++").path) }) {
            return URL(fileURLWithPath: "/usr/bin/clang++")
        }
        return locator.findTools(named: "clang++", miseToolDirectories: ["llvm", "aqua-llvm-llvm-project", "conda-clang"],
                          preferredDirectories: developerBinDirectories).first
    }

    public func cmake() -> URL? {
        locator.findTools(named: "cmake", miseToolDirectories: ["cmake", "aqua-kitware-cmake"]).first
    }

    /// ctest next to the cmake that configures the project.
    public func ctest() -> URL? {
        if let cmake = cmake() {
            let sibling = cmake.deletingLastPathComponent().appendingPathComponent("ctest")
            if FileManager.default.isExecutableFile(atPath: sibling.path) { return sibling }
        }
        return locator.findTools(named: "ctest", miseToolDirectories: ["cmake", "aqua-kitware-cmake"]).first
    }

    /// `llvm-profdata` / `llvm-cov` matching a compiler: the same directory, or the Xcode toolchain for Apple clang.
    public func llvmTool(_ name: String, matching compiler: URL?) -> URL? {
        let fm = FileManager.default
        if let compiler {
            let sibling = compiler.resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent(name)
            if fm.isExecutableFile(atPath: sibling.path) { return sibling }
        }
        for dir in developerBinDirectories where fm.isExecutableFile(atPath: dir.appendingPathComponent(name).path) {
            return dir.appendingPathComponent(name)
        }
        return locator.findTools(named: name, miseToolDirectories: ["llvm", "aqua-llvm-llvm-project", "conda-llvm-tools", "conda-llvm"]).first
    }

    // MARK: JavaScript / TypeScript

    public func node() -> URL? {
        locator.findTools(named: "node", miseToolDirectories: ["node", "nodejs", "aqua-nodejs-node"]).first
    }

    public func bun() -> URL? {
        locator.findTools(named: "bun", miseToolDirectories: ["bun", "aqua-oven-sh-bun"],
                          preferredDirectories: [locator.home.appendingPathComponent(".bun/bin")]).first
    }

    /// Major version of a Node.js binary (`node --version`), cached per path.
    public func nodeMajorVersion(_ node: URL) -> Int? {
        if let cached = Self.versionCache.get(node.path) { return cached }
        let pipe = Pipe()
        let process = Process()
        process.executableURL = node
        process.arguments = ["--version"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let major = Int(text.trimmingCharacters(in: .whitespacesAndNewlines).dropFirst().split(separator: ".").first ?? "")
        Self.versionCache.set(node.path, major)
        return major
    }

    private static let versionCache = Cache<Int?>()

    /// Node.js runs TypeScript directly (type stripping) from version 23.6.
    public func nodeRunsTypeScript(_ node: URL) -> Bool { (nodeMajorVersion(node) ?? 0) >= 23 }

    /// A JS package's executable: the project's node_modules/.bin first, then mise npm installs and global prefixes.
    public func nodePackageBinary(_ name: String, package: String? = nil, projectRoot: URL?) -> URL? {
        let fm = FileManager.default
        var dir = projectRoot
        while let current = dir {
            let candidate = current.appendingPathComponent("node_modules/.bin/\(name)")
            if fm.isExecutableFile(atPath: candidate.path) { return candidate }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path || current.path == SharedPaths.realHomeDirectory.path { break }
            dir = parent
        }
        var preferred: [URL] = []
        for version in locator.sortedChildren(of: locator.miseDataDirectory.appendingPathComponent("installs/npm-\(package ?? name)")) {
            preferred.append(version.appendingPathComponent("node_modules/.bin"))
            preferred.append(version.appendingPathComponent("bin"))
        }
        preferred.append(locator.home.appendingPathComponent(".bun/bin"))
        if let node = node() { preferred.append(node.deletingLastPathComponent()) }
        return locator.findTools(named: name, miseToolDirectories: [], preferredDirectories: preferred).first
    }

    /// `tsserver.js` of a classic TypeScript (5.x/6.x), needed by typescript-language-server: the project's first.
    public func tsserver(projectRoot: URL?) -> URL? {
        let fm = FileManager.default
        var dir = projectRoot
        while let current = dir {
            let candidate = current.appendingPathComponent("node_modules/typescript/lib/tsserver.js")
            if fm.fileExists(atPath: candidate.path) { return candidate }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path || current.path == SharedPaths.realHomeDirectory.path { break }
            dir = parent
        }
        var roots: [URL] = locator.sortedChildren(of: locator.miseDataDirectory.appendingPathComponent("installs/npm-typescript"))
            .map { $0.appendingPathComponent("node_modules") }
        if let node = node() { roots.append(node.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("lib/node_modules")) }
        roots.append(locator.home.appendingPathComponent(".bun/install/global/node_modules"))
        for root in roots {
            let candidate = root.appendingPathComponent("typescript/lib/tsserver.js")
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// TypeScript 7's native compiler, which serves LSP itself (`tsc --lsp --stdio`).
    public func nativeTypeScript(projectRoot: URL?) -> URL? {
        let fm = FileManager.default
        var packages: [URL] = []
        var dir = projectRoot
        while let current = dir {
            packages.append(current.appendingPathComponent("node_modules/typescript"))
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path || current.path == SharedPaths.realHomeDirectory.path { break }
            dir = parent
        }
        packages += locator.sortedChildren(of: locator.miseDataDirectory.appendingPathComponent("installs/npm-typescript"))
            .map { $0.appendingPathComponent("node_modules/typescript") }
        for package in packages {
            guard let data = fm.contents(atPath: package.appendingPathComponent("package.json").path),
                  let json = try? JSONDecoder().decode(JSONValue.self, from: data),
                  let version = json["version"]?.stringValue, (Int(version.split(separator: ".").first ?? "") ?? 0) >= 7 else { continue }
            let tsc = package.appendingPathComponent("bin/tsc")
            if fm.fileExists(atPath: tsc.path) { return tsc }
        }
        return locator.findTools(named: "tsgo", miseToolDirectories: ["npm-typescript-native-preview"]).first
    }

    // MARK: WebAssembly

    public func wasmTools() -> URL? {
        locator.findTools(named: "wasm-tools", miseToolDirectories: ["wasm-tools", "aqua-bytecodealliance-wasm-tools", "cargo-wasm-tools"]).first
    }

    public func wasmtime() -> URL? {
        locator.findTools(named: "wasmtime", miseToolDirectories: ["wasmtime", "aqua-bytecodealliance-wasmtime"],
                          preferredDirectories: [locator.home.appendingPathComponent(".wasmtime/bin")]).first
    }

    /// wabt's tools (wat2wasm, wasm2wat, wasm-objdump).
    public func wabt(_ name: String) -> URL? {
        locator.findTools(named: name, miseToolDirectories: ["wabt", "aqua-webassembly-wabt", "npm-wabt"]).first
    }

    public static let wasmToolsHint = "Install wasm-tools (`mise use -g wasm-tools`) or wabt (`mise use -g wabt`)."
    public static let wasmtimeHint = "Install Wasmtime (`mise use -g wasmtime`)."
    public static let nodeHint = "Install Node.js (`mise use -g node@lts`)."
    public static let cmakeHint = "Install CMake (`mise use -g cmake`)."
    public static let clangHint = "Install Xcode or the Command Line Tools (`xcode-select --install`)."
}

/// A tiny thread-safe cache.
final class Cache<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Value] = [:]
    func get(_ key: String) -> Value? { lock.withLock { values[key] } }
    func set(_ key: String, _ value: Value) { lock.withLock { values[key] = value } }
}

/// How a language server is started for a workspace: the binary, its arguments and LSP initializationOptions.
public struct ServerLaunch: Equatable, Sendable {
    public var executable: URL
    public var arguments: [String]
    public var initializationOptions: JSONValue?

    /// JavaScript/TypeScript: typescript-language-server needs a classic TypeScript (tsserver.js); without one,
    /// TypeScript 7's native `tsc --lsp --stdio` serves instead. User arguments replace the defaults.
    public static func resolve(language: Language, binary: URL, userArguments: [String], root: URL,
                               tools: ToolFinder) throws -> ServerLaunch {
        var launch = ServerLaunch(executable: binary, arguments: userArguments, initializationOptions: nil)
        guard language == .javascript || language == .typescript else { return launch }
        let name = binary.lastPathComponent
        if name == "tsc" || name == "tsgo" {
            if userArguments.isEmpty || userArguments == ["--stdio"] { launch.arguments = ["--lsp", "--stdio"] }
            return launch
        }
        if userArguments.isEmpty { launch.arguments = ["--stdio"] }
        if let tsserver = tools.tsserver(projectRoot: root) {
            launch.initializationOptions = ["tsserver": ["path": .string(tsserver.path)], "hostInfo": "CrossKit"]
            return launch
        }
        if let native = tools.nativeTypeScript(projectRoot: root) {
            return ServerLaunch(executable: native, arguments: ["--lsp", "--stdio"], initializationOptions: nil)
        }
        throw BridgeError.unsupported("typescript-language-server needs TypeScript: add it to the project (`npm i -D typescript`) or install it globally (`mise use -g npm:typescript`).")
    }
}
