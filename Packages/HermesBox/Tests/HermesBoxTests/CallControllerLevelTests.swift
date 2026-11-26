import Foundation
import Testing

@testable import HermesBox

@MainActor
private func until(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<300 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return false
}

@MainActor
@Suite("Call controller: real mic and playback levels (fakes)")
struct CallControllerLevelTests {
    private func startedController() async -> (CallController, FakeCallAudio) {
        let link = FakeCallLink()
        let audio = FakeCallAudio()
        let controller = CallController(
            makeLink: { _ in link }, audio: audio, audioSession: VoiceAudioSession(driver: FakeAudioDriver()), microphone: FakeMicrophone(),
            preferences: InMemoryCallPreferences(), activity: RecordingActivity(), waitingCount: { _ in 0 },
            time: ManualTimeSource(), endGrace: .seconds(3))
        await controller.start(bot: CallBot(botKey: testBotKey, name: "Hermes", gatewayId: "oracle"))
        link.pushHello(Hub.helloOk())
        _ = await until { link.messages.contains(.start(id: "c1", botKey: testBotKey, engine: .free)) }
        link.pushInbound(Hub.started(id: "c1"))
        _ = await until { controller.session?.role == .owner }
        return (controller, audio)
    }

    private let loud = [Int16](repeating: 0, count: 160).enumerated().map { $0.offset % 2 == 0 ? Int16(9000) : Int16(-9000) }

    @Test func theMicLevelFollowsTheMicrophoneAndFallsToZeroWhenMuted() async {
        let (controller, audio) = await startedController()
        #expect(controller.micLevel == 0)
        for _ in 0..<20 {
            audio.hear(loud)
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(await until { controller.micLevel > 0.4 })
        controller.setMuted(true)
        #expect(await until { controller.micLevel == 0 })
    }

    @Test func thePlaybackLevelFollowsWhatTheSpeakerRendersAndLeavesATrail() async {
        let (controller, _) = await startedController()
        for _ in 0..<15 {
            controller.notePlayback(db: -20)
            try? await Task.sleep(for: .milliseconds(15))
        }
        #expect(await until { controller.playbackLevel > 0.5 })
        #expect(!controller.playbackTrail.isSilent)
        #expect(await until { controller.playbackLevel == 0 }, "no buffers means silence, not the last value")
    }
}
