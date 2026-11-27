import Foundation

/// Speech that arrived while the call's audio engine was not running yet (S28). A CallKit call starts its engine only
/// after the system activated the audio session, which can be a second or more after the bot began to speak; the
/// greeting would be lost. The queue keeps up to `capacityMs` of audio in arrival order, drops the OLDEST beyond that,
/// and hands everything back in order when the engine runs. Pure; counts only, never content.
public struct PendingSpeechQueue: Sendable {
    public enum DropReason: String, Sendable { case overflow, cleared }

    /// What happened to the audio since the last `takeCounters()`: for one log line.
    public struct Counters: Sendable, Equatable {
        public var queued = 0
        public var flushed = 0
        public var droppedOverflow = 0
        public var droppedCleared = 0
        public var isEmpty: Bool { queued == 0 && flushed == 0 && droppedOverflow == 0 && droppedCleared == 0 }
    }

    /// About 15 s of speech: enough for a greeting, not a pile of stale talk.
    public static let defaultCapacityMs = 15_000

    public let capacityMs: Int
    private var chunks: [PlaybackChunk] = []
    private var counters = Counters()

    public init(capacityMs: Int = PendingSpeechQueue.defaultCapacityMs) { self.capacityMs = capacityMs }

    public var isEmpty: Bool { chunks.isEmpty }
    public var chunkCount: Int { chunks.count }
    public var queuedMs: Int { chunks.reduce(0) { $0 + Self.durationMs(of: $1) } }

    /// PCM16 mono length of a chunk in milliseconds.
    static func durationMs(of chunk: PlaybackChunk) -> Int { chunk.pcm.count / 2 * 1000 / max(chunk.sampleRate, 1) }

    public mutating func enqueue(_ chunk: PlaybackChunk) {
        guard !chunk.pcm.isEmpty else { return }
        var chunk = chunk
        // One chunk longer than the whole cap keeps only its last part (whole samples).
        let capacityBytes = capacityMs * max(chunk.sampleRate, 1) / 1000 * 2
        if chunk.pcm.count > capacityBytes {
            chunk.pcm = Data(chunk.pcm.suffix(capacityBytes))
            counters.droppedOverflow += 1
        }
        chunks.append(chunk)
        counters.queued += 1
        while queuedMs > capacityMs, chunks.count > 1 {
            chunks.removeFirst()
            counters.droppedOverflow += 1
        }
    }

    /// Everything queued, in arrival order; the queue is empty afterwards.
    public mutating func drain() -> [PlaybackChunk] {
        let out = chunks
        chunks = []
        counters.flushed += out.count
        return out
    }

    /// The call ended, the role was lost, the link dropped or the person barged in: stale speech must never play.
    public mutating func clear() {
        counters.droppedCleared += chunks.count
        chunks = []
    }

    /// The counters since the last call, then reset.
    public mutating func takeCounters() -> Counters {
        defer { counters = Counters() }
        return counters
    }
}
