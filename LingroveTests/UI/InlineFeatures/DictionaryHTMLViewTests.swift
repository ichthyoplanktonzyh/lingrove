import AppKit
import Darwin
import SwiftUI
import Testing
import WebKit
@testable import Lingrove

@Suite(.serialized)
@MainActor
struct DictionaryHTMLViewTests {
    @Test func rendersLocalCSSAndImagesWithoutExecutingDictionaryScripts() async throws {
        var height: CGFloat = 120
        var paths: [String] = []
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        let server = try DictionaryHTTPFixture(data: png)
        defer { server.stop() }
        let serverDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while server.port == nil, ContinuousClock.now < serverDeadline { try await Task.sleep(for: .milliseconds(10)) }
        let port = try #require(server.port)
        let remoteURL = URL(string: "http://127.0.0.1:\(port)/image.png")!
        let (served, _) = try await URLSession.shared.data(from: remoteURL)
        #expect(served == png, "The remote canary must serve a valid image before testing blocked requests")
        let baselineHits = server.hits
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        try png.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let article = LearningDictionaryArticle(html: """
            <link rel="stylesheet" href="book.css"><p id="word">A rich dictionary definition.</p>
            <img id="local" src="test.png"><img id="remote" src="\(remoteURL.absoluteString)">
            <img id="file" src="\(fileURL.absoluteString)"><script>document.body.dataset.dictionaryScriptRan='true'</script>
            """, text: "A rich dictionary definition.", sourceName: "Test")
        let view = DictionaryHTMLView(article: article, loadResource: { path in
            paths.append(path)
            if path == "test.png" { return .init(data: png, mimeType: "image/png") }
            if path == "book.css" { return .init(data: Data("#word{color:rgb(12,34,56)}".utf8), mimeType: "text/css") }
            return nil
        }, reference: { _ in }, height: Binding(get: { height }, set: { height = $0 }))
        let host = NSHostingView(rootView: view.frame(width: 320, height: 300))
        let window = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 320, height: 300),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        let web = try #require(findWebView(host))
        let deadline = ContinuousClock.now.advanced(by: .seconds(12))
        while web.isLoading || height == 120, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!web.isLoading && height != 120, "The app's isolated height measurement must work with content JavaScript disabled")
        #expect(!web.configuration.websiteDataStore.isPersistent)
        #expect(!web.configuration.defaultWebpagePreferences.allowsContentJavaScript)
        let result: Any = try await withCheckedThrowingContinuation { continuation in
            web.evaluateJavaScript("""
                ({script:document.body.dataset.dictionaryScriptRan || 'absent',
                  color:getComputedStyle(document.getElementById('word')).color,
                  local:document.getElementById('local').naturalWidth,
                  remote:document.getElementById('remote').naturalWidth,
                  file:document.getElementById('file').naturalWidth})
                """, in: nil, in: .defaultClient) { continuation.resume(with: $0) }
        }
        let values = try #require(result as? [String: Any])
        #expect(values["script"] as? String == "absent")
        #expect(values["color"] as? String == "rgb(12, 34, 56)")
        #expect(values["local"] as? Int == 1 && values["remote"] as? Int == 0 && values["file"] as? Int == 0)
        #expect(server.hits == baselineHits, "CSP must prevent network requests to a reachable image server")
        #expect(Set(paths) == ["book.css", "test.png"])
    }

    @Test func retiringArticleCancelsItsResourceCallbacks() async throws {
        let coordinator = DictionaryHTMLView.Coordinator(loadResource: { _ in
            try? await Task.sleep(for: .milliseconds(50))
            return .init(data: Data([1]), mimeType: "image/png")
        }, reference: { _ in }, height: .constant(24))
        let task = SchemeTaskProbe(url: coordinator.baseURL.appendingPathComponent("image.png"))
        let web = WKWebView()
        coordinator.webView(web, start: task)
        coordinator.retire()
        try await Task.sleep(for: .milliseconds(80))
        #expect(task.callbacks == 0)
        let foreign = SchemeTaskProbe(url: URL(string: "lingrove-dictionary://different/image.png")!)
        coordinator.webView(web, start: foreign)
        #expect(foreign.failures == 1)
    }

    @Test func longArticlesUseTheOuterScrollViewAndReachTheLastEntry() async throws {
        let lines = (0..<100).map { "<p>Dictionary line \($0): a definition with examples.</p>" }.joined()
        let article = LearningDictionaryArticle(html: lines + "<a id='last' href='entry://word'>Final entry link</a>",
            text: "Long dictionary fixture", sourceName: "Fixture")
        let host = NSHostingView(rootView: DictionaryScrollingFixture(article: article))
        let window = NSWindow(contentRect: .init(x: 120, y: 120, width: 340, height: 300),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Lingrove dictionary scrolling acceptance"
        window.isReleasedWhenClosed = false; window.contentView = host
        if LingroveCompatibility.processEnvironment["LINGROVE_UI_DICTIONARY_REVIEW"] == "1" { window.level = .floating }
        window.orderFrontRegardless()
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        let web = try #require(findWebView(host))
        let deadline = ContinuousClock.now.advanced(by: .seconds(12))
        while web.isLoading || web.bounds.height < 1_000, ContinuousClock.now < deadline {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!web.isLoading && web.bounds.height > 1_000)
        let outer = try #require(web.enclosingScrollView)
        let start = outer.contentView.bounds.origin.y
        let wheel = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                        wheel1: -140, wheel2: 0, wheel3: 0))
        web.scrollWheel(with: try #require(NSEvent(cgEvent: wheel)))
        try await Task.sleep(for: .milliseconds(100))
        #expect(outer.contentView.bounds.origin.y != start, "The web view must forward wheels to the visible outer scroller")
        func internalScrollers(_ view: NSView) -> [NSScrollView] {
            view.subviews.flatMap { ($0 as? NSScrollView).map { [$0] } ?? [] } + view.subviews.flatMap(internalScrollers)
        }
        #expect(internalScrollers(web).allSatisfy { !$0.hasVerticalScroller && !$0.hasHorizontalScroller })
        if LingroveCompatibility.processEnvironment["LINGROVE_UI_DICTIONARY_REVIEW"] == "1" {
            window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .seconds(60))
        }
        outer.contentView.scroll(to: NSPoint(x: 0, y: max(0, (outer.documentView?.bounds.height ?? 0) - outer.contentView.bounds.height)))
        outer.reflectScrolledClipView(outer.contentView)
        let geometry: Any = try await withCheckedThrowingContinuation { continuation in
            web.evaluateJavaScript("""
                ({bottom:document.getElementById('last').getBoundingClientRect().bottom,
                  height:innerHeight,overflow:getComputedStyle(document.documentElement).overflow})
                """, in: nil, in: .defaultClient) { continuation.resume(with: $0) }
        }
        let values = try #require(geometry as? [String: Any])
        #expect(values["overflow"] as? String == "hidden")
        #expect((values["bottom"] as? Double ?? .infinity) <= (values["height"] as? Double ?? 0) + 1)
    }

    private func findWebView(_ view: NSView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        return view.subviews.lazy.compactMap { findWebView($0) }.first
    }
}

