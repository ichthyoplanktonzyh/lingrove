import Foundation
import Testing
@testable import Lingrove

/// The executable fixture speaks the real framed protocol and delivers PCM blocks. These
/// tests exercise async pipe readiness, reuse, cancellation/reaping, and idle unloading without
/// requiring a downloaded neural model; model-backed acceptance is a separate Release run.
@Suite(.timeLimit(.minutes(1))) struct LocalSpeechRuntimeTests {
    @Test func fastReadyAndTwoSequentialRequestsReuseOneHelper() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runtime = LocalSpeechRuntime(helperURL: fixture.helper)
        let first = try await collect(runtime, for: fixture.request("first"), configuration: fixture.configuration)
        let second = try await collect(runtime, for: fixture.request("second"), configuration: fixture.configuration)
        #expect(first == second)
        let pids = try String(contentsOf: fixture.record, encoding: .utf8).split(separator: "\n")
        #expect(pids.count == 1)
        await runtime.shutdown()
    }

    @Test func requestSamplingChangesDoNotReloadTheSameModel() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runtime = LocalSpeechRuntime(helperURL: fixture.helper)
        var first = fixture.request("first")
        first.sampling = .init(temperature: 0.1, topP: 0.7, topK: 12, repetitionPenalty: 1.1, seedMode: .fixed, fixedSeed: 81)
        _ = try await collect(runtime, for: first, configuration: fixture.configuration)
        _ = try await collect(runtime, for: fixture.request("second"), configuration: fixture.configuration)
        let rows = try String(contentsOf: fixture.root.appendingPathComponent("parameters"), encoding: .utf8)
            .split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        #expect(rows.count == 2)
        #expect(rows[0]["temperature"] as? Double == 0.1 && rows[0]["seed"] as? Int == 81)
        #expect(rows[0]["top_k"] as? Int == 12 && rows[0]["top_p"] as? Double == 0.7)
        #expect(rows[1]["temperature"] as? Double == 0.8 && rows[1]["seed"] as? Int == 42)
        #expect(try String(contentsOf: fixture.record, encoding: .utf8).split(separator: "\n").count == 1)
        await runtime.shutdown()
    }

    @Test func cancelledRequestIsReapedAndNextRequestSucceeds() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runtime = LocalSpeechRuntime(helperURL: fixture.helper)
        let request = fixture.request("wait")
        let job = Task { try await collect(runtime, for: request, configuration: fixture.configuration) }
        try await Task.sleep(for: .milliseconds(150))
        job.cancel()
        await runtime.cancel(request.token)
        await #expect(throws: (any Error).self) { try await job.value }
        let data = try await collect(runtime, for: fixture.request("after"), configuration: fixture.configuration)
        #expect(data.count == 9_600)
        await runtime.shutdown()
    }

    @Test func idleTimeoutUnloadsTheHelper() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runtime = LocalSpeechRuntime(helperURL: fixture.helper, idleTimeout: .milliseconds(30))
        _ = try await collect(runtime, for: fixture.request("first"), configuration: fixture.configuration)
        try await Task.sleep(for: .milliseconds(200))
        _ = try await collect(runtime, for: fixture.request("second"), configuration: fixture.configuration)
        let pids = try String(contentsOf: fixture.record, encoding: .utf8).split(separator: "\n")
        #expect(pids.count == 2)
        await runtime.shutdown()
    }

    @Test func operationTimeoutDoesNotPoisonTheNextRequest() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runtime = LocalSpeechRuntime(helperURL: fixture.helper, operationTimeout: .seconds(2))
        await #expect(throws: (any Error).self) {
            try await collect(runtime, for: fixture.request("ignore-term"), configuration: fixture.configuration)
        }
        let data = try await collect(runtime, for: fixture.request("after"), configuration: fixture.configuration)
        #expect(data.count == 9_600)
        await runtime.shutdown()
    }

    @Test func cancellationDuringDrainDoesNotNeedAnExplicitCancelCall() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runtime = LocalSpeechRuntime(helperURL: fixture.helper)
        let first = Task { try await collect(runtime, for: fixture.request("ignore-term"), configuration: fixture.configuration) }
        for _ in 0..<300 {
            let marker = try? String(contentsOf: fixture.root.appendingPathComponent("requests"), encoding: .utf8)
            if marker?.contains("ignore-term") == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let second = Task { try await collect(runtime, for: fixture.request("second"), configuration: fixture.configuration) }
        try await Task.sleep(for: .milliseconds(150))
        second.cancel()
        await #expect(throws: CancellationError.self) { try await second.value }
        await #expect(throws: (any Error).self) { try await first.value }
        let data = try await collect(runtime, for: fixture.request("after"), configuration: fixture.configuration)
        #expect(data.count == 9_600)
        let starts = try String(contentsOf: fixture.record, encoding: .utf8).split(separator: "\n")
        #expect(starts.count == 2)
        await runtime.shutdown()
    }

    @Test func blockedTelemetryDoesNotHoldGenerationOrReaping() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let gate = SpeechEventGate()
        let runtime = LocalSpeechRuntime(helperURL: fixture.helper, events: { _ in await gate.wait() })
        defer { Task { await gate.release() } }
        let data = try await collect(runtime, for: fixture.request("first"), configuration: fixture.configuration)
        #expect(data.count == 9_600)
        await runtime.shutdown()
        let pids = try String(contentsOf: fixture.record, encoding: .utf8).split(separator: "\n")
        for text in pids {
            if let pid = Int32(text) { #expect(kill(pid, 0) != 0) }
        }
        await gate.release()
    }

    private func collect(_ runtime: LocalSpeechRuntime, for request: SpeechAudioRequest,
                         configuration: SpeechLocalConfiguration) async throws -> Data {
        let collector = PCMCollector()
        try await runtime.stream(for: request, configuration: configuration) { await collector.append($0) }
        return await collector.data
    }

    @Test func blockedPlaybackReceiverDoesNotPreventCancellationOrNewSession() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runtime = LocalSpeechRuntime(helperURL: fixture.helper)
        let gate = SpeechEventGate()
        let request = fixture.request("first")
        let job = Task {
            try await runtime.stream(for: request, configuration: fixture.configuration) { _ in await gate.wait() }
        }
        for _ in 0..<200 {
            if await gate.entered { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await gate.entered)
        await runtime.cancel(request.token)
        await #expect(throws: (any Error).self) { try await job.value }
        let data = try await collect(runtime, for: fixture.request("after"), configuration: fixture.configuration)
        #expect(data.count == 9_600)
        await gate.release()
        await runtime.shutdown()
    }

    @Test func deliversBeforeGenerationCompletesAndCancelsWhileReceiving() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runtime = LocalSpeechRuntime(helperURL: fixture.helper)
        let collector = PCMCollector()
        let request = fixture.request("chunk-then-wait")
        let job = Task {
            try await runtime.stream(for: request, configuration: fixture.configuration) { await collector.append($0) }
        }
        for _ in 0..<200 {
            if await !collector.data.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await collector.data.count == 9_600)
        job.cancel()
        await #expect(throws: (any Error).self) { try await job.value }
        await runtime.shutdown()
    }

    @Test(arguments: ["wrong-sequence", "truncated"])
    func invalidStreamFailsAndNextRequestRecovers(_ text: String) async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runtime = LocalSpeechRuntime(helperURL: fixture.helper)
        await #expect(throws: (any Error).self) {
            try await collect(runtime, for: fixture.request(text), configuration: fixture.configuration)
        }
        let data = try await collect(runtime, for: fixture.request("after"), configuration: fixture.configuration)
        #expect(data.count == 9_600)
        await runtime.shutdown()
    }

    private struct Fixture {
        let root: URL
        let helper: URL
        let record: URL
        var configuration: SpeechLocalConfiguration {
            .init(modelURL: root.appendingPathComponent("model.gguf"),
                projectionURL: root.appendingPathComponent("decoder.gguf"), referenceAudioURL: nil)
        }
        func request(_ text: String) -> SpeechAudioRequest {
            .init(token: SpeechPlaybackToken(), text: text, language: .english, source: .local(configuration))
        }
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("speech-runtime-test-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            helper = root.appendingPathComponent("helper")
            record = root.appendingPathComponent("starts")
            let script = #"""
            #!/usr/bin/python3
            import sys,json,os,time,struct,signal
            with open(os.path.join(os.path.dirname(__file__),'starts'),'a') as f: f.write(str(os.getpid())+'\n')
            def send(value,data=b''):
                h=json.dumps(value).encode()
                sys.stdout.buffer.write(struct.pack('>I',len(h))+h+data);sys.stdout.buffer.flush()
            send({'event':'ready','protocol_version':2})
            for line in sys.stdin:
                r=json.loads(line)
                with open(os.path.join(os.path.dirname(__file__),'parameters'),'a') as f: f.write(json.dumps(r)+'\n')
                if r['text']=='ignore-term': signal.signal(signal.SIGTERM,signal.SIG_IGN)
                with open(os.path.join(os.path.dirname(__file__),'requests'),'a') as f: f.write(r['text']+'\n')
                if r['text'] in ('wait','ignore-term'): time.sleep(10)
                send({'event':'chunk','id':r['id'],'sequence':0,'sample_rate':24000,'samples':2400,
                    'payload_bytes':9600,'format':'f32le','channels':1},bytes(9600))
                if r['text']=='chunk-then-wait': time.sleep(10)
                if r['text']=='wrong-sequence':
                    send({'event':'chunk','id':r['id'],'sequence':0,'sample_rate':24000,'samples':2400,
                        'payload_bytes':9600,'format':'f32le','channels':1},bytes(9600))
                if r['text']=='truncated':
                    sys.stdout.buffer.write(struct.pack('>I',200)+b'{');sys.stdout.buffer.flush();sys.exit()
                send({'event':'result','id':r['id'],'ok':True,'samples':2400,'sample_rate':24000})
            """#
            try script.write(to: helper, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        }
    }
}

/// A deliberately blocked observer proves that logging/UI delivery cannot own native lifetime.
private actor SpeechEventGate {
    private(set) var entered = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        entered = true
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        released = true
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
    }
}

private actor PCMCollector {
    private(set) var data = Data()
    func append(_ chunk: SpeechPCMChunk) { data.append(chunk.data) }
}
