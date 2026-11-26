import Foundation
import Testing

@testable import HermesBox

@Suite("Call audio maths: resampler, end of speech, barge-in, jitter buffer")
struct CallAudioMathTests {
    // MARK: resampler

    @Test func sameRateIsIdentity() {
        var resampler = PCMResampler(inputRate: 16_000, outputRate: 16_000)
        let out = resampler.process([0, 0.5, -0.5, 1])
        #expect(out == [0, PCM16.sample(from: 0.5), PCM16.sample(from: -0.5), 32767])
    }

    @Test func downsamplingFrom48kGivesOneThirdOfTheSamples() {
        var resampler = PCMResampler(inputRate: 48_000, outputRate: 16_000)
        let out = resampler.process([Float](repeating: 0.25, count: 4800))
        #expect(out.count == 1600)
        #expect(out.allSatisfy { abs(Int($0) - Int(PCM16.sample(from: 0.25))) <= 1 })
    }

    @Test func fromCdRateTheCountIsRightAcrossBuffers() {
        var resampler = PCMResampler(inputRate: 44_100, outputRate: 16_000)
        var total = 0
        for _ in 0..<100 { total += resampler.process([Float](repeating: 0.1, count: 441)).count }
        // 44,100 samples in is one second out, give or take the sample held back.
        #expect(abs(total - 16_000) <= 1)
    }

    @Test func splitInputGivesTheSameSamplesAsOneBuffer() {
        let input = (0..<4410).map { Float(sin(Double($0) / 20)) }
        var whole = PCMResampler(inputRate: 44_100, outputRate: 16_000)
        var split = PCMResampler(inputRate: 44_100, outputRate: 16_000)
        let all = whole.process(input)
        let parts = split.process(Array(input[0..<1000])) + split.process(Array(input[1000..<3333])) + split.process(Array(input[3333...]))
        #expect(all == parts)
    }

    @Test func pcmBytesAreLittleEndianAndRoundTrip() {
        let data = PCM16.data(from: [1, -2, 0x0102])
        #expect([UInt8](data) == [1, 0, 0xFE, 0xFF, 0x02, 0x01])
        #expect(PCM16.samples(from: data) == [1, -2, 0x0102])
    }

    @Test func levelOfSilenceAndFullScale() {
        #expect(PCM16.levelDb(silence(ms: 20)[...]) == -120)
        #expect(abs(PCM16.levelDb(sine(ms: 20, amplitude: 32767)[...]) - -3.0) < 0.6)
    }

    // MARK: end of speech

    private func run(_ gate: inout UtteranceGate, _ samples: [Int16], speaking: Bool = false) -> [UtteranceGate.Output] {
        gate.process(samples, assistantSpeaking: speaking)
    }

    @Test func aQuietGainControlledVoiceOpensAnUtteranceAndIsEnded() {
        // About -49 dBFS RMS: what a voice-processing mic can give for conversation held at arm's length. The old floor
        // (-45) never opened on it: nothing was sent, no end of speech, the call looked connected and heard nothing.
        var gate = UtteranceGate()
        var outputs = run(&gate, silence(ms: 300))
        outputs += run(&gate, sine(ms: 600, amplitude: 160))
        outputs += run(&gate, silence(ms: 1200))
        #expect(outputs.contains(.speechStarted))
        #expect(outputs.last == .endOfSpeech)
        #expect(gate.lastLevelDb == -120)
    }

    @Test func theGateReportsTheLevelAndTheThresholdInDbfs() {
        var gate = UtteranceGate()
        _ = run(&gate, sine(ms: 20, amplitude: 3277))  // 10 percent of full scale peak: about -23 dBFS RMS
        #expect(abs(gate.lastLevelDb - -23.0) < 1.0)
        #expect(gate.thresholdDb <= -52 && gate.thresholdDb >= -70)
    }

    @Test func quietEchoNearTheIdleFloorNeverInterruptsTheBot() {
        var gate = UtteranceGate()
        _ = run(&gate, silence(ms: 400))
        let echo = sine(ms: 2000, amplitude: 330)  // about -43 dBFS
        #expect(!run(&gate, echo, speaking: true).contains(.bargeIn))
    }

    // MARK: mic channel mixing

    @Test func theLoudestChannelWinsInsteadOfAveragingTheVoiceAwayAcrossSilentChannels() {
        let voice = (0..<100).map { Float(sin(Double($0) / 5)) * 0.1 }
        let silent = [Float](repeating: 0, count: 100)
        let mixed = MicMixer.loudestChannel([silent, voice, silent, silent, silent])
        #expect(mixed == voice, "an average over five channels would be 14 dB quieter")
        #expect(MicMixer.loudestChannel([]).isEmpty)
    }

    @Test func interleavedAndIntegerMicBuffersAreReadWithoutLosingTheVoice() {
        let interleaved: [Float] = [0.5, 0, -0.5, 0, 0.25, 0]
        #expect(MicMixer.deinterleave(interleaved, stride: 2, channel: 0) == [0.5, -0.5, 0.25])
        #expect(MicMixer.deinterleave(interleaved, stride: 2, channel: 2).isEmpty)
        #expect(MicMixer.floats(fromInt16: [16384, -16384]) == [0.5, -0.5])
        #expect(MicMixer.floats(fromInt32: [1_073_741_824]) == [0.5])
    }

    @Test func roomNoiseNeverOpensAnUtterance() {
        var gate = UtteranceGate()
        let noise = sine(ms: 3000, amplitude: 60, frequency: 90)  // about -60 dBFS
        #expect(run(&gate, noise).isEmpty)
    }

