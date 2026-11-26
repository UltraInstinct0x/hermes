import Foundation

/// The always-on "Hermes Bot" bubble (S22): one line of what is true right now (machines online, requests waiting,
/// the last event with its age), and the same bubble turns into the call bubble while a call runs.
///
/// The box also writes this type: its `ContentState` JSON is built by `box/bff/push-planner.mjs`
/// (`baseContentState`), and a test on each side pins the keys. Every time in it is whole EPOCH SECONDS (`Int`),
/// not a `Date`: ActivityKit decodes a pushed state with the default decoder, where a `Date` would be seconds since
/// 2001, and a plain integer cannot be misread.
public struct BaseActivityAttributes: Codable, Hashable, Sendable {
    public var title: String
    /// When this activity was started, epoch seconds. Lets the app tell a system end at the 8 hour limit from the
    /// owner swiping it away, after a relaunch. Absent on an activity an older server started.
    public var startedAt: Int?

    public init(title: String = ActivityBrand.name, startedAt: Int? = nil) {
        self.title = title
        self.startedAt = startedAt
    }

    public struct ContentState: Codable, Hashable, Sendable {
        public enum Mode: String, Codable, Hashable, Sendable {
            /// The always-on line.
            case idle
            /// A call is running: state, elapsed time, Mute (when this phone talks) and End.
            case call
        }

        public struct Call: Codable, Hashable, Sendable {
            public var botKey: String
            public var botName: String
            public var stateLine: String
            /// Epoch seconds; the elapsed time counts by itself from it.
            public var startedAt: Int
            /// This phone is the one talking: Mute is meaningful. Another device's call gets End only.
            public var ownerHere: Bool
            public var ownerName: String?
            public var isMuted: Bool?
            /// The sound goes to the speaker or a connected device (the AirPlay circle is filled). Absent from an older writer.
            public var outputOn: Bool?
            /// A tap on the circle may swap speaker and receiver (no device connected). Absent: the circle opens the call.
            public var canChooseOutput: Bool?

            public init(
                botKey: String, botName: String, stateLine: String, startedAt: Int, ownerHere: Bool, ownerName: String? = nil, isMuted: Bool? = nil,
                outputOn: Bool? = nil, canChooseOutput: Bool? = nil
            ) {
                self.outputOn = outputOn
                self.canChooseOutput = canChooseOutput
                self.botKey = botKey
                self.botName = botName
                self.stateLine = stateLine
                self.startedAt = startedAt
                self.ownerHere = ownerHere
                self.ownerName = ownerName
                self.isMuted = isMuted
            }
        }

        /// One session that works right now (S25): a bot's own turn, or the tasks of one delegating turn. The words are
        /// made by whoever writes the state (the box's `running-summary.mjs` or the app's `RunningSummary`), the widget
        /// only draws them. `startedAt` is epoch seconds: the elapsed time counts by itself on the phone.
        public struct Running: Codable, Hashable, Sendable {
            public var botKey: String
            public var botName: String
            /// `turn` or `tasks`. A plain string, so a kind a newer box sends never breaks an older widget's decoding.
            public var kind: String
            public var startedAt: Int
            /// "Using terminal", "Working", "Working in a chat: <topic>", "3 chats: 1 done, 2 working".
            public var line: String

            public init(botKey: String, botName: String, kind: String, startedAt: Int, line: String) {
                self.botKey = botKey
                self.botName = botName
                self.kind = kind
                self.startedAt = startedAt
                self.line = line
            }
        }

        public var mode: Mode
        public var machinesOnline: Int
        public var machinesTotal: Int
        public var waiting: Int
        /// The last real event ("Allowed once (hermesbot)"). Nil until there is one: nothing is invented.
        public var lastEvent: String?
        public var lastEventAt: Int?
        /// When this state was made, epoch seconds: "updated N min ago" counts from it.
        public var updatedAt: Int
        public var call: Call?
        /// S25: at most two sessions working right now, longest running first. Nil (absent) when nothing runs, and
        /// from an older box: optional, so either side may be older than the other.
        public var running: [Running]?
        /// S25: how many more sessions work than `running` shows ("+2 more"). Absent for none.
        public var runningMore: Int?

