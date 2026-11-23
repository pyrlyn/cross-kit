import Foundation

public enum Language: String, CaseIterable, Codable, Identifiable, Sendable {
    case kotlin
    case zig
    case rust
    case cpp
    case javascript
    case typescript
    /// WebAssembly text format (`.wat`, `.wast`); binary `.wasm` modules are inspected in the Preview window.
    case wasm

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .kotlin: return "Kotlin"
        case .zig: return "Zig"
        case .rust: return "Rust"
        case .cpp: return "C++"
        case .javascript: return "JavaScript"
        case .typescript: return "TypeScript"
        case .wasm: return "WebAssembly"
        }
    }

    /// LSP `languageId` used in `textDocument/didOpen`.
    public var languageID: String {
        switch self {
        case .wasm: return "wat"
        default: return rawValue
        }
    }

    /// The `languageId` for a particular file: JSX/TSX need the React variants, `.wast` scripts their own id.
    public func languageID(forPath path: String?) -> String {
        let ext = ((path ?? "") as NSString).pathExtension.lowercased()
        switch (self, ext) {
        case (.javascript, "jsx"): return "javascriptreact"
        case (.typescript, "tsx"): return "typescriptreact"
        case (.wasm, "wast"): return "wast"
        default: return languageID
        }
    }

    /// Executable name of the language server.
    public var serverBinaryName: String {
        switch self {
        case .kotlin: return "kotlin-language-server"
        case .zig: return "zls"
        case .rust: return "rust-analyzer"
        case .cpp: return "clangd"
        case .javascript, .typescript: return "typescript-language-server"
        case .wasm: return "wat_server"
        }
    }

    public var defaultExtensions: [String] {
        switch self {
        case .kotlin: return ["kt", "kts"]
        case .zig: return ["zig"]
        case .rust: return ["rs"]
        // `.h` is left out on purpose: in Xcode it is usually a C or Objective-C header.
        case .cpp: return ["cpp", "cc", "cxx", "c++", "hpp", "hh", "hxx", "ipp", "tpp"]
        case .javascript: return ["js", "mjs", "cjs", "jsx"]
        case .typescript: return ["ts", "mts", "cts", "tsx"]
        case .wasm: return ["wat", "wast"]
        }
    }

    /// Extra server arguments by default. typescript-language-server's `--stdio` (or `--lsp --stdio` for
    /// TypeScript 7's tsc) is added by `ServerLaunch` when no arguments are set.
    public var defaultArguments: [String] { [] }

    /// Files that mark a project root, nearest first.
    public var rootMarkers: [String] {
        switch self {
        case .kotlin: return ["settings.gradle.kts", "settings.gradle", "build.gradle.kts", "build.gradle", "pom.xml"]
        case .zig: return ["build.zig", "zls.json"]
        case .rust: return ["Cargo.toml", "rust-project.json"]
        case .cpp: return ["compile_commands.json", "compile_flags.txt", ".clangd", "CMakeLists.txt", "meson.build"]
        case .javascript: return ["package.json", "jsconfig.json", "tsconfig.json", "deno.json"]
        case .typescript: return ["tsconfig.json", "package.json", "deno.json"]
        case .wasm: return ["wasm-project.json", "package.json", "Cargo.toml", "build.zig"]
        }
    }

    /// mise install directory names that may contain the server.
    public var miseToolDirectoryNames: [String] {
        switch self {
        case .kotlin: return ["github-fwcd-kotlin-language-server", "kotlin-language-server", "ubi-fwcd-kotlin-language-server", "aqua-fwcd-kotlin-language-server"]
        case .zig: return ["zls", "aqua-zigtools-zls", "github-zigtools-zls", "ubi-zigtools-zls"]
        case .rust: return ["rust-analyzer", "aqua-rust-lang-rust-analyzer", "github-rust-lang-rust-analyzer"]
        case .cpp: return ["clangd", "aqua-clangd-clangd", "github-clangd-clangd", "llvm", "aqua-llvm-llvm-project", "conda-clang-tools", "conda-clang"]
        case .javascript, .typescript: return ["npm-typescript-language-server", "typescript-language-server"]
        case .wasm: return ["github-g-plane-wasm-language-tools", "aqua-g-plane-wasm-language-tools", "ubi-g-plane-wasm-language-tools",
                            "cargo-wasm-language-tools", "wasm-language-tools"]
        }
    }

    public var installHint: String {
        switch self {
        case .kotlin: return "mise install github:fwcd/kotlin-language-server@latest"
        case .zig: return "mise install zls@<your zig version>"
        case .rust: return "rustup component add rust-analyzer"
        case .cpp: return "clangd ships with Xcode and the Command Line Tools (`xcode-select --install`); or `mise use -g clangd`"
        case .javascript, .typescript: return "mise use -g npm:typescript-language-server npm:typescript (needs Node.js, e.g. `mise use -g node`)"
        case .wasm: return "mise use -g github:g-plane/wasm-language-tools (or `cargo install wasm-language-tools`)"
        }
    }

    /// Kotlin LS indexes slowly; give it more time.
    public var initializeTimeout: TimeInterval { self == .kotlin ? 240 : 90 }
    public var requestTimeout: TimeInterval { self == .kotlin ? 180 : 60 }
    public var diagnosticsTimeout: TimeInterval { self == .kotlin ? 120 : 45 }

    /// Line comment start: CrossKit's annotation lines use it (`// [CrossKit]`, `;; [CrossKit]` in WAT).
    public var lineCommentPrefix: String { self == .wasm ? ";;" : "//" }

    /// Guess from an Xcode content UTI such as `public.rust-source`.
    public static func guess(fromUTI uti: String) -> Language? {
        let lower = uti.lowercased()
        if lower.contains("kotlin") { return .kotlin }
        if lower.contains("zig") { return .zig }
        if lower.contains("rust") { return .rust }
        if lower.contains("c-plus-plus") || lower.contains("cpp") { return .cpp }
        if lower.contains("typescript") { return .typescript }
        if lower.contains("javascript") { return .javascript }
        if lower.contains("webassembly") || lower.contains("wasm") || lower.hasSuffix(".wat") { return .wasm }
        return nil
    }

    /// Language for a path by its default extensions (settings may map more extensions).
    public static func guess(fromPath path: String) -> Language? {
        let ext = (path as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        return allCases.first { $0.defaultExtensions.contains(ext) }
    }
}

