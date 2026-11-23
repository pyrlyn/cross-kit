import SwiftUI
import AppKit
import CrossKitCore

/// Build & Run, Compose previews, Kotlin targets and inline-annotation settings.
extension AppModel {
    // MARK: Build & Run

    func updateProgramRun(_ run: ProgramRun) {
        let isNew = !programRuns.contains { $0.id == run.id }
        if let index = programRuns.firstIndex(where: { $0.id == run.id }) {
            programRuns[index] = run
        } else {
            programRuns.insert(run, at: 0)
            if programRuns.count > 30 { programRuns.removeLast(programRuns.count - 30) }
        }
        launchConfigurations = settings.launchConfigurations().sorted { $0.id < $1.id }
        // Long-running programs come to the front so their output and Stop button are visible.
        if isNew || (run.state == .running && RunWindow.selection.id != run.id && run.mode == .run) {
            RunWindow.show(model: self, select: run.id)
        }
    }

    func stopRun(_ id: String) {
        handler.runService.stop(id)
    }

    func clearFinishedRuns() {
        programRuns.removeAll { !$0.state.isActive }
    }

    var runWaitBinding: Binding<Double> {
        Binding(
            get: { self.settings.runWaitSeconds },
            set: { value in
                self.objectWillChange.send()
                self.settings.runWaitSeconds = max(0, value)
            })
    }

    // MARK: Compose previews

    func showPreview(_ result: PreviewResult) {
        previewImages = Dictionary(uniqueKeysWithValues: result.previews.compactMap { rendered in
            rendered.imagePath.flatMap { NSImage(contentsOfFile: $0) }.map { (rendered.id, $0) }
        })
        preview = result
        previewShowsInspection = false
        previewError = nil
        previewFileDate = Self.modificationDate(result.filePath)
        PreviewWindow.show(model: self)
    }

    /// Renders the shown file again (saved contents), keeping the focused preview.
    func refreshPreview() {
        guard let current = preview, !previewRendering else { return }
        let focusLine = current.previews.first { $0.id == current.focusedID }?.preview.line ?? 0
        let text = (try? String(contentsOfFile: current.filePath, encoding: .utf8)) ?? ""
        previewRendering = true
        let service = handler.previewService
        Task {
            do {
                let result = try await service.render(file: URL(fileURLWithPath: current.filePath), text: text, cursorLine: focusLine)
                await MainActor.run {
                    self.previewRendering = false
                    self.showPreview(result)
                }
            } catch {
                await MainActor.run {
                    self.previewRendering = false
                    self.previewError = error.localizedDescription
                    self.previewFileDate = Self.modificationDate(current.filePath)
                }
            }
        }
    }

    /// Called every second by the Preview window: re-renders when the file was saved.
    func checkPreviewAutoRefresh() {
        if previewShowsInspection {
            guard settings.previewAutoRefresh, let current = inspection, !inspecting else { return }
            if let date = Self.modificationDate(current.filePath), let known = previewFileDate, date > known {
                previewFileDate = date
                refreshInspection()
            }
            return
        }
        guard settings.previewAutoRefresh, let current = preview, !previewRendering else { return }
        let date = Self.modificationDate(current.filePath)
        if let date, let known = previewFileDate, date > known {
            previewFileDate = date
            refreshPreview()
        }
    }

    static func modificationDate(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    var previewDensityBinding: Binding<Double> {
        Binding(
            get: { self.settings.previewDensity },
            set: { value in
                self.objectWillChange.send()
                self.settings.previewDensity = min(max(value, 1), 4)
            })
    }

    var previewAutoRefreshBinding: Binding<Bool> {
        Binding(
            get: { self.settings.previewAutoRefresh },
            set: { value in
                self.objectWillChange.send()
                self.settings.previewAutoRefresh = value
            })
    }

    // MARK: Kotlin targets

    /// "auto", "jvm", "native" or "custom" (with `kotlinCustomTargetBinding`).
    var kotlinTargetBinding: Binding<String> {
        Binding(
            get: {
                switch self.settings.kotlinTarget {
                case .auto: return "auto"
                case .jvm: return "jvm"
                case .native: return "native"
                case .named: return "custom"
                }
            },
            set: { value in
                self.objectWillChange.send()
                switch value {
                case "jvm": self.settings.kotlinTarget = .jvm
                case "native": self.settings.kotlinTarget = .native
                case "custom":
                    if case .named = self.settings.kotlinTarget { return }
                    self.settings.kotlinTarget = .named(KotlinProject.hostNativePreset)
                default: self.settings.kotlinTarget = .auto
                }
            })
    }

    var kotlinCustomTargetBinding: Binding<String> {
        Binding(
            get: { if case .named(let name) = self.settings.kotlinTarget { return name }; return "" },
            set: { value in
                let name = value.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                self.objectWillChange.send()
                self.settings.kotlinTarget = KotlinTargetChoice(name)
            })
    }

    var kotlinNativeDebuggerBinding: Binding<String> {
        Binding(
            get: { self.settings.kotlinNativeDebugger?.rawValue ?? "auto" },
            set: { value in
                self.objectWillChange.send()
                self.settings.kotlinNativeDebugger = DebuggerKind(rawValue: value)
            })
    }

    var gradleDaemonBinding: Binding<Bool> {
        Binding(
            get: { self.settings.gradleDaemon },
            set: { value in
                self.objectWillChange.send()
                self.settings.gradleDaemon = value
            })
    }

    // MARK: Inline annotations

    func inlineBinding<T>(_ keyPath: WritableKeyPath<InlineAnnotationOptions, T>) -> Binding<T> {
        Binding(
            get: { self.settings.inlineOptions[keyPath: keyPath] },
            set: { value in
                self.objectWillChange.send()
                var options = self.settings.inlineOptions
                options[keyPath: keyPath] = value
                self.settings.inlineOptions = options
            })
    }
}
