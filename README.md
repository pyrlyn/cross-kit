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

## Settings window

Open **CrossKit.app**, the menu bar icon, or **Editor › CrossKit › Open CrossKit Settings** in Xcode. For each language you can:

* **Turn the language on or off.**
* **Pick the server binary.** CrossKit auto-detects it by default. You can also pick one from the list of detected binaries, choose a file with **Choose…**, or go back to auto-detection.
* **Turn individual features on or off:** completion, go to definition, find references, diagnostics, hover, running tests, debugging, Build & Run, Code Lens, inlay hints, ErrorLens, and (Kotlin) Compose Preview.
* **Kotlin targets:** the target for Multiplatform modules (auto, JVM, Kotlin/Native for this Mac, or a named target), the debugger for Kotlin/Native binaries, and whether to keep the Gradle daemon running.
* **Configure debugging:** the debugger (auto-detected or forced), its binary, and the Kotlin JDWP port. Per-project launch configurations are listed and editable at the bottom of the window.
* **Configure test running:** the runner (auto-detected or forced), the test tool binary (auto-detected or chosen), and extra arguments such as `--offline`.
* **See live server status:** running (with pid and workspace), starting, restarting, stopped, error, or not found. The last error is shown with the tail of the server's stderr, next to **Restart** and **Stop** buttons.

The idle timeout, the test timeout, the inline-annotation options (what lenses, hints, and ErrorLens show, and where hints go), how long Run File waits for a program, and the Compose preview scale and auto-refresh are global settings. Changes are saved immediately; there is no Save button.

### Auto-detection order

Auto-detection checks these locations in order and uses the first executable it finds:

