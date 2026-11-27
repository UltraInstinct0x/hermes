import Foundation
import Testing

@testable import HermesBox

@Suite("Call screen embeds: tweets through oEmbed")
struct CallEmbedTests {
    @Test func onlyStatusLinksOnXAndTwitterAreTweets() {
        func status(_ text: String) -> String? { URL(string: text).flatMap(CallEmbed.tweetStatusURL)?.absoluteString }
        #expect(status("https://x.com/jack/status/20") == "https://twitter.com/jack/status/20")
        #expect(status("https://twitter.com/jack/status/20?s=46&t=abc") == "https://twitter.com/jack/status/20")
        #expect(status("https://mobile.twitter.com/jack/status/20/photo/1") == "https://twitter.com/jack/status/20")
        #expect(status("https://x.com/jack") == nil)
        #expect(status("https://x.com/jack/status/abc") == nil)
        #expect(status("https://x.com.evil.example/jack/status/20") == nil)
        #expect(status("http://x.com/jack/status/20") == nil)
        #expect(status("https://example.com/jack/status/20") == nil)
    }

    @Test func theOEmbedRequestCarriesTheStatusThemeAndNoTracking() throws {
        let status = try #require(URL(string: "https://twitter.com/jack/status/20"))
        let url = try #require(CallEmbed.oEmbedURL(for: status, dark: true))
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(url.host == "publish.twitter.com" && url.path == "/oembed")
        #expect(items["url"] == status.absoluteString)
        #expect(items["dnt"] == "true" && items["theme"] == "dark" && items["omit_script"] == "0")
        #expect(CallEmbed.oEmbedURL(for: status, dark: false)?.query?.contains("theme=light") == true)
    }

    @Test func theMarkupKeepsTheBlockquoteAndDropsEveryScript() throws {
        let html = "<blockquote class=\"twitter-tweet\"><p>hi</p></blockquote>\\n<script async src=\"https://evil.example/x.js\"></script>"
        let data = try JSONSerialization.data(withJSONObject: ["html": html.replacingOccurrences(of: "\\n", with: "\n"), "type": "rich"])
        let markup = try #require(CallEmbed.tweetMarkup(fromOEmbed: data))
        #expect(markup.contains("twitter-tweet") && !markup.lowercased().contains("<script"))
    }

    @Test func answersThatAreNotAPostOrTooBigAreRefused() throws {
        #expect(CallEmbed.tweetMarkup(fromOEmbed: Data("not json".utf8)) == nil)
        #expect(CallEmbed.tweetMarkup(fromOEmbed: try JSONSerialization.data(withJSONObject: ["html": "<p>plain</p>"])) == nil)
        let big = try JSONSerialization.data(withJSONObject: ["html": "<blockquote class=\"twitter-tweet\">" + String(repeating: "a", count: 250_000)])
        #expect(CallEmbed.tweetMarkup(fromOEmbed: big) == nil)
    }

    @Test func theWrapperLoadsOnlyTwittersOwnScriptAndHasNoEmDash() {
        let page = CallEmbed.wrapperPage(tweetMarkup: "<blockquote class=\"twitter-tweet\"></blockquote>", dark: true)
        #expect(page.components(separatedBy: "<script").count == 2)
        #expect(page.contains("https://platform.twitter.com/widgets.js"))
        #expect(!page.contains("\u{2014}"))
        #expect(CallEmbed.wrapperBaseURL.absoluteString == "https://twitter.com")
    }
}
