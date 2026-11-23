import SwiftUI
import CrossKitCore

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Bridge") {
                    if let error = model.bridgeError {
                        Text(error).foregroundStyle(.red)
                    } else {
                        Text("Listening").foregroundStyle(.green)
                    }
                }
                HStack {
                    Text("Stop idle servers after")
                    Stepper(value: model.idleMinutes, in: 0...240, step: 5) {
                        Text(model.idleMinutes.wrappedValue == 0 ? "never" : "\(Int(model.idleMinutes.wrappedValue)) min")
                            .monospacedDigit()
                    }
                }
                HStack {
                    Text("Test timeout")
                    Stepper(value: model.testTimeoutMinutes, in: 1...120, step: 1) {
                        Text("\(Int(model.testTimeoutMinutes.wrappedValue)) min").monospacedDigit()
                    }
                }
                HStack {
                    Button("Open Extensions Settings…") { model.openExtensionsSettings() }
                    Button("Re-detect Servers") { model.refreshDetection() }
                }
                Text("Enable “CrossKit” under System Settings › General › Login Items & Extensions › Xcode Source Editor, then use Editor › CrossKit in Xcode. Bind keys in Xcode › Settings › Key Bindings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("General")
            }

            ForEach(Language.allCases) { language in
                LanguageSection(language: language)
            }

            InlineAnnotationsSection()

            RunAndPreviewSection()

            LaunchConfigurationsSection()
        }
        .formStyle(.grouped)
    }
}

struct LanguageSection: View {
    let language: Language
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let enabled = model.enabledBinding(language)
        let status = model.statuses[language] ?? ServerStatus()
        Section {
            Toggle("Enabled", isOn: enabled)

            Group {
                LabeledContent("Server") {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(model.effectivePath(language) ?? "Not found")
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .foregroundStyle(model.effectivePath(language) == nil ? .red : .primary)
                        Text(model.isCustomPath(language) ? "Chosen manually" : "Auto-detected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Spacer()
                    if let candidates = model.detectedPaths[language], candidates.count > 1 {
                        Menu("Detected (\(candidates.count))") {
                            ForEach(candidates, id: \.self) { path in
                                Button(path) { model.setCustomPath(path, for: language) }
                            }
                        }
                        .fixedSize()
                    }
                    Button("Choose…") { model.chooseBinary(for: language) }
                    Button("Use Auto-detect") { model.setCustomPath(nil, for: language) }
                        .disabled(!model.isCustomPath(language))
                }
                if model.effectivePath(language) == nil {
                    Text("Install with: \(language.installHint)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                LabeledContent("Features") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Feature.allCases.filter { $0.applies(to: language) }) { feature in
                            Toggle(feature.displayName(for: language), isOn: model.featureBinding(feature, language))
                                .toggleStyle(.checkbox)
                        }
                    }
                }

                TestSettings(language: language)

                if language == .kotlin {
                    KotlinTargetSettings()
                }

                DebugSettings(language: language)

                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle().fill(color(for: status.state)).frame(width: 9, height: 9)
                        Text(label(for: status))
                    }
                }
                if let error = status.lastError {
                    Text(error)
                        .font(.caption.monospaced())
                        .foregroundStyle(.red)
                        .lineLimit(6)
                        .textSelection(.enabled)
                }
                HStack {
                    Spacer()
                    Button("Restart") { model.restart(language) }
                    Button("Stop") { model.stop(language) }
                        .disabled(status.state != .running && status.state != .starting)
                }
            }
            .disabled(!enabled.wrappedValue)
        } header: {
            HStack(spacing: 6) {
                FileIconView(language: language, size: 18)
                Text(language.displayName)
            }
        }
    }

    private func label(for status: ServerStatus) -> String {
        var text = status.state.rawValue.capitalized
        if let pid = status.pid, status.state == .running || status.state == .starting { text += " (pid \(pid))" }
        if status.restartCount > 0 { text += ", restarts: \(status.restartCount)" }
        if let root = status.rootPath, status.state == .running { text += " — \((root as NSString).lastPathComponent)" }
        return text
    }

    private func color(for state: ServerStatus.State) -> Color {
        switch state {
        case .running: return .green
        case .starting, .restarting: return .yellow
        case .error, .notFound: return .red
        case .stopped, .disabled: return .gray
        }
    }
}

