import Foundation

/// Разбор ссылок-импортов: sub://, orbit://, clash://, sing-box:// и т.п.
enum DeepLink {
    static let schemes = [
        "sub", "orbit", "sing-box", "clash", "clashmeta", "v2rayng", "hiddify", "happ", "shadowrocket",
        "vless", "vmess", "trojan", "ss", "hysteria2", "hy2", "tuic", "anytls", "socks", "socks5",
    ]

    private static let queryStyle = [
        "orbit://", "sing-box://", "clash://", "clashmeta://", "v2rayng://", "hiddify://", "happ://",
    ]

    /// Если строка — ссылка на подписку, возвращает (имя, URL подписки).
    static func subscriptionRequest(from raw: String) -> (name: String, url: String)? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = s.lowercased()

        if lower.hasPrefix("shadowrocket://add/") {
            return subscriptionRequest(from: String(s.dropFirst("shadowrocket://add/".count)))
        }

        if lower.hasPrefix("sub://") {
            var payload = String(s.dropFirst("sub://".count))
            var name = ""
            if let hash = payload.firstIndex(of: "#") {
                name = String(payload[payload.index(after: hash)...]).removingPercentEncoding ?? ""
                payload = String(payload[..<hash])
            }
            let plain = payload.removingPercentEncoding ?? payload
            if let decoded = LinkParser.base64Decode(plain)?.trimmingCharacters(in: .whitespacesAndNewlines),
               decoded.lowercased().hasPrefix("http") {
                return (name, decoded)
            }
            if plain.lowercased().hasPrefix("http") { return (name, plain) }
            return nil
        }

        if queryStyle.contains(where: { lower.hasPrefix($0) }),
           let c = URLComponents(string: s),
           let url = c.queryItems?.first(where: { $0.name == "url" })?.value, !url.isEmpty {
            let name = c.queryItems?.first(where: { $0.name == "name" })?.value
                ?? c.fragment?.removingPercentEncoding ?? ""
            return (name, url)
        }

        if (lower.hasPrefix("http://") || lower.hasPrefix("https://")), !s.contains(" "), !s.contains("\n") {
            return ("", s)
        }
        return nil
    }
}
