import Foundation
import Testing

@testable import HermesBox

private func item(_ n: Int, title: String? = nil) -> CallDisplayItem {
    CallDisplayItem(id: "id\(n)", kind: .markdown, title: title ?? "Item \(n)", body: "x")
}

@Suite("Call ended summary: one shared ending for every cause")
struct CallEndedSummaryTests {
    private func summary(_ ending: CallEnding, name: String = "Hermes") -> CallEndedSummary {
        CallEndedSummary.make(ending: ending, botName: name, duration: 240, display: [])
    }

    @Test func eachReasonHasItsTitle() {
        #expect(summary(.byClient).title == "You ended the call")
        #expect(summary(.other("ended_by_bot")).title == "Hermes ended the call")
        #expect(summary(.other("answered_elsewhere")).title == "The call was handed to another device")
        #expect(summary(.gatewayLost).title == "The connection was lost")
        #expect(summary(.hubRestart).title == "The connection was lost")
        #expect(summary(.idleTimeout).title == "The call ended")
        #expect(summary(.maxDuration).title == "The call ended")
    }

    @Test func aReasonFromANewerHubNeverCrashesAndFallsBack() {
        for reason in ["", "something_new", "ENDED_BY_BOT ", "ended_by_bot\u{0}", String(repeating: "x", count: 5000), "🙂"] {
            #expect(summary(CallEnding(reason: reason)).title == "The call ended")
        }
        #expect(summary(CallEnding(reason: "brand_new_reason")).kind == .other)
        #expect(summary(CallEnding(reason: "ended_by_bot")).kind == .botEnded)
    }

    @Test func aBotWithNoNameStillReadsCalmly() {
        #expect(summary(.other("ended_by_bot"), name: "  ").title == "Your bot ended the call")
    }

    @Test func durationIsInPlainWords() {
        #expect(CallEndedSummary.durationWords(0) == nil)
        #expect(CallEndedSummary.durationWords(.nan) == nil)
        #expect(CallEndedSummary.durationWords(20) == "Less than a minute")
        #expect(CallEndedSummary.durationWords(60) == "1 minute")
        #expect(CallEndedSummary.durationWords(240) == "4 minutes")
        #expect(CallEndedSummary.durationWords(3600) == "1 hour")
        #expect(CallEndedSummary.durationWords(3900) == "1 hour 5 minutes")
        #expect(CallEndedSummary.durationWords(7200 + 120) == "2 hours 2 minutes")
    }

    @Test func titlesAreTheFirstFiveNewestAndEmptyOnesAreNamedByKind() {
        let items = (1...7).map { item($0) }
        #expect(CallEndedSummary.titles(items) == ["Item 1", "Item 2", "Item 3", "Item 4", "Item 5"])
        #expect(CallEndedSummary.titles([item(1, title: " ")]) == ["Note"])
        #expect(CallEndedSummary.titles([]).isEmpty)
    }

    @Test func aFailureBeforeTheCallStartedCouldNotStart() {
        let failure = CallFailure(sentence: "Could not reach the call service.", details: "raw cause", canRetry: true)
        let early = CallEndedSummary.make(failure: failure, started: false, botName: "Hermes", duration: 3, display: [])
        #expect(early.title == "The call could not start")
        #expect(early.durationText == nil)
        #expect(early.detail == "Could not reach the call service.")
        #expect(early.copyableDetails == "raw cause")
        let late = CallEndedSummary.make(failure: failure, started: true, botName: "Hermes", duration: 120, display: [])
        #expect(late.title == "The connection was lost")
        #expect(late.durationText == "2 minutes")
    }

    @Test func callsThatCannotBeRetriedDoNotOfferCallAgain() {
        let off = CallFailure(sentence: "Calls are not enabled on this machine.", details: "404", canRetry: false)
        #expect(!CallEndedSummary.make(failure: off, started: false, botName: "H", duration: 0, display: []).canCallAgain)
    }

    @Test func noTitleHasAnEmDash() {
        let kinds: [CallEndedSummary.Kind] = [.ownerEnded, .botEnded, .handedOver, .connectionLost, .couldNotStart, .other]
        for kind in kinds {
            #expect(!CallEndedSummary.title(kind, botName: "Hermes").contains("\u{2014}"))
        }
    }
}
