import SwiftUI
import AppKit

// MARK: - Step model

enum InstallStepStatus: String {
    case pending, running, installed, already, failed
}

/// One row of an install screen: a service's npm install, or a Node.js
/// install step (download, verify, extract...).
struct InstallStepItem: Identifiable, Equatable {
    let id: String
    var title: String
    var detail: String?
    var status: InstallStepStatus
    var output: String = ""
    var error: String?
    /// Copy-pasteable terminal equivalent.
    var command: String?
    var progress: Double?
}

extension InstallStepItem {
    init(_ step: PackageInstallStep) {
        self.init(
            id: step.service,
            title: step.name,
            detail: step.packages.joined(separator: ", "),
            status: InstallStepStatus(rawValue: step.status) ?? .pending,
            output: step.output,
            error: step.error,
            command: step.command
        )
    }

    init(failure: PackageFailureRecord, name: String) {
        self.init(id: failure.service, title: name, detail: failure.packages.joined(separator: ", "), status: .failed, output: failure.output, error: failure.error, command: failure.command)
    }
}

/// Client-side steps (Node.js download, core npm install) with live output.
@Observable
@MainActor
final class TaskLog {
    var steps: [InstallStepItem] = []
    var isRunning = false

    private static let outputLimit = 200_000

    var currentOutput: String { steps.last?.output ?? "" }

    func reset() {
        steps = []
        isRunning = true
    }

    func begin(_ id: String, _ title: String) {
        steps.append(InstallStepItem(id: id, title: title, status: .running))
    }

    func append(_ text: String) {
        guard !steps.isEmpty else { return }
        var out = steps[steps.count - 1].output + text
        if out.count > Self.outputLimit { out = "…\n" + out.suffix(Self.outputLimit) }
        steps[steps.count - 1].output = out
    }

    func setProgress(_ value: Double?, detail: String?) {
        guard !steps.isEmpty else { return }
        steps[steps.count - 1].progress = value
        steps[steps.count - 1].detail = detail
    }

    func finish() {
        guard !steps.isEmpty else { return }
        steps[steps.count - 1].status = .installed
        steps[steps.count - 1].progress = nil
    }

    /// Marks the running step failed (or adds one) and stops.
    func fail(_ message: String, command: String?) {
        if let i = steps.lastIndex(where: { $0.status == .running }) {
            steps[i].status = .failed
            steps[i].error = message
            steps[i].command = command
            steps[i].progress = nil
        } else {
            steps.append(InstallStepItem(id: UUID().uuidString, title: "Install", status: .failed, error: message, command: command))
        }
        isRunning = false
    }

    func done() { isRunning = false }

    /// The most useful `npm error` line of an npm run.
    static func npmErrorSummary(_ output: String) -> String? {
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let errs = lines.filter { $0.hasPrefix("npm error") || $0.hasPrefix("npm ERR!") }
            .map { $0.replacingOccurrences(of: "npm error", with: "").replacingOccurrences(of: "npm ERR!", with: "").trimmingCharacters(in: .whitespaces) }
        let skip = ["code ", "syscall ", "errno ", "path ", "at ", "{", "}", "A complete log", "Log files"]
        return errs.first { line in !line.isEmpty && !skip.contains { line.hasPrefix($0) } }
    }
}

// MARK: - Shared views

/// Terminal-style output. Every line is kept; new output is appended (the
/// text isn't redrawn, so nothing jumps) and the view only follows the end
/// while the user is scrolled to the bottom - scroll up to read and it
/// stays put.
struct CommandLogView: View {
    let text: String
    var minHeight: CGFloat = 140

