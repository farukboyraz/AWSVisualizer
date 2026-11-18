import Foundation

extension Notification.Name {
    /// Posted (on the main queue) when the AWS CLI's sign-in caches change -
    /// e.g. `aws sso login` / `aws login` was run in a terminal.
    static let awsSignInFilesChanged = Notification.Name("awsSignInFilesChanged")
}

/// Watches the folders the AWS CLI writes sign-ins to (~/.aws/sso/cache,
/// ~/.aws/login/cache, ~/.aws/cli/cache, and ~/.aws itself for a changed
/// config), so a login made outside the app is picked up right away
/// instead of the profile staying "expired" until the next check.
/// Changes are coalesced: one notification ~1.5 s after the last write.
final class AWSSignInWatcher {
    static let shared = AWSSignInWatcher()

    private var sources: [DispatchSourceFileSystemObject] = []
    private var pending: DispatchWorkItem?
    private let queue = DispatchQueue(label: "aws-sign-in-watcher")

    private init() {}

    private static var folders: [URL] {
        let aws = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".aws")
        return [aws, aws.appendingPathComponent("sso/cache"), aws.appendingPathComponent("login/cache"), aws.appendingPathComponent("cli/cache")]
    }

    /// Starts watching (again): folders created since the last start are
    /// picked up too. Safe to call more than once.
    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.sources.forEach { $0.cancel() }
            self.sources = Self.folders.compactMap(self.watch)
        }
    }

    private func watch(_ folder: URL) -> DispatchSourceFileSystemObject? {
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend], queue: queue)
        source.setEventHandler { [weak self] in self?.changed() }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    private func changed() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            // A cache folder may have just been created: watch it too.
            self?.start()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .awsSignInFilesChanged, object: nil)
            }
        }
        pending = work
        queue.asyncAfter(deadline: .now() + 1.5, execute: work)
    }
}
