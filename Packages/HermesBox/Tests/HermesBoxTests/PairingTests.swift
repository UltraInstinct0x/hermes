import Foundation
import Testing

@testable import HermesBox

// Test-only values. None of these is a real token: the pairing token here is a made-up string.
private let fakeToken = "TEST-ONLY-pairing-token-0123456789abcdef"

@Suite("Pairing link parsing")
struct PairingLinkTests {
    private func parsed(_ raw: String) throws -> BoxPairingLink { try BoxPairingLink.parse(raw).get() }

    @Test func aFragmentLinkYieldsTheBoxAndTheToken() throws {
        let link = try parsed("https://my-box.tail1234.ts.net/pair#\(fakeToken)")
        #expect(link.baseURL?.absoluteString == "https://my-box.tail1234.ts.net")
        #expect(link.token.reveal() == fakeToken)
    }

    @Test func keyedFragmentsAndQueriesAreAccepted() throws {
        #expect(try parsed("https://box.ts.net/#token=\(fakeToken)").token.reveal() == fakeToken)
        #expect(try parsed("https://box.ts.net/pair#pair=\(fakeToken)").token.reveal() == fakeToken)
        #expect(try parsed("https://box.ts.net/pair?pair=\(fakeToken)").token.reveal() == fakeToken)
    }

    @Test func aBareTokenHasNoBoxYet() throws {
        let link = try parsed(fakeToken)
        #expect(link.baseURL == nil)
        #expect(link.token.reveal() == fakeToken)
    }

    @Test func surroundingWhitespaceFromAPasteIsIgnored() throws {
        #expect(try parsed("  https://box.ts.net/pair#\(fakeToken)\n").token.reveal() == fakeToken)
    }

    @Test func plainHttpIsRefusedExceptOnLoopback() throws {
        #expect(throws: BFFError.self) { try parsed("http://box.ts.net/pair#\(fakeToken)") }
        #expect(try parsed("http://127.0.0.1:8790/pair#\(fakeToken)").baseURL?.absoluteString == "http://127.0.0.1:8790")
    }

    @Test func linksWithoutACodeOrNonsenseGiveACalmSentence() {
        for raw in ["", "https://box.ts.net/pair", "hello world", "short"] {
            guard case .failure(let error) = BoxPairingLink.parse(raw) else {
                Issue.record("expected a failure for \(raw)")
                continue
            }
            #expect(!error.calmSentence.isEmpty)
            #expect(!error.calmSentence.contains("\u{2014}"))
        }
    }

    @Test func aTypedBoxAddressBecomesABaseURL() {
        #expect(BoxPairingLink.baseURL(fromAddress: "my-box.tail1234.ts.net")?.absoluteString == "https://my-box.tail1234.ts.net")
        #expect(BoxPairingLink.baseURL(fromAddress: "https://my-box.ts.net/")?.absoluteString == "https://my-box.ts.net")
        #expect(BoxPairingLink.baseURL(fromAddress: "http://box.ts.net") == nil)
        #expect(BoxPairingLink.baseURL(fromAddress: "  ") == nil)
    }

    @Test func theTokenNeverPrintsInAnyDescription() throws {
        let token = try #require(PairingToken(fakeToken))
        #expect(!"\(token)".contains(fakeToken))
        #expect(!String(reflecting: token).contains(fakeToken))
        #expect(!String(describing: BoxPairingLink(baseURL: nil, token: token)).contains(fakeToken))
        var dumped = ""
        dump(token, to: &dumped)
        #expect(!dumped.contains(fakeToken))
    }
}

@Suite("Pairing against a fake BFF")
struct PairingServiceTests {
    private func link(_ base: URL) throws -> BoxPairingLink {
        try BoxPairingLink.parse("\(base.absoluteString)/pair#\(fakeToken)").get()
    }

