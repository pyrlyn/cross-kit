# Limitations


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
