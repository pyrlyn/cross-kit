import Foundation

/// Finds language-server binaries in common install locations without running any installer.
public struct ServerLocator: Sendable {
    public var home: URL
    public var pathEnvironment: String
    public var miseDataDirectory: URL

    public init(home: URL = SharedPaths.realHomeDirectory,
                pathEnvironment: String = ProcessInfo.processInfo.environment["PATH"] ?? "",
                miseDataDirectory: URL? = nil) {
        self.home = home
        self.pathEnvironment = pathEnvironment
        if let miseDataDirectory {
            self.miseDataDirectory = miseDataDirectory
        } else if let env = ProcessInfo.processInfo.environment["MISE_DATA_DIR"], !env.isEmpty {
            self.miseDataDirectory = URL(fileURLWithPath: env, isDirectory: true)
        } else {
            self.miseDataDirectory = home.appendingPathComponent(".local/share/mise", isDirectory: true)
        }
    }

    private var fileManager: FileManager { .default }

    /// First usable binary for the language, or nil.
    public func detect(_ language: Language) -> URL? {
        candidates(for: language).first
    }

    /// All usable binaries for the language, best first, de-duplicated by resolved path.
    public func candidates(for language: Language) -> [URL] {
        let name = language.serverBinaryName
        var result: [URL] = []
        var seen = Set<String>()
        func add(_ url: URL) {
            let resolved = url.resolvingSymlinksInPath().path
            guard isExecutableFile(url.path), !seen.contains(resolved) else { return }
            seen.insert(resolved)
            result.append(url)
        }

        // 1. Real binaries shipped with rustup toolchains (newest first).
        if language == .rust {
            for toolchain in sortedChildren(of: home.appendingPathComponent(".rustup/toolchains")) {
                add(toolchain.appendingPathComponent("bin/\(name)"))
            }
        }
        // 1b. clangd from Xcode / the Command Line Tools (the real binary, not the /usr/bin xcrun shim).
        if language == .cpp {
            for dir in ToolFinder(locator: self).developerBinDirectories { add(dir.appendingPathComponent(name)) }
        }
        // 2. mise installs (newest version first), searched a few levels deep.
        let installs = miseDataDirectory.appendingPathComponent("installs")
        for toolDir in language.miseToolDirectoryNames {
            for version in sortedChildren(of: installs.appendingPathComponent(toolDir)) {
                // npm packages keep their executables in node_modules/.bin (hidden directories are not searched).
                add(version.appendingPathComponent("node_modules/.bin/\(name)"))
                for found in findExecutables(named: name, in: version, maxDepth: 4) { add(found) }
            }
        }
        // 3. Well-known bin directories.
        var dirs: [URL] = [
            home.appendingPathComponent(".cargo/bin"),
            URL(fileURLWithPath: "/opt/homebrew/bin"),
            URL(fileURLWithPath: "/usr/local/bin"),
            home.appendingPathComponent(".local/bin"),
        ]
        for candidate in sortedChildren(of: home.appendingPathComponent(".sdkman/candidates")) {
            dirs.append(candidate.appendingPathComponent("current/bin"))
        }
        dirs.append(miseDataDirectory.appendingPathComponent("shims"))
        // 4. PATH.
        dirs += pathEnvironment.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        for dir in dirs {
            let url = dir.appendingPathComponent(name)
            if language == .rust, url.path.hasSuffix(".cargo/bin/rust-analyzer"), !rustupProxyHasComponent() {
                continue // rustup proxy without the component installed just prints an error
            }
            if url.deletingLastPathComponent().lastPathComponent == "shims", !miseShimHasVersion(url) {
                continue
            }
            add(url)
        }
        // 5. JavaScript/TypeScript: TypeScript 7's native compiler serves LSP itself (`tsc --lsp --stdio`).
        if language == .javascript || language == .typescript, let native = ToolFinder(locator: self).nativeTypeScript(projectRoot: nil) {
            add(native)
        }
        return result
    }

