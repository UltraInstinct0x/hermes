import Foundation
import HermesKit
import Observation
#if os(iOS)
import HermesActivityKit
import HermesBox
import HermesPush
#endif

extension LedgerSource {
    var setupStatus: SetupStatus {
        let source = profileID.map { "\(gatewayID) · \($0)" } ?? gatewayID
        let id = "needs-you.\(source)"
        let title = String(localized: "Needs You · \(source)")
        switch state {
        case .live:
            return SetupStatus(id: id, state: .ready, title: title)
        case .unsupported:
            return SetupStatus(id: id, state: .limited, title: title,
                               fallback: String(localized: "\(source): open chats still show their requests."),
                               steps: [SetupStep(String(localized: "Set up the box ledger to see earlier requests."))])
        case .notAuthorized:
            return SetupStatus(id: id, state: .notSetUp, title: title,
                               detail: String(localized: "\(source): not authorized."),
                               steps: [SetupStep(String(localized: "Sign in to the owning gateway with access to this profile."))])
        case .offline:
            return SetupStatus(id: id, state: .unknown, title: title, detail: String(localized: "\(source): offline."))
        case .error:
            return SetupStatus(id: id, state: .unknown, title: title, detail: String(localized: "\(source): couldn't check requests."))
        }
    }
}

@MainActor
@Observable
final class NeedsYouFeed {
    private(set) var snapshot: LedgerSnapshot?
    private(set) var earlier: [LedgerRow] = []
    private(set) var moreHistory = true
    private(set) var loadingHistory = false
    private(set) var answering: Set<LedgerRow.ID> = []
    private(set) var receipts: [LedgerRow.ID: String] = [:]
    private(set) var requestNames: [LedgerRow.ID: RequestNames] = [:]
    private(set) var lookupRetries: [LedgerRow.ID: Int] = [:]

    struct RequestNames: Sendable {
        let installID: String?
        let bot: String?
        let chat: String?
        let approval: ApprovalRequest?
    }

    private enum Route: Sendable {
        case direct(BotRoster)
        case box(BackendClient, String)
    }

    private enum Cursor {
        case box(String)
        case end
    }

    @ObservationIgnored private var routes = LedgerRouteCache<Route>()
    @ObservationIgnored private var failedLookups: Set<LedgerRow.ID> = []
    @ObservationIgnored private var cursors: [UUID: Cursor] = [:]
    @ObservationIgnored private var boxWorkspaces: Set<UUID> = []
    @ObservationIgnored private var boxLiveSources: [UUID: Set<LedgerSource.ID>] = [:]
    @ObservationIgnored private let ledgerRefresh = LedgerRefresh()
    @ObservationIgnored private var incompleteLegacySources: Set<LedgerSource.ID> = []
    #if os(iOS)
    @ObservationIgnored var watchRequestsDidChange: (() -> Void)?
    @ObservationIgnored private var watchRequestsRevision = 0
    #endif

    func refresh(_ workspaces: [BotWorkspace]) async {
        await ledgerRefresh.refresh { await refreshSnapshot(workspaces) }
    }

