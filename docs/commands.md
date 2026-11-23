# Commands


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
