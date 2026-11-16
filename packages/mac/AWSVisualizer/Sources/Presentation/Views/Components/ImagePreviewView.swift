import SwiftUI
import AppKit

/// Image preview (png, jpeg, gif, webp, bmp, tiff, heic, ico…) for S3
/// objects, archive entries and CodeCommit files. Fits the image in the
/// pane (never upscaled past its own size); "Actual size" toggles 1:1 with
/// scrolling. GIFs animate.
struct ImagePreviewView: View {
    let data: Data

    @State private var actualSize = false

    var body: some View {
        if let image = NSImage(data: data) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    let pixels = image.representations.first.map { "\($0.pixelsWide) × \($0.pixelsHigh) px" } ?? ""
                    Text("\(pixels) · \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer()
                    Toggle("Actual size", isOn: $actualSize)
                        .toggleStyle(.button)
                        .controlSize(.small)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                Divider()
                Group {
                    if actualSize {
                        ScrollView([.horizontal, .vertical]) {
                            AnimatedImageView(image: image)
                                .frame(width: image.size.width, height: image.size.height)
                                .padding()
                        }
                    } else {
                        AnimatedImageView(image: image)
                            .frame(maxWidth: image.size.width, maxHeight: image.size.height)
                            .aspectRatio(image.size, contentMode: .fit)
                            .padding()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .background(checkerboard)
            }
        } else {
            EmptyStateView(message: "This image format can't be shown")
        }
    }

    /// Light checkerboard so transparent PNG/GIF areas are visible.
    private var checkerboard: some View {
        Canvas { context, size in
            let tile: CGFloat = 10
            for row in 0..<Int(size.height / tile) + 1 {
                for col in 0..<Int(size.width / tile) + 1 where (row + col) % 2 == 0 {
                    context.fill(Path(CGRect(x: CGFloat(col) * tile, y: CGFloat(row) * tile, width: tile, height: tile)), with: .color(.secondary.opacity(0.08)))
                }
            }
        }
    }
}

/// NSImageView so animated GIFs play (SwiftUI's `Image` shows frame one).
private struct AnimatedImageView: NSViewRepresentable {
    let image: NSImage

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.animates = true
        view.image = image
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        if view.image !== image { view.image = image }
    }
}
