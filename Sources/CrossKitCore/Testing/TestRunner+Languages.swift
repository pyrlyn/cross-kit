import Foundation

/// Test commands of the C++ (CMake + CTest), JavaScript/TypeScript (Vitest, Jest, node:test, bun) and
/// WebAssembly (wasmtime, Node.js harness) runners, with optional coverage collection.
extension TestRunnerResolver {
    func scratch(_ name: String) -> URL {
        let dir = workDirectory.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func reportFile(_ ext: String) -> URL {
        scratch("test-reports").appendingPathComponent("\(UUID().uuidString).\(ext)")
    }

    /// The tests a run selects: the cursor test, else every test of the file.
    func selected(_ scope: TestScope, tests: [DiscoveredTest], cursorTest: DiscoveredTest?) -> [DiscoveredTest] {
        if scope == .cursor, let cursorTest { return [cursorTest] }
        return tests
    }

    /// Compile flags of CrossKit's coverage build of a CMake project.
    public static let cmakeCoverageArguments = [
        "-DCMAKE_C_FLAGS=-fprofile-instr-generate -fcoverage-mapping",
        "-DCMAKE_CXX_FLAGS=-fprofile-instr-generate -fcoverage-mapping",
        "-DCMAKE_EXE_LINKER_FLAGS=-fprofile-instr-generate",
        "-DCMAKE_SHARED_LINKER_FLAGS=-fprofile-instr-generate",
    ]

    static func relativePath(_ file: URL, to root: URL) -> String {
        let f = file.standardizedFileURL.path, r = root.standardizedFileURL.path
        return f.hasPrefix(r + "/") ? String(f.dropFirst(r.count + 1)) : f
    }

    func extendedCommand(kind: TestRunnerKind, executable exe: URL, language: Language, file: URL, root: URL, scope: TestScope,
                         tests: [DiscoveredTest], cursorTest: DiscoveredTest?, coverage: Bool) throws -> TestCommand {
        let chosen = selected(scope, tests: tests, cursorTest: cursorTest)
        let extra = settings.testArguments(for: language)
        var env = environment(language: language, executable: exe)
        let runID = UUID().uuidString
        var artifacts: CoverageArtifacts?
        let coverageDir = coverage ? scratch("coverage").appendingPathComponent(runID, isDirectory: true) : nil
        if let coverageDir { try FileManager.default.createDirectory(at: coverageDir, withIntermediateDirectories: true) }

        switch kind {
        case .ctest:
            guard CppTesting.projectRoot(for: file) != nil else {
                throw TestRunnerError.noProject("No CMakeLists.txt above \(file.lastPathComponent). CrossKit runs C++ tests with CMake + CTest: register them with gtest_discover_tests / catch_discover_tests / doctest_discover_tests or add_test.")
            }
            guard let ctest = tools.ctest() else { throw TestRunnerError.toolNotFound("ctest", hint: ToolFinder.cmakeHint) }
            let build = CppTesting.buildDirectory(root: root, variant: coverage ? "coverage" : "debug", workDirectory: workDirectory)
            let report = reportFile("xml")
            var ctestArgs = [ctest.path, "--test-dir", build.path, "--output-on-failure", "--no-tests=error", "--output-junit", report.path]
            if !chosen.isEmpty { ctestArgs += ["-R", CppTesting.ctestRegex(for: chosen)] }
            ctestArgs += extra
            var configure: [String] = []
            if coverage, let clang = tools.clangxx() {
                // The compiler whose llvm-profdata/llvm-cov read the profiles.
                configure.append("-DCMAKE_CXX_COMPILER=\(clang.path)")
            }
            if coverage, let coverageDir {
                configure += Self.cmakeCoverageArguments
                env["LLVM_PROFILE_FILE"] = coverageDir.appendingPathComponent("%p-%m.profraw").path
                artifacts = CoverageArtifacts(format: .llvmProfiles, path: coverageDir.path, baseDirectory: root.path,
                                              buildDirectory: build.path, compiler: tools.clangxx()?.path, scratchDirectory: coverageDir.path)
            }
            let script = CppTesting.buildScript(cmake: exe.path, root: root, buildDirectory: build, configureArguments: configure, then: [ctestArgs])
            return TestCommand(kind: kind, executable: "/bin/sh", arguments: ["-c", script], workingDirectory: root.path,
                               environment: env, reportFile: report.path, coverage: artifacts)

        case .vitest:
            let report = reportFile("xml")
            // Vitest filters by substring of the real path; a path relative to the root avoids /tmp vs /private/tmp mismatches.
            var args = ["run", Self.relativePath(file, to: root), "--reporter=default", "--reporter=junit", "--outputFile.junit=\(report.path)"]
            if scope == .cursor, let test = cursorTest { args += ["-t", JSTesting.namePattern(for: test)] }
            if let coverageDir {
                let fm = FileManager.default
                let provider = fm.fileExists(atPath: root.appendingPathComponent("node_modules/@vitest/coverage-v8").path) ? "v8"
                    : fm.fileExists(atPath: root.appendingPathComponent("node_modules/@vitest/coverage-istanbul").path) ? "istanbul" : nil
                guard let provider else {
                    throw TestRunnerError.toolNotFound("@vitest/coverage-v8", hint: "Vitest coverage needs a provider in the project: `npm install -D @vitest/coverage-v8`. Or choose node:test as the runner.")
                }
                args += ["--coverage.enabled=true", "--coverage.provider=\(provider)", "--coverage.reporter=lcov",
                         "--coverage.reportsDirectory=\(coverageDir.path)", "--coverage.clean=false"]
                artifacts = CoverageArtifacts(format: .lcov, path: coverageDir.appendingPathComponent("lcov.info").path,
                                              baseDirectory: root.path, scratchDirectory: coverageDir.path)
            }
            return TestCommand(kind: kind, executable: exe.path, arguments: args + extra, workingDirectory: root.path,
                               environment: env, reportFile: report.path, coverage: artifacts)

        case .jest:
            let report = reportFile("json")
            var args = ["--runTestsByPath", Self.relativePath(file, to: root), "--json", "--outputFile=\(report.path)", "--testLocationInResults", "--ci"]
            if scope == .cursor, let test = cursorTest { args += ["-t", JSTesting.namePattern(for: test)] }
            if let coverageDir {
                args += ["--coverage", "--coverageReporters=lcov", "--coverageDirectory=\(coverageDir.path)"]
                artifacts = CoverageArtifacts(format: .lcov, path: coverageDir.appendingPathComponent("lcov.info").path,
                                              baseDirectory: root.path, scratchDirectory: coverageDir.path)
            }
            return TestCommand(kind: kind, executable: exe.path, arguments: args + extra, workingDirectory: root.path,
                               environment: env, reportFile: report.path, coverage: artifacts)

        case .nodeTest:
            if language == .typescript, !tools.nodeRunsTypeScript(exe) {
                throw TestRunnerError.toolNotFound("Node.js 23.6 or newer", hint: "node:test runs TypeScript natively from Node.js 23.6 (`mise use -g node@lts`). Or choose Vitest/Jest/bun.")
            }
            let report = reportFile("xml")
            var args = ["--test", "--test-reporter=spec", "--test-reporter-destination=stdout",
                        "--test-reporter=junit", "--test-reporter-destination=\(report.path)"]
            if scope == .cursor, let test = cursorTest { args.append("--test-name-pattern=\(JSTesting.namePattern(for: test))") }
            if let coverageDir {
                let lcov = coverageDir.appendingPathComponent("lcov.info")
                args += ["--experimental-test-coverage", "--test-reporter=lcov", "--test-reporter-destination=\(lcov.path)"]
                artifacts = CoverageArtifacts(format: .lcov, path: lcov.path, baseDirectory: root.path, scratchDirectory: coverageDir.path)
            }
            args += extra + [file.path]
            return TestCommand(kind: kind, executable: exe.path, arguments: args, workingDirectory: root.path,
                               environment: env, reportFile: report.path, coverage: artifacts)

        case .bunTest:
            let report = reportFile("xml")
            var args = ["test", file.path, "--reporter=junit", "--reporter-outfile=\(report.path)"]
            if scope == .cursor, let test = cursorTest { args += ["-t", JSTesting.namePattern(for: test)] }
            if let coverageDir {
                args += ["--coverage", "--coverage-reporter=lcov", "--coverage-dir=\(coverageDir.path)"]
                artifacts = CoverageArtifacts(format: .lcov, path: coverageDir.appendingPathComponent("lcov.info").path,
                                              baseDirectory: root.path, scratchDirectory: coverageDir.path)
            }
            return TestCommand(kind: kind, executable: exe.path, arguments: args + extra, workingDirectory: root.path,
                               environment: env, reportFile: report.path, coverage: artifacts)

        case .wasmtimeInvoke:
            let script = WasmTesting.invokeScript(wasmtime: exe.path, file: file.path, tests: chosen.map(\.filter))
            return TestCommand(kind: kind, executable: "/bin/sh", arguments: ["-c", script], workingDirectory: root.path, environment: env)

        case .nodeWasm:
            guard let converter = WasmTesting.converter(tools: tools) else {
                throw TestRunnerError.toolNotFound("wasm-tools", hint: ToolFinder.wasmToolsHint)
            }
            let harness = try WasmHarness.install(in: workDirectory)
            let work = coverageDir ?? scratch("wasm").appendingPathComponent(runID, isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            var source = file
            if coverage {
                let text = try String(contentsOf: file, encoding: .utf8)
                let instrumented = WatInstrumenter.instrument(text)
                source = work.appendingPathComponent(file.lastPathComponent)
                try instrumented.text.write(to: source, atomically: true, encoding: .utf8)
                let probes = work.appendingPathComponent("probes.json")
                try JSONEncoder().encode(instrumented.probes).write(to: probes)
                artifacts = CoverageArtifacts(format: .watCounters, path: probes.path, baseDirectory: root.path,
                                              sourceFile: file.path, scratchDirectory: work.path)
            }
            let output = work.appendingPathComponent((file.lastPathComponent as NSString).deletingPathExtension + ".wasm")
            let script = WasmTesting.harnessScript(converter: converter, node: exe.path, harness: harness.path, file: source.path,
                                                   output: output.path, tests: chosen.map(\.filter))
            return TestCommand(kind: kind, executable: "/bin/sh", arguments: ["-c", script], workingDirectory: root.path,
                               environment: env, coverage: artifacts)

        case .wasmtimeWast:
            return TestCommand(kind: kind, executable: exe.path, arguments: ["wast"] + extra + [file.path], workingDirectory: root.path, environment: env)

        case .zigBuild, .zigTest, .cargoTest, .cargoNextest, .gradle, .gradleWrapper:
            preconditionFailure("handled by command(language:…)")
        }
    }
}
