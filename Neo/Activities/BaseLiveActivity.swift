import ActivityKit
import AppIntents
import HermesActivityKit
import HermesAvatarUI
import SwiftUI
import WidgetKit

/// The always-on "Hermes Bot" bubble (S22): machines online, requests waiting and the last event with its age, and
/// the call bubble (state, elapsed time, Mute, End) while a call runs. The lock screen and banner are the layouts that
/// matter on an iPhone without a Dynamic Island (the owner's 12 mini); the island layouts are for other phones.
///
/// S25: while sessions work (and no call runs) the idle lines give way to at most two compact rows,
/// `<bot>  <elapsed>  <what it does>`, plus "+N more" and a small waiting hint; the elapsed time counts natively with
/// `Text(timerInterval:)`, so no push is needed for the clock. Approval cards never enter this bubble.
///
/// Every word comes from `BaseActivityPresentation`. Ages count by themselves (`Text(_, style: .relative)`), so the
/// bubble never shows a frozen "3 min ago"; once the box stops refreshing it, iOS marks the activity stale and it
/// says "Not updating".
struct NeoBaseLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: BaseActivityAttributes.self) { context in
            BaseLockScreenView(state: context.state, isStale: context.isStale)
                .padding(16)
                .widgetURL(link(for: context.state))
        } dynamicIsland: { context in
            let presentation = BaseActivityPresentation(context.state)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    NeoBrandedTitle(title: presentation.title)
                        .font(.headline)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    BaseTrailingFigure(state: context.state)
                        .font(.headline.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.isStale ? "Not updating" : (presentation.isCall ? presentation.callSubtitle : (presentation.runningRows.first?.line ?? presentation.waitingLine)))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if presentation.isCall {
                        BaseCallControls(presentation: presentation, isStale: context.isStale)
                    } else if presentation.isWorking, !context.isStale {
                        BaseWorkingDetail(presentation: presentation)
                    } else {
                        BaseIdleDetail(state: context.state, isStale: context.isStale)
                    }
                }
            } compactLeading: {
                BaseIslandIcon(isCall: presentation.isCall)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(presentation.accessibilityLabel(now: Date()))
            } compactTrailing: {
                BaseTrailingFigure(state: context.state)
                    .font(.caption.monospacedDigit())
                    .frame(maxWidth: 52)
            } minimal: {
                BaseIslandIcon(isCall: presentation.isCall)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(presentation.accessibilityLabel(now: Date()))
            }
            .widgetURL(link(for: context.state))
        }
    }

    private func link(for state: BaseActivityAttributes.ContentState) -> URL {
        if state.mode == .call, let call = state.call { return ActivityLink.call(botKey: call.botKey).url }
        return ActivityLink.waiting.url
    }
}

/// The island's one small icon: the app's mark, or the phone while a call runs (there the symbol says "a call").
struct BaseIslandIcon: View {
    let isCall: Bool

    var body: some View {
        if isCall {
            Image(systemName: "phone.fill")
        } else {
            NeoActivityMark(size: 18)
        }
    }
}

/// The island's trailing figure: the call timer, the longest running session's elapsed time, or how many requests
/// wait (nothing when none).
struct BaseTrailingFigure: View {
    let state: BaseActivityAttributes.ContentState

    var body: some View {
        let presentation = BaseActivityPresentation(state)
        if state.mode == .call, let start = presentation.callStart {
            Text(start, style: .timer)
        } else if let first = presentation.runningRows.first {
            Text(timerInterval: first.start...Date.distantFuture, countsDown: false)
        } else if state.waiting > 0 {
            Text("\(state.waiting)")
        } else {
            EmptyView()
        }
    }
}

