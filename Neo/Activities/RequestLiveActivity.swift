import ActivityKit
import AppIntents
import HermesActivityKit
import HermesPush
import SwiftUI
import WidgetKit

/// Approvals and questions on the lock screen, with the seconds that remain, the command or question
/// clipped, and buttons that answer without opening the app. A tap opens the Waiting list.
struct NeoRequestLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RequestActivityAttributes.self) { context in
            RequestLockScreenView(presentation: RequestActivityPresentation(context.state), isStale: context.isStale)
                .padding(16)
                .widgetURL(requestLink(context.state).url)
        } dynamicIsland: { context in
            let presentation = RequestActivityPresentation(context.state)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    RequestLeadingIcon(presentation: presentation, markSize: 28)
                        .font(.title2)
                        .accessibilityHidden(true)
                }
                DynamicIslandExpandedRegion(.trailing, priority: 1) {
                    RequestCountdownView(presentation: presentation)
                        .font(.title3.monospacedDigit())
                        .fixedSize(horizontal: true, vertical: false)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(presentation.title)
                        .font(.headline)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        RequestButtons(presentation: presentation, isStale: context.isStale)
                            .frame(maxHeight: 108)
                    }
                }
            } compactLeading: {
                RequestLeadingIcon(presentation: presentation)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(presentation.accessibilityLabel(now: Date()))
            } compactTrailing: {
                RequestCountdownView(presentation: presentation)
                    .font(.caption.monospacedDigit())
                    .frame(maxWidth: 52)
            } minimal: {
                RequestLeadingIcon(presentation: presentation)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(presentation.accessibilityLabel(now: Date()))
            }
            .widgetURL(requestLink(context.state).url)
        }
    }
}

private func requestLink(_ state: RequestActivityAttributes.ContentState) -> ActivityLink {
    if let reference = RequestReference(state) { return .request(reference) }
    if !state.botKey.isEmpty, !state.requestId.isEmpty { return .lookup(botKey: state.botKey, requestId: state.requestId) }
    return state.botKey.isEmpty ? .waiting : .bot(key: state.botKey)
}

/// The leading icon: the app's mark while the request waits (the title says whether it is an approval, a question or
/// a prompt for the computer), the result's symbol once it is finished.
struct RequestLeadingIcon: View {
    let presentation: RequestActivityPresentation
    var markSize: CGFloat = 20

    var body: some View {
        if let symbol = presentation.outcomeSymbol {
            Image(systemName: symbol)
        } else {
            NeoActivityMark(size: markSize)
        }
    }
}

/// The seconds that remain, counting down by itself from the gateway's deadline; the word "Waiting" when the
/// deadline is unknown; nothing for a finished request.
struct RequestCountdownView: View {
    let presentation: RequestActivityPresentation

    var body: some View {
        switch presentation.countdown {
        case .timer(let range):
            Text(timerInterval: range, countsDown: true, showsHours: false)
                .multilineTextAlignment(.trailing)
        case .waiting:
            Text(RequestActivityPresentation.waitingWord)
        case .none:
            EmptyView()
        }
    }
}

struct RequestLockScreenView: View {
    let presentation: RequestActivityPresentation
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                RequestLeadingIcon(presentation: presentation)
                    .accessibilityHidden(true)
                Text(presentation.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if !isStale { RequestCountdownView(presentation: presentation).font(.headline.monospacedDigit()) }
            }
            if isStale && presentation.state.outcome == nil {
                Text("Not updating. Open Hermes Neo to answer.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            RequestButtons(presentation: presentation, isStale: isStale)
                .frame(maxHeight: 100)
        }
        .accessibilityElement(children: .contain)
    }
}

/// Approve once and Deny, a question's choices (up to three), or "Open to answer" as a link. Buttons are
/// hidden while stale: a stale request may be gone, so the app is the place to answer.
struct RequestButtons: View {
    let presentation: RequestActivityPresentation
    let isStale: Bool

    var body: some View {
        let state = presentation.state
        #if DEBUG && targetEnvironment(simulator)
        let demo = state.botKey == "demo::hermes" && state.requestId == "demo-answer-request"
        #else
        let demo = false
        #endif
        let actions = presentation.actions(lockScreenAnswersEnabled: demo || NotificationCatalog.neoLockScreenAnswersEnabled, isStale: isStale)
        ViewThatFits(in: .vertical) {
            RequestActionContent(presentation: presentation, actions: actions, full: true)
                .fixedSize(horizontal: false, vertical: true)
            RequestActionContent(presentation: presentation, actions: fallback(for: actions), full: false)
        }
    }

    private func fallback(for actions: [RequestActivityPresentation.Action]) -> [RequestActivityPresentation.Action] {
        if actions.isEmpty { return [] }
        return actions.contains(.typeAnAnswer) ? [.typeAnAnswer] : [.openToAnswer]
    }
}

private struct RequestActionContent: View {
    let presentation: RequestActivityPresentation
    let actions: [RequestActivityPresentation.Action]
    let full: Bool

    private var shown: String {
        actions.contains(.approve) ? presentation.state.command ?? "" : presentation.body
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !shown.isEmpty {
                Text(VisibleText.of(shown))
                    .font(.subheadline)
                    .lineLimit(full && actions.contains(where: \.isInlineAnswer) ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if actions.contains(where: \.isInlineAnswer) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 4) {
                        inlineButton(at: 0)
                        inlineButton(at: 1)
                        inlineButton(at: 2)
                        if actions.contains(.typeAnAnswer) {
                            Link(destination: requestLink(presentation.state).url) {
                                Text(presentation.title(for: .typeAnAnswer))
                                    .font(.caption)
                                    .frame(minHeight: 32)
                            }
                            .accessibilityLabel(presentation.accessibilityLabel(for: .typeAnAnswer))
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    button(for: actions.contains(.typeAnAnswer) ? .typeAnAnswer : .openToAnswer)
                }
            } else if let action = actions.first {
                button(for: action)
            }
        }
    }

    @ViewBuilder
    private func inlineButton(at index: Int) -> some View {
        if actions.indices.contains(index), actions[index].isInlineAnswer { button(for: actions[index]) }
    }

    @ViewBuilder
    private func button(for action: RequestActivityPresentation.Action) -> some View {
        switch action {
        case .approve, .deny, .choice:
            if let reference = RequestReference(presentation.state), let text = presentation.textToVerify(for: action) {
                Button(intent: NeoAnswerRequestIntent(reference: reference, shown: text, action: action)) {
                    label(for: action, symbol: action == .approve ? "checkmark" : action == .deny ? "xmark" : nil)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(presentation.accessibilityLabel(for: action))
            }
        case .openToAnswer, .typeAnAnswer:
            Link(destination: requestLink(presentation.state).url) {
                label(for: action, symbol: "arrow.up.forward.app")
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(presentation.accessibilityLabel(for: action))
        }
    }

    @ViewBuilder
    private func label(for action: RequestActivityPresentation.Action, symbol: String?) -> some View {
        Group {
            if let symbol {
                Label(presentation.title(for: action), systemImage: symbol)
            } else {
                Text(presentation.title(for: action))
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(minHeight: 32)
    }
}

private extension RequestActivityPresentation.Action {
    var isInlineAnswer: Bool {
        switch self {
        case .approve, .deny, .choice: true
        case .openToAnswer, .typeAnAnswer: false
        }
    }
}