    private func refreshSnapshot(_ workspaces: [BotWorkspace]) async -> Bool {
        var routing = LedgerRouteCache<Route>()
        var boxes: Set<UUID> = []
        var liveBoxSources: [UUID: Set<LedgerSource.ID>] = [:]
        var incomplete: Set<LedgerSource.ID> = []
        var snapshots: [LedgerSnapshot] = []
        for workspace in workspaces {
            guard let roster = workspace.roster, !Task.isCancelled else { continue }
            let backend = roster.backendClient
            var coverage: [LedgerSource] = []
            do {
                if let box = try await backend.federatedLedger() {
                    snapshots.append(box)
                    boxes.insert(workspace.id)
                    liveBoxSources[workspace.id] = Set((box.sources ?? []).filter { $0.state == .live }.map(\.id))
                    for row in box.open {
                        if let alias = row.gatewayID { routing.set(.box(backend, alias), for: row.id, gateway: workspace.id) }
                    }
                    for source in box.sources ?? [] where source.state == .unsupported {
                        guard source.profileID != nil else { continue }
                        let route = Route.box(backend, source.gatewayID)
                        do {
                            let scan = try await Self.scanLegacyRequests(source.id, route: route)
                            snapshots.append(.init(open: scan.rows, recent: [], openCount: scan.rows.count, sources: nil))
                            for row in scan.rows where routing[row.id] == nil {
                                routing.set(route, for: row.id, gateway: workspace.id)
                            }
                            if scan.failure != nil { incomplete.insert(source.id) }
                        } catch {
                            incomplete.insert(source.id)
                        }
                    }
                    continue
                }
            } catch {
                coverage = [LedgerSource(id: .init(gatewayID: workspace.id.uuidString, profileID: nil),
                                         state: RequestLedgerClient.state(of: error))]
                snapshots.append(LedgerSnapshot(open: [], recent: [], openCount: 0, sources: coverage))
            }
            let profiles = roster.profiles.map(\.name)
            var open: [LedgerRow] = []
            let route = Route.direct(roster)
            for profile in profiles.isEmpty ? ["default"] : profiles {
                let source = LedgerSource.ID(gatewayID: workspace.id.uuidString, profileID: profile)
                do {
                    let scan = try await Self.scanLegacyRequests(source, route: route)
                    for row in scan.rows where routing[row.id] == nil { routing.set(route, for: row.id, gateway: workspace.id) }
                    open += scan.rows
                    coverage.append(.init(id: source, state: scan.failure ?? .unsupported))
                } catch {
                    coverage.append(.init(id: source, state: RequestLedgerClient.state(of: error)))
                }
            }
            snapshots.append(.init(open: open, recent: [], openCount: open.count, sources: coverage))
            workspace.ledgerSources = coverage
        }
        guard !Task.isCancelled else { return false }
        let merged = LedgerSnapshot.merge(snapshots)
        #if os(iOS)
        let watchRequestsChanged = snapshot?.open != merged.open || snapshot?.sources != merged.sources
            || incompleteLegacySources != incomplete
        #endif
        incompleteLegacySources = incomplete
        snapshot = merged
        for workspace in workspaces where boxes.contains(workspace.id) {
            workspace.ledgerSources = merged.sources ?? []
        }
        routes.replace(with: routing)
        lookupRetries = lookupRetries.filter { routing[$0.key] != nil }
        for id in failedLookups where routing[id] != nil && requestNames[id] == nil {
            lookupRetries[id, default: 0] += 1
        }
        failedLookups.removeAll()
        for (workspaceID, live) in liveBoxSources where !live.isSubset(of: boxLiveSources[workspaceID] ?? []) {
            cursors.removeValue(forKey: workspaceID)
        }
        boxWorkspaces = boxes
        boxLiveSources = liveBoxSources
        updateMoreHistory(workspaces)
        #if os(iOS)
        if watchRequestsChanged {
            watchRequestsRevision += 1
            watchRequestsDidChange?()
        }
        #endif
        return true
    }

    func forgetGateway(_ id: UUID) {
        routes.remove(gateway: id)
    }

    private static func scanLegacyRequests(
        _ id: LedgerSource.ID, route: Route
    ) async throws -> (rows: [LedgerRow], failure: LedgerSource.State?) {
        try await Self.withRoute(route) { request in
            try await RequestLedgerClient.scanLegacyRequests(source: id, request: request)
        }
    }

    private static func withRoute<T: Sendable>(
        _ route: Route, perform: @Sendable (@escaping RequestLedgerClient.Transport) async throws -> T
    ) async throws -> T {
        try await withSocket(route, receivesServerRequests: false) { socket in
            try await perform { try await socket.request($0, $1, timeout: .seconds(10)) }
        }
    }

    private static func withSocket<T: Sendable>(
        _ route: Route, receivesServerRequests: Bool, perform: @Sendable (GatewaySocket) async throws -> T
    ) async throws -> T {
        let socket: GatewaySocket
        switch route {
        case .direct(let roster):
            socket = GatewaySocket(url: try await roster.backendClient.gatewaySocketURL())
        case .box(let backend, let alias):
            socket = try await backend.ledgerSocket(gatewayID: alias, identity: .hermesApp)
        }
        defer { Task { await socket.close() } }
        try await socket.connect(receivesServerRequests: receivesServerRequests)
        return try await perform(socket)
    }

