# Testing, debugging and previews


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
