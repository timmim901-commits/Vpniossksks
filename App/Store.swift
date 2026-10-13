import Foundation

@MainActor
final class Store: ObservableObject {
    @Published var data = Persisted() {
        didSet { save() }
    }
    /// Сообщение для всплывающего окна (результат импорта по ссылке и т.п.).
    @Published var toast: String?

    init() {
        if let raw = try? Data(contentsOf: FilePath.storeFile),
           let decoded = try? JSONDecoder().decode(Persisted.self, from: raw) {
            data = decoded
        }
    }

    private func save() {
        do {
            let raw = try JSONEncoder().encode(data)
            try raw.write(to: FilePath.storeFile, options: .atomic)
        } catch {
            NSLog("Orbit: store save failed: \(error)")
        }
    }

    // MARK: Узлы

    func add(nodes: [Node]) {
        data.nodes.append(contentsOf: nodes)
    }

    func remove(nodeIDs: Set<UUID>) {
        data.nodes.removeAll { nodeIDs.contains($0.id) }
        data.chainList = data.chainList.compactMap { c in
            var c = c
            c.members.removeAll { nodeIDs.contains($0) }
            return c.members.isEmpty ? nil : c
        }
        if let selected = data.settings.selectedNodeID, nodeIDs.contains(selected) {
            data.settings.selectedNodeID = nil
        }
        // выбранная цепочка могла исчезнуть
        if let selected = data.settings.selectedNodeID,
           !data.nodes.contains(where: { $0.id == selected }), !data.chainList.contains(where: { $0.id == selected }) {
            data.settings.selectedNodeID = nil
        }
    }

    /// Умный импорт: ссылки на подписки (sub://, https://…), share-ссылки, WireGuard, JSON.
    func smartImport(_ text: String) async -> (ok: Bool, message: String) {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var nodeLines: [String] = []
        var subsAdded = 0
        var nodesFromSubs = 0
        var errors: [String] = []

        // JSON и WireGuard-конфиги многострочные — не разбираем построчно
        let whole = LinkParser.normalizeQuotes(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if whole.hasPrefix("{") || whole.hasPrefix("[") || whole.contains("[Interface]") {
            nodeLines = [whole]
        } else {
            for line in lines {
                if let sub = DeepLink.subscriptionRequest(from: line) {
                    do {
                        let n = try await addSubscription(name: sub.name, url: sub.url)
                        subsAdded += 1; nodesFromSubs += n
                        Log.app.log("подписка добавлена: \(URL(string: sub.url)?.host ?? "?"), узлов \(n)")
                    } catch {
                        errors.append(error.localizedDescription)
                        Log.app.log("подписка ОШИБКА (\(URL(string: sub.url)?.host ?? "?")): \(error.localizedDescription)")
                    }
                } else {
                    nodeLines.append(line)
                }
            }
        }
        var added = 0
        if !nodeLines.isEmpty {
            added = importText(nodeLines.joined(separator: "\n"))
            Log.app.log("импорт узлов: строк \(nodeLines.count), добавлено \(added)")
        }
        var parts: [String] = []
        if subsAdded > 0 { parts.append("подписок: \(subsAdded) (узлов \(nodesFromSubs))") }
        if added > 0 { parts.append("узлов: \(added)") }
        if parts.isEmpty {
            return (false, errors.first ?? "Не удалось распознать ни ссылку на подписку, ни узел")
        }
        var msg = "Добавлено — " + parts.joined(separator: ", ")
        if let e = errors.first { msg += "\nОшибка: " + e }
        return (true, msg)
    }

    /// Импорт текста: ссылки, WireGuard-конфиг, sing-box JSON.
    @discardableResult
    func importText(_ text: String) -> Int {
        let nodes = LinkParser.parse(text: text)
        add(nodes: nodes)
        return nodes.count
    }

    // MARK: Подписки

    func addSubscription(name: String, url: String) async throws -> Int {
        var sub = Subscription(name: name.isEmpty ? (URL(string: url)?.host ?? "Подписка") : name, url: url)
        let nodes = try await Subscriptions.fetch(url: url)
        sub.updatedAt = Date()
        data.subscriptions.append(sub)
        add(nodes: nodes.map { var n = $0; n.subscriptionID = sub.id; return n })
        return nodes.count
    }

    func refresh(subscription: Subscription) async throws -> Int {
        let nodes = try await Subscriptions.fetch(url: subscription.url)
        data.nodes.removeAll { $0.subscriptionID == subscription.id }
        add(nodes: nodes.map { var n = $0; n.subscriptionID = subscription.id; return n })
        if let idx = data.subscriptions.firstIndex(where: { $0.id == subscription.id }) {
            data.subscriptions[idx].updatedAt = Date()
        }
        if let selected = data.settings.selectedNodeID, !data.nodes.contains(where: { $0.id == selected }) {
            data.settings.selectedNodeID = nil
        }
        return nodes.count
    }

    func remove(subscription: Subscription) {
        data.nodes.removeAll { $0.subscriptionID == subscription.id }
        data.subscriptions.removeAll { $0.id == subscription.id }
    }
}

enum Subscriptions {
    static func fetch(url: String) async throws -> [Node] {
        guard let u = URL(string: url) else { throw URLError(.badURL) }
        var req = URLRequest(url: u)
        req.timeoutInterval = 30
        req.setValue("sing-box Orbit/1.0", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            throw URLError(.cannotDecodeContentData)
        }
        let nodes = LinkParser.parse(text: text)
        if nodes.isEmpty {
            throw NSError(domain: "Orbit", code: 1, userInfo: [NSLocalizedDescriptionKey: "В подписке не найдено ни одного узла"])
        }
        return nodes
    }
}
