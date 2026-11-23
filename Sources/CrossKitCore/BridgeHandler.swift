import Foundation

/// Host-side request handling: resolves the document and language, enforces settings,
/// talks to the language server and returns bridge models.
public final class BridgeHandler: @unchecked Sendable {
    public typealias DocumentResolver = @Sendable (BridgeRequest, Language?) -> URL?
    public typealias LocationOpener = @Sendable (BridgeLocation) -> Void

    private let manager: ServerManager
    private let settings: SettingsStore
    private let scratchDirectory: URL
    public var documentResolver: DocumentResolver?
    public var openLocation: LocationOpener?
    public var testService: TestService
    public var debugService: DebugService
    public var runService: RunService
    public var previewService: PreviewService
    public var inspectService: InspectService
    public var coverageService: CoverageService
    /// Called with every finished test run (the host shows them in its Test Results window).
    public var onTestRun: (@Sendable (TestRunResult) -> Void)?
    /// Called with every preview render (the host shows its Preview window).
    public var onPreview: (@Sendable (PreviewResult) -> Void)?
    /// Called with every inspection (C++/JavaScript/TypeScript/WebAssembly previews).
    public var onInspection: (@Sendable (InspectionResult) -> Void)?
    /// Called with every coverage report (the host shows its Coverage window).
    public var onCoverage: (@Sendable (CoverageReport) -> Void)?

    public init(manager: ServerManager, settings: SettingsStore, scratchDirectory: URL = SharedPaths.scratchDirectory) {
        self.manager = manager
        self.settings = settings
        self.scratchDirectory = scratchDirectory
        let resolver = TestRunnerResolver(settings: settings)
        self.testService = TestService(resolver: resolver)
        let planner = LaunchPlanner(settings: settings, resolver: resolver)
        self.debugService = DebugService(planner: planner)
        self.runService = RunService(planner: planner)
        self.previewService = PreviewService(planner: planner)
        self.inspectService = InspectService(tools: resolver.tools, workDirectory: resolver.workDirectory)
        self.coverageService = CoverageService(tests: testService)
    }

