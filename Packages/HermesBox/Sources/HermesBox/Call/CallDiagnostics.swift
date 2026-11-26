import Foundation

/// What the phone side of a call has done, as plain numbers: the answer to "did my voice leave the phone?" in one
/// look. Shown behind Details on the call screen and appended to Copy details. No speech text, no secrets.
public struct CallDiagnostics: Sendable, Equatable {
    public var link = "connecting"
    public var role = "none"
    public var hubState = "starting"
    public var epoch: UInt32?
    public var captureFormat = ""
    /// Microphone samples (16 kHz, after resampling) that reached the call, and how many were thrown away because the
    /// phone could not talk (muted, on hold, not the owner, link down).
    public var micSamples = 0
    public var micSamplesIgnored = 0
    public var lastMicDb = -120.0
    public var peakMicDb = -120.0
    public var gateThresholdDb = -52.0
    public var utterancesStarted = 0
    public var framesQueued = 0
    public var framesSent = 0
    public var framesFailed = 0
    public var bytesSent = 0
    public var eosSent = 0
    public var bargeInsSent = 0
    public var lastHubError: String?
    public var hubErrors = 0
    public var partialRows = 0
    public var finalPersonRows = 0
    public var repliesStarted = 0
    /// "on", or "off (fallback)" after the first start delivered no audio.
    public var echoCancellation = "on"
    /// Tap buffer batches that reached the call (before any muting or gating) and the watchdog's verdict.
    public var micBatches = 0
    public var watchdog = "waiting"
    /// Session, route, permission and engine lines from the audio edge.
    public var audioReport: [String] = []

    public init() {}

    /// Folds one batch of mic samples (already 16 kHz) into the level numbers.
    public mutating func noteMic(samples: [Int16], thresholdDb: Double) {
        micSamples += samples.count
        let level = PCM16.levelDb(samples[...])
        lastMicDb = level
        peakMicDb = max(peakMicDb, level)
        gateThresholdDb = thresholdDb
    }

    /// The mic level as a short phrase, so a silent microphone is obvious: "-31 dBFS (peak -18), opens at -52".
    public var micLine: String {
        guard micSamples > 0 else { return "no microphone audio yet" }
        return "\(Int(lastMicDb.rounded())) dBFS (peak \(Int(peakMicDb.rounded()))), opens at \(Int(gateThresholdDb.rounded()))"
    }

    /// The block for Details and Copy details. One fact per line, `key: value`.
    public var text: String {
        [
            "link: \(link)",
            "role: \(role), hub state: \(hubState), epoch: \(epoch.map(String.init) ?? "none")",
            "capture: \(captureFormat.isEmpty ? "unknown" : captureFormat)",
            "mic samples: \(micSamples), ignored: \(micSamplesIgnored)",
            "mic level: \(micLine)",
            "utterances started: \(utterancesStarted)",
            "frames queued: \(framesQueued), sent: \(framesSent), failed: \(framesFailed), bytes sent: \(bytesSent)",
            "end-of-speech sent: \(eosSent), barge-ins sent: \(bargeInsSent)",
            "hub errors: \(hubErrors), last: \(lastHubError ?? "none")",
            "transcript rows: \(partialRows) partial, \(finalPersonRows) final of yours",
            "replies started: \(repliesStarted)",
            "echo cancellation: \(echoCancellation), mic batches: \(micBatches), watchdog: \(watchdog)",
        ].joined(separator: "\n") + (audioReport.isEmpty ? "" : "\n" + audioReport.joined(separator: "\n"))
    }
}

/// The counters that change on the audio sending task, away from the main actor.
public final class UplinkCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var sent = 0
    private var failed = 0
    private var bytes = 0

    public init() {}

    func record(delivered: Bool, bytesInFrame: Int) {
        lock.withLock {
            if delivered {
                sent += 1
                bytes += bytesInFrame
            } else {
                failed += 1
            }
        }
    }

    var snapshot: (sent: Int, failed: Int, bytes: Int) { lock.withLock { (sent, failed, bytes) } }
}
