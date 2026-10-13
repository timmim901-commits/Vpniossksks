import Foundation
import Network

/// TCP-пинг до сервера (работает без туннеля).
enum Pinger {
    private final class Once {
        private var fired = false
        private let lock = NSLock()
        func fire() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if fired { return false }
            fired = true
            return true
        }
    }

    /// Минимальное время TCP-рукопожатия из двух попыток, мс.
    static func tcp(host: String, port: Int, timeout: TimeInterval = 4) async -> Int? {
        guard let first = await once(host: host, port: port, timeout: timeout) else { return nil }
        if let second = await once(host: host, port: port, timeout: timeout) { return min(first, second) }
        return first
    }

    private static func once(host: String, port: Int, timeout: TimeInterval) async -> Int? {
        guard port > 0, port < 65536, let p = NWEndpoint.Port(rawValue: UInt16(port)) else { return nil }
        return await withCheckedContinuation { (cont: CheckedContinuation<Int?, Never>) in
            let conn = NWConnection(host: NWEndpoint.Host(host), port: p, using: .tcp)
            let box = Once()
            let start = DispatchTime.now().uptimeNanoseconds
            let finish: (Int?) -> Void = { value in
                if box.fire() {
                    conn.cancel()
                    cont.resume(returning: value)
                }
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let ms = Int(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
                    finish(max(ms, 1))
                case .failed:
                    finish(nil)
                default:
                    break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }
}

@MainActor
final class PingModel: ObservableObject {
    enum State: Equatable {
        case testing
        case ms(Int)
        case failed(String)
        case udp
    }

    @Published var states: [UUID: State] = [:]

    /// Проверить всё: через туннель (реальный HTTP-тест) если он включён, иначе TCP до сервера.
    func testAll(store: Store, connected: Bool) async {
        let jobs = jobList(store: store)
        for j in jobs { states[j.id] = .testing }
        Log.app.log("пинг: \(jobs.count) шт., режим=\(connected ? "через туннель" : "TCP")")
        let secret = store.data.settings.clashSecret
        let url = store.data.settings.urlTestURL
        let batch = 8
        var index = 0
        while index < jobs.count {
            let slice = Array(jobs[index..<min(index + batch, jobs.count)])
            index += batch
            await withTaskGroup(of: (UUID, State).self) { group in
                for j in slice {
                    group.addTask { (j.id, await Self.measure(j, connected: connected, secret: secret, url: url)) }
                }
                for await (id, st) in group { states[id] = st }
            }
        }
        Log.app.log("пинг: готово")
    }

    func test(id: UUID, store: Store, connected: Bool) async {
        guard let job = jobList(store: store).first(where: { $0.id == id }) else { return }
        states[id] = .testing
        let st = await Self.measure(job, connected: connected,
                                    secret: store.data.settings.clashSecret, url: store.data.settings.urlTestURL)
        states[id] = st
    }

    // MARK: -

    struct Job {
        let id: UUID
        let tag: String
        let host: String?
        let port: Int
        let udp: Bool
    }

    private func jobList(store: Store) -> [Job] {
        let builder = ConfigBuilder(data: store.data)
        let tags = builder.tagMap()
        var jobs: [Job] = []
        for n in store.data.nodes where !n.isHelper {
            guard let tag = tags[n.id] else { continue }
            let hp = n.hostPort
            jobs.append(Job(id: n.id, tag: tag, host: hp?.host, port: hp?.port ?? 0, udp: n.isUDP))
        }
        for c in store.data.chainList {
            guard let tag = tags[c.id],
                  let firstID = c.members.first,
                  let first = store.data.nodes.first(where: { $0.id == firstID }) else { continue }
            let hp = first.hostPort
            jobs.append(Job(id: c.id, tag: tag, host: hp?.host, port: hp?.port ?? 0, udp: first.isUDP))
        }
        return jobs
    }

    nonisolated private static func measure(_ j: Job, connected: Bool, secret: String, url: String) async -> State {
        if connected {
            do {
                let ms = try await ClashClient(secret: secret).delay(tag: j.tag, url: url)
                return ms > 0 ? .ms(ms) : .failed("таймаут")
            } catch {
                return .failed("таймаут")
            }
        }
        if j.udp { return .udp }
        guard let host = j.host else { return .failed("нет адреса") }
        if let ms = await Pinger.tcp(host: host, port: j.port) { return .ms(ms) }
        return .failed("таймаут")
    }
}
