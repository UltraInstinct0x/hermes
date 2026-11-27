#if os(iOS)
import Foundation
import HermesBox
import HermesKit
import Observation

/// A call through the owner's box as one of the app's own Talk calls (`TalkDisplay`), so it gets every app-level call
/// feature: `TalkCenter` holds it while it runs, so the real call pill shows in the chat (`CallPill`), End and
/// minimise go through `TalkCenter`, and when it ends its card (`CallSummaryCard`) goes into the calling bot's chat,
/// with its words behind Transcript and Talk Again.
@MainActor
@Observable
final class NeoTalkCall: TalkDisplay {
    @ObservationIgnored let calls: CallController
    @ObservationIgnored private weak var box: NeoBox?
    @ObservationIgnored private var watcher: Task<Void, Never>?
    @ObservationIgnored private var attached = false
    @ObservationIgnored private var recorded = false
    var showsCaptions = false

    init(calls: CallController, box: NeoBox) {
        self.calls = calls
        self.box = box
    }

    /// Follows the call: shown by `TalkCenter` while it runs, its card made once when it ends, let go when cleared.
    func start() {
        guard watcher == nil else { return }
        let calls = calls
        watcher = Task { [weak self] in
            for await phase in Observations({ calls.phase }) {
                self?.follow(phase)
            }
        }
    }

    private func follow(_ phase: CallController.Phase) {
        switch phase {
        case .running:
            recorded = false
            if lastStart == nil { lastStart = calls.callStartedAt ?? .now }
            guard !attached else { return }
            attached = true
            let calls = calls
            TalkCenter.shared.attach(external: self, expanded: calls.isScreenShown, end: { calls.end() })
        case .over, .failed:
            if !recorded {
                recorded = true
                Task { await self.saveRecord() }
            }
            // Ended while minimised: its card says it all, no ended screen waits behind the pill.
            if attached, !TalkCenter.shared.isExpanded { calls.clear() }
        case .idle:
            lastStart = nil
            guard attached else { return }
            attached = false
            TalkCenter.shared.detachExternal()
        }
    }

    /// The call's card in the bot's chat, as `TalkCenter` makes one for its own calls.
    private func saveRecord() async {
        guard let started = lastStart, let bot = calls.bot, let session = calls.session else { return }
        let rows = session.captions.rows.filter { !$0.text.isEmpty }
        guard !rows.isEmpty else { return }
        let lines = rows.map { CallRecord.Line(isUser: $0.speaker == .person, text: $0.text) }
        let profile = BotKey(rawValue: bot.botKey).profileId
        let chat = await box?.botChatSessionID(botKey: bot.botKey)
        var record = CallRecord(
            id: UUID(), session: chat, botName: profile, title: bot.name, startedAt: started, endedAt: .now,
            turns: lines.filter { !$0.isUser }.count, approvals: 0, steps: 0)
        record.lines = lines
        if let last = lines.last(where: { !$0.isUser })?.text, TalkCenter.isSummary(last) { record.summary = last }
        TalkCenter.shared.save(record)
    }

    /// When the running call started here (kept for its card once it is over).
    @ObservationIgnored private var lastStart: Date?

    // MARK: TalkDisplay

    var phase: TalkSession.Phase {
        if !calls.isInCall { return .connecting }
        if calls.hold != nil { return .onHold }
        if chat?.pendingApproval != nil { return .approval }
        switch NeoCallOrbHost.state(calls) {
        case .speaking: return .speaking
        case .processing: return .working
        case .connecting, .neutral: return .connecting
        case .paused: return .onHold
        case .listening, .muted, .standby: return .listening
        }
    }

    var speakerName: String { calls.bot?.name ?? "Your bot" }

    var figureAppearance: BotAppearance {
        box?.appearance(botKey: calls.bot?.botKey) ?? BotAppearance(profile: BotKey(rawValue: calls.bot?.botKey ?? "").profileId)
    }

    var engineName: String { calls.session.map { CallPresentation.engineName($0.engine) } ?? CallPresentation.engineName(.free) }
    var startedAt: Date? { calls.callStartedAt }

    var status: String { calls.stateLine }

    var caption: (settled: String, lighter: String)? {
        guard let captions = calls.session?.captions else { return nil }
        if let heard = captions.partialPerson { return (settled: "", lighter: heard) }
        return captions.botLine.map { (settled: $0, lighter: "") }
    }

    var hint: String? { nil }
    var notice: String? { calls.session?.notice }
    var isLoudRoom: Bool { false }
    var setupNote: SetupStatus? { nil }
    var isMuted: Bool { calls.isMuted }
    var inputLevel: Float { Float(calls.micLevel) }
    var outputLevel: Float { Float(calls.playbackLevel) }
    var runningStep: (title: String, since: Date)? { nil }
    var card: String? { nil }
    var pendingApproval: ApprovalRequest? { chat?.pendingApproval }
    var pendingRequest: HermesRequest? { chat?.shownRequest }
    var chat: ConversationModel? { box?.waitingConversation(botKey: calls.bot?.botKey) }
    var route: AudioRoute { AudioRoute(output: calls.outputState.routeIsFilled ? .speaker : .receiver, name: "") }
    var heard: String { calls.session?.captions.partialPerson ?? "" }

    var transcriptLines: [TalkLine] {
        (calls.session?.captions.rows ?? []).filter { !$0.text.isEmpty }.map { TalkLine(id: $0.rowId, isUser: $0.speaker == .person, text: $0.text) }
    }

    func toggleMute() { calls.toggleMute() }
    func interrupt() {}
    func retry() { Task { await calls.retry() } }

    func respond(_ choice: ApprovalChoice, to approval: ApprovalRequest) {
        chat?.respond(to: approval, with: choice)
    }
}
#endif
