import Foundation

/// Собирает конфиг sing-box (формат 1.12+/1.14) из узлов, правил и настроек.
struct ConfigBuilder {
    typealias JSON = [String: Any]

    let data: Persisted

    private static let reservedTags: Set<String> = ["direct", "proxy", "auto", "ts", "dns-remote", "dns-local", "dns-ts"]

    struct BuildError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Уникальные теги выбираемых узлов и цепочек (нужны и приложению для запросов к Clash API).
    /// Вспомогательные звенья (ShadowTLS) тега не получают — они используются только внутри цепочек.
    func tagMap() -> [UUID: String] {
        var used = ConfigBuilder.reservedTags
        var tags: [UUID: String] = [:]
        func unique(_ base: String) -> String {
            var tag = base.isEmpty ? "node" : base
            var n = 2
            while used.contains(tag) { tag = "\(base) (\(n))"; n += 1 }
            used.insert(tag)
            return tag
        }
        for node in data.nodes where !node.isHelper {
            tags[node.id] = unique(node.name.isEmpty ? node.type : node.name)
        }
        for chain in data.chainList {
            tags[chain.id] = unique("⛓ " + chain.name)
        }
        return tags
    }

    static let xrayBasePort = 10800

    /// Локальные SOCKS-порты узлов Xray (sing-box → 127.0.0.1:порт → Xray).
    func xrayPorts() -> [UUID: Int] {
        var result: [UUID: Int] = [:]
        for (i, node) in data.nodes.filter({ $0.isXray }).enumerated() {
            result[node.id] = ConfigBuilder.xrayBasePort + i
        }
        return result
    }

