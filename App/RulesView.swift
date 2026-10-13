import SwiftUI

struct RulesView: View {
    @EnvironmentObject var store: Store
    @State private var editing: Rule?
    @State private var showImport = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Локальные сети напрямую", isOn: $store.data.settings.bypassLAN)
                    Toggle("Россия напрямую (geoip/geosite, .ru)", isOn: $store.data.settings.bypassRU)
                    Toggle("Блокировать рекламу", isOn: $store.data.settings.blockAds)
                } header: {
                    Text("Готовые наборы")
                } footer: {
                    Text(store.data.settings.mode == .rule
                         ? "Правила применяются сверху вниз, первое совпадение побеждает. Всё остальное — через «Прокси»."
                         : "Правила работают только в режиме «По правилам».")
                }

                Section("Мои правила") {
                    ForEach($store.data.rules) { $rule in
                        HStack {
                            Toggle("", isOn: $rule.enabled).labelsHidden()
                            Button { editing = rule } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(rule.value).foregroundStyle(.primary).lineLimit(1)
                                        Text(rule.kind.rawValue).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(rule.action.title)
                                        .font(.caption.bold())
                                        .padding(.horizontal, 8).padding(.vertical, 3)
                                        .background(color(rule.action).opacity(0.15), in: Capsule())
                                        .foregroundStyle(color(rule.action))
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .onDelete { store.data.rules.remove(atOffsets: $0) }
                    .onMove { store.data.rules.move(fromOffsets: $0, toOffset: $1) }
                    if store.data.rules.isEmpty {
                        Text("Правил пока нет. Добавьте вручную или импортируйте список в формате Shadowrocket / Surge / Clash.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Правила")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { editing = Rule(kind: .domainSuffix, value: "", action: .proxy) } label: { Label("Новое правило", systemImage: "plus") }
                        Button { showImport = true } label: { Label("Импорт списка", systemImage: "square.and.arrow.down") }
                    } label: { Image(systemName: "plus") }
                }
            }
            .sheet(item: $editing) { rule in
                RuleEditor(rule: rule) { saved in
                    if let i = store.data.rules.firstIndex(where: { $0.id == saved.id }) {
                        store.data.rules[i] = saved
                    } else {
                        store.data.rules.append(saved)
                    }
                }
            }
            .sheet(isPresented: $showImport) { RuleImportSheet() }
        }
    }

    private func color(_ a: RuleAction) -> Color {
        switch a { case .proxy: return .blue; case .direct: return .green; case .reject: return .red }
    }
}

struct RuleEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var rule: Rule
    let onSave: (Rule) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Picker("Тип", selection: $rule.kind) {
                    ForEach(RuleKind.allCases) { Text($0.rawValue).tag($0) }
                }
                TextField(rule.kind.hint, text: $rule.value)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Picker("Действие", selection: $rule.action) {
                    ForEach(RuleAction.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text("Несколько значений — через запятую.").font(.footnote).foregroundStyle(.secondary)
            }
            .navigationTitle("Правило")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") { onSave(rule); dismiss() }
                        .disabled(rule.value.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

struct RuleImportSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var info: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 8) {
                Text("Формат: DOMAIN-SUFFIX,google.com,PROXY — по строке. Поддерживаются DOMAIN, DOMAIN-SUFFIX, DOMAIN-KEYWORD, IP-CIDR, IP-CIDR6, SRC-IP-CIDR, GEOIP, GEOSITE, DST-PORT. Остальные типы (USER-AGENT, URL-REGEX, PROCESS-NAME и т.п.) пропускаются.")
                    .font(.footnote).foregroundStyle(.secondary)
                TextEditor(text: $text)
                    .font(.system(.footnote, design: .monospaced))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                if let info { Text(info).font(.footnote).foregroundStyle(.orange) }
            }
            .padding()
            .navigationTitle("Импорт правил")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Импорт") {
                        let r = RuleImporter.parse(text)
                        store.data.rules.append(contentsOf: r.rules)
                        if r.rules.isEmpty { info = "Ничего не распознано" }
                        else if r.skipped > 0 { info = "Добавлено: \(r.rules.count), пропущено: \(r.skipped)" }
                        else { dismiss() }
                    }.disabled(text.isEmpty)
                }
            }
        }
    }
}