    @Test func redeemPostsTheTokenOnceWithClientIosAndNoOriginHeader() async throws {
        let box = StubURLProtocol.box { _ in .json(#"{"ok":true,"device":{"id":"d-123","label":"Test iPhone"}}"#, headers: ["Set-Cookie": "bff_device=cookie-value; Path=/; HttpOnly; Secure"]) }
        let secrets = InMemorySecretStore()
        let service = PairingService(transport: box.transport, secrets: secrets, deviceLabel: "Test iPhone")
        let paired = try await service.pair(try link(box.baseURL))

        #expect(paired.baseURL == box.baseURL)
        #expect(paired.hasDeviceToken == false)
        let calls = StubURLProtocol.requests(host: box.host)
        #expect(calls.count == 1)
        let call = try #require(calls.first)
        #expect(call.method == "POST")
        #expect(call.path == "/bff/pair/redeem")
        #expect(call.bodyJSON?["token"] as? String == fakeToken)
        #expect(call.bodyJSON?["deviceLabel"] as? String == "Test iPhone")
        #expect(call.bodyJSON?["client"] as? String == "ios")
        #expect(call.header("Origin") == nil, "a native client sends no Origin, so the BFF CSRF check passes")
        #expect(call.header("Cookie") == nil)
    }

    @Test func withoutADeviceTokenNothingSecretIsStoredAndTheCookieIsNotKept() async throws {
        let box = StubURLProtocol.box { request in
            request.path == "/bff/pair/redeem"
                ? .json(#"{"ok":true,"device":{"id":"d-123","label":"Test iPhone"}}"#, headers: ["Set-Cookie": "bff_device=cookie-value; Path=/; HttpOnly; Secure"])
                : .json(#"{"ok":true,"gateways":[]}"#)
        }
        let secrets = InMemorySecretStore()
        let service = PairingService(transport: box.transport, secrets: secrets, deviceLabel: "Test iPhone")
        _ = try await service.pair(try link(box.baseURL))

        #expect(secrets.accounts == [SecretAccount.boxBaseURL], "only the box address is remembered")
        for account in secrets.accounts {
            let value = try #require(try secrets.read(account))
            #expect(!value.contains(fakeToken))
            #expect(!value.contains("cookie-value"))
            #expect(!value.contains("d-123"), "the BFF device handle is not kept")
        }
        // A second call carries no cookie either.
        _ = try await BFFClient(baseURL: box.baseURL, transport: box.transport).gateways()
        #expect(StubURLProtocol.requests(host: box.host).last?.header("Cookie") == nil)
    }

    @Test func aDeviceTokenFromR2GoesOnlyToTheSecretStoreAndBecomesTheBearer() async throws {
        let box = StubURLProtocol.box { request in
            request.path == "/bff/pair/redeem"
                ? .json(#"{"ok":true,"device":{"id":"d-9","label":"Test iPhone"},"deviceToken":"TEST-ONLY-device-token"}"#)
                : .json(#"{"ok":true,"gateways":[]}"#)
        }
        let secrets = InMemorySecretStore()
        let service = PairingService(transport: box.transport, secrets: secrets, deviceLabel: "Test iPhone")
        let paired = try await service.pair(try link(box.baseURL))
        #expect(paired.hasDeviceToken)
        #expect(try secrets.read(SecretAccount.deviceToken) == "TEST-ONLY-device-token")

        let client = BFFClient(baseURL: box.baseURL, transport: box.transport, authorizer: service.authorizer())
        _ = try await client.gateways()
        let last = try #require(StubURLProtocol.requests(host: box.host).last)
        #expect(last.header("Authorization") == "Bearer TEST-ONLY-device-token")
    }

    @Test func withoutADeviceTokenNoAuthorizationHeaderIsSent() async throws {
        let box = StubURLProtocol.box { _ in .json(#"{"ok":true,"gateways":[]}"#) }
        let secrets = InMemorySecretStore()
        let service = PairingService(transport: box.transport, secrets: secrets, deviceLabel: "x")
        _ = try await BFFClient(baseURL: box.baseURL, transport: box.transport, authorizer: service.authorizer()).gateways()
        #expect(StubURLProtocol.requests(host: box.host).last?.header("Authorization") == nil)
    }

    @Test func aUsedOrExpiredTokenIsACalmSentenceWithTheRawCauseBehindDetails() async throws {
        let box = StubURLProtocol.box { _ in
            .json(#"{"ok":false,"error":{"code":"invalid_pairing_token","message":"invalid or expired pairing token"}}"#, status: 403)
        }
        let service = PairingService(transport: box.transport, secrets: InMemorySecretStore(), deviceLabel: "x")
        do {
            _ = try await service.pair(try link(box.baseURL))
            Issue.record("expected a failure")
        } catch let error as BFFError {
            #expect(error == .envelope(code: "invalid_pairing_token", message: "invalid or expired pairing token", status: 403))
            #expect(error.calmSentence.contains("did not work"))
            #expect(!error.calmSentence.contains("403"))
            #expect(!error.detail.contains(fakeToken))
            #expect(!error.calmSentence.contains(fakeToken))
        }
    }

    @Test func aFailedPairingStoresNothing() async throws {
        let box = StubURLProtocol.box { _ in .json(#"{"ok":false,"error":{"code":"rate_limited","message":"Too many attempts."}}"#, status: 429) }
        let secrets = InMemorySecretStore()
        let service = PairingService(transport: box.transport, secrets: secrets, deviceLabel: "x")
        await #expect(throws: BFFError.self) { try await service.pair(try link(box.baseURL)) }
        #expect(secrets.accounts.isEmpty)
    }

    @Test func anUnreachableBoxNamesTailscale() async throws {
        let box = StubURLProtocol.box { _ in .failure(.cannotConnectToHost) }
        let service = PairingService(transport: box.transport, secrets: InMemorySecretStore(), deviceLabel: "x")
        do {
            _ = try await service.pair(try link(box.baseURL))
            Issue.record("expected a failure")
        } catch let error as BFFError {
            #expect(error.calmSentence.contains("Tailscale"))
            #expect(!error.detail.contains(fakeToken), "the request path is logged, never the body")
        }
    }

    @Test func aBareTokenNeedsTheBoxAddressAndLoadRemembersThePairing() async throws {
        let box = StubURLProtocol.box { _ in .json(#"{"ok":true,"device":{"id":"d","label":"x"}}"#) }
        let secrets = InMemorySecretStore()
        let service = PairingService(transport: box.transport, secrets: secrets, deviceLabel: "x")
        let bare = try BoxPairingLink.parse(fakeToken).get()
        await #expect(throws: BFFError.self) { try await service.pair(bare) }
        _ = try await service.pair(bare, baseURL: box.baseURL)
        #expect(try service.load() == PairedBox(baseURL: box.baseURL, hasDeviceToken: false))
        try service.forget()
        #expect(try service.load() == nil)
    }
}
