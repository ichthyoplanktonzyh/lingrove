import Foundation

/// One app-owned actor speaks AnkiConnect v6. Ephemeral transport drops cookies, disallows
/// redirects, and bounds responses; even an unexpected local redirect cannot forward a key or
/// vocabulary text to another host. Request bodies and server errors never enter app logs.
actor AnkiConnectClient: AnkiConnecting {
    private let session: URLSession
    init(session: URLSession? = nil) {
        self.session = session ?? LearningEndpointSession.makeSession()
    }

    func perform(_ action: String, params: [String: AnkiValue], connection: AnkiConnection) async throws -> AnkiValue {
        guard AnkiReviewPolicy.endpoint(connection.endpoint.absoluteString) != nil else { throw invalidResponse() }
        var body: [String: AnkiValue] = ["action": .string(action), "version": .number(6), "params": .object(params)]
        if !connection.apiKey.isEmpty { body["key"] = .string(connection.apiKey) }
        var request = URLRequest(url: connection.endpoint, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { throw invalidResponse() }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 2_000_000 else { throw invalidResponse() }
                data.append(byte)
            }
            try Task.checkCancellation()
            guard let envelope = try JSONDecoder().decode(AnkiValue.self, from: data).object,
                  let error = envelope["error"], let result = envelope["result"] else { throw invalidResponse() }
            guard error == .null else {
                // Add-on error strings can contain note fields and keys. Surface a bounded,
                // actionable application message rather than forwarding arbitrary server text.
                throw AnkiReviewError.message(String(localized: "Anki rejected the request. Check the API key, fields and active profile.",
                    table: "Vocabulary"))
            }
            return result
        } catch let error as AnkiReviewError { throw error } catch is CancellationError { throw CancellationError() } catch {
            throw AnkiReviewError.message(String(localized: "Could not connect to Anki. Open Anki with AnkiConnect enabled.",
                table: "Vocabulary"))
        }
    }

    private func invalidResponse() -> AnkiReviewError {
        .message(String(localized: "AnkiConnect returned an invalid response.", table: "Vocabulary"))
    }
}
