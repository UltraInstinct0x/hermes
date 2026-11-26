#if os(iOS)
import Foundation
import HermesKit
import WatchConnectivity

final class WatchPhoneRelay: NSObject, WCSessionDelegate {
    private weak var model: AppModel?

    func start(model: AppModel) {
        guard WCSession.isSupported() else { return }
        self.model = model
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    nonisolated func session(
        _ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?
    ) {}

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func session(
        _ session: WCSession, didReceiveMessageData messageData: Data, replyHandler: @escaping (Data) -> Void
    ) {
        nonisolated(unsafe) let reply = replyHandler
        Task { @MainActor [weak self] in
            guard let request = try? JSONDecoder().decode(WatchCompanion.Request.self, from: messageData) else {
                reply(Data())
                return
            }
            let response = await self?.respond(to: request) ?? .unavailable
            reply((try? JSONEncoder().encode(response)) ?? Data())
        }
    }

    private func respond(to request: WatchCompanion.Request) async -> WatchCompanion.Response {
        guard let model else { return .unavailable }
        switch request {
        case .roster:
            var bots: [WatchCompanion.Bot] = []
            var hasUnavailableGateway = false
            for gateway in model.bots {
                guard let roster = model.workspaces[gateway.id]?.roster else { continue }
                let isLive = await roster.prepareForWatchRead()
                if !isLive { hasUnavailableGateway = true }
                bots += (roster.visibleBots + roster.hiddenBots).map { profile in
                    WatchCompanion.Bot(
                        id: .init(gateway: gateway.id, profile: profile.name),
                        title: profile.title, gatewayName: gateway.name,
                        state: !isLive ? .offline : roster.isBusy(profile.name) ? .working : .idle
                    )
                }
            }
            return .roster(bots, hasUnavailableGateway: hasUnavailableGateway)
        case .latestReply(let id):
            guard let roster = model.workspaces[id.gateway]?.roster else { return .botNotFound }
            guard await roster.prepareForWatchRead() else { return .unavailable }
            guard roster.bot(named: id.profile) != nil else { return .botNotFound }
            do {
                guard let chatID = try await roster.resolveBotChat(id.profile) else { return .latestReply(nil) }
                await roster.readyForHTTP()
                let deadline = ContinuousClock.now + .seconds(10)
                var offset = 0
                var messages: [SessionMessage] = []
                while ContinuousClock.now < deadline {
                    let page = try await roster.transcript(storedSessionID: chatID, profile: id.profile, offset: offset)
                    if offset > 0, !page.messages.isEmpty, page.messages == Array(messages.prefix(page.messages.count)) {
                        return .unavailable
                    }
                    messages = page.messages + messages
                    if let reply = WatchCompanion.latestReply(in: messages) {
                        return .latestReply(reply)
                    }
                    guard page.hasEarlier, !page.messages.isEmpty else { return .latestReply(nil) }
                    offset += page.messages.count
                }
                return .unavailable
            } catch {
                return .unavailable
            }
        }
    }
}
#endif