public enum Feature: String, CaseIterable, Codable, Identifiable, Sendable {
    case completion
    case definition
    case references
    case diagnostics
    case hover
    case tests
    case coverage
    case debug
    case run
    case codeLens
    case inlayHints
    case errorLens
    case preview

    public var id: String { rawValue }

    /// Previews exist for Kotlin (Compose), C++, JavaScript, TypeScript and WebAssembly; coverage for the
    /// languages with a coverage tool CrossKit drives.
    public func applies(to language: Language) -> Bool {
        switch self {
        case .preview: return language != .zig && language != .rust
        case .coverage: return [.cpp, .javascript, .typescript, .wasm].contains(language)
        default: return true
        }
    }

    public var displayName: String {
        switch self {
        case .completion: return "Completion"
        case .definition: return "Go to Definition"
        case .references: return "Find References"
        case .diagnostics: return "Diagnostics"
        case .hover: return "Hover"
        case .tests: return "Run Tests"
        case .coverage: return "Code Coverage"
        case .debug: return "Debugging"
        case .run: return "Build & Run"
        case .codeLens: return "Code Lens"
        case .inlayHints: return "Inlay Hints"
        case .errorLens: return "ErrorLens"
        case .preview: return "Preview"
        }
    }

    /// Feature name shown for a language (Kotlin previews are Compose previews).
    public func displayName(for language: Language) -> String {
        switch (self, language) {
        case (.preview, .kotlin): return "Compose Preview"
        case (.preview, .wasm): return "Module Preview (WAT / sections)"
        case (.preview, .cpp): return "Preview (assembly, symbols)"
        case (.preview, .javascript), (.preview, .typescript): return "Preview (module outline, emitted JS)"
        default: return displayName
        }
    }
}
