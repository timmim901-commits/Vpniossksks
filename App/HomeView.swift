import SwiftUI
import NetworkExtension
import AVFoundation

private enum HomeSheet: Identifiable {
    case addText, addSub, scanner
    case editNode(UUID?, String)
    case editChain(UUID?)
    var id: String {
        switch self {
        case .addText: return "addText"
        case .addSub: return "addSub"
        case .scanner: return "scanner"
        case .editNode(let i, let t): return "node-\(i?.uuidString ?? "new")-\(t.hashValue)"
        case .editChain(let i): return "chain-\(i?.uuidString ?? "new")"
        }
    }
}

struct HomeView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var vpn: VPNManager
    @StateObject private var ping = PingModel()

    @State private var traffic: ClashClient.Traffic?
    @State private var activeTag: String?
    @State private var sheet: HomeSheet?
    @State private var message: String?

    private var client: ClashClient { ClashClient(secret: store.data.settings.clashSecret) }
    private var tagMap: [UUID: String] { ConfigBuilder(data: store.data).tagMap() }
    private var connected: Bool { vpn.status == .connected }
    private var testing: Bool { ping.states.values.contains(.testing) }
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
                        row(title: "Авто (лучший по пингу)", subtitle: "urltest", id: nil,
                            selected: store.data.settings.selectedNodeID == nil)
                    }
                    ForEach(store.data.nodes.filter { !$0.isHelper }) { node in
                        Button {
                            store.data.settings.selectedNodeID = node.id
                            if let tag = tagMap[node.id] { select(tag: tag) }
                        } label: {
                            row(title: node.name, subtitle: node.type.uppercased(), id: node.id,
                                selected: store.data.settings.selectedNodeID == node.id)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { store.remove(nodeIDs: [node.id]) } label: { Label("Удалить", systemImage: "trash") }
                            Button { sheet = .editNode(node.id, "") } label: { Label("JSON", systemImage: "curlybraces") }.tint(.indigo)
                        }
                        .swipeActions(edge: .leading) {
                            Button { Task { await ping.test(id: node.id, store: store, connected: connected) } } label: {
                                Label("Пинг", systemImage: "speedometer")
                            }.tint(.green)
                        }
                    }
                    if store.data.nodes.isEmpty {
                        Text("Добавьте узлы кнопкой «+»: ссылку, подписку, QR, WireGuard-конфиг, либо создайте узел из шаблона/JSON.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }

                let helpers = store.data.nodes.filter { $0.isHelper }
                if !helpers.isEmpty {
                    Section("Звенья (ShadowTLS)") {
                        ForEach(helpers) { node in
                            Button { sheet = .editNode(node.id, "") } label: {
                                VStack(alignment: .leading) {
                                    Text(node.name).foregroundStyle(.primary)
                                    Text("только для цепочек").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .swipeActions {
                                Button(role: .destructive) { store.remove(nodeIDs: [node.id]) } label: { Label("Удалить", systemImage: "trash") }
                            }
                        }
                    }
                }

                Section {
                    ForEach(store.data.chainList) { chain in
                        Button {
                            store.data.settings.selectedNodeID = chain.id
                            if let tag = tagMap[chain.id] { select(tag: tag) }
                        } label: {
                            row(title: "⛓ " + chain.name, subtitle: chainSubtitle(chain), id: chain.id,
                                selected: store.data.settings.selectedNodeID == chain.id)
                        }
                        .swipeActions {
                            Button(role: .destructive) { removeChain(chain) } label: { Label("Удалить", systemImage: "trash") }
                            Button { sheet = .editChain(chain.id) } label: { Label("Изменить", systemImage: "pencil") }.tint(.indigo)
                        }
                    }
                    Button { sheet = .editChain(nil) } label: { Label("Создать цепочку (Relay)", systemImage: "link") }
                        .disabled(store.data.nodes.count < 2)
                } header: { Text("Цепочки") } footer: {
                    Text("Relay: трафик последовательно проходит через несколько узлов, например ShadowTLS → Shadowsocks.")
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
                        Task { await ping.testAll(store: store, connected: connected) }
                    } label: {
                        if testing { ProgressView() } else { Image(systemName: "speedometer") }
                    }
                    .disabled(testing)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { pasteFromClipboard() } label: { Label("Вставить из буфера", systemImage: "doc.on.clipboard") }
                        Button { sheet = .scanner } label: { Label("Сканировать QR", systemImage: "qrcode.viewfinder") }
                        Button { sheet = .addText } label: { Label("Ссылки / JSON / WireGuard", systemImage: "text.cursor") }
                        Button { sheet = .addSub } label: { Label("Подписка по URL", systemImage: "link.badge.plus") }
                        Divider()
                        Menu {
                            ForEach(NodeTemplates.all) { t in
                                Button(t.title) { sheet = .editNode(nil, t.json) }
                            }
                        } label: { Label("Новый узел из шаблона", systemImage: "doc.badge.plus") }
                        Button { sheet = .editNode(nil, "{\n  \"type\": \"\"\n}") } label: { Label("Новый узел (JSON)", systemImage: "curlybraces") }
                        Button { sheet = .editChain(nil) } label: { Label("Новая цепочка", systemImage: "link") }
                    } label: { Image(systemName: "plus") }
                }
            }
            .sheet(item: $sheet) { item in
                switch item {
                case .addText: AddTextSheet()
                case .addSub: AddSubscriptionSheet()
                case .scanner:
                    QRScannerView { code in
                        sheet = nil
                        Task { message = await store.smartImport(code).message }
                    }
                case .editNode(let id, let json): NodeEditorView(nodeID: id, initialJSON: json)
                case .editChain(let id): ChainEditorView(chainID: id)
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
                NavigationLink("Открыть логи") { LogCenterView() }.font(.footnote)
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

    private func chainSubtitle(_ chain: Chain) -> String {
        chain.members.compactMap { id in store.data.nodes.first { $0.id == id }?.type.uppercased() }.joined(separator: " → ")
    }

    @ViewBuilder
    private func pingLabel(_ id: UUID) -> some View {
        switch ping.states[id] {
        case .testing:
            ProgressView().controlSize(.small)
        case .ms(let v):
            Text("\(v) мс").font(.caption.monospacedDigit()).foregroundStyle(v < 300 ? .green : .orange)
        case .failed(let why):
            Text(why).font(.caption).foregroundStyle(.red)
        case .udp:
            Text("UDP").font(.caption).foregroundStyle(.secondary)
        case nil:
            EmptyView()
        }
    }

    private func row(title: String, subtitle: String, id: UUID?, selected: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(.primary)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let id { pingLabel(id) }
            if selected { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
        }
    }

    // MARK: Действия

    private func select(tag: String) {
        guard vpn.status == .connected else { return }
        Task { try? await client.select(tag: tag) }
    }

    private func removeChain(_ chain: Chain) {
        store.data.chainList.removeAll { $0.id == chain.id }
        if store.data.settings.selectedNodeID == chain.id { store.data.settings.selectedNodeID = nil }
    }

    private func pasteFromClipboard() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            message = "Буфер обмена пуст"; return
        }
        Task { message = await store.smartImport(text).message }
    }

    private func refresh(_ sub: Subscription) async {
        do {
            let n = try await store.refresh(subscription: sub)
            message = "Обновлено, узлов: \(n)"
        } catch {
            message = error.localizedDescription
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
                Text("Вставьте ссылки на узлы или подписки (sub://, https://…), по одной в строке, WireGuard .conf или sing-box JSON.")
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
                        Task {
                            let r = await store.smartImport(text)
                            if r.ok { dismiss() } else { result = r.message }
                        }
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
