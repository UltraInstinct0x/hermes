import Foundation
import Testing

@testable import HermesBox

private func makeClient(_ connector: ScriptedConnector, time: ManualTimeSource, policy: CallReconnectPolicy = CallReconnectPolicy()) -> CallClient {
    CallClient(
        url: { URL(string: "wss://box.example/gw/oracle/api/call/ws")! }, headers: { ["Authorization": "Bearer test-token"] },
        connector: connector, time: time, policy: policy)
}

private func waitForEvent(_ collector: Collector<CallLinkEvent>, _ message: String, _ match: @escaping @Sendable (CallLinkEvent) -> Bool) async -> Bool {
    await eventually(message) { collector.values.contains(where: match) }
}

@Suite("Call client: the hub socket, heartbeat and reconnection (fake socket, fake clock)")
struct CallClientTests {
    @Test func connectsWithTheDeviceBearerAndReportsHello() async {
        let socket = FakeWebSocket()
        let connector = ScriptedConnector([.socket(socket)])
        let client = makeClient(connector, time: ManualTimeSource())
        let events = Collector(client.events)
        await client.open()
        socket.push(Hub.helloOk(client: "phone-1"))
        #expect(await waitForEvent(events, "up") { if case .up(let hello) = $0 { hello.clientId == "phone-1" } else { false } })
        #expect(connector.headers.first?["Authorization"] == "Bearer test-token")
        #expect(connector.urls.first?.path == "/gw/oracle/api/call/ws")
        await client.close()
    }

    @Test func textFramesAndBinaryAudioReachTheOwner() async {
        let socket = FakeWebSocket()
        let client = makeClient(ScriptedConnector([.socket(socket)]), time: ManualTimeSource())
        let events = Collector(client.events)
        await client.open()
        socket.push(Hub.helloOk())
        socket.push(Hub.ttsStart(reply: 4))
        socket.pushBinary(CallAudioFrame.encodeDown(replyId: 4, pcm: Data([1, 0, 2, 0])))
        socket.pushBinary(Data([0x09, 1, 2]))  // junk is dropped
        #expect(await waitForEvent(events, "audio") { $0 == .audio(replyId: 4, pcm: Data([1, 0, 2, 0])) })
        #expect(events.values.contains(.inbound(.ttsStart(callId: testCallId, replyId: 4, sampleRate: 24000, text: "hi"))))
        #expect(events.values.filter { if case .audio = $0 { true } else { false } }.count == 1)
        await client.close()
    }

    @Test func sendsVerbsAsTextAndAudioAsBinaryWithTheEpoch() async {
        let socket = FakeWebSocket()
        let client = makeClient(ScriptedConnector([.socket(socket)]), time: ManualTimeSource())
        let events = Collector(client.events)
        await client.open()
        socket.push(Hub.helloOk())
        _ = await waitForEvent(events, "up") { if case .up = $0 { true } else { false } }
        await client.send(.eos(callId: testCallId, epoch: 7))
        let delivered = await client.sendAudio(epoch: 7, pcm: Data([5, 0]))
        #expect(delivered)
        #expect(socket.sent == [CallOutbound.eos(callId: testCallId, epoch: 7).json])
        #expect(socket.sentBinary == [Data([0x01, 0, 0, 0, 7, 5, 0])])
        await client.close()
    }

    @Test func audioBeforeTheSocketIsUpIsReportedAsNotDelivered() async {
        let client = makeClient(ScriptedConnector([]), time: ManualTimeSource())
        let delivered = await client.sendAudio(epoch: 1, pcm: Data([1, 0]))
        #expect(!delivered)
    }

