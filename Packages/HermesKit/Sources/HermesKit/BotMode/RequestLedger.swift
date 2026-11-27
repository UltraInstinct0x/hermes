import Foundation

public struct LedgerAnswerer: Decodable, Sendable, Equatable {
    public let clientID: String
    public let label: String?
    public let kind: String?

    enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case label, kind
    }
}

public struct LedgerRow: Decodable, Sendable, Identifiable, Equatable {
    public let ledgerID: String?
    public let requestID: String
    public let gatewayID: String?
    public let profileID: String?
    public let profile: String
    public let sessionID: String?
    public let kind: String
    public let state: String
    public let prompt: String?
    public let choices: [JSONValue]?
    public let outcome: String?
    public let createdAt: TimeInterval
    public let expiresAt: TimeInterval?
    public let answeredAt: TimeInterval?
    public let settledAt: TimeInterval?
    public let answeredBy: LedgerAnswerer?

    public struct ID: Codable, Sendable, Hashable {
        let canonical: Bool
        let gateway: String?
        let profile: String
        let key: String
    }

    public var id: ID {
        if let ledgerID { return ID(canonical: true, gateway: nil, profile: "", key: ledgerID) }
        return ID(canonical: false, gateway: gatewayID, profile: profile, key: requestID)
    }

    public func approval(in snapshot: JSONValue) -> ApprovalRequest? {
        nativeApproval(in: snapshot)?.approval ?? legacyApproval(in: snapshot)
    }

    public func legacyApproval(in snapshot: JSONValue) -> ApprovalRequest? {
        guard kind == "approval", let request = openRequest(in: snapshot) else { return nil }
        return GatewayTurnDecoder.approval(from: request)
    }

    public func nativeApproval(in snapshot: JSONValue, generation: Int? = nil) -> NativeApproval? {
        guard kind == "approval", state == "open", !requestID.hasPrefix("srq-"), let sessionID,
              let prompt = Self.nativePrompt(in: snapshot, sessionID: sessionID, requestID: requestID,
                                             generation: generation, kind: kind),
              let offered = prompt["choices"]?.arrayValue,
              var approval: ApprovalRequest = try? RequestLedgerClient.decode(prompt),
              let generation = approval.executionGeneration else { return nil }
        approval.requestID = requestID
        approval.choices = approval.choices.filter { offered.contains(.string($0.rawValue)) }
        guard !approval.choices.isEmpty else { return nil }
        return NativeApproval(approval: approval, command: prompt["command"]?.stringValue, generation: generation,
                              isPlainCommand: prompt["tool_name"]?.stringValue == "terminal"
                                  && prompt["smart_denied"]?.boolValue == false && prompt["edit"] == nil)
    }

    public struct NativeApproval: Sendable {
        public let approval: ApprovalRequest
        public let command: String?
        public let generation: Int
        public let isPlainCommand: Bool
    }

    public static func nativePrompt(in snapshot: JSONValue, sessionID: String, requestID: String,
                                    generation: Int?, kind: String) -> JSONValue? {
        guard !sessionID.isEmpty, !requestID.isEmpty, snapshot["session_id"]?.stringValue == sessionID,
              let liveGeneration = snapshot["execution_generation"]?.doubleValue.flatMap(Int.init(exactly:)),
              liveGeneration >= 0, generation == nil || generation == liveGeneration else { return nil }
        let matches = snapshot["prompts"]?.arrayValue?.filter {
            $0["prompt_id"]?.stringValue == requestID && $0["kind"]?.stringValue == kind
                && $0["execution_generation"]?.doubleValue == Double(liveGeneration)
        } ?? []
        return matches.count == 1 ? matches[0] : nil
    }

    public func openRequest(in snapshot: JSONValue) -> GatewayServerRequest? {
        guard requestID.hasPrefix("srq-"), requestID.count > 4 else { return nil }
        for frame in snapshot["open_requests"]?.arrayValue ?? [] {
            guard frame["method"]?.stringValue == kind, frame["id"]?.stringValue == requestID,
                  let params = frame["params"] else { continue }
            return .init(id: requestID, method: kind, params: params)
        }
        return nil
    }

