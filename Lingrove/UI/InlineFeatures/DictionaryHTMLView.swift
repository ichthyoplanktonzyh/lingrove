import AppKit
import SwiftUI
import WebKit

/// A card-owned, disposable web view renders dictionary typography without inheriting a browser
/// session. Its coordinator owns resource requests only until this article is replaced/closed.
struct DictionaryHTMLView: NSViewRepresentable {
    let article: LearningDictionaryArticle
    let loadResource: DictionaryResourceLoader
    let reference: (String) -> Void
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator {
        let loader = loadResource
        return Coordinator(loadResource: { path in await loader(path) }, reference: reference, height: $height)
    }
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.setURLSchemeHandler(context.coordinator, forURLScheme: "lingrove-dictionary")
        let view = DictionaryArticleWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.underPageBackgroundColor = .clear
        view.loadHTMLString(DictionaryHTMLPolicy.document(article.html), baseURL: context.coordinator.baseURL)
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {}
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.retire()
        view.stopLoading()
        view.navigationDelegate = nil
    }

    /// Each document has an unguessable origin and a byte/request budget. The resource loader
    /// already knows its dictionary; URLs cannot select another book or expose arbitrary files.
    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKURLSchemeHandler {
        let baseURL = URL(string: "lingrove-dictionary://" + UUID().uuidString.lowercased() + "/")!
        private let loadResource: DictionaryResourceLoader
        private let reference: (String) -> Void
        private var height: Binding<CGFloat>
        private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
        private var retired = false
        private var bytes = 0
        private var requests = 0

        init(loadResource: @escaping DictionaryResourceLoader,
             reference: @escaping (String) -> Void, height: Binding<CGFloat>) {
            self.loadResource = loadResource
            self.reference = reference
            self.height = height
        }
        func retire() { retired = true; tasks.values.forEach { $0.cancel() }; tasks.removeAll() }

        func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
            let id = ObjectIdentifier(urlSchemeTask)
            requests += 1
            guard !retired, requests <= 128, let url = urlSchemeTask.request.url,
                  url.host == baseURL.host, let path = DictionaryContentPolicy.resourcePath(url.path) else {
                urlSchemeTask.didFailWithError(URLError(.noPermissionsToReadFile)); return
            }
            tasks[id] = Task { [weak self] in
                guard let self else { return }
                let resource = await loadResource(path)
                guard !Task.isCancelled, !retired, tasks[id] != nil else { return }
                tasks[id] = nil
                guard let resource, bytes + resource.data.count <= 16_000_000 else {
                    urlSchemeTask.didFailWithError(URLError(.resourceUnavailable)); return
                }
                bytes += resource.data.count
                urlSchemeTask.didReceive(URLResponse(url: url, mimeType: resource.mimeType,
                    expectedContentLength: resource.data.count, textEncodingName: resource.mimeType == "text/css" ? "utf-8" : nil))
                urlSchemeTask.didReceive(resource.data)
                urlSchemeTask.didFinish()
            }
        }
        func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
            tasks.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.cancel()
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // This constant executes in the app's isolated world, never dictionary JavaScript.
            // Keeping a single outer scroll view preserves the card's header/favorite actions.
            webView.evaluateJavaScript("Math.min(12000,Math.max(24,document.documentElement.scrollHeight))",
                                      in: nil, in: .defaultClient) { [weak self] result in
                guard let self, !self.retired, case .success(let value) = result, let number = value as? NSNumber else { return }
                self.height.wrappedValue = CGFloat(number.doubleValue)
            }
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard !retired, let url = navigationAction.request.url else { decisionHandler(.cancel); return }
            if navigationAction.navigationType == .linkActivated {
                if let query = DictionaryLinkPolicy.reference(url) {
                    reference(query)
                } else if let external = DictionaryLinkPolicy.externalURL(url.absoluteString) {
                    NSWorkspace.shared.open(external)
                }
                decisionHandler(.cancel)
            } else {
                decisionHandler(url.absoluteString == "about:blank" || url == baseURL ? .allow : .cancel)
            }
        }
    }
}

/// HTML paints at document height inside the card's existing scroll view. WebKit's internal
/// scroll surface must not consume wheels or add another pair of scrollers. Hit testing only
/// redirects wheel events; text selection and dictionary links keep their normal WebKit path.
private final class DictionaryArticleWebView: WKWebView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        if NSApp.currentEvent?.type == .scrollWheel, let scroll = enclosingScrollView { return scroll }
        return super.hitTest(point)
    }

    override func scrollWheel(with event: NSEvent) {
        enclosingScrollView?.scrollWheel(with: event)
    }

    override func layout() {
        super.layout()
        suppressScrollers(in: self)
    }

    private func suppressScrollers(in view: NSView) {
        for child in view.subviews {
            if let scroll = child as? NSScrollView {
                if scroll.hasVerticalScroller { scroll.hasVerticalScroller = false }
                if scroll.hasHorizontalScroller { scroll.hasHorizontalScroller = false }
                scroll.verticalScrollElasticity = .none
                scroll.horizontalScrollElasticity = .none
            }
            suppressScrollers(in: child)
        }
    }
}
