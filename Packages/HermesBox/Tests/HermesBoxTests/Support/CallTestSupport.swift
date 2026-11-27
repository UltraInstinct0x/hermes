import Foundation

@testable import HermesBox

let testCallId = "123e4567-e89b-12d3-a456-426614174000"
let testBotKey = "oracle::hermesbot"

/// Hub frames as the hub's own code builds them (`box/call-hub/hub.mjs`), as JSON text.
enum Hub {
    static func text(_ object: [String: Any]) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
    }

    static func participant(_ id: String, kind: String = "ios", label: String = "", role: String = "listener") -> [String: Any] {
        ["client_id": id, "kind": kind, "label": label, "role": role, "connected": true, "audio_out": role == "owner", "joined_at": 1]
    }

    static func summary(
        state: String = "active", owner: String? = "phone", epoch: Int = 1, engine: String = "free", seq: Int = 0,
        participants: [[String: Any]]? = nil, ended: String? = nil
    ) -> [String: Any] {
        var call: [String: Any] = [
            "call_id": testCallId, "bot_key": testBotKey, "engine": engine, "state": state, "owner_epoch": epoch,
            "participants": participants ?? (owner.map { [participant($0, role: "owner")] } ?? []), "started_at": 1000, "last_activity_at": 1000,
            "ended_at": NSNull(), "voice_session_id": "v1", "bot_session_id": "b1", "seq": seq,
        ]
        call["owner_client_id"] = owner ?? NSNull()
        call["ended_reason"] = ended ?? NSNull()
        return call
    }

    static func helloOk(client: String = "phone", calls: [[String: Any]] = [], yours: [[String: Any]] = []) -> String {
        text([
            "type": "hello.ok", "proto": 1, "client_id": client, "server_time": 1,
            "limits": ["max_participants": 8], "calls": calls, "yours": yours,
        ])
    }

    static func started(id: String, epoch: Int = 1) -> String {
        text(["type": "call.started", "id": id, "call_id": testCallId, "owner_epoch": epoch, "call": summary(epoch: epoch)])
    }

    static func state(role: String?, epoch: Int, call: [String: Any]) -> String {
        text(["type": "call.state", "call": call, "you": ["role": role as Any? ?? NSNull(), "owner_epoch": epoch]])
    }

    static func joined(id: String?, role: String?, epoch: Int, events: [[String: Any]] = []) -> String {
        var frame: [String: Any] = [
            "type": "call.joined", "call_id": testCallId, "you": ["role": role as Any? ?? NSNull(), "owner_epoch": epoch],
            "resumed": false, "events": events,
        ]
        if let id { frame["id"] = id }
        return text(frame)
    }

    static func transcript(row: String, speaker: String, text value: String, final: Bool = true, seq: Int? = 1) -> [String: Any] {
        var frame: [String: Any] = ["type": "call.transcript", "call_id": testCallId, "row_id": row, "speaker": speaker, "text": value, "final": final]
        if let seq { frame["seq"] = seq }
        return frame
    }

    static func error(_ code: String, id: String? = nil, callId: String? = nil, epoch: Int? = nil) -> String {
        var frame: [String: Any] = ["type": "error", "code": code, "message": "x"]
        if let id { frame["id"] = id }
        if let callId { frame["call_id"] = callId }
        if let epoch { frame["owner_epoch"] = epoch }
        return text(frame)
    }

    static func ended(_ reason: String) -> String { text(["type": "call.ended", "call_id": testCallId, "reason": reason]) }
    static func ttsStart(reply: Int, rate: Int = 24000) -> String {
        text(["type": "tts.start", "call_id": testCallId, "reply_id": reply, "sample_rate": rate, "text": "hi"])
    }
    static func ttsEnd(reply: Int) -> String { text(["type": "tts.end", "call_id": testCallId, "reply_id": reply]) }
    static func ttsStop() -> String { text(["type": "tts.stop", "call_id": testCallId]) }
    static func taken(epoch: Int, changed: Bool = true) -> String {
        text(["type": "call.taken", "call_id": testCallId, "owner_epoch": epoch, "changed": changed])
    }
}

/// A connector that hands out the scripted outcomes in order (a socket, or a failure with an HTTP-like code).
final class ScriptedConnector: WebSocketConnector {
    enum Outcome { case socket(FakeWebSocket), failure(WebSocketClosed) }
    private let state = Locked<(outcomes: [Outcome], urls: [URL], headers: [[String: String]])>(([], [], []))

    init(_ outcomes: [Outcome]) { state.withLock { $0.outcomes = outcomes } }

    var urls: [URL] { state.withLock { $0.urls } }
    var headers: [[String: String]] { state.withLock { $0.headers } }
    var attempts: Int { state.withLock { $0.urls.count } }

    func connect(to url: URL, headers: [String: String]) async throws -> any WebSocketConnection {
        let next = state.withLock { s -> Outcome? in
            s.urls.append(url)
            s.headers.append(headers)
            return s.outcomes.isEmpty ? nil : s.outcomes.removeFirst()
        }
        switch next {
        case .socket(let socket)?: return socket
        case .failure(let closed)?: throw closed
        case nil: throw WebSocketClosed(code: nil, reason: "no more scripted outcomes")
        }
    }
}

/// A call link the controller drives: records what was sent, plays what the test pushes.
final class FakeCallLink: CallLink, @unchecked Sendable {
    let events: AsyncStream<CallLinkEvent>
    private let continuation: AsyncStream<CallLinkEvent>.Continuation
    private let log = Locked<(messages: [CallOutbound], audio: [(UInt32, Data)], opened: Int, closed: Int, order: [String])>(([], [], 0, 0, []))

