#if os(iOS)
import HermesBox
import SwiftUI

/// The transcript page of the call: the first page of Hermes Bot's two-page pager, in upstream Talk's transcript flow
/// (`TalkTranscript` in App/Views/Talk/TalkView.swift: each line a small semibold speaker name over its words, what is
/// still being heard in a lighter ink at the end), larger (`.title3`) and every recent line, newest at the bottom. It
/// follows new lines unless the person scrolled up; a button takes them back (Hermes Bot's `CallTranscriptView`).
struct NeoCallTranscript: View {
    /// View: the app's chat (your words in a bubble on the right, the bot's as text on the left), or large captions.
    enum Style: String {
        case chat, captions
    }

    let lines: [CallTranscriptLine]
    var style: Style = .captions
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var atBottom = true

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(lines) { line in
                    switch style {
                    case .captions: caption(line)
                    case .chat: chat(line)
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            let distance = geometry.contentSize.height - geometry.contentOffset.y - geometry.containerSize.height
            return CallTranscriptFollow.isAtBottom(distanceFromBottom: distance)
        } action: { _, nowAtBottom in
            atBottom = nowAtBottom
        }
        .onChange(of: lines) { _, _ in
            if atBottom { position.scrollTo(edge: .bottom) }
        }
        .overlay(alignment: .bottomTrailing) {
            if !atBottom {
                Button {
                    withAnimation { position.scrollTo(edge: .bottom) }
                } label: {
                    Image(systemName: "arrow.down")
                        .frame(width: NeoCallTheme.tapTarget, height: NeoCallTheme.tapTarget)
                        .background(.regularMaterial, in: Circle())
                }
                .accessibilityLabel("Jump to the latest line")
            }
        }
        .contentMargins(.top, 16, for: .scrollContent)
        .overlay {
            if lines.isEmpty {
                Text("The conversation will appear here.").font(.subheadline).foregroundStyle(NeoCallTheme.secondaryText)
            }
        }
    }

    /// Captions: upstream Talk's transcript rows (speaker over words), large.
    private func caption(_ line: CallTranscriptLine) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(line.speaker)
                .font(.caption.weight(.semibold))
                .foregroundStyle(NeoCallTheme.secondaryText)
            Text(line.text)
                .font(.title3)
                .foregroundStyle(line.isLive ? NeoCallTheme.tertiaryText : NeoCallTheme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// The app's chat: your words in its user bubble on the right, the bot's reply as plain text on the left.
    @ViewBuilder
    private func chat(_ line: CallTranscriptLine) -> some View {
        if line.isPerson {
            Text(line.text)
                .font(.title3)
                .foregroundStyle(line.isLive ? Theme.tertiaryText : Theme.primaryText)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 48)
                .accessibilityLabel("You: \(line.text)")
        } else {
            Text(line.text)
                .font(.title3)
                .foregroundStyle(Theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("\(line.speaker): \(line.text)")
        }
    }
}
#endif
