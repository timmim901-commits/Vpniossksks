import SwiftUI
import UIKit

// MARK: - Свойства узла

extension Node {
    /// Вспомогательное звено (например, ShadowTLS): само по себе не выбирается, используется в цепочках.
    var isHelper: Bool { type == "shadowtls" }

    var object: [String: Any]? {
        guard let d = json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    /// Адрес для TCP-пинга.
    var hostPort: (host: String, port: Int)? {
        guard let o = object else { return nil }
        if let peers = o["peers"] as? [[String: Any]], let p = peers.first, let host = p["address"] as? String {
            return (host, (p["port"] as? Int) ?? 51820)
        }
        if let host = o["server"] as? String {
            if let port = o["server_port"] as? Int { return (host, port) }
            if let range = host.range(of: ":"), !host.contains("]"), let port = Int(host[range.upperBound...]) {
                return (String(host[..<range.lowerBound]), port)
            }
            return (host, type == "openconnect" ? 443 : 443)
        }
        return nil
    }

    /// Протоколы поверх UDP: TCP-пинг для них бессмыслен.
    var isUDP: Bool {
        switch type {
        case "hysteria", "hysteria2", "tuic", "wireguard", "masque-client": return true
        case "openvpn-client": return (object?["network"] as? String ?? "udp") == "udp"
        case "naive": return (object?["quic"] as? Bool) == true
        default: return false
        }
    }
}

// MARK: - Проверка JSON узла

enum NodeJSON {
    static let knownTypes: [String] = [
        "vless", "vmess", "trojan", "shadowsocks", "shadowtls", "hysteria", "hysteria2", "tuic", "anytls",
        "http", "socks", "naive", "ssh", "snell", "gost", "tor",
        "wireguard", "masque-client", "openconnect", "openvpn-client",
    ]

    struct Parsed {
        var name: String
        var type: String
        var isEndpoint: Bool
        var json: String
    }

    static func pretty(_ obj: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(obj),
              let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let s = String(data: d, encoding: .utf8) else { return nil }
        return s
    }

    static func format(_ text: String) -> String? {
        let t = LinkParser.normalizeQuotes(text)
        guard let d = t.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: d) else { return nil }
        return pretty(obj)
    }

    static func validate(text: String, name: String) -> Result<Parsed, NSError> {
        func fail(_ m: String) -> Result<Parsed, NSError> {
            .failure(NSError(domain: "Orbit", code: 1, userInfo: [NSLocalizedDescriptionKey: m]))
        }
        let t = LinkParser.normalizeQuotes(text)
        guard let d = t.data(using: .utf8) else { return fail("Пустой текст") }
        let any: Any
        do { any = try JSONSerialization.jsonObject(with: d) } catch {
            let ns = error as NSError
            let hint = (ns.userInfo["NSDebugDescription"] as? String) ?? ns.localizedDescription
            return fail("Ошибка JSON: \(hint)")
        }
        guard var obj = any as? [String: Any] else { return fail("Ожидался объект { … }") }
        guard let type = obj["type"] as? String, !type.isEmpty else { return fail("Нет поля \"type\"") }
        if !knownTypes.contains(type) {
            return fail("Тип «\(type)» не поддерживается ядром. Доступно: \(knownTypes.joined(separator: ", "))")
        }
        let isEndpoint = LinkParser.endpointTypes.contains(type)
        if !isEndpoint, type != "tor", obj["server"] == nil, obj["_shadowtls"] == nil {
            return fail("Нет поля \"server\"")
        }
        var finalName = name.trimmingCharacters(in: .whitespaces)
        if finalName.isEmpty { finalName = (obj["tag"] as? String) ?? "\(type) \(obj["server"] as? String ?? "")" }
        obj["tag"] = finalName
        guard let out = pretty(obj) else { return fail("Не удалось сериализовать JSON") }
        return .success(Parsed(name: finalName, type: type, isEndpoint: isEndpoint, json: out))
    }
}

// MARK: - Шаблоны

enum NodeTemplates {
    struct Template: Identifiable {
        let id = UUID()
        let title: String
        let json: String
    }