    public func handle(_ request: BridgeRequest) async -> BridgeResponse {
        do {
            return try await process(request)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private func process(_ request: BridgeRequest) async throws -> BridgeResponse {
        if request.operation == .ping { return BridgeResponse() }

        var file = request.filePath.map { URL(fileURLWithPath: $0) }
        var language = file.flatMap { settings.language(forPath: $0.path) }
        if file == nil {
            let hint = Language.guess(fromUTI: request.contentUTI)
            file = documentResolver?(request, hint)
            language = file.flatMap { settings.language(forPath: $0.path) } ?? hint
        }
        guard let language else { throw BridgeError.unknownLanguage(request.contentUTI) }
        guard settings.isEnabled(language) else { throw BridgeError.languageDisabled(language) }
        if let feature = request.operation.feature, !settings.isFeatureEnabled(feature, for: language) {
            throw BridgeError.featureDisabled(feature, language)
        }
        if request.operation == .discoverTests || request.operation == .runTests {
            guard let file else { throw TestRunnerError.needsSavedFile }
            return try await processTests(request, language: language, file: file.resolvingSymlinksInPath())
        }
        if request.operation == .debugFile || request.operation == .debugTest {
            guard let file else { throw DebugError.needsSavedFile }
            var response = BridgeResponse()
            response.language = language
            response.filePath = file.resolvingSymlinksInPath().path
            response.debugLaunch = try await debugService.start(
                language: language, file: file.resolvingSymlinksInPath(), text: request.text, cursorLine: request.line,
                target: request.operation == .debugTest ? .test : .file)
            return response
        }
        if request.operation == .build || request.operation == .run {
            guard let file else { throw DebugError.needsSavedFile }
            var response = BridgeResponse()
            response.language = language
            response.filePath = file.resolvingSymlinksInPath().path
            let resolved = file.resolvingSymlinksInPath()
            response.programRun = request.operation == .build
                ? try await runService.build(language: language, file: resolved, text: request.text)
                : try await runService.runFile(language: language, file: resolved, text: request.text)
            return response
        }
        if request.operation == .coverage {
            guard let file else { throw TestRunnerError.needsSavedFile }
            let resolved = file.resolvingSymlinksInPath()
            var response = BridgeResponse()
            response.language = language
            response.filePath = resolved.path
            response.tests = testService.discover(language, file: resolved, text: request.text)
            let report = try await coverageService.run(language, file: resolved, text: request.text,
                                                       scope: request.testScope ?? .file, cursorLine: request.line)
            if let run = report.testRun { onTestRun?(run) }
            onCoverage?(report)
            response.coverage = report
            response.testRun = report.testRun
            return response
        }
        if request.operation == .preview, InspectService.supports(language) {
            guard let file else { throw DebugError.needsSavedFile }
            var response = BridgeResponse()
            response.language = language
            response.filePath = file.resolvingSymlinksInPath().path
            let result = try await inspectService.inspect(language: language, file: file.resolvingSymlinksInPath(), text: request.text)
            onInspection?(result)
            response.inspection = result
            return response
        }
        if request.operation == .preview {
            guard language == .kotlin else { throw BridgeError.unsupported("Compose previews are available for Kotlin files only.") }
            guard let file else { throw DebugError.needsSavedFile }
            var response = BridgeResponse()
            response.language = language
            response.filePath = file.resolvingSymlinksInPath().path
            let result = try await previewService.render(file: file.resolvingSymlinksInPath(), text: request.text, cursorLine: request.line)
            onPreview?(result)
            response.preview = result
            return response
        }
        var inlineKinds: [InlineKind] = []
        if request.operation == .inlineAnnotations {
            if let requested = request.inlineKinds {
                for kind in requested where !settings.isFeatureEnabled(kind.feature, for: language) {
                    throw BridgeError.featureDisabled(kind.feature, language)
                }
                inlineKinds = requested
            } else {
                inlineKinds = InlineKind.allCases.filter { settings.isFeatureEnabled($0.feature, for: language) }
                guard !inlineKinds.isEmpty else {
                    throw BridgeError.unsupported("Code Lens, Inlay Hints and ErrorLens are all turned off for \(language.displayName) in CrossKit settings.")
                }
            }
        }
        let documentURL = try (file ?? WorkspaceResolver.scratchFile(for: language, text: request.text, in: scratchDirectory))
            .resolvingSymlinksInPath()
        let root = WorkspaceResolver.root(for: documentURL, language: language).resolvingSymlinksInPath()
        let client = try await manager.client(for: language, root: root)
        let uri = LSPClient.normalizeURI(documentURL.absoluteString)
        let before = client.diagnosticsState(uri: uri).sequence
        try client.syncDocument(uri: uri, text: request.text)

        var response = BridgeResponse()
        response.language = language
        response.filePath = documentURL.path
        response.rootPath = root.path
        let textDocument: JSONValue = ["uri": .string(uri)]
        let position: JSONValue = ["line": .int(request.line), "character": .int(request.character)]
        let timeout = language.requestTimeout

        switch request.operation {
        case .ping, .discoverTests, .runTests, .debugFile, .debugTest, .build, .run, .preview, .coverage:
            break
        case .inlineAnnotations:
            let options = settings.inlineOptions
            response.inlineKinds = inlineKinds
            response.inlineOptions = options
            if inlineKinds.contains(.codeLens) {
                response.codeLenses = try await codeLenses(client: client, textDocument: textDocument, language: language,
                                                           file: documentURL, text: request.text, options: options, timeout: timeout)
            }
            if inlineKinds.contains(.inlayHints) {
                guard client.capabilities["inlayHintProvider"] != nil else {
                    throw BridgeError.unsupported("\(language.serverBinaryName) does not provide inlay hints.")
                }
                // The whole document: the end must be a real position (rust-analyzer rejects lines past the end).
                let lines = request.text.components(separatedBy: "\n")
                let end: JSONValue = ["line": .int(max(lines.count - 1, 0)), "character": .int(lines.last?.utf16.count ?? 0)]
                let result = try await warmRequest(client, "textDocument/inlayHint", [
                    "textDocument": textDocument,
                    "range": ["start": ["line": 0, "character": 0], "end": end],
                ], timeout: timeout)
                response.inlayHints = LSPConvert.inlayHints(result).filter { hint in
                    switch hint.kind {
                    case .type: return options.hintTypes
                    case .parameter: return options.hintParameters
                    case .other: return options.hintOther
                    }
                }
            }
            if inlineKinds.contains(.errorLens) {
                let (items, received) = await fetchDiagnostics(client: client, uri: uri, textDocument: textDocument, before: before,
                                                               language: language, timeout: timeout)
                response.diagnostics = items.filter { $0.severity <= options.errorLensMinimumSeverity }
                response.diagnosticsReceived = received
            }
        case .completion:
            let result = try await warmRequest(client, "textDocument/completion", [
                "textDocument": textDocument, "position": position, "context": ["triggerKind": 1],
            ], timeout: timeout)
            response.completions = Array(LSPConvert.completions(result).prefix(500))
        case .definition:
            let result = try await warmRequest(client, "textDocument/definition", [
                "textDocument": textDocument, "position": position,
            ], timeout: timeout)
            let locations = withPreviews(LSPConvert.locations(result), currentPath: documentURL.path, currentText: request.text)
            response.locations = locations
            if let first = locations.first, first.path != documentURL.path { openLocation?(first) }
        case .references:
            let result = try await warmRequest(client, "textDocument/references", [
                "textDocument": textDocument, "position": position, "context": ["includeDeclaration": true],
            ], timeout: timeout)
            response.locations = withPreviews(LSPConvert.locations(result), currentPath: documentURL.path, currentText: request.text)
        case .hover:
            let result = try await warmRequest(client, "textDocument/hover", [
                "textDocument": textDocument, "position": position,
            ], timeout: timeout)
            response.hover = LSPConvert.hoverText(result)
        case .diagnostics:
            let (items, received) = await fetchDiagnostics(client: client, uri: uri, textDocument: textDocument, before: before,
                                                           language: language, timeout: timeout)
            response.diagnostics = items
            response.diagnosticsReceived = received
        }
        await manager.touch(language, root: root)
        return response
    }

    private func fetchDiagnostics(client: LSPClient, uri: String, textDocument: JSONValue, before: Int, language: Language,
                                  timeout: TimeInterval) async -> ([BridgeDiagnostic], Bool) {
        if client.capabilities["diagnosticProvider"] != nil,
           let result = try? await client.request("textDocument/diagnostic", ["textDocument": textDocument], timeout: timeout),
           let items = result["items"]?.arrayValue {
            return (LSPConvert.diagnostics(items), true)
        }
        if let items = await client.waitForDiagnostics(uri: uri, afterSequence: before, timeout: language.diagnosticsTimeout) {
            return (LSPConvert.diagnostics(items), true)
        }
        return (LSPConvert.diagnostics(client.diagnosticsState(uri: uri).items), false)
    }

    // MARK: CodeLens

    /// Declarations that get a reference-count lens: class, method, enum, interface, function, object, struct.
    static let lensSymbolKinds: Set<Int> = [5, 6, 10, 11, 12, 19, 23]

    private func codeLenses(client: LSPClient, textDocument: JSONValue, language: Language, file: URL, text: String,
                            options: InlineAnnotationOptions, timeout: TimeInterval) async throws -> [BridgeCodeLens] {
        var lenses: [Int: BridgeCodeLens] = [:]
        if options.lensReferences, client.capabilities["documentSymbolProvider"] != nil {
            let result = try await warmRequest(client, "textDocument/documentSymbol", ["textDocument": textDocument], timeout: timeout)
            let symbols = LSPConvert.symbols(result).filter { Self.lensSymbolKinds.contains($0.kind) }
            let canCount = client.capabilities["referencesProvider"] != nil
            let deadline = Date().addingTimeInterval(language == .kotlin ? 90 : 45)
            for symbol in symbols.prefix(150) where lenses[symbol.selection.startLine] == nil {
                var count: Int?
                if canCount, Date() < deadline {
                    let position: JSONValue = ["line": .int(symbol.selection.startLine), "character": .int(symbol.selection.startCharacter)]
                    if let refs = try? await client.request("textDocument/references", [
                        "textDocument": textDocument, "position": position, "context": ["includeDeclaration": false],
                    ], timeout: 20) {
                        count = LSPConvert.locations(refs).filter {
                            !($0.path == file.path && $0.range.startLine == symbol.selection.startLine)
                        }.count
                    }
                }
                lenses[symbol.selection.startLine] = BridgeCodeLens(line: symbol.selection.startLine, symbol: symbol.name, references: count)
            }
        }
        if options.lensActions {
            func add(_ line: Int, _ name: String, _ actions: [String]) {
                var lens = lenses[line] ?? BridgeCodeLens(line: line, symbol: name)
                lens.actions += actions.filter { !lens.actions.contains($0) }
                lenses[line] = lens
            }
            let root = testService.resolver.projectRoot(for: file, language: language)
            if settings.isFeatureEnabled(.tests, for: language) || settings.isFeatureEnabled(.debug, for: language) {
                for test in TestDiscovery.discover(language, text: text, filePath: file.path, root: root) {
                    var actions: [String] = []
                    if settings.isFeatureEnabled(.tests, for: language) { actions.append("▶ Run Test") }
                    if settings.isFeatureEnabled(.debug, for: language) { actions.append("⚙ Debug Test") }
                    add(test.line, test.name, actions)
                }
            }
            if let main = TestDiscovery.mainLine(language, text: text) {
                var actions: [String] = []
                if settings.isFeatureEnabled(.run, for: language) { actions.append("▶ Run") }
                if settings.isFeatureEnabled(.debug, for: language) { actions.append("⚙ Debug") }
                if !actions.isEmpty { add(main, "main", actions) }
            }
            if language == .kotlin, settings.isFeatureEnabled(.preview, for: language) {
                for preview in PreviewDiscovery.discover(text: text, fileName: file.lastPathComponent) where preview.index == 0 {
                    add(preview.line, preview.function, ["◉ Preview"])
                }
            }
        }
        return lenses.values.filter { $0.references != nil || !$0.actions.isEmpty }.sorted { $0.line < $1.line }
    }

    // MARK: Tests

    private func processTests(_ request: BridgeRequest, language: Language, file: URL) async throws -> BridgeResponse {
        var tests = testService.discover(language, file: file, text: request.text)
        if language == .rust, let runnables = await rustRunnables(file: file, text: request.text, expectTests: !tests.isEmpty),
           !runnables.isEmpty {
            tests = runnables
        }
        var response = BridgeResponse()
        response.language = language
        response.filePath = file.path
        response.rootPath = testService.resolver.projectRoot(for: file, language: language).path
        response.tests = tests
        if request.operation == .runTests {
            let run = try await testService.run(language, file: file, text: request.text, scope: request.testScope ?? .file,
                                                cursorLine: request.line, tests: tests)
            onTestRun?(run)
            response.testRun = run
        }
        return response
    }

    /// rust-analyzer's `experimental/runnables`: exact test paths plus the cargo arguments it would use.
    private func rustRunnables(file: URL, text: String, expectTests: Bool) async -> [DiscoveredTest]? {
        guard settings.isEnabled(.rust), await manager.resolveBinary(for: .rust) != nil else { return nil }
        let root = WorkspaceResolver.root(for: file, language: .rust).resolvingSymlinksInPath()
        guard let client = try? await manager.client(for: .rust, root: root) else { return nil }
        let uri = LSPClient.normalizeURI(file.absoluteString)
        guard (try? client.syncDocument(uri: uri, text: text)) != nil else { return nil }
        var tests: [DiscoveredTest] = []
        for _ in 0..<30 {
            guard let result = try? await client.request("experimental/runnables", ["textDocument": ["uri": .string(uri)]],
                                                         timeout: 30) else { return nil }
            tests = Self.parseRunnables(result)
            if !tests.isEmpty || !expectTests || Date().timeIntervalSince(client.startedAt) > 60 { break }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return tests
    }

    static func parseRunnables(_ result: JSONValue) -> [DiscoveredTest] {
        (result.arrayValue ?? []).compactMap { runnable in
            guard let label = runnable["label"]?.stringValue, label.hasPrefix("test ") else { return nil }
            let path = String(label.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            let location = runnable["location"]
            let line = (LSPConvert.range(location?["targetSelectionRange"]) ?? LSPConvert.range(location?["targetRange"]))?.startLine ?? 0
            let args = runnable["args"]
            let cargo = (args?["cargoArgs"]?.arrayValue ?? []).compactMap(\.stringValue)
                + (args?["cargoExtraArgs"]?.arrayValue ?? []).compactMap(\.stringValue)
            let exe = (args?["executableArgs"]?.arrayValue ?? []).compactMap(\.stringValue)
            return DiscoveredTest(name: path.components(separatedBy: "::").last ?? path, filter: path, line: line,
                                  cargoArgs: cargo.isEmpty ? nil : cargo, executableArgs: exe.isEmpty ? nil : exe)
        }
    }

    /// Right after start, servers often answer `null`/`[]` while still indexing; retry briefly.
    private func warmRequest(_ client: LSPClient, _ method: String, _ params: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        var result = try await retryingRequest(client, method, params, timeout: timeout)
        var attempts = 0
        while Self.isEmpty(result), Date().timeIntervalSince(client.startedAt) < 60, attempts < 15 {
            attempts += 1
            try await Task.sleep(nanoseconds: 1_000_000_000)
            result = try await retryingRequest(client, method, params, timeout: timeout)
        }
        return result
    }

    /// Retries requests the server dropped because the workspace changed underneath them
    /// (ContentModified -32801, ServerCancelled -32802), which rust-analyzer does while indexing.
    private func retryingRequest(_ client: LSPClient, _ method: String, _ params: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        var attempt = 0
        while true {
            do {
                return try await client.request(method, params, timeout: timeout)
            } catch LSPError.server(let error) where Self.transientCodes.contains(error.code) && attempt < 10 {
                attempt += 1
                try await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    static let transientCodes: Set<Int> = [-32801, -32802]

    static func isEmpty(_ value: JSONValue) -> Bool {
        switch value {
        case .null: return true
        case .array(let items): return items.isEmpty
        case .object(let object):
            if let items = object["items"]?.arrayValue { return items.isEmpty }
            return false
        default: return false
        }
    }

    private func withPreviews(_ locations: [BridgeLocation], currentPath: String, currentText: String) -> [BridgeLocation] {
        var cache: [String: [Substring]] = [currentPath: currentText.split(separator: "\n", omittingEmptySubsequences: false)]
        return locations.map { location in
            var location = location
            if cache[location.path] == nil {
                let text = (try? String(contentsOfFile: location.path, encoding: .utf8)) ?? ""
                cache[location.path] = text.split(separator: "\n", omittingEmptySubsequences: false)
            }
            if let lines = cache[location.path], lines.indices.contains(location.range.startLine) {
                location.preview = lines[location.range.startLine].trimmingCharacters(in: .whitespaces)
            }
            return location
        }
    }
}