    public func frameClarificationChoice(in snapshot: JSONValue, questionID: String, shown: String, answer: String) -> JSONValue? {
        guard kind == "clarify", let sessionID, !sessionID.isEmpty,
              ["session_id", "stored_session_id", "resumed"].contains(where: { snapshot[$0]?.stringValue == sessionID }),
              let frame = openRequest(in: snapshot),
              let request = HermesRequest.parse(frame), case .clarify(let questions) = request.kind,
              questions.count == 1, let question = questions.first, question.id == questionID,
              question.question == shown, !question.multiSelect,
              frame.params["answers"]?[questionID] == nil, question.choices.contains(answer) else { return nil }
        return .object(["answers": .object([questionID: .string(answer)])])
    }

    enum CodingKeys: String, CodingKey {
        case ledgerID = "ledger_id", requestID = "request_id", gatewayID = "gateway_id"
        case profileID = "profile_id", sessionID = "session_id"
        case createdAt = "created_at", expiresAt = "expires_at", answeredAt = "answered_at", answeredBy = "answered_by"
        case settledAt = "settled_at"
        case profile, kind, state, prompt, choices, outcome
    }
}

public struct LedgerRouteCache<Route> {
    private var entries: [LedgerRow.ID: (gateway: UUID, route: Route)] = [:]
    private var removedGateways: Set<UUID> = []

    public init() {}

    public subscript(id: LedgerRow.ID) -> Route? { entries[id]?.route }

    public func gateway(for id: LedgerRow.ID) -> UUID? { entries[id]?.gateway }

    public mutating func set(_ route: Route, for id: LedgerRow.ID, gateway: UUID) {
        entries[id] = (gateway, route)
    }

    public mutating func replace(with refreshed: Self) {
        entries = refreshed.entries.filter { !removedGateways.contains($0.value.gateway) }
    }

    public mutating func remove(gateway: UUID) {
        removedGateways.insert(gateway)
        entries = entries.filter { $0.value.gateway != gateway }
    }
}

@MainActor
public final class LedgerRefresh {
    private var refreshing = false
    private var needsRefresh = false
    private var waiters: [CheckedContinuation<Bool, Never>] = []

    public init() {}

    public func refresh(_ scan: @MainActor () async -> Bool) async {
        guard !Task.isCancelled else { return }
        guard !refreshing else { needsRefresh = true; return }
        refreshing = true
        await run(scan)
    }

    public func waitForNextSnapshot(_ scan: @escaping @MainActor () async -> Bool) async {
        while !Task.isCancelled {
            let task: Task<Void, Never>?
            if refreshing {
                task = nil
            } else {
                refreshing = true
                task = Task { await run(scan) }
            }
            let published = await withTaskCancellationHandler {
                await withCheckedContinuation { waiters.append($0) }
            } onCancel: {
                task?.cancel()
            }
            if published { return }
        }
    }

    private func run(_ scan: @MainActor () async -> Bool) async {
        defer {
            refreshing = false
            resumeWaiters(published: false)
        }
        repeat {
            needsRefresh = false
            guard !Task.isCancelled, await scan() else { return }
            resumeWaiters(published: true)
        } while needsRefresh
    }

    private func resumeWaiters(published: Bool) {
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume(returning: published) }
    }
}

public struct LedgerSource: Decodable, Sendable, Equatable, Identifiable {
    public enum State: String, Decodable, Sendable {
        case live, unsupported, offline, notAuthorized = "not_authorized", error
    }

    public struct ID: Hashable, Sendable {
        public let gatewayID: String
        public let profileID: String?

        public init(gatewayID: String, profileID: String?) {
            self.gatewayID = gatewayID
            self.profileID = profileID
        }
    }

    public let gatewayID: String
    public let profileID: String?
    public let state: State

    public var id: ID { ID(gatewayID: gatewayID, profileID: profileID) }