    var body: some View {
        TerminalTextView(text: text.isEmpty ? "Waiting for output…" : text)
            .frame(minHeight: minHeight)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct TerminalTextView: NSViewRepresentable {
    let text: String

    final class Coordinator {
        var shown = ""
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor.black.withAlphaComponent(0.85)
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        if let tv = scroll.documentView as? NSTextView {
            tv.isEditable = false
            tv.isSelectable = true
            tv.isRichText = false
            tv.drawsBackground = false
            tv.textContainerInset = NSSize(width: 8, height: 8)
            tv.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            tv.textColor = NSColor.white.withAlphaComponent(0.9)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView, let storage = tv.textStorage else { return }
        let coordinator = context.coordinator
        guard text != coordinator.shown else { return }

        // At the bottom (within a couple of lines) before this update?
        let visible = scroll.contentView.bounds
        let atBottom = visible.maxY >= tv.frame.height - 24

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.9),
        ]
        if !coordinator.shown.isEmpty, text.hasPrefix(coordinator.shown) {
            storage.append(NSAttributedString(string: String(text.dropFirst(coordinator.shown.count)), attributes: attributes))
        } else {
            // Another step selected (or the output was trimmed): redraw, keep the scroll position.
            let origin = visible.origin
            storage.setAttributedString(NSAttributedString(string: text, attributes: attributes))
            if !atBottom { scroll.contentView.scroll(to: origin) }
        }
        coordinator.shown = text
        if atBottom { tv.scrollToEndOfDocument(nil) }
    }
}

/// A command with a Copy button.
struct CopyableCommandView: View {
    let command: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Run it yourself in Terminal").font(.caption.bold())
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
            Text(command)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color.secondary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}

struct InstallStatusIcon: View {
    let status: InstallStepStatus

    var body: some View {
        Group {
            switch status {
            case .pending: Image(systemName: "circle").foregroundStyle(.tertiary)
            case .running: ProgressView().controlSize(.mini)
            case .installed: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .already: Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
            case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            }
        }
        .frame(width: 14, height: 14)
    }
}

/// Spinner at the top while running; when finished a green check with how
/// many were installed (orange warning when something failed). Below:
/// every step with its status, and one continuous terminal with every
/// step's commands and output in order (two blank lines between steps).
/// Failed rows open the error screen.
struct InstallProgressPanel: View {
    let title: String
    let steps: [InstallStepItem]
    let isRunning: Bool
    /// What the counts are of ("services", "steps").
    var noun: String = "services"
    /// Replaces "N services installed" when everything succeeded (e.g. "Node.js 22.x installed").
    var successTitle: String?
    var onRetry: ((InstallStepItem) -> Void)?

    @State private var errorItem: InstallStepItem?

    private var installed: Int { steps.filter { $0.status == .installed }.count }
    private var already: Int { steps.filter { $0.status == .already }.count }
    private var failed: Int { steps.filter { $0.status == .failed }.count }
    private var finished: Int { steps.filter { $0.status != .pending && $0.status != .running }.count }

    /// Started steps' output, in order. Only grows while steps run (earlier
    /// steps are finished), so the terminal just appends.
    private var terminalText: String {
        var out = ""
        for step in steps where step.status != .pending && !step.output.isEmpty {
            if !out.isEmpty { out += out.hasSuffix("\n") ? "\n\n" : "\n\n\n" }
            out += step.output
        }
        return out
    }

