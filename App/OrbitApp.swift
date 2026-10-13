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
                .task { await vpn.load() }
                .onReceive(store.$data.dropFirst().debounce(for: .seconds(1), scheduler: RunLoop.main)) { _ in
                    Task { await vpn.apply(store) }
                }
        }
    }
}

struct ContentView: View {
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
    }
}
