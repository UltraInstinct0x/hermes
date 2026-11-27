import Foundation

/// What the session asks its owner to do. The session itself touches no socket, no audio and no clock.
public enum CallEffect: Sendable, Equatable {
    case send(CallOutbound)
    /// Drop everything queued for playback now (barge-in, takeover, end).
    case stopPlayback
    case beginReply(replyId: UInt32, sampleRate: Int)
    case endReply(replyId: UInt32)
    /// The call is over (the reason is on the session).
    case finished
}

/// The last lines of the call as the screen draws them.
public struct CallCaptions: Sendable, Equatable {
    public private(set) var rows: [CallTranscriptRow] = []
    public private(set) var partialPerson: String?

    public init() {}

    mutating func apply(_ row: CallTranscriptRow) {
        if row.isPartial {
            partialPerson = row.text.isEmpty ? nil : row.text
            return
        }
        if row.speaker == .person { partialPerson = nil }
        if let index = rows.firstIndex(where: { $0.rowId == row.rowId }) {
            rows[index] = row
        } else {
            rows.append(row)
            if rows.count > 60 { rows.removeFirst(rows.count - 60) }
        }
    }

    /// What the person said last, or what they are saying now.
    public var userLine: String? {
        partialPerson ?? rows.last(where: { $0.speaker == .person && !$0.text.isEmpty })?.text
    }

    public var botLine: String? { rows.last(where: { $0.speaker == .voice && !$0.text.isEmpty })?.text }
}

/// Why a call is over, as a calm sentence.
public enum CallEnding: Sendable, Equatable {
    case byClient
    case gatewayLost
    case idleTimeout
    case maxDuration
    case hubRestart
    case other(String)

    init(reason: String) {
        switch reason {
        case "ended_by_client": self = .byClient
        case "gateway_lost": self = .gatewayLost
        case "idle_timeout", "ownerless_timeout": self = .idleTimeout
        case "max_duration": self = .maxDuration
        case "hub_restart": self = .hubRestart
        default: self = .other(reason)
        }
    }

    public var sentence: String {
        switch self {
        case .byClient: "The call ended."
        case .gatewayLost: "The call ended because the server lost its voice link."
        case .idleTimeout: "The call ended because nobody was on it."
        case .maxDuration: "The call ended because it reached its time limit."
        case .hubRestart: "The call ended because the call service restarted."
        case .other: "The call ended."
        }
    }

    /// A call the person ended themselves needs no Retry.
    public var isCalm: Bool { self == .byClient }
}

/// The client's view of one call: who drives it, under which epoch, what was said, what is playing. Pure.
///
/// Epoch fencing as the client sees it (S19 R4, R5, R40): the epoch is taken ONLY from `call.started`, `call.joined`,
/// `call.taken`, `call.state` and `hello.ok.yours`, and is forgotten the moment the link drops. Audio is allowed
/// only while this device is the owner of an active call on a live link (`uplinkEpoch`). After a reconnect the
/// phone asks for the role again with `call.join`; it speaks again only when it is the owner, or when the call is
/// ownerless and it was the owner before (it then takes it, the hub answers with a fresh epoch).
public struct CallSession: Sendable, Equatable {
    public enum Link: Sendable, Equatable { case connecting, up, reconnecting }

    public enum Intent: Sendable, Equatable {
        /// Start a call to the bot, or join the one that already runs for it.
        case start(botKey: String, engine: CallEngine)
        /// Join a call that is known by id (a call running on the desktop).
        case join(callId: String)
        /// S27: answer a ring the box started for `botKey`: join the ownerless call, then take it at once.
        case answer(callId: String, botKey: String)
    }

    private enum Pending: Sendable, Equatable { case start, join, take, end, say, leave }

