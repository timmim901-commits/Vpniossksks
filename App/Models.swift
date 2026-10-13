import Foundation

enum RoutingMode: String, Codable, CaseIterable, Identifiable {
    case rule, global, direct
    var id: String { rawValue }
    var title: String {
        switch self {
        case .rule: return "По правилам"
        case .global: return "Глобально"
        case .direct: return "Напрямую"
        }
    }
}

enum RuleKind: String, Codable, CaseIterable, Identifiable {
    case domain = "DOMAIN"
    case domainSuffix = "DOMAIN-SUFFIX"
    case domainKeyword = "DOMAIN-KEYWORD"
    case domainRegex = "DOMAIN-REGEX"
    case ipCidr = "IP-CIDR"
    case sourceIpCidr = "SRC-IP-CIDR"
    case geoip = "GEOIP"
    case geosite = "GEOSITE"
    case dstPort = "DST-PORT"
    case network = "NETWORK"
    var id: String { rawValue }

    var hint: String {
        switch self {
        case .domain: return "example.com"
        case .domainSuffix: return "google.com"
        case .domainKeyword: return "youtube"
        case .domainRegex: return "^ad[0-9]+\\.example\\.com$"
        case .ipCidr: return "10.0.0.0/8"
        case .sourceIpCidr: return "192.168.1.0/24"
        case .geoip: return "ru"
        case .geosite: return "category-ads-all"
        case .dstPort: return "443 или 8000-9000"
        case .network: return "tcp или udp"
        }
    }
}

enum RuleAction: String, Codable, CaseIterable, Identifiable {
    case proxy = "PROXY"
    case direct = "DIRECT"
    case reject = "REJECT"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .proxy: return "Прокси"
        case .direct: return "Напрямую"
        case .reject: return "Блок"
        }
    }
}

struct Rule: Codable, Identifiable, Hashable {
    var id = UUID()
    var kind: RuleKind
    var value: String
    var action: RuleAction
    var enabled = true
}

struct Node: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var type: String
    /// Готовый outbound (или endpoint для WireGuard) sing-box в виде JSON.
    var json: String
    var isEndpoint = false
    var subscriptionID: UUID?
}

/// Цепочка (Relay): трафик идёт через звенья по порядку, первое — ближайшее к устройству.
struct Chain: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var members: [UUID]
}

struct Subscription: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var url: String
    var updatedAt: Date?
}

struct TailscaleSettings: Codable {
    var enabled = false
    var authKey = ""
    var controlURL = ""
    var hostname = ""
    var acceptRoutes = true
    var exitNode = ""
    var exitNodeAllowLAN = true
    /// Весь трафик (кроме правил) через exit node.
    var routeAllViaExit = false
}

struct AppSettings: Codable {
    var mode: RoutingMode = .rule
    /// nil — автоподбор (urltest).
    var selectedNodeID: UUID?
    var remoteDNS = "https://1.1.1.1/dns-query"
    var localDNS = "77.88.8.8"
    var ipv6 = false
    var mtu = 1400
    var bypassLAN = true
    var bypassRU = false
    var blockAds = false
    var onDemand = false
    var urlTestURL = "https://www.gstatic.com/generate_204"
    var siteURL = "https://yandex.qwexiup.fun"
    var logLevel = "info"
    var clashSecret = UUID().uuidString
    // Поля ниже необязательные, чтобы старый store.json продолжал читаться.
    var useCustomConfig: Bool?
    var customConfig: String?
}

struct Persisted: Codable {
    var nodes: [Node] = []
    var subscriptions: [Subscription] = []
    var rules: [Rule] = []
    var settings = AppSettings()
    var tailscale = TailscaleSettings()
    var chains: [Chain]?

    var chainList: [Chain] {
        get { chains ?? [] }
        set { chains = newValue }
    }
}
