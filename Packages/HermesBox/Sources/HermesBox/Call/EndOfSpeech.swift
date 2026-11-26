import Foundation

/// Every constant of the phone's end-of-speech and barge-in detection, in ONE place (tested in `EndOfSpeechTests`).
/// Conservative on purpose: a late end of speech costs a moment, an early one cuts the person off.
public struct EndOfSpeechConfig: Sendable, Equatable {
    /// 20 ms at 16 kHz.
    public var frameSamples = 320
    /// Nothing quieter than this counts as speech: the floor of the threshold.
    public var minSpeechDb = -52.0
    /// Speech is this far above the measured room noise.
    public var marginDb = 12.0
    public var initialNoiseDb = -70.0
    /// How fast the noise estimate follows the room (per quiet frame).
    public var noiseRise = 0.02
    public var noiseFall = 0.2
    /// Speech frames in a row that open an utterance (120 ms).
    public var onsetFrames = 6
    /// Silence that closes it. Long on purpose: people pause inside a sentence.
    public var hangoverMs = 900
    /// Audio from before the onset that is sent too, so the first word is whole.
    public var prerollMs = 300
    /// Under the hub's own 60 s cut.
    public var maxUtteranceMs = 55_000
    /// While the bot speaks the threshold is higher (echo that survived cancellation must not interrupt it) ...
    public var bargeInExtraDb = 8.0
    /// ... and the voice must last this long.
    public var bargeInSustainMs = 1000
    /// Floor of the barge-in threshold (the old idle floor plus the extra): quiet echo never interrupts, whatever the room noise.
    public var bargeInMinDb = -37.0

    public init() {}

    var frameMs: Int { frameSamples * 1000 / 16_000 }
}

/// Turns the microphone's 16 kHz PCM into what the hub wants: only utterances, each ended by an explicit end of
/// speech (`audio.eos`, S19 R13), and a barge-in when the person talks over the bot. Pure.
public struct UtteranceGate: Sendable {
    public enum Output: Sendable, Equatable {
        /// The person began to talk over the bot: send `audio.barge_in` BEFORE the audio that follows.
        case bargeIn
        case speechStarted
        /// PCM16 bytes to send up.
        case audio(Data)
        case endOfSpeech
    }

    private enum Mode { case idle, speaking }

    public let config: EndOfSpeechConfig
    private var mode = Mode.idle
    private var pendingSamples: [Int16] = []
    private var ring: [[Int16]] = []
    private var speechRun = 0
    private var silenceFrames = 0
    private var utteranceFrames = 0
    private var noiseDb: Double
    /// Level of the last frame, and the level that opens an utterance now (for Details).
    public private(set) var lastLevelDb = -120.0
    public var thresholdDb: Double { max(config.minSpeechDb, noiseDb + config.marginDb) }

    public init(config: EndOfSpeechConfig = EndOfSpeechConfig()) {
        self.config = config
        noiseDb = config.initialNoiseDb
    }

    public var isSpeaking: Bool { mode == .speaking }

    /// Voice frames in a row while no utterance is open. Reaching `onsetFrames` is the FIRST sign of a barge-in
    /// (the bot ducks); the stop gate (`bargeInSustainMs`) comes later.
    public var voiceRun: Int { mode == .idle ? speechRun : 0 }

    /// Feed mic samples. `assistantSpeaking` is true while speech is playing on this phone.
    public mutating func process(_ samples: [Int16], assistantSpeaking: Bool) -> [Output] {
        pendingSamples += samples
        var out: [Output] = []
        while pendingSamples.count >= config.frameSamples {
            let frame = Array(pendingSamples.prefix(config.frameSamples))
            pendingSamples.removeFirst(config.frameSamples)
            step(frame, assistantSpeaking: assistantSpeaking, into: &out)
        }
        return out
    }

    /// Mute or stop: an utterance in flight is ended now, so the hub is not left waiting for it.
    public mutating func finishUtterance() -> [Output] {
        let wasSpeaking = mode == .speaking
        reset()
        return wasSpeaking ? [.endOfSpeech] : []
    }

    public mutating func reset() {
        mode = .idle
        pendingSamples = []
        ring = []
        speechRun = 0
        silenceFrames = 0
        utteranceFrames = 0
    }

    private var prerollFrames: Int { config.prerollMs / config.frameMs }

    private mutating func step(_ frame: [Int16], assistantSpeaking: Bool, into out: inout [Output]) {
        let level = PCM16.levelDb(frame[...])
        lastLevelDb = level
        let base = max(config.minSpeechDb, noiseDb + config.marginDb)
        switch mode {
        case .idle:
            let threshold = assistantSpeaking ? max(base + config.bargeInExtraDb, config.bargeInMinDb) : base
            if level > threshold {
                speechRun += 1
            } else {
                speechRun = 0
                if !assistantSpeaking { followNoise(level) }
            }
            let needed = assistantSpeaking ? max(config.onsetFrames, config.bargeInSustainMs / config.frameMs) : config.onsetFrames
            ring.append(frame)
            let keep = needed + prerollFrames
            if ring.count > keep { ring.removeFirst(ring.count - keep) }
            guard speechRun >= needed else { return }
            if assistantSpeaking { out.append(.bargeIn) }
            out.append(.speechStarted)
            let lead = ring.suffix(min(ring.count, speechRun + prerollFrames))
            for chunk in lead { out.append(.audio(PCM16.data(from: chunk))) }
            utteranceFrames = lead.count
            ring = []
            speechRun = 0
            silenceFrames = 0
            mode = .speaking
        case .speaking:
            out.append(.audio(PCM16.data(from: frame)))
            utteranceFrames += 1
            silenceFrames = level > base ? 0 : silenceFrames + 1
            if silenceFrames * config.frameMs >= config.hangoverMs || utteranceFrames * config.frameMs >= config.maxUtteranceMs {
                out.append(.endOfSpeech)
                reset()
            }
        }
    }

    /// The noise estimate falls fast and rises slowly, so a pause in a loud room does not become "speech".
    private mutating func followNoise(_ level: Double) {
        let rate = level < noiseDb ? config.noiseFall : config.noiseRise
        noiseDb += (max(level, -90) - noiseDb) * rate
    }
}
