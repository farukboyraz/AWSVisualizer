import SwiftUI

/// Shown instead of a service screen whose npm packages aren't installed:
/// what's missing, an Install button (progress popup), the last recorded
/// error if an install failed, and the terminal command.
struct ServicePackageMissingView: View {
    let entry: AWSServiceCatalogEntry

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api
    @State private var state: ServicePackagesState?
    @State private var failure: PackageFailureRecord?
    @State private var installing = false
    @State private var showError = false

    var body: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)
            ServiceIcon(entry: entry)
                .font(.system(size: 40))
            Text("\(entry.name) isn't installed yet").font(.title2.bold())
            Text("This service needs its AWS SDK npm packages. Installing takes a few seconds and doesn't restart the app.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            if let state {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(state.packages, id: \.name) { p in
                        HStack {
                            Image(systemName: p.installed == nil ? "circle" : "checkmark.circle.fill")
                                .foregroundStyle(p.installed == nil ? Color.secondary : Color.green)
                            Text(p.name).font(.system(.caption, design: .monospaced))
                            Spacer()
                            Text(p.installed ?? p.required).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: 460)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            if let failure {
                Button {
                    showError = true
                } label: {
                    Label("Last install failed: \(failure.error)", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .lineLimit(2)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .frame(maxWidth: 460)
            }
            NewButton("Install \(entry.name)", systemImage: "arrow.down.circle") { installing = true }
            if let state {
                CopyableCommandView(command: state.command).frame(maxWidth: 560)
            }
            Spacer(minLength: 0)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: entry) { await load() }
        .sheet(isPresented: $installing) {
            PackageInstallSheet(services: [entry.id]) { installing = false }
        }
        .sheet(isPresented: $showError) {
            if let failure {
                InstallErrorView(item: InstallStepItem(failure: failure, name: entry.name), onRetry: {
                    showError = false
                    installing = true
                }) { showError = false }
            }
        }
    }

    private func load() async {
        guard let status = try? await api.getPackagesStatus() else { return }
        state = status.services[entry.id]
        failure = status.failures[entry.id]
        // Installed meanwhile (Terminal, another service sharing the package).
        if state?.installed == true { await appState.reloadServiceCatalog(using: api) }
    }
}
