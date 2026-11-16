import SwiftUI

struct ProfilePopover: View {
    var onOpenSettings: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api
    @Environment(\.dismiss) private var dismiss

    @State private var showLogoutConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                AccountInfoSection()

                Divider()

                ProfilePicker()
                RegionPicker()

                Divider()

                LanguagePicker()
                AppearancePicker()

                PlatformsSection(compact: true)

                AccessibleEnvironmentsSection(environments: appState.accessibleEnvironments, allowsEditing: false)

                Divider()

                Button {
                    onOpenSettings()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .buttonStyle(.borderless)

                Button(role: .destructive) {
                    showLogoutConfirmation = true
                } label: {
                    Label("Logout", systemImage: "rectangle.portrait.and.arrow.right")
                }
                .buttonStyle(.borderless)
                .confirmationDialog("Are you sure you want to logout?", isPresented: $showLogoutConfirmation) {
                    Button("Logout", role: .destructive) {
                        Task { await performLogout() }
                    }
                    Button("Cancel", role: .cancel) {}
                }
            }
            .padding()
        }
        .frame(width: 320)
        .frame(maxHeight: 520)
        .task {
            await loadAccessibleEnvironments()
        }
    }

    private func performLogout() async {
        do {
            try await api.logout()
        } catch {
            // continue with local logout regardless
        }
        appState.isAuthenticated = false
        appState.callerIdentity = nil
        appState.screen = .boot
    }

    private func loadAccessibleEnvironments() async {
        if let environments = try? await api.getAccessibleEnvironments() {
            appState.accessibleEnvironments = environments
        }
    }
}
