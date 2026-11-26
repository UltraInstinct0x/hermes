#if os(iOS) && DEBUG
import Foundation
import HermesBox
import HermesKit

// `-NEO_CALL_DEMO transcript|screen|ended|bar`: a real `CallController` on a scripted hub (no box, no audio), so the
// call screen can be compared with Hermes Bot's on the same content. The same script runs in a copy of Hermes Bot for
// the comparison screenshots. Debug only.

nonisolated private let demoCallId = "123e4567-e89b-12d3-a456-426614174000"
nonisolated private let demoBotKey = "oracle::hermesbot"

nonisolated private func frame(_ object: [String: Any]) -> String {
    String(decoding: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
}

nonisolated private func summary() -> [String: Any] {
    [
        "call_id": demoCallId, "bot_key": demoBotKey, "engine": "free", "state": "active", "owner_epoch": 1,
        "participants": [["client_id": "phone", "kind": "ios", "label": "", "role": "owner", "connected": true, "audio_out": true, "joined_at": 1]],
        "started_at": 1000, "last_activity_at": 1000, "ended_at": NSNull(), "voice_session_id": "v1", "bot_session_id": "b1", "seq": 0,
        "owner_client_id": "phone", "ended_reason": NSNull(),
    ]
}

/// The hub's side of the demo.
nonisolated final class NeoDemoLink: CallLink, @unchecked Sendable {
    let events: AsyncStream<CallLinkEvent>
    private let continuation: AsyncStream<CallLinkEvent>.Continuation

    init() { (events, continuation) = AsyncStream.makeStream(of: CallLinkEvent.self, bufferingPolicy: .unbounded) }

    func open() async {}
    func send(_ message: CallOutbound) async {
        // The call asked to start: the hub starts it.
        if case .start(let id, _, _) = message {
            push(frame(["type": "call.started", "id": id, "call_id": demoCallId, "owner_epoch": 1, "call": summary()]))
        }
    }
    func sendAudio(epoch: UInt32, pcm: Data) async -> Bool { true }
    func close() async {}

    func push(_ text: String) {
        guard let inbound = CallInbound.parse(text) else { return }
        if case .helloOk(let hello) = inbound { continuation.yield(.up(hello)) } else { continuation.yield(.inbound(inbound)) }
    }

    func hello() {
        push(frame(["type": "hello.ok", "proto": 1, "client_id": "phone", "server_time": 1, "limits": ["max_participants": 8], "calls": [], "yours": []]))
    }

    func line(_ n: Int, person: Bool, _ text: String, final: Bool = true) {
        push(frame([
            "type": "call.transcript", "call_id": demoCallId, "row_id": final ? "r\(n)" : "partial", "speaker": person ? "person" : "voice",
            "text": text, "final": final, "seq": n,
        ]))
    }

    func card(_ n: Int, _ title: String, _ body: String) {
        let id = "00000000-0000-4000-8000-\(String(format: "%012d", n))"
        push(frame(["type": "call.display", "call_id": demoCallId, "at": n, "item": ["id": id, "kind": "markdown", "title": title, "body": body]]))
    }

    func speak() {
        push(frame(["type": "tts.start", "call_id": demoCallId, "reply_id": 1, "sample_rate": 24000, "text": "hi"]))
        continuation.yield(.audio(replyId: 1, pcm: Data(repeating: 0, count: 4800)))
    }

    func end() { push(frame(["type": "call.ended", "call_id": demoCallId, "reason": "ended_by_client"])) }
}

@MainActor
final class NeoDemoAudio: CallAudioIO {
    var onDrained: (@MainActor () -> Void)?
    var onFailure: (@MainActor (String) -> Void)?
    var onPlaybackLevel: (@Sendable (Double) -> Void)?
    private(set) var isPlaying = false
    private var feed: Task<Void, Never>?
    /// A quiet room: silence every 50 ms, so the call hears a microphone (its watchdog fails a silent one).
    func start(onSamples: @escaping @Sendable ([Int16]) -> Void, echoCancellation: Bool) throws {
        feed?.cancel()
        feed = Task {
            while !Task.isCancelled {
                onSamples([Int16](repeating: 0, count: 800))
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }
    func stop() { feed?.cancel() }
    func play(_ chunk: PlaybackChunk) { isPlaying = true }
    func stopPlayback() { isPlaying = false }
    func routeChanged() throws {}
}

@MainActor
final class NeoDemoMicrophone: CallMicrophone {
    func access() -> MicrophoneAccess { .granted }
    func request() async -> Bool { true }
}

@MainActor
final class NeoDemoDriver: AudioSessionDriver {
    func activate(_ purpose: AudioPurpose) throws {}
    func deactivate() throws {}
    func events() -> AsyncStream<AudioSessionEvent> { AsyncStream { _ in } }
}

/// The scripted call: 8 turns and the person still talking, 3 cards; `screen` adds a 4th card once the screen is
/// up (the pager follows it to the screen page), `ended` ends the call.
@MainActor
enum NeoCallDemo {
    static var mode: String? { UserDefaults.standard.string(forKey: "NEO_CALL_DEMO") }

    /// `waiting`: what the bot waits on during the call, as upstream's TalkStage fakes it.
    static let approval = ApprovalRequest(
        requestID: "r1", command: "rm -rf ./build && make release", description: "Recursive delete", choices: [.once, .session, .always, .deny])

    static func make() async -> CallController {
        let link = NeoDemoLink()
        let calls = CallController(
            makeLink: { _ in link }, audio: NeoDemoAudio(), audioSession: VoiceAudioSession(driver: NeoDemoDriver()), microphone: NeoDemoMicrophone())
        await calls.start(bot: CallBot(botKey: demoBotKey, name: "Hermes Bot", gatewayId: "oracle"))
        link.hello()
        for _ in 0..<100 where calls.session?.role != .owner { try? await Task.sleep(for: .milliseconds(20)) }
        let turns: [(Bool, String)] = [
            (true, "Good morning. What's on today?"),
            (false, "Morning! You have two meetings: a stand-up at ten and the Salesforce review at two."),
            (true, "Move the review to four if Ayşe is free."),
            (false, "Ayşe is free at four. I moved the review and told the attendees."),
            (true, "And what's the weather like in Antalya?"),
            (false, "Sunny, 24 degrees, a light breeze from the sea. I put the forecast on your screen."),
            (true, "Is my flight still on time?"),
            (false, "SXS 123 is on time, boarding at 18:40 from gate 207. The details are on your screen too."),
        ]
        for (index, turn) in turns.enumerated() { link.line(index + 1, person: turn.0, turn.1) }
        link.line(9, person: true, "Great, and remind me to", final: false)
        link.card(1, "Your calendar this afternoon", "- 10:00 Stand-up\n- ~~14:00~~ **16:00** Salesforce review (moved)\n- 18:40 Boarding SXS 123")
        link.card(2, "Today's weather in Antalya", "Sunny, **24 °C**. Wind 12 km/h from the south-west. Sea 22 °C.")
        link.card(3, "Flight SXS 123", "**On time.** Boarding 18:40, gate 207.\nAntalya (AYT) → Frankfurt (FRA), 19:20 → 21:35.")
        link.speak()
        // Everything is on the call before the screen shows, so it opens on the transcript page.
        for _ in 0..<100 where calls.displayItems.count < 3 || (calls.session?.captions.rows.count ?? 0) < 8 {
            try? await Task.sleep(for: .milliseconds(20))
        }
        calls.isScreenShown = mode != "bar"
        if mode == "screen" {
            Task {
                try? await Task.sleep(for: .seconds(2))
                link.card(4, "Reminder", "Pack the charger before 18:00.")
            }
        }
        if mode == "ended" {
            Task {
                try? await Task.sleep(for: .seconds(1))
                link.end()
            }
        }
        return calls
    }
}
#endif
