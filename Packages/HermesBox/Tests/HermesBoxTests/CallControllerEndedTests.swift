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

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_000_000)
    func advance(_ seconds: TimeInterval) { lock.withLock { date = date.addingTimeInterval(seconds) } }
    func now() -> Date { lock.withLock { date } }
}

@MainActor
@Suite("Call controller: the end-of-call summary (fakes)")
struct CallControllerEndedTests {
    private func started(clock: Clock) async -> (CallController, FakeCallLink) {
        let link = FakeCallLink()
        let controller = CallController(
            makeLink: { _ in link }, audio: FakeCallAudio(), audioSession: VoiceAudioSession(driver: FakeAudioDriver()),
            microphone: FakeMicrophone(), preferences: InMemoryCallPreferences(), activity: RecordingActivity(),
            waitingCount: { _ in 0 }, time: ManualTimeSource(), now: { clock.now() }, endGrace: .seconds(3))
        await controller.start(bot: CallBot(botKey: testBotKey, name: "Hermes", gatewayId: "oracle"))
        link.pushHello(Hub.helloOk())
        _ = await until { link.messages.contains(.start(id: "c1", botKey: testBotKey, engine: .free)) }
        link.pushInbound(Hub.started(id: "c1"))
        _ = await until { controller.session?.role == .owner }
        return (controller, link)
    }

    private func sendCallContent(_ link: FakeCallLink) {
        link.pushInbound(Hub.text(Hub.transcript(row: "r1", speaker: "person", text: "Show me the report", seq: 1)))
        link.pushInbound(Hub.text(Hub.transcript(row: "r2", speaker: "voice", text: "Here it is", seq: 2)))
        link.pushInbound(
            Hub.text([
                "type": "call.display", "call_id": testCallId, "at": 1,
                "item": ["id": "00000000-0000-4000-8000-000000000001", "kind": "markdown", "title": "Report", "body": "text"],
            ]))
    }

    @Test func aBotEndedCallReachesTheSummaryAndKeepsTheTranscriptAndItems() async {
        let clock = Clock()
        let (controller, link) = await started(clock: clock)
        sendCallContent(link)
        #expect(await until { controller.displayItems.count == 1 && controller.session?.captions.botLine == "Here it is" })
        clock.advance(240)
        controller.closeScreen()
        link.pushInbound(Hub.ended("ended_by_bot"))
        #expect(await until { !controller.isInCall })
        let summary = controller.endedSummary
        #expect(summary?.kind == .botEnded)
        #expect(summary?.title == "Hermes ended the call")
        #expect(summary?.durationText == "4 minutes")
        #expect(summary?.displayTitles == ["Report"])
        #expect(controller.session?.captions.botLine == "Here it is", "the transcript stays readable")
        #expect(controller.session?.captions.userLine == "Show me the report")
        #expect(controller.isScreenShown, "a hidden call screen comes back when the bot hangs up")
    }

    @Test func anOwnerEndedCallGetsTheSameSummary() async {
        let clock = Clock()
        let (controller, link) = await started(clock: clock)
        clock.advance(60)
        link.pushInbound(Hub.ended("ended_by_client"))
        #expect(await until { !controller.isInCall })
        #expect(controller.endedSummary?.title == "You ended the call")
        #expect(controller.endedSummary?.durationText == "1 minute")
    }

    @Test func anUnknownReasonStillEndsCalmly() async {
        let (controller, link) = await started(clock: Clock())
        link.pushInbound(Hub.ended("a_reason_from_the_future"))
        #expect(await until { !controller.isInCall })
        #expect(controller.endedSummary?.title == "The call ended")
    }

    @Test func doneForgetsTheSummary() async {
        let (controller, link) = await started(clock: Clock())
        link.pushInbound(Hub.ended("ended_by_bot"))
        #expect(await until { !controller.isInCall })
        controller.clear()
        #expect(controller.endedSummary == nil)
    }
}
