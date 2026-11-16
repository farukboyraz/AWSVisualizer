import SwiftUI

enum LoadState<Value> {
    case loading
    case loaded(Value)
    case empty
    case failed(String)
}

extension LoadState {
    /// Finished loading - with data or with an empty result.
    var isSettled: Bool {
        switch self {
        case .loaded, .empty: return true
        case .loading, .failed: return false
        }
    }
}

struct LoadableContent<Value, Content: View>: View {
    private let state: LoadState<Value>
    private let retry: (() -> Void)?
    private let cancel: (() -> Void)?
    private let emptyMessage: String
    /// Minimum height for the loading/empty/failed placeholder only - never
    /// applied to `.loaded` content, so real content keeps its natural
    /// top-aligned flow instead of being centered in the available height.
    private let minHeight: CGFloat?
    private let content: (Value) -> Content

    init(
        _ state: LoadState<Value>,
        retry: (() -> Void)? = nil,
        cancel: (() -> Void)? = nil,
        emptyMessage: String = "No data available",
        minHeight: CGFloat? = nil,
        @ViewBuilder content: @escaping (Value) -> Content
    ) {
        self.state = state
        self.retry = retry
        self.cancel = cancel
        self.emptyMessage = emptyMessage
        self.minHeight = minHeight
        self.content = content
    }

    var body: some View {
        Group {
            switch state {
            case .loading:
                BrandedLoader(cancel: cancel)
            case .loaded(let value):
                content(value)
            case .empty:
                EmptyStateView(message: emptyMessage)
            case .failed(let message):
                ErrorStateView(message: message, retry: retry)
            }
        }
        .frame(maxWidth: .infinity, minHeight: isLoadedState ? nil : minHeight, maxHeight: .infinity)
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
        .animation(.easeInOut(duration: 0.25), value: stateTag)
    }

    private var isLoadedState: Bool {
        if case .loaded = state { return true }
        return false
    }

    private var stateTag: Int {
        switch state {
        case .loading: 0
        case .loaded: 1
        case .empty: 2
        case .failed: 3
        }
    }
}

struct BrandedLoader: View {
    var message: String? = nil
    var cancel: (() -> Void)? = nil

    @State private var pulse = false

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            HStack {
                Spacer(minLength: 0)
                VStack(spacing: 16) {
                    AWSBrandMark(size: 64)
                        .scaleEffect(pulse ? 1.1 : 0.9)
                        .opacity(pulse ? 1 : 0.5)
                        .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: pulse)
                        .onAppear { pulse = true }

                    if let message {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    if let cancel {
                        SecondaryButton("Cancel", action: cancel)
                    }
                }
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The app's brand mark - the same cloud/aws/nodes artwork as the Dock
/// icon (`Sources/Resources/awsvis.png`, bundled via `Bundle.module` since
/// it already has "aws" baked into the image, no separate wordmark overlay
/// needed).
struct AWSBrandMark: View {
    var size: CGFloat = 40

    /// From the app's Resources (copied by start-mac.js), else the SwiftPM
    /// resource bundle next to the executable - looked up by path, because
    /// `Bundle.module` stops the app when its bundle isn't where the build left it.
    private static let image: NSImage? = {
        if let url = Bundle.main.url(forResource: "awsvis", withExtension: "png") { return NSImage(contentsOf: url) }
        let names = ["AWSVisualizer_AWSVisualizer.bundle"]
        let roots = [Bundle.main.resourceURL, Bundle.main.bundleURL, Bundle.main.executableURL?.deletingLastPathComponent()].compactMap { $0 }
        for root in roots {
            for name in names {
                if let bundle = Bundle(url: root.appendingPathComponent(name)),
                   let url = bundle.url(forResource: "awsvis", withExtension: "png", subdirectory: "Resources") ?? bundle.url(forResource: "awsvis", withExtension: "png") {
                    return NSImage(contentsOf: url)
                }
            }
        }
        return nil
    }()

    var body: some View {
        if let image = Self.image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            Image(systemName: "cloud.fill")
                .font(.system(size: size))
                .foregroundStyle(
                    LinearGradient(colors: [Color(red: 1.0, green: 0.73, blue: 0.35), Color(red: 1.0, green: 0.6, blue: 0.0)], startPoint: .top, endPoint: .bottom)
                )
        }
    }
}

struct ErrorStateView: View {
    let message: String
    var retry: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if let retry {
                RefreshButton("Retry", action: retry)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct EmptyStateView: View {
    var message: String = "No data available"

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