    /// Generic lookup for toolchain binaries (zig, cargo, gradle, …), best first.
    public func findTools(named name: String, miseToolDirectories: [String], preferredDirectories: [URL] = []) -> [URL] {
        var result: [URL] = []
        var seen = Set<String>()
        func add(_ url: URL) {
            let resolved = url.resolvingSymlinksInPath().path
            guard isExecutableFile(url.path), !seen.contains(resolved) else { return }
            seen.insert(resolved)
            result.append(url)
        }
        for dir in preferredDirectories { add(dir.appendingPathComponent(name)) }
        let installs = miseDataDirectory.appendingPathComponent("installs")
        for toolDir in miseToolDirectories {
            for version in sortedChildren(of: installs.appendingPathComponent(toolDir)) {
                for found in findExecutables(named: name, in: version, maxDepth: 3) { add(found) }
            }
        }
        var dirs: [URL] = [home.appendingPathComponent(".cargo/bin"), URL(fileURLWithPath: "/opt/homebrew/bin"),
                           URL(fileURLWithPath: "/usr/local/bin"), home.appendingPathComponent(".local/bin")]
        for candidate in sortedChildren(of: home.appendingPathComponent(".sdkman/candidates")) {
            dirs.append(candidate.appendingPathComponent("current/bin"))
        }
        dirs += pathEnvironment.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        for dir in dirs { add(dir.appendingPathComponent(name)) }
        return result
    }

    /// Tool directories a server needs on PATH (e.g. `cargo` for rust-analyzer, `zig` for zls, `java` for Kotlin LS).
    public func supportDirectories(for language: Language) -> [URL] {
        var dirs: [URL] = []
        switch language {
        case .rust:
            dirs.append(home.appendingPathComponent(".cargo/bin"))
        case .zig:
            let zigInstalls = miseDataDirectory.appendingPathComponent("installs/zig")
            for version in sortedChildren(of: zigInstalls) where isExecutableFile(version.appendingPathComponent("zig").path) {
                dirs.append(version)
                break
            }
        case .kotlin:
            if let javaHome = javaHome() { dirs.append(javaHome.appendingPathComponent("bin")) }
        case .javascript, .typescript:
            // typescript-language-server and tsc are Node.js scripts.
            if let node = ToolFinder(locator: self).node() { dirs.append(node.deletingLastPathComponent()) }
        case .cpp, .wasm:
            break
        }
        dirs.append(miseDataDirectory.appendingPathComponent("shims"))
        return dirs
    }

    /// A JDK suitable for kotlin-language-server (prefers 21, then 17, then any).
    public func javaHome() -> URL? {
        if let env = ProcessInfo.processInfo.environment["JAVA_HOME"], isExecutableFile(env + "/bin/java") {
            return URL(fileURLWithPath: env)
        }
        let javaInstalls = sortedChildren(of: miseDataDirectory.appendingPathComponent("installs/java"))
        func home(of dir: URL) -> URL? {
            for candidate in [dir, dir.appendingPathComponent("Contents/Home")]
            where isExecutableFile(candidate.appendingPathComponent("bin/java").path) {
                return candidate
            }
            return nil
        }
        for preferred in ["21", "17"] {
            for dir in javaInstalls where dir.lastPathComponent.contains(preferred) {
                if let h = home(of: dir) { return h }
            }
        }
        for dir in javaInstalls { if let h = home(of: dir) { return h } }
        for jvm in sortedChildren(of: URL(fileURLWithPath: "/Library/Java/JavaVirtualMachines")) {
            if let h = home(of: jvm) { return h }
        }
        return nil
    }

    // MARK: Helpers

    func isExecutableFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
            && fileManager.isExecutableFile(atPath: path)
    }

    /// Children sorted by version-like name, newest first.
    public func sortedChildren(of dir: URL) -> [URL] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: dir.path) else { return [] }
        // Concrete versions (digit-first names) before aliases like "latest", newest first.
        func rank(_ name: String) -> Int { name.first?.isNumber == true ? 0 : 1 }
        return names.filter { !$0.hasPrefix(".") }
            .sorted { rank($0) != rank($1) ? rank($0) < rank($1) : $0.compare($1, options: .numeric) == .orderedDescending }
            .map { dir.appendingPathComponent($0) }
    }

    func findExecutables(named name: String, in dir: URL, maxDepth: Int) -> [URL] {
        var found: [URL] = []
        var queue: [(URL, Int)] = [(dir, 0)]
        while !queue.isEmpty {
            let (current, depth) = queue.removeFirst()
            let direct = current.appendingPathComponent(name)
            if isExecutableFile(direct.path) { found.append(direct) }
            guard depth < maxDepth, let children = try? fileManager.contentsOfDirectory(atPath: current.path) else { continue }
            for child in children.sorted() where !child.hasPrefix(".") {
                let url = current.appendingPathComponent(child)
                var isDir: ObjCBool = false
                if fileManager.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                    queue.append((url, depth + 1))
                }
            }
        }
        return found
    }

    private func rustupProxyHasComponent() -> Bool {
        // The proxy works if any toolchain ships the component; we prefer the toolchain binary anyway.
        sortedChildren(of: home.appendingPathComponent(".rustup/toolchains")).contains {
            isExecutableFile($0.appendingPathComponent("bin/rust-analyzer").path)
        }
    }

    private func miseShimHasVersion(_ shim: URL) -> Bool {
        // A mise shim only works when the tool is installed; check the installs directory.
        let tool = shim.lastPathComponent
        let names = Language.allCases.first { $0.serverBinaryName == tool }?.miseToolDirectoryNames ?? [tool]
        return names.contains { !sortedChildren(of: miseDataDirectory.appendingPathComponent("installs/\($0)")).isEmpty }
    }
}

