import Foundation
import Testing
@testable import Cotabby

/// The stub is keyed by URL, so tests can run concurrently without a shared mutable handler.
/// It exercises the actual request builder and bounded URLSession delegate without a real server.
nonisolated private final class SpeechURLProtocol: URLProtocol, @unchecked Sendable {
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let host = url.host ?? ""
        if host == "redirect.test" {
            let destination = URL(string: "https://redirected.test/audio/speech")!
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                headerFields: ["Location": destination.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: destination), redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let status = host == "failure.test" ? 401 : 200
        var payload = Data([1, 2, 3])
        if host == "request.test" {
            var body = request.httpBody
            if body == nil, let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 1_024)
                var result = Data()
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    result.append(buffer, count: count)
                }
                body = result
            }
            payload = (try? JSONSerialization.data(withJSONObject: [
                "path": url.path, "method": request.httpMethod ?? "",
                "authorization": request.value(forHTTPHeaderField: "Authorization") ?? "",
                "body": String(data: body ?? Data(), encoding: .utf8) ?? ""
            ])) ?? Data()
        }
        let length = host == "oversized.test" ? String(SpeechHTTPTransfer.maximumBytes + 1) : String(payload.count)
        var headers = ["Content-Type": "audio/wav"]
        if host != "streamed.test" { headers["Content-Length"] = length }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if host == "streamed.test" {
            let chunk = Data(repeating: 0, count: 1_024 * 1_024)
            for _ in 0..<33 { client?.urlProtocol(self, didLoad: chunk) }
            client?.urlProtocolDidFinishLoading(self)
        } else if host != "waiting.test" {
            client?.urlProtocol(self, didLoad: payload)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

@Suite(.timeLimit(.minutes(1))) struct SpeechEndpointClientTests {
    private func transfer() -> SpeechHTTPTransfer {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SpeechURLProtocol.self]
        return SpeechHTTPTransfer(configuration: configuration)
    }

    @Test func sendsOnlyExplicitSpeechFields() async throws {
        let endpoint = try OpenAICompatibleEndpointConfiguration(baseURLString: "https://request.test",
            modelName: "speech-model", apiMode: .chatCompletions)
        let client = SpeechEndpointClient(transfer: { self.transfer() })
        let result = try await client.audio(text: "Hello.", configuration: .init(endpoint: endpoint, voice: "voice-a"),
            apiKey: "speech-only-key")
        let echo = try #require(JSONSerialization.jsonObject(with: result) as? [String: String])
        #expect(echo["path"] == "/v1/audio/speech")
        #expect(echo["method"] == "POST")
        #expect(echo["authorization"] == "Bearer speech-only-key")
        let body = try #require(echo["body"]?.data(using: .utf8))
        let fields = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(fields == ["input": "Hello.", "model": "speech-model", "voice": "voice-a", "response_format": "wav"])
    }

    @Test(arguments: ["failure.test", "oversized.test", "streamed.test", "redirect.test"])
    func rejectsHTTPFailuresRedirectsAndDeclaredOrStreamedOversize(host: String) async throws {
        let request = URLRequest(url: try #require(URL(string: "https://\(host)/v1/audio/speech")))
        await #expect(throws: SpeechError.self) { try await transfer().data(for: request) }
    }

    @Test func cancellationStopsAResponseThatNeverCompletes() async throws {
        let request = URLRequest(url: try #require(URL(string: "https://waiting.test/v1/audio/speech")))
        let job = Task { try await transfer().data(for: request) }
        try await Task.sleep(for: .milliseconds(30))
        job.cancel()
        await #expect(throws: CancellationError.self) { try await job.value }
    }
}
