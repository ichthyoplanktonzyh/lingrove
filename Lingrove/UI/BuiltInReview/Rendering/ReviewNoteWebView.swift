import LingroveNotebook
import AppKit
import SwiftUI
import WebKit

/// A disposable renderer for resolved note HTML/CSS. It has no session, storage, account or
/// scheduling dependency. Templates use only the caller's in-memory media map; WebKit owns
/// scrolling and selection inside this surface while the native host keeps rating controls.
struct ReviewNoteWebView: NSViewRepresentable {
    let html: String
    let css: String
    var images: [String: Data] = [:]
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.setURLSchemeHandler(context.coordinator, forURLScheme: "lingrove-review")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.underPageBackgroundColor = .clear
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        let appearance = colorScheme == .dark ? "dark" : "light"
        let document = ReviewNoteHTMLDocument.make(html: html, css: css, dark: appearance == "dark")
        let coordinator = context.coordinator
        guard coordinator.document != document || coordinator.images != images else { return }
        coordinator.document = document; coordinator.images = images
        view.loadHTMLString(document, baseURL: coordinator.baseURL)
    }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.retired = true; coordinator.images = [:]
        view.stopLoading(); view.navigationDelegate = nil
    }
    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKURLSchemeHandler {
        let baseURL = URL(string: "lingrove-review://" + UUID().uuidString.lowercased() + "/")!
        var images: [String: Data] = [:]
        var document = ""
        var retired = false
        func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
            guard !retired, let url = task.request.url, url.host == baseURL.host,
                  url.path == "/" + url.lastPathComponent, let bytes = images[url.lastPathComponent], bytes.count <= 16_777_216 else {
                task.didFailWithError(URLError(.resourceUnavailable)); return
            }
            task.didReceive(URLResponse(url: url, mimeType: "image/png", expectedContentLength: bytes.count, textEncodingName: nil))
            task.didReceive(bytes); task.didFinish()
        }
        func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard !retired, action.navigationType != .linkActivated, let url = action.request.url else {
                decisionHandler(.cancel); return
            }
            decisionHandler(url.absoluteString == "about:blank" || url == baseURL ? .allow : .cancel)
        }
    }
}
