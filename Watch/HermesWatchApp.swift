import HermesKit
import SwiftUI
import WatchConnectivity

@main
struct HermesWatchApp: App {
    @State private var phone = WatchLink()

    var body: some Scene {
        WindowGroup {
            WatchBotList(phone: phone)
                .task { phone.activate() }
        }
    }
}

@Observable
final class WatchLink: NSObject, WCSessionDelegate {
    private(set) var reachable = false

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
        updateReachability()
    }

    nonisolated func session(
        _ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?
    ) {
        Task { @MainActor [weak self] in self?.updateReachability() }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in self?.updateReachability() }
    }

    private func updateReachability() {
        reachable = WCSession.default.activationState == .activated && WCSession.default.isReachable
    }

    func read(_ request: WatchCompanion.Request) async -> WatchCompanion.Response? {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "HERMES_WATCH_FIXTURE") {
            return fixture(request)
        }
        #endif
        guard reachable, let data = try? JSONEncoder().encode(request) else { return nil }
        return await withCheckedContinuation { continuation in
            WCSession.default.sendMessageData(data, replyHandler: { @Sendable reply in
                continuation.resume(returning: try? JSONDecoder().decode(WatchCompanion.Response.self, from: reply))
            }, errorHandler: { @Sendable _ in
                continuation.resume(returning: nil)
            })
        }
    }

    #if DEBUG
    private func fixture(_ request: WatchCompanion.Request) -> WatchCompanion.Response {
        let id = WatchCompanion.BotID(gateway: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)), profile: "default")
        switch request {
        case .roster:
            return .roster([
                .init(id: id, title: "Hermes", gatewayName: "Hermes", state: .working),
                .init(id: .init(gateway: id.gateway, profile: "writer"), title: "Ada", gatewayName: "Hermes", state: .offline)
            ], hasUnavailableGateway: true)
        case .latestReply(let bot):
            return bot == id ? .latestReply("The **backups** finished.") : .unavailable
        }
    }
    #endif
}

private struct WatchBotList: View {
    let phone: WatchLink
    @State private var response: WatchCompanion.Response?
    @State private var retry = 0
    @Environment(\.scenePhase) private var phase

    var body: some View {
        NavigationStack {
            List {
                if case .roster(let bots, let hasUnavailableGateway) = response {
                    if hasUnavailableGateway {
                        Text("Some gateways aren’t available.").foregroundStyle(.secondary)
                    } else if bots.isEmpty {
                        Text("Set up Bot Mode in Hermes on your iPhone.").foregroundStyle(.secondary)
                    }
                    let labels = WatchCompanion.gatewayLabels(for: bots)
                    ForEach(bots) { bot in
                        NavigationLink {
                            WatchBotDetail(bot: bot, phone: phone)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(bot.title).font(.headline)
                                if let gateway = labels[bot.id] {
                                    Text(gateway).font(.footnote).foregroundStyle(.secondary)
                                }
                                Text(status(bot.state)).font(.footnote).foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                        .accessibilityIdentifier("watchBot-\(bot.id.gateway)-\(bot.id.profile)")
                    }
                    Button("Refresh") { retry += 1 }
                } else {
                    Text("Open Hermes on your iPhone and try again.").foregroundStyle(.secondary)
                    Button("Retry") { retry += 1 }
                }
            }
            .navigationTitle("Bots")
        }
        .task(id: ReadTrigger(reachable: phone.reachable, active: phase == .active, retry: retry)) {
            guard phase == .active else { return }
            let result = await phone.read(.roster)
            if !Task.isCancelled { response = result }
        }
    }

    private func status(_ state: WatchCompanion.Bot.State) -> LocalizedStringKey {
        switch state {
        case .idle: "Idle"
        case .working: "Working"
        case .offline: "Offline"
        }
    }
}

private struct WatchBotDetail: View {
    let bot: WatchCompanion.Bot
    let phone: WatchLink
    @State private var response: WatchCompanion.Response?
    @State private var retry = 0
    @Environment(\.scenePhase) private var phase

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Latest reply").font(.headline)
                switch response {
                case .latestReply(let reply):
                    if let reply {
                        Text(WatchCompanion.formattedReply(reply))
                            .accessibilityIdentifier("watchLatestReply")
                    } else {
                        Text("No reply yet.")
                    }
                    Button("Refresh") { retry += 1 }
                case .botNotFound:
                    Text("This Bot is no longer available.")
                case .unavailable, .roster:
                    Text("The reply isn’t available. Check Hermes on your iPhone.")
                    Button("Retry") { retry += 1 }
                case nil:
                    Text("Loading reply…")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(bot.title)
        .task(id: ReadTrigger(reachable: phone.reachable, active: phase == .active, retry: retry)) {
            guard phase == .active else { return }
            let result = await phone.read(.latestReply(bot.id))
            if !Task.isCancelled { response = result ?? .unavailable }
        }
    }
}

private struct ReadTrigger: Equatable {
    let reachable: Bool
    let active: Bool
    let retry: Int
}
