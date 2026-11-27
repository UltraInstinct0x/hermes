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
    private(set) var requestsRevision: String?

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

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let revision = applicationContext["requestsRevision"] as? String else { return }
        Task { @MainActor [weak self] in self?.requestsRevision = revision }
    }

    private func updateReachability() {
        reachable = WCSession.default.activationState == .activated && WCSession.default.isReachable
        if WCSession.default.activationState == .activated,
           let revision = WCSession.default.receivedApplicationContext["requestsRevision"] as? String {
            requestsRevision = revision
        }
    }

    func send(_ request: WatchCompanion.Request) async -> WatchCompanion.Response? {
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

    func checkRequests(id: UUID) async -> WatchCompanion.Response? {
        let deadline = ContinuousClock.now + .seconds(45)
        while !Task.isCancelled && ContinuousClock.now < deadline {
            let response = await send(.openRequests(id))
            guard response == .checkingRequests else { return response }
            try? await Task.sleep(for: .seconds(1))
        }
        return .unavailable
    }

    #if DEBUG
    private var fixtureSettled: Set<WatchCompanion.RequestCard.ID> = []

    private var fixtureCards: [WatchCompanion.RequestCard] {
        [
            .init(requestID: "srq-backup", source: "Ops · Backups",
                  content: .approval(command: "tar -czf backup.tar.gz reports/", decisions: [.once, .deny])),
            .init(requestID: "srq-report", source: "Research Buddy",
                  content: .clarify([.init(id: "format", prompt: "Which format for the report?", choices: ["PDF", "Markdown"])]))
        ]
    }

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
        case .openRequests:
            if UserDefaults.standard.bool(forKey: "HERMES_WATCH_SLOW_REQUESTS"),
               fixtureCheckCount < 3 {
                fixtureCheckCount += 1
                return .checkingRequests
            }
            return .openRequests(fixtureCards.filter { !fixtureSettled.contains($0.id) }, incomplete: false)
        case .answer(let card, let answer):
            guard fixtureCards.contains(card), card.result(for: answer) != nil else { return .answer(.invalidAnswer) }
            guard fixtureSettled.insert(card.id).inserted else { return .answer(.noLongerPending) }
            return .answer(answer == .approval(.deny) ? .noLongerPending : .sent)
        }
    }
    private var fixtureCheckCount = 0
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
                NavigationLink("Requests") { WatchRequestList(phone: phone) }
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
            let result = await phone.send(.roster)
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
                case .unavailable, .roster, .checkingRequests, .openRequests, .answer:
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
            let result = await phone.send(.latestReply(bot.id))
            if !Task.isCancelled { response = result ?? .unavailable }
        }
    }
}

private struct WatchRequestList: View {
    let phone: WatchLink
    @State private var response: WatchCompanion.Response?
    @State private var retry = 0
    @State private var previousRead: ReadTrigger?
    @Environment(\.scenePhase) private var phase

