import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

/// Menu-bar metric selection for Mistral's included-API lane.
/// Kept separate from StatusItemBalanceDisplayTests, which sits at the type-body-length limit.
@MainActor
struct MistralMenuBarMetricTests {
    @Test
    func `menu bar display text uses mistral included API when selected`() {
        let settings = testSettingsStore(
            suiteName: "MistralMenuBarMetricTests-mistral-included-api",
            userDefaults: InMemoryUserDefaults())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = UsageProvider.mistral.instanceID
        settings.menuBarDisplayMode = .both
        settings.usageBarsShowUsed = true
        settings.setMenuBarMetricPreference(.primary, for: .mistral)
        let (store, controller) = Self.makeStoreAndController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }
        let snapshot = MistralUsageSnapshot(
            totalCost: 1.2345,
            currency: "EUR",
            currencySymbol: "€",
            totalInputTokens: 10000,
            totalOutputTokens: 5000,
            totalCachedTokens: 0,
            modelCount: 2,
            startDate: nil,
            endDate: nil,
            updatedAt: Date())
            .toUsageSnapshot()
            .with(
                primary: RateWindow(
                    usedPercent: 2,
                    windowMinutes: nil,
                    resetsAt: nil,
                    resetDescription: "€0.51 / €25.50 · €24.99 left"),
                secondary: nil)

        store._setSnapshotForTesting(snapshot, provider: .mistral)
        store._setErrorForTesting(nil, provider: .mistral)

        let displayText = controller.menuBarDisplayText(for: .mistral, snapshot: snapshot)

        #expect(displayText == "2%")
    }

    private static func makeStoreAndController(settings: SettingsStore)
        -> (UsageStore, StatusItemController)
    {
        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: testStatusBar())
        return (store, controller)
    }
}
