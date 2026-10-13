import Foundation

/// Разбор share-ссылок (vless/vmess/trojan/ss/hysteria2/tuic/anytls/socks), WireGuard .conf и sing-box JSON.
enum LinkParser {
    typealias JSON = [String: Any]

    static func parse(text: String) -> [Node] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }

        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            return parseJSON(trimmed)
        }
        if trimmed.contains("[Interface]"), let node = parseWireGuardConf(trimmed) {
            return [node]
        }
        if !trimmed.contains("://"), let decoded = base64Decode(trimmed), decoded.contains("://") || decoded.contains("{") {
            return parse(text: decoded)
        }
        var nodes: [Node] = []
        for raw in trimmed.components(separatedBy: CharacterSet.newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if let node = parseLink(line) { nodes.append(node) }
        }
        return nodes
    }

    // MARK: JSON

    private static let skipTypes: Set<String> = ["selector", "urltest", "direct", "block", "dns", "any"]
    private static let endpointTypes: Set<String> = ["wireguard"]

    private static func parseJSON(_ text: String) -> [Node] {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var items: [JSON] = []
        if let arr = obj as? [JSON] {
            items = arr
        } else if let dict = obj as? JSON {
            if let out = dict["outbounds"] as? [JSON] { items += out }
            if let eps = dict["endpoints"] as? [JSON] { items += eps }
            if dict["type"] != nil { items.append(dict) }
        }
        var nodes: [Node] = []
        for var item in items {
            guard let type = item["type"] as? String, !skipTypes.contains(type) else { continue }
            let name = (item["tag"] as? String) ?? "\(type) \(item["server"] as? String ?? "")"
            item["tag"] = name
            if let node = makeNode(name: name, type: type, json: item, isEndpoint: endpointTypes.contains(type)) {
                nodes.append(node)
            }
        }
        return nodes
    }

    // MARK: Ссылки

    static func parseLink(_ link: String) -> Node? {
        guard let schemeRange = link.range(of: "://") else { return nil }
        let scheme = link[..<schemeRange.lowerBound].lowercased()
        switch scheme {
        case "vless": return parseVLESS(link)
        case "vmess": return parseVMess(link)
        case "trojan": return parseTrojan(link)
        case "ss": return parseShadowsocks(link)
        case "hysteria2", "hy2": return parseHysteria2(link)
        case "tuic": return parseTUIC(link)
        case "anytls": return parseAnyTLS(link)
        case "socks", "socks5", "socks5h": return parseSocks(link)
        default: return nil
        }
    }

    private struct Parsed {
        var user: String?
        var password: String?
        var host: String
        var port: Int
        var query: [String: String]
        var name: String
    }

    private static func components(_ link: String, defaultPort: Int = 443) -> Parsed? {
        guard let c = URLComponents(string: link), var host = c.host, !host.isEmpty else { return nil }
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        var q: [String: String] = [:]
        for item in c.queryItems ?? [] { q[item.name] = item.value ?? "" }
        let port = c.port ?? defaultPort
        let name = (c.fragment?.removingPercentEncoding ?? c.fragment).flatMap { $0.isEmpty ? nil : $0 } ?? "\(host):\(port)"
        return Parsed(user: c.user?.removingPercentEncoding ?? c.user,
                      password: c.password?.removingPercentEncoding ?? c.password,
                      host: host, port: port, query: q, name: name)
    }

    private static func tls(_ q: [String: String], defaultSNI: String, force: Bool = false) -> JSON? {
        let security = q["security"] ?? (force ? "tls" : "none")
        guard security == "tls" || security == "reality" || force else { return nil }
        var t: JSON = ["enabled": true]
        let sni = q["sni"] ?? q["peer"] ?? q["host"] ?? defaultSNI
        if !sni.isEmpty { t["server_name"] = sni }
        if q["allowInsecure"] == "1" || q["insecure"] == "1" || q["allow_insecure"] == "1" { t["insecure"] = true }
        if let alpn = q["alpn"], !alpn.isEmpty { t["alpn"] = alpn.split(separator: ",").map(String.init) }
        if let fp = q["fp"], !fp.isEmpty { t["utls"] = ["enabled": true, "fingerprint": fp] }
        if security == "reality" {
            t["reality"] = ["enabled": true, "public_key": q["pbk"] ?? "", "short_id": q["sid"] ?? ""]
            if t["utls"] == nil { t["utls"] = ["enabled": true, "fingerprint": "chrome"] }
        }
        return t
    }

    private static func transport(_ q: [String: String], host: String) -> JSON? {
        let type = q["type"] ?? q["net"] ?? "tcp"
        let path = q["path"] ?? "/"
        let hostHeader = q["host"] ?? ""
        switch type {
        case "ws":
            var t: JSON = ["type": "ws", "path": path]
            if !hostHeader.isEmpty { t["headers"] = ["Host": hostHeader] }
            return t
        case "grpc":
            return ["type": "grpc", "service_name": q["serviceName"] ?? q["path"] ?? ""]
        case "http", "h2":
            var t: JSON = ["type": "http", "path": path]
            if !hostHeader.isEmpty { t["host"] = hostHeader.split(separator: ",").map(String.init) }
            return t
        case "httpupgrade":
            var t: JSON = ["type": "httpupgrade", "path": path]
            if !hostHeader.isEmpty { t["host"] = hostHeader }
            return t
        default:
            return nil
        }
    }

    private static func parseVLESS(_ link: String) -> Node? {
        guard let p = components(link), let uuid = p.user else { return nil }
        let type = p.query["type"] ?? "tcp"
        if type == "xhttp" || type == "splithttp" { return nil } // sing-box не поддерживает
        var o: JSON = ["type": "vless", "tag": p.name, "server": p.host, "server_port": p.port, "uuid": uuid]
        if let flow = p.query["flow"], !flow.isEmpty { o["flow"] = flow }
        o["packet_encoding"] = p.query["packetEncoding"] ?? "xudp"
        if let t = tls(p.query, defaultSNI: p.host) { o["tls"] = t }
        if let tr = transport(p.query, host: p.host) { o["transport"] = tr }
        return makeNode(name: p.name, type: "vless", json: o)
    }

    private static func parseVMess(_ link: String) -> Node? {
        let body = String(link.dropFirst("vmess://".count))
        guard let decoded = base64Decode(body),
              let data = decoded.data(using: .utf8),
              let j = try? JSONSerialization.jsonObject(with: data) as? JSON else { return nil }
        func str(_ k: String) -> String {
            if let s = j[k] as? String { return s }
            if let n = j[k] as? NSNumber { return n.stringValue }
            return ""
        }
        let host = str("add")
        let port = Int(str("port")) ?? 443
        guard !host.isEmpty else { return nil }
        let name = str("ps").isEmpty ? "\(host):\(port)" : str("ps")
        var o: JSON = ["type": "vmess", "tag": name, "server": host, "server_port": port,
                       "uuid": str("id"), "security": str("scy").isEmpty ? "auto" : str("scy"),
                       "alter_id": Int(str("aid")) ?? 0]
        var q: [String: String] = ["type": str("net"), "path": str("path"), "host": str("host"),
                                   "security": str("tls") == "tls" ? "tls" : "none",
                                   "sni": str("sni"), "alpn": str("alpn"), "fp": str("fp")]
        if q["type"] == "" { q["type"] = "tcp" }
        if let t = tls(q, defaultSNI: str("host").isEmpty ? host : str("host")) { o["tls"] = t }
        if let tr = transport(q, host: host) { o["transport"] = tr }
        return makeNode(name: name, type: "vmess", json: o)
    }

    private static func parseTrojan(_ link: String) -> Node? {
        guard let p = components(link), let password = p.user else { return nil }
        var o: JSON = ["type": "trojan", "tag": p.name, "server": p.host, "server_port": p.port, "password": password]
        o["tls"] = tls(p.query, defaultSNI: p.host, force: true)
        if let tr = transport(p.query, host: p.host) { o["transport"] = tr }
        return makeNode(name: p.name, type: "trojan", json: o)
    }

    private static func parseShadowsocks(_ link: String) -> Node? {
        var rest = String(link.dropFirst("ss://".count))
        var name: String?
        if let hash = rest.firstIndex(of: "#") {
            name = String(rest[rest.index(after: hash)...]).removingPercentEncoding
            rest = String(rest[..<hash])
        }
        var query = ""
        if let qm = rest.firstIndex(of: "?") {
            query = String(rest[rest.index(after: qm)...])
            rest = String(rest[..<qm])
        }
        if rest.hasSuffix("/") { rest.removeLast() }

        var method = "", password = "", host = "", port = 0
        if let at = rest.lastIndex(of: "@") {
            var userinfo = String(rest[..<at])
            let hostport = String(rest[rest.index(after: at)...])
            if !userinfo.contains(":") { userinfo = base64Decode(userinfo) ?? userinfo }
            else { userinfo = userinfo.removingPercentEncoding ?? userinfo }
            guard let colon = userinfo.firstIndex(of: ":") else { return nil }
            method = String(userinfo[..<colon])
            password = String(userinfo[userinfo.index(after: colon)...])
            guard let (h, p) = splitHostPort(hostport) else { return nil }
            host = h; port = p
        } else {
            guard let decoded = base64Decode(rest), let at = decoded.lastIndex(of: "@") else { return nil }
            let userinfo = String(decoded[..<at])
            guard let colon = userinfo.firstIndex(of: ":"),
                  let (h, p) = splitHostPort(String(decoded[decoded.index(after: at)...])) else { return nil }
            method = String(userinfo[..<colon])
            password = String(userinfo[userinfo.index(after: colon)...])
            host = h; port = p
        }
        let tag = (name?.isEmpty == false) ? name! : "\(host):\(port)"
        var o: JSON = ["type": "shadowsocks", "tag": tag, "server": host, "server_port": port,
                       "method": method, "password": password]
        // plugin=v2ray-plugin;... → в sing-box нужен отдельный транспорт, поддерживаем только obfs-local
        if let plugin = query.components(separatedBy: "&").first(where: { $0.hasPrefix("plugin=") }) {
            let value = String(plugin.dropFirst("plugin=".count)).removingPercentEncoding ?? ""
            let parts = value.components(separatedBy: ";")
            if let first = parts.first, first == "obfs-local" || first == "simple-obfs" {
                o["plugin"] = "obfs-local"
                o["plugin_opts"] = parts.dropFirst().joined(separator: ";")
            } else if !value.isEmpty {
                return nil
            }
        }
        return makeNode(name: tag, type: "shadowsocks", json: o)
    }

    private static func parseHysteria2(_ link: String) -> Node? {
        guard var p = components(link) else { return nil }
        let password = [p.user, p.password].compactMap { $0 }.joined(separator: ":")
        p.query["security"] = "tls"
        var o: JSON = ["type": "hysteria2", "tag": p.name, "server": p.host, "server_port": p.port, "password": password]
        o["tls"] = tls(p.query, defaultSNI: p.host, force: true)
        if let obfs = p.query["obfs"], !obfs.isEmpty {
            o["obfs"] = ["type": obfs, "password": p.query["obfs-password"] ?? ""]
        }
        if let ports = p.query["mport"], !ports.isEmpty {
            o["server_ports"] = ports.split(separator: ",").map { $0.replacingOccurrences(of: "-", with: ":") }
        }
        return makeNode(name: p.name, type: "hysteria2", json: o)
    }

    private static func parseTUIC(_ link: String) -> Node? {
        guard var p = components(link), let uuid = p.user else { return nil }
        p.query["security"] = "tls"
        var o: JSON = ["type": "tuic", "tag": p.name, "server": p.host, "server_port": p.port,
                       "uuid": uuid, "password": p.password ?? ""]
        o["congestion_control"] = p.query["congestion_control"] ?? "bbr"
        o["udp_relay_mode"] = p.query["udp_relay_mode"] ?? "native"
        o["tls"] = tls(p.query, defaultSNI: p.host, force: true)
        return makeNode(name: p.name, type: "tuic", json: o)
    }

    private static func parseAnyTLS(_ link: String) -> Node? {
        guard var p = components(link), let password = p.user else { return nil }
        p.query["security"] = "tls"
        var o: JSON = ["type": "anytls", "tag": p.name, "server": p.host, "server_port": p.port, "password": password]
        o["tls"] = tls(p.query, defaultSNI: p.host, force: true)
        return makeNode(name: p.name, type: "anytls", json: o)
    }

    private static func parseSocks(_ link: String) -> Node? {
        guard let p = components(link, defaultPort: 1080) else { return nil }
        var o: JSON = ["type": "socks", "tag": p.name, "server": p.host, "server_port": p.port, "version": "5"]
        if let u = p.user, !u.isEmpty {
            if let pw = p.password {
                o["username"] = u; o["password"] = pw
            } else if let decoded = base64Decode(u), let colon = decoded.firstIndex(of: ":") {
                o["username"] = String(decoded[..<colon])
                o["password"] = String(decoded[decoded.index(after: colon)...])
            } else {
                o["username"] = u
            }
        }
        return makeNode(name: p.name, type: "socks", json: o)
    }

    // MARK: WireGuard .conf

    static func parseWireGuardConf(_ text: String) -> Node? {
        var section = ""
        var iface: [String: String] = [:]
        var peer: [String: String] = [:]
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("[") { section = line.lowercased(); continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if section == "[interface]" { iface[key] = value }
            else if section == "[peer]", peer[key] == nil { peer[key] = value }
        }
        guard let priv = iface["privatekey"], let pub = peer["publickey"],
              let endpoint = peer["endpoint"], let (host, port) = splitHostPort(endpoint) else { return nil }
        func list(_ s: String?) -> [String] {
            (s ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        var p: JSON = ["address": host, "port": port, "public_key": pub,
                       "allowed_ips": list(peer["allowedips"]).isEmpty ? ["0.0.0.0/0", "::/0"] : list(peer["allowedips"])]
        if let psk = peer["presharedkey"] { p["pre_shared_key"] = psk }
        if let ka = peer["persistentkeepalive"], let n = Int(ka) { p["persistent_keepalive_interval"] = n }
        let name = "WireGuard \(host)"
        var o: JSON = ["type": "wireguard", "tag": name, "address": list(iface["address"]),
                       "private_key": priv, "peers": [p]]
        if let mtu = iface["mtu"], let n = Int(mtu) { o["mtu"] = n }
        return makeNode(name: name, type: "wireguard", json: o, isEndpoint: true)
    }

    // MARK: Утилиты

    private static func splitHostPort(_ s: String) -> (String, Int)? {
        var s = s
        if let slash = s.firstIndex(of: "/") { s = String(s[..<slash]) }
        if s.hasPrefix("["), let close = s.firstIndex(of: "]") {
            let host = String(s[s.index(after: s.startIndex)..<close])
            let after = s[s.index(after: close)...]
            guard after.hasPrefix(":"), let port = Int(after.dropFirst()) else { return nil }
            return (host, port)
        }
        guard let colon = s.lastIndex(of: ":"), let port = Int(s[s.index(after: colon)...]) else { return nil }
        return (String(s[..<colon]), port)
    }

    static func base64Decode(_ s: String) -> String? {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        guard let d = Data(base64Encoded: t), let str = String(data: d, encoding: .utf8) else { return nil }
        return str
    }

    private static func makeNode(name: String, type: String, json: JSON, isEndpoint: Bool = false) -> Node? {
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return Node(name: name, type: type, json: text, isEndpoint: isEndpoint)
    }
}
