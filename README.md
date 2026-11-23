# CrossKit

CrossKit is an Xcode Source Editor Extension that bridges Xcode to Language Server Protocol (LSP) servers for **Kotlin**, **Zig**, **Rust**, **C++**, **JavaScript**, **TypeScript**, and **WebAssembly** text:

| Language | Server | File extensions (default) |
|---|---|---|
| Kotlin | [`kotlin-language-server`](https://github.com/fwcd/kotlin-language-server) | `.kt`, `.kts` |
| Zig | [`zls`](https://github.com/zigtools/zls) | `.zig` |
| Rust | [`rust-analyzer`](https://rust-analyzer.github.io) | `.rs` |
| C++ | [`clangd`](https://clangd.llvm.org) | `.cpp`, `.cc`, `.cxx`, `.c++`, `.hpp`, `.hh`, `.hxx`, `.ipp`, `.tpp` |
| JavaScript | [`typescript-language-server`](https://github.com/typescript-language-server/typescript-language-server) | `.js`, `.mjs`, `.cjs`, `.jsx` |
| TypeScript | `typescript-language-server` (or TypeScript 7's `tsc --lsp`) | `.ts`, `.mts`, `.cts`, `.tsx` |
| WebAssembly | [`wat_server`](https://github.com/g-plane/wasm-language-tools) | `.wat`, `.wast` |

It provides completion, go to definition, find references, diagnostics, and hover info as **Editor › CrossKit** menu commands, which you can bind to keys. It also runs tests with each language's native runner (`zig test` / `zig build test`, `cargo test` / `cargo nextest`, JUnit 5 through Gradle) starts debug sessions (lldb-dap, lldb, CodeLLDB, or JDWP with jdb), builds and runs programs, handles Kotlin Multiplatform JVM and Kotlin/Native targets, renders Compose Multiplatform `@Preview` functions in a Preview window, and approximates Code Lens, inlay hints, and ErrorLens with `// [CrossKit]` comments. C++ (CMake/CTest with GoogleTest or Catch2, lldb-dap), JavaScript/TypeScript (Vitest, Jest, node:test, bun; the Node.js inspector), and WebAssembly (wasmtime, a Node.js harness, `.wast` scripts) also get code coverage in a Coverage window (llvm-cov, V8/istanbul LCOV, instrumented WAT) and file inspections in the Preview window (assembly, symbols, emitted JavaScript, WAT, hex). Source files are shown with macOS-style document icons in CrossKit's windows. A detailed user guide is in [docs/GUIDE.md](docs/GUIDE.md). Everything is configured in a native settings window, so you never edit a config file. CrossKit makes no network calls; it only launches local server binaries.

## How it works

```
Xcode ──XcodeKit──▶ CrossKitExtension.appex (sandboxed)
                         │  CFMessagePort "group.dev.pyrlyn.CrossKit.bridge" (JSON, Content-Length framed)
                         ▼
                    CrossKit.app (host, not sandboxed, menu bar + settings window)
                         │  stdio, JSON-RPC 2.0 with LSP Content-Length framing
                         ▼
          kotlin-language-server / zls / rust-analyzer (one per language + workspace root)
```

* **Why a host app?** Apple requires one to ship the extension. Xcode also only loads *sandboxed* extensions, and a sandboxed process cannot spawn arbitrary binaries. So all process management lives in the host app, which is deliberately **not sandboxed**. The extension only collects the buffer and the cursor, sends a request, and applies the resulting edits.
* **IPC.** The extension and the host share the App Group `group.dev.pyrlyn.CrossKit`. The sandbox lets the extension look up Mach ports prefixed with that group, so the host serves a `CFMessagePort` named `group.dev.pyrlyn.CrossKit.bridge`. No files or sockets are shared, which keeps macOS container-protection prompts out of the way. If the host is not running, the extension launches it in the background.
* **Settings.** They live in `UserDefaults(suiteName: "group.dev.pyrlyn.CrossKit")`, the shared App Group store. The host enforces them, and the extension reads the same store. Defaults are built in: every language is on, every feature is on, binaries are auto-detected, and idle servers stop after 15 minutes.
* **Server lifecycle** (`ServerManager`):
  * A server starts lazily on the first request for its language and workspace root, then completes the `initialize`/`initialized` handshake.
  * Workspace roots are detected from `Cargo.toml`, `build.zig`, `settings.gradle(.kts)`, `build.gradle(.kts)`, or `pom.xml`, then from `.git`, then from the file's folder.
  * A crashed server restarts with exponential backoff (1, 2, 4, 8, 16 s). After 5 crashes in 5 minutes it stays down and the error appears in settings.
  * Idle servers shut down after the configured timeout.
  * Shutdown is clean: `shutdown` → `exit`, then SIGTERM, then SIGKILL. Each server runs in its own process group, so helpers such as rust-analyzer's proc-macro server or zls's `zig build` runner are reaped too. Quitting the host stops everything.

## Build

You need Xcode 16 or later (tested with Xcode 27.2 on macOS 27). The project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen), pinned in `.mise.toml`. The generated `CrossKit.xcodeproj` is committed, so you only need XcodeGen when you change `project.yml`.

```sh
scripts/generate.sh                     # regenerate CrossKit.xcodeproj (optional)
xcodebuild -project CrossKit.xcodeproj -scheme CrossKit -configuration Release \
  -derivedDataPath build/DerivedData build
scripts/test.sh                         # unit + end-to-end tests
```

**Signing.** Xcode refuses App Group entitlements without a provisioning profile, so Xcode's own signing is turned off (`CODE_SIGNING_ALLOWED=NO`). Instead, `scripts/codesign-bundle.sh` signs the finished app inside-out with the right entitlements, ad-hoc (`-`) by default. To sign with your certificate, set an identity:

```sh
CROSSKIT_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" xcodebuild … build
```

## Enable in Xcode

1. Copy `build/DerivedData/Build/Products/Release/CrossKit.app` to `/Applications` and open it once. A menu bar icon appears.
2. Go to **System Settings › General › Login Items & Extensions**, find **Xcode Source Editor** (or **Extensions › Xcode Source Editor**), and enable **CrossKit**. The **Open Extensions Settings…** button in CrossKit opens this pane.
3. Restart Xcode. The commands appear under **Editor › CrossKit**. Bind keys in **Xcode › Settings › Key Bindings** by searching for "CrossKit".
4. The first time you run a command, macOS asks whether CrossKit may control Xcode. Allow it so CrossKit can tell which file is being edited (see Limitations).

## Documentation

A detailed user guide is in [docs/GUIDE.md](docs/GUIDE.md). The README sections that used to follow are now:

- [Settings and language servers](docs/settings-and-language-servers.md)
- [Commands](docs/commands.md)
- [Testing, debugging and previews](docs/testing-and-debugging.md)
- [Limitations](docs/limitations.md)
- [Tests](docs/tests.md)
- [Layout](docs/layout.md)