    @Test func pingsEveryTwentySecondsAndStaysUpWhileTheHubAnswers() async {
        let socket = FakeWebSocket()
        let time = ManualTimeSource()
        let client = makeClient(ScriptedConnector([.socket(socket)]), time: time)
        let events = Collector(client.events)
        await client.open()
        socket.push(Hub.helloOk())
        _ = await waitForEvent(events, "up") { if case .up = $0 { true } else { false } }
        await time.advance(by: .seconds(20))
        #expect(socket.sent.filter { $0 == CallOutbound.ping.json }.count == 1)
        socket.push(#"{"type":"pong"}"#)
        await time.advance(by: .seconds(20))
        #expect(socket.sent.filter { $0 == CallOutbound.ping.json }.count == 2)
        #expect(!events.values.contains(.down))
        await client.close()
    }

    @Test func aSilentLinkIsDeadAfterFortyFiveSecondsAndTheClientRedials() async {
        let first = FakeWebSocket()
        let second = FakeWebSocket()
        let connector = ScriptedConnector([.socket(first), .socket(second)])
        let time = ManualTimeSource()
        let client = makeClient(connector, time: time)
        let events = Collector(client.events)
        await client.open()
        first.push(Hub.helloOk())
        _ = await waitForEvent(events, "up") { if case .up = $0 { true } else { false } }
        // pings at 20 and 40 s go unanswered; the check at 60 s finds 60 s of silence (more than 45) and drops the link.
        await time.advance(by: .seconds(60))
        #expect(await waitForEvent(events, "down") { $0 == .down })
        #expect(first.closeCode == webSocketAbruptCloseCode)
        await time.advance(by: .seconds(1))
        second.push(Hub.helloOk())
        #expect(await eventually("second up") { events.values.filter { if case .up = $0 { true } else { false } }.count == 2 })
        await client.close()
    }

    @Test func aDroppedLinkIsRedialledAndTheOwnerIsToldDownThenUp() async {
        let first = FakeWebSocket()
        let second = FakeWebSocket()
        let connector = ScriptedConnector([.socket(first), .socket(second)])
        let client = makeClient(connector, time: ManualTimeSource())
        let events = Collector(client.events)
        await client.open()
        first.push(Hub.helloOk())
        _ = await waitForEvent(events, "up") { if case .up = $0 { true } else { false } }
        first.drop(code: 1006)
        #expect(await waitForEvent(events, "down") { $0 == .down })
        second.push(Hub.helloOk())
        #expect(await eventually("second up") { events.values.filter { if case .up = $0 { true } else { false } }.count == 2 })
        #expect(connector.attempts == 2)
        await client.close()
    }

    @Test func a404MeansCallsAreNotEnabledAndNothingIsRetried() async {
        let connector = ScriptedConnector([.failure(WebSocketClosed(code: 404, reason: "HTTP 404"))])
        let client = makeClient(connector, time: ManualTimeSource())
        let events = Collector(client.events)
        await client.open()
        #expect(await waitForEvent(events, "disabled") { $0 == .failed(.disabled) })
        #expect(connector.attempts == 1)
    }

    @Test func refusedCredentialsAreFatalToo() async {
        for code in [401, 403] {
            let client = makeClient(ScriptedConnector([.failure(WebSocketClosed(code: code))]), time: ManualTimeSource())
            let events = Collector(client.events)
            await client.open()
            #expect(await waitForEvent(events, "unauthorized") { $0 == .failed(.unauthorized) })
        }
    }

    @Test func aReplacedConnectionIsNotRedialled() async {
        let socket = FakeWebSocket()
        let connector = ScriptedConnector([.socket(socket)])
        let client = makeClient(connector, time: ManualTimeSource())
        let events = Collector(client.events)
        await client.open()
        socket.push(Hub.helloOk())
        _ = await waitForEvent(events, "up") { if case .up = $0 { true } else { false } }
        socket.drop(code: 4009)
        #expect(await waitForEvent(events, "replaced") { $0 == .failed(.replaced) })
        #expect(connector.attempts == 1)
    }

    @Test func aFirstConnectionThatNeverComesUpFailsFastInsteadOfSpinning() async {
        let connector = ScriptedConnector([.failure(WebSocketClosed(code: nil, reason: "offline"))])
        let client = makeClient(connector, time: ManualTimeSource())
        let events = Collector(client.events)
        await client.open()
        #expect(await waitForEvent(events, "unreachable") { if case .failed(.unreachable) = $0 { true } else { false } })
        #expect(connector.attempts == 1)
    }

    @Test func aLinkThatStaysDownLongerThanACanWaitGivesUp() async {
        let first = FakeWebSocket()
        var policy = CallReconnectPolicy()
        policy.giveUpAfter = .seconds(20)
        let connector = ScriptedConnector([.socket(first)])  // every redial after the first fails
        let time = ManualTimeSource()
        let client = makeClient(connector, time: time, policy: policy)
        let events = Collector(client.events)
        await client.open()
        first.push(Hub.helloOk())
        _ = await waitForEvent(events, "up") { if case .up = $0 { true } else { false } }
        first.drop(code: 1006)
        _ = await waitForEvent(events, "down") { $0 == .down }
        for _ in 0..<10 { await time.advance(by: .seconds(5)) }
        #expect(await waitForEvent(events, "gave up") { if case .failed(.gaveUp) = $0 { true } else { false } })
    }

    @Test func theReconnectPolicyIsQuickFirstThenSteady() {
        let policy = CallReconnectPolicy()
        #expect(policy.delay(afterFailures: 0) == .zero)
        #expect(policy.delay(afterFailures: 1) < policy.delay(afterFailures: 3))
        #expect(policy.delay(afterFailures: 50) == .seconds(5))
        #expect(!policy.shouldGiveUp(downFor: .seconds(300)) && policy.shouldGiveUp(downFor: .seconds(330)))
        #expect(CallReconnectPolicy.classify(WebSocketClosed(code: 429)) == .retryLater)
        #expect(CallReconnectPolicy.classify(WebSocketClosed(code: 1013)) == .retry)
    }

    @Test func callRouteURLIsTheGatewayShape() {
        let bff = BFFClient(baseURL: URL(string: "https://box.tailnet.ts.net")!, transport: URLSessionHTTPTransport())
        #expect(bff.callWebSocketURL(gatewayId: "oracle")?.absoluteString == "wss://box.tailnet.ts.net/gw/oracle/api/call/ws")
    }
}