    public let botKey: String
    public private(set) var engine: CallEngine
    public private(set) var link: Link = .connecting
    public private(set) var callId: String?
    public private(set) var hubState: HubCallState = .starting
    public private(set) var role: CallRole?
    public private(set) var epoch: UInt32?
    public private(set) var ownerClientId: String?
    public private(set) var ownerName: String?
    public private(set) var clientId: String?
    public private(set) var lastSeq = 0
    public private(set) var captions = CallCaptions()
    /// What the bot put on the call screen. Gone with the call.
    public private(set) var display = CallDisplayList()
    /// What was on the screen at the moment the call ended (the list itself is emptied then), for the end-of-call summary.
    public private(set) var displayWhenEnded: [CallDisplayItem] = []
    /// The bot is in standby: it hears the microphone but answers only to a wake word. The call stays open.
    public private(set) var standingBy = false
    public private(set) var ending: CallEnding?
    /// The hub refused the request; a calm sentence for it.
    public private(set) var refusal: HubErrorCode?
    /// A calm line about something that did not work but did not end the call.
    public private(set) var notice: String?
    /// Replies the hub announced and has not ended yet.
    public private(set) var openReplies: Set<UInt32> = []
    /// The person finished a sentence and the bot has not answered yet.
    public private(set) var awaitingReply = false
    /// This device was the owner before the link dropped: it takes the call back when nobody else did.
    public private(set) var wantsOwner = false
    /// A call that was already running when this phone asked (joined, not started).
    public private(set) var joinedExisting = false
    /// S27: this session answers a ring (CallKit): it takes the call as soon as it has joined it.
    public private(set) var answersRing = false
    /// The last error code the hub sent, how many it sent, and the transcript rows seen (for Details).
    public private(set) var lastHubError: HubErrorCode?
    public private(set) var hubErrorCount = 0
    public private(set) var partialRows = 0
    public private(set) var finalPersonRows = 0

    private var intent: Intent
    private var pending: [String: Pending] = [:]
    private var counter = 0

    public init(intent: Intent) {
        self.intent = intent
        switch intent {
        case .start(let botKey, let engine):
            self.botKey = botKey
            self.engine = engine
        case .join:
            self.botKey = ""
            self.engine = .free
        case .answer(_, let botKey):
            self.botKey = botKey
            self.engine = .free
            answersRing = true
        }
        if case .join(let id) = intent { callId = id }
        if case .answer(let id, _) = intent { callId = id }
    }

    // MARK: derived

    /// What the bot had on the screen at the end, whether the call ended with a reason or failed on the phone.
    public var displayForSummary: [CallDisplayItem] { ending == nil ? display.items : displayWhenEnded }

    public var isOver: Bool { ending != nil || hubState.isFinal }

    /// The epoch to put on mic frames, or nil when this device may not talk into the call right now.
    public var uplinkEpoch: UInt32? {
        guard link == .up, role == .owner, hubState == .active, engine == .free, ending == nil else { return nil }
        return epoch
    }

    public var isListenerOnly: Bool { role == .listener && link == .up && !isOver }

    /// Another device drives the call: the screen says so and offers the takeover.
    public var isElsewhere: Bool { isListenerOnly && ownerClientId != nil && ownerClientId != clientId }

    public var canTakeOver: Bool { isListenerOnly && engine == .free && hubState == .active }

    // MARK: link

    /// The link is up and the hub said hello. Starts, joins or resumes, depending on what is known.
    public mutating func linkUp(_ hello: HelloOk) -> [CallEffect] {
        link = .up
        clientId = hello.clientId
        epoch = nil
        if role == .owner { wantsOwner = true }
        role = nil
        if let id = callId {
            if answersRing, let ringing = hello.calls.first(where: { $0.callId == id }) { adopt(ringing) }
            if let mine = hello.yours.first(where: { $0.callId == id }) {
                role = mine.role
                epoch = mine.ownerEpoch
            }
            return [join(id, since: lastSeq > 0 ? lastSeq : nil)]
        }
        guard case .start(let botKey, let engine) = intent else { return [] }
        if let running = hello.calls.first(where: { $0.botKey == botKey && !$0.state.isFinal }) {
            joinedExisting = true
            adopt(running)
            callId = running.callId
            return [join(running.callId, since: nil)]
        }
        self.engine = engine
        return [send(.start, { .start(id: $0, botKey: botKey, engine: engine) })]
    }

