import ActivityKit
import AppIntents
import HermesActivityKit
import SwiftUI
import WidgetKit

/// Approvals and questions on the lock screen, with the seconds that remain, the command or question
/// clipped, and buttons that answer without opening the app. A tap opens the Waiting list.
struct NeoRequestLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RequestActivityAttributes.self) { context in
            RequestLockScreenView(presentation: RequestActivityPresentation(context.state), isStale: context.isStale)
                .padding(16)
                .widgetURL(ActivityLink.waiting.url)
        } dynamicIsland: { context in
            let presentation = RequestActivityPresentation(context.state)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    RequestLeadingIcon(presentation: presentation, markSize: 28)
                        .font(.title2)
                        .accessibilityHidden(true)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    RequestCountdownView(presentation: presentation)
                        .font(.title3.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(presentation.title)
                        .font(.headline)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        if !presentation.body.isEmpty {
                            Text(presentation.body)
                                .font(.subheadline)
                                .lineLimit(2)
                        }
                        RequestButtons(presentation: presentation, isStale: context.isStale)
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
            .widgetURL(ActivityLink.waiting.url)
        }
    }
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
                    .lineLimit(2)
                Spacer(minLength: 8)
                if !isStale { RequestCountdownView(presentation: presentation).font(.headline.monospacedDigit()) }
            }
            if !presentation.body.isEmpty {
                Text(presentation.body)
                    .font(.subheadline)
                    .lineLimit(3)
            }
            if isStale && presentation.state.outcome == nil {
                Text("Not updating. Open Hermes Bot to answer.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let more = presentation.moreLine {
                Text(more)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            RequestButtons(presentation: presentation, isStale: isStale)
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
        let actions = presentation.actions.filter { isStale ? $0 == .openToAnswer : true }
        if !actions.isEmpty {
            HStack(spacing: 8) {
                ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                    switch action {
                    case .approve:
                        Button(intent: NeoApproveRequestIntent(botKey: state.botKey, requestId: state.requestId)) {
                            label(for: action, symbol: "checkmark")
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityLabel(presentation.accessibilityLabel(for: action))
                    case .deny:
                        Button(role: .destructive, intent: NeoDenyRequestIntent(botKey: state.botKey, requestId: state.requestId)) {
                            label(for: action, symbol: "xmark")
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel(presentation.accessibilityLabel(for: action))
                    case .choice(_, let choice):
                        Button(intent: NeoAnswerChoiceIntent(botKey: state.botKey, requestId: state.requestId, questionId: state.questionId ?? "", choice: choice)) {
                            label(for: action, symbol: nil)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel(presentation.accessibilityLabel(for: action))
                    case .openToAnswer:
                        Link(destination: ActivityLink.waiting.url) {
                            label(for: action, symbol: "arrow.up.forward.app")
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel(presentation.accessibilityLabel(for: action))
                    }
                }
            }
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
        .frame(maxWidth: .infinity, minHeight: 44)
    }
}
