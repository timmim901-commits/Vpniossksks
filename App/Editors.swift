import SwiftUI

// MARK: - Редактор узла (JSON)

struct NodeEditorView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss

    /// nil — новый узел.
    let nodeID: UUID?
    var initialJSON: String = ""

    @State private var name = ""
    @State private var text = ""
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Название", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                CodeEditor(text: $text)
                if let error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                } else {
                    Text("JSON одного outbound/endpoint sing-box. Поле tag задаётся названием.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding()
            .navigationTitle(nodeID == nil ? "Новый узел" : "Редактор узла")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Сохранить") { save() } }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button { format() } label: { Label("Формат", systemImage: "text.alignleft") }
                    Button { paste() } label: { Label("Вставить", systemImage: "doc.on.clipboard") }
                    Menu {
                        ForEach(NodeTemplates.all) { t in
                            Button(t.title) { text = t.json; error = nil }
                        }
                    } label: { Label("Шаблоны", systemImage: "doc.badge.plus") }
                    Button { UIPasteboard.general.string = text } label: { Label("Копировать", systemImage: "doc.on.doc") }
                }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                if let id = nodeID, let n = store.data.nodes.first(where: { $0.id == id }) {
                    name = n.name
                    text = n.json
                } else {
                    text = initialJSON
                }
            }
        }
    }

    private func format() {
        if let f = NodeJSON.format(text) { text = f; error = nil }
        else { error = "Не удаётся разобрать JSON" }
    }

    private func paste() {
        if let s = UIPasteboard.general.string { text = s }
    }

    private func save() {
        switch NodeJSON.validate(text: text, name: name) {
        case .failure(let e):
            error = e.localizedDescription
        case .success(let p):
            if let id = nodeID, let i = store.data.nodes.firstIndex(where: { $0.id == id }) {
                store.data.nodes[i].name = p.name
                store.data.nodes[i].type = p.type
                store.data.nodes[i].isEndpoint = p.isEndpoint
                store.data.nodes[i].json = p.json
            } else {
                store.add(nodes: [Node(name: p.name, type: p.type, json: p.json, isEndpoint: p.isEndpoint)])
            }
            Log.app.log("узел сохранён: \(p.name) (\(p.type))")
            dismiss()
        }
    }
}

// MARK: - Редактор цепочки (Relay)

struct ChainEditorView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss

    let chainID: UUID?
    @State private var name = ""
    @State private var members: [UUID] = []
    @State private var loaded = false

    private func node(_ id: UUID) -> Node? { store.data.nodes.first { $0.id == id } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Название цепочки", text: $name)
                } footer: {
                    Text("Трафик идёт по звеньям сверху вниз: первое — ближайшее к устройству, последнее — выход в интернет. Звенья должны быть TCP-совместимыми (UDP-протоколы только последними).")
                }
                Section("Звенья") {
                    ForEach(Array(members.enumerated()), id: \.offset) { i, id in
                        HStack {
                            Text("\(i + 1).").foregroundStyle(.secondary)
                            VStack(alignment: .leading) {
                                Text(node(id)?.name ?? "—")
                                Text((node(id)?.type ?? "").uppercased()).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onMove { members.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { members.remove(atOffsets: $0) }
                    Menu {
                        ForEach(store.data.nodes) { n in
                            Button("\(n.name) · \(n.type)") { members.append(n.id) }
                        }
                    } label: { Label("Добавить звено", systemImage: "plus.circle") }
                    .disabled(store.data.nodes.isEmpty)
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle(chainID == nil ? "Новая цепочка" : "Цепочка")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") { save() }.disabled(members.count < 2)
                }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                if let id = chainID, let c = store.data.chainList.first(where: { $0.id == id }) {
                    name = c.name; members = c.members
                }
            }
        }
    }

    private func save() {
        let title = name.trimmingCharacters(in: .whitespaces).isEmpty ? "Цепочка" : name
        if let id = chainID, let i = store.data.chainList.firstIndex(where: { $0.id == id }) {
            store.data.chainList[i].name = title
            store.data.chainList[i].members = members
        } else {
            store.data.chainList.append(Chain(name: title, members: members))
        }
        dismiss()
    }
}

// MARK: - Свой конфиг целиком

struct CustomConfigView: View {
    @EnvironmentObject var store: Store
    @State private var text = ""
    @State private var info: String?
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Использовать свой конфиг", isOn: Binding(
                get: { store.data.settings.useCustomConfig ?? false },
                set: { store.data.settings.useCustomConfig = $0 }))
            Text("При включении приложение не собирает конфиг само: ядро получает ровно этот JSON. Должен содержать inbound tun, а для пинга и выбора узлов — clash_api на 127.0.0.1:9099.")
                .font(.footnote).foregroundStyle(.secondary)
            CodeEditor(text: $text)
            if let info { Text(info).font(.footnote).foregroundStyle(.orange) }
        }
        .padding()
        .navigationTitle("Свой конфиг")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                Button { fromGenerated() } label: { Label("Из текущего", systemImage: "wand.and.stars") }
                Button {
                    if let f = NodeJSON.format(text) { text = f; info = nil } else { info = "Некорректный JSON" }
                } label: { Label("Формат", systemImage: "text.alignleft") }
                Button { if let s = UIPasteboard.general.string { text = s } } label: { Label("Вставить", systemImage: "doc.on.clipboard") }
                Button { commit() } label: { Label("Сохранить", systemImage: "checkmark.circle") }
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            text = store.data.settings.customConfig ?? ""
            if text.isEmpty { fromGenerated() }
        }
    }

    private func fromGenerated() {
        var d = store.data
        d.settings.useCustomConfig = false
        if let s = try? ConfigBuilder(data: d).build() {
            text = NodeJSON.format(s) ?? s
            info = nil
        } else {
            info = "Не удалось собрать конфиг"
        }
    }

    private func commit() {
        guard let f = NodeJSON.format(text) else { info = "Некорректный JSON — не сохранено"; return }
        text = f
        store.data.settings.customConfig = f
        info = "Сохранено"
    }
}