    public init(id: ID, state: State) {
        gatewayID = id.gatewayID
        profileID = id.profileID
        self.state = state
    }

    enum CodingKeys: String, CodingKey {
        case gatewayID = "gateway_id", profileID = "profile_id", state = "status"
    }
}

public struct LedgerSnapshot: Decodable, Sendable, Equatable {
    public let open: [LedgerRow]
    public let recent: [LedgerRow]
    public let openCount: Int
    public let sources: [LedgerSource]?

    public init(open: [LedgerRow], recent: [LedgerRow], openCount: Int, sources: [LedgerSource]?) {
        self.open = open
        self.recent = recent
        self.openCount = openCount
        self.sources = sources
    }

    enum CodingKeys: String, CodingKey {
        case open, recent, sources, openCount = "open_count"
    }

    public static func merge(_ snapshots: [Self]) -> Self {
        let recent = unique(snapshots.flatMap(\.recent).sorted {
            ($0.settledAt ?? $0.answeredAt ?? $0.createdAt) > ($1.settledAt ?? $1.answeredAt ?? $1.createdAt)
        })
        let settled = Set(recent.map(\.id))
        let open = unique(snapshots.flatMap(\.open).sorted { $0.createdAt < $1.createdAt }).filter { !settled.contains($0.id) }
        var seen = Set<LedgerSource.ID>()
        let sources = snapshots.flatMap { $0.sources ?? [] }.filter { seen.insert($0.id).inserted }
        return Self(open: open, recent: recent, openCount: open.count, sources: sources)
    }

    static func unique(_ rows: [LedgerRow]) -> [LedgerRow] {
        var seen = Set<LedgerRow.ID>()
        return rows.filter { seen.insert($0.id).inserted }
    }
}

public struct LedgerHistory: Decodable, Sendable, Equatable {
    public static let closedStates = ["answered", "expired", "withdrawn", "cancelled", "lost_on_restart"]

    public let requests: [LedgerRow]
    public let nextBefore: TimeInterval?
    public let sources: [LedgerSource]?

    enum CodingKeys: String, CodingKey {
        case requests, nextBefore = "next_before", sources
    }
}

public struct FederatedLedgerHistory: Decodable, Sendable, Equatable {
    public let requests: [LedgerRow]
    public let nextBefore: String?
    public let sources: [LedgerSource]

    enum CodingKeys: String, CodingKey {
        case requests, nextBefore = "next_before", sources
    }
}

public struct LedgerSettlement: Decodable, Sendable, Equatable {
    public let ledgerID: String
    public let outcome: String?
    public let answeredBy: LedgerAnswerer?

    enum CodingKeys: String, CodingKey {
        case ledgerID = "ledger_id", outcome, answeredBy = "answered_by"
    }
}

public enum LedgerAnswer: Sendable, Equatable {
    case accepted(LedgerAnswerer?)
    case noLongerPending(LedgerSettlement?)
}

public enum ExactClarifyAnswer {
    public static func questions(in ledger: LedgerSnapshot, ledgerID: String) -> [JSONValue]? {
        let matches = ledger.open.filter { $0.ledgerID == ledgerID && $0.kind == "clarify" }
        return matches.count == 1 ? matches.first?.choices : nil
    }

    public static func request(in snapshot: JSONValue, requestID: String) -> GatewayServerRequest? {
        guard case .array(let open)? = snapshot["open_requests"] else { return nil }
        let matches = open.compactMap { row -> GatewayServerRequest? in
            guard let id = row["id"]?.stringValue, !id.isEmpty, row["method"]?.stringValue == "clarify",
                  let params = row["params"] else { return nil }
            guard id == requestID else { return nil }
            return GatewayServerRequest(id: id, method: "clarify", params: params)
        }
        return matches.count == 1 ? matches.first : nil
    }
}

public struct RequestLedgerClient: Sendable {
    public typealias Transport = @Sendable (String, [String: JSONValue]) async throws -> JSONValue
    public typealias FederatedRead = @Sendable () async throws -> LedgerSnapshot?

