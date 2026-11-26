import Foundation

/// A run of PCM16 ready for the player.
public struct PlaybackChunk: Sendable, Equatable {
    public var replyId: UInt32
    public var sampleRate: Int
    public var pcm: Data
}

/// Holds the first moments of each spoken reply until there is enough to play without gaps, then lets chunks
/// through as they come. A chunk of a reply the hub never announced (or one that was stopped or ended) is
/// dropped, so late audio after a barge-in or a takeover can never play. Pure.
public struct ReplyJitterBuffer: Sendable {
    private struct Reply {
        var sampleRate: Int
        var held = Data()
        var started = false
    }

    /// How much audio waits before a reply starts to play.
    public let prebufferMs: Int
    private var replies: [UInt32: Reply] = [:]

    public init(prebufferMs: Int = 250) { self.prebufferMs = prebufferMs }

    public var isEmpty: Bool { replies.isEmpty }

    public mutating func begin(replyId: UInt32, sampleRate: Int) {
        replies[replyId] = Reply(sampleRate: sampleRate)
    }

    public mutating func push(replyId: UInt32, pcm: Data) -> [PlaybackChunk] {
        guard var reply = replies[replyId], !pcm.isEmpty else { return [] }
        defer { replies[replyId] = reply }
        if reply.started { return [PlaybackChunk(replyId: replyId, sampleRate: reply.sampleRate, pcm: pcm)] }
        reply.held.append(pcm)
        let heldMs = reply.held.count / 2 * 1000 / max(reply.sampleRate, 1)
        guard heldMs >= prebufferMs else { return [] }
        reply.started = true
        let chunk = PlaybackChunk(replyId: replyId, sampleRate: reply.sampleRate, pcm: reply.held)
        reply.held = Data()
        return [chunk]
    }

    /// The hub finished (or failed) the reply: whatever is held plays now, and the reply is closed.
    public mutating func end(replyId: UInt32) -> [PlaybackChunk] {
        guard let reply = replies.removeValue(forKey: replyId), !reply.held.isEmpty else { return [] }
        return [PlaybackChunk(replyId: replyId, sampleRate: reply.sampleRate, pcm: reply.held)]
    }

    /// Barge-in, takeover, end of call: forget everything.
    public mutating func stop() { replies = [:] }
}
