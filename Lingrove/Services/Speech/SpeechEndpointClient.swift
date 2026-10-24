import Foundation

/// A speech-only HTTP adapter. It sends only the explicitly requested phrase; endpoint/profile
/// ownership stays separate from completion and translation. Each request owns its transport,
/// so cancelling one utterance cannot cancel a later request's URLSession task.
nonisolated struct SpeechEndpointClient: Sendable {
    private let transfer: @Sendable () -> SpeechHTTPTransfer

    init(transfer: @escaping @Sendable () -> SpeechHTTPTransfer = { SpeechHTTPTransfer() }) {
        self.transfer = transfer
    }

    func audio(text: String, configuration: SpeechEndpointConfiguration, apiKey: String?) async throws -> Data {
        var request = URLRequest(url: configuration.endpoint.apiURL(path: "audio/speech"))
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/wav, audio/mpeg", forHTTPHeaderField: "Accept")
        if let apiKey, !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": configuration.endpoint.modelName, "input": text,
            "voice": configuration.voice, "response_format": "wav"
        ])
        return try await transfer().data(for: request)
    }
}

/// URLSession delivers chunks off the main actor. The lock protects the continuation, task, and
/// bounded buffer across those callbacks and Swift cancellation. No user text/body is logged.
/// @unchecked Sendable is limited to this explicitly locked Objective-C delegate boundary.
nonisolated final class SpeechHTTPTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let maximumBytes = 32 * 1_024 * 1_024
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var bytes = Data()
    private var finished = false
    private let configuration: URLSessionConfiguration

    init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForResource = 120
        self.configuration = configuration
    }

    func data(for request: URLRequest) async throws -> Data {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { waiter in
                lock.lock()
                if finished {
                    lock.unlock()
                    waiter.resume(throwing: CancellationError())
                    return
                }
                continuation = waiter
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                self.session = session
                let task = session.dataTask(with: request)
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            self.finish(.failure(CancellationError()))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // An explicitly selected server cannot redirect spoken text or credentials elsewhere.
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(.failure(SpeechError.generationFailed))
            return
        }
        guard (200...299).contains(response.statusCode) else {
            completionHandler(.cancel)
            finish(.failure(SpeechError.endpointStatus(response.statusCode)))
            return
        }
        guard response.expectedContentLength <= Self.maximumBytes else {
            completionHandler(.cancel)
            finish(.failure(SpeechError.responseTooLarge))
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        let tooLarge = data.count > Self.maximumBytes - bytes.count
        if !tooLarge { bytes.append(data) }
        lock.unlock()
        if tooLarge { finish(.failure(SpeechError.responseTooLarge)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)); return }
        lock.lock()
        let result = bytes
        lock.unlock()
        finish(result.isEmpty ? .failure(SpeechError.invalidAudio) : .success(result))
    }

    private func finish(_ result: Result<Data, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let waiter = continuation
        let session = self.session
        continuation = nil
        self.session = nil
        task = nil
        bytes = Data()
        lock.unlock()
        session?.invalidateAndCancel()
        waiter?.resume(with: result)
    }
}