    /// Конфиг для встроенного Xray (nil, если узлов Xray нет).
    func buildXray() -> String? {
        let ports = xrayPorts()
        guard !ports.isEmpty else { return nil }
        var inbounds: [JSON] = []
        var outbounds: [JSON] = []
        var rules: [JSON] = []
        for node in data.nodes where node.isXray {
            guard let port = ports[node.id], var out = parse(node) else { continue }
            out.removeValue(forKey: "type")
            out.removeValue(forKey: "tag")
            let n = port - ConfigBuilder.xrayBasePort
            out["tag"] = "out-\(n)"
            inbounds.append(["tag": "in-\(n)", "listen": "127.0.0.1", "port": port, "protocol": "socks",
                             "settings": ["udp": true, "auth": "noauth"] as JSON])
            outbounds.append(out)
            rules.append(["type": "field", "inboundTag": ["in-\(n)"], "outboundTag": "out-\(n)"])
        }
        let config: JSON = [
            "log": ["loglevel": "warning"] as JSON,
            "inbounds": inbounds,
            "outbounds": outbounds,
            "routing": ["domainStrategy": "AsIs", "rules": rules] as JSON,
        ]
        guard let d = try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    private func xraySocks(tag: String, port: Int) -> JSON {
        ["type": "socks", "tag": tag, "server": "127.0.0.1", "server_port": port, "version": "5"]
    }

    private func parse(_ node: Node) -> JSON? {
        guard let raw = node.json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: raw)) as? JSON
    }

    /// Раскрывает встроенный "_shadowtls": добавляет вспомогательный outbound и ставит detour.
    private func expand(_ obj: JSON, tag: String, into outbounds: inout [JSON]) -> JSON {
        var obj = obj
        if var st = obj["_shadowtls"] as? JSON {
            obj.removeValue(forKey: "_shadowtls")
            let helperTag = tag + " ›tls"
            st["tag"] = helperTag
            outbounds.append(st)
            obj["detour"] = helperTag
        }
        return obj
    }

    func build() throws -> String {
        let s = data.settings
        if s.useCustomConfig == true, let custom = s.customConfig,
           !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return LinkParser.normalizeQuotes(custom)
        }
        let ts = data.tailscale
        let tsOn = ts.enabled

        // --- узлы ---
        var outbounds: [JSON] = []
        var endpoints: [JSON] = []
        let tags = tagMap()
        let xports = xrayPorts()
        for node in data.nodes where !node.isHelper {
            if node.isXray, let tag = tags[node.id], let port = xports[node.id] {
                outbounds.append(xraySocks(tag: tag, port: port))
                continue
            }
            guard let tag = tags[node.id], var obj = parse(node) else { continue }
            obj["tag"] = tag
            obj = expand(obj, tag: tag, into: &outbounds)
            if node.isEndpoint { endpoints.append(obj) } else { outbounds.append(obj) }
        }
        // --- цепочки (Relay): каждое звено — копия узла с detour на предыдущее ---
        for chain in data.chainList {
            guard let chainTag = tags[chain.id] else { continue }
            let members = chain.members.compactMap { id in data.nodes.first { $0.id == id } }
            var previous: String?
            for (i, member) in members.enumerated() {
                let isLast = i == members.count - 1
                let tag = isLast ? chainTag : "\(chainTag) ›\(i + 1)"
                if member.isXray, let port = xports[member.id] {
                    outbounds.append(xraySocks(tag: tag, port: port))
                    previous = tag
                    continue
                }
                guard var obj = parse(member) else { continue }
                obj["tag"] = tag
                obj = expand(obj, tag: tag, into: &outbounds)
                if let previous { obj["detour"] = previous }
                if member.isEndpoint { endpoints.append(obj) } else { outbounds.append(obj) }
                previous = tag
            }
        }
        let nodeTags = data.nodes.filter { !$0.isHelper }.compactMap { tags[$0.id] }
            + data.chainList.compactMap { tags[$0.id] }
        let hasNodes = !nodeTags.isEmpty

        outbounds.append(["type": "direct", "tag": "direct"])
        if hasNodes {
            outbounds.append([
                "type": "urltest", "tag": "auto", "outbounds": nodeTags,
                "url": s.urlTestURL, "interval": "5m", "tolerance": 50,
            ])
            var selector: JSON = ["type": "selector", "tag": "proxy", "outbounds": ["auto"] + nodeTags]
            if let id = s.selectedNodeID, let tag = tags[id] { selector["default"] = tag } else { selector["default"] = "auto" }
            outbounds.append(selector)
        } else {
            outbounds.append(["type": "selector", "tag": "proxy", "outbounds": ["direct"]])
        }

        // --- Tailscale ---
        if tsOn {
            var e: JSON = ["type": "tailscale", "tag": "ts", "state_directory": "tailscale",
                           "accept_routes": ts.acceptRoutes]
            if !ts.authKey.isEmpty { e["auth_key"] = ts.authKey }
            if !ts.controlURL.isEmpty { e["control_url"] = ts.controlURL }
            if !ts.hostname.isEmpty { e["hostname"] = ts.hostname }
            if !ts.exitNode.isEmpty {
                e["exit_node"] = ts.exitNode
                e["exit_node_allow_lan_access"] = ts.exitNodeAllowLAN
            }
            endpoints.append(e)
        }

        // --- наборы правил (geoip / geosite) ---
        var ruleSets: [String: JSON] = [:]
        let downloadDetour = (hasNodes && s.mode != .direct) ? "proxy" : "direct"
        func ruleSetTag(_ kind: RuleKind, _ name: String) -> String {
            let n = name.lowercased()
            let tag = (kind == .geoip ? "geoip-" : "geosite-") + n
            if ruleSets[tag] == nil {
                let repo = kind == .geoip ? "sing-geoip" : "sing-geosite"
                ruleSets[tag] = [
                    "type": "remote", "tag": tag, "format": "binary",
                    "url": "https://raw.githubusercontent.com/SagerNet/\(repo)/rule-set/\(tag).srs",
                    "http_client": "hc", "update_interval": "3d",
                ]
            }
            return tag
        }

        // --- правила маршрутизации ---
        var routeRules: [JSON] = [
            ["action": "sniff"],
            ["protocol": "dns", "action": "hijack-dns"],
        ]
        var dnsRules: [JSON] = []

        if tsOn {
            routeRules.append(["ip_cidr": ["100.64.0.0/10", "fd7a:115c:a1e0::/48"], "outbound": "ts"])
            routeRules.append(["domain_suffix": ["ts.net"], "outbound": "ts"])
            dnsRules.append(["domain_suffix": ["ts.net"], "action": "route", "server": "dns-ts"])
        }
        if s.bypassLAN {
            routeRules.append(["ip_is_private": true, "outbound": "direct"])
        }

        if s.mode == .rule {
            if s.blockAds {
                let t = ruleSetTag(.geosite, "category-ads-all")
                routeRules.append(["rule_set": [t], "action": "reject"])
                dnsRules.append(["rule_set": [t], "action": "reject"])
            }
            for rule in data.rules where rule.enabled {
                guard let (match, isDomainLike) = matcher(for: rule, ruleSetTag: ruleSetTag) else { continue }
                var r = match
                switch rule.action {
                case .proxy: r["outbound"] = "proxy"
                case .direct: r["outbound"] = "direct"
                case .reject: r["action"] = "reject"
                }
                routeRules.append(r)
                if isDomainLike {
                    var d = match
                    switch rule.action {
                    case .proxy: d["action"] = "route"; d["server"] = "dns-remote"
                    case .direct: d["action"] = "route"; d["server"] = "dns-local"
                    case .reject: d["action"] = "reject"
                    }
                    dnsRules.append(d)
                }
            }
            if s.bypassRU {
                let gs = ruleSetTag(.geosite, "category-ru")
                let gy = ruleSetTag(.geosite, "yandex")
                let gi = ruleSetTag(.geoip, "ru")
                routeRules.append(["rule_set": [gs, gy], "outbound": "direct"])
                routeRules.append(["domain_suffix": [".ru", ".su", ".xn--p1ai"], "outbound": "direct"])
                routeRules.append(["rule_set": [gi], "outbound": "direct"])
                dnsRules.append(["rule_set": [gs, gy], "action": "route", "server": "dns-local"])
                dnsRules.append(["domain_suffix": [".ru", ".su", ".xn--p1ai"], "action": "route", "server": "dns-local"])
            }
        }

        var finalOutbound = "proxy"
        switch s.mode {
        case .direct: finalOutbound = "direct"
        default:
            if tsOn && ts.routeAllViaExit && !ts.exitNode.isEmpty { finalOutbound = "ts" }
            if !hasNodes && finalOutbound == "proxy" { finalOutbound = "direct" }
        }

        // --- DNS ---
        var dnsServers: [JSON] = []
        dnsServers.append(dnsServer(tag: "dns-local", from: s.localDNS, detour: nil))
        var remote = dnsServer(tag: "dns-remote", from: s.remoteDNS, detour: hasNodes && s.mode != .direct ? "proxy" : nil)
        if s.mode == .direct { remote = dnsServer(tag: "dns-remote", from: s.localDNS, detour: nil) }
        dnsServers.append(remote)
        if tsOn { dnsServers.append(["type": "tailscale", "tag": "dns-ts", "endpoint": "ts"]) }

        // --- итог ---
        let inbound: JSON = [
            "type": "tun", "tag": "tun-in",
            "address": s.ipv6 ? ["172.19.0.1/30", "fdfe:dcba:9876::1/126"] : ["172.19.0.1/30"],
            "mtu": s.mtu, "auto_route": true,
        ]
        // `stack` не указываем: с 1.15 используется собственный стек sing-tun.

        var root: JSON = [
            "log": ["level": s.logLevel, "timestamp": true],
            "dns": [
                "servers": dnsServers,
                "rules": dnsRules,
                "final": s.mode == .direct ? "dns-local" : "dns-remote",
                "strategy": s.ipv6 ? "prefer_ipv4" : "ipv4_only",
            ] as JSON,
            "inbounds": [inbound],
            "outbounds": outbounds,
            "route": [
                "rules": routeRules,
                "rule_set": Array(ruleSets.values),
                "final": finalOutbound,
                "auto_detect_interface": true,
                "default_domain_resolver": "dns-local",
            ] as JSON,
            "experimental": [
                "cache_file": ["enabled": true],
                "clash_api": [
                    "external_controller": "\(ClashAPI.host):\(ClashAPI.port)",
                    "secret": s.clashSecret,
                ],
            ] as JSON,
        ]
        if !endpoints.isEmpty { root["endpoints"] = endpoints }
        if !ruleSets.isEmpty {
            // Скачивание geo-списков: через прокси, если он есть, иначе напрямую.
            root["http_clients"] = [["tag": "hc", "detour": downloadDetour] as JSON]
        }

        let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        guard let text = String(data: out, encoding: .utf8) else { throw BuildError(message: "Не удалось собрать конфиг") }
        return text
    }

    // MARK: Правила

    /// Возвращает условие правила и признак «применимо к DNS» (доменные условия).
    private func matcher(for rule: Rule, ruleSetTag: (RuleKind, String) -> String) -> (JSON, Bool)? {
        let values = rule.value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !values.isEmpty else { return nil }
        switch rule.kind {
        case .domain: return (["domain": values], true)
        case .domainSuffix: return (["domain_suffix": values], true)
        case .domainKeyword: return (["domain_keyword": values], true)
        case .domainRegex: return (["domain_regex": values], true)
        case .ipCidr: return (["ip_cidr": values], false)
        case .sourceIpCidr: return (["source_ip_cidr": values], false)
        case .geoip: return (["rule_set": values.map { ruleSetTag(.geoip, $0) }], false)
        case .geosite: return (["rule_set": values.map { ruleSetTag(.geosite, $0) }], true)
        case .network:
            let n = values[0].lowercased()
            return n == "tcp" || n == "udp" ? (["network": n], false) : nil
        case .dstPort:
            var ports: [Int] = []
            var ranges: [String] = []
            for v in values {
                if v.contains("-") || v.contains(":") { ranges.append(v.replacingOccurrences(of: "-", with: ":")) }
                else if let p = Int(v) { ports.append(p) }
            }
            var m: JSON = [:]
            if !ports.isEmpty { m["port"] = ports }
            if !ranges.isEmpty { m["port_range"] = ranges }
            return m.isEmpty ? nil : (m, false)
        }
    }

    // MARK: DNS

    private func dnsServer(tag: String, from address: String, detour: String?) -> JSON {
        var s: JSON = ["tag": tag]
        var raw = address.trimmingCharacters(in: .whitespaces)
        if raw.isEmpty { raw = "1.1.1.1" }
        var scheme = "udp"
        if let r = raw.range(of: "://") {
            scheme = String(raw[..<r.lowerBound]).lowercased()
            raw = String(raw[r.upperBound...])
        }
        var path: String?
        if let slash = raw.firstIndex(of: "/") {
            path = String(raw[slash...])
            raw = String(raw[..<slash])
        }
        var host = raw
        var port: Int?
        if let colon = raw.lastIndex(of: ":"), !raw.contains("]"), raw.filter({ $0 == ":" }).count == 1 {
            host = String(raw[..<colon])
            port = Int(raw[raw.index(after: colon)...])
        }
        switch scheme {
        case "https", "h3": s["type"] = scheme == "h3" ? "h3" : "https"; if let path { s["path"] = path }
        case "tls": s["type"] = "tls"
        case "quic": s["type"] = "quic"
        case "tcp": s["type"] = "tcp"
        default: s["type"] = "udp"
        }
        s["server"] = host
        if let port { s["server_port"] = port }
        if let detour { s["detour"] = detour }
        if host.rangeOfCharacter(from: CharacterSet.letters) != nil, !host.contains(":") {
            // доменное имя DNS-сервера нужно разрешить через локальный DNS
            if tag != "dns-local" { s["domain_resolver"] = "dns-local" }
        }
        return s
    }
}

