//
//  QwenAuthView.swift
//  JustaUsageBar
//
//  Signs in to the QwenCloud console in a private web view and hands back the
//  console's Cookie header, which is what reads Token Plan usage. The web view
//  keeps nothing on disk; only the header is saved, encrypted, by Usagebar.
//

import SwiftUI
import WebKit

struct QwenAuthView: View {
    @Environment(\.dismiss) private var dismiss
    let onAuthenticated: (String) -> Void
    @State private var status = "Sign in to QwenCloud to show your Token Plan limits."
    @State private var isDone = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sign in to QwenCloud")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Button("Cancel") { dismiss() }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            HStack(spacing: 6) {
                if isDone {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                Text(status)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)

            Divider()

            QwenWebView { cookie in
                guard !isDone else { return }
                isDone = true
                status = "Signed in. Loading your limits…"
                onAuthenticated(cookie)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { dismiss() }
            }
        }
        .frame(width: 480, height: 640)
    }
}

private struct QwenWebView: NSViewRepresentable {
    let onSignedIn: (String) -> Void

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        webView.load(URLRequest(url: QwenAPIService.dashboardURL))
        context.coordinator.start(webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.stop()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onSignedIn: onSignedIn)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        /// Cookies the console sets once a sign-in has gone through.
        private static let sessionCookies: Set<String> = [
            "login_aliyunid_ticket", "login_qwencloud_ticket", "qwen_sso_ticket"
        ]

        let onSignedIn: (String) -> Void
        private let checkTimer = RepeatingTimer()
        private weak var webView: WKWebView?
        private var hasFinished = false
        private var hasOpenedLogin = false

        init(onSignedIn: @escaping (String) -> Void) {
            self.onSignedIn = onSignedIn
        }

        func start(_ webView: WKWebView) {
            self.webView = webView
            checkTimer.start(every: 1.5) { [weak self] in self?.check() }
        }

        func stop() {
            checkTimer.stop()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            check()
            // Signed out, the console shows a "Log in now" button instead of
            // redirecting, so press it once to go straight to the sign-in.
            guard !hasOpenedLogin, webView.url?.host == "home.qwencloud.com" else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self, weak webView] in
                guard let self, !self.hasFinished, !self.hasOpenedLogin, let webView else { return }
                webView.evaluateJavaScript("""
                    (() => {
                        const button = [...document.querySelectorAll('button')]
                            .find(b => /log\\s*in now/i.test(b.textContent || ''));
                        if (button) { button.click(); return true; }
                        return false;
                    })()
                    """) { [weak self] result, _ in
                    if result as? Bool == true { self?.hasOpenedLogin = true }
                }
            }
        }

        /// Sign-in providers that open a popup load in the same view instead.
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            return nil
        }

        /// Done once the console itself is showing and its session cookies exist.
        private func check() {
            guard !hasFinished, let webView, webView.url?.host == "home.qwencloud.com" else { return }
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self, !self.hasFinished else { return }
                let console = cookies.filter { $0.domain.hasSuffix("qwencloud.com") && !$0.value.isEmpty }
                guard console.contains(where: { Self.sessionCookies.contains($0.name) }) else { return }
                self.hasFinished = true
                self.stop()
                var seen: Set<String> = []
                let header = console
                    .filter { seen.insert($0.name).inserted }
                    .map { "\($0.name)=\($0.value)" }
                    .joined(separator: "; ")
                self.onSignedIn(header)
            }
        }
    }
}
