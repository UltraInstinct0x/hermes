import Foundation
import Testing

@testable import HermesBox

@Suite("Hermes Neo: a reply's caption as it is spoken, a sentence at a time")
struct CallCaptionProgressTests {
    private let reply = "SXS 123 is on time. Boarding at 18:40 from gate 207. The details are on your screen."

    @Test func onlyTheSentenceBeingSpokenShowsWithItsHeardWordsSettled() {
        let start = CallCaptionProgress.split(reply, progress: 0)
        #expect(start.settled == "" && start.lighter == "SXS 123 is on time.")
        let middle = CallCaptionProgress.split(reply, progress: 0.5)
        #expect((middle.settled + middle.lighter) == "Boarding at 18:40 from gate 207.")
        #expect(!middle.settled.isEmpty && !middle.lighter.isEmpty)
        #expect(middle.settled.hasSuffix(" "), "whole words only")
        let end = CallCaptionProgress.split(reply, progress: 1)
        #expect(end.settled == "The details are on your screen." && end.lighter == "")
    }

    @Test func sentencesFollowOneByOne() {
        var seen: [String] = []
        for step in 0...20 {
            let caption = CallCaptionProgress.split(reply, progress: Double(step) / 20)
            let sentence = caption.settled + caption.lighter
            if seen.last != sentence { seen.append(sentence) }
        }
        #expect(seen == ["SXS 123 is on time.", "Boarding at 18:40 from gate 207.", "The details are on your screen."])
    }

    @Test func emptyAndOneSentenceReplies() {
        #expect(CallCaptionProgress.split("", progress: 0.5) == ("", ""))
        let one = CallCaptionProgress.split("Hello there", progress: 0.6)
        #expect(one.settled + one.lighter == "Hello there")
    }
}
