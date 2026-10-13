import Foundation
import Libbox
import NetworkExtension

// Адаптировано из SagerNet/sing-box-for-apple (GPL-3.0).
final class PacketTunnelProvider: NEPacketTunnelProvider {
    struct OverridePreferences {
        var autoRouteUseSubRangesByDefault = false
        var excludeAPNsRoute = false
        var excludeDefaultRoute = false
        var systemProxyEnabled = true
    }

    private(set) var commandServer: LibboxCommandServer?
    /// Конфиг, присланный приложением сообщением (если общий контейнер недоступен).
    private var payloadOverride: (config: String, xray: String?)?
    private lazy var platformInterface = ExtensionPlatformInterface(self)

    override func startTunnel(options _: [String: NSObject]?) async throws {
        Breadcrumb.log("---------- startTunnel ----------")
        Breadcrumb.log("startTunnel, bundle=\(Bundle.main.bundleIdentifier ?? "?"), group=\(AppConfig.appGroupID), groupOK=\(FilePath.hasGroupContainer)")
        do {
            try await start()
            Breadcrumb.log("OK: туннель запущен")
        } catch {
            Breadcrumb.log("ОШИБКА: \(error.localizedDescription)")
            throw error
        }
    }

    private func start() async throws {
        if !FilePath.hasGroupContainer {
            Breadcrumb.log("App Group недоступна — работаю без неё: конфиг приходит через профиль VPN и сообщения")
        }
        let basePath = FilePath.sharedDirectory.relativePath
        let workingPath = FilePath.workingDirectory.relativePath
        let tempPath = FilePath.cacheDirectory.relativePath

        let setup = LibboxSetupOptions()
        setup.basePath = basePath
        setup.workingPath = workingPath
        setup.tempPath = tempPath
        setup.logMaxLines = 3000
        setup.debug = false
        setup.crashReportSource = "NetworkExtension"
        setup.appVersion = "1"
        setup.appMarketingVersion = "1.0"
        setup.oomKillerEnabled = true // лимит памяти расширения на iOS ~50 МБ
        setup.platformMetadata = "{}"

        var setupError: NSError?
        LibboxSetup(setup, &setupError)
        if let setupError {
            throw ExtensionStartupError("setup: \(setupError.localizedDescription)")
        }

        Breadcrumb.log("setup OK")
        var error: NSError?
        commandServer = LibboxNewCommandServer(platformInterface, platformInterface, &error)
        if let error {
            throw ExtensionStartupError("create command server: \(error.localizedDescription)")
        }
        do {
            try commandServer!.start()
        } catch {
            throw ExtensionStartupError("start command server: \(error.localizedDescription)")
        }
        Breadcrumb.log("command server OK")
        try await startService()
        writeMessage("Orbit: туннель запущен")
    }

    func writeMessage(_ message: String, level: Int32 = 4) {
        commandServer?.writeMessage(level, message: message)
    }

    /// Конфиг лежит в общем контейнере, его пишет основное приложение.
    private func startService() async throws {
        let content: String
        let xrayText: String?
        if let o = payloadOverride {
            content = o.config
            xrayText = o.xray
        } else if FilePath.hasGroupContainer, let text = try? String(contentsOf: FilePath.configFile, encoding: .utf8) {
            content = text
            xrayText = try? String(contentsOf: FilePath.xrayFile, encoding: .utf8)
        } else if let pc = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration,
                  let text = pc["config"] as? String, !text.isEmpty {
            content = text
            xrayText = pc["xray"] as? String
            Breadcrumb.log("конфиг взят из профиля VPN")
        } else {
            throw ExtensionStartupError("нет конфига: общий контейнер недоступен, а профиль VPN не содержит конфиг. Нажмите «подключить» в приложении ещё раз")
        }
        try startXrayIfNeeded(xrayText)
        Breadcrumb.log("config.json: \(content.utf8.count) байт, запускаю ядро")
        let options = LibboxOverrideOptions()
        do {
            try commandServer!.startOrReloadService(content, options: options)
        } catch {
            throw ExtensionStartupError("start service: \(error.localizedDescription)")
        }
    }

    /// Узлы Xray: ядро Xray слушает локальные SOCKS-порты, sing-box отправляет в них трафик.
    private func startXrayIfNeeded(_ xrayText: String?) throws {
        var err: NSError?
        guard let text = xrayText,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            _ = XraybridgeStop(&err)
            return
        }
        Breadcrumb.log("xray.json: \(text.utf8.count) байт, запускаю Xray \(XraybridgeVersion())")
        if !XraybridgeStart(text, &err) {
            throw ExtensionStartupError("xray: \(err?.localizedDescription ?? "ошибка запуска")")
        }
        Breadcrumb.log("xray запущен")
    }

    func stopService() {
        var xerr: NSError?
        _ = XraybridgeStop(&xerr)
        do {
            try commandServer?.closeService()
        } catch {
            writeMessage("stop service: \(error.localizedDescription)")
        }
        platformInterface.reset()
    }

    func reloadService() async throws {
        Breadcrumb.log("reload: перечитываю config.json")
        writeMessage("Orbit: перезагрузка конфигурации")
        reasserting = true
        defer { reasserting = false }
        try await startService()
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        Breadcrumb.log("stopTunnel, причина=\(reason.rawValue)")
        writeMessage("Orbit: остановка, причина \(reason.rawValue)")
        stopService()
        if let server = commandServer {
            try? await Task.sleep(nanoseconds: 100 * NSEC_PER_MSEC)
            server.close()
            commandServer = nil
        }
    }

    /// Сообщения от приложения: "reload" — перечитать конфиг; JSON {"cmd":"reload","config":…,"xray":…} —
    /// применить присланный конфиг; "logs" — вернуть логи расширения (когда общий контейнер недоступен).
    override func handleAppMessage(_ messageData: Data) async -> Data? {
        if String(data: messageData, encoding: .utf8) == "logs" {
            let payload: [String: String] = ["tunnel": Log.tunnel.read(), "core": Log.core.read()]
            return try? JSONSerialization.data(withJSONObject: payload)
        }
        var isReload = String(data: messageData, encoding: .utf8) == "reload"
        if !isReload, let obj = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any],
           obj["cmd"] as? String == "reload", let config = obj["config"] as? String {
            payloadOverride = (config, obj["xray"] as? String)
            isReload = true
        }
        guard isReload else { return nil }
        do {
            try await reloadService()
            Breadcrumb.log("reload OK")
            return nil
        } catch {
            Breadcrumb.log("reload ОШИБКА: \(error.localizedDescription)")
            return error.localizedDescription.data(using: .utf8)
        }
    }

    override func sleep() async {
        Breadcrumb.log("sleep")
        commandServer?.pause()
    }

    override func wake() {
        Breadcrumb.log("wake")
        commandServer?.wake()
    }
}

/// NSError, чтобы текст причины доходил до приложения (fetchLastDisconnectError).
final class ExtensionStartupError: NSError, @unchecked Sendable {
    init(_ message: String) {
        super.init(domain: "Orbit", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }
}
