import Foundation

/// How a link the bot shows is put on the call screen. A plain page loads as itself. A post on X or Twitter usually needs a
/// login when loaded as a page, so it is embedded the way Twitter documents for native apps ("Displaying Tweets in iOS
/// apps"): ask `publish.twitter.com/oembed` for the post's markup and render it, with Twitter's own `widgets.js`, in a web
/// view whose base URL is https://twitter.com. If any step fails the screen falls back to loading the link itself.
/// Pure helpers plus one small fetch; the web view lives in the app target.
public enum CallEmbed {
    public static let oEmbedTimeout: TimeInterval = 10
    public static let oEmbedByteCap = 200_000
    public static let wrapperBaseURL = URL(string: "https://twitter.com")!
    private static let widgetsScript = "https://platform.twitter.com/widgets.js"

    /// The post's own URL when `url` is an X or Twitter status link (`/<user>/status/<digits>`), otherwise nil.
    public static func tweetStatusURL(_ url: URL) -> URL? {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return nil }
        let hosts: Set<String> = ["x.com", "www.x.com", "mobile.x.com", "twitter.com", "www.twitter.com", "mobile.twitter.com"]
        guard hosts.contains(host) else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 3, parts[1].lowercased() == "status", !parts[2].isEmpty, parts[2].allSatisfy(\.isASCIIDigit),
            !parts[0].isEmpty
        else { return nil }
        return URL(string: "https://twitter.com/\(parts[0])/status/\(parts[2])")
    }

    /// `https://publish.twitter.com/oembed?url=<status>&omit_script=0&dnt=true&theme=<dark|light>`.
    public static func oEmbedURL(for status: URL, dark: Bool) -> URL? {
        var components = URLComponents(string: "https://publish.twitter.com/oembed")
        components?.queryItems = [
            URLQueryItem(name: "url", value: status.absoluteString), URLQueryItem(name: "omit_script", value: "0"),
            URLQueryItem(name: "dnt", value: "true"), URLQueryItem(name: "theme", value: dark ? "dark" : "light"),
        ]
        return components?.url
    }

    /// The `html` of an oEmbed answer: only a Twitter blockquote, with every script removed (the wrapper adds the one
    /// `widgets.js` itself). Nil for anything else or an answer over the size cap.
    public static func tweetMarkup(fromOEmbed data: Data) -> String? {
        guard data.count <= oEmbedByteCap,
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let html = object["html"] as? String, html.contains("twitter-tweet")
        else { return nil }
        let withoutScripts = html.replacingOccurrences(of: "<script[\\s\\S]*?</script>", with: "", options: [.regularExpression, .caseInsensitive])
        return withoutScripts.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A small page around the markup: scaled to the phone, transparent so the app's own background shows, then Twitter's script.
    public static func wrapperPage(tweetMarkup: String, dark: Bool) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <meta name="color-scheme" content="\(dark ? "dark" : "light")">
        <style>html,body{margin:0;background:transparent}body{padding:12px 4px}.twitter-tweet{margin:0 auto!important}</style>
        </head><body>\(tweetMarkup)<script async src="\(widgetsScript)" charset="utf-8"></script></body></html>
        """
    }

    /// Fetches the wrapper page for a status link. Nil when oEmbed does not answer in time or does not give a post.
    public static func fetchTweetPage(status: URL, dark: Bool, session: URLSession? = nil) async -> String? {
        guard let endpoint = oEmbedURL(for: status, dark: dark) else { return nil }
        var request = URLRequest(url: endpoint, timeoutInterval: oEmbedTimeout)
        request.httpShouldHandleCookies = false
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = oEmbedTimeout
        configuration.timeoutIntervalForResource = oEmbedTimeout
        let session = session ?? URLSession(configuration: configuration)
        guard let (data, response) = try? await session.data(for: request),
            let http = response as? HTTPURLResponse, http.statusCode == 200, http.url?.host == "publish.twitter.com",
            let markup = tweetMarkup(fromOEmbed: data)
        else { return nil }
        return wrapperPage(tweetMarkup: markup, dark: dark)
    }
}

extension Character {
    fileprivate var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