    @Test func speechThenSilenceSendsAudioThenOneEndOfSpeech() {
        var gate = UtteranceGate()
        var outputs = run(&gate, silence(ms: 400))
        outputs += run(&gate, sine(ms: 600, amplitude: 8000))
        outputs += run(&gate, silence(ms: 1200))
        #expect(outputs.first == .speechStarted)
        #expect(outputs.filter { $0 == .endOfSpeech }.count == 1)
        #expect(outputs.last == .endOfSpeech)
        let bytes = outputs.reduce(0) { total, output in
            if case .audio(let data) = output { return total + data.count }
            return total
        }
        // preroll (300 ms) + speech (600 ms) + the hangover (900 ms), all at 32 bytes per millisecond
        #expect(bytes >= (300 + 600 + 880) * 32 && bytes <= (300 + 600 + 940) * 32)
    }

    @Test func aPauseShorterThanTheHangoverDoesNotEndTheSentence() {
        var gate = UtteranceGate()
        var outputs = run(&gate, sine(ms: 500, amplitude: 8000))
        outputs += run(&gate, silence(ms: 600))
        outputs += run(&gate, sine(ms: 500, amplitude: 8000))
        #expect(!outputs.contains(.endOfSpeech))
        #expect(gate.isSpeaking)
    }

    @Test func aShortClickIsNotSpeech() {
        var gate = UtteranceGate()
        #expect(run(&gate, sine(ms: 60, amplitude: 20000) + silence(ms: 500)).isEmpty)
    }

    @Test func theUtteranceIsCutBeforeTheHubsSixtySeconds() {
        var gate = UtteranceGate()
        let outputs = run(&gate, sine(ms: 58_000, amplitude: 8000))
        #expect(outputs.contains(.endOfSpeech))
    }

    @Test func muteEndsAnUtteranceInFlightOnce() {
        var gate = UtteranceGate()
        _ = run(&gate, sine(ms: 400, amplitude: 8000))
        #expect(gate.finishUtterance() == [.endOfSpeech])
        #expect(gate.finishUtterance().isEmpty)
    }

    // MARK: barge-in

    @Test func quietEchoWhileTheBotSpeaksDoesNotInterrupt() {
        var gate = UtteranceGate()
        _ = run(&gate, silence(ms: 400))
        let echo = sine(ms: 2000, amplitude: 500)  // about -39 dBFS: speech when idle, echo while the bot speaks
        #expect(!run(&gate, echo, speaking: true).contains(.bargeIn))
    }

    @Test func aBriefBlipWhileTheBotSpeaksDoesNotInterrupt() {
        var gate = UtteranceGate()
        #expect(run(&gate, sine(ms: 160, amplitude: 9000) + silence(ms: 400), speaking: true).isEmpty)
    }

    @Test func aRealVoiceOverTheBotSendsBargeInBeforeAnyAudio() {
        var gate = UtteranceGate()
        _ = run(&gate, silence(ms: 300), speaking: true)
        let outputs = run(&gate, sine(ms: 1200, amplitude: 9000), speaking: true)  // the stop gate is 1 s of sustained voice
        #expect(outputs.first == .bargeIn)
        #expect(outputs[1] == .speechStarted)
        #expect(outputs.dropFirst(2).first.map { if case .audio = $0 { true } else { false } } == true)
    }

    @Test func theConstantsLiveInOnePlace() {
        let config = EndOfSpeechConfig()
        #expect(config.hangoverMs == 900 && config.onsetFrames == 6 && config.prerollMs == 300 && config.bargeInSustainMs == 1000)
        #expect(config.maxUtteranceMs < 60_000)
    }

    // MARK: jitter buffer

    @Test func aReplyWaitsForItsPrebufferThenFlows() {
        var jitter = ReplyJitterBuffer(prebufferMs: 250)
        jitter.begin(replyId: 1, sampleRate: 24_000)
        let tenMs = Data(count: 480)  // 240 samples
        var played = 0
        for _ in 0..<24 { played += jitter.push(replyId: 1, pcm: tenMs).count }
        #expect(played == 0, "240 ms is still short of 250")
        let first = jitter.push(replyId: 1, pcm: tenMs)
        #expect(first.count == 1 && first[0].pcm.count == 25 * 480 && first[0].sampleRate == 24_000)
        #expect(jitter.push(replyId: 1, pcm: tenMs).first?.pcm.count == 480)
    }

    @Test func aShortReplyPlaysWhenItEnds() {
        var jitter = ReplyJitterBuffer()
        jitter.begin(replyId: 2, sampleRate: 16_000)
        #expect(jitter.push(replyId: 2, pcm: Data(count: 640)).isEmpty)
        #expect(jitter.end(replyId: 2).first?.pcm.count == 640)
        #expect(jitter.end(replyId: 2).isEmpty)
    }

    @Test func stopForgetsEverythingSoLateChunksNeverPlay() {
        var jitter = ReplyJitterBuffer(prebufferMs: 10)
        jitter.begin(replyId: 3, sampleRate: 16_000)
        _ = jitter.push(replyId: 3, pcm: Data(count: 640))
        jitter.stop()
        #expect(jitter.push(replyId: 3, pcm: Data(count: 640)).isEmpty)
        #expect(jitter.push(replyId: 99, pcm: Data(count: 640)).isEmpty, "a reply nobody announced")
        #expect(jitter.isEmpty)
    }
}
