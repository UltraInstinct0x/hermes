import Foundation
import HermesActivityKit
import HermesKit
import Observation
#if os(iOS)
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
    private(set) var nativeClarifications: [LedgerRow.ID: NativeClarification] = [:]

    struct NativeClarification: Sendable, Equatable {
        let reference: RequestReference
        let question: HermesRequest.Question
    }

    struct NativeApproval: Sendable {
        let reference: RequestReference
        let prompt: LedgerRow.NativeApproval
    }

    struct RequestNames: Sendable {
        let installID: String?
        let bot: String?
        let chat: String?
        let approval: ApprovalRequest?
        var clarification: NativeClarification? = nil
        var nativeApproval: NativeApproval? = nil
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
                    for row in box.open + box.recent {
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
        let active = Set(merged.open.map(\.id))
        nativeClarifications = nativeClarifications.filter { active.contains($0.key) }
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
              requestNames[row.id]?.nativeApproval.map({ $0.prompt.isPlainCommand }) != false,
              InlineApproval.isOrdinary(smartDenied: approval.smartDenied, memorySave: approval.isMemorySave,
                                        paymentFill: approval.isPaymentFill) else { return [] }
        return approval.choices.filter { choice in
            choice == .deny || choice == .once && approval.command.map(ApprovalCard.showsWholeInBatch) == true
        }
    }

    func answer(_ row: LedgerRow, choice: ApprovalChoice, workspaces: [BotWorkspace]) async {
        if let card = requestNames[row.id]?.nativeApproval {
            guard inlineChoices(row).contains(choice) else { return }
            if await answerNativeRequest(card.reference, selection: .approval(allow: choice == .once),
                                         shown: card.prompt.command ?? "", requiresPlainCommand: true) != nil {
                await refresh(workspaces)
            }
            return
        }
        guard inlineChoices(row).contains(choice), let session = row.sessionID, let route = routes[row.id],
              let gateway = routes.gateway(for: row.id),
              let shown = requestNames[row.id]?.approval,
              answering.insert(row.id).inserted else { return }
        defer { answering.remove(row.id) }
        do {
            let sent = try await Self.answerOnOwner(row, session: session, route: route) { snapshot in
                guard self.routes.gateway(for: row.id) == gateway,
                      let live = row.legacyApproval(in: snapshot),
                      InlineApproval.isOrdinary(smartDenied: live.smartDenied, memorySave: live.isMemorySave,
                                                paymentFill: live.isPaymentFill),
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

    func resolveRequest(_ ref: RequestReference, workspaces: [BotWorkspace]) async -> LedgerRow? {
        await resolveRequest(botKey: ref.botKey, requestId: ref.requestId, sessionId: ref.sessionId, workspaces: workspaces)
    }

    func resolveRequest(botKey: String, requestId: String, sessionId: String? = nil,
                        workspaces: [BotWorkspace]) async -> LedgerRow? {
        await ledgerRefresh.waitForNextSnapshot { await self.refreshSnapshot(workspaces) }
        return requestRow(botKey: botKey, requestId: requestId, sessionId: sessionId, includeRecent: true)
    }

    private func requestRow(botKey: String, requestId: String, sessionId: String?, includeRecent: Bool = false) -> LedgerRow? {
        guard let snapshot else { return nil }
        let matches = (snapshot.open + (includeRecent ? snapshot.recent : [])).filter {
            $0.requestID == requestId && (sessionId == nil || $0.sessionID == sessionId)
                && "\($0.gatewayID ?? "")::\($0.profileID ?? $0.profile)" == botKey
        }
        return matches.count == 1 ? matches.first : nil
    }

    func answerNativeRequest(_ ref: RequestReference, selection: RequestSelection, shown: String,
                             acceptsTypedAnswer: Bool = false, choiceOnCard: ApprovalChoice? = nil,
                             requiresPlainCommand: Bool = false) async -> RequestActivityAttributes.ContentState.Outcome? {
        guard let row = requestRow(botKey: ref.botKey, requestId: ref.requestId, sessionId: ref.sessionId) else { return .noLongerWaiting }
        guard let route = routes[row.id] else { return nil }
        guard receipts[row.id] == nil, answering.insert(row.id).inserted else { return nil }
        defer { answering.remove(row.id) }
        if ref.isFrame {
            guard row.kind == "clarify", case .clarification(let answer, let questionId) = selection,
                  let questionId else { return .noLongerWaiting }
            do {
                let sent = try await Self.answerOnOwner(row, session: ref.sessionId, route: route) { snapshot in
                    row.frameClarificationChoice(in: snapshot, questionID: questionId, shown: shown, answer: answer)
                }
                let outcome: RequestActivityAttributes.ContentState.Outcome = sent ? .answered : .noLongerWaiting
                receipts[row.id] = RequestActivityPresentation.finalLine(outcome, answeredBy: nil)
                return outcome
            } catch {
                return nil
            }
        }
        guard let generation = ref.executionGeneration else { return .noLongerWaiting }
        let outcome: RequestActivityAttributes.ContentState.Outcome
        do {
            outcome = try await Self.withSocket(route, receivesServerRequests: false) { socket in
                let profile = row.profileID ?? row.profile
                let live = try await socket.request("session.resume", Self.resume(ref.sessionId, profile: profile), timeout: .seconds(10))
                guard let prompt = Self.nativePrompt(in: live, reference: ref, kind: row.kind) else { return .noLongerWaiting }
                var params: [String: JSONValue] = [
                    "session_id": .string(ref.sessionId), "execution_generation": .number(Double(generation)),
                    "prompt_id": .string(ref.requestId), "profile": .string(profile),
                ]
                let method: String
                switch selection {
                case .approval(let allow):
                    let choice = choiceOnCard ?? (allow ? .once : .deny)
                    guard let approval = row.nativeApproval(in: live, generation: ref.executionGeneration),
                          (approval.command ?? "") == shown, approval.approval.choices.contains(choice) else { return .noLongerWaiting }
                    if choiceOnCard == nil {
                        guard (!requiresPlainCommand || approval.isPlainCommand), prompt["edit"] == nil, !shown.isEmpty,
                              InlineApproval.isOrdinary(smartDenied: approval.approval.smartDenied,
                                                        memorySave: approval.approval.isMemorySave,
                                                        paymentFill: approval.approval.isPaymentFill),
                              choice == .deny || approval.approval.command.map(InlineApproval.showsWholeCommand) == true
                        else { return .noLongerWaiting }
                    }
                    params["choice"] = .string(choice.rawValue)
                    method = "approval.respond"
                case .clarification(let answer, _):
                    guard row.kind == "clarify", prompt["question"]?.stringValue == shown,
                          !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          acceptsTypedAnswer || (prompt["multi_select"]?.boolValue == false
                            && prompt["choices"]?.arrayValue?.contains(.string(answer)) == true) else { return .noLongerWaiting }
                    params["answer"] = .string(answer)
                    method = "clarify.respond"
                }
                let receipt = try await socket.request(method, params, timeout: .seconds(10))
                guard receipt["prompt_id"]?.stringValue == ref.requestId else { throw URLError(.badServerResponse) }
                switch receipt["status"]?.stringValue {
                case "resolved": return .answered
                case "already_resolved": return .noLongerWaiting
                default: throw URLError(.badServerResponse)
                }
            }
        } catch let error as GatewayRPCError where ["stale_generation", "approval_not_pending", "invalid_params"].contains(
            error.data?["reason"]?.stringValue ?? error.message) {
            outcome = .noLongerWaiting
        } catch {
            return nil
        }
        receipts[row.id] = RequestActivityPresentation.finalLine(outcome, answeredBy: nil)
        return outcome
    }

    private nonisolated static func nativePrompt(in snapshot: JSONValue, reference: RequestReference, kind: String) -> JSONValue? {
        LedgerRow.nativePrompt(in: snapshot, sessionID: reference.sessionId, requestID: reference.requestId,
                               generation: reference.executionGeneration, kind: kind)
    }

    private nonisolated static func nativeApproval(_ row: LedgerRow, in snapshot: JSONValue) -> NativeApproval? {
        guard let approval = row.nativeApproval(in: snapshot), let gateway = row.gatewayID,
              let reference = RequestReference(botKey: "\(gateway)::\(row.profileID ?? row.profile)", requestId: row.requestID,
                                               sessionId: row.sessionID, executionGeneration: approval.generation) else { return nil }
        return NativeApproval(reference: reference, prompt: approval)
    }

    private nonisolated static func nativeClarification(_ row: LedgerRow, in snapshot: JSONValue) -> NativeClarification? {
        guard let gateway = row.gatewayID,
              let ref = RequestReference(botKey: "\(gateway)::\(row.profileID ?? row.profile)", requestId: row.requestID,
                                         sessionId: row.sessionID, executionGeneration: snapshot["execution_generation"]?.truncatedIntValue),
              let prompt = nativePrompt(in: snapshot, reference: ref, kind: "clarify"),
              let text = prompt["question"]?.stringValue, !text.isEmpty,
              let multiSelect = prompt["multi_select"]?.boolValue,
              let rawChoices = prompt["choices"]?.arrayValue else { return nil }
        let choices = rawChoices.compactMap(\.stringValue)
        guard rawChoices.count == choices.count, Set(choices).count == choices.count else { return nil }
        return NativeClarification(reference: ref, question: .init(id: ref.requestId, question: text, choices: choices, multiSelect: multiSelect))
    }

    func inlineClarificationChoices(_ row: LedgerRow) -> [String] {
        guard receipts[row.id] == nil, row.expiresAt.map({ $0 > Date.now.timeIntervalSince1970 }) ?? true,
              let q = nativeClarifications[row.id]?.question, !q.multiSelect,
              q.choices.count <= RequestActivityPresentation.maxChoiceButtons,
              q.question.count <= RequestActivityPresentation.detailLimit else { return [] }
        return q.choices
    }

    func openClarification(_ row: LedgerRow, reference: RequestReference? = nil, in conversation: ConversationModel) async {
        if let route = routes[row.id], let session = row.sessionID, row.state == "open" {
            let profile = row.profileID ?? row.profile
            let live = try? await Self.withRoute(route) {
                try await $0("session.resume", Self.resume(session, profile: profile))
            }
            if let live, let card = Self.nativeClarification(row, in: live), reference == nil || reference == card.reference {
                conversation.ledgerClarification = card
                return
            }
            if reference == nil || reference?.isFrame == true,
               let live, let frame = row.openRequest(in: live), let request = HermesRequest.parse(frame) {
                conversation.receive(request)
                conversation.shownWaitingID = "r:" + request.id
                return
            }
        }
        conversation.banner = .invalidResponse(RequestActivityPresentation.finalLine(.noLongerWaiting, answeredBy: nil))
    }

    func openApproval(_ row: LedgerRow, reference: RequestReference? = nil, in conversation: ConversationModel) async {
        if let route = routes[row.id], let session = row.sessionID, row.state == "open" {
            let live = try? await Self.withRoute(route) {
                try await $0("session.resume", Self.resume(session, profile: row.profileID ?? row.profile))
            }
            if let live, let card = Self.nativeApproval(row, in: live), reference == nil || reference == card.reference {
                conversation.ledgerApproval = card
                return
            }
            if reference == nil, let live, row.legacyApproval(in: live) != nil { return }
        }
        conversation.recordRequestOutcome(.noLongerWaiting)
    }

    #if os(iOS)
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

    @discardableResult
    func openLocalChat(_ row: LedgerRow, app: AppModel, window: UUID?) -> ConversationModel? {
        guard let workspace = localWorkspace(for: row, in: app), let session = row.sessionID else { return nil }
        app.select(workspace.id, in: window)
        let profile = row.profileID ?? row.profile
        if let bot = workspace.roster?.bot(named: profile),
           bot.canonicalSession.map({ $0.id == session || $0.resolvedID == session }) == true {
            workspace.sidebarMode = .bots
            workspace.selection = .bot(profile)
            return workspace.roster?.conversation(for: profile)
        } else {
            workspace.sidebarMode = .chats
            let key = workspace.unreadKey(forStoredSession: session)
            var chat = workspace.session(forKey: key) ?? HermesSession.opened(id: session)
            if !chat.hasRealTitle { chat.title = requestNames[row.id]?.chat }
            workspace.openLedgerChat(chat, profile: profile)
            return workspace.conversation(forKey: chat.stableID)
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
                var approval: ApprovalRequest?
                var clarification: NativeClarification?
                var nativeApproval: NativeApproval?
                if row.state == "open", row.kind == "approval" || row.kind == "clarify" {
                    let snapshot = try await request("session.resume", Self.resume(id, profile: profile))
                    nativeApproval = Self.nativeApproval(row, in: snapshot)
                    approval = nativeApproval?.prompt.approval ?? row.legacyApproval(in: snapshot)
                    if row.kind == "clarify" { clarification = Self.nativeClarification(row, in: snapshot) }
                }
                return RequestNames(installID: installID, bot: bot?.title, chat: chat?["title"]?.stringValue,
                                    approval: approval, clarification: clarification, nativeApproval: nativeApproval)
            }
            guard !Task.isCancelled else { return }
            requestNames[row.id] = names
            if snapshot?.open.contains(where: { $0.id == row.id }) == true {
                nativeClarifications[row.id] = names.clarification
            }
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
