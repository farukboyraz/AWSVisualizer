import SwiftUI

/// A circular, dark-red "X" button meant for the top corner of a sheet or
/// popover. By default tapping it asks for a Yes/No confirmation first
/// (for "your changes weren't applied" style warnings) before running
/// `action` - every piece of copy is supplied by the caller so this stays
/// screen-agnostic and localizable rather than baking in one screen's
/// wording. Pass `requiresConfirmation: false` to reuse just the look
/// (circular, dark red, white X) without the dialog, for a plain close
/// button elsewhere.
struct ConfirmingCloseButton: View {
    var requiresConfirmation: Bool = true
    var confirmationTitle: String = ""
    var confirmationMessage: String = ""
    var confirmButtonTitle: String = ""
    var cancelButtonTitle: String = ""
    var action: () -> Void

    @State private var showConfirmation = false

    var body: some View {
        Button {
            if requiresConfirmation {
                showConfirmation = true
            } else {
                action()
            }
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Color(red: 0.72, green: 0.09, blue: 0.09), in: Circle())
        }
        .buttonStyle(.plain)
        .confirmationDialog(confirmationTitle, isPresented: $showConfirmation, titleVisibility: .visible) {
            Button(confirmButtonTitle, role: .destructive) { action() }
            Button(cancelButtonTitle, role: .cancel) {}
        } message: {
            Text(confirmationMessage)
        }
    }
}