1. Rust only: `~/.rustup/toolchains/*/bin/rust-analyzer`, newest toolchain first.
2. mise installs, newest version first, for example `~/.local/share/mise/installs/zls/<ver>/zls` or `…/github-fwcd-kotlin-language-server/<ver>/bin/kotlin-language-server`. `MISE_DATA_DIR` is respected.
3. `~/.cargo/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, and `~/.sdkman/candidates/*/current/bin`.
4. mise shims (`~/.local/share/mise/shims`), used only if the tool is actually installed.
5. Directories on `PATH`.

Servers get an extended `PATH`, so `cargo`, `zig`, and `java` resolve even when the app was started from Finder. Kotlin also gets `JAVA_HOME`, preferring JDK 21, then 17, then any JDK found in mise or `/Library/Java`. A Rust toolchain binary also pins `RUSTUP_TOOLCHAIN`.

## Install the language servers

Install whichever servers you need. CrossKit never installs anything itself.

```sh
# Rust
rustup component add rust-analyzer

# Zig: zls must match your Zig version (check with `zig version`)
mise install zls@0.17          # or download from https://github.com/zigtools/zls/releases

# Kotlin (needs a JDK; 17 or 21 recommended)
mise install github:fwcd/kotlin-language-server@latest
# or unzip server.zip from https://github.com/fwcd/kotlin-language-server/releases

# C++: clangd ships with Xcode / the Command Line Tools; CMake for tests and coverage
mise use -g cmake@latest

# JavaScript / TypeScript (Node.js 23.6+ runs TypeScript directly)
mise use -g node@lts npm:typescript npm:typescript-language-server

# WebAssembly text
mise use -g github:g-plane/wasm-language-tools wasmtime github:bytecodealliance/wasm-tools
```

If a server is installed somewhere unusual, use **Choose…** in settings to point at it.

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

## Commands

| Command | LSP request | What happens in the editor |
|---|---|---|
| Complete at Cursor | `textDocument/completion` | Replaces the identifier prefix with the best-ranked match. Snippets become plain text. The caret moves to the end. |
| List Completions | `textDocument/completion` | Inserts up to 40 ranked candidates as comment lines above the cursor. |
| Go to Definition | `textDocument/definition` | In the same file, selects the definition. In another file, Xcode opens it at the right line (`xed --line`) and a comment shows the location. |
| Find References | `textDocument/references` | Inserts a comment block listing `path:line:col` with a preview for each reference. |
| Show Hover Info | `textDocument/hover` | Inserts the hover text (signature and docs) as comments above the cursor. |
| Show Diagnostics | pushed `publishDiagnostics` (or pull `textDocument/diagnostic`) | Inserts `// [CrossKit] error: …` above each affected line. |
| Show Test Markers | – | Inserts `// [CrossKit] ▶ test …` above every test found in the file. |
| Run Tests in File | – | Runs every test in the file, shows a pass/fail summary alert, and puts a `✓ passed` / `✗ failed — reason` marker above each test. |
| Run Test at Cursor | – | Runs only the test that encloses the cursor. |
| Debug File at Cursor | – | Builds the program and debugs it with a breakpoint on the cursor line. |
| Debug Test at Cursor | – | Builds and debugs only the test that encloses the cursor. |
| Build Project | – | Builds the project (or loose file) for the current language and Kotlin target; the alert shows success or the compiler output. |
| Run File | – | Builds and runs the file's `main`; short runs show their output in the alert, long ones keep running in the Run window. |
| Run Tests with Coverage | – | Runs the file's tests (or the one at the cursor) with coverage, marks uncovered blocks with `░ not covered: lines a–b`, and opens the Coverage window. C++, JavaScript, TypeScript, WebAssembly. |
| Show Preview | – | Kotlin: renders the file's `@Preview` composables to PNG on the desktop JVM and shows them in the Preview window, focused on the one at the cursor. C++, JS/TS, WebAssembly: shows the file's inspection tabs (assembly, symbols, emitted JavaScript, WAT, …). |
| Show Code Lenses | `textDocument/documentSymbol`, `textDocument/references` | Inserts `// [CrossKit] ◆ N references · ▶ Run · ⚙ Debug` above declarations (Run Test / Debug Test above tests, Preview above previews). |
| Show Inlay Hints | `textDocument/inlayHint` | Inserts type and parameter hints above the line (`‹: i32›`) or at its end (`  // [CrossKit] » total: i32, a: 1`). |
| Show ErrorLens Diagnostics | diagnostics | Appends the most severe diagnostic of each line at its end: `  // [CrossKit] ✖ error: …`. |
| Refresh Inline Annotations | all of the above | Refreshes every enabled kind; never duplicates. |
| Clear Inline Annotations | – | Removes lenses, hints, and ErrorLens comments only. |
| Clear CrossKit Annotations | – | Removes every `// [CrossKit]` line and trailing `// [CrossKit]` segment. |
| Open CrossKit Settings | – | Brings up the host app. |

Annotation lines are ordinary `//` comments and always start with `// [CrossKit]` (`;; [CrossKit]` in WebAssembly text), so you can remove them with one command. Undo works as usual.

## Running tests

| Language | Runners (auto-detect picks the first that applies) | Test discovery |
|---|---|---|
| Zig | `zig build test` when the project has `build.zig`, otherwise `zig test <file>` (with `--test-filter` for one test) | `test "name" { … }`, `test name { … }`, and unnamed `test { … }` blocks |
| Rust | `cargo nextest run` when cargo-nextest is installed, otherwise `cargo test` | `#[test]`, `#[tokio::test]`, and similar attributes inside nested `mod`s; when rust-analyzer is available, its `experimental/runnables` supply the exact test paths and cargo arguments |
| Kotlin | `./gradlew test` when the project has a wrapper, otherwise `gradle test`; filtered with `--tests` | `@Test`, `@ParameterizedTest`, `@RepeatedTest`, and `@TestFactory` functions, including `@Nested` inner classes |
| C++ | CMake + CTest (`ctest -R … --output-junit`) in a CrossKit build folder | GoogleTest `TEST`/`TEST_F`/`TEST_P`/`TYPED_TEST`, Catch2/doctest `TEST_CASE`/`SCENARIO` |
| JavaScript, TypeScript | `bun:test`/`node:test` imports, then Vitest or Jest from imports or `package.json`, then `node --test` | `test`/`it` inside `describe`/`suite`, with `.only`/`.skip` |
| WebAssembly | `wasmtime run --invoke` (or the Node.js harness) for exported `test*` functions; `wasmtime wast` for `.wast` | `(export "test…")` functions, `assert_*` directives |

Every run also appears in the host app's **Test Results** window: the command, working directory, duration, full output, and a table of tests with status, time, failure output, and a `file:line` button that opens the test in Xcode. Gradle results come from the JUnit XML reports in `build/test-results/test` (`build/test-results/<target>Test` in Multiplatform modules). If a runner or toolchain is missing, the alert says what to install or which setting to change. Tests run against the saved file, and you get a warning if the buffer has unsaved changes. Runs time out after the configured test timeout (15 minutes by default); the whole process group is then stopped.

## Debugging

**Debug File at Cursor** and **Debug Test at Cursor** build the program (or the single test) and start a debugger with a breakpoint on the cursor line:

| Language | Build | Debugger (auto-detect first) |
|---|---|---|
| Zig | `zig build-exe` / `zig build install`; tests via `zig test --test-filter … --test-no-exec` | lldb-dap (managed by CrossKit, Debugger window), lldb in Terminal, or CodeLLDB |
| Rust | `cargo build` / `cargo test --no-run`, executable taken from Cargo's JSON output | the same |
| Kotlin | Gradle compiles and reports the runtime classpath; the JVM starts with a JDWP agent (`suspend=y`); tests run via Gradle with the agent in the test JVM | jdb in Terminal (already attached, breakpoint set), or wait for an IDE to attach |
| C++ | CMake Debug build (target found with CMake's File API, test command from `ctest --show-only=json-v1`), or `clang++ -g -O0` for a loose file | lldb-dap, lldb in Terminal, or CodeLLDB |
| JavaScript, TypeScript | none (TypeScript runs with Node.js type stripping); tests in-process with node:test, Vitest, or Jest | Node.js inspector in the Debugger window (CDP), `node inspect` in Terminal, or wait for Chrome DevTools / VS Code |
| WebAssembly | `.wat` → `.wasm` with `wasm-tools`/`wat2wasm`, run in a Node.js harness | Node.js inspector with `.wat` line mapping; lldb + `wasmtime -D debug-info` for modules with DWARF |

The host app's **Debugger** window shows sessions with Continue / Step Over / Step Into / Step Out / Pause / Stop, the call stack (click to open the line in Xcode), local variables, and program output. Debuggers are auto-detected from Xcode, the Command Line Tools, Homebrew LLVM, and VS Code/Cursor extensions (CodeLLDB), and can be overridden per language. Each project gets an auto-saved **launch configuration** (program or main class, arguments, environment, working directory, test binary arguments), editable in the settings window. Stopping a session, a program exit, or quitting CrossKit leaves no processes behind.

## Build & Run, Kotlin targets, previews, inline annotations

* **Build Project / Run File:** `zig build-exe` or `zig build install`, `cargo build`, and Gradle per Kotlin target. Every build and run is listed in the host app's **Run** window with its commands, live output, exit code, and a **Stop** button.
* **Kotlin Multiplatform targets** are read from `build.gradle(.kts)`. The file's source set decides first (`jvmMain` → JVM, `macosArm64Main`/`nativeMain` → Native), then the launch configuration's **Kotlin target**, then the setting. JVM targets use `<target>MainClasses`, `<target>Test`, and the JDWP debug path. Kotlin/Native uses `linkDebugExecutable<Target>` and runs or debugs the `.kexe` with lldb-dap (or lldb / CodeLLDB); **Debug Test at Cursor** links `linkDebugTest<Target>` and runs `test.kexe --ktest_filter=…`.
* **Compose previews:** CrossKit finds `@Preview` functions, compiles the module's JVM target, and renders each preview headless with Compose Desktop's `ImageComposeScene` through a tiny renderer compiled once with `javac`. PNGs go to `~/Library/Caches/CrossKit/Preview`; the **Preview** window shows them, highlights the one at the cursor, and re-renders on save.
* **Inline annotations:** lenses above declarations, inlay hints above the line or at its end, and ErrorLens at the end of the line, as `// [CrossKit]` comments. Each kind can be turned off per language; refreshing replaces instead of duplicating, and lines that end inside a multi-line string or comment get their annotation above instead.

See [docs/GUIDE.md](docs/GUIDE.md) for the detailed user guide.

## Limitations

These are XcodeKit constraints and the workarounds CrossKit uses:

* **No custom UI inside the editor.** Extensions can only run menu commands that edit the buffer and selection. There is no completion pop-up, no squiggles, no hover tooltip, no real Code Lens or inlay hints, and no live diagnostics; every feature runs on demand, and inline annotations are comments that you refresh with a command. Extra information is inserted as removable comment lines, and messages appear as Xcode alerts, because XcodeKit can only show text as an error.
* **Xcode does not tell extensions the file path.** The host asks Xcode through Apple Events which source documents are open and picks the one whose contents match the buffer. If that fails, for example because Automation permission was denied, the buffer goes into a scratch project in `~/Library/Caches/CrossKit/Scratch`. Single-file features still work, but cross-file results refer to the scratch project.
* **Columns.** LSP positions use UTF-16 code units, the same as XcodeKit's. If you indent with tabs, Xcode may report columns with tabs expanded, which can shift the column slightly.
* **One request at a time.** The bridge handles requests sequentially, so a slow Kotlin request delays the next command.
* **Kotlin without a build file** (a loose `.kt` file) has no stdlib classpath, so `println` and similar are reported as unresolved. In Gradle or Maven projects, kotlin-language-server resolves the classpath with Gradle or Maven, which may use the network on their side. CrossKit itself never does.
* **Cold start.** The first request per language waits for the server to start; Kotlin takes the longest. Empty results during the first minute are retried briefly while the server indexes.
* **Kotlin targets** come from a simple parse of `build.gradle(.kts)`; targets declared in convention plugins need to be named in the settings or launch configuration. Only the host macOS target runs; other native targets can only be built.
* **Compose previews** render on the desktop JVM: no Android resources, `@PreviewParameter`, multipreview annotations, interaction, or animation.
* **New languages:** C++ tests and coverage need CMake; Vitest coverage needs `@vitest/coverage-v8`; bun tests cannot be debugged; WebAssembly line mapping inside functions is approximate. Xcode's own navigator icons cannot be changed by an extension. See the guide's chapter 19.
* **Signing.** Ad-hoc signed builds are meant for local use. For distribution, sign with a Developer ID, ideally with a provisioning profile for the App Group, and notarize.
* **Not covered by automated tests.** The XcodeKit glue (`SourceEditorCommand`) can only run inside Xcode. Everything below it, from the editor command engine through the bridge, server manager, and real servers, is covered by tests.

## Tests

```sh
scripts/test.sh
```

* **Unit tests:**
  * LSP/JSON-RPC framing and codec: partial chunks, byte-vs-character lengths, header errors, and request/response/notification encoding.
  * LSP result conversion: Location, LocationLink, CompletionList, snippets, and hover shapes.
  * The editor command engine.
  * Settings persistence.
  * Auto-detection against a fake home directory.
  * The CFMessagePort bridge.
  * A fake Python language server that crashes on purpose, to check initialization, automatic restart with backoff, feature toggles, and that no processes are left behind.
* **End-to-end tests** (`EndToEndTests`), one per language:
  * Each test auto-detects the real server, or skips with an install hint if it is missing.
  * It creates a temporary project (a Cargo crate, a `build.zig` project, or a `.kt` file).
  * It drives the extension's layer (`EditorCommandEngine` → `BridgeClient` → `BridgeServer` → `BridgeHandler` → `ServerManager` → server) and checks startup and initialization, diagnostics for a seeded syntax error, completion of a partial identifier, go to definition, and hover.
  * It then shuts the server down cleanly and checks that the process group is gone.
* **Test-running unit tests:** test discovery for each language, output parsers (`zig test`, `zig build test`, libtest, nextest, JUnit XML, Gradle console), runner selection and command construction against a fake toolchain, missing-tool messages, and editor test markers.
* **Debugging unit tests:** debugger detection against a fake toolchain, launch-plan generation for every language and target, launch-configuration auto-save and overrides, argument/environment parsing, lldb command generation, Cargo artifact parsing, Kotlin class resolution, and unsaved-annotation line mapping.
* **Debugging end-to-end tests** (`DebugEndToEndTests`): Zig and Rust debug a program and a single test through lldb-dap, check that the breakpoint is hit at the right line with the right local variables, run to a clean exit, and check that no adapter or debuggee process is left. A Zig test also runs the generated lldb Terminal script in batch mode. Two Kotlin tests (a program, and a JUnit test via Gradle) start the JVM with JDWP, attach jdb exactly like the Terminal script, hit the breakpoint, read the locals, and exit cleanly.
* **Feature unit tests** (`FeatureUnitTests.swift`): Kotlin target parsing and selection, task and output paths, Native and JVM launch plans (link tasks, `--ktest_filter`, `-Pcrosskit.target`, launch-config overrides, non-host errors, Gradle daemon flags), Multiplatform test tasks, `@Preview` discovery, inline annotation placement, merging, refresh, clear, unsafe line ends, LSP inlay-hint and symbol conversion, Build/Run/Preview command messages, and settings round trips.
* **Feature end-to-end tests** (`FeatureEndToEndTests`), with fixtures in `build/e2e` and the Gradle daemon off: Zig and Rust Build Project and Run File; a Kotlin Multiplatform project built, run, tested, and debugged with lldb-dap on Kotlin/Native (`macosArm64`), then run and tested on the JVM; a Compose Multiplatform module whose three previews are rendered to PNGs of the expected size; and Code Lens, inlay hints, ErrorLens, refresh, and clear against rust-analyzer and zls. Each skips when its toolchain (or, for Kotlin, its offline Gradle caches; set `CROSSKIT_E2E_NETWORK=1` to allow downloads) is missing.
* **Language unit tests** (`LanguageUnitTests.swift`): C++/JS/TS/WebAssembly test discovery, CTest regexes and CMake File API parsing, JUnit/Jest/wasmtime/`.wast` result parsing, WAT function lookup and coverage instrumentation, the `.wasm` binary reader, LCOV parsing and uncovered ranges, `;; [CrossKit]` marker mapping, Chrome DevTools Protocol helpers, debugger choices, and file icon styles.
* **Coverage end-to-end tests** (`CoverageEndToEndTests`): **Run Tests with Coverage** for a CMake/C++ project (llvm-cov), TypeScript and JavaScript (node:test, V8 LCOV), and WebAssembly (instrumented WAT through the Node.js harness), plus the inspection tabs of every new language.
* The LSP, test-running and debugging end-to-end suites also cover clangd, typescript-language-server (JS and TS), wat_server, CTest, node:test, Vitest, wasmtime, the Node.js harness, `.wast`, lldb-dap for C++ files and CTest tests, and the Node.js inspector for JavaScript, TypeScript, Vitest, and WebAssembly.
* **Test-running end-to-end tests** (`TestRunEndToEndTests`), one per language: a temporary project with one passing and one failing test is run through the bridge with **Run Tests in File** and **Run Test at Cursor**, checking statuses, failure output, `file:line` links, and markers. Each test skips if its toolchain is missing. The Kotlin test passes `--offline` when JUnit is already in the Gradle cache.

## Layout

```
project.yml                      XcodeGen spec (source of truth for CrossKit.xcodeproj)
Sources/CrossKitCore/            shared framework: framing, JSON-RPC, LSP client, process mgmt,
                                 server manager, settings, auto-detection, bridge, editor engine
Sources/CrossKitCore/Testing/    test discovery, runners, result parsers
Sources/CrossKitCore/Debugging/  debugger detection, launch planning, DAP client, debug sessions
Sources/CrossKitCore/Kotlin/     Kotlin Multiplatform target parsing and selection
Sources/CrossKitCore/Running/    Build Project and Run File
Sources/CrossKitCore/Preview/    @Preview discovery, embedded renderer, preview rendering, file inspections
Sources/CrossKitCore/Coverage/   coverage runs, LCOV/llvm-cov/WAT counter collection
Sources/CrossKitCore/Wasm/       WAT scanning and instrumentation, .wasm reader, Node.js harness
Sources/CrossKitCore/Icons/      file icon styles (badge and colours per file type)
Sources/CrossKitCore/Annotations/ Code Lens, inlay hint, and ErrorLens comment placement
Sources/CrossKitApp/             host app: settings, Test Results, Debugger, Run, Preview and Coverage windows, file icons, menu bar, Xcode lookup
docs/GUIDE.md                    detailed user guide
Sources/CrossKitExtension/       XcodeKit extension (commands → bridge → buffer edits)
Tests/CrossKitCoreTests/         unit + end-to-end tests
scripts/                         generate.sh, test.sh, codesign-bundle.sh
```