    var body: some View {
        VStack(spacing: 12) {
            header
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                        row(step, index: index + 1)
                    }
                }
            }
            .frame(maxHeight: 130)
            VStack(alignment: .leading, spacing: 4) {
                Text("Terminal").font(.caption).foregroundStyle(.secondary)
                CommandLogView(text: terminalText, minHeight: 220)
                    .frame(maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
        }
        .sheet(item: $errorItem) { item in
            InstallErrorView(item: item, onRetry: onRetry.map { retry in { errorItem = nil; retry(item) } }) {
                errorItem = nil
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        VStack(spacing: 6) {
            if isRunning {
                ProgressView().controlSize(.large)
                Text(title).font(.headline)
                Text("\(finished) of \(steps.count) \(noun) done").font(.caption).foregroundStyle(.secondary)
            } else if failed == 0 {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 40)).foregroundStyle(.green)
                Text(successTitle ?? "\(installed) \(noun) installed").font(.headline)
                if already > 0 { Text("\(already) already installed").font(.caption).foregroundStyle(.secondary) }
            } else {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 40)).foregroundStyle(.orange)
                Text("\(installed) \(noun) installed, \(failed) failed").font(.headline)
                Text("Select a failed row to see the error and retry.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func row(_ step: InstallStepItem, index: Int) -> some View {
        Button {
            if step.status == .failed { errorItem = step }
        } label: {
            HStack(spacing: 8) {
                Text("\(index).").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary).frame(width: 20, alignment: .trailing)
                InstallStatusIcon(status: step.status)
                Text(step.title).font(.caption)
                if let detail = step.detail {
                    Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                if let p = step.progress {
                    ProgressView(value: p).controlSize(.mini).frame(maxWidth: 120)
                }
                Spacer(minLength: 4)
                switch step.status {
                case .already: Text("Already installed").font(.caption2).foregroundStyle(.secondary)
                case .failed:
                    Label("View error", systemImage: "chevron.right").labelStyle(.titleAndIcon).font(.caption2).foregroundStyle(.red)
                default: EmptyView()
                }
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 6)
            .background(step.status == .running ? Color.accentColor.opacity(0.12) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// What went wrong, the npm output, a command to run by hand, and Retry.
struct InstallErrorView: View {
    let item: InstallStepItem
    var onRetry: (() -> Void)?
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "xmark.octagon.fill").font(.title).foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(item.title) could not be installed").font(.title3.bold())
                    if let detail = item.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                }
            }
            Text(item.error ?? "The install failed.")
                .font(.callout)
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text("Check your internet connection (and proxy / npm registry settings), then retry. You can also run the same command in Terminal - the app picks the package up as soon as it's installed.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let command = item.command { CopyableCommandView(command: command) }
            VStack(alignment: .leading, spacing: 4) {
                Text("Output").font(.caption.bold())
                CommandLogView(text: item.output, minHeight: 180)
            }
            HStack {
                Spacer()
                SecondaryButton("Close", action: onClose)
                if let onRetry {
                    RefreshButton("Retry", action: onRetry)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 640)
    }
}

// MARK: - Service package installs (sidecar jobs)

/// Starts a job on the sidecar and polls it until it finishes.
@Observable
@MainActor
final class PackageInstallController {
    var job: PackageInstallJob?
    var error: String?
    private var pollTask: Task<Void, Never>?

    var steps: [InstallStepItem] { job?.steps.map(InstallStepItem.init) ?? [] }
    var isRunning: Bool { job?.isRunning ?? (error == nil) }

    func start(_ services: [String], api: APIService, onFinished: @escaping @MainActor (PackageInstallJob) -> Void = { _ in }) {
        pollTask?.cancel()
        job = nil
        error = nil
        pollTask = Task {
            do {
                var current = try await api.installServicePackages(services)
                job = current
                while current.isRunning, !Task.isCancelled {
                    try await Task.sleep(nanoseconds: 600_000_000)
                    current = try await api.getInstallJob(current.id)
                    job = current
                }
                onFinished(current)
            } catch is CancellationError {
            } catch {
                self.error = error.friendlyMessage
            }
        }
    }

    func cancelPolling() { pollTask?.cancel() }
}

/// The install popup (Settings › Services "Install", the service screen's
/// Install, Retry from an error): spinner on top while it runs, then the
/// result. Retrying a failed row starts a new job for that service in the
/// same popup.
struct PackageInstallSheet: View {
    let services: [String]
    var onFinished: () -> Void = {}
    var onClose: () -> Void

    @Environment(\.apiService) private var api
    @Environment(AppState.self) private var appState
    @State private var controller = PackageInstallController()

    var body: some View {
        VStack(spacing: 14) {
            InstallProgressPanel(title: "Installing packages…", steps: controller.steps, isRunning: controller.isRunning, onRetry: { item in run([item.id]) })
            if let error = controller.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                if controller.isRunning {
                    Text("You can close this window - the install keeps running.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                SecondaryButton(controller.isRunning ? "Hide" : "Close") {
                    controller.cancelPolling()
                    onClose()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 640, height: 600)
        .onAppear { run(services) }
    }

    private func run(_ ids: [String]) {
        controller.start(ids, api: api) { _ in
            Task {
                await appState.reloadServiceCatalog(using: api)
                onFinished()
            }
        }
    }
}

extension AppState {
    /// Re-reads the catalog (package install state lives on each entry).
    @MainActor
    func reloadServiceCatalog(using api: APIService) async {
        if let catalog = try? await api.getServiceCatalog() { serviceCatalog = catalog }
    }
}