    init() { (events, continuation) = AsyncStream.makeStream(of: CallLinkEvent.self, bufferingPolicy: .unbounded) }

    var messages: [CallOutbound] { log.withLock { $0.messages } }
    var audio: [(epoch: UInt32, pcm: Data)] { log.withLock { $0.audio.map { (epoch: $0.0, pcm: $0.1) } } }
    var opened: Int { log.withLock { $0.opened } }
    var closed: Int { log.withLock { $0.closed } }
    /// Everything sent, in the order it left: "audio" for a frame, the wire type for a verb.
    var order: [String] { log.withLock { $0.order } }

    func open() async { log.withLock { $0.opened += 1 } }
    func send(_ message: CallOutbound) async {
        log.withLock {
            $0.messages.append(message)
            $0.order.append(Self.type(of: message))
        }
    }
    func sendAudio(epoch: UInt32, pcm: Data) async -> Bool {
        log.withLock {
            $0.audio.append((epoch, pcm))
            $0.order.append("audio")
        }
        return true
    }

    private static func type(of message: CallOutbound) -> String {
        let data = Data(message.json.utf8)
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["type"] as? String ?? "?"
    }
    func close() async { log.withLock { $0.closed += 1 } }

    func push(_ event: CallLinkEvent) { continuation.yield(event) }
    func pushInbound(_ text: String) { if let inbound = CallInbound.parse(text) { continuation.yield(.inbound(inbound)) } }
    func pushHello(_ text: String) { if case .helloOk(let hello)? = CallInbound.parse(text) { continuation.yield(.up(hello)) } }
}

enum FakeAudioFailure: Error { case notSettled }

@MainActor
final class FakeCallAudio: CallAudioIO {
    var onDrained: (@MainActor () -> Void)?
    private(set) var starts = 0
    private(set) var stops = 0
    private(set) var played: [PlaybackChunk] = []
    private(set) var playbackStops = 0
    /// Every playback level the call asked for, in order.
    private(set) var levels: [Float] = []
    func setPlaybackLevel(_ level: Float) { levels.append(level) }
    private(set) var routeChanges = 0
    /// Every output the call asked of the session, in order (nil = left to the system).
    private(set) var outputs: [CallOutputChoice?] = []
    var external = false
    var hasExternalOutput: Bool { external }
    /// What the session reports: the last thing asked, unless a device is connected.
    var currentOutput: CallOutputKind { external ? .external : (outputs.last.flatMap { $0 } == .receiver ? .receiver : .speaker) }
    func setOutput(_ choice: CallOutputChoice?) { outputs.append(choice) }
    var startError: (any Error)?
    var playing = false
    var onFailure: (@MainActor (String) -> Void)?
    var onPlaybackLevel: (@Sendable (Double) -> Void)?
    /// Each start in order: whether echo cancellation was asked for, and what the audio session had done by then.
    private(set) var startModes: [Bool] = []
    var beforeStart: (() -> Void)?
    var report: [String] = []
    var captureReport: [String] { report }
    private var handler: (@Sendable ([Int16]) -> Void)?

    var isPlaying: Bool { playing }

    func start(onSamples: @escaping @Sendable ([Int16]) -> Void, echoCancellation: Bool) throws {
        beforeStart?()
        if let startError { throw startError }
        startModes.append(echoCancellation)
        starts += 1
        handler = onSamples
    }

    func stop() { stops += 1 }
    func play(_ chunk: PlaybackChunk) {
        played.append(chunk)
        playing = true
    }
    func stopPlayback() {
        playbackStops += 1
        playing = false
    }
    /// How many of the next route rebuilds fail (the system has not settled on the next route yet).
    var routeChangeFailures = 0
    func routeChanged() throws {
        routeChanges += 1
        if routeChangeFailures > 0 {
            routeChangeFailures -= 1
            throw FakeAudioFailure.notSettled
        }
    }

    /// The microphone delivers samples.
    func hear(_ samples: [Int16]) { handler?(samples) }
    func drain() {
        playing = false
        onDrained?()
    }
}

@MainActor
final class FakeMicrophone: CallMicrophone {
    var status = MicrophoneAccess.granted
    var grantsOnRequest = true
    private(set) var requests = 0

    func access() -> MicrophoneAccess { status }
    func request() async -> Bool {
        requests += 1
        status = grantsOnRequest ? .granted : .denied
        return grantsOnRequest
    }
}

@MainActor
final class RecordingActivity: CallActivityPresenting {
    private(set) var changes: [CallActivitySnapshot] = []
    private(set) var endings: [CallActivitySnapshot] = []
    func callChanged(_ snapshot: CallActivitySnapshot) { changes.append(snapshot) }
    func callEnded(_ snapshot: CallActivitySnapshot) { endings.append(snapshot) }
}

/// A sine wave as PCM16 at 16 kHz: speech stand-in for the detector tests.
func sine(ms: Int, amplitude: Double, frequency: Double = 440) -> [Int16] {
    (0..<(ms * 16)).map { Int16(amplitude * sin(2 * .pi * frequency * Double($0) / 16_000)) }
}

func silence(ms: Int) -> [Int16] { [Int16](repeating: 0, count: ms * 16) }


@MainActor
final class FakeProximity: CallProximitySensing {
    var onChange: (@MainActor (Bool) -> Void)?
    private(set) var running = false
    private(set) var starts = 0
    func start() {
        if !running { starts += 1 }
        running = true
    }
    func stop() { running = false }
    /// The phone is brought to the ear (true) or taken away (false).
    func move(near: Bool) { onChange?(near) }
}
