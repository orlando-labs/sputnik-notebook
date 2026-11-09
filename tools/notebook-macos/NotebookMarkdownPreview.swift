import AppKit
import SwiftUI
import WebKit

struct NotebookMarkdownPreview: NSViewRepresentable {
    let source: String
    let theme: [String: String]

    static func colors(dark: Bool) -> [String: String] {
        _ = NotebookPalette.currentPreset
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        var colors = [String: String]()
        let palette: [String: NSColor] = [
            "paper": NotebookPalette.nativeEditor, "ink": NotebookPalette.nativeInk,
            "rule": NotebookPalette.nativeRule, "muted": NotebookPalette.nativeMuted,
            "accent": NotebookPalette.nativeAccent
        ]
        appearance?.performAsCurrentDrawingAppearance {
            for (key, value) in palette {
                guard let color = value.usingColorSpace(.sRGB) else { continue }
                let channels = [color.redComponent, color.greenComponent, color.blueComponent].map { Int(($0 * 255).rounded()) }
                colors[key] = String(format: "#%02X%02X%02X", channels[0], channels[1], channels[2])
            }
        }
        return colors
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.underPageBackgroundColor = NotebookPalette.nativeEditor
        view.setAccessibilityIdentifier("notebook-markdown-document-preview")
        let entry = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "MarkdownPreview")
            ?? Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("MarkdownPreview/index.html")
        context.coordinator.entry = entry
        if let entry, FileManager.default.fileExists(atPath: entry.path) {
            view.loadFileURL(entry, allowingReadAccessTo: entry.deletingLastPathComponent())
        } else {
            context.coordinator.showFallback(in: view, source: source)
        }
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.update(source: source, theme: theme, in: view)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var entry: URL?
        private var source = ""
        private var theme: [String: String] = [:]
        private var ready = false
        private var rendered: (source: String, theme: [String: String])?

        func update(source: String, theme: [String: String], in view: WKWebView) {
            self.source = source
            self.theme = theme
            render(in: view)
        }

        private func render(in view: WKWebView) {
            guard ready, rendered?.source != source || rendered?.theme != theme else { return }
            rendered = (source, theme)
            let arguments = ["source": source, "theme": theme] as [String: Any]
            Task { @MainActor [weak self, weak view] in
                guard let view else { return }
                do {
                    _ = try await view.callAsyncJavaScript("renderNotebookMarkdown(source, theme)",
                                                           arguments: arguments, in: nil, contentWorld: .page)
                } catch {
                    if let self { self.showFallback(in: view, source: self.source) }
                }
            }
        }

        func showFallback(in view: WKWebView, source: String) {
            ready = false
            let escaped = source.prefix(262144).replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            view.loadHTMLString("""
            <meta charset="utf-8"><meta name="color-scheme" content="light dark">
            <p>Markdown preview is unavailable.</p><pre style="white-space:pre-wrap">\(escaped)</pre>
            """, baseURL: nil)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let entry, webView.url?.path == entry.path else { return }
            ready = true
            render(in: webView)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if !ready { showFallback(in: webView, source: source) }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { decisionHandler(.cancel); return }
            if url.absoluteString == "about:blank" || (url.isFileURL && url.path == entry?.path) {
                decisionHandler(.allow)
                return
            }
            if action.navigationType == .linkActivated, let scheme = url.scheme?.lowercased(),
               ["http", "https", "mailto"].contains(scheme) {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
        }
    }
}
