import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

private final class MistralSubscriptionRequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequest: URLRequest?

    var request: URLRequest? {
        self.lock.withLock { self.storedRequest }
    }

    func record(_ request: URLRequest) {
        self.lock.withLock { self.storedRequest = request }
    }
}

@Suite
struct MistralSubscriptionBudgetTests {
    private static func flightPush(_ chunk: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [1, chunk])
        return "<script>self.__next_f.push(\(String(decoding: data, as: UTF8.self)))</script>"
    }
    @Test
    func `parses API allowance from subscription flight payload`() throws {
        let html = #"""
        <script>self.__next_f.push([1,"7:[\"$\",\"$L1\",null,{\"budget\":{\"vibe_budget\":{\"usage_percentage\":0.0,\"initial_budget\":255.0,\"currency\":\"eur\",\"reset_at\":\"2026-10-01T00:00:00.000Z\",\"payg_enabled\":false},\"api_budget\":{\"usage_percentage\":2.0,\"initial_budget\":25.5,\"currency\":\"eur\",\"reset_at\":\"2026-10-01T00:00:00.000Z\",\"payg_enabled\":false}}}]"])</script>
        """#

        let result = try MistralSubscriptionBudgetParser.parse(html: html)

        #expect(result.api.usagePercentage == 2)
        #expect(result.api.limit == 25.5)
        #expect(result.api.currencyCode == "EUR")
        #expect(result.api.usedAmount == 0.51)
        #expect(result.api.remainingAmount == 24.99)
        #expect(result.api.payAsYouGoEnabled == false)
        let expectedReset = try #require(ISO8601DateParser.parse("2026-10-01T00:00:00.000Z"))
        #expect(result.api.resetsAt == expectedReset)
        let expectedVibeReset = try #require(ISO8601DateParser.parse("2026-10-01T00:00:00.000Z"))
        #expect(try #require(result.vibe).resetsAt == expectedVibeReset)
    }

    @Test
    func `parses API allowance when Vibe allowance is absent`() throws {
        let html = try Self.flightPush(
            #"7:["$",null,null,{"budget":{"api_budget":{"usage_percentage":1.1,"initial_budget":25.5,"currency":"eur","reset_at":"2026-10-01T00:00:00.000Z","payg_enabled":true}}}]\n"#)

        let result = try MistralSubscriptionBudgetParser.parse(html: html)

        #expect(result.api.usagePercentage == 1.1)
        #expect(result.api.limit == 25.5)
    }

    @Test
    func `reassembles subscription budget split across flight pushes`() throws {
        let record = #"7:["$","$L1",null,{"budget":{"api_budget":{"usage_percentage":2.0,"initial_budget":25.5,"currency":"eur","reset_at":"2026-10-01T00:00:00.000Z","payg_enabled":false},"vibe_budget":{"usage_percentage":0.0,"initial_budget":255.0,"currency":"eur","reset_at":"2026-10-01T00:00:00.000Z","payg_enabled":false}}}]\n"#
        let split = record.index(record.startIndex, offsetBy: record.count / 2)
        let html = try Self.flightPush(String(record[..<split]))
            + Self.flightPush(String(record[split...]))

        let result = try MistralSubscriptionBudgetParser.parse(html: html)

        #expect(result.api.limit == 25.5)
        #expect(try #require(result.vibe).limit == 255)
    }

    @Test
    func `subscription request fetches authenticated budget page`() async throws {
        let record = #"7:["$","$L1",null,{"budget":{"api_budget":{"usage_percentage":2.0,"initial_budget":25.5,"currency":"eur","reset_at":"2026-10-01T00:00:00.000Z","payg_enabled":false},"vibe_budget":{"usage_percentage":0.0,"initial_budget":255.0,"currency":"eur","reset_at":"2026-10-01T00:00:00.000Z","payg_enabled":false}}}]\n"#
        let data = Data(try Self.flightPush(record).utf8)
        let capture = MistralSubscriptionRequestCapture()
        let transport = ProviderHTTPTransportHandler { request in
            capture.record(request)
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html"]))
            return (data, response)
        }

        let result = try await MistralUsageFetcher.fetchSubscriptionBudgets(
            cookieHeader: "ory_session_test=abc; csrftoken=csrf",
            timeout: 2,
            transport: transport)
        let request = try #require(capture.request)

        #expect(result.api.limit == 25.5)
        #expect(request.url?.absoluteString == "https://admin.mistral.ai/subscription")
        #expect(request.timeoutInterval == 2)
        #expect(request.httpShouldHandleCookies == false)
        #expect(request.value(forHTTPHeaderField: "Cookie") == "ory_session_test=abc; csrftoken=csrf")
        #expect(request.value(forHTTPHeaderField: "Accept") == "text/html")
    }

    @Test
    func `subscription budgets become API and Vibe windows`() throws {
        let html = try Self.flightPush(#"7:["$",null,null,{"budget":{"api_budget":{"usage_percentage":2.0,"initial_budget":25.5,"currency":"eur","reset_at":"2026-10-01T00:00:00.000Z","payg_enabled":false},"vibe_budget":{"usage_percentage":0.0,"initial_budget":255.0,"currency":"eur","reset_at":"2026-10-01T00:00:00.000Z","payg_enabled":false}}}]\n"#)
        let budgets = try MistralSubscriptionBudgetParser.parse(html: html)
        let existing = NamedRateWindow(
            id: "existing",
            title: "Existing",
            window: RateWindow(usedPercent: 4, windowMinutes: nil, resetsAt: nil, resetDescription: nil))
        let base = UsageSnapshot(
            primary: nil,
            secondary: nil,
            extraRateWindows: [existing],
            updatedAt: Date())

        let result = MistralWebFetchStrategy.attachSubscriptionBudgets(to: base, budgets: budgets)

        #expect(result.primary?.usedPercent == 2)
        #expect(result.primary?.resetsAt == budgets.api.resetsAt)
        #expect(result.primary?.resetDescription == "€0.51 / €25.50 · €24.99 left")
        #expect(result.extraRateWindows?.contains(where: { $0.id == "existing" }) == true)
        let vibe = try #require(result.extraRateWindows?.first { $0.id == "mistral-monthly-plan" })
        #expect(vibe.window.usedPercent == 0)
        #expect(vibe.window.resetDescription == "€0.00 / €255.00 · €255.00 left")
    }

    @Test
    func `Mistral exposes included API as a selectable primary metric`() {
        let descriptor = MistralProviderDescriptor.descriptor

        #expect(descriptor.menuBarMetrics.supports(.primary))
        #expect(MistralProviderDescriptor.primaryLabel(window: RateWindow(
            usedPercent: 2,
            windowMinutes: nil,
            resetsAt: nil,
            resetDescription: nil)) == "Included API")
        #expect(MistralProviderDescriptor.primaryLabel(window: nil) == nil)
        #expect(descriptor.metadata.sessionLabel == "Balance")
    }
}
