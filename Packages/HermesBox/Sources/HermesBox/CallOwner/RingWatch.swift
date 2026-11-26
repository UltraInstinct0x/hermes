import Foundation

/// Follows one ring on the call hub while it rings here (S27 R11): a ring that is gone, answered on another device or
/// ended by the box stops ringing on this phone at once, and a decline is sent through it (`ring.decline`). Its own
/// socket to the hub, closed as soon as the ring is answered, declined or over: answering opens the call's own link.
@MainActor
final class RingWatch {
    private let link: any CallLink
    private let callId: String
    private let time: any TimeSource
    private let onVerdict: @MainActor (RingEndedReason) -> Void
    private var reader: Task<Void, Never>?
    private var isUp = false
    private var declining = false
    private var declineSent = false
    private var closed = false

    init(link: any CallLink, callId: String, time: any TimeSource, onVerdict: @escaping @MainActor (RingEndedReason) -> Void) {
        self.link = link
        self.callId = callId
        self.time = time
        self.onVerdict = onVerdict
    }

    /// The socket is closed (the ring ended, or the box could not be reached): a decline needs a new watch.
    var isClosed: Bool { closed }

    func start() {
        let link = self.link
        reader = Task { [weak self] in
            await link.open()
            for await event in link.events {
                guard let self, !Task.isCancelled else { return }
                self.handle(event)
            }
        }
    }

    /// The owner declined: tell the hub, then close (after its answer, or after `wait` at the latest). `done` runs once
    /// the socket is closed, so the app can give back the background time it asked for.
    func decline(wait: Duration = .seconds(5), done: @escaping @MainActor () -> Void = {}) {
        declining = true
        sendDeclineIfUp()
        Task { [weak self, time] in
            try? await time.sleep(for: wait)
            self?.stop()
            done()
        }
    }

    func stop() {
        guard !closed else { return }
        closed = true
        reader?.cancel()
        reader = nil
        let link = self.link
        Task { await link.close() }
    }

    private func handle(_ event: CallLinkEvent) {
        switch event {
        case .up(let hello):
            isUp = true
            if declining {
                sendDeclineIfUp()
                return
            }
            report(RingWatchVerdict.verdict(for: hello.calls.first { $0.callId == callId }))
        case .down:
            isUp = false
        case .inbound(.state(let call, _)) where call.callId == callId:
            guard !declining else { return }
            report(RingWatchVerdict.verdict(for: call))
        case .inbound(.ended(let id, let reason)) where id == callId:
            guard !declining else { return }
            report(RingWatchVerdict.endedReason(reason))
        case .inbound(.other(type: "ring.declined")), .inbound(.error(_, _, _, _)):
            // The hub answered the decline (or refused it: the ring was gone already). Either way the work is done.
            if declining { stop() }
        case .failed:
            // No box right now: the ring keeps ringing until its expiry, which ends it here anyway.
            stop()
        case .inbound, .audio:
            break
        }
    }

    private func report(_ verdict: RingEndedReason?) {
        guard let verdict, !closed else { return }
        onVerdict(verdict)
        stop()
    }

    private func sendDeclineIfUp() {
        guard declining, isUp, !declineSent else { return }
        declineSent = true
        let link = self.link
        let message = CallOutbound.ringDecline(id: "decline", callId: callId)
        Task { await link.send(message) }
    }
}
