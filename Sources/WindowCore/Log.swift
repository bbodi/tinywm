import Foundation

/// A plain-text trail of what tinywm saw and decided, so a window that ends up in the wrong
/// place can be traced afterwards. Nothing is written until `start(at:)` is called, so tests
/// and library users stay quiet.
public enum Log {
    /// Turns a window ID into a readable name. The app sets it to show the app and the title.
    nonisolated(unsafe) public static var describe: (String) -> String = { $0 }

    /// The file grows to this size, then moves to `<name>.1` and a new file starts.
    public static let maxBytes = 20_000_000

    private static let sink = Sink()

    public static var isOn: Bool { sink.isOn }

    public static func start(at url: URL) { sink.open(url) }

    /// Writes one line. The message is built only while the log is on.
    public static func note(_ category: String, _ message: @autoclosure () -> String) {
        guard sink.isOn else { return }
        sink.write(category, message(), at: Date())
    }

    /// A window's ID with its app and title, such as `w12 Ghostty "~/dev"`.
    public static func name(_ id: String) -> String { describe(id) }

    public static func names(_ ids: [String]) -> String { "[" + ids.map(describe).joined(separator: ", ") + "]" }

    public static func rect(_ r: Rect?) -> String {
        guard let r else { return "nil" }
        return "(\(Int(r.x.rounded())),\(Int(r.y.rounded())) \(Int(r.width.rounded()))x\(Int(r.height.rounded())))"
    }
}

private final class Sink: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "tinywm.log")
    private var handle: FileHandle?
    private var url: URL?
    private var size = 0
    private let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    var isOn: Bool { lock.withLock { handle != nil } }

    func open(_ url: URL) {
        lock.withLock {
            self.url = url
            reopen()
        }
    }

    func write(_ category: String, _ message: String, at date: Date) {
        queue.async { [self] in
            let text = message.replacingOccurrences(of: "\n", with: "\n    ")
            let line = "\(stamp.string(from: date)) [\(category)] \(text)\n"
            let data = Data(line.utf8)
            lock.withLock {
                guard let handle else { return }
                handle.write(data)
                size += data.count
                if size > Log.maxBytes { reopen(rotating: true) }
            }
        }
    }

    /// Call with the lock held.
    private func reopen(rotating: Bool = false) {
        try? handle?.close()
        handle = nil
        guard let url else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if rotating || existing > Log.maxBytes {
            let old = url.appendingPathExtension("1")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        handle = try? FileHandle(forWritingTo: url)
        size = Int((try? handle?.seekToEnd()) ?? 0)
    }
}
