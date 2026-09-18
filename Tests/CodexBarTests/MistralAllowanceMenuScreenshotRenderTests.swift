import AppKit
import SwiftUI
import XCTest
@testable import CodexBar
@testable import CodexBarCore

/// Renders the real UsageMenuCardView for Mistral with the shared descriptor and presentation
/// hooks driving both allowance lanes, so a freshly built app screenshot exists for review.
/// Uses a synthetic snapshot seeded with the amounts already verified against a live,
/// authenticated Mistral subscription response (see MistralLiveSubscriptionProofTests) — no
/// network access, no account, no Keychain use.
@MainActor
final class MistralAllowanceMenuScreenshotRenderTests: XCTestCase {
    func test_includedAPIAndMonthlyPlanRenderThroughSharedDescriptor() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-18T00:00:00Z"))
        let resetsAt = try XCTUnwrap(ISO8601DateParser.parse("2026-10-01T00:00:00.000Z"))
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 1.1344,
                windowMinutes: nil,
                resetsAt: resetsAt,
                resetDescription: "€0.29 / €25.50 · €25.21 left"),
            secondary: nil,
            extraRateWindows: [
                NamedRateWindow(
                    id: "mistral-monthly-plan",
                    title: "Monthly Plan",
                    window: RateWindow(
                        usedPercent: 0,
                        windowMinutes: nil,
                        resetsAt: resetsAt,
                        resetDescription: "€0.00 / €255.00 · €255.00 left")),
            ],
            updatedAt: now)

        let descriptor = MistralProviderDescriptor.descriptor
        let labels = descriptor.presentation.rateWindowLabels(
            metadata: descriptor.metadata,
            snapshot: snapshot,
            now: now)
        XCTAssertEqual(labels.primary, "Included API")

        let model = try UsageMenuCardView.Model.make(.init(
            provider: .mistral,
            metadata: XCTUnwrap(ProviderDefaults.metadata[.mistral]),
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: true,
            resetTimeDisplayStyle: .absolute,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: true,
            paceVisible: false,
            usesLiveSubtitle: false,
            now: now))

        XCTAssertEqual(model.metrics.first?.title, "Included API")

        if let path = ProcessInfo.processInfo.environment["CODEXBAR_MISTRAL_ALLOWANCE_PROOF_DIR"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for dark in [false, true] {
                let view = AnyView(UsageMenuCardView(model: model, width: 320)
                    .environment(\.locale, Locale(identifier: "en_US_POSIX"))
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .environment(\.displayScale, 2)
                    .background(Color(nsColor: .windowBackgroundColor)))
                let hosting = NSHostingView(rootView: view)
                hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                try XCTUnwrap(MenuLayoutScreenshotRenderTests.pngDataWithWindow(hosting: hosting))
                    .write(to: directory.appendingPathComponent("mistral-allowances-\(dark ? "dark" : "light").png"))
            }
        }
    }
}
