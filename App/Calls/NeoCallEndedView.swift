#if os(iOS)
import HermesAvatarUI
import HermesBox
import SwiftUI
import UIKit

/// The one calm ending of every call, in place of the indicator and the call's content. Hermes Bot's
/// `CallEndedView`; the words come from `CallEndedSummary`. Neo has no box chat, so "Open the chat"
/// is left out.
struct NeoCallEndedView: View {
    let summary: CallEndedSummary
    /// The bot's key, for its avatar (a still ring when it is not known).
    var botKey: String?
    let onCallAgain: () -> Void
    let onDone: () -> Void

    @AccessibilityFocusState private var titleFocused: Bool
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if let botKey {
                    // The bot at rest: who the call was with, at a glance. (Its sleeping pose shrinks to a dot at
                    // this size, which read as nobody.)
                    BloubView(profile: bloubProfile(fromKey: botKey), status: .idle, size: 100, animate: false)
                        .frame(width: 100, height: 100)
                        .padding(.top, 8)
                        .accessibilityHidden(true)
                } else {
                    Circle()
                        .stroke(NeoCallTheme.secondaryText.opacity(0.6), lineWidth: 2)
                        .frame(width: 72, height: 72)
                        .frame(width: 88, height: 88)
                        .padding(.top, 8)
                        .accessibilityHidden(true)
                }
                VStack(spacing: 6) {
                    Text(summary.title)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(NeoCallTheme.primaryText)
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityFocused($titleFocused)
                    if let duration = summary.durationText {
                        Text(duration).font(.subheadline).foregroundStyle(NeoCallTheme.secondaryText)
                    }
                    if let detail = summary.detail {
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(NeoCallTheme.secondaryText)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .contain)
                if !summary.displayTitles.isEmpty { shown }
                actions
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            titleFocused = true
            UIAccessibility.post(notification: .screenChanged, argument: summary.spokenLabel)
        }
    }

    /// What the bot put on the screen, titles only.
    private var shown: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Shown during the call").font(.footnote.weight(.semibold)).foregroundStyle(NeoCallTheme.secondaryText)
            ForEach(Array(summary.displayTitles.enumerated()), id: \.offset) { _, title in
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(NeoCallTheme.primaryText)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NeoCallTheme.botBubble, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Shown during the call")
    }

    private var actions: some View {
        VStack(spacing: 10) {
            if summary.canCallAgain {
                Button(action: onCallAgain) { Text("Call again").frame(maxWidth: .infinity, minHeight: NeoCallTheme.tapTarget) }
                    .buttonStyle(.borderedProminent)
                    .accessibilityHint("Starts a new call with \(summary.botName.isEmpty ? "this bot" : summary.botName)")
            }
            Button(action: onDone) { Text("Done").frame(maxWidth: .infinity, minHeight: NeoCallTheme.tapTarget) }
                .buttonStyle(.bordered)
            if let details = summary.copyableDetails, !details.isEmpty {
                Button(copied ? "Copied" : "Copy details") {
                    UIPasteboard.general.string = details
                    copied = true
                }
                .font(.footnote)
                .frame(minHeight: NeoCallTheme.tapTarget)
                .accessibilityLabel("Copy details")
                .accessibilityHint("Copies the technical cause to the clipboard")
            }
        }
    }
}
#endif
