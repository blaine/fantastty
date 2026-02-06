import SwiftUI
import WebKit

/// A browser tab view with URL bar and WKWebView content.
struct BrowserTabView: View {
    @ObservedObject var tab: TerminalTab
    @State private var urlText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            // URL bar
            HStack(spacing: 8) {
                // Back/Forward
                Button { tab.webView?.goBack() } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.plain)
                .disabled(!(tab.webView?.canGoBack ?? false))

                Button { tab.webView?.goForward() } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.plain)
                .disabled(!(tab.webView?.canGoForward ?? false))

                Button { tab.webView?.reload() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)

                // URL text field
                TextField("Enter URL...", text: $urlText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
                    .onSubmit {
                        navigateTo(urlText)
                    }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            // Web content
            WebViewRepresentable(tab: tab)
        }
        .onAppear {
            urlText = tab.url?.absoluteString ?? ""
        }
        .onChange(of: tab.url) {
            urlText = tab.url?.absoluteString ?? ""
        }
    }

    private func navigateTo(_ input: String) {
        var urlString = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !urlString.contains("://") {
            urlString = "https://\(urlString)"
        }
        guard let url = URL(string: urlString) else { return }
        tab.url = url
        tab.webView?.load(URLRequest(url: url))
    }
}

/// NSViewRepresentable wrapper for WKWebView.
struct WebViewRepresentable: NSViewRepresentable {
    @ObservedObject var tab: TerminalTab

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.navigationDelegate = context.coordinator
        tab.webView = webView

        if let url = tab.url {
            webView.load(URLRequest(url: url))
        }

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Only load if the URL changed and differs from current page
        if let url = tab.url, webView.url != url {
            webView.load(URLRequest(url: url))
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(tab: tab)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        let tab: TerminalTab

        init(tab: TerminalTab) {
            self.tab = tab
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            tab.title = webView.title ?? tab.url?.host ?? "Browser"
            if let currentURL = webView.url {
                tab.url = currentURL
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            if let currentURL = webView.url {
                tab.url = currentURL
            }
        }
    }
}