    /// The link dropped. The epoch is forgotten on purpose: it is never reused after a reconnect.
    public mutating func linkDown() {
        link = callId == nil ? .connecting : .reconnecting
        if role == .owner { wantsOwner = true }
        role = nil
        epoch = nil
        openReplies = []
        pending = [:]
    }

    // MARK: what the person does

    public mutating func take() -> [CallEffect] {
        guard let id = callId, canTakeOver else { return [] }
        return [send(.take, { .take(id: $0, callId: id) })]
    }

    public mutating func end() -> [CallEffect] {
        guard let id = callId, link == .up else { return [.stopPlayback] + finish(.byClient) }
        return [send(.end, { .end(id: $0, callId: id) })]
    }

    public mutating func say(_ text: String) -> [CallEffect] {
        guard let id = callId, link == .up else { return [] }
        return [send(.say, { .say(id: $0, callId: id, text: text) })]
    }

    /// The phone's own end-of-speech: the hub is now working on an answer.
    public mutating func localUtteranceEnded() { awaitingReply = true }

    /// The person began a new utterance: whatever was pending is superseded.
    public mutating func localSpeechBegan() { awaitingReply = false }

    public mutating func dismissNotice() { notice = nil }

    /// The person cleared the screen. Local only: the hub and the other devices keep theirs.
    public mutating func clearDisplay() { display.clear() }

    // MARK: what the hub says

    public mutating func handle(_ inbound: CallInbound) -> [CallEffect] {
        switch inbound {
        case .helloOk, .callList, .said, .left, .pong, .other:
            return []
        case .started(let id, let callId, let epoch, let call):
            settle(id)
            self.callId = callId
            adopt(call)
            role = .owner
            self.epoch = epoch
            return []
        case .joined(let id, let callId, let you, _, let events):
            settle(id)
            self.callId = callId
            role = you.role
            epoch = you.ownerEpoch
            for row in events { record(row) }
            if you.role == .owner {
                wantsOwner = false
                return []
            }
            // Claim the call at once (a free takeover is immediate) when nobody drives it: after a reconnect, or when
            // this phone asked for a call and found one that is ownerless or is its OWN stale one (a crash, a restart,
            // a lost socket). A live call of ANOTHER device is left alone: the screen offers the takeover.
            let ownerless = ownerClientId == nil
            let mine = ownerClientId != nil && ownerClientId == clientId
            if answersRing {
                // A ring is answered by exactly one device: another one that already drives it answered first.
                guard ownerless || mine else { return [.stopPlayback] + finish(.other("answered_elsewhere")) }
                wantsOwner = false
                guard !pending.values.contains(.take) else { return [] }
                return [send(.take, { .take(id: $0, callId: callId) })]
            }
            let claim = engine == .free && !pending.values.contains(.take)
                && ((wantsOwner && (ownerless || mine)) || (joinedExisting && (ownerless || mine)))
            wantsOwner = false
            if claim { return [send(.take, { .take(id: $0, callId: callId) })] }
            return []
        case .taken(let callId, let epoch, _):
            guard callId == self.callId else { return [] }
            pending = pending.filter { $0.value != .take }
            role = .owner
            self.epoch = epoch
            wantsOwner = false
            notice = nil
            return []
        case .state(let call, let you):
            guard call.callId == callId else { return [] }
            let wasOwner = role == .owner
            adopt(call)
            role = you.role
            epoch = you.ownerEpoch
            var effects: [CallEffect] = []
            if wasOwner && you.role != .owner {
                wantsOwner = false
                openReplies = []
                effects.append(.stopPlayback)
            }
            if call.state.isFinal { effects += finish(CallEnding(reason: call.endedReason ?? "")) }
            return effects
        case .transcript(let row):
            guard row.callId == callId else { return [] }
            record(row)
            return []
        case .handover(let callId, _, _, let to):
            guard callId == self.callId else { return [] }
            if to != clientId {
                openReplies = []
                return [.stopPlayback]
            }
            return []
        case .display(let callId, let item):
            guard callId == self.callId else { return [] }
            display.apply(item)
            return []
        case .displayClear(let callId):
            guard callId == self.callId else { return [] }
            display.clear()
            return []
        case .standby(let callId, let on):
            guard callId == self.callId else { return [] }
            standingBy = on
            return []
        case .ended(let callId, let reason):
            guard callId == self.callId else { return [] }
            return finish(CallEnding(reason: reason))
        case .ttsStart(let callId, let replyId, let rate, _):
            guard callId == self.callId, role == .owner else { return [] }
            openReplies.insert(replyId)
            awaitingReply = false
            return [.beginReply(replyId: replyId, sampleRate: rate)]
        case .ttsEnd(let callId, let replyId, _):
            guard callId == self.callId else { return [] }
            openReplies.remove(replyId)
            return [.endReply(replyId: replyId)]
        case .ttsStop(let callId):
            guard callId == self.callId else { return [] }
            openReplies = []
            return [.stopPlayback]
        case .error(let code, let id, let errorCallId, _):
            return handleError(code, id: id, callId: errorCallId)
        }
    }

