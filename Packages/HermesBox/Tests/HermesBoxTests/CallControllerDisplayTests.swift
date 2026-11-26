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

private func displayFrame(_ n: Int) -> String {
    let id = "00000000-0000-4000-8000-\(String(format: "%012d", n))"
    return Hub.text([
        "type": "call.display", "call_id": testCallId, "at": 1,
        "item": ["id": id, "kind": "markdown", "title": "Item \(n)", "body": "text \(n)"],
    ])
}

@MainActor
@Suite("Call controller: what the bot shows on the call screen (fakes)")
struct CallControllerDisplayTests {
    private func startedController() async -> (CallController, FakeCallLink) {
        let link = FakeCallLink()
        let audioSession = VoiceAudioSession(driver: FakeAudioDriver())
        let controller = CallController(
            makeLink: { _ in link }, audio: FakeCallAudio(), audioSession: audioSession, microphone: FakeMicrophone(),
            preferences: InMemoryCallPreferences(), activity: RecordingActivity(), waitingCount: { _ in 0 },
            time: ManualTimeSource(), endGrace: .seconds(3))
        await controller.start(bot: CallBot(botKey: testBotKey, name: "Hermes", gatewayId: "oracle"))
        link.pushHello(Hub.helloOk())
        _ = await until { link.messages.contains(.start(id: "c1", botKey: testBotKey, engine: .free)) }
        link.pushInbound(Hub.started(id: "c1"))
        _ = await until { controller.session?.role == .owner }
        return (controller, link)
    }

    @Test func itemsShowNewestFirstAndClearIsLocalOnly() async {
        let (controller, link) = await startedController()
        link.pushInbound(displayFrame(1))
        link.pushInbound(displayFrame(2))
        #expect(await until { controller.displayItems.count == 2 })
        #expect(controller.displayItems.map(\.title) == ["Item 2", "Item 1"])
        let sentBefore = link.messages.count
        controller.clearDisplay()
        #expect(controller.displayItems.isEmpty)
        #expect(link.messages.count == sentBefore, "nothing is sent to the hub")
        #expect(controller.isInCall)
    }

    @Test func theCallEndingEmptiesTheScreen() async {
        let (controller, link) = await startedController()
        link.pushInbound(displayFrame(1))
        #expect(await until { controller.displayItems.count == 1 })
        link.pushInbound(Hub.text(["type": "call.ended", "call_id": testCallId, "reason": "ended_by_client"]))
        #expect(await until { !controller.isInCall })
        #expect(controller.displayItems.isEmpty)
    }
}