struct TestSettings: View {
    let language: Language
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let enabled = model.settings.isFeatureEnabled(.tests, for: language)
        LabeledContent("Test runner") {
            Picker("", selection: model.testRunnerBinding(language)) {
                Text("Auto-detect").tag("auto")
                ForEach(TestRunnerKind.kinds(for: language)) { kind in
                    Text(kind.displayName).tag(kind.rawValue)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
        .disabled(!enabled)
        LabeledContent("Test tools") {
            VStack(alignment: .trailing, spacing: 2) {
                if let custom = model.settings.testExecutablePath(for: language) {
                    Text("custom: \(custom)").font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                }
                ForEach(model.testTools[language] ?? [], id: \.tool) { item in
                    Text("\(item.tool): \(item.path ?? "not found")")
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(item.path == nil ? .orange : .secondary)
                }
                HStack {
                    Button("Choose…") { model.chooseTestExecutable(for: language) }
                    Button("Use Auto-detect") { model.resetTestExecutable(for: language) }
                        .disabled(model.settings.testExecutablePath(for: language) == nil)
                }
            }
        }
        .disabled(!enabled)
        LabeledContent("Extra test arguments") {
            TextField("e.g. --offline", text: model.testArgumentsBinding(language))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
        }
        .disabled(!enabled)
    }
}

struct DebugSettings: View {
    let language: Language
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let enabled = model.settings.isFeatureEnabled(.debug, for: language)
        let kind = model.effectiveDebugger(language)
        LabeledContent("Debugger") {
            Picker("", selection: model.debuggerBinding(language)) {
                Text("Auto-detect (\(model.debuggers.autoKind(for: language).displayName))").tag("auto")
                ForEach(DebuggerKind.choices(for: language)) { kind in
                    Text(kind.displayName).tag(kind.rawValue)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
        .disabled(!enabled)
        LabeledContent("Debugger tools") {
            VStack(alignment: .trailing, spacing: 2) {
                if let custom = model.settings.debuggerPath(for: kind) {
                    Text("custom \(kind.toolName): \(custom)").font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                }
                ForEach(model.debugTools[language] ?? [], id: \.tool) { item in
                    Text("\(item.tool): \(item.path ?? "not found")")
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(item.path == nil ? .orange : .secondary)
                }
                HStack {
                    Button("Choose \(kind.toolName)…") { model.chooseDebuggerPath(for: kind) }
                    Button("Use Auto-detect") { model.resetDebuggerPath(for: kind) }
                        .disabled(model.settings.debuggerPath(for: kind) == nil)
                }
            }
        }
        .disabled(!enabled)
        if language == .kotlin {
            LabeledContent("JDWP port") {
                TextField("5005", text: model.jdwpPortBinding)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .help("Port the debugged JVM listens on; 0 picks a free port each time.")
            }
            .disabled(!enabled)
        }
    }
}

struct KotlinTargetSettings: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        LabeledContent("Kotlin target") {
            VStack(alignment: .trailing, spacing: 4) {
                Picker("", selection: model.kotlinTargetBinding) {
                    Text(KotlinTargetChoice.auto.displayName).tag("auto")
                    Text(KotlinTargetChoice.jvm.displayName).tag("jvm")
                    Text("Kotlin/Native (\(KotlinProject.hostNativePreset))").tag("native")
                    Text("Other target…").tag("custom")
                }
                .labelsHidden()
                .fixedSize()
                if model.kotlinTargetBinding.wrappedValue == "custom" {
                    TextField("Gradle target name, e.g. desktop or linuxX64", text: model.kotlinCustomTargetBinding)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                }
            }
        }
        .help("Target for Build Project, Run File, tests and debugging in Kotlin Multiplatform modules. Files in a target's own source set (jvmMain, nativeMain, …) always use that target. A launch configuration can override it per project.")
        LabeledContent("Native debugger") {
            Picker("", selection: model.kotlinNativeDebuggerBinding) {
                Text("Auto-detect (\(model.debuggers.autoKind(for: .zig).displayName))").tag("auto")
                ForEach(DebuggerKind.nativeChoices) { kind in
                    Text(kind.displayName).tag(kind.rawValue)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
        .help("Debugger for Kotlin/Native binaries (linkDebugExecutable…). JVM targets use the Debugger setting below.")
        Toggle("Keep the Gradle daemon running (faster builds, runs, tests and previews)", isOn: model.gradleDaemonBinding)
            .help("When off, Gradle runs with --no-daemon and the Kotlin compiler in-process. Debug sessions never use the daemon.")
    }
}

struct InlineAnnotationsSection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Section {
            LabeledContent("Code Lens") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Reference counts", isOn: model.inlineBinding(\.lensReferences)).toggleStyle(.checkbox)
                    Toggle("Run, Debug and Preview actions", isOn: model.inlineBinding(\.lensActions)).toggleStyle(.checkbox)
                }
            }
            LabeledContent("Inlay hints") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Types", isOn: model.inlineBinding(\.hintTypes)).toggleStyle(.checkbox)
                    Toggle("Parameter names", isOn: model.inlineBinding(\.hintParameters)).toggleStyle(.checkbox)
                    Toggle("Other hints (chaining, closing braces, …)", isOn: model.inlineBinding(\.hintOther)).toggleStyle(.checkbox)
                    Picker("Placement", selection: model.inlineBinding(\.hintPlacement)) {
                        ForEach(InlineAnnotationOptions.Placement.allCases, id: \.self) { placement in
                            Text(placement.displayName).tag(placement)
                        }
                    }
                    .fixedSize()
                }
            }
            LabeledContent("ErrorLens") {
                VStack(alignment: .leading, spacing: 4) {
                    Picker("Show", selection: model.inlineBinding(\.errorLensMinimumSeverity)) {
                        Text("Errors").tag(1)
                        Text("Errors and warnings").tag(2)
                        Text("Errors, warnings and information").tag(3)
                        Text("Everything, including hints").tag(4)
                    }
                    .fixedSize()
                    Toggle("Show the diagnostic source (e.g. rustc, zls)", isOn: model.inlineBinding(\.errorLensShowSource)).toggleStyle(.checkbox)
                }
            }
            Text("Xcode extensions cannot draw inside the editor, so these are inserted as `// [CrossKit]` comments: lenses above declarations, hints above the line or at its end, ErrorLens at the end of the line. Turn each on or off per language under Features; Clear Inline Annotations removes them.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Inline Annotations")
        }
    }
}