    public struct Source: Sendable {
        public let id: LedgerSource.ID
        public let client: RequestLedgerClient
        /// The existing per-chat snapshots for this profile, fetched only when the ledger is unsupported.
        public let legacy: @Sendable () async throws -> [LedgerRow]

        public init(id: LedgerSource.ID, client: RequestLedgerClient, legacy: @escaping @Sendable () async throws -> [LedgerRow]) {
            self.id = id
            self.client = client
            self.legacy = legacy
        }
    }

    private let transport: Transport

    public init(transport: @escaping Transport) { self.transport = transport }

    public func list(profile: String, gatewayID: String) async throws -> LedgerSnapshot {
        let json = try await transport("request.list", ["profile": .string(profile)])
        let list: LedgerSnapshot = try Self.decode(Self.routed(json, keys: ["open", "recent"], gatewayID: gatewayID, profile: profile))
        return LedgerSnapshot(open: list.open, recent: list.recent, openCount: list.openCount,
                              sources: [LedgerSource(id: .init(gatewayID: gatewayID, profileID: profile), state: .live)])
    }

    public func history(profile: String, gatewayID: String, before: TimeInterval? = nil, limit: Int = 50) async throws -> LedgerHistory {
        var params: [String: JSONValue] = ["profile": .string(profile), "limit": .number(Double(limit)),
                                           "states": .array(LedgerHistory.closedStates.map(JSONValue.string))]
        if let before { params["before"] = .number(before) }
        let json = try await transport("request.history", params)
        return try Self.decode(Self.routed(json, keys: ["requests"], gatewayID: gatewayID, profile: profile))
    }

    public func answer(ledgerID: String, profile: String?, result: [String: JSONValue]) async throws -> LedgerAnswer {
        guard !ledgerID.isEmpty else { throw HermesError.invalidResponse("missing request id") }
        var params: [String: JSONValue] = ["id": .string(ledgerID), "result": .object(result)]
        if let profile { params["profile"] = .string(profile) }
        do {
            let reply = try await transport("request.answer", params)
            switch reply["status"]?.stringValue {
            case "ok":
                return .accepted(try reply["answered_by"].flatMap { $0 == .null ? nil : try Self.decode($0) })
            case "expired":
                return .noLongerPending(nil)
            default:
                throw HermesError.invalidResponse("request.answer")
            }
        } catch let error as GatewayRPCError where error.code == 4065 && error.message == "no longer pending" {
            let settlement: LedgerSettlement? = error.data?["settlement"].flatMap { try? Self.decode($0) }
            return .noLongerPending(settlement.flatMap { $0.ledgerID == ledgerID ? $0 : nil })
        }
    }

