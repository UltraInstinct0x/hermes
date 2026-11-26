import Foundation

// The pure rules of a VoIP push (S27 R11). iOS terminates an app that does not report EVERY VoIP push to CallKit, and
// stops delivering them after repeats (S27 4.1). So nothing here decides whether to report: every push is reported, and
// this decides whether the reported call keeps ringing or is ended at once, and why.
//
// The shape (a pure plan per push, then one table for what a failed report means) is adapted from
// `HermesNativeCallPlan` and the report error handling in kaishi00/hermes-conduit (MIT, Copyright (c) 2026 kaishi00),
// `Conduit/Voice/HermesNativeCalls.swift`. See NOTICE.md.

/// Why a call ended, as CallKit's `CXCallEndedReason` names it. The app target maps it 1:1 (CallKit is iPhone only).
public enum RingEndedReason: String, Sendable, Equatable {
    /// Something went wrong (an unreadable push, an answer that could not reach the box).
    case failed
    /// The other side ended it (the ring is gone on the box).
    case remoteEnded
    /// Nobody answered (the ring expired, or it arrived while the owner was busy).
    case unanswered
    case answeredElsewhere
    case declinedElsewhere
}

/// Why a push is ended at once.
public enum RingEndCause: String, Sendable, Equatable {
    /// Not a ring this app can read (still reported as "Hermes Bot").
    case unreadable
    /// The push came after the ring's `expires_at`.
    case late
    /// The owner is already in a call on this phone.
    case busy
    /// A second push for a ring that already ended here.
    case duplicate
    /// "Calls from your bots" is off on this phone, or the phone is not paired.
    case callsOff

    public var endedReason: RingEndedReason {
        switch self {
        case .unreadable, .callsOff: .failed
        case .late, .busy: .unanswered
        case .duplicate: .remoteEnded
        }
    }
}

/// What the phone knows when a push arrives.
public struct RingContext: Sendable, Equatable {
    public var now: Date
    /// The owner's "Calls from your bots" switch, and whether the phone is paired.
    public var callsEnabled: Bool
    /// A voice call already runs on this phone (an in-app call, or an answered ring).
    public var inCall: Bool
    /// Rings reported here that still ring or run.
    public var liveCallIds: Set<String>
    /// Rings that ended here recently (declined, answered and over, expired).
    public var finishedCallIds: Set<String>

    public init(now: Date, callsEnabled: Bool, inCall: Bool = false, liveCallIds: Set<String> = [], finishedCallIds: Set<String> = []) {
        self.now = now
        self.callsEnabled = callsEnabled
        self.inCall = inCall
        self.liveCallIds = liveCallIds
        self.finishedCallIds = finishedCallIds
    }
}

/// The plan for one push, decided before it is reported.
public enum RingDecision: Sendable, Equatable {
    /// Report it and let it ring.
    case ring
    /// The same ring is ringing here already: report it again under the same UUID (CallKit answers "already exists"
    /// and the ringing call is untouched).
    case alreadyRinging
    /// Report it, then end it at once.
    case endAtOnce(RingEndCause)

    public static func decide(_ push: RingPush?, context: RingContext) -> RingDecision {
        guard let push else { return .endAtOnce(.unreadable) }
        if context.liveCallIds.contains(push.callId) { return .alreadyRinging }
        if context.finishedCallIds.contains(push.callId) { return .endAtOnce(.duplicate) }
        guard context.callsEnabled else { return .endAtOnce(.callsOff) }
        guard context.now < push.expiresAt else { return .endAtOnce(.late) }
        if context.inCall { return .endAtOnce(.busy) }
        return .ring
    }

    /// The UUID to report. A ring uses its stable call UUID; a push that is ended at once without being the live ring
    /// (unreadable, or a late copy of a ring that already ended here) gets a fresh one, so it can never touch a real call.
    public func reportUUID(for push: RingPush?, fresh: () -> UUID = { UUID() }) -> UUID {
        switch self {
        case .ring, .alreadyRinging:
            return push.map { RingCallID.uuid(for: $0.callId) } ?? fresh()
        case .endAtOnce(.unreadable), .endAtOnce(.duplicate):
            return fresh()
        case .endAtOnce:
            return push.map { RingCallID.uuid(for: $0.callId) } ?? fresh()
        }
    }
}

/// `CXErrorCodeIncomingCallError`, as the report callback hands it over.
public enum RingReportError: Sendable, Equatable {
    case unknown
    case unentitled
    case callUUIDAlreadyExists
    case filteredByDoNotDisturb
    case filteredByBlockList
}

/// What follows the report callback.
public enum RingAfterReport: Sendable, Equatable {
    /// It rings: watch the ring on the box and end it at its expiry.
    case ringing
    /// End the reported call now, with this reason.
    case endNow(RingEndedReason)
    /// CallKit did not show it, and the owner should hear that a bot tried (a local notification).
    case notShownTellOwner
    /// CallKit did not show it on purpose (Do Not Disturb, a blocked caller) or already has it: nothing to do.
    case nothing

    public static func after(_ error: RingReportError?, decision: RingDecision) -> RingAfterReport {
        switch (error, decision) {
        case (nil, .ring): return .ringing
        case (nil, .alreadyRinging): return .nothing
        case (nil, .endAtOnce(let cause)): return .endNow(cause.endedReason)
        // CallKit already shows this very call (the app restarted while it rang): keep following it.
        case (.callUUIDAlreadyExists?, .ring): return .ringing
        // The owner asked for quiet, or this very call is already on screen.
        case (.callUUIDAlreadyExists?, _), (.filteredByDoNotDisturb?, _), (.filteredByBlockList?, _): return .nothing
        // A ring that should have rung did not: say so once, calmly. A push that was ending anyway needs no word.
        case (.unknown?, .ring), (.unentitled?, .ring): return .notShownTellOwner
        case (.unknown?, _), (.unentitled?, _): return .nothing
        }
    }
}

/// The result of answering a ring on the call controller.
public enum RingAnswerOutcome: Sendable, Equatable {
    /// This phone owns the call: the bot speaks its opener.
    case answered
    /// The join or take did not work (no Tailscale, the ring is gone, timed out). The call is over here.
    case failed(detail: String)
    /// Another call already runs on this phone.
    case busy
}

/// What the hub says about a ring this phone watches while it rings (`hello.ok.calls`, `call.state`, `call.ended`).
public enum RingWatchVerdict {
    /// Nil while the ring still waits for an answer.
    public static func verdict(for call: CallSummary?) -> RingEndedReason? {
        guard let call else { return .remoteEnded }
        if call.state.isFinal { return endedReason(call.endedReason ?? "") }
        if call.ownerClientId != nil { return .answeredElsewhere }
        return nil
    }

    public static func endedReason(_ hubReason: String) -> RingEndedReason {
        switch hubReason {
        case "no_answer": .unanswered
        case "declined": .declinedElsewhere
        default: .remoteEnded
        }
    }
}
