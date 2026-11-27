import Foundation
import HermesActivityKit
import Testing

private typealias State = RequestActivityAttributes.ContentState
private let since = Date(timeIntervalSince1970: 1_791_000_000)

private func approval(deadline: Date? = since.addingTimeInterval(90), detail: String = "rm -rf /tmp/build", tool: String? = "terminal", more: Int = 0) -> State {
    State(botKey: "oracle::hermesbot", requestId: "srq-3", botName: "Hermes Bot", style: .approval, detail: detail, toolName: tool, deadline: deadline, since: since, moreWaiting: more)
}

private func question(choices: [String] = ["eu", "us"], needsApp: Bool = false, qid: String? = "q1") -> State {
    State(botKey: "oracle::hermesbot", requestId: "srq-2", botName: "Hermes Bot", style: .question, detail: "Which region?", deadline: nil, since: since, choices: choices, needsApp: needsApp, questionId: qid)
}

@Suite("Live Activity words: strings, countdown maths, buttons, accessibility")
struct ActivityPresentationTests {
    // MARK: countdown

    @Test func theCountdownRunsFromTheRequestsStartToTheGatewaysDeadline() {
        let shown = RequestActivityPresentation(approval())
        #expect(shown.countdown == .timer(since...since.addingTimeInterval(90)))
        #expect(shown.remainingSeconds(now: since.addingTimeInterval(10)) == 80)
        #expect(shown.remainingSeconds(now: since.addingTimeInterval(89.2)) == 1, "a part of a second still counts as a second")
        #expect(shown.remainingSeconds(now: since.addingTimeInterval(120)) == 0, "never negative")
    }

    @Test func noDeadlineMeansWaitingAndNoCountdown() {
        let shown = RequestActivityPresentation(approval(deadline: nil))
        #expect(shown.countdown == .waiting && shown.remainingSeconds(now: since) == nil)
        #expect(RequestActivityPresentation.waitingWord == "Waiting")
        #expect(shown.accessibilityLabel(now: since).hasSuffix("Waiting"))
    }

    @Test func aRequestFirstSeenAfterItsDeadlineGetsAValidRangeNotACrash() {
        var late = approval()
        late.since = since.addingTimeInterval(500)
        guard case .timer(let range) = RequestActivityPresentation(late).countdown else { Issue.record("no timer"); return }
        #expect(range.lowerBound <= range.upperBound)
    }

    @Test func aFinishedRequestHasNothingToCount() {
        var done = approval()
        done.outcome = .denied
        #expect(RequestActivityPresentation(done).countdown == .none)
    }

    @Test func aWaitingRequestShowsTheAppMarkAndAFinishedOneItsResult() {
        // Owner 2026-10-12: no status symbol while a request waits (the bubble shows the app's icon, the title says
        // the kind); the symbol stays where it carries the result.
        #expect(RequestActivityPresentation(approval()).outcomeSymbol == nil)
        #expect(RequestActivityPresentation(question()).outcomeSymbol == nil)
        let symbols: [(State.Outcome, String)] = [
            (.allowedOnce, "checkmark.circle.fill"), (.answeredElsewhere, "checkmark.circle.fill"), (.denied, "xmark.circle.fill"),
            (.expired, "clock.badge.xmark"), (.noLongerWaiting, "clock.badge.xmark"),
        ]
        for (outcome, symbol) in symbols {
            var done = approval()
            done.outcome = outcome
            #expect(RequestActivityPresentation(done).outcomeSymbol == symbol)
        }
    }

    @Test func clockAndSpokenFormats() {
        #expect(RequestActivityPresentation.clock(seconds: 90) == "1:30")
        #expect(RequestActivityPresentation.clock(seconds: 7) == "0:07")
        #expect(RequestActivityPresentation.clock(seconds: -3) == "0:00")
        #expect(RequestActivityPresentation.spoken(seconds: 90) == "1 minute 30 seconds")
        #expect(RequestActivityPresentation.spoken(seconds: 60) == "1 minute")
        #expect(RequestActivityPresentation.spoken(seconds: 1) == "1 second")
        #expect(RequestActivityPresentation.spoken(seconds: 0) == "0 seconds")
    }

    // MARK: text

    @Test func theCommandIsClippedAndTheToolNamed() {
        let long = String(repeating: "word ", count: 80)
        let shown = RequestActivityPresentation(approval(detail: long))
        #expect(shown.body.hasPrefix("terminal: word word"))
        #expect(shown.body.count <= RequestActivityPresentation.detailLimit + "terminal: ".count + 3)
        #expect(shown.body.hasSuffix("...") && !shown.body.contains("\u{2014}"))
        #expect(RequestActivityPresentation.clip("a\n  b\tc", 20) == "a b c", "whitespace collapses")
    }

    @Test func titlesNameTheBotAndWhatItWants() {
        #expect(RequestActivityPresentation(approval()).title == "Hermes Bot needs your approval")
        #expect(RequestActivityPresentation(question()).title == "Hermes Bot has a question")
        var computer = approval()
        computer.style = .computerOnly
        #expect(RequestActivityPresentation(computer).title == "Hermes Bot needs you at the computer")
    }