struct RunAndPreviewSection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Section {
            HStack {
                Text("Run File waits for the program")
                Stepper(value: model.runWaitBinding, in: 0...120, step: 5) {
                    Text("\(Int(model.runWaitBinding.wrappedValue)) s").monospacedDigit()
                }
            }
            .help("Programs that finish within this time show their output in the alert; longer ones keep running in CrossKit › Run.")
            Picker("Compose preview scale", selection: model.previewDensityBinding) {
                Text("1× (1 px per dp)").tag(1.0)
                Text("2× (Retina)").tag(2.0)
                Text("3×").tag(3.0)
            }
            .fixedSize()
            Toggle("Re-render the Preview window when its file is saved", isOn: model.previewAutoRefreshBinding)
        } header: {
            Text("Build, Run & Preview")
        }
    }
}

struct LaunchConfigurationsSection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Section {
            if model.launchConfigurations.isEmpty {
                Text("A configuration is created and saved automatically the first time you build, run or debug a project (Editor › CrossKit › Run File, Debug File at Cursor).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(model.launchConfigurations) { configuration in
                LaunchConfigurationEditor(configuration: configuration)
            }
        } header: {
            Text("Launch Configurations")
        }
    }
}

struct LaunchConfigurationEditor: View {
    @EnvironmentObject private var model: AppModel
    @State private var config: LaunchConfiguration
    @State private var arguments: String
    @State private var environment: String
    @State private var testArguments: String

    init(configuration: LaunchConfiguration) {
        _config = State(initialValue: configuration)
        _arguments = State(initialValue: LaunchConfiguration.joinArguments(configuration.arguments))
        _environment = State(initialValue: LaunchConfiguration.formatEnvironment(configuration.environment))
        _testArguments = State(initialValue: LaunchConfiguration.joinArguments(configuration.testArguments))
    }

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                if config.language == .kotlin {
                    LabeledContent("Kotlin target") {
                        TextField("settings (\(model.settings.kotlinTarget.displayName))", text: Binding(
                            get: { config.kotlinTarget ?? "" },
                            set: { config.kotlinTarget = $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0.trimmingCharacters(in: .whitespaces) }))
                            .textFieldStyle(.roundedBorder)
                            .help("auto, jvm, native, or a Gradle target name such as desktop or macosArm64. Empty follows CrossKit settings.")
                    }
                }
                LabeledContent(config.language == .kotlin ? "Main class / executable" : "Program") {
                    TextField(config.language == .kotlin ? "auto (JVM: e.g. demo.MainKt; Native: path to a .kexe)" : "auto (built by CrossKit)", text: $config.program)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("Arguments") {
                    TextField("e.g. --port 8080 \"two words\"", text: $arguments).textFieldStyle(.roundedBorder)
                }
                LabeledContent("Environment") {
                    TextEditor(text: $environment)
                        .font(.caption.monospaced())
                        .frame(height: 54)
                        .overlay(alignment: .topLeading) {
                            if environment.isEmpty {
                                Text("KEY=VALUE, one per line").font(.caption).foregroundStyle(.tertiary).padding(4).allowsHitTesting(false)
                            }
                        }
                }
                LabeledContent("Working directory") {
                    TextField(config.projectRoot, text: $config.workingDirectory).textFieldStyle(.roundedBorder)
                }
                LabeledContent("Test binary arguments") {
                    TextField(config.language == .rust ? "e.g. --include-ignored" : "", text: $testArguments).textFieldStyle(.roundedBorder)
                }
                .disabled(config.language == .kotlin)
                Toggle("Build before launching", isOn: $config.buildBeforeLaunch)
                    .help("Zig projects with build.zig run `zig build install` first. Loose Zig files, Cargo and Gradle projects are always built.")
                HStack {
                    Spacer()
                    Button("Delete", role: .destructive) { model.delete(config) }
                }
            }
            .padding(.vertical, 4)
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(config.language.displayName) · \(config.projectName)")
                Text(config.projectRoot).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
        .onChange(of: config) { _, value in model.save(value) }
        .onChange(of: arguments) { _, value in config.arguments = LaunchConfiguration.splitArguments(value) }
        .onChange(of: environment) { _, value in config.environment = LaunchConfiguration.parseEnvironment(value) }
        .onChange(of: testArguments) { _, value in config.testArguments = LaunchConfiguration.splitArguments(value) }
    }
}