        public init(
            mode: Mode = .idle, machinesOnline: Int, machinesTotal: Int, waiting: Int, lastEvent: String? = nil, lastEventAt: Int? = nil,
            updatedAt: Int, call: Call? = nil, running: [Running]? = nil, runningMore: Int? = nil
        ) {
            self.mode = mode
            self.machinesOnline = machinesOnline
            self.machinesTotal = machinesTotal
            self.waiting = waiting
            self.lastEvent = lastEvent
            self.lastEventAt = lastEventAt
            self.updatedAt = updatedAt
            self.call = call
            self.running = running
            self.runningMore = runningMore
        }
    }
}

/// The words of the base bubble, as pure functions of a content state and the clock. The widget draws what this
/// says and decides nothing. No em-dashes (product rule).
public struct BaseActivityPresentation: Equatable, Sendable {
    public typealias State = BaseActivityAttributes.ContentState

    /// The box keeps the bubble fresh (a heartbeat about every 10 minutes, stale date 20 minutes ahead). Past that
    /// the bubble says so instead of looking current.
    public static let staleAfter: TimeInterval = 20 * 60

    public let state: State

    public init(_ state: State) { self.state = state }

    public var isCall: Bool { state.mode == .call && state.call != nil }

    // MARK: the idle line

    /// The header: the app's name ("Hermes Bot") on the always-on line, the bot's own name during a call.
    public var title: String { isCall ? (state.call?.botName ?? ActivityBrand.name) : ActivityBrand.name }

    /// "2 of 2 machines online", "1 machine online", "No machine online". Nil when the app does not know any machine yet.
    public var machinesLine: String? {
        guard state.machinesTotal > 0 else { return nil }
        if state.machinesOnline == 0 { return "No machine online" }
        if state.machinesTotal == 1 { return "1 machine online" }
        return "\(state.machinesOnline) of \(state.machinesTotal) machines online"
    }

    /// "Nothing waiting" or "1 request waiting" / "3 requests waiting".
    public var waitingLine: String {
        switch state.waiting {
        case 0: "Nothing waiting"
        case 1: "1 request waiting"
        default: "\(state.waiting) requests waiting"
        }
    }

    /// The one line of the bubble: machines, waiting, then the last event with its age when there is one.
    public func idleLine(now: Date) -> String {
        var parts: [String] = []
        if let machines = machinesLine { parts.append(machines) }
        parts.append(waitingLine)
        if let event = lastEventLine(now: now) { parts.append(event) }
        return parts.joined(separator: ". ")
    }

    public func lastEventLine(now: Date) -> String? {
        guard let text = state.lastEvent, !text.isEmpty else { return nil }
        guard let at = state.lastEventAt else { return text }
        return "\(text), \(Self.age(seconds: now.timeIntervalSince1970 - Double(at)))"
    }

    // MARK: honesty about age

    public func isStale(now: Date) -> Bool { now.timeIntervalSince1970 - Double(state.updatedAt) > Self.staleAfter }

    /// "Updated just now", "Updated 4 min ago". Counts from the state's own time, never from when it was drawn.
    public func updatedLine(now: Date) -> String {
        let seconds = now.timeIntervalSince1970 - Double(state.updatedAt)
        return seconds < 60 ? "Updated just now" : "Updated \(Self.age(seconds: seconds))"
    }

    /// The line when the bubble is stale: it does not pretend to be current.
    public func staleLine(now: Date) -> String { "Not updating. \(updatedLine(now: now))" }

    /// "just now", "4 min ago", "2 h ago", "3 d ago".
    public static func age(seconds: Double) -> String {
        let clamped = max(0, seconds)
        switch clamped {
        case ..<60: return "just now"
        case ..<3600: return "\(Int(clamped / 60)) min ago"
        case ..<86_400: return "\(Int(clamped / 3600)) h ago"
        default: return "\(Int(clamped / 86_400)) d ago"
        }
    }

    // MARK: the call morph

    /// "Listening", "Muted"... or "Listening (on Gokhan's Mac)" when another device talks.
    public var callSubtitle: String {
        guard let call = state.call else { return "" }
        if call.ownerHere { return call.isMuted == true ? "Muted" : call.stateLine }
        if let owner = call.ownerName, !owner.isEmpty { return "\(call.stateLine) (on \(owner))" }
        return call.stateLine
    }

