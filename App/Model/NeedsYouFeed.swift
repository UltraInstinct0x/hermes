import Foundation
import HermesKit
import Observation

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
                               fallback: String(localized: "\(source): open chats still show their requests. History needs a newer Hermes."),
                               steps: [.updateHermes])
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

    private enum HistoryRoute: Hashable {
        case box(UUID)
        case direct(LedgerSource.ID)
    }

    private enum Cursor {
        case box(String)
        case direct(TimeInterval)
        case end
    }

    @ObservationIgnored private var routes: [LedgerRow.ID: Route] = [:]
    @ObservationIgnored private var cursors: [HistoryRoute: Cursor] = [:]
    @ObservationIgnored private var boxWorkspaces: Set<UUID> = []
    @ObservationIgnored private var boxLiveSources: [UUID: Set<LedgerSource.ID>] = [:]
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var needsRefresh = false

    func refresh(_ workspaces: [BotWorkspace]) async {
        guard !refreshing else { needsRefresh = true; return }
        refreshing = true
        defer { refreshing = false }
        repeat {
            needsRefresh = false
            var routing: [LedgerRow.ID: Route] = [:]
            var boxes: Set<UUID> = []
            var liveBoxSources: [UUID: Set<LedgerSource.ID>] = [:]
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
                            if let alias = row.gatewayID { routing[row.id] = .box(backend, alias) }
                        }
                        let sources = (box.sources ?? []).compactMap { item -> RequestLedgerClient.Source? in
                            guard item.state == .unsupported, let profile = item.profileID else { return nil }
                            let route = Route.box(backend, item.gatewayID)
                            return Self.source(item.id, profile: profile, route: route)
                        }
                        if !sources.isEmpty {
                            snapshots.append(try await RequestLedgerClient.snapshot(sources: sources, federated: { box }))
                        }
                        continue
                    }
                } catch {
                    coverage = [LedgerSource(id: .init(gatewayID: workspace.id.uuidString, profileID: nil),
                                             state: RequestLedgerClient.state(of: error))]
                    snapshots.append(LedgerSnapshot(open: [], recent: [], openCount: 0, sources: coverage))
                }
                let sources = directSources(workspace, roster: roster)
                if let local = try? await RequestLedgerClient.snapshot(sources: sources) {
                    snapshots.append(local)
                    coverage += local.sources ?? []
                    for row in local.open where routing[row.id] == nil { routing[row.id] = .direct(roster) }
                }
                workspace.ledgerSources = coverage
            }
            guard !Task.isCancelled else { return }
            let merged = LedgerSnapshot.merge(snapshots)
            snapshot = merged
            for workspace in workspaces where boxes.contains(workspace.id) {
                workspace.ledgerSources = merged.sources ?? []
            }
            routes = routing
            for (workspaceID, live) in liveBoxSources where !live.isSubset(of: boxLiveSources[workspaceID] ?? []) {
                cursors.removeValue(forKey: .box(workspaceID))
            }
            boxWorkspaces = boxes
            boxLiveSources = liveBoxSources
            updateMoreHistory(workspaces)
        } while needsRefresh && !Task.isCancelled
    }

    private func directSources(_ workspace: BotWorkspace, roster: BotRoster) -> [RequestLedgerClient.Source] {
        let profiles = roster.profiles.map(\.name)
        return (profiles.isEmpty ? ["default"] : profiles).map { profile in
            Self.source(.init(gatewayID: workspace.id.uuidString, profileID: profile), profile: profile, route: .direct(roster))
        }
    }

    private static func source(_ id: LedgerSource.ID, profile: String, route: Route) -> RequestLedgerClient.Source {
        .init(id: id, client: .init { method, params in
            try await Self.withRoute(route) { try await $0(method, params) }
        }, legacy: {
            try await Self.withRoute(route, readOnly: true) { request in
                let listing = try await request("session.list", [
                    "profile": .string(profile), "limit": .number(200), "include_hidden": .bool(true),
                ])
                var rows: [LedgerRow] = []
                for session in listing["sessions"]?.arrayValue ?? [] {
                    guard let key = session["resolved_id"]?.stringValue ?? session["id"]?.stringValue else { continue }
                    let snapshot = try await request("session.resume", [
                        "session_id": .string(key), "profile": .string(profile), "omit_messages": .bool(true),
                    ])
                    rows += RequestLedgerClient.legacyRows(snapshot: snapshot, sessionID: key, source: id)
                }
                return rows
            }
        })
    }

    private static func withRoute<T: Sendable>(
        _ route: Route, readOnly: Bool = false, perform: @Sendable (@escaping RequestLedgerClient.Transport) async throws -> T
    ) async throws -> T {
        let socket: GatewaySocket
        switch route {
        case .direct(let roster):
            if !readOnly {
                return try await perform { try await roster.request($0, $1, timeout: .seconds(10)) }
            }
            socket = GatewaySocket(url: try await roster.backendClient.gatewaySocketURL())
        case .box(let backend, let alias):
            socket = try await backend.ledgerSocket(gatewayID: alias, identity: .hermesApp)
        }
        defer { Task { await socket.close() } }
        try await socket.connect(receivesServerRequests: !readOnly)
        return try await perform { try await socket.request($0, $1, timeout: .seconds(10)) }
    }

    func inlineChoices(_ row: LedgerRow) -> [ApprovalChoice] {
        guard routes[row.id] != nil, receipts[row.id] == nil,
              row.expiresAt.map({ $0 > Date.now.timeIntervalSince1970 }) ?? true,
              let approval = requestNames[row.id]?.approval,
              !approval.smartDenied, !approval.isMemorySave, !approval.isPaymentFill else { return [] }
        return approval.choices.filter { choice in
            guard row.choices?.contains(.string(choice.rawValue)) == true else { return false }
            return choice == .deny || choice == .once && approval.command.map(ApprovalCard.showsWholeInBatch) == true
        }
    }

    func answer(_ row: LedgerRow, choice: ApprovalChoice, workspaces: [BotWorkspace]) async {
        guard inlineChoices(row).contains(choice), let id = row.ledgerID, let route = routes[row.id],
              answering.insert(row.id).inserted else { return }
        defer { answering.remove(row.id) }
        do {
            let answer = try await Self.withRoute(route) { transport in
                try await RequestLedgerClient(transport: transport).answer(ledgerID: id, profile: row.profileID ?? row.profile,
                                                                            result: ["choice": .string(choice.rawValue)])
            }
            switch answer {
            case .accepted(let winner):
                receipts[row.id] = Self.answeredBy(winner)
            case .noLongerPending(let settlement):
                receipts[row.id] = settlement?.answeredBy.map { Self.answeredBy($0) } ?? String(localized: "No longer pending")
            }
            await refresh(workspaces)
        } catch {
            receipts[row.id] = String(localized: "Couldn't answer. Check again.")
        }
    }

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
        guard requestNames[row.id] == nil, let route = routes[row.id] else { return }
        let profile = row.profileID ?? row.profile
        let names = try? await Self.withRoute(route, readOnly: true) { request in
            let profiles = try? await request("profiles.list", ["include_sessions": .bool(false)])
            let installID = profiles?["install_id"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            let bot = profiles?["profiles"]?.arrayValue?.first { $0["name"]?.stringValue == profile }.map(BotProfile.init(json:))
            guard let id = row.sessionID else { return RequestNames(installID: installID, bot: bot?.title, chat: nil, approval: nil) }
            let list = try? await request("session.list", [
                "profile": .string(profile), "limit": .number(200), "include_hidden": .bool(true),
            ])
            let chat = list?["sessions"]?.arrayValue?.first {
                $0["id"]?.stringValue == id || $0["resolved_id"]?.stringValue == id
            }
            let approval: ApprovalRequest?
            if row.kind == "approval", row.ledgerID != nil,
               let snapshot = try? await request("session.resume", [
                   "session_id": .string(id), "profile": .string(profile), "omit_messages": .bool(true),
               ]) {
                approval = row.approval(in: snapshot)
            } else {
                approval = nil
            }
            return RequestNames(installID: installID, bot: bot?.title, chat: chat?["title"]?.stringValue, approval: approval)
        }
        if let names { requestNames[row.id] = names }
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
                let key = HistoryRoute.box(workspace.id)
                if case .end? = cursors[key] { continue }
                let before: String?
                if case .box(let cursor)? = cursors[key] { before = cursor } else { before = nil }
                if let page = try? await roster.backendClient.federatedLedgerHistory(before: before) {
                    rows += page.requests.filter { $0.state != "open" }
                    cursors[key] = page.nextBefore.map(Cursor.box) ?? .end
                }
            } else {
                for source in directSources(workspace, roster: roster) {
                    guard let profile = source.id.profileID,
                          workspace.ledgerSources.contains(where: { $0.id == source.id && $0.state == .live }) else { continue }
                    let key = HistoryRoute.direct(source.id)
                    if case .end? = cursors[key] { continue }
                    let before: TimeInterval?
                    if case .direct(let cursor)? = cursors[key] { before = cursor } else { before = nil }
                    if let page = try? await source.client.history(profile: profile, gatewayID: source.id.gatewayID, before: before) {
                        rows += page.requests
                        cursors[key] = page.nextBefore.map(Cursor.direct) ?? .end
                    }
                }
            }
        }
        var seen: Set<LedgerRow.ID> = []
        earlier = (earlier + rows).sorted { $0.createdAt > $1.createdAt }.filter { seen.insert($0.id).inserted }
        updateMoreHistory(workspaces)
    }

    private func updateMoreHistory(_ workspaces: [BotWorkspace]) {
        let choices = workspaces.flatMap { workspace -> [HistoryRoute] in
            if boxWorkspaces.contains(workspace.id) {
                return boxLiveSources[workspace.id]?.isEmpty == false ? [.box(workspace.id)] : []
            }
            return workspace.ledgerSources.filter { $0.state == .live && $0.profileID != nil }
                .map { .direct($0.id) }
        }
        moreHistory = choices.contains { key in
            if case .end? = cursors[key] { return false }
            return true
        }
    }
}
