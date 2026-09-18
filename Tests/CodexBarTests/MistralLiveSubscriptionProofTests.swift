import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

/// Live proof: replays a captured, authenticated admin.mistral.ai/subscription page through the
/// production fetch path — `MistralUsageFetcher.fetchSubscriptionBudgets` plus
/// `MistralWebFetchStrategy.attachSubscriptionBudgets` — and renders the labels the menu card and
/// menu bar show. No network access, no secrets: the fixture lives outside the repo.
///
/// Disabled by default so CI / `make test` never require the captured fixture.
/// To run it locally:
///   1. Save an authenticated https://admin.mistral.ai/subscription page as HTML.
///   2. Temporarily remove the `.disabled(...)` trait below (keep the guard).
///   3. MISTRAL_LIVE_HTML_PATH=/path/to/page.html swift test --filter MistralLiveSubscriptionProofTests
struct MistralLiveSubscriptionProofTests {
    @Test(.disabled("Set MISTRAL_LIVE_HTML_PATH to a captured subscription page to run this proof."))
    func `production path renders live subscription allowances end to end`() async throws {
        guard let path = ProcessInfo.processInfo.environment["MISTRAL_LIVE_HTML_PATH"] else {
            Issue.record("MISTRAL_LIVE_HTML_PATH is not set; point it at a captured subscription page.")
            return
        }
        let html = try String(contentsOfFile: path, encoding: .utf8)

        // Serve the captured authenticated page through the real transport seam so the
        // production fetch path runs completely unmodified.
        let transport = ProviderHTTPTransportHandler { request in
            guard let url = request.url,
                  url.absoluteString == "https://admin.mistral.ai/subscription",
                  request.value(forHTTPHeaderField: "Cookie") != nil,
                  let response = HTTPURLResponse(
                      url: url,
                      statusCode: 200,
                      httpVersion: nil,
                      headerFields: ["Content-Type": "text/html"])
            else { throw URLError(.badServerResponse) }
            return (Data(html.utf8), response)
        }

        let budgets = try await MistralUsageFetcher.fetchSubscriptionBudgets(
            cookieHeader: "ory_session_redacted=redacted; csrftoken=redacted",
            timeout: 5,
            transport: transport)
        let base = UsageSnapshot(primary: nil, secondary: nil, updatedAt: Date())
        let snapshot = MistralWebFetchStrategy.attachSubscriptionBudgets(to: base, budgets: budgets)

        let descriptor = MistralProviderDescriptor.descriptor
        let labels = descriptor.presentation.rateWindowLabels(
            metadata: descriptor.metadata, snapshot: snapshot, now: Date())

        print("— production fetch path, captured live subscription page —")
        print("primary lane label : \(labels.primary)")
        print("primary percent    : \(String(format: "%.4f", snapshot.primary?.usedPercent ?? -1))%")
        print("primary detail     : \(snapshot.primary?.resetDescription ?? "nil")")
        let resets = snapshot.primary?.resetsAt.map { ISO8601DateFormatter().string(from: $0) } ?? "nil"
        print("primary resets at  : \(resets)")
        for named in snapshot.extraRateWindows ?? [] {
            let shows = descriptor.presentation.menuCard
                .extraRateWindowShowsResetDescriptionAsDetail(named)
            print("extra window       : id=\(named.id) title=\(named.title)")
            print("  percent          : \(String(format: "%.4f", named.window.usedPercent))%")
            print("  detail           : \(named.window.resetDescription ?? "nil") (rendered: \(shows))")
        }

        #expect(labels.primary == "Included API")
        #expect(snapshot.primary?.resetsAt != nil)
        #expect(snapshot.primary?.resetDescription != nil)
        #expect(snapshot.primary?.usedPercent == budgets.api.usagePercentage)
    }
}
