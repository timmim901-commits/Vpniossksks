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
                    NavigationLink("Лог запуска туннеля") { TunnelLogView() }
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

struct TunnelLogView: View {
    @State private var text = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("App Group: \(AppConfig.appGroupID) — \(FilePath.hasGroupContainer ? "доступна" : "НЕДОСТУПНА")")
                    .font(.footnote.bold())
                    .foregroundStyle(FilePath.hasGroupContainer ? .green : .red)
                Text("Bundle ID: \(Bundle.main.bundleIdentifier ?? "?")").font(.footnote)
                Divider()
                Text(text.isEmpty ? "Лог пуст: туннель ещё не запускался." : text)
                    .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding()
        }
        .navigationTitle("Лог туннеля")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { Button { text = Breadcrumb.read() } label: { Image(systemName: "arrow.clockwise") } }
            ToolbarItem(placement: .topBarTrailing) { ShareLink(item: text) }
        }
        .onAppear { text = Breadcrumb.read() }
    }
}
