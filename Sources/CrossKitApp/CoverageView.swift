import SwiftUI
import AppKit
import CrossKitCore

/// Coverage reports from Editor › CrossKit › Run Tests with Coverage: files with their line coverage
/// and the source with covered (green) and missed (red) lines, like Xcode's coverage view.
@MainActor
enum CoverageWindow {
    private static var window: NSWindow?

    static func show(model: AppModel) {
        if window == nil {
            let hosting = NSHostingController(rootView: CoverageView().environmentObject(model))
            let w = NSWindow(contentViewController: hosting)
            w.title = "CrossKit Coverage"
            w.setContentSize(NSSize(width: 900, height: 620))
            w.styleMask.insert([.resizable, .miniaturizable])
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("CrossKitCoverage")
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct CoverageView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedReport: UUID?
    @State private var selectedFile: String?

    private var report: CoverageReport? {
        model.coverageReports.first { $0.id == (selectedReport ?? model.coverageReports.first?.id) }
    }

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                Picker("Report", selection: Binding(get: { selectedReport ?? model.coverageReports.first?.id },
                                                    set: { selectedReport = $0; selectedFile = nil })) {
                    ForEach(model.coverageReports) { report in
                        Text("\(report.language.displayName) · \(report.createdAt.formatted(date: .omitted, time: .shortened)) · \(CoverageFormat.percent(report.percent))")
                            .tag(Optional(report.id))
                    }
                }
                .labelsHidden()
                .padding(8)
                if let report {
                    List(report.files.sorted { $0.path < $1.path }, selection: $selectedFile) { file in
                        HStack(spacing: 6) {
                            FileIconView(path: file.path, size: 16)
                            Text(CoverageFormat.relative(file.path, root: report.projectRoot)).lineLimit(1).truncationMode(.head)
                            Spacer()
                            CoverageBar(percent: file.percent).frame(width: 48, height: 6)
                            Text(CoverageFormat.percent(file.percent)).monospacedDigit().font(.caption).frame(width: 46, alignment: .trailing)
                        }
                        .tag(file.path)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(report.summary).font(.caption)
                        Text("\(report.tool) · \(report.projectRoot)").font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                        if let warning = report.warning {
                            Label(warning, systemImage: "exclamationmark.triangle").font(.caption2).foregroundStyle(.orange)
                        }
                    }
                    .padding(8)
                } else {
                    Text("No coverage yet.\nUse Editor › CrossKit › Run Tests with Coverage in Xcode.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 280, idealWidth: 320)

            if let report, let file = report.files.first(where: { $0.path == (selectedFile ?? report.files.sorted { $0.path < $1.path }.first?.path) }) {
                CoverageSourceView(file: file)
                    .frame(minWidth: 480)
            } else {
                Text("Select a file").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

enum CoverageFormat {
    static func percent(_ value: Double) -> String { String(format: "%.1f%%", value) }

    static func relative(_ path: String, root: String) -> String {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : (path as NSString).lastPathComponent
    }

    static func color(_ percent: Double) -> Color {
        percent >= 80 ? .green : percent >= 50 ? .orange : .red
    }
}

struct CoverageBar: View {
    let percent: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule().fill(CoverageFormat.color(percent)).frame(width: geometry.size.width * percent / 100)
            }
        }
    }
}

private struct CoverageSourceView: View {
    @EnvironmentObject private var model: AppModel
    let file: FileCoverage

    var body: some View {
        let lines = ((try? String(contentsOfFile: file.path, encoding: .utf8)) ?? "").components(separatedBy: "\n")
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                FileIconView(path: file.path, size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text((file.path as NSString).lastPathComponent).font(.headline)
                    Text("\(file.linesHit)/\(file.linesFound) lines · \(file.functionsHit)/\(file.functions.count) functions"
                         + (file.branchesFound > 0 ? " · \(file.branchesHit)/\(file.branchesFound) branches" : ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open in Xcode") { model.openInXcode(file: file.path, line: file.uncoveredRanges.first?.lowerBound ?? 1) }
            }
            .padding(10)
            Divider()
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, text in
                        let hits = file.lines[index + 1]
                        HStack(spacing: 0) {
                            Text("\(index + 1)").foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                            Text(hits.map { $0 > 0 ? "\($0)×" : "0" } ?? "")
                                .foregroundStyle(hits == 0 ? Color.red : Color.secondary)
                                .frame(width: 52, alignment: .trailing)
                                .padding(.trailing, 8)
                            Text(text.isEmpty ? " " : text)
                        }
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(hits == nil ? Color.clear : hits! > 0 ? Color.green.opacity(0.12) : Color.red.opacity(0.18))
                        .onTapGesture(count: 2) { model.openInXcode(file: file.path, line: index + 1) }
                    }
                }
                .padding(.vertical, 4)
                .textSelection(.enabled)
            }
        }
    }
}