public enum ServerEnvironment {
    /// Environment for a server process: inherits ours and extends PATH so helper tools resolve
    /// even when the host app was launched from Finder with a minimal PATH.
    public static func make(language: Language, binary: URL, locator: ServerLocator,
                            base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base
        var paths: [String] = [binary.deletingLastPathComponent().path]
        paths += locator.supportDirectories(for: language).map(\.path)
        paths += [locator.home.appendingPathComponent(".cargo/bin").path, "/opt/homebrew/bin", "/usr/local/bin"]
        paths += (base["PATH"] ?? "").split(separator: ":").map(String.init)
        paths += ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()
        env["PATH"] = paths.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
        switch language {
        case .kotlin:
            if env["JAVA_HOME"] == nil, let javaHome = locator.javaHome() { env["JAVA_HOME"] = javaHome.path }
        case .rust:
            // Binary inside ~/.rustup/toolchains/<name>/bin → pin cargo/rustc to the same toolchain.
            let components = binary.pathComponents
            if let index = components.firstIndex(of: "toolchains"), index + 1 < components.count,
               components.contains(".rustup") {
                env["RUSTUP_TOOLCHAIN"] = components[index + 1]
            }
        case .zig, .cpp, .javascript, .typescript, .wasm:
            break
        }
        return env
    }
}

public enum WorkspaceResolver {
    /// Nearest ancestor containing a language root marker, else nearest `.git`, else the file's directory.
    public static func root(for file: URL, language: Language) -> URL {
        let fm = FileManager.default
        let start = file.deletingLastPathComponent()
        var current = start
        var gitRoot: URL?
        let stop = Set(["/", SharedPaths.realHomeDirectory.path])
        while true {
            if language.rootMarkers.contains(where: { fm.fileExists(atPath: current.appendingPathComponent($0).path) }) {
                return current
            }
            if gitRoot == nil, fm.fileExists(atPath: current.appendingPathComponent(".git").path) {
                gitRoot = current
            }
            if stop.contains(current.path) { break }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return gitRoot ?? start
    }

    /// A throwaway project used when the edited file's path is unknown (e.g. unsaved buffer).
    public static func scratchFile(for language: Language, text: String, in directory: URL) throws -> URL {
        let fm = FileManager.default
        let root = directory.appendingPathComponent(language.rawValue, isDirectory: true)
        let file: URL
        switch language {
        case .rust:
            try fm.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
            let manifest = root.appendingPathComponent("Cargo.toml")
            if !fm.fileExists(atPath: manifest.path) {
                try "[package]\nname = \"crosskit-scratch\"\nversion = \"0.1.0\"\nedition = \"2021\"\n\n[dependencies]\n"
                    .write(to: manifest, atomically: true, encoding: .utf8)
            }
            file = root.appendingPathComponent("src/main.rs")
        case .zig:
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            file = root.appendingPathComponent("main.zig")
        case .kotlin:
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            file = root.appendingPathComponent("Main.kt")
        case .cpp:
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            let flags = root.appendingPathComponent("compile_flags.txt")
            if !fm.fileExists(atPath: flags.path) { try "-std=c++20\n-Wall\n".write(to: flags, atomically: true, encoding: .utf8) }
            file = root.appendingPathComponent("main.cpp")
        case .javascript:
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            file = root.appendingPathComponent("main.js")
        case .typescript:
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            let config = root.appendingPathComponent("tsconfig.json")
            if !fm.fileExists(atPath: config.path) {
                try #"{ "compilerOptions": { "strict": true, "target": "es2022", "module": "nodenext" } }"#
                    .write(to: config, atomically: true, encoding: .utf8)
            }
            file = root.appendingPathComponent("main.ts")
        case .wasm:
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            file = root.appendingPathComponent("main.wat")
        }
        try text.write(to: file, atomically: true, encoding: .utf8)
        return file
    }
}
