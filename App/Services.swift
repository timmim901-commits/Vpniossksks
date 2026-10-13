import Foundation
import NetworkExtension

// MARK: - Clash API (локальный API ядра внутри туннеля)

struct ClashClient {
    let secret: String

    private func request(_ path: String, method: String = "GET", body: Data? = nil, timeout: TimeInterval = 8) async throws -> Data {
        guard let url = URL(string: "http://\(ClashAPI.host):\(ClashAPI.port)\(path)") else { throw URLError(.badURL) }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 { throw URLError(.badServerResponse) }
        return data
    }

    private func enc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")) ?? s
    }

    struct Traffic { var up: Int64; var down: Int64; var connections: Int }

    func traffic() async throws -> Traffic {
        let d = try await request("/connections")
        let j = try JSONSerialization.jsonObject(with: d) as? [String: Any] ?? [:]
        let up = (j["uploadTotal"] as? NSNumber)?.int64Value ?? 0
        let down = (j["downloadTotal"] as? NSNumber)?.int64Value ?? 0
        let conns = (j["connections"] as? [Any])?.count ?? 0
        return Traffic(up: up, down: down, connections: conns)
    }

    func select(tag: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["name": tag])
        _ = try await request("/proxies/proxy", method: "PUT", body: body)
    }

    /// Какой узел сейчас выбран в группе (для «Авто» — какой выбрал urltest).
    func currentNode() async throws -> String? {
        let d = try await request("/proxies/proxy")
        let j = try JSONSerialization.jsonObject(with: d) as? [String: Any]
        guard var now = j?["now"] as? String else { return nil }
        if now == "auto", let d2 = try? await request("/proxies/auto"),
           let j2 = try? JSONSerialization.jsonObject(with: d2) as? [String: Any],
           let n2 = j2["now"] as? String { now = n2 }
        return now
    }

    func delay(tag: String, url: String) async throws -> Int {
        let q = "?url=\(enc(url))&timeout=5000"
        let d = try await request("/proxies/\(enc(tag))/delay\(q)", timeout: 8)
        let j = try JSONSerialization.jsonObject(with: d) as? [String: Any]
        return (j?["delay"] as? NSNumber)?.intValue ?? -1
    }
}

// MARK: - Управление VPN-профилем

@MainActor
final class VPNManager: ObservableObject {
    @Published private(set) var status: NEVPNStatus = .invalid
    @Published var lastError: String?

    private var manager: NETunnelProviderManager?
    private var observer: NSObjectProtocol?

    var isActive: Bool { status == .connected || status == .connecting || status == .reasserting }

    static func describe(_ s: NEVPNStatus) -> String {
        switch s {
        case .invalid: return "invalid"
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .reasserting: return "reasserting"
        case .disconnecting: return "disconnecting"
        @unknown default: return "unknown"
        }
    }

    func load() async {
        do {
            let all = try await NETunnelProviderManager.loadAllFromPreferences()
            manager = all.first {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == AppConfig.extensionBundleID
            }
            attach()
            Log.app.log("load: профилей=\(all.count), наш=\(manager != nil), статус=\(Self.describe(status))")
        } catch {
            lastError = error.localizedDescription
            Log.app.log("load ОШИБКА: \(error.localizedDescription)")
        }
    }

    private func attach() {
        status = manager?.connection.status ?? .invalid
        if let observer { NotificationCenter.default.removeObserver(observer) }
        guard let connection = manager?.connection else { return }
        observer = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: connection, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.status = self.manager?.connection.status ?? .invalid
                Log.app.log("статус → \(Self.describe(self.status))")
                if self.status == .disconnected {
                    self.manager?.connection.fetchLastDisconnectError { err in
                        Task { @MainActor in
                            if let err {
                                self.lastError = err.localizedDescription
                                Log.app.log("причина отключения: \(err.localizedDescription) [\((err as NSError).domain) \((err as NSError).code)]")
                            }
                        }
                    }
                }
            }
        }
    }

    private func ensureManager(onDemand: Bool) async throws -> NETunnelProviderManager {
        let m = manager ?? NETunnelProviderManager()
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = AppConfig.extensionBundleID
        proto.serverAddress = "Orbit"
        m.protocolConfiguration = proto
        m.localizedDescription = "Orbit"
        m.isEnabled = true
        m.onDemandRules = onDemand ? [NEOnDemandRuleConnect()] : []
        m.isOnDemandEnabled = onDemand
        try await m.saveToPreferences()
        try await m.loadFromPreferences()
        manager = m
        attach()
        Log.app.log("профиль VPN сохранён (extension=\(AppConfig.extensionBundleID), onDemand=\(onDemand))")
        return m
    }

    func writeConfig(_ store: Store) throws {
        let text = try ConfigBuilder(data: store.data).build()
        try text.write(to: FilePath.configFile, atomically: true, encoding: .utf8)
        if let xray = ConfigBuilder(data: store.data).buildXray() {
            try xray.write(to: FilePath.xrayFile, atomically: true, encoding: .utf8)
            Log.app.log("xray.json записан: \(xray.utf8.count) байт")
        } else {
            try? FileManager.default.removeItem(at: FilePath.xrayFile)
        }
        let d = store.data
        Log.app.log("конфиг записан: \(text.utf8.count) байт, режим=\(d.settings.mode.rawValue), узлов=\(d.nodes.count), правил=\(d.rules.count), tailscale=\(d.tailscale.enabled)")
    }

    func connect(_ store: Store) async {
        Log.app.log("connect: нажата кнопка (группа=\(FilePath.hasGroupContainer), bundle=\(Bundle.main.bundleIdentifier ?? "?"))")
        do {
            try writeConfig(store)
            let m = try await ensureManager(onDemand: store.data.settings.onDemand)
            try m.connection.startVPNTunnel()
            lastError = nil
            Log.app.log("connect: startVPNTunnel вызван")
        } catch {
            lastError = error.localizedDescription
            Log.app.log("connect ОШИБКА: \(error.localizedDescription) [\((error as NSError).domain) \((error as NSError).code)]")
        }
    }

    func disconnect() {
        Log.app.log("disconnect: нажата кнопка")
        // Иначе on-demand сразу поднимет туннель обратно.
        if let m = manager, m.isOnDemandEnabled {
            m.isOnDemandEnabled = false
            m.saveToPreferences { _ in m.connection.stopVPNTunnel() }
        } else {
            manager?.connection.stopVPNTunnel()
        }
    }

    /// Применить изменения настроек: перезаписать конфиг и, если туннель работает, перечитать его.
    func apply(_ store: Store) async {
        do {
            try writeConfig(store)
            if isActive, let session = manager?.connection as? NETunnelProviderSession {
                try session.sendProviderMessage(Data("reload".utf8)) { reply in
                    let text = reply.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    Log.app.log("reload: ответ туннеля \(text.isEmpty ? "OK" : "ОШИБКА: " + text)")
                    if !text.isEmpty {
                        Task { @MainActor in self.lastError = text }
                    }
                }
            }
            if let m = manager, m.isOnDemandEnabled != store.data.settings.onDemand {
                _ = try await ensureManager(onDemand: store.data.settings.onDemand)
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            Log.app.log("apply ОШИБКА: \(error.localizedDescription)")
        }
    }
}

enum Format {
    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .binary)
    }
}
