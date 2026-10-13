import Foundation

/// Файловый лог в общем контейнере с ограничением размера (читают и приложение, и туннель).
struct LogFile {
    let name: String
    let maxBytes: Int

    private static let lock = NSLock()
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f
    }()

    var url: URL { FilePath.sharedDirectory.appendingPathComponent(name) }

    func log(_ text: String) {
        LogFile.lock.lock(); defer { LogFile.lock.unlock() }
        let line = "\(LogFile.formatter.string(from: Date())) \(text)\n"
        guard let data = line.data(using: .utf8) else { return }
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            if let attrs = try? fm.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? Int, size > maxBytes,
               let old = try? Data(contentsOf: url) {
                // оставляем вторую половину, начиная с целой строки
                var tail = old.suffix(maxBytes / 2)
                if let nl = tail.firstIndex(of: 10) { tail = tail.suffix(from: tail.index(after: nl)) }
                try? Data(tail).write(to: url, options: .atomic)
            }
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(data); try? h.close()
                return
            }
        }
        try? data.write(to: url)
    }

    func read() -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    func clear() {
        LogFile.lock.lock(); defer { LogFile.lock.unlock() }
        try? FileManager.default.removeItem(at: url)
    }
}

enum Log {
    static let app = LogFile(name: "app.log", maxBytes: 200_000)
    static let tunnel = LogFile(name: "tunnel.log", maxBytes: 120_000)
    static let core = LogFile(name: "core.log", maxBytes: 300_000)
}

/// Короткий алиас для лога туннеля.
enum Breadcrumb {
    static func log(_ text: String) { Log.tunnel.log(text) }
    static func read() -> String { Log.tunnel.read() }
}