    @Test func aSudoPromptShowsOnlyTheFixedSentenceEvenIfTextWasSomehowSet() {
        var computer = approval(detail: "hunter2")
        computer.style = .computerOnly
        let shown = RequestActivityPresentation(computer)
        #expect(shown.body == "Answer on the computer." && !shown.accessibilityLabel(now: since).contains("hunter2"))
    }

    @Test func everyFinalLine() {
        typealias Outcome = State.Outcome
        let lines: [(Outcome, String?, String)] = [
            (.allowedOnce, nil, "Allowed once"), (.allowedForSession, nil, "Allowed for the session"), (.allowedAlways, nil, "Always allowed"),
            (.denied, nil, "Denied"), (.answered, nil, "Answered"), (.answeredElsewhere, "Gokhan's Mac", "Answered on Gokhan's Mac"),
            (.answeredElsewhere, nil, "Answered on another device"), (.answeredElsewhere, "", "Answered on another device"),
            (.expired, nil, "Expired"), (.noLongerWaiting, nil, "No longer waiting"),
        ]
        for (outcome, device, text) in lines { #expect(RequestActivityPresentation.finalLine(outcome, answeredBy: device) == text) }
    }

    @Test func waitingCountsOnlyWhenMoreThanOneWaits() {
        #expect(RequestActivityPresentation(approval()).waitingTitle == nil && RequestActivityPresentation(approval()).moreLine == nil)
        #expect(RequestActivityPresentation(approval(more: 1)).waitingTitle == "2 waiting")
        #expect(RequestActivityPresentation(approval(more: 1)).moreLine == "1 more waiting")
    }

    // MARK: buttons

    @Test func anApprovalOffersApproveOnceAndDeny() {
        let shown = RequestActivityPresentation(approval())
        #expect(shown.actions == [.approve, .deny])
        #expect(shown.title(for: .approve) == "Approve once" && shown.title(for: .deny) == "Deny")
    }

    @Test func aQuestionOffersUpToThreeChoicesAndOpensTheAppForMore() {
        #expect(RequestActivityPresentation(question()).actions == [.choice(index: 0, label: "eu"), .choice(index: 1, label: "us")])
        let many = RequestActivityPresentation(question(choices: ["a", "b", "c"], needsApp: true))
        #expect(many.actions.count == 4 && many.actions.last == .openToAnswer)
        let overflow = RequestActivityPresentation(question(choices: ["a", "b", "c", "d"]))
        #expect(overflow.actions.count == 4 && overflow.actions.last == .openToAnswer, "a fourth choice needs the app")
    }

    @Test func freeTextCannotBeTypedOnTheLockScreenSoItSaysOpenToAnswer() {
        #expect(RequestActivityPresentation(question(choices: [])).actions == [.openToAnswer])
        #expect(RequestActivityPresentation(question(choices: ["a"], qid: nil)).actions == [.openToAnswer])
        #expect(RequestActivityPresentation(question(choices: [])).title(for: .openToAnswer) == "Open to answer")
    }

    @Test func aFinishedRequestOffersNoButtons() {
        var done = question()
        done.outcome = .answered
        #expect(RequestActivityPresentation(done).actions.isEmpty)
    }

    // MARK: accessibility and house style

    @Test func theWholeActivityReadsAsOneSentenceWithTheTimeLeft() {
        let label = RequestActivityPresentation(approval(more: 1)).accessibilityLabel(now: since.addingTimeInterval(30))
        #expect(label == "Hermes Bot needs your approval. terminal: rm -rf /tmp/build. 1 minute left. 1 more waiting")
    }

    @Test func everyButtonHasAnAccessibleLabel() {
        let shown = RequestActivityPresentation(approval())
        #expect(shown.accessibilityLabel(for: .approve).contains("Approve once"))
        #expect(shown.accessibilityLabel(for: .deny).hasPrefix("Deny"))
        #expect(shown.accessibilityLabel(for: .choice(index: 0, label: "eu")) == "Answer eu")
        #expect(shown.accessibilityLabel(for: .openToAnswer) == "Open Hermes Neo to answer")
    }

    @Test func noWordInTheActivitiesHasAnEmDash() {
        var strings: [String] = [RequestActivityPresentation.approveTitle, RequestActivityPresentation.denyTitle, RequestActivityPresentation.openToAnswerTitle, RequestActivityPresentation.waitingWord]
        for style in [State.Style.approval, .question, .computerOnly] {
            var state = approval(more: 2)
            state.style = style
            let shown = RequestActivityPresentation(state)
            strings += [shown.title, shown.body, shown.waitingTitle ?? "", shown.moreLine ?? "", shown.accessibilityLabel(now: since)]
            strings += shown.actions.flatMap { [shown.title(for: $0), shown.accessibilityLabel(for: $0)] }
        }
        for outcome in [State.Outcome.allowedOnce, .allowedForSession, .allowedAlways, .denied, .answered, .answeredElsewhere, .expired, .noLongerWaiting] {
            strings.append(RequestActivityPresentation.finalLine(outcome, answeredBy: nil))
        }
        for text in strings { #expect(!text.contains("\u{2014}") && !text.contains("\u{2013}"), "\(text)") }
    }

    // MARK: links and the content state

    @Test func onlyAnExactLiveRequestInAnExperimentalBuildOffersAnswers() {
        var state = approval(deadline: nil, detail: "git status")
        state.requestId = "srq-a12345678901"
        #expect(RequestActivityPresentation(state).actions(lockScreenAnswersEnabled: true, isStale: false) == [.openToAnswer])
        state.sessionId = "session-1"
        state.executionGeneration = 8
        state.command = "git status"
        state.approvalKind = "command"
        let live = RequestActivityPresentation(state)
        #expect(live.actions(lockScreenAnswersEnabled: true, isStale: false) == [.openToAnswer])
        #expect(live.actions(lockScreenAnswersEnabled: false, isStale: false) == [.openToAnswer])
        #expect(live.actions(lockScreenAnswersEnabled: true, isStale: true) == [.openToAnswer])
        state.requestId = "a12345678901b12345678901c1234567"
        #expect(RequestActivityPresentation(state).actions(lockScreenAnswersEnabled: true, isStale: false) == [.approve, .deny])
        state.command = String(repeating: "x", count: 241)
        #expect(RequestActivityPresentation(state).actions(lockScreenAnswersEnabled: true, isStale: false) == [.openToAnswer])
        state.command = "git status"
        state.approvalKind = "restricted"
        #expect(RequestActivityPresentation(state).actions(lockScreenAnswersEnabled: true, isStale: false) == [.openToAnswer])
        state.outcome = .expired
        #expect(RequestActivityPresentation(state).actions(lockScreenAnswersEnabled: true, isStale: false).isEmpty)
    }

    @Test func aSingleChoiceQuestionAlwaysOffersTyping() {
        var state = approval(deadline: nil, detail: "Which color?")
        state.style = .question
        state.requestId = "native-question"
        state.sessionId = "session-1"
        state.executionGeneration = 1
        state.choices = ["Red", "Blue"]
        state.questionId = "color"
        #expect(RequestActivityPresentation(state).actions(lockScreenAnswersEnabled: true, isStale: false)
            == [.choice(index: 0, label: "Red"), .choice(index: 1, label: "Blue"), .typeAnAnswer])
        state.needsApp = true
        #expect(RequestActivityPresentation(state).actions(lockScreenAnswersEnabled: true, isStale: false) == [.typeAnAnswer])
        state.choices = []
        #expect(RequestActivityPresentation(state).actions(lockScreenAnswersEnabled: true, isStale: false) == [.typeAnAnswer])
    }

    @Test func aFrameQuestionUsesItsExactLinkWithoutAGeneration() throws {
        var state = question()
        state.sessionId = "session-1"
        let reference = try #require(RequestReference(state))
        #expect(reference.isFrame)
        let link = ActivityLink.request(reference)
        #expect(ActivityLink(url: link.url) == link)
        #expect(RequestActivityPresentation(state).actions(lockScreenAnswersEnabled: true, isStale: false)
            == [.choice(index: 0, label: "eu"), .choice(index: 1, label: "us"), .typeAnAnswer])
        state.questionId = nil
        #expect(RequestActivityPresentation(state).actions(lockScreenAnswersEnabled: true, isStale: false) == [.typeAnAnswer])
    }

