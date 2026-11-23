import SwiftUI
import AppKit
import CrossKitCore

/// The Debugger window is an AppKit window so the host can bring it up from a bridge request
/// even when no SwiftUI scene is open.
@MainActor
enum DebuggerWindow {
    private static var window: NSWindow?
    static let selection = DebuggerSelection()

    static func show(model: AppModel, select id: String? = nil) {
        if let id { selection.id = id }
        if window == nil {
            let hosting = NSHostingController(rootView: DebuggerView().environmentObject(model).environmentObject(selection))
            let w = NSWindow(contentViewController: hosting)
            w.title = "CrossKit Debugger"
            w.setContentSize(NSSize(width: 980, height: 620))
            w.styleMask.insert([.resizable, .miniaturizable])
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("CrossKitDebugger")
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
final class DebuggerSelection: ObservableObject {
    @Published var id: String?
}

struct DebuggerView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var selection: DebuggerSelection

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(model.debugSessions, selection: $selection.id) { session in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            FileIconView(language: session.language, size: 16)
                            Text(session.title).fontWeight(.medium)
                        }
                        HStack(spacing: 4) {
                            Circle().fill(color(session.state)).frame(width: 7, height: 7)
                            Text("\(session.language.displayName) · \(stateLabel(session.state))")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .tag(session.id)
                }
                .overlay {
                    if model.debugSessions.isEmpty {
                        Text("No debug sessions.\nUse Editor › CrossKit › Debug File at Cursor in Xcode.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                            .padding()
                    }
                }
                Divider()
                HStack {
                    Button("Clear Finished") { model.clearFinishedSessions() }
                    Spacer()
                }
                .padding(6)
            }
            .frame(minWidth: 220, idealWidth: 260, maxWidth: 360)

            if let id = selection.id, let session = model.debugSessions.first(where: { $0.id == id }) {
                SessionDetail(session: session)
                    .frame(minWidth: 520)
            } else {
                Text("Select a session").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func stateLabel(_ state: DebugSessionState) -> String {
        switch state {
        case .building: return "building"
        case .starting: return "starting"
        case .running: return "running"
        case .stopped: return "paused"
        case .waitingForDebugger: return "waiting for debugger"
        case .external: return "in Terminal"
        case .exited: return "exited"
        case .failed: return "failed"
        }
    }

    private func color(_ state: DebugSessionState) -> Color {
        switch state {
        case .running, .external: return .green
        case .stopped, .waitingForDebugger, .starting, .building: return .orange
        case .exited: return .gray
        case .failed: return .red
        }
    }
}

struct SessionDetail: View {
    let session: DebugSessionSnapshot
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    FileIconView(language: session.language, size: 22)
                    Text(session.title).font(.title3).fontWeight(.semibold)
                }
                Text("\(session.debugger.displayName) · \(session.program)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                if let reason = session.stopReason, session.state == .stopped {
                    Text("Paused: \(reason)").font(.caption).foregroundStyle(.orange)
                }
                if let code = session.exitCode, session.state == .exited {
                    Text("Exited with code \(code)").font(.caption).foregroundStyle(code == 0 ? Color.secondary : Color.red)
                }
                if let error = session.error {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
            }

            HStack {
                Button { model.perform(.resume, on: session.id) } label: { Label("Continue", systemImage: "play.fill") }
                    .disabled(!session.canContinue).keyboardShortcut("y", modifiers: [.command, .control])
                Button { model.perform(.stepOver, on: session.id) } label: { Label("Step Over", systemImage: "arrow.turn.down.right") }
                    .disabled(!session.canStep)
                Button { model.perform(.stepIn, on: session.id) } label: { Label("Step Into", systemImage: "arrow.down.to.line") }
                    .disabled(!session.canStep)
                Button { model.perform(.stepOut, on: session.id) } label: { Label("Step Out", systemImage: "arrow.up.to.line") }
                    .disabled(!session.canStep)
                Button { model.perform(.pause, on: session.id) } label: { Label("Pause", systemImage: "pause.fill") }
                    .disabled(!session.canPause)
                Spacer()
                Button(role: .destructive) { model.perform(.stop, on: session.id) } label: { Label("Stop", systemImage: "stop.fill") }
                    .disabled(!session.canStop)
            }
            .labelStyle(.titleAndIcon)

            if session.debugger.isJVM, let address = session.jdwpAddress {
                GroupBox("JDWP") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("The JVM listens on \(address) and waits (suspend=y) until a debugger attaches.")
                        HStack {
                            Text(session.attachCommand ?? "jdb -attach \(address)").font(.caption.monospaced()).textSelection(.enabled)
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(session.attachCommand ?? "jdb -attach \(address)", forType: .string)
                            }
                        }
                        Text("IntelliJ IDEA: Run › Edit Configurations › + › Remote JVM Debug, host 127.0.0.1, port \(address.split(separator: ":").last ?? "").")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if session.debugger == .nodeAttach, let address = session.jdwpAddress {
                GroupBox("Node.js inspector") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Node.js listens on \(address) and waits (--inspect-brk) until a debugger attaches.")
                        HStack {
                            Text(session.attachCommand ?? "node inspect \(address)").font(.caption.monospaced()).textSelection(.enabled).lineLimit(4)
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(session.attachCommand ?? "node inspect \(address)", forType: .string)
                            }
                        }
                        Text("Chrome: open chrome://inspect › Configure… › add \(address). VS Code: a launch configuration of type \"node\", request \"attach\", port \(address.split(separator: ":").last ?? "").")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if session.debugger == .nodeInspect, session.state == .external || session.state == .waitingForDebugger {
                Text("node inspect runs in a Terminal window; use its commands there (`cont`, `next`, `step`, `out`, `repl`, `bt`, `sb(file, line)`).")
                    .font(.caption).foregroundStyle(.secondary)
            } else if session.state == .external {
                Text("lldb runs in a Terminal window; use lldb commands there (`continue`, `next`, `step`, `frame variable`, `bt`).")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if session.debugger.isControlled {
                HSplitView {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Call Stack").font(.headline)
                        List(session.frames) { frame in
                            Button {
                                if let file = frame.file, let line = frame.line { model.openInXcode(file: file, line: line) }
                            } label: {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(frame.name).lineLimit(1)
                                    if let file = frame.file {
                                        Text("\((file as NSString).lastPathComponent):\(frame.line ?? 0)")
                                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(frame.file == nil)
                        }
                    }
                    .frame(minWidth: 220)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Variables").font(.headline)
                        Table(session.variables) {
                            TableColumn("Name", value: \.name)
                            TableColumn("Value") { Text($0.value).textSelection(.enabled) }
                            TableColumn("Type") { Text($0.type ?? "") }
                        }
                    }
                    .frame(minWidth: 260)
                }
                .frame(minHeight: 200)
            }

            Text("Output").font(.headline)
            ScrollView {
                Text(session.output.isEmpty ? " " : session.output)
                    .font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(minHeight: 100)
            .background(Color(nsColor: .textBackgroundColor))
        }
        .padding(12)
    }
}
