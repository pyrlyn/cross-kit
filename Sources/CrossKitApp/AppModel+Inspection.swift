import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CrossKitCore

/// File inspections (assembly, symbols, emitted JavaScript, WAT…) and coverage reports.
extension AppModel {
    func showInspection(_ result: InspectionResult) {
        inspection = result
        inspectionError = nil
        previewShowsInspection = true
        previewFileDate = Self.modificationDate(result.filePath)
        PreviewWindow.show(model: self)
    }

    /// Inspects a file from disk: a source file of a supported language or a binary `.wasm` module.
    func inspect(file: URL) {
        let ext = file.pathExtension.lowercased()
        guard let language = ext == "wasm" ? .wasm : Language.allCases.first(where: { $0.defaultExtensions.contains(ext) }),
              InspectService.supports(language) else {
            inspectionError = "CrossKit cannot inspect .\(ext) files."
            return
        }
        let text = ext == "wasm" ? "" : ((try? String(contentsOf: file, encoding: .utf8)) ?? "")
        inspecting = true
        let service = handler.inspectService
        Task {
            do {
                let result = try await service.inspect(language: language, file: file.resolvingSymlinksInPath(), text: text)
                await MainActor.run {
                    self.inspecting = false
                    self.showInspection(result)
                }
            } catch {
                await MainActor.run {
                    self.inspecting = false
                    self.inspectionError = error.localizedDescription
                    PreviewWindow.show(model: self)
                }
            }
        }
    }

    func refreshInspection() {
        guard let current = inspection, !inspecting else { return }
        inspect(file: URL(fileURLWithPath: current.filePath))
    }

    func chooseFileToInspect() {
        let panel = NSOpenPanel()
        panel.title = "Inspect a file"
        panel.message = "Choose a C++, JavaScript, TypeScript, WebAssembly text (.wat) or binary (.wasm) file."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = (["wasm", "wat", "wast"] + Language.cpp.defaultExtensions + Language.javascript.defaultExtensions
            + Language.typescript.defaultExtensions).compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK, let url = panel.url { inspect(file: url) }
    }

    /// Menu items take images, not views: the language's document icon rendered once.
    func languageIcon(_ language: Language) -> NSImage? {
        if let cached = Self.iconCache[language] { return cached }
        let image = FileIconRenderer.image(FileIconStyle.forLanguage(language), size: 16)
        Self.iconCache[language] = image
        return image
    }

    private static var iconCache: [Language: NSImage] = [:]

    func showCoverage(_ report: CoverageReport) {
        coverageReports.insert(report, at: 0)
        if coverageReports.count > 20 { coverageReports.removeLast(coverageReports.count - 20) }
        CoverageWindow.show(model: self)
    }
}
