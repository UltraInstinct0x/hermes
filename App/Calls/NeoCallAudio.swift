#if os(iOS)
@preconcurrency import AVFAudio
import Foundation
import HermesBox
import HermesKit
import os

/// Hermes Neo: the audio of a call from a Bot, through the app's one `AudioCoordinator`.
///
/// Hermes Bot gave its call an engine and an audio-session arbiter of its own. Here the coordinator
/// owns the session and the engine (`docs/voice.md` §7), so the ported `CallController` is handed
/// this object for both of its ports:
/// - `AudioSessionDriver`: `configure(.call)` (a CallKit call) takes the `.call` role with the
///   session pending, so only its category is set; `activate(.call)` takes it as an ordinary role.
/// - `CallAudioIO`: the microphone is a consumer of the graph's one tap, the Bot's speech a player
///   in the same engine (so echo cancellation hears it). `start` waits for the role, and for a
///   CallKit call marks the session live first (`didActivate` came before the controller starts the
///   audio), which is when voice processing goes on.
///
/// Nothing here calls `setCategory`, `setActive` or `overrideOutputAudioPort`: the speaker or the
/// receiver is a role option the coordinator applies.
@MainActor
final class NeoCallAudio: AudioSessionDriver, CallAudioIO {
    var onDrained: (@MainActor () -> Void)?
    var onFailure: (@MainActor (String) -> Void)?
    var onPlaybackLevel: (@Sendable (Double) -> Void)?

