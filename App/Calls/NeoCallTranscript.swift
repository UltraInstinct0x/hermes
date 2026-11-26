#if os(iOS)
import HermesBox
import SwiftUI

/// The conversation of the call, in large captions (Talk's caption style, `TalkTexts`, at `.title3`
/// and with every recent turn rather than the last one): oldest at the top, newest at the bottom,
/// following new lines unless the person scrolled up (a button takes them back). The person's lines
/// are quieter than the bot's and carry "You"; their words still being said are lighter still.
/// Structure from Hermes Bot's `CallTranscriptView`.
struct NeoCallTranscript: View {
    let lines: [CallTranscriptLine]
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var atBottom = true

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(lines) { line in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(line.speaker)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(line.isPerson ? Theme.tertiaryText : Theme.secondaryText)
                        Text(line.text)
                            .font(.title3.weight(line.isPerson ? .regular : .medium))
                            .foregroundStyle(line.isLive ? Theme.tertiaryText : line.isPerson ? Theme.secondaryText : Theme.primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                            .contentTransition(.opacity)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.vertical, 8)
        }
        // Room under the fade, so the oldest line still in view is readable once scrolled to.
        .contentMargins(.top, 24, for: .scrollContent)
        .scrollClipDisabled(false)
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom)
        .scrollIndicators(.hidden)
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
                        .frame(width: 44, height: 44)
                        .background(.regularMaterial, in: Circle())
                }
                .accessibilityLabel("Jump to the latest line")
            }
        }
        .overlay {
            if lines.isEmpty {
                Text("The conversation will appear here.").font(.subheadline).foregroundStyle(Theme.secondaryText)
            }
        }
    }
}
#endif
