import SwiftUI
import Combine

@main
struct OrbitApp: App {
    @StateObject private var store = Store()
    @StateObject private var vpn = VPNManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(vpn)
                .task {
                    Log.app.log("запуск приложения: iOS \(UIDevice.current.systemVersion), \(UIDevice.current.model), bundle=\(Bundle.main.bundleIdentifier ?? "?"), группа=\(FilePath.hasGroupContainer)")
                    await vpn.load()
                }
                .onOpenURL { url in
                    Log.app.log("открыта ссылка: \(url.scheme ?? "?")://…")
                    Task {
                        let r = await store.smartImport(url.absoluteString)
                        store.toast = r.message
                    }
                }
                .onReceive(store.$data.dropFirst().debounce(for: .seconds(1), scheduler: RunLoop.main)) { _ in
                    Task { await vpn.apply(store) }
                }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("Узлы", systemImage: "bolt.horizontal.circle") }
            RulesView()
                .tabItem { Label("Правила", systemImage: "list.bullet.rectangle") }
            TailscaleView()
                .tabItem { Label("Tailscale", systemImage: "point.3.connected.trianglepath.dotted") }
            SiteView()
                .tabItem { Label("Сайт", systemImage: "globe") }
            SettingsView()
                .tabItem { Label("Ещё", systemImage: "gearshape") }
        }
        .alert("Orbit", isPresented: Binding(get: { store.toast != nil }, set: { if !$0 { store.toast = nil } })) {
            Button("OK") { store.toast = nil }
        } message: { Text(store.toast ?? "") }
    }
}