// MARK: - Импорт правил в синтаксисе Shadowrocket/Surge/Clash

enum RuleImporter {
    struct Result {
        var rules: [Rule] = []
        var skipped = 0
    }

    static func parse(_ text: String) -> Result {
        var result = Result()
        var inRuleSection: Bool? = nil
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") || line.hasPrefix("//") { continue }
            if line.hasPrefix("[") {
                inRuleSection = line.lowercased() == "[rule]"
                continue
            }
            if inRuleSection == false { continue }
            var parts = line.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.first == "-" { parts.removeFirst() }       // Clash: "- DOMAIN,..."
            if let f = parts.first, f.hasPrefix("- ") { parts[0] = String(f.dropFirst(2)) }
            guard parts.count >= 2 else { continue }
            let type = parts[0].uppercased()
            if type == "FINAL" || type == "MATCH" { result.skipped += 1; continue }
            guard parts.count >= 3 else { result.skipped += 1; continue }
            let kind: RuleKind?
            switch type {
            case "DOMAIN": kind = .domain
            case "DOMAIN-SUFFIX": kind = .domainSuffix
            case "DOMAIN-KEYWORD": kind = .domainKeyword
            case "IP-CIDR", "IP-CIDR6": kind = .ipCidr
            case "SRC-IP-CIDR": kind = .sourceIpCidr
            case "GEOIP": kind = .geoip
            case "GEOSITE": kind = .geosite
            case "DST-PORT": kind = .dstPort
            case "NETWORK": kind = .network
            default: kind = nil
            }
            guard let k = kind else { result.skipped += 1; continue }
            let actionRaw = parts[2].uppercased()
            let action: RuleAction
            if actionRaw == "DIRECT" { action = .direct }
            else if actionRaw.hasPrefix("REJECT") { action = .reject }
            else { action = .proxy }
            result.rules.append(Rule(kind: k, value: parts[1], action: action))
        }
        return result
    }
}