    private let coordinator: AudioCoordinator
    nonisolated private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "HermesNeo", category: "call-audio")

    /// The role being taken, then held.
    private var acquiring: Task<AudioLease, any Error>?
    private var lease: AudioLease?
    private var options = AudioRoleOptions(prefersSpeaker: false)
    private var leaseEvents: Task<Void, Never>?
    private var sessionEvents: AsyncStream<AudioSessionEvent>.Continuation?

    /// A start waits for the role; a stop or a newer start makes it give up.
    private var generation = 0
    private var starting: Task<Void, Never>?
    private var running = false
    private var consumer: UUID?
    private var converter: CallTapConverter?
    private var player: AudioPlayerChain?
    private var playerRate: Double = 0
    /// Buffers scheduled and not yet played; a new `playGeneration` makes cancelled completions harmless.
    private var pending = 0
    private var playGeneration = 0
    private var level: Float = 1
    private var rampTask: Task<Void, Never>?
    private var lastError: String?

    init(coordinator: AudioCoordinator = .shared) {
        self.coordinator = coordinator
    }

    // MARK: AudioSessionDriver

    func activate(_ purpose: AudioPurpose) throws {
        take(AudioRoleOptions(prefersSpeaker: options.prefersSpeaker))
    }

    /// A CallKit call: the role is taken with the session pending; CallKit activates it.
    func configure(_ purpose: AudioPurpose) throws {
        take(AudioRoleOptions(prefersSpeaker: options.prefersSpeaker, systemActivation: .pending))
    }

    func deactivate() throws {
        stop()
        let acquiring = acquiring
        let lease = lease
        self.acquiring = nil
        self.lease = nil
        leaseEvents?.cancel()
        leaseEvents = nil
        options.systemActivation = nil
        Task { [coordinator] in
            if let lease {
                await coordinator.release(lease)
            } else if let taken = try? await acquiring?.value {
                await coordinator.release(taken)
            }
        }
    }

    func events() -> AsyncStream<AudioSessionEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: AudioSessionEvent.self)
        sessionEvents = continuation
        return stream
    }

    private func take(_ wanted: AudioRoleOptions) {
        guard lease == nil, acquiring == nil else { return }
        options = wanted
        let coordinator = coordinator
        let task = Task { try await coordinator.acquire(.call, owner: "call", options: wanted) }
        acquiring = task
        Task { [weak self] in
            do {
                let lease = try await task.value
                guard let self, self.acquiring == task else {
                    await coordinator.release(lease)
                    return
                }
                self.lease = lease
                self.follow(lease)
            } catch {
                guard let self, self.acquiring == task else { return }
                self.acquiring = nil
                self.fail("the call could not take the audio: \(error)")
            }
        }
    }

    /// The coordinator's news, in the controller's words.
    private func follow(_ lease: AudioLease) {
        leaseEvents?.cancel()
        leaseEvents = Task { [weak self] in
            for await event in lease.events {
                guard let self else { return }
                switch event {
                case .paused:
                    self.sessionEvents?.yield(.interruptionBegan)
                case .resumed:
                    self.sessionEvents?.yield(.interruptionEnded(shouldResume: true))
                case .routeChanged:
                    self.sessionEvents?.yield(.routeChanged)
                case .engineRestarted:
                    self.engineRestarted()
                case .ended(let reason):
                    self.lease = nil
                    self.acquiring = nil
                    self.fail("the call lost the audio (\(reason))")
                case .inputMuteChanged:
                    break
                }
            }
        }
    }

    /// The role, live: waits for it to be taken, and for a CallKit call marks the session active.
    private func liveLease() async throws -> AudioLease {
        guard let task = acquiring else { throw AudioGraphError.noInput }
        let lease = try await task.value
        if options.systemActivation == .pending {
            options.systemActivation = .active
            try await coordinator.update(lease, options: options)
        }
        return lease
    }

    // MARK: CallAudioIO

    var isPlaying: Bool { pending > 0 }

    func start(onSamples: @escaping @Sendable ([Int16]) -> Void, echoCancellation: Bool) throws {
        stop()
        generation += 1
        let mine = generation
        running = true
        lastError = nil
        // Voice processing is the call role's; the controller's fallback without it can't change
        // the shared engine, so it only restarts the capture.
        if !echoCancellation { Self.logger.info("capture restarted (echo cancellation stays on in the shared engine)") }
        starting = Task { [weak self] in
            do {
                guard let lease = try await self?.liveLease() else { return }
                guard let self, mine == self.generation, self.running else { return }
                try self.attach(to: lease.graph, onSamples: onSamples)
            } catch {
                guard let self, mine == self.generation else { return }
                self.fail("the call audio could not start: \(error)")
            }
        }
    }

    private func attach(to graph: AudioGraph, onSamples: @escaping @Sendable ([Int16]) -> Void) throws {
        let converter = CallTapConverter(emit: onSamples, onFirstBuffer: Self.firstBufferLogger())
        self.converter = converter
        consumer = try graph.addInputConsumer(Self.tapBlock(converter))
        try makePlayer(rate: 24_000, in: graph)
        Self.logger.info("call audio started on the shared engine")
    }

    private func makePlayer(rate: Double, in graph: AudioGraph) throws {
        if let player { graph.removePlayer(player) }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else { return }
        let chain = try graph.makePlayer(format: format)
        chain.volume = level
        player = chain
        playerRate = rate
    }

    func stop() {
        generation += 1
        starting?.cancel()
        starting = nil
        guard running else { return }
        running = false
        stopPlayback()
        if let graph = lease?.graph {
            if let consumer { graph.removeInputConsumer(consumer) }
            if let player { graph.removePlayer(player) }
        }
        consumer = nil
        player = nil
    }

    /// The coordinator restarts the engine on a route or hardware change; a media services reset
    /// drops the players, so the Bot's player is made again.
    func routeChanged() throws {}

    private func engineRestarted() {
        guard running, let graph = lease?.graph else { return }
        if let player, !graph.contains(player) {
            self.player = nil
            pending = 0
            do { try makePlayer(rate: playerRate == 0 ? 24_000 : playerRate, in: graph) } catch {
                fail("the call's player could not come back: \(error)")
            }
        }
    }

    func setOutput(_ choice: CallOutputChoice?) {
        let speaker = choice == .speaker
        guard speaker != options.prefersSpeaker else { return }
        options.prefersSpeaker = speaker
        guard let lease else { return }
        let wanted = options
        Task { [coordinator] in try? await coordinator.update(lease, options: wanted) }
    }

    var currentOutput: CallOutputKind {
        let ports = AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType)
        if ports.contains(.builtInSpeaker) { return .speaker }
        if ports.contains(.builtInReceiver) { return .receiver }
        return ports.isEmpty ? .speaker : .external
    }

    var hasExternalOutput: Bool {
        let outside: Set<AVAudioSession.Port> = [
            .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .airPlay, .headphones, .usbAudio, .carAudio, .HDMI, .lineOut,
        ]
        return AVAudioSession.sharedInstance().currentRoute.outputs.contains { outside.contains($0.portType) }
    }

    var captureDescription: String { converter?.summary ?? "microphone not started" }

    var captureReport: [String] {
        let session = AVAudioSession.sharedInstance()
        let route = session.currentRoute.inputs.first
        return [
            "session (AudioCoordinator, role call): category=\(session.category.rawValue) mode=\(session.mode.rawValue) sampleRate=\(Int(session.sampleRate))",
            "input route: \(route.map { "\($0.portName) (\($0.portType.rawValue))" } ?? "none")",
            "engine: running=\(lease?.graph.isRunning ?? false) system activation: \(options.systemActivation?.rawValue ?? "app")",
            "tap: \(converter?.summary ?? "none")",
            "last audio error: \(lastError ?? "none")",
        ]
    }

    func play(_ chunk: PlaybackChunk) {
        guard running, !chunk.pcm.isEmpty, let graph = lease?.graph else { return }
        let rate = Double(chunk.sampleRate)
        if rate != playerRate || player == nil, pending == 0 {
            do { try makePlayer(rate: rate, in: graph) } catch {
                fail("the call's player could not start: \(error)")
                return
            }
        }
        guard let player, let format = AVAudioFormat(standardFormatWithSampleRate: playerRate, channels: 1) else { return }
        let samples = PCM16.samples(from: chunk.pcm)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
            let target = buffer.floatChannelData?[0]
        else { return }
        var sum = 0.0
        for (index, sample) in samples.enumerated() {
            let value = Float(sample) / 32768
            target[index] = value
            sum += Double(value) * Double(value)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let rms = (sum / Double(max(samples.count, 1))).squareRoot()
        let decibels = rms <= 0.000_001 ? -120 : 20 * log10(rms)
        pending += 1
        player.schedule(buffer, completion: Self.playbackCompletion(self, generation: playGeneration, decibels: decibels, report: onPlaybackLevel))
        if !player.isPlaying {
            do { try player.play() } catch { fail("the call's player could not play: \(error)") }
        }
    }

    func stopPlayback() {
        playGeneration += 1
        pending = 0
        player?.stop()
        onPlaybackLevel?(-120)
    }

    /// The player's own volume (not the system's), in a few small steps so the change doesn't click.
    func setPlaybackLevel(_ target: Float) {
        let goal = min(max(target, 0), 1)
        level = goal
        rampTask?.cancel()
        guard let player else { return }
        let from = player.volume
        guard from != goal else { return }
        let steps = 5
        rampTask = Task { [weak self] in
            for step in 1...steps {
                try? await Task.sleep(for: .milliseconds(6))
                guard !Task.isCancelled, let player = self?.player else { return }
                player.volume = from + (goal - from) * Float(step) / Float(steps)
            }
        }
    }

    private func bufferPlayed(generation played: Int) {
        guard played == playGeneration, pending > 0 else { return }
        pending -= 1
        if pending == 0 {
            onPlaybackLevel?(-120)
            onDrained?()
        }
    }

    private func fail(_ reason: String) {
        lastError = reason
        Self.logger.error("\(reason, privacy: .public)")
        onFailure?(reason)
    }

    // MARK: audio-thread closures, built outside the main actor

    /// The tap runs on an audio thread: a closure written in a main-actor method would carry that
    /// isolation and trap there.
    nonisolated private static func tapBlock(_ converter: CallTapConverter) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { buffer, _ in converter.convert(buffer) }
    }

    nonisolated private static func firstBufferLogger() -> @Sendable (String) -> Void {
        { line in logger.info("\(line, privacy: .public)") }
    }

    /// The player's completion runs on its own queue: hop to the main actor explicitly. The level
    /// of what just played is reported then, so the meter follows the speaker, not the network.
    nonisolated private static func playbackCompletion(
        _ audio: NeoCallAudio, generation: Int, decibels: Double, report: (@Sendable (Double) -> Void)?
    ) -> @Sendable () -> Void {
        { [weak audio] in
            report?(decibels)
            Task { @MainActor in audio?.bufferPlayed(generation: generation) }
        }
    }
}
#endif