    func inlineChoices(_ row: LedgerRow) -> [ApprovalChoice] {
        guard routes[row.id] != nil, row.sessionID?.isEmpty == false, receipts[row.id] == nil,
              row.expiresAt.map({ $0 > Date.now.timeIntervalSince1970 }) ?? true,
              let approval = requestNames[row.id]?.approval,
              !approval.smartDenied, !approval.isMemorySave, !approval.isPaymentFill else { return [] }
        return approval.choices.filter { choice in
            choice == .deny || choice == .once && approval.command.map(ApprovalCard.showsWholeInBatch) == true
        }
    }

    func answer(_ row: LedgerRow, choice: ApprovalChoice, workspaces: [BotWorkspace]) async {
        guard inlineChoices(row).contains(choice), let session = row.sessionID, let route = routes[row.id],
              let gateway = routes.gateway(for: row.id),
              let shown = requestNames[row.id]?.approval,
              answering.insert(row.id).inserted else { return }
        defer { answering.remove(row.id) }
        do {
            let sent = try await Self.answerOnOwner(row, session: session, route: route) { snapshot in
                guard self.routes.gateway(for: row.id) == gateway,
                      let live = row.approval(in: snapshot), !live.smartDenied, !live.isMemorySave, !live.isPaymentFill,
                      live.command == shown.command, live.choices.contains(choice) else { return nil }
                return .object(["choice": .string(choice.rawValue)])
            }
            receipts[row.id] = sent ? String(localized: "Answer sent from this device") : String(localized: "No longer pending")
            await refresh(workspaces)
        } catch {
            receipts[row.id] = String(localized: "Couldn't answer. Check again.")
        }
    }

    private static func answerOnOwner(
        _ row: LedgerRow, session: String, route: Route, result: @MainActor @Sendable (JSONValue) -> JSONValue?
    ) async throws -> Bool {
        try await Self.withSocket(route, receivesServerRequests: true) { socket in
            let snapshot = try await socket.request("session.resume", Self.resume(session, profile: row.profileID ?? row.profile),
                                                    timeout: .seconds(10))
            guard let answer = await result(snapshot) else { return false }
            guard await socket.respond(to: row.requestID, result: answer) else { throw URLError(.networkConnectionLost) }
            return true
        }
    }

    #if os(iOS)
    func answerFromLiveActivity(botKey: BotKey, requestId: String, shown: String, answer: WatchCompanion.RequestAnswer,
                                workspaces: [BotWorkspace]) async -> Bool {
        guard NotificationCatalog.lockScreenAnswersEnabled, RequestActivityPresentation.isExactRequestID(requestId),
              !botKey.gatewayId.isEmpty, !botKey.profileId.isEmpty else { return false }
        await ledgerRefresh.waitForNextSnapshot { await self.refreshSnapshot(workspaces) }
        let matches = snapshot?.open.filter {
            $0.requestID == requestId && $0.gatewayID == botKey.gatewayId && ($0.profileID ?? $0.profile) == botKey.profileId
        } ?? []
        guard matches.count == 1, let row = matches.first, let session = row.sessionID, let route = routes[row.id],
              let gateway = routes.gateway(for: row.id), answering.insert(row.id).inserted else { return false }
        defer { answering.remove(row.id) }
        do {
            return try await Self.answerOnOwner(row, session: session, route: route) { snapshot in
                guard self.routes.gateway(for: row.id) == gateway,
                      let live = WatchCompanion.RequestCard(row: row, snapshot: snapshot, gateway: gateway, source: "") else { return nil }
                switch (live.content, answer) {
                case (.approval(let command, _), .approval):
                    guard !shown.isEmpty, command == shown else { return nil }
                case (.clarify(let questions), .clarify(let answers)):
                    guard questions.count == 1, let question = questions.first, !question.multiSelect,
                          question.prompt == VisibleText.of(shown), case .text(let choice) = answers[question.id],
                          question.choices.contains(choice) else { return nil }
                default: return nil
                }
                return live.result(for: answer)
            }
        } catch {
            return false
        }
    }

