# Layout


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
