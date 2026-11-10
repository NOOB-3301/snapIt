import AppKit
import SwiftUI
import WebKit

/// The answer renderer: bundled Markdown and KaTeX in a web view, no network needed.
struct AnswerView: NSViewRepresentable {
    var turns: [Turn]
    var deadLinks: [String] = []
    var busy = false
    var canRegenerate = true
    var onRegenerate: () -> Void = {}

    private var script: String {
        let payload: [String: Any] = ["turns": turns.map { ["role": $0.role, "text": $0.text] }, "dead": deadLinks]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return "" }
        return "(p => window.render && render(p.turns, p.dead, \(busy), \(canRegenerate)))(\(json))"
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "snapit")
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.setValue(false, forKey: "drawsBackground")
        if let scroll = web.enclosingScrollView {
            scroll.drawsBackground = false
            scroll.verticalScrollElasticity = .none
            scroll.horizontalScrollElasticity = .none
        }
        context.coordinator.web = web
        context.coordinator.onRegenerate = onRegenerate
        context.coordinator.pending = script
        if let dir = Self.webDirectory {
            web.loadFileURL(dir.appendingPathComponent("index.html"), allowingReadAccessTo: dir)
        }
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        context.coordinator.onRegenerate = onRegenerate
        context.coordinator.pending = script
        context.coordinator.flush()
    }

    private static var webDirectory: URL? {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("web")
        if let bundled, FileManager.default.fileExists(atPath: bundled.appendingPathComponent("index.html").path) { return bundled }
        // Running .build/debug/SnapIt straight from SwiftPM, where there is no resource bundle.
        let repo = Bundle.main.executableURL?.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/web")
        if let repo, FileManager.default.fileExists(atPath: repo.appendingPathComponent("index.html").path) { return repo }
        Log.write("answer renderer missing: web/index.html")
        return nil
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var web: WKWebView?
        var onRegenerate: () -> Void = {}
        var pending = ""
        private var loaded = false
        private var last = ""

        func flush() {
            guard loaded, !pending.isEmpty, pending != last, let web else { return }
            last = pending
            web.evaluateJavaScript(pending) { _, error in
                if let error { Log.write("answer render failed: \(error.localizedDescription)") }
            }
        }

        /// Trust boundary: the page shows text from the web, so only these two messages do anything.
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            if let text = body["copy"] as? String {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            } else if body["regenerate"] as? Bool == true {
                onRegenerate()
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            flush()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            Log.write("answer renderer failed to load: \(error.localizedDescription)")
        }

        /// Links open in the browser: the renderer never navigates, so it cannot fetch anything by itself.
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
                if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}