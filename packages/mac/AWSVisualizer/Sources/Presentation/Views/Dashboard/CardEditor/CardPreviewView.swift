import SwiftUI

/// The data under the card editor: what the current selection points at
/// (a folder's contents, matching items, the commits a PR would bring…),
/// shown whether it has rows or is empty.
struct CardPreviewView: View {
    enum Phase: Equatable {
        case waiting
        case loading
        case loaded(CardPreview)
        case failed(String)
        case unavailable
    }

    let state: Phase
    let language: AppLanguage
    var onReload: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(language.cardStepPreview, systemImage: "eye").font(.headline)
                Spacer()
                if case .loaded = state { Button(action: onReload) { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless) }
                if case .failed = state { Button(action: onReload) { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless) }
            }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder private var content: some View {
        switch state {
        case .waiting:
            message(language.cardPreviewWaiting, icon: "hand.point.up.left")
        case .unavailable:
            message(language.cardPreviewNone, icon: "eye.slash")
        case .loading:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(language.cardPreviewLoading).foregroundStyle(.secondary) }
                .frame(maxWidth: .infinity, minHeight: 60)
        case .failed(let error):
            Label(error, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        case .loaded(let preview):
            VStack(alignment: .leading, spacing: 6) {
                Text(preview.title(language)).font(.callout.weight(.semibold)).lineLimit(2)
                if preview.rows.isEmpty {
                    message(preview.emptyMessage(language), icon: "tray")
                } else {
                    table(preview)
                }
                if preview.more == true { Text(language.cardPreviewMore).font(.caption).foregroundStyle(.secondary) }
                if let note = preview.note { Text(note(language)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
        }
    }

    private func message(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 50)
    }

    /// A compact grid; long cells are cut and shown whole on hover.
    private func table(_ preview: CardPreview) -> some View {
        ScrollView([.horizontal, .vertical]) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow {
                    ForEach(Array(preview.columns.enumerated()), id: \.offset) { _, column in
                        Text(column(language)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
                Divider()
                ForEach(Array(preview.rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(cell)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1)
                                .frame(maxWidth: 260, alignment: .leading)
                                .help(cell)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxHeight: 240)
    }
}
