import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var vpn: VPNManager
    @State private var showConfig = false

    var body: some View {
        NavigationStack {
            Form {
                Section("DNS") {
                    LabeledContent("Через прокси") {
                        TextField("https://1.1.1.1/dns-query", text: $store.data.settings.remoteDNS)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Напрямую") {
                        TextField("77.88.8.8", text: $store.data.settings.localDNS)
                            .multilineTextAlignment(.trailing)
                    }
                    Text("Форматы: 1.1.1.1, https://host/dns-query, tls://host, quic://host.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .textInputAutocapitalization(.never).autocorrectionDisabled()

                Section("Туннель") {
                    Toggle("IPv6", isOn: $store.data.settings.ipv6)
                    Stepper("MTU: \(store.data.settings.mtu)", value: $store.data.settings.mtu, in: 1280...1500, step: 20)
                    Toggle("Автоподключение (On Demand)", isOn: $store.data.settings.onDemand)
                    LabeledContent("URL проверки") {
                        TextField("https://www.gstatic.com/generate_204", text: $store.data.settings.urlTestURL)
                            .multilineTextAlignment(.trailing).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    Picker("Уровень журнала", selection: $store.data.settings.logLevel) {
                        ForEach(["error", "warn", "info", "debug"], id: \.self) { Text($0).tag($0) }
                    }
                }

                Section("Вкладка «Сайт»") {
                    TextField("https://…", text: $store.data.settings.siteURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                }

                Section("Диагностика") {
                    NavigationLink("Журнал ядра") { LogsView() }
                    NavigationLink("Логи и отчёт") { LogCenterView() }
                    Button("Показать конфиг sing-box") { showConfig = true }
                }

                Section("О программе") {
                    Text("Ядро: sing-box (GPL-3.0). Сетевой слой туннеля основан на sing-box-for-apple.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Ещё")
            .sheet(isPresented: $showConfig) { ConfigPreview() }
        }
    }
}

struct ConfigPreview: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            let text = (try? ConfigBuilder(data: store.data).build()) ?? "Ошибка сборки конфига"
            ScrollView {
                Text(text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding()
            }
            .navigationTitle("config.json")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { ShareLink(item: text) }
            }
        }
    }
}

struct LogsView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var vpn: VPNManager
    @State private var lines: [String] = []
    @State private var task: Task<Void, Never>?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if vpn.status != .connected {
                        Text("Журнал доступен, когда туннель подключён.").foregroundStyle(.secondary)
                    }
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                        Text(l).font(.system(size: 11, design: .monospaced)).id(i)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            .onChange(of: lines.count) { n in if n > 0 { proxy.scrollTo(n - 1, anchor: .bottom) } }
        }
        .navigationTitle("Журнал")
        .onAppear { start() }
        .onDisappear { task?.cancel() }
    }

    private func start() {
        task?.cancel()
        let secret = store.data.settings.clashSecret
        let level = store.data.settings.logLevel
        task = Task {
            guard let url = URL(string: "http://\(ClashAPI.host):\(ClashAPI.port)/logs?level=\(level)") else { return }
            var req = URLRequest(url: url, timeoutInterval: 3600)
            req.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
            do {
                let (bytes, _) = try await URLSession.shared.bytes(for: req)
                for try await line in bytes.lines {
                    if Task.isCancelled { break }
                    var text = line
                    if let d = line.data(using: .utf8),
                       let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                       let payload = j["payload"] as? String {
                        text = "[\(j["type"] as? String ?? "")] \(payload)"
                    }
                    await MainActor.run {
                        lines.append(text)
                        if lines.count > 500 { lines.removeFirst(100) }
                    }
                }
            } catch {}
        }
    }
}

enum Diagnostics {
    /// Текст отчёта: версии, состояние, хвосты логов и конфиг без секретов.
    @MainActor
    static func report(store: Store) -> String {
        let d = store.data
        var out: [String] = []
        let ver = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        out.append("== Orbit \(ver) ==")
        out.append("iOS \(UIDevice.current.systemVersion), \(UIDevice.current.model)")
        out.append("bundle: \(Bundle.main.bundleIdentifier ?? "?")")
        out.append("app group: \(AppConfig.appGroupID) — \(FilePath.hasGroupContainer ? "доступна" : "НЕДОСТУПНА")")
        out.append("режим: \(d.settings.mode.rawValue), узлов: \(d.nodes.count) [\(Set(d.nodes.map { $0.type }).sorted().joined(separator: ","))], подписок: \(d.subscriptions.count), правил: \(d.rules.count)")
        out.append("tailscale: \(d.tailscale.enabled), ipv6: \(d.settings.ipv6), mtu: \(d.settings.mtu), onDemand: \(d.settings.onDemand)")
        func tail(_ s: String, _ n: Int) -> String { s.count > n ? "…" + String(s.suffix(n)) : s }
        out.append("\n== app.log ==\n" + tail(Log.app.read(), 6000))
        out.append("\n== tunnel.log ==\n" + tail(Log.tunnel.read(), 6000))
        out.append("\n== core.log ==\n" + tail(Log.core.read(), 8000))
        out.append("\n== config.json (секреты скрыты) ==\n" + redact((try? String(contentsOf: FilePath.configFile, encoding: .utf8)) ?? "нет файла"))
        return out.joined(separator: "\n")
    }

    static func redact(_ json: String) -> String {
        let pattern = #""(password|secret|auth_key|private_key|pre_shared_key|uuid|public_key|short_id|username)"\s*:\s*"[^"]*""#
        return json.replacingOccurrences(of: pattern, with: #""$1" : "***""#, options: .regularExpression)
    }
}

struct LogCenterView: View {
    enum Source: String, CaseIterable, Identifiable {
        case app = "Приложение", tunnel = "Туннель", core = "Ядро"
        var id: String { rawValue }
        var file: LogFile {
            switch self {
            case .app: return Log.app
            case .tunnel: return Log.tunnel
            case .core: return Log.core
            }
        }
    }

    @EnvironmentObject var store: Store
    @State private var source: Source = .tunnel
    @State private var text = ""
    @State private var copied = false

    var body: some View {
        VStack(spacing: 8) {
            Picker("Источник", selection: $source) {
                ForEach(Source.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).padding(.horizontal)

            Text("App Group: \(FilePath.hasGroupContainer ? "доступна" : "НЕДОСТУПНА") • \(Bundle.main.bundleIdentifier ?? "?")")
                .font(.caption2.bold())
                .foregroundStyle(FilePath.hasGroupContainer ? .green : .red)

            ScrollView {
                Text(text.isEmpty ? "Лог пуст." : text)
                    .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)
            }

            HStack {
                Button(copied ? "Скопировано ✓" : "Скопировать отчёт") {
                    UIPasteboard.general.string = Diagnostics.report(store: store)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                }
                .buttonStyle(.borderedProminent)
                ShareLink(item: Diagnostics.report(store: store)) { Label("Поделиться", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.bordered)
            }
            .padding(.bottom, 8)
        }
        .navigationTitle("Логи")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { refresh() } label: { Image(systemName: "arrow.clockwise") }
                Button(role: .destructive) { source.file.clear(); refresh() } label: { Image(systemName: "trash") }
            }
        }
        .onAppear { refresh() }
        .onChange(of: source) { _ in refresh() }
    }

    private func refresh() { text = source.file.read() }
}