    public var showsMute: Bool { state.call?.ownerHere == true }
    /// The AirPlay circle sits next to Mute, on the phone that talks.
    public var showsOutput: Bool { showsMute }
    public var outputOn: Bool { state.call?.outputOn == true }
    public var canChooseOutput: Bool { state.call?.canChooseOutput == true }
    public static let outputSymbol = "airplayaudio"
    public var outputAccessibilityLabel: String {
        canChooseOutput ? (outputOn ? "Switch the sound to the phone receiver" : "Switch the sound to the speaker") : "Choose where the sound plays, in the app"
    }
    public var muteTitle: String { state.call?.isMuted == true ? "Unmute" : "Mute" }
    public var muteAccessibilityLabel: String { state.call?.isMuted == true ? "Unmute the microphone" : "Mute the microphone" }
    public static let endTitle = "End"
    public static let endAccessibilityLabel = "End the call"

    /// The elapsed time of the call counts by itself from this date.
    public var callStart: Date? { state.call.map { Date(timeIntervalSince1970: Double($0.startedAt)) } }

    // MARK: what runs right now (S25)

    /// The most rows the bubble draws, whatever a state carries: compact and calm (owner decision 2026-10-12).
    public static let runningLimit = 2

    /// One drawn row: `<bot>  <elapsed, counting by itself>  <what it does>`.
    public struct RunningRow: Equatable, Sendable, Identifiable {
        public let id: String
        public let botKey: String
        public let botName: String
        public let isTasks: Bool
        public let line: String
        /// The elapsed time counts natively from here (`Text(timerInterval:)`): no push is needed for the clock.
        public let start: Date

        /// "hermesbot, working for 4 minutes: Using terminal".
        public func accessibilityLabel(now: Date) -> String {
            "\(botName), working for \(BaseActivityPresentation.spokenDuration(seconds: Int(now.timeIntervalSince(start)))): \(line)"
        }
    }

    /// The rows to draw, in the order the writer chose (longest running first), never more than `runningLimit`.
    public var runningRows: [RunningRow] {
        guard !isCall else { return [] }
        return (state.running ?? []).prefix(Self.runningLimit).enumerated().map { index, row in
            RunningRow(
                id: "\(index)|\(row.botKey)|\(row.kind)", botKey: row.botKey, botName: row.botName.isEmpty ? "Hermes" : row.botName,
                isTasks: row.kind == "tasks", line: row.line, start: Date(timeIntervalSince1970: Double(row.startedAt)))
        }
    }

    /// The bubble is in its working shape: at least one session runs (and no call).
    public var isWorking: Bool { !runningRows.isEmpty }

    /// "+2 more": what the state counts beyond the rows, plus any rows it sent beyond the limit. Nil for none.
    public var runningMoreLine: String? {
        let more = (state.runningMore ?? 0) + max(0, (state.running?.count ?? 0) - Self.runningLimit)
        return more > 0 && isWorking ? "+\(more) more" : nil
    }

    /// While sessions work, requests are only a hint ("1 request waiting"): the cards live in the separate
    /// approvals bubble (S22). Nil when nothing waits.
    public var waitingHint: String? { state.waiting > 0 ? waitingLine : nil }

    /// "less than a minute", "4 minutes", "1 hour 5 minutes".
    public static func spokenDuration(seconds: Int) -> String {
        let minutes = max(0, seconds) / 60
        if minutes == 0 { return "less than a minute" }
        let hours = minutes / 60
        let rest = minutes % 60
        let minuteWords = "\(rest) \(rest == 1 ? "minute" : "minutes")"
        guard hours > 0 else { return minuteWords }
        let hourWords = "\(hours) \(hours == 1 ? "hour" : "hours")"
        return rest == 0 ? hourWords : "\(hourWords) \(minuteWords)"
    }

    // MARK: accessibility

    public func accessibilityLabel(now: Date) -> String {
        if isCall, let call = state.call {
            let elapsed = max(0, Int(now.timeIntervalSince1970 - Double(call.startedAt)))
            return "Call with \(call.botName). \(callSubtitle). \(RequestActivityPresentation.spoken(seconds: elapsed)) so far"
        }
        if isWorking, !isStale(now: now) {
            let parts = runningRows.map { $0.accessibilityLabel(now: now) } + [runningMoreLine, waitingHint].compactMap { $0 }
            return "\(ActivityBrand.name). \(parts.joined(separator: ". ")). \(updatedLine(now: now))"
        }
        let line = isStale(now: now) ? staleLine(now: now) : "\(idleLine(now: now)). \(updatedLine(now: now))"
        return "\(ActivityBrand.name). \(line)"
    }
}
