import Foundation

/// Hermes Neo: the call's caption with the same rule as the app's own Talk call (`TalkSession.caption`,
/// App/Model/TalkSession.swift:205): while the person talks, their words (still changing, lighter); once they are done,
/// their words settled, kept until the bot's reply is HEARD; while the bot speaks, the sentence being played settled
/// and the next one already queued for playback lighter. The bot's words never show before their audio plays: text the
/// hub sent ahead (`tts.start`, one sentence per reply) waits here until the player reaches it. Pure, tested.
public struct CallCaptionTimeline: Sendable, Equatable {
    /// What the hub heard so far of the person's turn (`call.transcript` partial).
    private var heardChanging: String?
    /// The person's last finished turn, shown until a reply that came after it plays.
    private var heardSettled: String?
    /// Replies the hub announced up to the person's last finished turn: the first one after that answers it.
    private var settledAfterReply: UInt32 = 0
    private var latestReply: UInt32 = 0
    /// Each reply's sentence (`tts.start` text), by reply id.
    private var sentences: [UInt32: String] = [:]

    public init() {}

    /// A transcript row of the call.
    public mutating func row(_ row: CallTranscriptRow) {
        guard row.speaker == .person else { return }
        if row.isPartial {
            heardChanging = row.text.isEmpty ? nil : row.text
        } else if !row.text.isEmpty {
            heardChanging = nil
            heardSettled = row.text
            settledAfterReply = latestReply
        }
    }

    /// `tts.start`: a sentence about to be spoken (its audio follows; it shows only once that plays).
    public mutating func replyAnnounced(_ replyId: UInt32, text: String) {
        latestReply = max(latestReply, replyId)
        sentences[replyId] = text
        if sentences.count > 64, let oldest = sentences.keys.min() { sentences[oldest] = nil }
    }

    /// The caption now, given what the player plays: `playing` the reply heard now (then the ones queued after it).
    public func caption(playing queue: [UInt32]) -> (settled: String, lighter: String)? {
        // Talking: the words still change, lighter (TalkSession: `.listening`).
        if let heardChanging { return ("", heardChanging) }
        // Speaking: the sentence being played, then the next one queued (TalkSession: `.speaking`).
        if let playing = queue.first, playing > settledAfterReply || heardSettled == nil, let sentence = sentences[playing] {
            let next = queue.dropFirst().first.flatMap { sentences[$0] }.map { " " + $0 } ?? ""
            return (sentence, next)
        }
        // Done talking, the reply not heard yet: their words stay (TalkSession: `.working`).
        if let heardSettled { return (heardSettled, "") }
        return nil
    }

    /// The person's words on screen (Talk's `heard`).
    public var heard: String { heardChanging ?? heardSettled ?? "" }

    /// A reply that answers the person's last turn has started to play: their words give way (call this as it plays).
    public mutating func replyPlaying(_ replyId: UInt32) {
        if replyId > settledAfterReply { heardSettled = nil }
    }
}
