#if os(iOS)
import Foundation
import HermesKit
import UIKit
import WatchConnectivity

final class WatchPhoneRelay: NSObject, WCSessionDelegate {
    private weak var model: AppModel?
    private var requestCheckID: UUID?
    private var requestCheck: Task<Void, Never>?
    private var requestResult: WatchCompanion.Response?
    private var requestBackgroundTime = UIBackgroundTaskIdentifier.invalid

    func start(model: AppModel) {
        guard WCSession.isSupported() else { return }
        self.model = model
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func gatewayRemoved() {
        finishRequestCheck(nil)
        requestCheckID = nil
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        try? WCSession.default.updateApplicationContext(["requestsRevision": UUID().uuidString])
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
        case .openRequests(let id):
            return checkRequests(id, model: model)
        case .answer(let card, let answer):
            return .answer(await model.needsYou.answerFromWatch(card, answer: answer))
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
                    if let reply = WatchCompanion.latestReply(in: messages, hasEarlier: page.hasEarlier) {
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

    private func checkRequests(_ id: UUID, model: AppModel) -> WatchCompanion.Response {
        if requestCheckID == id {
            return requestResult ?? .checkingRequests
        }
        requestCheckID = id
        requestResult = nil
        if requestCheck == nil {
            requestBackgroundTime = UIApplication.shared.beginBackgroundTask(withName: "Watch Requests") { [weak self] in
                self?.finishRequestCheck(.unavailable)
            }
            requestCheck = Task { [weak self, weak model] in
                guard let model else { return }
                let workspaces = model.bots.compactMap { model.workspaces[$0.id] }
                let result = await model.needsYou.watchRequests(workspaces)
                guard !Task.isCancelled, let self else { return }
                finishRequestCheck(result)
            }
        }
        return .checkingRequests
    }

    private func finishRequestCheck(_ result: WatchCompanion.Response?) {
        requestCheck?.cancel()
        requestCheck = nil
        requestResult = result
        guard requestBackgroundTime != .invalid else { return }
        UIApplication.shared.endBackgroundTask(requestBackgroundTime)
        requestBackgroundTime = .invalid
    }
}
#endif
