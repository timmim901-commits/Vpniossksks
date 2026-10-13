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
    private lazy var platformInterface = ExtensionPlatformInterface(self)

    override func startTunnel(options _: [String: NSObject]?) async throws {
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
        try await startService()
        writeMessage("Orbit: туннель запущен")
    }

    func writeMessage(_ message: String, level: Int32 = 4) {
        commandServer?.writeMessage(level, message: message)
    }

    /// Конфиг лежит в общем контейнере, его пишет основное приложение.
    private func startService() async throws {
        let content: String
        do {
            content = try String(contentsOf: FilePath.configFile, encoding: .utf8)
        } catch {
            throw ExtensionStartupError("не удалось прочитать config.json: \(error.localizedDescription)")
        }
        let options = LibboxOverrideOptions()
        do {
            try commandServer!.startOrReloadService(content, options: options)
        } catch {
            throw ExtensionStartupError("start service: \(error.localizedDescription)")
        }
    }

    func stopService() {
        do {
            try commandServer?.closeService()
        } catch {
            writeMessage("stop service: \(error.localizedDescription)")
        }
        platformInterface.reset()
    }

    func reloadService() async throws {
        writeMessage("Orbit: перезагрузка конфигурации")
        reasserting = true
        defer { reasserting = false }
        try await startService()
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        writeMessage("Orbit: остановка, причина \(reason.rawValue)")
        stopService()
        if let server = commandServer {
            try? await Task.sleep(nanoseconds: 100 * NSEC_PER_MSEC)
            server.close()
            commandServer = nil
        }
    }

    /// Сообщение от приложения: "reload" — перечитать config.json.
    override func handleAppMessage(_ messageData: Data) async -> Data? {
        guard String(data: messageData, encoding: .utf8) == "reload" else { return nil }
        do {
            try await reloadService()
            return nil
        } catch {
            return error.localizedDescription.data(using: .utf8)
        }
    }

    override func sleep() async {
        commandServer?.pause()
    }

    override func wake() {
        commandServer?.wake()
    }
}

final class ExtensionStartupError: NSObject, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
