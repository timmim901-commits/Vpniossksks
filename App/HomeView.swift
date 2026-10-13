import SwiftUI
import NetworkExtension
import AVFoundation

struct HomeView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var vpn: VPNManager

    @State private var traffic: ClashClient.Traffic?
    @State private var latencies: [UUID: Int] = [:]
    @State private var testing = false
    @State private var activeTag: String?
    @State private var showAddText = false
    @State private var showAddSub = false
    @State private var showScanner = false
    @State private var message: String?

    private var client: ClashClient { ClashClient(secret: store.data.settings.clashSecret) }
    private var tagMap: [UUID: String] { ConfigBuilder(data: store.data).tagMap() }
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            List {
                Section { header }

                Section("Узлы") {
                    Button {
                        store.data.settings.selectedNodeID = nil
                        select(tag: "auto")
                    } label: {
                        row(title: "Авто (лучший по пингу)", subtitle: "urltest", latency: nil,
                            selected: store.data.settings.selectedNodeID == nil)
                    }
                    ForEach(store.data.nodes) { node in
                        Button {
                            store.data.settings.selectedNodeID = node.id
                            if let tag = tagMap[node.id] { select(tag: tag) }
                        } label: {
                            row(title: node.name, subtitle: node.type.uppercased(), latency: latencies[node.id],
                                selected: store.data.settings.selectedNodeID == node.id)
                        }
                    }
                    .onDelete { idx in
                        let ids = Set(idx.map { store.data.nodes[$0].id })
                        store.remove(nodeIDs: ids)
                    }
                    if store.data.nodes.isEmpty {
                        Text("Добавьте узлы кнопкой «+»: ссылку vless://, vmess://, trojan://, ss://, hysteria2://, tuic://, подписку, QR или WireGuard-конфиг.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }

                if !store.data.subscriptions.isEmpty {
                    Section("Подписки") {
                        ForEach(store.data.subscriptions) { sub in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(sub.name)
                                    Text(sub.updatedAt.map { "Обновлено \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button {
                                    Task { await refresh(sub) }
                                } label: { Image(systemName: "arrow.clockwise") }
                                .buttonStyle(.borderless)
                            }
                            .swipeActions {
                                Button(role: .destructive) { store.remove(subscription: sub) } label: { Label("Удалить", systemImage: "trash") }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Orbit")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task { await testAll() }
                    } label: {
                        if testing { ProgressView() } else { Image(systemName: "speedometer") }
                    }
                    .disabled(vpn.status != .connected || testing)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { pasteFromClipboard() } label: { Label("Вставить из буфера", systemImage: "doc.on.clipboard") }
                        Button { showScanner = true } label: { Label("Сканировать QR", systemImage: "qrcode.viewfinder") }
                        Button { showAddText = true } label: { Label("Ссылки / JSON / WireGuard", systemImage: "text.cursor") }
                        Button { showAddSub = true } label: { Label("Подписка по URL", systemImage: "link.badge.plus") }
                    } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showAddText) { AddTextSheet() }
            .sheet(isPresented: $showAddSub) { AddSubscriptionSheet() }
            .sheet(isPresented: $showScanner) {
                QRScannerView { code in
                    showScanner = false
                    let n = store.importText(code)
                    message = n > 0 ? "Добавлено узлов: \(n)" : "В QR не найдено узлов"
                }
            }
            .alert("Orbit", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK") { message = nil }
            } message: { Text(message ?? "") }
            .onReceive(timer) { _ in
                guard vpn.status == .connected else { traffic = nil; activeTag = nil; return }
                Task {
                    traffic = try? await client.traffic()
                    activeTag = try? await client.currentNode()
                }
            }
        }
    }

    // MARK: Шапка

    private var header: some View {
        VStack(spacing: 14) {
            Button {
                if vpn.isActive { vpn.disconnect() } else { Task { await vpn.connect(store) } }
            } label: {
                ZStack {
                    Circle().fill(vpn.status == .connected ? Color.green : Color.accentColor.opacity(0.85))
                        .frame(width: 96, height: 96)
                    Image(systemName: vpn.isActive ? "power.circle.fill" : "power")
                        .font(.system(size: 40, weight: .semibold)).foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
            Text(statusText).font(.headline)
            if let t = traffic, vpn.status == .connected {
                Text("↑ \(Format.bytes(t.up))   ↓ \(Format.bytes(t.down))   •   \(t.connections) соед.")
                    .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                if let tag = activeTag { Text("Сейчас: \(tag)").font(.footnote).foregroundStyle(.secondary) }
            }
            Picker("Режим", selection: $store.data.settings.mode) {
                ForEach(RoutingMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            if let e = vpn.lastError {
                Text(e).font(.footnote).foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    private var statusText: String {
        switch vpn.status {
        case .connected: return "Подключено"
        case .connecting: return "Подключение…"
        case .disconnecting: return "Отключение…"
        case .reasserting: return "Переподключение…"
        case .disconnected: return "Отключено"
        case .invalid: return "Профиль ещё не создан"
        @unknown default: return ""
        }
    }

    private func row(title: String, subtitle: String, latency: Int?, selected: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(.primary)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let l = latency {
                Text(l > 0 ? "\(l) мс" : "—").font(.caption.monospacedDigit())
                    .foregroundStyle(l > 0 ? (l < 300 ? .green : .orange) : .red)
            }
            if selected { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
        }
    }

    // MARK: Действия

    private func select(tag: String) {
        guard vpn.status == .connected else { return }
        Task { try? await client.select(tag: tag) }
    }

    private func pasteFromClipboard() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            message = "Буфер обмена пуст"; return
        }
        let n = store.importText(text)
        message = n > 0 ? "Добавлено узлов: \(n)" : "В буфере не найдено поддерживаемых ссылок"
    }

    private func refresh(_ sub: Subscription) async {
        do {
            let n = try await store.refresh(subscription: sub)
            message = "Обновлено, узлов: \(n)"
        } catch {
            message = error.localizedDescription
        }
    }

    private func testAll() async {
        testing = true
        defer { testing = false }
        let tags = tagMap
        let url = store.data.settings.urlTestURL
        let c = client
        await withTaskGroup(of: (UUID, Int).self) { group in
            for node in store.data.nodes {
                guard let tag = tags[node.id] else { continue }
                group.addTask { (node.id, (try? await c.delay(tag: tag, url: url)) ?? -1) }
            }
            for await (id, ms) in group { latencies[id] = ms }
        }
    }
}

// MARK: - Листы добавления

struct AddTextSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var result: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 8) {
                Text("Вставьте одну или несколько ссылок (по одной в строке), WireGuard .conf или sing-box JSON.")
                    .font(.footnote).foregroundStyle(.secondary)
                TextEditor(text: $text)
                    .font(.system(.footnote, design: .monospaced))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                if let r = result { Text(r).font(.footnote).foregroundStyle(.orange) }
            }
            .padding()
            .navigationTitle("Добавить узлы")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Добавить") {
                        let n = store.importText(text)
                        if n > 0 { dismiss() } else { result = "Не удалось распознать ни одного узла" }
                    }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

struct AddSubscriptionSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Название (необязательно)", text: $name)
                    TextField("https://…", text: $url)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                }
                if let error { Text(error).foregroundStyle(.red).font(.footnote) }
                if busy { ProgressView() }
            }
            .navigationTitle("Подписка")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Загрузить") {
                        busy = true; error = nil
                        Task {
                            do {
                                _ = try await store.addSubscription(name: name, url: url.trimmingCharacters(in: .whitespaces))
                                dismiss()
                            } catch { self.error = error.localizedDescription }
                            busy = false
                        }
                    }.disabled(url.isEmpty || busy)
                }
            }
        }
    }
}

// MARK: - QR

struct QRScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let c = ScannerController()
        c.onCode = onCode
        return c
    }
    func updateUIViewController(_: ScannerController, context: Context) {}

    final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: ((String) -> Void)?
        private let session = AVCaptureSession()
        private var done = false

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else { return }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.frame = view.layer.bounds
            layer.videoGravity = .resizeAspectFill
            view.layer.addSublayer(layer)
            DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            view.layer.sublayers?.first { $0 is AVCaptureVideoPreviewLayer }?.frame = view.bounds
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            session.stopRunning()
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from _: AVCaptureConnection) {
            guard !done, let obj = objects.first as? AVMetadataMachineReadableCodeObject, let s = obj.stringValue else { return }
            done = true
            onCode?(s)
        }
    }
}
