# CrossKit User Guide

This guide explains how to install, configure, and use CrossKit day to day: language features, running tests, debugging, building and running programs, Kotlin JVM and Native targets, Compose previews, and inline annotations (Code Lens, inlay hints, ErrorLens) for Kotlin, Zig, Rust, C++, JavaScript, TypeScript, and WebAssembly from Xcode. C++, JavaScript/TypeScript, and WebAssembly have their own chapter, [C++, JavaScript, TypeScript, and WebAssembly](#19-c-javascript-typescript-and-webassembly), which also covers code coverage and file inspections. For architecture and build details, see the [README](../README.md).

## Contents

1. [What CrossKit is](#1-what-crosskit-is)
2. [Requirements](#2-requirements)
3. [Installation](#3-installation)
4. [The host app](#4-the-host-app)
5. [Settings reference](#5-settings-reference)
6. [Editor commands](#6-editor-commands)
7. [Language features](#7-language-features)
8. [Running tests](#8-running-tests)
9. [Debugging](#9-debugging)
10. [Build and run](#10-build-and-run)
11. [Kotlin targets: JVM and Native](#11-kotlin-targets-jvm-and-native)
12. [Compose previews](#12-compose-previews)
13. [Inline annotations: Code Lens, inlay hints, ErrorLens](#13-inline-annotations-code-lens-inlay-hints-errorlens)
14. [Launch configurations](#14-launch-configurations)
15. [Annotations and markers](#15-annotations-and-markers)
16. [Where CrossKit keeps things](#16-where-crosskit-keeps-things)
17. [Troubleshooting](#17-troubleshooting)
18. [Known limitations](#18-known-limitations)
19. [C++, JavaScript, TypeScript, and WebAssembly](#19-c-javascript-typescript-and-webassembly)
20. [File icons](#20-file-icons)

---

## 1. What CrossKit is

CrossKit has two parts:

* **CrossKit.app**, the host app. It lives in the menu bar, owns the settings window, and does all the real work: it starts language servers, test runners, build tools, programs, debuggers, and the Compose preview renderer.
* **CrossKit Extension**, an Xcode Source Editor Extension. It adds the **Editor › CrossKit** menu. Each command sends the current buffer and cursor to the host app and applies the result to the editor.

Xcode extensions cannot draw custom UI in the editor. So CrossKit shows results in three ways:

* **Editor edits.** For example, completion inserts text and go to definition moves the selection.
* **Comment lines** starting with `// [CrossKit]`, such as diagnostics, hover text, test results, code lenses, inlay hints, and ErrorLens messages. Inline annotations can also be appended to the end of a code line as `  // [CrossKit] …`. One command removes them all.
* **An alert**, used for short messages such as a test summary or "No definition found". XcodeKit can only show text this way.

Longer output goes to the host app's windows: **Test Results**, **Debugger**, **Run** (build and program output), **Preview** (rendered Compose previews and file inspections), and **Coverage** (line coverage per file).

WebAssembly text has no `//` comments, so in `.wat` and `.wast` files CrossKit writes `;; [CrossKit]` instead. Everything said about `// [CrossKit]` lines applies to them too.

## 2. Requirements

* macOS 14 or later, and Xcode 16 or later (tested with Xcode 27.2).
* For each language you want to use:

| Language | Language server | Tests | Debugging | Build & Run |
|---|---|---|---|---|
| Kotlin | `kotlin-language-server` + a JDK (17 or 21 recommended) | Gradle (`./gradlew` or `gradle`) with JUnit 5 or `kotlin.test` | JVM: a JDK (`java`, `jdb`) + Gradle. Kotlin/Native: `lldb-dap` or `lldb` | Gradle + a JDK |
| Zig | `zls` matching your Zig version | `zig` | `zig` + `lldb-dap` or `lldb` (from Xcode or the Command Line Tools) | `zig` |
| Rust | `rust-analyzer` | `cargo` (optionally `cargo-nextest`) | `cargo` + `lldb-dap` or `lldb`, or CodeLLDB | `cargo` |
| C++ | `clangd` (ships with Xcode) | CMake + CTest (`cmake`, `ctest`) with GoogleTest, Catch2, or doctest | `clang++` + `lldb-dap` or `lldb` (Xcode) | `clang++`, or CMake |
| JavaScript | `typescript-language-server` + Node.js | Vitest, Jest, `node --test`, or `bun test` | Node.js (built-in inspector) | Node.js |
| TypeScript | `typescript-language-server` + `typescript`, or TypeScript 7's `tsc --lsp` | Vitest, Jest, `node --test` (Node.js 23.6+), or `bun test` | Node.js | Node.js (23.6+ runs `.ts` directly) |
| WebAssembly (`.wat`, `.wast`) | `wat_server` (wasm-language-tools) | `wasmtime`, or Node.js + `wasm-tools`/`wat2wasm` | Node.js + `wasm-tools`/`wat2wasm`; lldb + `wasmtime` for modules with DWARF | `wasmtime`, or Node.js |

Optional, per feature:

* **Kotlin/Native** builds need the Kotlin Multiplatform Gradle plugin with a macOS target (`macosArm64` or `macosX64`) and the Xcode Command Line Tools. Gradle downloads the Kotlin/Native toolchain to `~/.konan` on the first build.
* **Compose previews** need a Gradle module with a JVM target and Compose Desktop on its runtime classpath (`compose.desktop.currentOs`), see [Compose previews](#12-compose-previews).
* **Inline annotations** use the language server: inlay hints need a server that supports `textDocument/inlayHint` (rust-analyzer and zls do).

CrossKit never installs anything and makes no network calls. Gradle and Cargo may download dependencies on their own, unless you pass `--offline` (see [Extra test arguments](#test-settings)).

Typical installs:

```sh
rustup component add rust-analyzer          # Rust language server
cargo install cargo-nextest                 # optional, faster Rust test runner
mise use -g zig@latest && mise install zls@<your zig version>
mise install github:fwcd/kotlin-language-server@latest
mise use -g java@temurin-21 gradle@latest
mise use -g node@lts cmake@latest          # JavaScript/TypeScript runtime, CMake/CTest for C++
mise use -g npm:typescript npm:typescript-language-server npm:vitest
mise use -g github:g-plane/wasm-language-tools wasmtime github:bytecodealliance/wasm-tools
xcode-select --install                      # lldb / lldb-dap if Xcode is not installed
```

## 3. Installation

1. Build CrossKit (see the README) and copy `CrossKit.app` to `/Applications`.
2. Open CrossKit.app once. A `</>` icon appears in the menu bar.
3. Open **System Settings › General › Login Items & Extensions › Xcode Source Editor** and turn on **CrossKit**. The **Open Extensions Settings…** button in CrossKit's settings window opens that pane.
4. Restart Xcode. The commands appear under **Editor › CrossKit**.
5. The first time you run a command, macOS asks whether CrossKit may control Xcode. Click **Allow**. CrossKit uses this to find the path of the file you are editing, which Xcode does not tell extensions. Without it, language features still work on a scratch copy, but tests and debugging need the real path.
6. Optional: bind keys in **Xcode › Settings › Key Bindings** by searching for "CrossKit". Suggested bindings:

| Command | Suggested key |
|---|---|
| Complete at Cursor | ⌃Space |
| Go to Definition | ⌃⌘J |
| Show Diagnostics | ⌃⌘D |
| Run Test at Cursor | ⌃⌘U |
| Debug File at Cursor | ⌃⌘R |
| Run File | ⌃⌥R |
| Build Project | ⌃⌥B |
| Run Tests with Coverage | ⌃⌥U |
| Show Preview | ⌃⌥P |
| Refresh Inline Annotations | ⌃⌥L |
| Clear Inline Annotations | ⌃⌥⇧L |

If the host app is not running when you use a command, the extension starts it in the background.

## 4. The host app

**Menu bar menu**

* The status of each language server, for example `Rust: running`.
* **Debugger…** opens the Debugger window.
* **Test Results…** opens the Test Results window.
* **Run…** opens the Run window.
* **Preview…** opens the Preview window (Compose previews and file inspections).
* **Inspect a File…** picks a C++, JavaScript, TypeScript, `.wat`, or binary `.wasm` file and shows its inspection.
* **Coverage…** opens the Coverage window.
* **Settings…** opens the settings window.
* **Quit CrossKit** stops every language server, test, and debug session, then quits.

**Settings window.** Everything is saved as soon as you change it; there is no Save button. See [Settings reference](#5-settings-reference).

**Test Results window**

* Lists the last 50 test runs, newest first.
* For a selected run, it shows the command, working directory, duration, exit status, and a table of tests with status, time, and failure output.
* Each test has a `file:line` button that opens the test in Xcode.
* The full runner output is shown underneath.

**Debugger window**

* Lists debug sessions.
* For a session controlled by CrossKit (lldb-dap, CodeLLDB, or the Node.js inspector), it has **Continue**, **Step Over**, **Step Into**, **Step Out**, **Pause**, and **Stop** buttons, plus the call stack, the local variables of the top frame, and the program's output.
* Click a stack frame to open that line in Xcode.
* The window comes to the front when a session starts or pauses at a breakpoint.

**Run window**

* Lists builds and program runs from **Build Project** and **Run File**, newest first, with their state (building, running, succeeded, failed, stopped).
* For a selected run, it shows the language, Kotlin target, project root, every command that was executed, the exit code, and the full output, updated live.
* **Stop** ends a build or a program that is still running, together with its child processes. **Clear Finished** removes finished entries.
* The window comes to the front when a build or run starts.

**Preview window**

* Shows the Compose previews of the last rendered file as cards: the image (on a checkerboard when the preview has no background), its name, its size in dp, and a `line N` button that opens the function in Xcode.
* The preview at the cursor is highlighted and scrolled into view.
* Toolbar: **Auto-refresh on save** (re-render when the file is saved), zoom (50%, 100%, 200%), **Log** (the Gradle and renderer output), and **Refresh** (⌘R).
* Failed previews show the error text instead of an image.

## 5. Settings reference

### General

| Setting | Default | Meaning |
|---|---|---|
| Bridge | – | Shows whether the host is listening for the extension. If it shows an error, quit and reopen CrossKit. |
| Stop idle servers after | 15 min | A language server unused for this long is shut down. Set it to `never` to keep servers running. |
| Test timeout | 15 min | A test run, debug build, Build Project, Run File build, or preview render that takes longer is stopped together with all of its child processes. |
| Re-detect Servers | – | Looks for servers, test tools, and debuggers again, for example after you install something. |

### Per language

| Setting | Meaning |
|---|---|
| Enabled | Turns the language off entirely. Commands then say the language is disabled. |
| Server | The language server binary. It is auto-detected unless you pick one from **Detected (n)** or with **Choose…**. **Use Auto-detect** returns to automatic detection. |
| Features | Checkboxes for Completion, Go to Definition, Find References, Diagnostics, Hover, Run Tests, Debugging, Build & Run, Code Lens, Inlay Hints, ErrorLens, and (Kotlin only) Compose Preview. A command whose feature is off answers "… is turned off". |
| Status | Live server state (running with pid and workspace, starting, restarting, stopped, error, or not found), the restart count, and the last error with the end of the server's stderr. Use **Restart** and **Stop** to control the server. |

<a id="test-settings"></a>**Test settings** (per language)

| Setting | Meaning |
|---|---|
| Test runner | **Auto-detect**, or force a runner: Zig `zig build test` / `zig test`; Rust `cargo test` / `cargo nextest`; Kotlin `Gradle wrapper (./gradlew test)` / `Gradle (gradle test)`; C++ `CMake + CTest`; JavaScript/TypeScript `Vitest` / `Jest` / `node:test` / `bun test`; WebAssembly `Wasmtime` / `Node.js harness` / `wasmtime wast`. |
| Test tools | The detected `zig`, `cargo`, `cargo-nextest`, `gradle`, and `java`, or "not found". Use **Choose…** to set a custom binary (it replaces zig, cargo, or gradle), and **Use Auto-detect** to undo that. |
| Extra test arguments | Appended to every test command, for example `--offline` for Gradle or `--release` for Cargo. For Kotlin, they are also passed to the Gradle calls used for debugging, Build Project, Run File, and Compose previews. |

**Debug settings** (per language)

| Setting | Meaning |
|---|---|
| Debugger | **Auto-detect**, or one of: Zig/Rust **lldb-dap (CrossKit Debugger window)**, **lldb in Terminal**, **CodeLLDB (CrossKit Debugger window)**; Kotlin **JDWP + jdb in Terminal**, **JDWP, wait for IDE to attach**; C++ like Zig/Rust; JavaScript/TypeScript **Node.js inspector (CrossKit Debugger window)**, **node inspect in Terminal**, **Node.js inspector, wait for Chrome DevTools / VS Code to attach**; WebAssembly the three Node.js choices plus lldb. Auto-detect picks lldb-dap when it is installed (otherwise lldb in Terminal) for Zig and Rust, and jdb for Kotlin. |
| Debugger tools | The detected `lldb-dap`, `lldb`, and `codelldb` (Zig/Rust), or `java` and `jdb` (Kotlin). **Choose …** sets a custom binary for the selected debugger. |
| JDWP port (Kotlin) | The port the debugged JVM listens on. The default is `5005`; `0` picks a free port each time. |

**Kotlin targets** (Kotlin only)

| Setting | Default | Meaning |
|---|---|---|
| Kotlin target | Auto (from the source set) | The target for Build Project, Run File, tests, and debugging in Kotlin Multiplatform modules: **Auto (from the source set)**, **JVM**, **Kotlin/Native (macosArm64)** (or `macosX64` on Intel Macs), or **Other target…** with a Gradle target name such as `desktop` or `linuxX64`. Files in a target's own source set always use that target. A launch configuration can override it per project. See [Kotlin targets](#11-kotlin-targets-jvm-and-native). |
| Native debugger | Auto-detect | The debugger for Kotlin/Native binaries: lldb-dap, lldb in Terminal, or CodeLLDB. Auto-detect works as for Zig and Rust. JVM targets use the **Debugger** setting above. |
| Keep the Gradle daemon running | On | When off, Build Project, Run File, tests, and previews run Gradle with `--no-daemon -Pkotlin.compiler.execution.strategy=in-process`, so no Gradle or Kotlin daemon stays behind. Debug sessions never use the daemon. |

### Inline annotations

| Setting | Default | Meaning |
|---|---|---|
| Code Lens › Reference counts | On | Show `◆ N references` above declarations. |
| Code Lens › Run, Debug and Preview actions | On | Show `▶ Run · ⚙ Debug` above `main`, `▶ Run Test · ⚙ Debug Test` above tests, and `◉ Preview` above Compose previews. An action is only shown when its feature is on for the language. |
| Inlay hints › Types | On | Inferred types, such as `total: i32`. |
| Inlay hints › Parameter names | On | Parameter names at call sites, such as `a: 1`. |
| Inlay hints › Other hints | Off | Everything else the server sends (chaining hints, closing-brace hints, …). |
| Inlay hints › Placement | Above the line | **Above the line** inserts a copy of the line with the hints in `‹…›`. **End of line** appends a short summary such as `» total: i32, a: 1`. |
| ErrorLens › Show | Errors and warnings | The lowest severity shown: errors; errors and warnings; errors, warnings and information; or everything, including hints. |
| ErrorLens › Show the diagnostic source | On | Append the source, such as `(rustc)` or `(zls)`. |

Each kind can also be turned off per language with the **Code Lens**, **Inlay Hints**, and **ErrorLens** feature checkboxes.

### Build, Run & Preview

| Setting | Default | Meaning |
|---|---|---|
| Run File waits for the program | 10 s | A program that finishes within this time shows its output in the alert. A longer one keeps running in the **Run** window. `0` returns as soon as it starts. |
| Compose preview scale | 2× (Retina) | Pixels per dp in rendered previews: 1×, 2×, or 3×. |
| Re-render the Preview window when its file is saved | On | Same as **Auto-refresh on save** in the Preview window. |

**Launch Configurations.** One entry per project you have built, run, or debugged. See [Launch configurations](#14-launch-configurations).

### Auto-detection

Servers, test tools, and debuggers are searched for in this order:

1. Tool-specific locations:
   * Rust: `~/.rustup/toolchains/*/bin` for rust-analyzer and cargo.
   * lldb and lldb-dap: the selected Xcode (`xcode-select -p`), `/Applications/Xcode.app`, the Command Line Tools, then Homebrew LLVM.
   * CodeLLDB: `~/.vscode/extensions/vadimcn.vscode-lldb-*/adapter/codelldb`, plus the same path under `~/.cursor`, `~/.vscode-insiders`, and `~/.windsurf`.
2. mise installs (newest version first). `MISE_DATA_DIR` is respected.
3. `~/.cargo/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, and SDKMAN.
4. mise shims, but only if the tool is really installed.
5. `PATH`.

The JDK comes from `JAVA_HOME`, then mise (21 is preferred, then 17), then `/Library/Java/JavaVirtualMachines`.

## 6. Editor commands

All commands are under **Editor › CrossKit**.

| Command | What it does |
|---|---|
| Complete at Cursor | Replaces the identifier before the cursor with the best completion. |
| List Completions | Inserts up to 40 ranked candidates as comment lines above the cursor. |
| Go to Definition | Selects the definition. If it is in another file, Xcode opens that file at the line. |
| Find References | Inserts a comment block listing every reference as `path:line:col` with a preview. |
| Show Hover Info | Inserts the type, signature, and documentation of the symbol under the cursor as comments. |
| Show Diagnostics | Inserts `// [CrossKit] error: …` above each line with an error or warning. |
| Clear CrossKit Annotations | Removes every `// [CrossKit]` (or `;; [CrossKit]`) line in the file, and every `  // [CrossKit] …` segment at the end of a line. |
| Show Test Markers | Inserts `// [CrossKit] ▶ test <name>` above every test in the file. |
| Run Tests in File | Runs all tests in the file, marks each one `✓` or `✗`, and shows a summary. |
| Run Test at Cursor | Runs only the test that contains the cursor. |
| Debug File at Cursor | Builds the program and starts the debugger, with a breakpoint on the cursor line. |
| Debug Test at Cursor | Builds the test that contains the cursor and debugs only that test, with a breakpoint on the cursor line. |
| Build Project | Builds the project (or the loose file) for the current language and Kotlin target, and shows the result. See [Build and run](#10-build-and-run). |
| Run File | Builds and runs the program of the current file (its `main`), shows the output in an alert, and keeps longer runs in the Run window. |
| Run Tests with Coverage | Runs the tests of the file (or the test at the cursor) with coverage on, marks the tests, adds `░ not covered: lines a–b` markers above uncovered code of the current file, and opens the Coverage window. C++, JavaScript, TypeScript, and WebAssembly. |
| Show Preview | Kotlin: renders every `@Preview` in the file and opens the Preview window, focused on the preview at the cursor. C++, JavaScript, TypeScript, WebAssembly: shows an inspection of the file (assembly, symbols, emitted JavaScript, WAT, …) in the Preview window. |
| Show Code Lenses | Inserts or refreshes `// [CrossKit] ◆ …` lines above declarations: reference counts and Run/Debug/Preview actions. |
| Show Inlay Hints | Inserts or refreshes the server's inlay hints as `// [CrossKit] » …` comments, above the line or at its end. |
| Show ErrorLens Diagnostics | Appends the most severe diagnostic of each line at its end: `  // [CrossKit] ✖ error: …`. |
| Refresh Inline Annotations | Refreshes every enabled kind (code lenses, inlay hints, ErrorLens) in one go. |
| Clear Inline Annotations | Removes code lenses, inlay hints, and ErrorLens comments, and leaves other `// [CrossKit]` lines alone. |
| Open CrossKit Settings | Brings up the host app. |

Every edit is a normal editor change, so **Undo** reverts it.

## 7. Language features

* **Servers start lazily.** The first command for a language starts its server for the workspace root.
  * The root is the nearest folder with `Cargo.toml`/`rust-project.json` (Rust), `build.zig`/`zls.json` (Zig), `settings.gradle(.kts)`/`build.gradle(.kts)`/`pom.xml` (Kotlin), `compile_commands.json`/`compile_flags.txt`/`.clangd`/`CMakeLists.txt`/`meson.build` (C++), `package.json`/`tsconfig.json`/`jsconfig.json`/`deno.json` (JavaScript, TypeScript), or `wasm-project.json`/`package.json`/`Cargo.toml`/`build.zig` (WebAssembly).
  * If there is none, the nearest `.git` folder is used, and otherwise the file's folder.
  * Each language and root pair has its own server.
* **Warm-up.** Servers need time to index, Kotlin especially (up to a minute). Empty results in the first minute are retried automatically.
* **Crash handling.**
  * A crashed server restarts after 1, 2, 4, 8, then 16 seconds.
  * After 5 crashes within 5 minutes it stays stopped, and the error appears under Status.
  * Click **Restart** to try again.
* **Completion** inserts plain text. Snippet placeholders such as `${1:arg}` are removed.
* **Diagnostics** are whatever the server has published for the current buffer content. Run the command again after editing.

## 8. Running tests

### Quick start

1. Open a test file in Xcode and **save it**, because tests run against the saved file.
2. Choose **Editor › CrossKit › Run Tests in File**, or put the cursor inside a test and choose **Run Test at Cursor**.
3. A summary alert appears, for example:
   ```
   ✗ Rust · cargo nextest: 1 passed, 1 failed in 1.7s
   ✗ tests::fails_on_purpose:16
   Details: CrossKit › Test Results
   ```
4. Each test gets a marker above it (above its `#[test]` or `@Test` line):
   ```rust
   // [CrossKit] ✓ passed 0.010s
   #[test]
   fn adds() { … }

   // [CrossKit] ✗ failed — assertion `left == right` failed: math is hard
   #[test]
   fn fails_on_purpose() { … }
   ```
   Running again replaces the old markers. **Clear CrossKit Annotations** removes them.
5. Open **CrossKit › Test Results** for the full output, timings, and clickable `file:line` links.

### How tests are found

| Language | Recognized tests |
|---|---|
| Zig | `test "name" { … }`, `test identifier { … }`, and unnamed `test { … }` blocks. |
| Rust | Functions with `#[test]`, `#[tokio::test]`, `#[rstest]`, `#[test_case]`, `#[wasm_bindgen_test]`, or `#[quickcheck]`, inside any nesting of inline `mod`s. The module path comes from the file's location in the crate (`src/a/b.rs` → `a::b::…`). If rust-analyzer is enabled and running, its `experimental/runnables` result is used instead, which gives exact test paths and Cargo arguments. |
| Kotlin | Functions annotated `@Test`, `@ParameterizedTest`, `@RepeatedTest`, `@TestFactory`, or `@TestTemplate` (JUnit 5 or `kotlin.test`), including `@Nested` inner classes. Test ids use the package and class: `demo.CalcTest.adds`, `demo.CalcTest$Inner.case`. |

"At cursor" means the nearest test that starts at or above the cursor line.

### Which runner runs

| Language | Auto-detect picks | Command for the whole file | Command for one test |
|---|---|---|---|
| Zig | `zig build test` if the project has `build.zig` | `zig build test --summary all` (runs the project's test step) | Same as the whole file. The project's test step decides what runs, and results are mapped to this file's tests. |
| Zig | `zig test` for a loose file | `zig test <file>` | `zig test <file> --test-filter "<name>"` |
| Rust | `cargo nextest` if `cargo-nextest` is installed | `cargo nextest run --no-fail-fast <target> <module>::` | `cargo nextest run <target> -E 'test(=<path>)'` |
| Rust | otherwise `cargo test` | `cargo test <target> -- <module>::` | `cargo test <target> -- <path> --exact` |
| Kotlin | `./gradlew test` if the project has an executable wrapper | `gradlew :module:test --tests <Class>` | `gradlew :module:test --tests <Class.method>` |
| Kotlin | otherwise `gradle test` | same, with `gradle` | same, with `gradle` |

* `<target>` is chosen from the file's location: `tests/<name>.rs` → `--test <name>`, `src/bin/<name>.rs` → `--bin <name>`, `src/main.rs` (or any file of a crate without `src/lib.rs`) → `--bins`, other files → `--lib`.
* Gradle results are read from the JUnit XML reports in `<module>/build/test-results/test`. Only reports written during this run are used.
* Commands run in the project root.
  * `PATH` is extended with the toolchain's folder, `~/.cargo/bin`, mise shims, and Homebrew.
  * Kotlin also gets `JAVA_HOME`.
  * Colors are turned off.
* Gradle uses its normal daemon for test runs, which makes repeated runs faster.

### When something is missing

CrossKit says what to install or which setting to change. For example:

* `zig was not found. Install Zig (e.g. mise use -g zig@latest) or choose the zig binary in CrossKit settings.`
* `cargo-nextest was not found. Install it (cargo install cargo-nextest …) or pick "cargo test" in CrossKit settings.`
* `No executable ./gradlew in /path. Choose "Gradle" as the runner or add the wrapper.`
* `No tests found in main.zig.` / `No test function at or above the cursor.`
* `Save the file inside a project before running tests (CrossKit could not determine its path).`

If the buffer has unsaved changes, the summary warns you: "tests ran against the saved file".

## 9. Debugging

### Quick start (Zig or Rust)

1. Save the file. Put the cursor on the line where you want to stop.
2. Choose **Editor › CrossKit › Debug File at Cursor**. To debug a single test, put the cursor inside it and choose **Debug Test at Cursor**.
3. CrossKit builds the program. The alert confirms the start, for example: `▶ Debugging main.zig with lldb-dap; breakpoint at main.zig:5. Controls are in CrossKit › Debugger.`
4. The **Debugger** window opens. When the breakpoint is hit, you see the call stack and local variables. Use **Continue**, **Step Over**, **Step Into**, **Step Out**, **Pause**, and **Stop**.
5. When the program exits, the session shows its exit code. **Stop** ends the session at any time and kills the program and the debugger.

With **lldb in Terminal**, a Terminal window opens running `lldb`. The program is already launched with your breakpoint set, and you continue with normal lldb commands (`continue`, `next`, `step`, `finish`, `frame variable`, `bt`, `breakpoint set …`).

### Quick start (Kotlin)

1. Open a file in a Gradle project. Put the cursor on a line in `main` (or anything `main` calls) and choose **Debug File at Cursor**. For a JUnit test, put the cursor in the test and choose **Debug Test at Cursor**.
2. CrossKit compiles the project with Gradle and starts the JVM with a JDWP agent that **waits for a debugger** (`suspend=y`) on `127.0.0.1:<port>`.
3. What happens next depends on the debugger setting:
   * **JDWP + jdb in Terminal** (default): a Terminal window opens with `jdb` attached. The breakpoint (`stop at demo.MainKt:5`) is already set and the program is running. Use jdb commands such as `locals`, `print x`, `where`, `next`, `step`, `cont`, and `clear`.
   * **JDWP, wait for IDE to attach**: attach from IntelliJ IDEA (**Run › Edit Configurations › + › Remote JVM Debug**, host `127.0.0.1`, the port shown) or from VS Code. Then set breakpoints there.
4. The Debugger window shows the JDWP address, a **Copy** button for the `jdb -attach` command, the program's output, and **Stop**.

### What gets built and launched

| Language | Debug File at Cursor | Debug Test at Cursor |
|---|---|---|
| Zig, loose file | `zig build-exe <file> -femit-bin=<cache>/<name>`, then that binary | `zig test <file> --test-filter "<name>" --test-no-exec -femit-bin=<cache>/<name>-test`, then that test binary |
| Zig, `build.zig` project | `zig build install` (when **Build before launching** is on), then the executable in `zig-out/bin` named like the project folder, or like the file, or the first one found | same as a loose file (compiles only this file's tests) |
| Rust | `cargo build --bins` (or `--bin <name>` for `src/bin/<name>.rs`); the executable comes from Cargo's JSON output | `cargo test --no-run <target>`, then the test binary with `<test path> --exact --nocapture --test-threads=1` |
| Kotlin | `gradle :module:crossKitClasspath` (compiles and prints the runtime classpath), then `java -agentlib:jdwp=… -cp <classpath> <MainClass>` | `gradle :module:test --tests <Class.method> --rerun` with the JDWP agent added to the test JVM |

* The file must declare `main` for **Debug File at Cursor**: `pub fn main` in Zig, `fn main` in Rust, top-level `fun main` in Kotlin.
* In a Rust library file of a crate that also has a binary, **Debug File at Cursor** builds and launches the binary and keeps the breakpoint in your library file.
* Kotlin main class: `<package>.<FileName>Kt`, or the name from `@file:JvmName("…")`. The breakpoint class is the innermost `class` or `object` around the cursor, or that file class.
* Kotlin needs Gradle (wrapper or installed). CrossKit adds a small init script (`crosskit-init.gradle` in its cache folder) that provides the classpath task and the test JVM's JDWP option. It does not change your build files.
* Debug builds pass `--no-daemon` and `-Pkotlin.compiler.execution.strategy=in-process` to Gradle, so no Gradle or Kotlin daemon is left running after the session.
* Builds use the **Test timeout** and run in the project root. If a build fails, the alert shows the command and the last 25 lines of output.

### Breakpoints

* The breakpoint goes on the cursor line of the saved file. Paths are resolved fully (for example `/private/tmp/…` rather than `/tmp/…`), so they match the debug info.
* If that line has no code, such as a blank line, a comment, or a Rust tail expression, lldb-dap sessions try the next four lines. The Output pane says where the breakpoint ended up ("resolved" or "pending").
* Lines with several machine locations (for example inside `assert_eq!`) may stop more than once. Press **Continue** again.
* If the buffer differs from the saved file only by `// [CrossKit]` lines, the cursor line is mapped to the saved file automatically. Any other unsaved change gives a warning that lines may not match.

### Choosing a debugger

| Debugger | Controlled by | Good for |
|---|---|---|
| lldb-dap | CrossKit's Debugger window | Quick inspection: stack, locals, and stepping without leaving the Mac UI. |
| lldb in Terminal | You, in Terminal | Everything lldb can do: watchpoints, expressions, conditional breakpoints. |
| CodeLLDB | CrossKit's Debugger window | Rust-aware value formatting. It is started over stdio, which has not been tested with every CodeLLDB version. |
| JDWP + jdb | You, in Terminal | Kotlin/JVM without an IDE. |
| JDWP, wait for IDE | Your IDE | Full Kotlin debugging in IntelliJ IDEA. |

### When something is missing

* `lldb-dap was not found. Install Xcode or the Command Line Tools (xcode-select --install), or choose the binary in CrossKit settings.`
* `codelldb was not found. Install the CodeLLDB extension (vadimcn.vscode-lldb) … or pick lldb-dap.`
* `java was not found. Install a JDK 17 or 21 (e.g. mise use -g java@temurin-21) or choose java in CrossKit settings.`
* `main.zig has no main function. Open the file with main, or use Debug Test at Cursor inside a test.`
* `Debugging Kotlin needs a Gradle project …`
* `Build failed: <command>` followed by the compiler output.

### Cleanup

* Each session runs its debugger, JVM, or Gradle process in its own process group.
* **Stop**, a program exit, or quitting CrossKit ends the session. CrossKit asks the debugger to terminate the program, then kills the process group and any debuggee process that is still alive.
* lldb and jdb sessions in Terminal belong to Terminal. Close them there.

## 10. Build and run

### Quick start

1. Open a file that declares `main` (`pub fn main` in Zig, `fn main` in Rust, top-level `fun main` in Kotlin) and save it.
2. Choose **Editor › CrossKit › Run File**. CrossKit builds the program, runs it, and shows the result in an alert:

   ```
   ✓ Run succeeded: main.rs (1.4s)
   result 42
   ```

3. To only compile, choose **Build Project**. The alert says `✓ Build succeeded: …` or shows the command and the last 25 lines of compiler output.

Every build and run also appears in the **Run** window (menu bar › **Run…**), with the commands, the full output, and a **Stop** button.

### What gets built and run

| Language | Build Project | Run File |
|---|---|---|
| Zig, loose file | `zig build-exe <file>` into CrossKit's cache, or `zig build-obj <file>` for a file without `main` | the binary from `zig build-exe` |
| Zig, `build.zig` project | `zig build install` | `zig build install`, then the executable in `zig-out/bin` (named like the project folder, or like the file, or the first one) |
| Rust | `cargo build` (every target of the crate) | `cargo build --bin <name>` (or `--bins` from a library file), then the executable from Cargo's JSON output |
| Kotlin, JVM target | `gradle :module:<target>MainClasses` | `gradle :module:crossKitClasspath`, then `java -cp <classpath> <MainClass>` |
| Kotlin, Native target | `gradle :module:linkDebugExecutable<Target>` (or `compileKotlin<Target>` when the module declares no executable) | the same link task, then the `.kexe` in `build/bin/<target>/debugExecutable` |

* Run File uses the project's launch configuration: **Arguments**, **Environment**, **Working directory**, and, if set, **Program** / **Main class / executable**. See [Launch configurations](#14-launch-configurations).
* **Run File waits for the program** (default 10 s): a program that finishes in time shows its exit status and the end of its output in the alert. A longer one, such as a server, keeps running; the alert says `▶ … is still running` and the Run window shows its live output. Stop it there.
* A program that exits with a non-zero code is reported as `✗ <file> exited with code N`, followed by its output.
* Builds use the **Test timeout**, and every build and program runs in its own process group. Stopping a run, or quitting CrossKit, kills the whole group.
* Run File and Build Project use the saved file. Save before running.

## 11. Kotlin targets: JVM and Native

CrossKit reads the targets of a Kotlin Multiplatform module from its `build.gradle(.kts)`, for example:

```kotlin
plugins { kotlin("multiplatform") version "2.4.21" }

kotlin {
    jvm()
    jvm("desktop")
    macosArm64 {
        binaries { executable { entryPoint = "demo.main" } }
    }
    linuxX64()
}
```

A plain Kotlin/JVM module (`kotlin("jvm")`) has a single JVM target, and everything works as before.

### Which target is used

For every Kotlin command that builds, runs, tests, or debugs, CrossKit picks one target:

1. **The source set of the file.** A file in `src/jvmMain`, `src/desktopTest`, `src/macosArm64Main`, … always uses that target. A file in `nativeMain`, `appleMain`, `macosMain`, or another native-only source set uses the host's macOS target.
2. **The launch configuration's Kotlin target**, if set (`jvm`, `native`, or a target name).
3. **The Kotlin target setting**: **Auto (from the source set)**, **JVM**, **Kotlin/Native (macosArm64)**, or **Other target…** with a name.
4. **Auto** picks the first JVM target, otherwise the host's macOS target, otherwise the first target.

Shared code in `commonMain` and `commonTest` therefore runs on the JVM by default and on Kotlin/Native when you choose it. The alert and the window titles name the target, for example `Main.kt · Native macosArm64` or `Main.kt · JVM (desktop)`.

### Per target

| | JVM target | Native target (host macOS) | Other targets (iOS, Linux, JS, Wasm, …) |
|---|---|---|---|
| Build Project | `<target>MainClasses` | `linkDebugExecutable<Target>` | `linkDebugExecutable<Target>` for native targets, `<target>MainClasses` otherwise |
| Run File | `java -cp …` | the linked `.kexe` | not supported: "does not run on this Mac" |
| Run Tests / Run Test at Cursor | `<target>Test` (`test` in a JVM-only module) with `--tests` filters | `<target>Test` (for example `macosArm64Test`) | `<target>Test`, if Gradle can run it on this Mac |
| Debug File at Cursor | JDWP + jdb, or wait for your IDE ([Debugging](#9-debugging)) | `linkDebugExecutable<Target>`, then the `.kexe` under the **Native debugger** (lldb-dap by default) | not supported |
| Debug Test at Cursor | the test task with the JDWP agent | `linkDebugTest<Target>`, then `test.kexe --ktest_filter=<package.Class.method>` | not supported |

Kotlin/Native details:

* The executable needs `binaries { executable { … } }` in the target. Its `entryPoint` decides which `main` runs, whatever file you start from.
* Debugging uses the same Debugger window as Zig and Rust: breakpoint at the cursor, stack, locals (such as `x = 20`), stepping. When the Kotlin/Native toolchain in `~/.konan` has `konan_lldb.py`, CrossKit loads it into lldb for nicer Kotlin values.
* Test reports are read from `build/test-results/<target>Test`, so test markers and the Test Results window work for every target.

## 12. Compose previews

CrossKit renders Compose Multiplatform `@Preview` functions to images, like Xcode's SwiftUI previews.

### Quick start

1. Put the cursor in a preview function and save the file:

   ```kotlin
   @Preview(widthDp = 120, heightDp = 60, showBackground = true)
   @Composable
   fun RedBoxPreview() {
       Box(Modifier.size(40.dp).background(Color.Red))
   }
   ```

2. Choose **Editor › CrossKit › Show Preview**. The alert says `◉ Rendered 3 of 3 previews in Greeting.kt (4.1s)`, and the **Preview** window opens with every preview of the file, the one at the cursor highlighted.
3. Edit and save. With **Auto-refresh on save** on, the window renders again by itself. Otherwise click **Refresh** (⌘R) or run the command again.

### What is found

* Functions annotated with `@Preview` from `androidx.compose.ui.tooling.preview` or `androidx.compose.desktop.ui.tooling.preview`, written with or without the package, including annotations that span several lines and several `@Preview` annotations on one function.
* Top-level functions (in the file class, such as `demo.GreetingKt`) and functions inside an `object`.
* Arguments used: `name`, `widthDp`, `heightDp`, `showBackground`, `backgroundColor`. Other arguments are ignored.
* Annotation classes (multipreview), properties, and functions with parameters are skipped.

### How it renders

1. Gradle compiles the module's JVM target and prints its runtime classpath (`crossKitClasspath`, from CrossKit's init script; in a Multiplatform module with `-Pcrosskit.target=<jvm target>`). A JVM target is always used, even when the **Kotlin target** setting is Native.
2. A small renderer (`CrossKitPreviewRenderer`, compiled once with your JDK's `javac`) runs headless with that classpath. It draws each preview with Compose Desktop's `ImageComposeScene` at the **Compose preview scale** and writes PNG files.
3. Previews without a size are measured; `widthDp`/`heightDp` fix the size. `showBackground` paints white or `backgroundColor`; otherwise the background is transparent.

Requirements: a Gradle module with a JVM target and Compose Desktop on its runtime classpath, for example:

```kotlin
kotlin {
    jvm("desktop")
    sourceSets {
        commonMain.dependencies {
            implementation("org.jetbrains.compose.runtime:runtime:1.12.2")
            implementation("org.jetbrains.compose.foundation:foundation:1.12.2")
            implementation("org.jetbrains.compose.ui:ui-tooling-preview:1.12.2")
        }
        val desktopMain by getting { dependencies { implementation(compose.desktop.currentOs) } }
    }
}
```

A preview that throws is shown as an error card with the exception; the others still render. The renderer's and Gradle's output is under **Log**.

## 13. Inline annotations: Code Lens, inlay hints, ErrorLens

Xcode extensions cannot draw inside the editor, so CrossKit approximates three popular inline features with `// [CrossKit]` comments:

```rust
// [CrossKit] ◆ 1 reference
fn add(a: i32, b: i32) -> i32 {
    a + b
}

// [CrossKit] ◆ 0 references · ▶ Run · ⚙ Debug
fn main() {
    let total = add(1, 2);  // [CrossKit] » total: i32, a: 1, b: 2
    let label: i32 = "no";  // [CrossKit] ✖ error: expected i32, found &'static str (rust-analyzer)
}
```

| Command | What it inserts |
|---|---|
| Show Code Lenses | Above each function, method, class, struct, enum, interface, and constructor the server reports: `◆ N references`, plus actions: `▶ Run · ⚙ Debug` above `main`, `▶ Run Test · ⚙ Debug Test` above tests, `◉ Preview` above Compose previews. The lens goes above attributes and annotations (`#[test]`, `@Preview`). |
| Show Inlay Hints | The server's inlay hints (types and parameter names by default). **Above the line**: a copy of the line with the hints in `‹…›`. **End of line**: a short summary appended to the line. |
| Show ErrorLens Diagnostics | At the end of each line with a diagnostic, its most severe message with `✖` (error), `⚠` (warning), `ℹ` (information), or `∙` (hint), and `(+N more)` when the line has several. |
| Refresh Inline Annotations | All enabled kinds at once. |
| Clear Inline Annotations | Removes all three kinds. |

* Each command first removes the annotations of its own kind, then inserts fresh ones, so you can run it as often as you like. The other kinds stay where they are.
* The text sent to the language server never contains CrossKit annotations, so positions stay right.
* When a line ends inside a multi-line string or block comment (Kotlin `"""`, Rust strings and raw strings, Zig `\\` lines, `/* … */`), appending a comment would change the code, so the annotation goes above that line instead.
* The cursor stays on the same code line.
* Reference counts use `textDocument/references` for up to 150 declarations per file; on very large files the rest get no count. Lens actions are labels: run them with **Run File**, **Debug File at Cursor**, **Run Test at Cursor**, **Debug Test at Cursor**, or **Show Preview**.
* Settings: see [Inline annotations](#inline-annotations) for what each kind shows, and the per-language **Code Lens**, **Inlay Hints**, and **ErrorLens** feature checkboxes to turn a kind off. A command for a kind that is turned off answers "… is turned off".

## 14. Launch configurations

The first time you build, run, or debug a project, CrossKit creates a **launch configuration** for that language and project root and saves it. Edit it in **Settings › Launch Configurations**; changes are saved immediately.

| Field | Meaning |
|---|---|
| Program (Zig/Rust) | Leave empty to let CrossKit build and find the program. If set, CrossKit launches this executable as is, without building. |
| Main class / executable (Kotlin) | Leave empty for the file's class (e.g. `demo.MainKt`) on JVM targets, or the linked `.kexe` on Kotlin/Native. If set, this class (JVM) or executable (Native) is launched instead. |
| Kotlin target (Kotlin) | Empty uses the **Kotlin target** setting. Otherwise `jvm`, `native`, or a Gradle target name such as `desktop` or `macosArm64`. Used by Build Project, Run File, tests, and debugging in this project. |
| Arguments | Command-line arguments for **Run File** and **Debug File at Cursor**, as you would type them in a shell: `--port 8080 "two words"`. |
| Environment | `KEY=VALUE`, one per line. Lines starting with `#` are ignored. Applied to the program you run or debug. |
| Working directory | Empty means the project root. |
| Test binary arguments | Extra arguments for the test binary in **Debug Test at Cursor**, for example `--include-ignored` (Rust). For Kotlin they are only used by Kotlin/Native test binaries. |
| Build before launching | For Zig projects with `build.zig`: run `zig build install` first. Loose Zig files, Cargo, and Gradle projects are always built, because the build produces the program path or classpath. |
| Delete | Removes the configuration. A fresh default is created the next time you debug the project. |

Configurations live in CrossKit's shared settings, not in your project, so nothing is added to your repository.

## 15. Annotations and markers

Every line CrossKit inserts is a `//` comment that starts with `// [CrossKit]`. This works in Kotlin, Zig, and Rust.

| Example | Source |
|---|---|
| `// [CrossKit] error: expected expression, found ';' [9:18] (zls)` | Show Diagnostics |
| `// [CrossKit] completions for "comp" (3):` then `// [CrossKit]   compute_answer — fn(i32) -> i32` | List Completions |
| `// [CrossKit] 2 reference(s):` then `// [CrossKit]   src/lib.rs:12:5  let x = compute(1);` | Find References |
| `// [CrossKit] definition:` then `// [CrossKit]   src/util.rs:3:8  pub fn compute(…)` | Go to Definition (other file) |
| `// [CrossKit] ▶ test add works — Editor › CrossKit › Run Test at Cursor` | Show Test Markers |
| `// [CrossKit] ✓ passed 0.010s` / `✗ failed — reason` / `○ skipped` | Run Tests |
| `// [CrossKit] ◆ 2 references · ▶ Run · ⚙ Debug` (above a declaration) | Show Code Lenses |
| `// [CrossKit] » let total‹: i32› = add(‹a:› 1, ‹b:› 2);` (above the line) | Show Inlay Hints, placement **Above the line** |
| `let total = add(1, 2);  // [CrossKit] » total: i32, a: 1, b: 2` | Show Inlay Hints, placement **End of line** |
| `let s: i32 = "no";  // [CrossKit] ✖ error: mismatched types (rustc) (+1 more)` | Show ErrorLens Diagnostics |

* Test markers (`▶ ✓ ✗ ○`) are replaced on every run.
* Inline annotations (`◆ » ✖ ⚠ ℹ ∙`) are replaced by every Show/Refresh command of the same kind, so running a command twice never duplicates them. **Clear Inline Annotations** removes only these.
* Other annotations stay until **Clear CrossKit Annotations**.
* Debug, Build Project, Run File, and Show Preview never edit the buffer. Run Tests with Coverage edits only CrossKit marker lines.

## 16. Where CrossKit keeps things

| What | Where |
|---|---|
| Settings, server status, launch configurations | `UserDefaults` suite `group.dev.pyrlyn.CrossKit` (App Group shared by the app and the extension) |
| Scratch copies of unsaved buffers | `~/Library/Caches/CrossKit/Scratch` |
| Debug builds of loose files, Gradle init script, session scripts (`lldb-commands`, `.jdbrc`, `CrossKit Debug.command`) | `~/Library/Caches/CrossKit/Debug` |
| Compose preview renderer (compiled once per JDK) and rendered PNGs (`renders/<file>-<hash>/…`, only the latest render of each file is kept) | `~/Library/Caches/CrossKit/Preview` |
| Kotlin/Native binaries | Your project's `build/bin/<target>/debugExecutable` and `debugTest` (written by Gradle) |
| Logs | Console.app, process `CrossKit` |

You can delete the cache folders at any time.

## 17. Troubleshooting

| Symptom | What to do |
|---|---|
| The CrossKit menu is missing in Xcode | Enable the extension in System Settings (step 3 of Installation) and restart Xcode. Make sure only one copy of CrossKit.app exists (for example, remove old builds from DerivedData). |
| "CrossKit host app is not reachable" or "did not answer in time" | Open CrossKit.app. If **Bridge** shows an error, quit CrossKit and open it again. A long test run or debug build also blocks other commands until it finishes. |
| Results refer to a `Scratch` folder | Automation permission was denied. Allow it under **System Settings › Privacy & Security › Automation › CrossKit › Xcode**. |
| Server shows **Not found** | Install it (see the hint under Server), or **Choose…** its binary, then click **Re-detect Servers**. |
| Kotlin results are empty at first | kotlin-language-server is still indexing. Wait a minute and try again. |
| zls reports a version mismatch | Install the zls version that matches `zig version`. |
| Gradle downloads or fails offline | Add `--offline` to **Extra test arguments** once dependencies are cached, or let it download once. |
| A breakpoint never hits | Save the file. Make sure the line has code, and check the Output pane for "pending". For `build.zig` projects, make sure the debugged executable is the one that contains the file. |
| Debugger shows no variables | The top frame may be in a system library. Use **Step Out** or **Continue** to a breakpoint in your code. |
| Kotlin JVM "waiting for debugger" forever | Attach with the command shown in the Debugger window, or click **Stop**. If the port is taken, set **JDWP port** to `0`. |
| "… declares no executable" (Kotlin/Native) | Add `binaries { executable { entryPoint = "your.package.main" } }` to the native target in `build.gradle.kts`. |
| "Target … does not run on this Mac" | Only the host's macOS target can run or be debugged. Choose JVM or Kotlin/Native for this Mac, or use Build Project, which builds any target. |
| Kotlin/Native build takes minutes the first time | Gradle downloads and warms up the Kotlin/Native toolchain in `~/.konan`. Later builds are much faster, especially with the Gradle daemon on. |
| "Compose previews need Compose Desktop" | Add `implementation(compose.desktop.currentOs)` to the JVM (desktop) source set. |
| A preview shows an error card | Open **Log** in the Preview window. Previews with parameters (`@PreviewParameter`) and previews that need Android resources cannot be rendered. |
| The preview shows old code | Previews render the saved file. Save, then **Refresh** (⌘R), or keep **Auto-refresh on save** on. |
| Show Inlay Hints says the server does not provide inlay hints | kotlin-language-server versions without `inlayHintProvider` cannot show them. Use Code Lens and ErrorLens instead. |
| No code lenses or hints right after opening a project | The server is still indexing. Run **Refresh Inline Annotations** again after a moment. |
| Gradle or Kotlin daemons stay running | Turn off **Keep the Gradle daemon running**, or run `gradle --stop`. |

## 18. Known limitations

* **No inline UI.** There are no pop-ups, squiggles, gutter icons, or live updates. Everything runs when you invoke a command (an XcodeKit limitation). Code lenses, inlay hints, and ErrorLens are approximated with `// [CrossKit]` comments that do not follow your edits until you refresh them, and lens actions are labels, not buttons: use the matching command (Run File, Debug Test at Cursor, …).
* **Breakpoints only from the cursor.** Each debug command sets one breakpoint, at the cursor line. Add more in lldb or jdb, or in your IDE for JDWP.
* **One request at a time.** The bridge handles requests one after another, so a long test run delays other commands until it finishes.
* **`zig build test`** runs the project's whole test step. Debug Test at Cursor compiles the file with `zig test`, which works when the file's imports resolve without `build.zig` modules.
* **Kotlin debugging** needs Gradle. Maven-only and loose `.kt` files are not supported for debugging, tests, Build & Run, or previews.
* **Kotlin targets** are read from `build.gradle(.kts)` with a simple parser. Targets created in convention plugins or with loops are not seen; name them in the **Kotlin target** setting or the launch configuration. Only the host macOS target can run; iOS, Linux, Windows, JS, and Wasm targets can only be built.
* **Kotlin/Native** programs use the build script's `entryPoint`, not the file you run from. Variables of Kotlin types are shown with lldb's raw formatting; CrossKit loads `konan_lldb.py` when the toolchain has it.
* **Compose previews** render on the desktop JVM, without Android resources, `@PreviewParameter`, multipreview annotations, interaction, or animation. The output depends on the Compose Desktop version of your project.
* **C++, JavaScript, TypeScript, WebAssembly:** see [Limitations](#limitations-of-the-new-languages) in chapter 19.
* **CodeLLDB** support has not been tested in CI. lldb-dap from Xcode is the tested path, for Zig, Rust, and Kotlin/Native.

## 19. C++, JavaScript, TypeScript, and WebAssembly

These four languages get the same commands as Zig and Rust: completion and the other language features, tests with gutter-style markers, debugging, Build Project and Run File. They also get two features of their own: **code coverage** and **file inspections** (the Preview window). CrossKit installs nothing. It finds the tools at runtime and, when one is missing, says what to install. The suggested installs use mise or the tools' own installers; Homebrew is never required.

### Setup

| Tool | Used for | Install |
|---|---|---|
| `clangd`, `clang++`, `lldb-dap`, `llvm-cov`, `llvm-profdata`, `nm`, `c++filt` | C++ language server, builds, debugging, coverage, inspections | Xcode or the Command Line Tools (`xcode-select --install`). `mise use -g llvm` also works. |
| `cmake`, `ctest` | C++ tests and CMake projects | `mise use -g cmake@latest` |
| `node` | JavaScript/TypeScript runs, tests, debugging; the WebAssembly harness | `mise use -g node@lts` (23.6 or newer runs TypeScript without a build step) |
| `typescript-language-server`, `typescript` | JS/TS language server, type checks, emitted JavaScript | `mise use -g npm:typescript-language-server npm:typescript`, or `npm install -D typescript` in the project. TypeScript 7 (`tsc --lsp`) is used when it is the only server found. |
| `vitest`, `jest` | JS/TS tests | `npm install -D vitest` / `npm install -D jest` in the project (preferred), or `mise use -g npm:vitest` / `npm:jest`. Vitest coverage also needs `npm install -D @vitest/coverage-v8`. |
| `bun` | `bun test` | `mise use -g bun` |
| `wat_server` | WebAssembly language server | `mise use -g github:g-plane/wasm-language-tools` (or `cargo install wasm-language-tools`) |
| `wasmtime` | WebAssembly tests, Run File, `.wast` scripts | `mise use -g wasmtime` |
| `wasm-tools` or `wat2wasm`/`wasm2wat` (wabt) | Converting `.wat` to `.wasm` for Node.js, the WAT and validation tabs | `mise use -g github:bytecodealliance/wasm-tools`, or wabt from its GitHub releases |

Tools are searched for in the order of [Auto-detection](#auto-detection). Node.js tools are looked up in the project's `node_modules/.bin` first. **Re-detect Servers** in Settings refreshes the list, and the **Test tools** and **Debugger tools** rows show what was found.

### Language features

* **C++** uses clangd. Point it at your flags with `compile_commands.json` (CMake: `-DCMAKE_EXPORT_COMPILE_COMMANDS=ON`) or a `compile_flags.txt`. Headers with `.hpp`, `.hh`, `.hxx` are C++; `.h` is left to Xcode because it is usually C or Objective-C.
* **JavaScript and TypeScript** use typescript-language-server (`.js`, `.mjs`, `.cjs`, `.jsx`, `.ts`, `.mts`, `.cts`, `.tsx`). It uses the project's TypeScript from `node_modules` when there is one.
* **WebAssembly text** (`.wat`, `.wast`) uses wat_server: completion of `$names` and instructions, go to definition, references, hover with signatures, and diagnostics including type checking.

### Running tests

Use **Run Tests in File**, **Run Test at Cursor**, **Debug Test at Cursor**, and **Show Test Markers** as for the other languages. Results appear as `✓`/`✗` markers above the tests and in the **Test Results** window.

| Language | How tests are found | Runner (auto-detect) |
|---|---|---|
| C++ | `TEST`, `TEST_F`, `TEST_P`, `TYPED_TEST` (GoogleTest), `TEST_CASE`, `SCENARIO`, `TEMPLATE_TEST_CASE` (Catch2, doctest) | **CMake + CTest**: CrossKit configures the project into its own build folder (`cmake -S <root> -B …`, Debug), builds it and runs `ctest -R <regex> --output-junit`. Register your tests with `gtest_discover_tests`, `catch_discover_tests`, or `add_test`. Parameterized names such as `Inst/Suite.Name/0` match their test. |
| JavaScript, TypeScript | `test(…)`, `it(…)`, `specify(…)` inside `describe`/`suite`/`context`, including `.only`, `.skip`, `.todo`, and `.concurrent` | `bun:test` or `node:test` imports pick that runner; then `vitest`/`jest` imports or dependencies in `package.json`; then `bun.lock`, `vitest.config.*`; otherwise **node:test**. Vitest and node:test report through JUnit, Jest through `--json`. |
| WebAssembly `.wat` | Exported functions whose export name starts with `test` (`(export "test_add")`). A test passes when it returns without a trap and does not return `0`. | **Wasmtime** (`wasmtime run --invoke`) when installed, otherwise the **Node.js harness** (the module is converted with `wasm-tools`/`wat2wasm` and run by Node.js). |
| WebAssembly `.wast` | Top-level `assert_*` directives | **wasmtime wast**. It stops at the first failing directive: earlier assertions pass, later ones are shown as skipped. |

A C++ file without a `CMakeLists.txt` above it has no test runner; use Run File for a quick check.

### Code coverage

Choose **Editor › CrossKit › Run Tests with Coverage**. The cursor decides the scope: inside a test only that test runs, otherwise the whole file. CrossKit then:

1. marks every test `✓` or `✗` as usual,
2. adds `// [CrossKit] ░ not covered: lines 12–15` above each uncovered block of the current file,
3. shows a summary such as `Coverage 84.6% (22/26 lines) in math.ts`, and
4. opens the **Coverage** window: every covered file of the project with its icon, a coverage bar and a percentage; select one to see the source with hit counts, covered lines in green and missed lines in red. Double-click a line to open it in Xcode.

| Language | How coverage is collected |
|---|---|
| C++ | A separate CMake build with `-fprofile-instr-generate -fcoverage-mapping` (using Xcode's clang). Tests run with `LLVM_PROFILE_FILE`; the profiles are merged with `llvm-profdata` and exported with `llvm-cov export -format=lcov`. |
| JavaScript, TypeScript | node:test: `--experimental-test-coverage` with the LCOV reporter (V8 coverage). Vitest: `--coverage` with the `v8` or `istanbul` provider installed in the project. Jest: `--coverage --coverageReporters=lcov` (istanbul). bun: `--coverage --coverage-reporter=lcov`. |
| WebAssembly | CrossKit instruments a copy of the module: an exported counter global per function and per `if` branch. After the tests, the harness reads the counters and maps them back to lines of the `.wat` file. Coverage of `.wat` tests always runs through the Node.js harness. |

Only files inside the project root are reported; test files, `node_modules`, and system headers are left out. Clear the markers with **Clear CrossKit Annotations**.

### Debugging

Use **Debug File at Cursor** and **Debug Test at Cursor**. The breakpoint is the cursor line, as for the other languages.

* **C++** uses lldb-dap (or lldb in Terminal, or CodeLLDB).
  * In a CMake project, CrossKit builds the Debug configuration and asks CMake's File API which target contains the file. For a test it asks CTest for the exact command (`ctest --show-only=json-v1`) and runs that executable with the test's arguments.
  * A loose file (no `CMakeLists.txt`) is compiled with `clang++ -g -O0` and the flags from `compile_commands.json` or `compile_flags.txt` (default `-std=c++20`).
* **JavaScript and TypeScript** use the Node.js inspector, started with `--inspect-brk` on a free local port.
  * **Node.js inspector (CrossKit Debugger window)** connects CrossKit to it: call stack, local and block variables, Continue/Step/Pause/Stop, console output.
  * **node inspect in Terminal** opens Node's command-line debugger with a hint for setting the breakpoint (`sb('file.ts', 12)`).
  * **Wait for Chrome DevTools / VS Code to attach** starts the program paused and shows the address. In Chrome open `chrome://inspect`, choose **Configure…** and add the address. In VS Code use a `node` launch configuration with `"request": "attach"` and the port.
  * TypeScript runs on Node.js 23.6+ natively (type stripping). Tests are debugged in-process: node:test with `--test-isolation=none`, Vitest with `--inspect-brk` in its worker and `--no-file-parallelism`, Jest with `--runInBand`. bun tests cannot be debugged.
* **WebAssembly** uses the Node.js inspector by default.
  * CrossKit converts the `.wat` file to a `.wasm` with name and debug sections, loads it in a small harness, and calls the export at the cursor (when it takes no parameters), otherwise `_start`, `main`, or `run`.
  * Breakpoints and stack frames are mapped between `.wat` lines and code offsets. Locals and parameters (`$a`, `$b`) are shown with their values.
  * The lldb choices run the module in `wasmtime -D debug-info`; this is useful for modules compiled from C, C++, Rust, or Zig with DWARF, not for hand-written `.wat`.
  * `.wast` scripts cannot be debugged; run them as tests.

### File inspections (Preview window)

**Show Preview** in a C++, JavaScript, TypeScript, or WebAssembly file opens the **Preview** window with tabs. **Open…** in the window (or **Inspect a File…** in the menu bar menu) inspects any file from disk, including binary `.wasm` modules. **Auto-refresh on save** re-runs the inspection when the file changes, and **Command** shows the command behind each tab.

| Language | Tabs |
|---|---|
| C++ | **Assembly -O0** and **Assembly -O2** (`clang++ -S`, demangled with `c++filt`, directives removed), **Symbols** (`nm -C -n`), **Includes** (the header tree from `clang++ -H`). The project's flags are taken from `compile_commands.json` or `compile_flags.txt`. |
| JavaScript | **Outline** (functions, classes, exports), **Imports**, **Syntax Check** (`node --check`). |
| TypeScript | **Outline**, **Imports**, **Emitted JavaScript** (`tsc`, or Node.js type stripping when TypeScript is missing), **Type Check** (`tsc --noEmit`). |
| WebAssembly | **Validation**, **Module** (types, imports, functions with signatures and code sizes, exports, memories, tables), **WAT** (the binary printed back as text by `wasm-tools print` or `wasm2wat`), **Hex** (the first bytes of the binary). |

### Run File and Build Project

* **C++**: CMake projects are configured and built in CrossKit's build folder and the target containing the file is run; loose files are compiled with `clang++`.
* **JavaScript**: `node file.js`. **TypeScript**: type-checked with `tsc --noEmit` when TypeScript is installed, then run with `node file.ts` (Node.js 23.6+).
* **WebAssembly**: `wasmtime run --invoke <export>` with the export at the cursor (or `_start`/`main`), otherwise the Node.js harness.

### When something is missing

Messages name the tool and how to get it, for example:

* `cmake was not found. Install CMake (mise use -g cmake). CTest ships with CMake.`
* `@vitest/coverage-v8 was not found. Vitest coverage needs a provider in the project: npm install -D @vitest/coverage-v8. Or choose node:test as the runner.`
* `Node.js 23.6 or newer was not found. node:test runs TypeScript natively from Node.js 23.6 (mise use -g node@lts). Or choose Vitest/Jest/bun.`
* `llvm-profdata/llvm-cov were not found. They ship with Xcode (xcrun llvm-cov) and LLVM (mise use -g llvm).`
* In the Preview window, a tab whose tool is missing explains what to install instead of failing the whole inspection.

<a id="limitations-of-the-new-languages"></a>
### Limitations

* **C++ tests need CMake.** Other build systems (Meson, Bazel, Make) get language features, Run File for loose files, and inspections, but no test runner, coverage, or target lookup.
* **C++ coverage** rebuilds the project in a separate folder with coverage flags and Xcode's clang, so the first run takes as long as a clean build.
* **Vitest coverage** needs `@vitest/coverage-v8` or `@vitest/coverage-istanbul` in the project. Jest and bun are supported but were not available on the test machine, so they are covered by unit tests only.
* **bun tests cannot be debugged.** Vitest breakpoints are set in the test worker; the first stop can take a second while Vitest starts.
* **WebAssembly line mapping** is exact for function boundaries but approximate inside functions with folded expressions (instructions are matched in order).
* **WebAssembly with lldb** only shows source lines for modules that carry DWARF debug info.
* **TypeScript without a build step** needs Node.js 23.6 or newer; older Node.js versions need Vitest, Jest, or bun for tests.

## 20. File icons

CrossKit draws macOS-style document icons for source files: a white page with a folded top-right corner, a coloured band, and a short badge.

| Files | Badge | Colour |
|---|---|---|
| `.cpp`, `.cc`, `.cxx` / `.hpp`, `.hh`, `.hxx` | `C++` / `H++` | C++ blue |
| `.js`, `.mjs`, `.cjs` / `.jsx` | `JS` / `JSX` | yellow, dark text |
| `.ts`, `.mts`, `.cts` / `.tsx` / `.d.ts` | `TS` / `TSX` / `D.TS` | TypeScript blue |
| `.wat` / `.wast` / `.wasm` | `WAT` / `WAST` / `WASM` | WebAssembly purple |
| `.kt` / `.kts` | `KT` / `KTS` | Kotlin purple to magenta |
| `.zig` | `ZIG` | Zig orange |
| `.rs` | `RS` | Rust copper |
| `.swift` | `SWIFT` | Swift orange |
| `.java` | `JAVA` | orange and blue |
| `CMakeLists.txt`, `package.json`, `tsconfig.json`, `Cargo.toml`, `build.zig` | `CMAKE`, `NPM`, `TS`, `RS`, `ZIG` | as their tools |

The icons appear in the Settings window (next to each language), the Test Results window (runs and test locations), the Run and Debugger windows, the Preview window's header, the Coverage window's file list, and the menu bar menu. Xcode's own project navigator and editor tabs cannot be changed by a Source Editor Extension, so Xcode keeps showing its standard icons there.