    // MARK: pieces

    private mutating func handleError(_ code: HubErrorCode, id: String?, callId errorCallId: String?) -> [CallEffect] {
        lastHubError = code
        hubErrorCount += 1
        let kind = id.flatMap { pending.removeValue(forKey: $0) }
        switch code {
        case .notOwner, .staleEpoch:
            role = .listener
            epoch = nil
            wantsOwner = false
            openReplies = []
            return [.stopPlayback]
        case .notFound:
            guard callId != nil else { refusal = code; return [] }
            return [.stopPlayback] + finish(.other("not_found"))
        case .callExists where kind == .start:
            guard let existing = errorCallId else { refusal = code; return [] }
            joinedExisting = true
            callId = existing
            return [join(existing, since: nil)]
        default:
            if kind == .start || callId == nil {
                refusal = code
            } else {
                notice = code.sentence
            }
            return []
        }
    }

    private mutating func record(_ row: CallTranscriptRow) {
        captions.apply(row)
        if row.isPartial { partialRows += 1 } else if row.speaker == .person, row.final { finalPersonRows += 1 }
        if let seq = row.seq { lastSeq = max(lastSeq, seq) }
        if row.speaker == .person, row.final, !row.isPartial { awaitingReply = true }
        if row.speaker == .voice { awaitingReply = false }
    }

    private mutating func adopt(_ call: CallSummary) {
        engine = call.engine
        hubState = call.state
        ownerClientId = call.ownerClientId
        ownerName = call.ownerName
        lastSeq = max(lastSeq, call.seq)
    }

    private mutating func finish(_ reason: CallEnding) -> [CallEffect] {
        guard ending == nil else { return [] }
        ending = reason
        displayWhenEnded = display.items
        display.clear()
        standingBy = false
        role = nil
        epoch = nil
        openReplies = []
        awaitingReply = false
        return [.stopPlayback, .finished]
    }

    private mutating func join(_ id: String, since: Int?) -> CallEffect {
        send(.join, { .join(id: $0, callId: id, since: since) })
    }

    private mutating func send(_ kind: Pending, _ make: (String) -> CallOutbound) -> CallEffect {
        counter += 1
        let id = "c\(counter)"
        pending[id] = kind
        return .send(make(id))
    }

    private mutating func settle(_ id: String?) {
        if let id { pending[id] = nil }
    }
}
