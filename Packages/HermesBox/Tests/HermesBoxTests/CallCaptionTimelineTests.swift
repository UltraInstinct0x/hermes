import Foundation
import Testing

@testable import HermesBox

/// The app's Talk caption rule (TalkSession.caption) on a call through the box.
@Suite("Hermes Neo: the call's caption follows what is heard, as Talk's does")
struct CallCaptionTimelineTests {
    private func row(_ id: String, _ text: String, person: Bool = true, final: Bool = true) -> CallTranscriptRow {
        CallTranscriptRow(callId: "c", seq: nil, rowId: final ? id : "partial", speaker: person ? .person : .voice, text: text, final: final)
    }

    @Test func thePersonsWordsShowAtOnceAndStayUntilTheReplyIsHeard() {
        var timeline = CallCaptionTimeline()
        timeline.row(row("p", "What's the weath", final: false))
        #expect(timeline.caption(playing: []) ?? ("", "") == ("", "What's the weath"), "live, as they are recognised")
        timeline.row(row("r1", "What's the weather in Antalya?"))
        // t0: the reply's text arrives (and its row), its audio doesn't play yet.
        timeline.replyAnnounced(7, text: "Sunny, 24 degrees.")
        timeline.row(row("r2", "Sunny, 24 degrees. A light breeze.", person: false))
        #expect(timeline.caption(playing: []) ?? ("", "") == ("What's the weather in Antalya?", ""), "no bot words before their audio")
        #expect(timeline.heard == "What's the weather in Antalya?")
        // t1: the audio of reply 7 plays.
        timeline.replyPlaying(7)
        #expect(timeline.caption(playing: [7]) ?? ("", "") == ("Sunny, 24 degrees.", ""))
        #expect(timeline.heard == "")
    }

    @Test func whileSpeakingTheSentencePlayedThenTheNextQueuedLighter() {
        var timeline = CallCaptionTimeline()
        timeline.replyAnnounced(1, text: "SXS 123 is on time.")
        timeline.replyAnnounced(2, text: "Boarding is at 18:40.")
        timeline.replyAnnounced(3, text: "Gate 207.")
        #expect(timeline.caption(playing: [1]) ?? ("", "") == ("SXS 123 is on time.", ""), "the next isn't queued for playback yet")
        #expect(timeline.caption(playing: [1, 2]) ?? ("", "") == ("SXS 123 is on time.", " Boarding is at 18:40."))
        #expect(timeline.caption(playing: [2, 3]) ?? ("", "") == ("Boarding is at 18:40.", " Gate 207."))
        #expect(timeline.caption(playing: [3]) ?? ("", "") == ("Gate 207.", ""))
    }

    @Test func anOlderReplyStillPlayingDoesNotHideTheNewTurn() {
        var timeline = CallCaptionTimeline()
        timeline.replyAnnounced(4, text: "An older sentence.")
        timeline.row(row("r9", "Stop, new question."))
        #expect(timeline.caption(playing: [4]) ?? ("", "") == ("Stop, new question.", ""))
    }

    @Test func talkingAgainShowsTheNewWords() {
        var timeline = CallCaptionTimeline()
        timeline.replyAnnounced(1, text: "Hello.")
        timeline.replyPlaying(1)
        timeline.row(row("p", "And", final: false))
        #expect(timeline.caption(playing: [1]) ?? ("", "") == ("", "And"))
    }
}