struct BaseLockScreenView: View {
    let state: BaseActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        let presentation = BaseActivityPresentation(state)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                NeoBrandedTitle(title: presentation.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                if presentation.isCall, let start = presentation.callStart {
                    Text(start, style: .timer).font(.headline.monospacedDigit())
                }
            }
            if presentation.isCall {
                Text(isStale ? "Not updating" : presentation.callSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                BaseCallControls(presentation: presentation, isStale: isStale)
            } else if presentation.isWorking, !isStale {
                BaseWorkingDetail(presentation: presentation)
            } else {
                BaseIdleDetail(state: state, isStale: isStale)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// S25: what works right now, compact and calm: at most two rows, "+N more", and a waiting hint (never a card).
/// Hidden once the bubble is stale: a timer for a session nobody confirms any more would not be honest.
struct BaseWorkingDetail: View {
    let presentation: BaseActivityPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(presentation.runningRows) { row in
                BaseRunningRowView(row: row)
            }
            let extras = [presentation.runningMoreLine, presentation.waitingHint].compactMap { $0 }
            if !extras.isEmpty {
                Text(extras.joined(separator: ". "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel(now: Date()))
    }
}

/// One row: `<bot>  <elapsed, counting by itself>  <what it does>`, a single line.
struct BaseRunningRowView: View {
    let row: BaseActivityPresentation.RunningRow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if row.isTasks {
                Image(systemName: "person.2.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            } else {
                // The working bot's own face, one still frame (a Live Activity cannot animate).
                BloubStill(profile: bloubProfile(fromKey: row.botKey), status: .working, size: 18)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 4 }
            }
            Text(row.botName)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text(timerInterval: row.start...Date.distantFuture, countsDown: false)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(maxWidth: 64, alignment: .leading)
            Text(row.line)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel(now: Date()))
    }
}

/// The idle lines: waiting, the last event with a self-counting age, machines; the age of the bubble only when stale.
struct BaseIdleDetail: View {
    let state: BaseActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        let presentation = BaseActivityPresentation(state)
        VStack(alignment: .leading, spacing: 4) {
            // First what needs the owner (the brightest line), then the last event with a self-counting age, then the machines.
            Text(presentation.waitingLine)
                .font(.subheadline)
                .foregroundStyle(isStale ? .secondary : .primary)
            if let event = state.lastEvent, !event.isEmpty {
                if let at = state.lastEventAt {
                    (Text("\(event), ") + Text(Date(timeIntervalSince1970: Double(at)), style: .relative) + Text(" ago"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text(event).font(.footnote).foregroundStyle(.secondary)
                }
            }
            if let machines = presentation.machinesLine {
                Text(machines)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // Age is shown only when it matters: a quiet box sends no push for many minutes, so a "Updated 12 min ago"
            // line next to a correct state only worried the owner. A stale bubble still says so.
            if isStale {
                (Text("Not updating. Updated ") + Text(Date(timeIntervalSince1970: Double(state.updatedAt)), style: .relative) + Text(" ago"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel(now: Date()))
    }
}

/// Mute (only on the phone that talks) and End, the same intents as the call activity. Hidden when stale.
struct BaseCallControls: View {
    let presentation: BaseActivityPresentation
    let isStale: Bool

    var body: some View {
        if !isStale {
            HStack(spacing: 12) {
                if presentation.showsMute {
                    // A microphone circle (filled while muted) and the AirPlay circle (filled while the speaker or a device has the sound).
                    let muted = presentation.state.call?.isMuted == true
                    Button(intent: NeoToggleCallMuteIntent()) {
                        Image(systemName: muted ? "mic.slash.fill" : "mic.fill").frame(width: 44, height: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(muted ? Color.primary : Color.secondary.opacity(0.35))
                    .foregroundStyle(muted ? Color(uiColor: .systemBackground) : Color.primary)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel(presentation.muteAccessibilityLabel)
                    BaseOutputCircle(presentation: presentation)
                }
                Button(role: .destructive, intent: NeoEndCallIntent()) {
                    Label(BaseActivityPresentation.endTitle, systemImage: "phone.down.fill")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel(BaseActivityPresentation.endAccessibilityLabel)
            }
        }
    }
}

/// The AirPlay circle of the call bubble: a tap swaps speaker and receiver when no device is connected, otherwise it opens the call.
struct BaseOutputCircle: View {
    let presentation: BaseActivityPresentation

    var body: some View {
        let symbol = Image(systemName: BaseActivityPresentation.outputSymbol).frame(width: 44, height: 44)
        if presentation.canChooseOutput {
            Button(intent: NeoToggleCallSpeakerIntent()) { symbol }
                .buttonStyle(.borderedProminent)
                .tint(presentation.outputOn ? Color.primary : Color.secondary.opacity(0.35))
                .foregroundStyle(presentation.outputOn ? Color(uiColor: .systemBackground) : Color.primary)
                .buttonBorderShape(.circle)
                .accessibilityLabel(presentation.outputAccessibilityLabel)
        } else if let call = presentation.state.call {
            Link(destination: ActivityLink.call(botKey: call.botKey).url) { symbol }
                .buttonStyle(.borderedProminent)
                .tint(presentation.outputOn ? Color.primary : Color.secondary.opacity(0.35))
                .foregroundStyle(presentation.outputOn ? Color(uiColor: .systemBackground) : Color.primary)
                .buttonBorderShape(.circle)
                .accessibilityLabel(presentation.outputAccessibilityLabel)
        }
    }
}
