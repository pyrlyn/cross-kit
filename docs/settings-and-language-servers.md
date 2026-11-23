# Settings and language servers


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
