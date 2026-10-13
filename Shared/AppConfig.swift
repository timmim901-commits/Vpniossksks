import Foundation

/// Значения берутся из Info.plist (см. project.yml → BASE_BUNDLE_ID / APP_GROUP_ID).
enum AppConfig {
    static let packageName: String = {
        (Bundle.main.object(forInfoDictionaryKey: "BasePackageIdentifier") as? String) ?? "com.timmim.vpn"
    }()

    static let appGroupID: String = {
        (Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String) ?? "group.com.timmim.vpn"
    }()

    static var extensionBundleID: String { packageName + ".tunnel" }
}

enum FilePath {
    static let sharedDirectory: URL = {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppConfig.appGroupID) {
            return url
        }
        // Без App Group (например, неверно подписан) — падать не будем, но туннель не заработает.
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }()

    static let cacheDirectory = sharedDirectory
        .appendingPathComponent("Library", isDirectory: true)
        .appendingPathComponent("Caches", isDirectory: true)

    static let workingDirectory = cacheDirectory.appendingPathComponent("Working", isDirectory: true)

    /// Готовый JSON-конфиг sing-box, который читает расширение.
    static let configFile = sharedDirectory.appendingPathComponent("config.json")
    /// Хранилище узлов, правил и настроек приложения.
    static let storeFile = sharedDirectory.appendingPathComponent("store.json")
}

enum ClashAPI {
    static let host = "127.0.0.1"
    static let port = 9099
}
