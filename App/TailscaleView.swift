import SwiftUI

struct TailscaleView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Включить Tailscale", isOn: $store.data.tailscale.enabled)
                } footer: {
                    Text("Tailscale работает внутри того же туннеля, что и остальной трафик (на iOS одновременно активен только один VPN). Адреса 100.64.0.0/10 и имена *.ts.net идут через tailnet.")
                }

                if store.data.tailscale.enabled {
                    Section {
                        SecureField("tskey-auth-…", text: $store.data.tailscale.authKey)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("Control URL (Headscale), пусто = Tailscale", text: $store.data.tailscale.controlURL)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        TextField("Имя устройства (по умолчанию — имя iPhone)", text: $store.data.tailscale.hostname)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    } header: { Text("Вход") } footer: {
                        Text("Создайте Auth key в админке Tailscale (Settings → Keys), лучше reusable. Без ключа вход потребует ссылки из журнала ядра.")
                    }

                    Section("Сеть") {
                        Toggle("Принимать маршруты (subnet routes)", isOn: $store.data.tailscale.acceptRoutes)
                        TextField("Exit node (имя или IP)", text: $store.data.tailscale.exitNode)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Toggle("Локальная сеть напрямую при exit node", isOn: $store.data.tailscale.exitNodeAllowLAN)
                        Toggle("Весь остальной трафик через exit node", isOn: $store.data.tailscale.routeAllViaExit)
                            .disabled(store.data.tailscale.exitNode.isEmpty)
                    }
                }
            }
            .navigationTitle("Tailscale")
        }
    }
}