    static let all: [Template] = [
        Template(title: "VLESS + Reality", json: """
        {
          "type": "vless",
          "server": "example.com",
          "server_port": 443,
          "uuid": "00000000-0000-0000-0000-000000000000",
          "flow": "xtls-rprx-vision",
          "packet_encoding": "xudp",
          "tls": {
            "enabled": true,
            "server_name": "www.microsoft.com",
            "utls": { "enabled": true, "fingerprint": "chrome" },
            "reality": { "enabled": true, "public_key": "PUBLIC_KEY", "short_id": "SHORT_ID" }
          }
        }
        """),
        Template(title: "VLESS + WebSocket + TLS", json: """
        {
          "type": "vless",
          "server": "example.com",
          "server_port": 443,
          "uuid": "00000000-0000-0000-0000-000000000000",
          "tls": { "enabled": true, "server_name": "example.com" },
          "transport": { "type": "ws", "path": "/ws", "headers": { "Host": "example.com" } }
        }
        """),
        Template(title: "VMess", json: """
        {
          "type": "vmess",
          "server": "example.com",
          "server_port": 443,
          "uuid": "00000000-0000-0000-0000-000000000000",
          "security": "auto",
          "tls": { "enabled": true, "server_name": "example.com" },
          "transport": { "type": "ws", "path": "/" }
        }
        """),
        Template(title: "Trojan", json: """
        {
          "type": "trojan",
          "server": "example.com",
          "server_port": 443,
          "password": "PASSWORD",
          "tls": { "enabled": true, "server_name": "example.com" }
        }
        """),
        Template(title: "Shadowsocks", json: """
        {
          "type": "shadowsocks",
          "server": "example.com",
          "server_port": 8388,
          "method": "2022-blake3-aes-128-gcm",
          "password": "PASSWORD"
        }
        """),
        Template(title: "Shadowsocks + ShadowTLS (в одном узле)", json: """
        {
          "type": "shadowsocks",
          "server": "example.com",
          "server_port": 443,
          "method": "2022-blake3-aes-128-gcm",
          "password": "SS_PASSWORD",
          "_shadowtls": {
            "type": "shadowtls",
            "server": "example.com",
            "server_port": 443,
            "version": 3,
            "password": "SHADOWTLS_PASSWORD",
            "tls": { "enabled": true, "server_name": "cloud.tencent.com" }
          }
        }
        """),
        Template(title: "ShadowTLS (звено для цепочки)", json: """
        {
          "type": "shadowtls",
          "server": "example.com",
          "server_port": 443,
          "version": 3,
          "password": "SHADOWTLS_PASSWORD",
          "tls": { "enabled": true, "server_name": "cloud.tencent.com" }
        }
        """),
        Template(title: "Hysteria2", json: """
        {
          "type": "hysteria2",
          "server": "example.com",
          "server_port": 443,
          "password": "PASSWORD",
          "obfs": { "type": "salamander", "password": "OBFS_PASSWORD" },
          "tls": { "enabled": true, "server_name": "example.com", "alpn": ["h3"] }
        }
        """),
        Template(title: "Hysteria (v1)", json: """
        {
          "type": "hysteria",
          "server": "example.com",
          "server_port": 443,
          "up_mbps": 50,
          "down_mbps": 100,
          "auth_str": "PASSWORD",
          "tls": { "enabled": true, "server_name": "example.com", "alpn": ["h3"] }
        }
        """),
        Template(title: "TUIC", json: """
        {
          "type": "tuic",
          "server": "example.com",
          "server_port": 443,
          "uuid": "00000000-0000-0000-0000-000000000000",
          "password": "PASSWORD",
          "congestion_control": "bbr",
          "udp_relay_mode": "native",
          "tls": { "enabled": true, "server_name": "example.com", "alpn": ["h3"] }
        }
        """),
        Template(title: "AnyTLS", json: """
        {
          "type": "anytls",
          "server": "example.com",
          "server_port": 443,
          "password": "PASSWORD",
          "tls": { "enabled": true, "server_name": "example.com" }
        }
        """),
        Template(title: "HTTP-прокси (+TLS)", json: """
        {
          "type": "http",
          "server": "example.com",
          "server_port": 443,
          "username": "user",
          "password": "PASSWORD",
          "tls": { "enabled": true, "server_name": "example.com" }
        }
        """),
        Template(title: "SOCKS5 (+TLS)", json: """
        {
          "type": "socks",
          "version": "5",
          "server": "example.com",
          "server_port": 1080,
          "username": "user",
          "password": "PASSWORD",
          "tls": { "enabled": true, "server_name": "example.com" }
        }
        """),
        Template(title: "GOST Relay (TCP, +TLS)", json: """
        {
          "type": "gost",
          "server": "example.com",
          "server_port": 8420,
          "username": "user",
          "password": "PASSWORD",
          "tls": { "enabled": true, "server_name": "example.com" }
        }
        """),
        Template(title: "Snell", json: """
        {
          "type": "snell",
          "server": "example.com",
          "server_port": 443,
          "version": 4,
          "psk": "PSK",
          "obfs_mode": "tls",
          "obfs_host": "www.microsoft.com"
        }
        """),
        Template(title: "NaiveProxy", json: """
        {
          "type": "naive",
          "server": "example.com",
          "server_port": 443,
          "username": "user",
          "password": "PASSWORD",
          "tls": { "enabled": true, "server_name": "example.com" }
        }
        """),
        Template(title: "SSH", json: """
        {
          "type": "ssh",
          "server": "example.com",
          "server_port": 22,
          "user": "root",
          "password": "PASSWORD"
        }
        """),
        Template(title: "WireGuard", json: """
        {
          "type": "wireguard",
          "address": ["10.0.0.2/32"],
          "private_key": "PRIVATE_KEY",
          "mtu": 1280,
          "peers": [
            {
              "address": "example.com",
              "port": 51820,
              "public_key": "PEER_PUBLIC_KEY",
              "allowed_ips": ["0.0.0.0/0", "::/0"]
            }
          ]
        }
        """),
        Template(title: "MASQUE (CONNECT-IP)", json: """
        {
          "type": "masque-client",
          "server": "example.com",
          "server_port": 443,
          "username": "user",
          "password": "PASSWORD",
          "tls": { "enabled": true, "server_name": "example.com" }
        }
        """),
        Template(title: "OpenConnect", json: """
        {
          "type": "openconnect",
          "server": "vpn.example.com",
          "flavor": "anyconnect",
          "username": "user",
          "password": "PASSWORD"
        }
        """),
        Template(title: "OpenVPN", json: """
        {
          "type": "openvpn-client",
          "mode": "tls",
          "server": "example.com",
          "server_port": 1194,
          "network": "udp",
          "username": "user",
          "password": "PASSWORD",
          "tls": {
            "certificate": ["-----BEGIN CERTIFICATE-----", "…", "-----END CERTIFICATE-----"]
          }
        }
        """),
    ]
}

// MARK: - Редактор кода без «умных» кавычек

struct CodeEditor: UIViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat = 13

    func makeUIView(context: Context) -> UITextView {
        let v = UITextView()
        v.delegate = context.coordinator
        v.font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        v.autocorrectionType = .no
        v.autocapitalizationType = .none
        v.smartQuotesType = .no
        v.smartDashesType = .no
        v.smartInsertDeleteType = .no
        v.spellCheckingType = .no
        v.backgroundColor = UIColor.secondarySystemBackground
        v.layer.cornerRadius = 8
        v.textContainerInset = UIEdgeInsets(top: 10, left: 6, bottom: 10, right: 6)
        v.keyboardDismissMode = .interactive
        v.text = text
        return v
    }

    func updateUIView(_ v: UITextView, context: Context) {
        if v.text != text { v.text = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        let parent: CodeEditor
        init(_ p: CodeEditor) { parent = p }
        func textViewDidChange(_ textView: UITextView) { parent.text = textView.text }
    }
}
