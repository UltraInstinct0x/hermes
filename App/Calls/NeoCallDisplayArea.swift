#if os(iOS)
import HermesBox
import SwiftUI
import WebKit

/// What the bot put on the call screen, the second page of the call's pager: one item per page, newest first. A link
/// is the page itself, drawn inline and full height (`NeoEmbeddedLink`); notes and pictures are cards that scroll
/// inside. The pages are stepped with two 44 pt arrows (the area is inside the call's own swipe pager, so it does not
/// swipe). Hermes Bot's `CallDisplayArea`, as it was; the words and the https-only rule come from
/// `CallDisplayPresentation`.
struct NeoCallDisplayArea: View {
    let items: [CallDisplayItem]
    let onClear: () -> Void
    @State private var index = 0

    private var current: CallDisplayItem? { items.isEmpty ? nil : items[min(index, items.count - 1)] }

    var body: some View {
        Group {
            if let current {
                VStack(spacing: 6) {
                    page(current).id(current.id)
                    controls
                }
            } else {
                Text(CallContentPane.emptyScreenSentence)
                    .font(.subheadline)
                    .foregroundStyle(NeoCallTheme.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // A newer item is the first page.
        .onChange(of: items.first?.id) { _, _ in index = 0 }
        .onChange(of: items.count) { _, count in index = min(index, max(count - 1, 0)) }
    }

    @ViewBuilder
    private func page(_ item: CallDisplayItem) -> some View {
        switch item.kind {
        case .url:
            if let url = CallDisplayPresentation.secureURL(item) {
                NeoEmbeddedLink(item: item, url: url)
            } else {
                unavailable(CallDisplayPresentation.linkUnavailable)
            }
        case .markdown, .image:
            ScrollView { NeoDisplayCard(item: item) }
        }
    }

    private func unavailable(_ sentence: String) -> some View {
        Text(sentence)
            .font(.subheadline)
            .foregroundStyle(NeoCallTheme.secondaryText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(NeoCallTheme.botBubble, in: RoundedRectangle(cornerRadius: 14))
    }

    private var controls: some View {
        HStack(spacing: 0) {
            if items.count > 1 {
                step("chevron.left", label: "Newer item", enabled: index > 0) { index -= 1 }
                Text(CallDisplayPresentation.pageLabel(index: index, count: items.count))
                    .font(.footnote)
                    .foregroundStyle(NeoCallTheme.secondaryText)
                    .padding(.horizontal, 6)
                step("chevron.right", label: "Older item", enabled: index < items.count - 1) { index += 1 }
            }
            Spacer()
            Button(CallDisplayPresentation.clearTitle, action: onClear)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(NeoCallTheme.userBubble)
                .frame(minWidth: NeoCallTheme.tapTarget, minHeight: NeoCallTheme.tapTarget)
                .accessibilityHint(CallDisplayPresentation.clearHint)
        }
    }

    private func step(_ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(enabled ? NeoCallTheme.primaryText : NeoCallTheme.secondaryText.opacity(0.4))
                .frame(width: NeoCallTheme.tapTarget, height: NeoCallTheme.tapTarget)
                .contentShape(Rectangle())
        }
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}

/// A note or a picture: a titled card.
private struct NeoDisplayCard: View {
    let item: CallDisplayItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: CallDisplayPresentation.symbol(item.kind)).foregroundStyle(NeoCallTheme.secondaryText).accessibilityHidden(true)
                Text(CallDisplayPresentation.title(item))
                    .font(.headline)
                    .foregroundStyle(NeoCallTheme.primaryText)
                    .lineLimit(2)
                    .accessibilityAddTraits(.isHeader)
            }
            if item.kind == .markdown { note } else { picture }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(NeoCallTheme.botBubble, in: RoundedRectangle(cornerRadius: 14))
    }

    private var note: some View {
        Text(CallDisplayPresentation.attributed(markdown: item.body ?? ""))
            .font(.body)
            .foregroundStyle(NeoCallTheme.primaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }

    @ViewBuilder
    private var picture: some View {
        if let url = CallDisplayPresentation.secureURL(item) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFit().frame(maxWidth: .infinity)
                case .failure:
                    Text(CallDisplayPresentation.imageUnavailable).font(.subheadline).foregroundStyle(NeoCallTheme.secondaryText)
                default:
                    ProgressView().frame(maxWidth: .infinity, minHeight: 80)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(CallDisplayPresentation.accessibilityLabel(item))
        } else {
            Text(CallDisplayPresentation.imageUnavailable).font(.subheadline).foregroundStyle(NeoCallTheme.secondaryText)
        }
    }
}

/// What an embedded page is told to show.
enum NeoEmbeddedContent: Equatable {
    case page(URL)
    /// Markup with the https base URL it is loaded under (the tweet wrapper).
    case markup(String, base: URL)
}

enum NeoEmbeddedLoadState: Equatable {
    case loading, loaded
    case failed(String)
}

/// A web page inside the call screen, locked down for what a bot may show: a non-persistent store,
/// https only (every navigation re-checked with `CallDisplayPresentation.secureURL`), no media
/// autoplay, links opening in place. Ported from Hermes Bot's `EmbeddedPage`.
struct NeoEmbeddedPage: UIViewRepresentable {
    let content: NeoEmbeddedContent
    /// Changes when the person asks for a retry.
    let attempt: Int
    let onState: (NeoEmbeddedLoadState) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onState: onState) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.allowsInlineMediaPlayback = true
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        context.coordinator.load(content, attempt: attempt, in: view)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.onState = onState
        context.coordinator.load(content, attempt: attempt, in: view)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var onState: (NeoEmbeddedLoadState) -> Void
        private var loaded: (NeoEmbeddedContent, Int)?

