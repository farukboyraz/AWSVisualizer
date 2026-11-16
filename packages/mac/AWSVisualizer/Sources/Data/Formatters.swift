import Foundation

enum Formatters {
    static func formatBytes(_ bytes: Int?) -> String {
        guard let bytes = bytes else { return "-" }
        if bytes < 1024 { return "\(bytes) B" }
        let kb = Double(bytes) / 1024
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        let mb = kb / 1024
        if mb < 1024 { return String(format: "%.1f MB", mb) }
        let gb = mb / 1024
        return String(format: "%.2f GB", gb)
    }

    static func formatDate(_ dateString: String?) -> String {
        guard let dateString = dateString else { return "-" }

        let formatters: [DateFormatter] = {
            let iso = DateFormatter()
            iso.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
            let iso2 = DateFormatter()
            iso2.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
            return [iso, iso2]
        }()

        for formatter in formatters {
            if let date = formatter.date(from: dateString) {
                let display = DateFormatter()
                display.dateStyle = .medium
                display.timeStyle = .short
                return display.string(from: date)
            }
        }
        return dateString
    }

    /// CloudWatch Logs timestamps (log group creation time, log stream/event
    /// timestamps) come back as unix epoch milliseconds.
    static func formatEpochMillis(_ millis: Int?) -> String {
        guard let millis else { return "-" }
        let date = Date(timeIntervalSince1970: TimeInterval(millis) / 1000)
        let display = DateFormatter()
        display.dateStyle = .medium
        display.timeStyle = .medium
        return display.string(from: date)
    }

    /// Git's raw author/committer date format: unix epoch seconds followed
    /// by a timezone offset, e.g. "1787654701 +0300".
    static func formatGitDate(_ raw: String?) -> String {
        guard let raw else { return "-" }
        let parts = raw.split(separator: " ")
        guard let seconds = parts.first.flatMap({ TimeInterval($0) }) else { return raw }

        let date = Date(timeIntervalSince1970: seconds)
        let display = DateFormatter()
        display.dateStyle = .medium
        display.timeStyle = .short
        return display.string(from: date)
    }
}