    func watchRequests(_ workspaces: [BotWorkspace], usePublished: Bool) async -> WatchCompanion.Response {
        if !usePublished || snapshot == nil {
            await ledgerRefresh.waitForNextSnapshot { await self.refreshSnapshot(workspaces) }
        }
        while !Task.isCancelled, let snapshot {
            let revision = watchRequestsRevision
            let result = await watchCards(snapshot, workspaces: workspaces)
            if revision == watchRequestsRevision { return result }
        }
        return .unavailable
    }

    private func watchCards(_ snapshot: LedgerSnapshot, workspaces: [BotWorkspace]) async -> WatchCompanion.Response {
        var cards: [WatchCompanion.RequestCard] = []
        var incomplete = !incompleteLegacySources.isEmpty || workspaces.contains { $0.roster == nil } || (snapshot.sources ?? []).contains {
            $0.state != .live && $0.state != .unsupported
        }
        for row in snapshot.open where row.kind == "approval" || row.kind == "clarify" {
            guard !Task.isCancelled else { return .unavailable }
            guard let session = row.sessionID, !session.isEmpty, let route = routes[row.id],
                  let gateway = routes.gateway(for: row.id) else {
                incomplete = true
                continue
            }
            let profile = row.profileID ?? row.profile
            let bot: String
            switch route {
            case .direct(let roster):
                bot = roster.bot(named: profile)?.title ?? profile
            case .box:
                bot = profile
            }
            do {
                let card = try await Self.withRoute(route) { request in
                    let live = try await request("session.resume", Self.resume(session, profile: profile))
                    let title = live["info"]?["title"]?.stringValue
                    let source = [bot, title].compactMap { $0 }.filter { !$0.isEmpty }
                    return WatchCompanion.RequestCard(row: row, snapshot: live, gateway: gateway,
                                                      source: (source.first == source.last ? Array(source.prefix(1)) : source)
                                                        .joined(separator: " · "))
                }
                if let card { cards.append(card) }
            } catch {
                incomplete = true
            }
        }
        return .openRequests(cards.filter { card in
            guard let id = card.id.row else { return false }
            return routes.gateway(for: id) == card.id.gateway
        }, incomplete: incomplete)
    }

    func answerFromWatch(_ card: WatchCompanion.RequestCard, answer: WatchCompanion.RequestAnswer) async -> WatchCompanion.AnswerStatus {
        guard !card.isExpired() else { return .noLongerPending }
        guard card.result(for: answer) != nil else { return .invalidAnswer }
        guard let id = card.id.row, let gateway = card.id.gateway, routes.gateway(for: id) == gateway,
              let row = snapshot?.open.first(where: { WatchCompanion.RequestCard.identity(of: $0, gateway: gateway) == card.id }),
              let session = row.sessionID, let route = routes[id] else { return .noLongerPending }
        guard answering.insert(row.id).inserted else { return .unavailable }
        defer { answering.remove(row.id) }
        do {
            let sent = try await Self.answerOnOwner(row, session: session, route: route) { snapshot in
                guard self.routes.gateway(for: id) == gateway,
                      let live = WatchCompanion.RequestCard(row: row, snapshot: snapshot, gateway: gateway, source: card.source),
                      live.content == card.content else { return nil }
                return live.result(for: answer)
            }
            return sent ? .sent : .noLongerPending
        } catch {
            return routes.gateway(for: id) == gateway ? .unavailable : .noLongerPending
        }
    }
    #endif

    static func answeredBy(_ winner: LedgerAnswerer?) -> String {
        let name = winner?.label ?? String(localized: "Unknown device")
        return String(localized: "Answered by \(name)")
    }

    func openLocalChat(_ row: LedgerRow, app: AppModel, window: UUID?) {
        guard let workspace = localWorkspace(for: row, in: app), let session = row.sessionID else { return }
        app.select(workspace.id, in: window)
        let profile = row.profileID ?? row.profile
        if let bot = workspace.roster?.bot(named: profile),
           bot.canonicalSession.map({ $0.id == session || $0.resolvedID == session }) == true {
            workspace.sidebarMode = .bots
            workspace.selection = .bot(profile)
        } else {
            workspace.sidebarMode = .chats
            let key = workspace.unreadKey(forStoredSession: session)
            var chat = workspace.session(forKey: key) ?? HermesSession.opened(id: session)
            if !chat.hasRealTitle { chat.title = requestNames[row.id]?.chat }
            workspace.openLedgerChat(chat, profile: profile)
        }
    }