    @Test func questionIntentVerifiesTheOriginalTextRatherThanTheDisplayCopy() {
        var state = question()
        state.detail = "Which\n  region?"
        let presentation = RequestActivityPresentation(state)
        #expect(presentation.body == "Which region?")
        #expect(presentation.textToVerify(for: .choice(index: 0, label: "eu")) == "Which\n  region?")
        #expect(presentation.textToVerify(for: .typeAnAnswer) == nil)
    }

    @Test func aCardLinkRoundTripsTheWholeReference() throws {
        let ref = try #require(RequestReference(botKey: "oracle::hermes", requestId: "native-id", sessionId: "session-1", executionGeneration: 0))
        let link = ActivityLink.request(ref)
        #expect(ActivityLink(url: link.url) == link)
        #expect(ActivityLink(url: URL(string: "hermesneo://request-card?key=oracle::hermes&request=native-id")!) == nil)
    }

    @Test func linksRoundTripAndForeignURLsAreIgnored() {
        for link in [ActivityLink.waiting, .bot(key: "oracle::hermesbot")] {
            #expect(ActivityLink(url: link.url) == link, "\(link.url)")
        }
        #expect(ActivityLink(url: URL(string: "https://example.com/waiting")!) == nil)
        #expect(ActivityLink(url: URL(string: "hermesneo://request-bot")!) == nil, "a bot link needs its key")
        #expect(ActivityLink(url: URL(string: "hermesbot://elsewhere")!) == nil)
    }

    @Test func theContentStateStaysFarUnderTheFourKilobyteActivityLimit() throws {
        var state = approval(detail: String(repeating: "x", count: 4000))
        state.detail = RequestActivityPresentation.clip(state.detail, RequestActivityPresentation.detailLimit)
        let size = try JSONEncoder().encode(state).count
        #expect(size < 1024, "\(size) bytes")
    }
}
