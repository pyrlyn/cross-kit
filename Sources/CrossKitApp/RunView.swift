import SwiftUI
import AppKit
import CrossKitCore

/// Output of Build Project and Run File, with Stop for programs that keep running.
@MainActor
enum RunWindow {
    private static var window: NSWindow?
    static let selection = RunSelection()

    static func show(model: AppModel, select id: String? = nil) {
        if let id { selection.id = id }
        if window == nil {
            let hosting = NSHostingController(rootView: RunView().environmentObject(model).environmentObject(selection))
            let w = NSWindow(contentViewController: hosting)
            w.title = "CrossKit Run"
            w.setContentSize(NSSize(width: 900, height: 560))
            w.styleMask.insert([.resizable, .miniaturizable])
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("CrossKitRun")
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
final class RunSelection: ObservableObject {
    @Published var id: String?
}

struct RunView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var selection: RunSelection

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(model.programRuns, selection: $selection.id) { run in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(run.title).fontWeight(.medium).lineLimit(1)
                        HStack(spacing: 4) {
                            Circle().fill(color(run.state)).frame(width: 7, height: 7)
                            Text("\(run.mode == .build ? "Build" : "Run") · \(label(run))")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .tag(run.id)
                }
                .overlay {
                    if model.programRuns.isEmpty {
                        Text("Nothing has run yet.\nUse Editor › CrossKit › Run File or Build Project in Xcode.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                            .padding()
                    }
                }
                Divider()
                HStack {
                    Button("Clear Finished") { model.clearFinishedRuns() }
                        .disabled(!model.programRuns.contains { !$0.state.isActive })
                    Spacer()
                }
                .padding(8)
            }
            .frame(minWidth: 220, idealWidth: 260, maxWidth: 360)

            if let run = model.programRuns.first(where: { $0.id == selection.id }) ?? model.programRuns.first {
                ProgramRunDetail(run: run)
            } else {
                Text("Select a run.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func label(_ run: ProgramRun) -> String {
        switch run.state {
        case .building: return "building…"
        case .running: return "running"
        case .succeeded: return run.mode == .run ? "exited 0" : "succeeded"
        case .failed: return run.exitCode.map { "exited \($0)" } ?? "failed"
        case .stopped: return "stopped"
        }
    }

    private func color(_ state: ProgramRun.State) -> Color {
        switch state {
        case .building, .running: return .yellow
        case .succeeded: return .green
        case .failed: return .red
        case .stopped: return .gray
        }
    }
}

struct ProgramRunDetail: View {
    let run: ProgramRun
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                FileIconView(language: run.language, size: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.title).font(.headline)
                    Text("\(run.language.displayName)\(run.target.map { " · \($0)" } ?? "") · \(run.projectRoot)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if run.state.isActive {
                    ProgressView().controlSize(.small)
                    Button("Stop") { model.stopRun(run.id) }
                }
            }
            if let error = run.error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(run.output.isEmpty ? " " : run.output)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(6)
                    Color.clear.frame(height: 1).id("end")
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: run.output) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            }
        }
        .padding(12)
        .frame(minWidth: 480)
    }
}
