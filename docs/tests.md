# Tests


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