        init(onState: @escaping (NeoEmbeddedLoadState) -> Void) { self.onState = onState }

        func load(_ content: NeoEmbeddedContent, attempt: Int, in view: WKWebView) {
            if let loaded, loaded.0 == content, loaded.1 == attempt { return }
            loaded = (content, attempt)
            report(.loading)
            switch content {
            case .page(let url): view.load(URLRequest(url: url))
            case .markup(let html, let base): view.loadHTMLString(html, baseURL: base)
            }
        }

        private func report(_ state: NeoEmbeddedLoadState) {
            Task { @MainActor in self.onState(state) }
        }

        /// https (checked again here), or `about:` for the blank frames pages use.
        private func allowed(_ url: URL?) -> Bool {
            guard let url else { return false }
            if url.scheme?.lowercased() == "about" { return true }
            return CallDisplayPresentation.secureURL(url.absoluteString) != nil
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            allowed(action.request.url) ? .allow : .cancel
        }

        func webView(
            _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if action.targetFrame == nil, allowed(action.request.url) { webView.load(action.request) }
            return nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { report(.loaded) }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { fail(error) }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            fail(error)
        }

        private func fail(_ error: any Error) {
            // A cancelled navigation (a refused link, a tap during a load) is not a failure of the page.
            if (error as NSError).code == NSURLErrorCancelled { return }
            report(.failed("\((error as NSError).domain) \((error as NSError).code)"))
        }
    }
}

/// One link on the call screen: the page itself, with a calm failure card and "Open in Safari".
struct NeoEmbeddedLink: View {
    let item: CallDisplayItem
    let url: URL

    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme
    @State private var content: NeoEmbeddedContent?
    @State private var state = NeoEmbeddedLoadState.loading
    @State private var attempt = 0

    var body: some View {
        ZStack {
            if let content {
                NeoEmbeddedPage(content: content, attempt: attempt) { state = $0 }
            }
            if case .failed(let details) = state {
                failure(details)
            } else if state == .loading {
                ProgressView().accessibilityLabel("Loading the page")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NeoCallTheme.botBubble)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(alignment: .topTrailing) { safariButton }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(CallDisplayPresentation.accessibilityLabel(item))
        .task(id: "\(url.absoluteString)#\(attempt)#\(colorScheme == .dark)") { await prepare() }
    }

    /// A post on X is fetched through oEmbed first and falls back to the link itself.
    private func prepare() async {
        state = .loading
        if let status = CallEmbed.tweetStatusURL(url), let page = await CallEmbed.fetchTweetPage(status: status, dark: colorScheme == .dark) {
            content = .markup(page, base: CallEmbed.wrapperBaseURL)
        } else {
            content = .page(url)
        }
    }

    private var safariButton: some View {
        Button {
            openURL(url)
        } label: {
            Image(systemName: "safari")
                .font(.body.weight(.semibold))
                .foregroundStyle(NeoCallTheme.primaryText)
                .frame(width: NeoCallTheme.tapTarget, height: NeoCallTheme.tapTarget)
                .background(.regularMaterial, in: Circle())
        }
        .padding(6)
        .accessibilityLabel("Open in Safari")
    }

    private func failure(_ details: String) -> some View {
        VStack(spacing: 8) {
            Text("This page could not be shown.").font(.subheadline).foregroundStyle(NeoCallTheme.primaryText)
            HStack {
                Button("Retry") { attempt += 1 }
                Button("Copy details") { UIPasteboard.general.string = details }
            }
            .buttonStyle(.bordered)
            .frame(minHeight: NeoCallTheme.tapTarget)
        }
        .padding(16)
        .background(NeoCallTheme.botBubble)
    }
}
#endif
