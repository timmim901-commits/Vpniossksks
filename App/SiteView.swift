import SwiftUI
import WebKit

final class WebController: ObservableObject {
    let webView: WKWebView = {
        let c = WKWebViewConfiguration()
        c.allowsInlineMediaPlayback = true
        let w = WKWebView(frame: .zero, configuration: c)
        w.allowsBackForwardNavigationGestures = true
        return w
    }()
    private var loaded: String?

    func loadIfNeeded(_ urlString: String) {
        guard loaded != urlString, let url = URL(string: urlString) else { return }
        loaded = urlString
        webView.load(URLRequest(url: url))
    }
}

struct WebContainer: UIViewRepresentable {
    let controller: WebController
    func makeUIView(context: Context) -> WKWebView { controller.webView }
    func updateUIView(_: WKWebView, context: Context) {}
}

struct SiteView: View {
    @EnvironmentObject var store: Store
    @StateObject private var web = WebController()

    var body: some View {
        NavigationStack {
            WebContainer(controller: web)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(URL(string: store.data.settings.siteURL)?.host ?? "Сайт")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItemGroup(placement: .topBarLeading) {
                        Button { web.webView.goBack() } label: { Image(systemName: "chevron.left") }
                        Button { web.webView.goForward() } label: { Image(systemName: "chevron.right") }
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button { web.webView.reload() } label: { Image(systemName: "arrow.clockwise") }
                        Button {
                            if let u = URL(string: store.data.settings.siteURL) { UIApplication.shared.open(u) }
                        } label: { Image(systemName: "safari") }
                    }
                }
                .onAppear { web.loadIfNeeded(store.data.settings.siteURL) }
                .onChange(of: store.data.settings.siteURL) { web.loadIfNeeded($0) }
        }
    }
}