    /// Uses the box view when present. An unavailable or refused box isn't evidence of an empty inbox.
    public static func snapshot(sources: [Source], federated: FederatedRead? = nil) async throws -> LedgerSnapshot {
        let box = try await federated?()
        let covered = Dictionary((box?.sources ?? []).map { ($0.id, $0.state) }, uniquingKeysWith: { first, _ in first })
        let local = sources.filter { covered[$0.id] == nil || covered[$0.id] == .unsupported }
        let snapshots = await withTaskGroup(of: LedgerSnapshot.self) { group in
            for source in local {
                guard let profile = source.id.profileID else { continue }
                group.addTask {
                    if covered[source.id] == .unsupported { return await fallback(source) }
                    do {
                        return try await source.client.list(profile: profile, gatewayID: source.id.gatewayID)
                    } catch let error as GatewayRPCError where error.code == -32601 {
                        return await fallback(source)
                    } catch {
                        return status(source, state(of: error))
                    }
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        try Task.checkCancellation()
        return LedgerSnapshot.merge((box.map { [$0] } ?? []) + snapshots)
    }

    private static func fallback(_ source: Source) async -> LedgerSnapshot {
        do {
            let open = try await source.legacy()
            return LedgerSnapshot(open: open, recent: [], openCount: open.count,
                                  sources: [LedgerSource(id: source.id, state: .unsupported)])
        } catch {
            return status(source, state(of: error))
        }
    }

    private static func status(_ source: Source, _ state: LedgerSource.State) -> LedgerSnapshot {
        LedgerSnapshot(open: [], recent: [], openCount: 0, sources: [LedgerSource(id: source.id, state: state)])
    }

    public static func state(of error: any Error) -> LedgerSource.State {
        switch error {
        case let error as GatewayRPCError where [401, 403, 4401, 4403].contains(error.code): .notAuthorized
        case BackendClient.Failure.signInRequired, BackendClient.Failure.http(403, _),
             HermesError.unauthorized, HermesError.accessRefused: .notAuthorized
        case let error as GatewayRPCError where [502, 503, 504].contains(error.code): .offline
        case GatewaySocket.Failure.notConnected, GatewaySocket.Failure.closed, HermesError.unreachable,
             BackendClient.Failure.http(502...504, _), is URLError: .offline
        default: .error
        }
    }

    public static func scanLegacyRequests(
        source: LedgerSource.ID, request: Transport
    ) async throws -> (rows: [LedgerRow], failure: LedgerSource.State?) {
        guard let profile = source.profileID else { return ([], nil) }
        let listing = try await request("session.list", [
            "profile": .string(profile), "limit": .number(200), "include_hidden": .bool(true),
        ])
        var rows: [LedgerRow] = []
        var failure: LedgerSource.State?
        for session in listing["sessions"]?.arrayValue ?? [] {
            try Task.checkCancellation()
            guard let key = session["resolved_id"]?.stringValue ?? session["id"]?.stringValue else { continue }
            do {
                let snapshot = try await request("session.resume", [
                    "session_id": .string(key), "profile": .string(profile), "omit_messages": .bool(true),
                ])
                rows += legacyRows(snapshot: snapshot, sessionID: key, source: source)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if failure == nil { failure = state(of: error) }
            }
        }
        return (rows, failure)
    }

    public static func legacyRows(snapshot: JSONValue, sessionID: String, source: LedgerSource.ID) -> [LedgerRow] {
        guard let profile = source.profileID, case .array(let open)? = snapshot["open_requests"] else { return [] }
        return open.compactMap { frame in
            guard let id = frame["id"]?.stringValue, let method = frame["method"]?.stringValue else { return nil }
            let params = frame["params"]
            let prompt = method == "approval" ? params?["command"] : nil
            return try? decode(.object([
                "request_id": .string(id), "kind": .string(method), "state": .string("open"),
                "session_id": .string(sessionID), "profile": .string(profile),
                "profile_id": .string(profile), "gateway_id": .string(source.gatewayID),
                "created_at": .number(0), "expires_at": params?["expires_at"] ?? .null, "prompt": prompt ?? .null,
            ]))
        }
    }

    static func decode<T: Decodable>(_ json: JSONValue) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(json))
    }

    private static func routed(_ json: JSONValue, keys: [String], gatewayID: String, profile: String) -> JSONValue {
        guard case .object(var object) = json else { return json }
        for key in keys {
            guard case .array(let rows)? = object[key] else { continue }
            object[key] = .array(rows.map { row in
                guard case .object(var fields) = row else { return row }
                fields["gateway_id"] = .string(gatewayID)
                fields["profile_id"] = .string(profile)
                return .object(fields)
            })
        }
        return .object(object)
    }
}

extension BackendClient {
    public func federatedLedger() async throws -> LedgerSnapshot? {
        do {
            return try RequestLedgerClient.decode(try await boxLedger("bff/ledger"))
        } catch Failure.http(let status, _) where [404, 405, 501].contains(status) {
            return nil
        }
    }

    public func federatedLedgerHistory(before: String? = nil, limit: Int = 50) async throws -> FederatedLedgerHistory? {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let before { query.append(URLQueryItem(name: "before", value: before)) }
        do {
            return try RequestLedgerClient.decode(try await boxLedger("bff/ledger/history", query: query))
        } catch Failure.http(let status, _) where [404, 405, 501].contains(status) {
            return nil
        }
    }
}
