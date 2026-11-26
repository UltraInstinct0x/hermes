import Foundation
import Testing

@testable import HermesBox

@Suite("Hermes Neo call screen: transcript lines and the avatar's look")
struct CallScreenModelTests {
    private func row(_ id: String, _ speaker: CallSpeaker, _ text: String) -> CallTranscriptRow {
        CallTranscriptRow(callId: "c", seq: nil, rowId: id, speaker: speaker, text: text, final: id != "partial")
    }

    @Test func linesAreOldestFirstWithTheLiveLineOfThePersonLast() {
        var captions = CallCaptions()
        captions.apply(row("r1", .person, "Hi"))
        captions.apply(row("r2", .voice, "Hello, how can I help?"))
        captions.apply(row("r3", .voice, ""))
        captions.apply(row("partial", .person, "What is the wea"))
        let lines = CallTranscriptLine.lines(captions, botName: "Hermes Bot")
        #expect(lines.map(\.id) == ["r1", "r2", "partial"], "empty rows are left out")
        #expect(lines.map(\.speaker) == ["You", "Hermes Bot", "You"])
        #expect(lines.map(\.isPerson) == [true, false, true])
        #expect(lines.last?.isLive == true && lines.first?.isLive == false)
    }

    @Test func aBotWithoutANameIsBot() {
        var captions = CallCaptions()
        captions.apply(row("r1", .voice, "Hello"))
        #expect(CallTranscriptLine.lines(captions, botName: "").first?.speaker == "Bot")
    }

    @Test func theAvatarPlaysTheCallsState() {
        #expect(CallAvatarLook(.listening) == .waiting)
        #expect(CallAvatarLook(.speaking) == .speaking)
        #expect(CallAvatarLook(.processing) == .working && CallAvatarLook(.connecting) == .working)
        #expect(CallAvatarLook(.paused) == .sleeping && CallAvatarLook(.standby) == .sleeping)
        #expect(CallAvatarLook(.muted) == .idle && CallAvatarLook(.neutral) == .idle)
        // Every look is one the avatar engine knows (HermesAvatar.BotStatus raw values).
        #expect(Set(CallAvatarLook.allCases.map(\.rawValue)) == ["idle", "working", "waiting", "error", "speaking", "sleeping"])
    }

    @Test func theRingFollowsTheMicrophoneWhileListeningAndTheSpeakerWhileTalking() {
        #expect(CallAvatarLook.meter(.listening) == .microphone)
        #expect(CallAvatarLook.meter(.speaking) == .speaker)
        for state in CallOrbState.allCases where state != .listening && state != .speaking {
            #expect(CallAvatarLook.meter(state) == .none, "\(state)")
        }
    }
}