    func localWorkspace(for row: LedgerRow, in app: AppModel) -> BotWorkspace? {
        guard row.sessionID != nil else { return nil }
        switch routes[row.id] {
        case .direct(let roster):
            return app.workspaces.values.first { $0.roster === roster }
        case .box:
            guard let installID = requestNames[row.id]?.installID else { return nil }
            let matches = app.workspaces.values.filter { workspace in
                workspace.roster?.installID == installID
            }
            return matches.count == 1 ? matches.first : nil
        case nil:
            return nil
        }
    }

    func loadRequestNames(_ row: LedgerRow) async {
        guard !Task.isCancelled, requestNames[row.id] == nil, let route = routes[row.id] else { return }
        let profile = row.profileID ?? row.profile
        do {
            let names = try await Self.withRoute(route) { request in
                let profiles = try await request("profiles.list", ["include_sessions": .bool(false)])
                let installID = profiles["install_id"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
                let bot = profiles["profiles"]?.arrayValue?.first { $0["name"]?.stringValue == profile }.map(BotProfile.init(json:))
                guard let id = row.sessionID else { return RequestNames(installID: installID, bot: bot?.title, chat: nil, approval: nil) }
                let list = try await request("session.list", [
                    "profile": .string(profile), "limit": .number(200), "include_hidden": .bool(true),
                ])
                let chat = list["sessions"]?.arrayValue?.first {
                    $0["id"]?.stringValue == id || $0["resolved_id"]?.stringValue == id
                }
                let approval: ApprovalRequest?
                if row.kind == "approval" {
                    let snapshot = try await request("session.resume", Self.resume(id, profile: profile))
                    approval = row.approval(in: snapshot)
                } else {
                    approval = nil
                }
                return RequestNames(installID: installID, bot: bot?.title, chat: chat?["title"]?.stringValue, approval: approval)
            }
            guard !Task.isCancelled else { return }
            requestNames[row.id] = names
            failedLookups.remove(row.id)
        } catch {
            if !Task.isCancelled, requestNames[row.id] == nil { failedLookups.insert(row.id) }
        }
    }

    private static func resume(_ session: String, profile: String) -> [String: JSONValue] {
        ["session_id": .string(session), "profile": .string(profile), "omit_messages": .bool(true)]
    }

    func represents(_ session: HermesSession, in workspace: BotWorkspace, app: AppModel) -> Bool {
        snapshot?.open.contains { row in
            (row.sessionID == session.id || row.sessionID == session.stableID)
                && localWorkspace(for: row, in: app) === workspace
        } == true
    }

    func loadEarlier(_ workspaces: [BotWorkspace]) async {
        guard !loadingHistory, moreHistory else { return }
        loadingHistory = true
        defer { loadingHistory = false }
        var rows: [LedgerRow] = []
        for workspace in workspaces {
            guard let roster = workspace.roster else { continue }
            if boxWorkspaces.contains(workspace.id) {
                let key = workspace.id
                if case .end? = cursors[key] { continue }
                let before: String?
                if case .box(let cursor)? = cursors[key] { before = cursor } else { before = nil }
                if let page = try? await roster.backendClient.federatedLedgerHistory(before: before) {
                    rows += page.requests.filter { $0.state != "open" }
                    cursors[key] = page.nextBefore.map(Cursor.box) ?? .end
                }
            }
        }
        var seen: Set<LedgerRow.ID> = []
        earlier = (earlier + rows).sorted { $0.createdAt > $1.createdAt }.filter { seen.insert($0.id).inserted }
        updateMoreHistory(workspaces)
    }

    private func updateMoreHistory(_ workspaces: [BotWorkspace]) {
        moreHistory = workspaces.contains { workspace in
            if case .end? = cursors[workspace.id] { return false }
            return boxLiveSources[workspace.id]?.isEmpty == false
        }
    }
}