/// The stateful parent is the production arrangement: measured HTML paints at document height,
/// and one bounded SwiftUI scroll view owns navigation through that document.
@MainActor
private struct DictionaryScrollingFixture: View {
    let article: LearningDictionaryArticle
    @State private var height: CGFloat = 120
    var body: some View {
        ScrollView {
            DictionaryHTMLView(article: article, loadResource: { _ in nil }, reference: { _ in }, height: $height)
                .frame(height: height)
        }.frame(width: 340, height: 300)
    }
}

@MainActor
private final class SchemeTaskProbe: NSObject, @preconcurrency WKURLSchemeTask {
    let request: URLRequest
    var callbacks = 0
    var failures = 0
    init(url: URL) { request = URLRequest(url: url) }
    func didReceive(_ response: URLResponse) { callbacks += 1 }
    func didReceive(_ data: Data) { callbacks += 1 }
    func didFinish() { callbacks += 1 }
    func didFailWithError(_ error: any Error) { failures += 1 }
}

/// A loopback-only canary proves that an unloaded image was blocked, rather than unavailable.
/// The server queue owns the socket; stop only changes a locked flag so descriptor reuse cannot
/// race an in-flight accept. A short poll keeps teardown bounded.
private nonisolated final class DictionaryHTTPFixture: @unchecked Sendable {
    private let descriptor: Int32
    private let lock = NSLock()
    private var count = 0
    private var stopped = false
    let port: UInt16?
    var hits: Int { lock.lock(); defer { lock.unlock() }; return count }
    init(data: Data) throws {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw URLError(.cannotConnectToHost) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(socketFD, 4) == 0 else { close(socketFD); throw URLError(.cannotConnectToHost) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &length) }
        }
        guard named == 0 else { close(socketFD); throw URLError(.cannotConnectToHost) }
        descriptor = socketFD
        port = UInt16(bigEndian: address.sin_port)
        _ = fcntl(socketFD, F_SETFL, O_NONBLOCK)
        DispatchQueue.global().async { [self] in serve(data) }
    }
    func stop() { lock.lock(); stopped = true; lock.unlock() }
    private var shouldStop: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    private func serve(_ data: Data) {
        defer { close(descriptor) }
        let header = "HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
        let response = Data(header.utf8) + data
        while !shouldStop {
            var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&event, 1, 50) > 0 else { continue }
            let client = accept(descriptor, nil, nil)
            guard client >= 0 else { continue }
            lock.lock(); count += 1; lock.unlock()
            var noSignal: Int32 = 1
            _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(client, F_SETFL, 0)
            var timeout = timeval(tv_sec: 1, tv_usec: 0)
            _ = setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var buffer = [UInt8](repeating: 0, count: 8192)
            _ = buffer.withUnsafeMutableBytes { recv(client, $0.baseAddress, $0.count, 0) }
            _ = response.withUnsafeBytes { send(client, $0.baseAddress, $0.count, 0) }
            close(client)
        }
    }
}
