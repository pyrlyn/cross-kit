import SwiftUI
import CrossKitCore

struct TestResultsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedRun: UUID?
    @State private var selectedTest: String?

    var body: some View {
        HSplitView {
            List(model.testRuns, selection: $selectedRun) { run in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Image(systemName: run.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(run.succeeded ? .green : .red)
                        if let path = run.filePath { FileIconView(path: path, size: 16) } else { FileIconView(language: run.language, size: 16) }
                        Text("\(run.language.displayName) · \((run.filePath as NSString?)?.lastPathComponent ?? "")")
                            .fontWeight(.medium)
                    }
                    Text(run.summary).font(.caption).foregroundStyle(.secondary)
                    Text(run.startedAt, style: .time).font(.caption2).foregroundStyle(.tertiary)
                }
                .tag(run.id)
            }
            .frame(minWidth: 240, idealWidth: 280)
            .overlay {
                if model.testRuns.isEmpty {
                    Text("No test runs yet.\nUse Editor › CrossKit › Run Tests in File in Xcode.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
            }

            if let run = model.testRuns.first(where: { $0.id == (selectedRun ?? model.testRuns.first?.id) }) {
                RunDetail(run: run, selectedTest: $selectedTest)
                    .frame(minWidth: 460)
            } else {
                Text("Select a run").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct RunDetail: View {
    let run: TestRunResult
    @Binding var selectedTest: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(run.summary).font(.headline)
            Text(run.command).font(.caption.monospaced()).textSelection(.enabled).lineLimit(3)
            Text("in \(run.workingDirectory)").font(.caption).foregroundStyle(.secondary)
            if let warning = run.warning {
                Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption)
            }
            Table(run.tests, selection: $selectedTest) {
                TableColumn("") { test in
                    Image(systemName: icon(test.status)).foregroundStyle(color(test.status))
                }
                .width(18)
                TableColumn("Test", value: \.name)
                TableColumn("Time") { test in
                    Text(test.duration.map { String(format: "%.3fs", $0) } ?? "–").monospacedDigit()
                }
                .width(70)
                TableColumn("Location") { test in
                    if let file = test.file, let line = test.line {
                        HStack(spacing: 4) {
                        FileIconView(path: file, size: 14)
                        Button("\((file as NSString).lastPathComponent):\(line + 1)") {
                            XcodeDocumentLocator.open(BridgeLocation(path: file, range: BridgeRange(
                                startLine: line, startCharacter: 0, endLine: line, endCharacter: 0)))
                        }
                        .buttonStyle(.link)
                        }
                    } else {
                        Text("–")
                    }
                }
                .width(160)
            }
            .frame(minHeight: 140)
            Text(selectedTest == nil ? "Runner output" : "Output of \(selectedTest!)").font(.subheadline)
            ScrollView {
                Text(outputText)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 120)
        }
        .padding()
    }

    private var outputText: String {
        if let name = selectedTest, let test = run.tests.first(where: { $0.name == name }) {
            return test.output ?? "(no output captured for this test)"
        }
        return run.output.isEmpty ? "(no output)" : run.output
    }

    private func icon(_ status: TestStatus) -> String {
        switch status {
        case .passed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .skipped: return "minus.circle"
        }
    }

    private func color(_ status: TestStatus) -> Color {
        switch status {
        case .passed: return .green
        case .failed: return .red
        case .skipped: return .gray
        }
    }
}
