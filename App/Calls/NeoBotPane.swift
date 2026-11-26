#if os(iOS)
import HermesBox
import SwiftUI
import WebKit

/// What the bot put on the call screen (`CallDisplay`), in a pane of its own that scrolls apart from
/// the transcript: every item, newest first, as a card (a note, a picture) or the page itself (a
/// link, drawn inline). Ported from Hermes Bot's `CallDisplayArea` (which paged one item at a time);
/// the words and the https-only rule come from `CallDisplayPresentation`.
struct NeoBotPane: View {
    let items: [CallDisplayItem]
    let onClear: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Label("On screen", systemImage: "rectangle.stack")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.secondaryText)
                if items.count > 1 {
                    Text("\(items.count)").font(.footnote.monospacedDigit()).foregroundStyle(Theme.tertiaryText)
                }
                Spacer()
                Button(CallDisplayPresentation.clearTitle, action: onClear)
                    .font(.subheadline.weight(.semibold))
                    .frame(minWidth: 44, minHeight: 32)
                    .accessibilityHint(CallDisplayPresentation.clearHint)
            }
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(items) { item in
                        page(item).id(item.id)
                    }
                }
            }
            .scrollIndicators(.visible)
        }
        .padding(10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.hairline))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("What the bot shows")
    }

    @ViewBuilder
    private func page(_ item: CallDisplayItem) -> some View {
        switch item.kind {
        case .url:
            if let url = CallDisplayPresentation.secureURL(item) {
                NeoEmbeddedLink(item: item, url: url).frame(height: 340)
            } else {
                Text(CallDisplayPresentation.linkUnavailable)
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                    .neoCard()
            }
        case .markdown, .image:
            NeoDisplayCard(item: item)
        }
    }
}

/// A note or a picture: a titled card.
private struct NeoDisplayCard: View {
    let item: CallDisplayItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: CallDisplayPresentation.symbol(item.kind)).foregroundStyle(Theme.secondaryText).accessibilityHidden(true)
                Text(CallDisplayPresentation.title(item))
                    .font(.headline)
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(2)
                    .accessibilityAddTraits(.isHeader)
            }
            if item.kind == .markdown { note } else { picture }
        }
        .neoCard()
    }

    private var note: some View {
        Text(CallDisplayPresentation.attributed(markdown: item.body ?? ""))
            .font(.body)
            .foregroundStyle(Theme.primaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }

    @ViewBuilder
    private var picture: some View {
        if let url = CallDisplayPresentation.secureURL(item) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFit().frame(maxWidth: .infinity).clipShape(RoundedRectangle(cornerRadius: 10))
                case .failure:
                    Text(CallDisplayPresentation.imageUnavailable).font(.subheadline).foregroundStyle(Theme.secondaryText)
                default:
                    ProgressView().frame(maxWidth: .infinity, minHeight: 80)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(CallDisplayPresentation.accessibilityLabel(item))
        } else {
            Text(CallDisplayPresentation.imageUnavailable).font(.subheadline).foregroundStyle(Theme.secondaryText)
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
        .background(Theme.controlFill)
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
                .foregroundStyle(Theme.primaryText)
                .frame(width: 44, height: 44)
                .background(.regularMaterial, in: Circle())
        }
        .padding(6)
        .accessibilityLabel("Open in Safari")
    }

    private func failure(_ details: String) -> some View {
        VStack(spacing: 8) {
            Text("This page could not be shown.").font(.subheadline).foregroundStyle(Theme.primaryText)
            HStack {
                Button("Retry") { attempt += 1 }
                Button("Copy details") { UIPasteboard.general.string = details }
            }
            .buttonStyle(.bordered)
        }
        .padding(16)
    }
}
#endif
