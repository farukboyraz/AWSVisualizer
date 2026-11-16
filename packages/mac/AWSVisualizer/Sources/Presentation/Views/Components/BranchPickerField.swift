import SwiftUI

/// A branch picker that opens `BranchTreeView` in a popover instead of a
/// flat dropdown menu - so picking a branch out of `features/asd`-style
/// names goes through the same searchable folder tree as the Branches tab,
/// rather than a long flat list of full paths. Used anywhere CodeCommit
/// needs the user to choose one branch (New Pull Request's source/
/// destination, Compare Branches' base/compare).
struct BranchPickerField: View {
    let branches: [CodeCommitBranch]
    let defaultBranch: String
    @Binding var selection: String

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(.secondary)
                Text(selection.isEmpty ? "Select a branch" : selection)
                    .foregroundStyle(selection.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented) {
            BranchTreeView(
                branches: branches,
                defaultBranch: defaultBranch,
                selectedBranchName: selection,
                onSelect: { branch in
                    selection = branch.name
                    isPresented = false
                }
            )
            .frame(width: 320, height: 360)
        }
    }
}
