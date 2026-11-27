import Foundation
import Testing

@testable import HermesBox

@Suite("Call wire: frames, golden bytes from the hub's own fixtures, parsing")
struct CallWireTests {
    // box/call-hub/tests/protocol.test.mjs: encodeUp(0x01020304, [1,0,2,0,3,0]) and encodeDown(9, same pcm).
    private let pcm = Data([1, 0, 2, 0, 3, 0])

    @Test func uplinkFrameIsTagEpochBigEndianThenPcm() {
        let frame = CallAudioFrame.encodeUp(epoch: 0x0102_0304, pcm: pcm)
        #expect([UInt8](frame) == [0x01, 0x01, 0x02, 0x03, 0x04, 1, 0, 2, 0, 3, 0])
        let decoded = CallAudioFrame.decodeUp(frame)
        #expect(decoded?.epoch == 0x0102_0304 && decoded?.pcm == pcm)
    }

    @Test func downlinkFrameIsTagReplyIdBigEndianThenPcm() {
        let frame = CallAudioFrame.encodeDown(replyId: 9, pcm: pcm)
        #expect([UInt8](frame) == [0x02, 0, 0, 0, 9, 1, 0, 2, 0, 3, 0])
        let decoded = CallAudioFrame.decodeDown(frame)
        #expect(decoded?.replyId == 9 && decoded?.pcm == pcm)
    }

    @Test func malformedFramesAreRefusedLikeTheHubDoes() {
        #expect(CallAudioFrame.decodeUp(Data([0x01, 0, 0, 0])) == nil, "too short")
        #expect(CallAudioFrame.decodeUp(Data([0x02, 0, 0, 0, 1, 0, 0])) == nil, "wrong tag")
        #expect(CallAudioFrame.decodeUp(Data([0x01, 0, 0, 0, 1, 9])) == nil, "odd PCM length")
        #expect(CallAudioFrame.decodeDown(Data([0x01, 0, 0, 0, 9, 1, 0])) == nil, "wrong tag")
        #expect(CallAudioFrame.decodeDown(Data([0x02, 0, 0, 0, 9, 1])) == nil, "odd PCM length")
    }

    @Test func epochUsesAllFourBytes() {
        let frame = CallAudioFrame.encodeUp(epoch: UInt32.max, pcm: Data([0, 0]))
        #expect(CallAudioFrame.decodeUp(frame)?.epoch == UInt32.max)
    }

    @Test func outboundVerbsAreExactJSON() {
        #expect(CallOutbound.hello.json == #"{"proto":1,"type":"hello"}"#)
        #expect(
            CallOutbound.start(id: "s1", botKey: "oracle::hermesbot", engine: .free).json
                == #"{"bot_key":"oracle::hermesbot","engine":"free","id":"s1","type":"call.start"}"#)
        #expect(CallOutbound.join(id: "j", callId: testCallId, since: 7).json == #"{"call_id":"\#(testCallId)","id":"j","since":7,"type":"call.join"}"#)
        #expect(CallOutbound.join(id: "j", callId: testCallId, since: nil).json == #"{"call_id":"\#(testCallId)","id":"j","type":"call.join"}"#)
        #expect(CallOutbound.take(id: "t", callId: testCallId).json == #"{"call_id":"\#(testCallId)","id":"t","type":"call.take"}"#)
        #expect(CallOutbound.eos(callId: testCallId, epoch: 2).json == #"{"call_id":"\#(testCallId)","epoch":2,"type":"audio.eos"}"#)
        #expect(CallOutbound.bargeIn(callId: testCallId, epoch: 2).json == #"{"call_id":"\#(testCallId)","epoch":2,"type":"audio.barge_in"}"#)
        #expect(CallOutbound.ping.json == #"{"type":"ping"}"#)
    }

    @Test func helloOkCarriesCallsAndMemberships() {
        let text = Hub.helloOk(
            calls: [Hub.summary(owner: "desk", participants: [Hub.participant("desk", kind: "desktop", label: "Mac", role: "owner")])],
            yours: [["call_id": testCallId, "role": "owner", "owner_epoch": 4]])
        guard case .helloOk(let hello)? = CallInbound.parse(text) else { Issue.record("not hello.ok"); return }
        #expect(hello.clientId == "phone")
        #expect(hello.calls.first?.botKey == testBotKey)
        #expect(hello.calls.first?.ownerName == "Mac")
        #expect(hello.yours == [CallMembership(callId: testCallId, role: .owner, ownerEpoch: 4)])
    }

    @Test func ownerNameFallsBackToTheKind() {
        let call = Hub.summary(owner: "d", participants: [Hub.participant("d", kind: "desktop", label: "", role: "owner")])
        guard case .state(let summary, _)? = CallInbound.parse(Hub.state(role: nil, epoch: 1, call: call)) else { Issue.record("not state"); return }
        #expect(summary.ownerName == "the desktop")
    }

    @Test func transcriptPartialsAndFinalsParse() {
        let partial = Hub.text(Hub.transcript(row: "partial", speaker: "person", text: "sel", final: false, seq: nil))
        guard case .transcript(let row)? = CallInbound.parse(partial) else { Issue.record("not transcript"); return }
        #expect(row.isPartial && !row.final && row.seq == nil)
    }

    @Test func errorsUseTheClosedSetAndUnknownBecomesInternal() {
        guard case .error(let code, let id, let callId, let epoch)? = CallInbound.parse(Hub.error("stale_epoch", id: "x", callId: testCallId, epoch: 5)) else {
            Issue.record("not error"); return
        }
        #expect(code == .staleEpoch && id == "x" && callId == testCallId && epoch == 5)
        guard case .error(let other, _, _, _)? = CallInbound.parse(Hub.error("brand_new_code")) else { Issue.record("not error"); return }
        #expect(other == .internal)
    }

    @Test func everyHubErrorHasACalmSentenceWithoutEmDashes() {
        for code in HubErrorCode.allCases {
            #expect(!code.sentence.isEmpty && !code.sentence.contains("\u{2014}"))
        }
    }

    @Test func junkIsNotAFrame() {
        #expect(CallInbound.parse("not json") == nil)
        #expect(CallInbound.parse(#"{"no":"type"}"#) == nil)
        #expect(CallInbound.parse(#"{"type":"call.delegation","call_id":"x"}"#) == .other(type: "call.delegation"))
    }
}