    var body: some View {
        List {
            switch response {
            case .openRequests(let cards, let incomplete):
                if incomplete {
                    Text("Some requests couldn’t be checked.").foregroundStyle(.secondary)
                } else if cards.isEmpty {
                    Text("No open requests.").foregroundStyle(.secondary)
                }
                ForEach(cards) { card in
                    NavigationLink {
                        WatchRequestDetail(card: card, phone: phone) { retry += 1 }
                    } label: {
                        VStack(alignment: .leading) {
                            Text(heading(for: card)).font(.headline).lineLimit(2)
                            Text(card.source).font(.footnote).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    .accessibilityIdentifier("watchRequest-\(card.id.requestID)")
                }
                Button("Refresh") { retry += 1 }
            case nil, .checkingRequests:
                Text("Checking requests…").foregroundStyle(.secondary)
            default:
                if phone.reachable {
                    Text("Couldn’t check requests. Try again.").foregroundStyle(.secondary)
                } else {
                    Text("Can’t reach Hermes on your iPhone.").foregroundStyle(.secondary)
                }
                Button("Retry") { retry += 1 }
            }
        }
        .navigationTitle("Requests")
        .task(id: readTrigger) { [trigger = readTrigger] in
            guard trigger.active else { return }
            let revision = trigger.requestsRevision
            let publishedID = previousRead.flatMap {
                $0.retry == trigger.retry && $0.requestsRevision != revision ? revision.flatMap(UUID.init(uuidString:)) : nil
            }
            previousRead = trigger
            response = nil
            let result = await phone.checkRequests(id: publishedID ?? UUID())
            if !Task.isCancelled { response = result ?? .unavailable }
        }
    }

    private var readTrigger: ReadTrigger {
        ReadTrigger(reachable: phone.reachable, active: phase == .active, retry: retry, requestsRevision: phone.requestsRevision)
    }

    private func heading(for card: WatchCompanion.RequestCard) -> String {
        switch card.content {
        case .approval, .openOnPhone(isApproval: true):
            String(localized: "Approval needed")
        case .clarify(let questions):
            questions.first?.prompt ?? String(localized: "Question")
        case .openOnPhone(isApproval: false):
            String(localized: "Question")
        }
    }
}

private struct WatchRequestDetail: View {
    let card: WatchCompanion.RequestCard
    let phone: WatchLink
    let refreshRequests: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var sending = false
    @State private var status: WatchCompanion.AnswerStatus?
    @State private var submitted: WatchCompanion.RequestAnswer?
    @State private var answers: [String: WatchCompanion.ClarifyAnswer] = [:]
    @State private var step = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if sending {
                    Text("Sending answer…").font(.headline)
                } else if let status {
                    Text(receipt(status)).font(.headline)
                        .accessibilityIdentifier("watchAnswerStatus")
                    Text(card.source).font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("watchAnswerSource")
                    if status == .sent, let submitted {
                        receiptDetails(submitted)
                    }
                    Button("Back to Requests") {
                        dismiss()
                        refreshRequests()
                    }
                } else {
                    Text(card.source).font(.footnote).foregroundStyle(.secondary)
                    switch card.content {
                    case .approval(let command, let decisions):
                        Text("Approval needed").font(.headline)
                        Text(command).font(.footnote.monospaced())
                            .fixedSize(horizontal: false, vertical: true)
                        if decisions.contains(.once) {
                            Button("Allow Once") { send(.approval(.once)) }.buttonStyle(.borderedProminent)
                        }
                        if decisions.contains(.deny) {
                            Button("Deny", role: .destructive) { send(.approval(.deny)) }
                        }
                    case .clarify(let questions):
                        if questions.indices.contains(step) { clarify(questions) }
                    case .openOnPhone:
                        Text("Open the request on your iPhone to review and answer it.").font(.footnote)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Request")
    }

    private func clarify(_ questions: [WatchCompanion.RequestCard.Question]) -> some View {
        let question = questions[step]
        let last = step == questions.count - 1
        return VStack(alignment: .leading, spacing: 8) {
            if questions.count > 1 {
                Text("Question \(step + 1) of \(questions.count)").font(.footnote).foregroundStyle(.secondary)
            }
            Text(question.prompt).font(.headline)
            ForEach(question.choices.indices, id: \.self) { index in
                let choice = question.choices[index]
                let chosen = isSelected(choice, for: question)
                Button { pick(choice, for: question) } label: {
                    HStack {
                        if chosen {
                            Image(systemName: "checkmark").accessibilityHidden(true)
                        }
                        Text(choice)
                    }
                }
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }
            if !question.multiSelect {
                TextField(question.choices.isEmpty ? "Your answer" : "Other answer", text: typedAnswer(for: question))
            }
            Button(last ? "Send" : "Next") {
                if last { send(.clarify(answers)) } else { step += 1 }
            }
            .buttonStyle(.borderedProminent)
            .disabled(answers[question.id] == nil)
            if step > 0 { Button("Previous question") { step -= 1 } }
        }
        .id(question.id)
    }

    private func typedAnswer(for question: WatchCompanion.RequestCard.Question) -> Binding<String> {
        Binding {
            guard case .text(let text) = answers[question.id], !question.choices.contains(text) else { return "" }
            return text
        } set: { value in
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            answers[question.id] = text.isEmpty ? nil : .text(value)
        }
    }

    private func isSelected(_ choice: String, for question: WatchCompanion.RequestCard.Question) -> Bool {
        switch answers[question.id] {
        case .text(let value): value == choice
        case .choices(let values): values.contains(choice)
        case nil: false
        }
    }

    private func pick(_ choice: String, for question: WatchCompanion.RequestCard.Question) {
        guard question.multiSelect else {
            answers[question.id] = .text(choice)
            return
        }
        var selected = question.choices.filter { isSelected($0, for: question) }
        if selected.contains(choice) { selected.removeAll { $0 == choice } } else { selected.append(choice) }
        answers[question.id] = selected.isEmpty ? nil : .choices(selected)
    }

    private func send(_ answer: WatchCompanion.RequestAnswer) {
        guard !sending, status == nil, card.result(for: answer) != nil else { return }
        sending = true
        Task {
            if case .answer(let result) = await phone.send(.answer(card, answer)) {
                submitted = answer
                status = result
            } else {
                status = .unavailable
            }
            sending = false
        }
    }

    @ViewBuilder
    private func receiptDetails(_ answer: WatchCompanion.RequestAnswer) -> some View {
        switch answer {
        case .approval(.once):
            Text("Allowed once").accessibilityIdentifier("watchSubmittedAnswer")
        case .approval(.deny):
            Text("Denied").accessibilityIdentifier("watchSubmittedAnswer")
        case .clarify:
            if case .clarify(let questions) = card.content, let result = card.result(for: answer)?["answers"] {
                ForEach(questions) { question in
                    if let value = result[question.id] {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(question.prompt).font(.footnote).foregroundStyle(.secondary)
                            Text(value.stringValue ?? (value.arrayValue ?? []).compactMap(\.stringValue).joined(separator: ", "))
                                .accessibilityIdentifier("watchSubmittedAnswer")
                        }
                    }
                }
            }
        }
    }

    private func receipt(_ status: WatchCompanion.AnswerStatus) -> LocalizedStringKey {
        switch status {
        case .sent: "Answer sent"
        case .noLongerPending: "This request changed or is no longer pending."
        case .invalidAnswer: "This answer couldn’t be sent. Refresh Requests."
        case .unavailable: "Couldn’t confirm the answer. Refresh Requests."
        }
    }
}

private struct ReadTrigger: Equatable {
    let reachable: Bool
    let active: Bool
    let retry: Int
    var requestsRevision: String? = nil
}
