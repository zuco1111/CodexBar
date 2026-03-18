import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite
struct UsageStorePlanUtilizationTests {
    @Test
    func coalescesChangedUsageWithinHourIntoSingleSample() throws {
        let calendar = Calendar(identifier: .gregorian)
        let hourStart = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone(secondsFromGMT: 0),
            year: 2026,
            month: 3,
            day: 17,
            hour: 10)))
        let first = makePlanSample(at: hourStart, primary: 10, secondary: 20)
        let second = makePlanSample(
            at: hourStart.addingTimeInterval(25 * 60),
            primary: 35,
            secondary: 45,
            primaryWindowMinutes: 300,
            secondaryWindowMinutes: 10080)

        let initial = try #require(
            UsageStore._updatedPlanUtilizationHistoryForTesting(
                provider: .codex,
                existingHistory: [],
                sample: first))
        let updated = try #require(
            UsageStore._updatedPlanUtilizationHistoryForTesting(
                provider: .codex,
                existingHistory: initial,
                sample: second))

        #expect(updated.count == 1)
        #expect(updated.last == second)
    }

    @Test
    func appendsNewSampleAfterCrossingIntoNextHourBucket() throws {
        let calendar = Calendar(identifier: .gregorian)
        let hourStart = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone(secondsFromGMT: 0),
            year: 2026,
            month: 3,
            day: 17,
            hour: 10)))
        let first = makePlanSample(at: hourStart, primary: 10, secondary: 20)
        let second = makePlanSample(at: hourStart.addingTimeInterval(50 * 60), primary: 35, secondary: 45)
        let nextHour = makePlanSample(at: hourStart.addingTimeInterval(65 * 60), primary: 60, secondary: 70)

        let oneHour = try #require(
            UsageStore._updatedPlanUtilizationHistoryForTesting(
                provider: .codex,
                existingHistory: [],
                sample: first))
        let coalesced = try #require(
            UsageStore._updatedPlanUtilizationHistoryForTesting(
                provider: .codex,
                existingHistory: oneHour,
                sample: second))
        let twoHours = try #require(
            UsageStore._updatedPlanUtilizationHistoryForTesting(
                provider: .codex,
                existingHistory: coalesced,
                sample: nextHour))

        #expect(coalesced.count == 1)
        #expect(twoHours.count == 2)
        #expect(twoHours.first == second)
        #expect(twoHours.last == nextHour)
    }

    @Test
    func staleWriteInSameHourDoesNotOverrideNewerValues() throws {
        let calendar = Calendar(identifier: .gregorian)
        let hourStart = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone(secondsFromGMT: 0),
            year: 2026,
            month: 3,
            day: 17,
            hour: 10)))
        let newer = makePlanSample(
            at: hourStart.addingTimeInterval(45 * 60),
            primary: 70,
            secondary: 80,
            primaryWindowMinutes: 300,
            secondaryWindowMinutes: 10080)
        let stale = makePlanSample(
            at: hourStart.addingTimeInterval(5 * 60),
            primary: 15,
            secondary: 25,
            primaryWindowMinutes: 60,
            secondaryWindowMinutes: 1440)

        let initial = try #require(
            UsageStore._updatedPlanUtilizationHistoryForTesting(
                provider: .codex,
                existingHistory: [],
                sample: newer))
        let updated = UsageStore._updatedPlanUtilizationHistoryForTesting(
            provider: .codex,
            existingHistory: initial,
            sample: stale)

        #expect(updated == nil)
        #expect(initial.count == 1)
        #expect(initial.last == newer)
    }

    @Test
    func newerSameHourSampleKeepsNewerMetadataAndBackfillsMissingValues() throws {
        let calendar = Calendar(identifier: .gregorian)
        let hourStart = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone(secondsFromGMT: 0),
            year: 2026,
            month: 3,
            day: 17,
            hour: 10)))
        let existing = makePlanSample(
            at: hourStart.addingTimeInterval(10 * 60),
            primary: 20,
            secondary: nil,
            primaryWindowMinutes: 300,
            secondaryWindowMinutes: 10080)
        let incomingReset = Date(timeIntervalSince1970: 1_710_000_000)
        let incoming = makePlanSample(
            at: hourStart.addingTimeInterval(50 * 60),
            primary: nil,
            secondary: 45,
            primaryResetsAt: incomingReset)

        let updated = try #require(
            UsageStore._updatedPlanUtilizationHistoryForTesting(
                provider: .codex,
                existingHistory: [existing],
                sample: incoming))

        let merged = try #require(updated.last)
        #expect(merged.capturedAt == incoming.capturedAt)
        #expect(merged.primaryUsedPercent == 20)
        #expect(merged.primaryWindowMinutes == 300)
        #expect(merged.primaryResetsAt == incomingReset)
        #expect(merged.secondaryUsedPercent == 45)
        #expect(merged.secondaryWindowMinutes == 10080)
    }

    @Test
    func staleSameHourSampleOnlyFillsMissingMetadata() throws {
        let calendar = Calendar(identifier: .gregorian)
        let hourStart = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone(secondsFromGMT: 0),
            year: 2026,
            month: 3,
            day: 17,
            hour: 10)))
        let newer = makePlanSample(
            at: hourStart.addingTimeInterval(50 * 60),
            primary: 40,
            secondary: 80,
            primaryWindowMinutes: nil,
            secondaryWindowMinutes: 10080)
        let staleReset = Date(timeIntervalSince1970: 1_710_123_456)
        let stale = makePlanSample(
            at: hourStart.addingTimeInterval(5 * 60),
            primary: 10,
            secondary: 20,
            primaryWindowMinutes: 300,
            primaryResetsAt: staleReset,
            secondaryWindowMinutes: nil)

        let updated = try #require(
            UsageStore._updatedPlanUtilizationHistoryForTesting(
                provider: .codex,
                existingHistory: [newer],
                sample: stale))

        let merged = try #require(updated.last)
        #expect(merged.capturedAt == newer.capturedAt)
        #expect(merged.primaryUsedPercent == 40)
        #expect(merged.secondaryUsedPercent == 80)
        #expect(merged.primaryWindowMinutes == 300)
        #expect(merged.primaryResetsAt == staleReset)
        #expect(merged.secondaryWindowMinutes == 10080)
    }

    @Test
    func trimsHistoryToExpandedRetentionLimit() throws {
        let maxSamples = UsageStore._planUtilizationMaxSamplesForTesting
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var history: [PlanUtilizationHistorySample] = []

        for offset in 0..<maxSamples {
            history.append(makePlanSample(
                at: base.addingTimeInterval(Double(offset) * 3600),
                primary: Double(offset % 100),
                secondary: nil))
        }

        let appended = makePlanSample(
            at: base.addingTimeInterval(Double(maxSamples) * 3600),
            primary: 50,
            secondary: 60)

        let updated = try #require(
            UsageStore._updatedPlanUtilizationHistoryForTesting(
                provider: .codex,
                existingHistory: history,
                sample: appended))

        #expect(updated.count == maxSamples)
        #expect(updated.first?.capturedAt == history[1].capturedAt)
        #expect(updated.last == appended)
    }

    @MainActor
    @Test
    func dailyModelShowsZeroBarsForMissingDays() throws {
        let calendar = Calendar(identifier: .gregorian)
        let firstBoundary = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone.current,
            year: 2026,
            month: 3,
            day: 4,
            hour: 10,
            minute: 0)))
        let thirdBoundary = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone.current,
            year: 2026,
            month: 3,
            day: 6,
            hour: 10,
            minute: 0)))
        let samples = [
            makePlanSample(
                at: thirdBoundary.addingTimeInterval(-30 * 60),
                primary: 20,
                secondary: 35,
                primaryWindowMinutes: 300,
                primaryResetsAt: thirdBoundary,
                secondaryWindowMinutes: 10080),
            makePlanSample(
                at: firstBoundary.addingTimeInterval(-30 * 60),
                primary: 62,
                secondary: 62,
                primaryWindowMinutes: 300,
                primaryResetsAt: firstBoundary,
                secondaryWindowMinutes: 10080),
        ]

        let model = try #require(
            PlanUtilizationHistoryChartMenuView._modelSnapshotForTesting(
                periodRawValue: "daily",
                samples: samples,
                provider: .codex))

        #expect(model.pointCount == 3)
        #expect(model.axisIndexes == [0, 2])
        #expect(model.xDomain == -0.5...29.5)
        #expect(model.selectedSource == "primary:300")
        #expect(model.usedPercents.count == 3)
        #expect(abs(model.usedPercents[0] - (62.0 * 5.0 / 24.0)) < 0.000_1)
        #expect(model.usedPercents[1] == 0)
        #expect(abs(model.usedPercents[2] - (20.0 * 5.0 / 24.0)) < 0.000_1)
    }

    @MainActor
    @Test
    func dailyModelShowsTrailingZeroBarsUpToReferenceDay() throws {
        let calendar = Calendar(identifier: .gregorian)
        let firstBoundary = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone.current,
            year: 2026,
            month: 3,
            day: 4,
            hour: 10,
            minute: 0)))
        let lastBoundary = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone.current,
            year: 2026,
            month: 3,
            day: 6,
            hour: 10,
            minute: 0)))
        let referenceDate = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone.current,
            year: 2026,
            month: 3,
            day: 8,
            hour: 12,
            minute: 0)))
        let samples = [
            makePlanSample(
                at: lastBoundary.addingTimeInterval(-30 * 60),
                primary: 20,
                secondary: nil,
                primaryWindowMinutes: 300,
                primaryResetsAt: lastBoundary),
            makePlanSample(
                at: firstBoundary.addingTimeInterval(-30 * 60),
                primary: 62,
                secondary: nil,
                primaryWindowMinutes: 300,
                primaryResetsAt: firstBoundary),
        ]

        let model = try #require(
            PlanUtilizationHistoryChartMenuView._modelSnapshotForTesting(
                periodRawValue: "daily",
                samples: samples,
                provider: .codex,
                referenceDate: referenceDate))

        #expect(model.pointCount == 5)
        #expect(model.axisIndexes == [0, 4])
        #expect(model.usedPercents.count == 5)
        #expect(abs(model.usedPercents[0] - (62.0 * 5.0 / 24.0)) < 0.000_1)
        #expect(model.usedPercents[1] == 0)
        #expect(abs(model.usedPercents[2] - (20.0 * 5.0 / 24.0)) < 0.000_1)
        #expect(model.usedPercents[3] == 0)
        #expect(model.usedPercents[4] == 0)
    }

    @MainActor
    @Test
    func weeklyModelShowsZeroBarsForMissingWeeks() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 6)))
        let samples = [
            makePlanSample(
                at: now,
                primary: 10,
                secondary: 35,
                primaryWindowMinutes: 300,
                secondaryWindowMinutes: 10080),
            makePlanSample(
                at: now.addingTimeInterval(-7 * 24 * 3600),
                primary: 20,
                secondary: 48,
                primaryWindowMinutes: 300,
                secondaryWindowMinutes: 10080),
            makePlanSample(
                at: now.addingTimeInterval(-21 * 24 * 3600),
                primary: 30,
                secondary: 62,
                primaryWindowMinutes: 300,
                secondaryWindowMinutes: 10080),
        ]

        let model = try #require(
            PlanUtilizationHistoryChartMenuView._modelSnapshotForTesting(
                periodRawValue: "weekly",
                samples: samples,
                provider: .codex))

        #expect(model.pointCount == 4)
        #expect(model.axisIndexes == [3])
        #expect(model.xDomain == -0.5...23.5)
        #expect(model.selectedSource == "secondary:10080")
        #expect(model.usedPercents == [62, 0, 48, 35])
    }

    @MainActor
    @Test
    func monthlyModelDerivesFromSecondaryWindowHistory() throws {
        let calendar = Calendar(identifier: .gregorian)
        let start = try #require(calendar.date(from: DateComponents(year: 2024, month: 1, day: 1)))
        var samples: [PlanUtilizationHistorySample] = []

        for monthOffset in 0..<30 {
            let date = try #require(calendar.date(byAdding: .month, value: monthOffset, to: start))
            samples.append(makePlanSample(
                at: date,
                primary: nil,
                secondary: Double((monthOffset % 10) * 10),
                secondaryWindowMinutes: 10080))
        }

        let model = try #require(
            PlanUtilizationHistoryChartMenuView._modelSnapshotForTesting(
                periodRawValue: "monthly",
                samples: samples,
                provider: .codex))

        #expect(model.pointCount == 24)
        #expect(model.axisIndexes == [23])
        #expect(model.xDomain == -0.5...23.5)
        #expect(model.selectedSource == "secondary:10080")
        #expect(model.usedPercents.count == 24)
    }

    @MainActor
    @Test
    func dailyModelHidesFreeCodexSevenDayOnlyHistory() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 6)))
        let samples = [
            makePlanSample(at: now, primary: 20, secondary: nil, primaryWindowMinutes: 10080),
            makePlanSample(
                at: now.addingTimeInterval(-7 * 24 * 3600),
                primary: 48,
                secondary: nil,
                primaryWindowMinutes: 10080),
        ]

        let model = try #require(
            PlanUtilizationHistoryChartMenuView._modelSnapshotForTesting(
                periodRawValue: "daily",
                samples: samples,
                provider: .codex))

        #expect(model.pointCount == 0)
        #expect(model.selectedSource == nil)
    }

    @MainActor
    @Test
    func freeCodexSevenDayOnlyHistoryShowsWeeklyAndMonthlyTabsOnly() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 6)))
        let samples = [
            makePlanSample(at: now, primary: 20, secondary: nil, primaryWindowMinutes: 10080),
            makePlanSample(
                at: now.addingTimeInterval(-7 * 24 * 3600),
                primary: 48,
                secondary: nil,
                primaryWindowMinutes: 10080),
        ]

        let visiblePeriods = PlanUtilizationHistoryChartMenuView._visiblePeriodsForTesting(samples: samples)

        #expect(visiblePeriods == ["weekly", "monthly"])
    }

    @Test
    func fiveHourOnlyHistoryShowsAllTabs() {
        let base = Date(timeIntervalSince1970: Double(18000 * 100_000))
        let samples = [
            makePlanSample(at: base.addingTimeInterval(60), primary: 20, secondary: nil, primaryWindowMinutes: 300),
            makePlanSample(at: base.addingTimeInterval(3600), primary: 10, secondary: nil, primaryWindowMinutes: 300),
            makePlanSample(at: base.addingTimeInterval(18060), primary: 40, secondary: nil, primaryWindowMinutes: 300),
        ]

        let visiblePeriods = PlanUtilizationHistoryChartMenuView._visiblePeriodsForTesting(samples: samples)

        #expect(visiblePeriods == ["daily", "weekly", "monthly"])
    }

    @MainActor
    @Test
    func weeklyAndMonthlyModelsUsePrimaryWhenItIsTheBestEligibleWindow() throws {
        let calendar = Calendar(identifier: .gregorian)
        let firstBoundary = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone.current,
            year: 2026,
            month: 3,
            day: 8,
            hour: 0,
            minute: 0)))
        let secondBoundary = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone.current,
            year: 2026,
            month: 3,
            day: 15,
            hour: 0,
            minute: 0)))
        let thirdBoundary = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone.current,
            year: 2026,
            month: 3,
            day: 22,
            hour: 0,
            minute: 0)))
        let samples = [
            makePlanSample(
                at: firstBoundary.addingTimeInterval(-30 * 60),
                primary: 62,
                secondary: nil,
                primaryWindowMinutes: 10080,
                primaryResetsAt: firstBoundary),
            makePlanSample(
                at: secondBoundary.addingTimeInterval(-30 * 60),
                primary: 48,
                secondary: nil,
                primaryWindowMinutes: 10080,
                primaryResetsAt: secondBoundary),
            makePlanSample(
                at: thirdBoundary.addingTimeInterval(-30 * 60),
                primary: 20,
                secondary: nil,
                primaryWindowMinutes: 10080,
                primaryResetsAt: thirdBoundary),
        ]

        let weeklyModel = try #require(
            PlanUtilizationHistoryChartMenuView._modelSnapshotForTesting(
                periodRawValue: "weekly",
                samples: samples,
                provider: .codex))
        let monthlyModel = try #require(
            PlanUtilizationHistoryChartMenuView._modelSnapshotForTesting(
                periodRawValue: "monthly",
                samples: samples,
                provider: .codex))

        #expect(weeklyModel.pointCount == 3)
        #expect(weeklyModel.selectedSource == "primary:10080")
        #expect(monthlyModel.pointCount == 1)
        #expect(monthlyModel.selectedSource == "primary:10080")
        #expect(weeklyModel.usedPercents == [62, 48, 20])
        #expect(monthlyModel.usedPercents.count == 1)
        #expect(abs(monthlyModel.usedPercents[0] - ((62.0 + 48.0 + 20.0) * 7.0 / 31.0)) < 0.000_1)
    }

    @MainActor
    @Test
    func weeklyModelDerivesFromPrimaryFiveHourHistoryWhenSevenDayWindowIsMissing() throws {
        let base = Date(timeIntervalSince1970: Double(18000 * 100_000))
        let samples = [
            makePlanSample(at: base.addingTimeInterval(60), primary: 20, secondary: nil, primaryWindowMinutes: 300),
            makePlanSample(at: base.addingTimeInterval(3600), primary: 10, secondary: nil, primaryWindowMinutes: 300),
            makePlanSample(at: base.addingTimeInterval(18060), primary: 40, secondary: nil, primaryWindowMinutes: 300),
        ]

        let model = try #require(
            PlanUtilizationHistoryChartMenuView._modelSnapshotForTesting(
                periodRawValue: "weekly",
                samples: samples,
                provider: .codex))

        #expect(model.pointCount == 1)
        #expect(model.selectedSource == "primary:300")
        #expect(model.usedPercents.count == 1)
        #expect(abs(model.usedPercents[0] - ((20.0 * 5.0 + 40.0 * 5.0) / (7.0 * 24.0))) < 0.000_1)
    }

    @MainActor
    @Test
    func detailLinesShowUsedAndWastedOnSingleLineForDerivedData() throws {
        let calendar = Calendar(identifier: .gregorian)
        let boundary = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone.current,
            year: 2026,
            month: 3,
            day: 7,
            hour: 5,
            minute: 0)))
        let samples = [
            makePlanSample(
                at: boundary.addingTimeInterval(-30 * 60),
                primary: 48,
                secondary: nil,
                primaryWindowMinutes: 300,
                primaryResetsAt: boundary),
        ]

        let detail = try #require(
            PlanUtilizationHistoryChartMenuView._detailLinesForTesting(
                periodRawValue: "daily",
                samples: samples,
                provider: .codex))

        #expect(detail.primary == "Mar 7: 10% used, 90% wasted")
        #expect(detail.secondary == "Estimated from provider-reported 5-hour windows.")
    }

    @MainActor
    @Test
    func exactFitModelUsesDirectProviderReportedCopy() throws {
        let calendar = Calendar(identifier: .gregorian)
        let boundary = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone.current,
            year: 2026,
            month: 3,
            day: 15,
            hour: 5,
            minute: 0)))
        let samples = [
            makePlanSample(
                at: boundary.addingTimeInterval(-30 * 60),
                primary: nil,
                secondary: 35,
                secondaryWindowMinutes: 10080,
                secondaryResetsAt: boundary),
        ]

        let model = try #require(
            PlanUtilizationHistoryChartMenuView._modelSnapshotForTesting(
                periodRawValue: "weekly",
                samples: samples,
                provider: .codex))

        #expect(model.provenanceText == "Provider-reported weekly usage.")
    }

    @Test
    func chartEmptyStateShowsRefreshingWhileLoading() throws {
        let text = try #require(
            PlanUtilizationHistoryChartMenuView._emptyStateTextForTesting(
                periodRawValue: "daily",
                isRefreshing: true))

        #expect(text == "Refreshing...")
    }

    @Test
    func chartEmptyStateShowsPeriodSpecificMessageWhenNotRefreshing() throws {
        let text = try #require(
            PlanUtilizationHistoryChartMenuView._emptyStateTextForTesting(
                periodRawValue: "weekly",
                isRefreshing: false))

        #expect(text == "No weekly utilization data yet.")
    }

    @MainActor
    @Test
    func makeStoreUsesIsolatedTemporaryStorage() throws {
        let store = Self.makeStore()
        let temporaryRoot = FileManager.default.temporaryDirectory.standardizedFileURL.path
        let configURL = store.settings.configStore.fileURL.standardizedFileURL
        let planHistoryURL = try #require(store.planUtilizationHistoryStore.fileURL?.standardizedFileURL)

        #expect(configURL.path.hasPrefix(temporaryRoot))
        #expect(configURL != CodexBarConfigStore.defaultURL().standardizedFileURL)
        #expect(planHistoryURL.path.hasPrefix(temporaryRoot))
    }

    @MainActor
    @Test
    func planHistorySelectsCurrentAccountBucket() throws {
        let store = Self.makeStore()
        let aliceSnapshot = Self.makeSnapshot(provider: .codex, email: "alice@example.com")
        let bobSnapshot = Self.makeSnapshot(provider: .codex, email: "bob@example.com")
        let aliceKey = try #require(
            UsageStore._planUtilizationAccountKeyForTesting(
                provider: .codex,
                snapshot: aliceSnapshot))
        let bobKey = try #require(
            UsageStore._planUtilizationAccountKeyForTesting(
                provider: .codex,
                snapshot: bobSnapshot))

        let aliceSample = makePlanSample(at: Date(timeIntervalSince1970: 1_700_000_000), primary: 10, secondary: 20)
        let bobSample = makePlanSample(at: Date(timeIntervalSince1970: 1_700_086_400), primary: 40, secondary: 50)

        store.planUtilizationHistory[.codex] = PlanUtilizationHistoryBuckets(
            unscoped: [makePlanSample(at: Date(timeIntervalSince1970: 1_699_913_600), primary: 90, secondary: 90)],
            accounts: [
                aliceKey: [aliceSample],
                bobKey: [bobSample],
            ])

        store._setSnapshotForTesting(aliceSnapshot, provider: .codex)
        #expect(store.planUtilizationHistory(for: .codex) == [
            makePlanSample(at: Date(timeIntervalSince1970: 1_699_913_600), primary: 90, secondary: 90),
            aliceSample,
        ])

        store._setSnapshotForTesting(bobSnapshot, provider: .codex)
        #expect(store.planUtilizationHistory(for: .codex) == [bobSample])
    }

    @MainActor
    @Test
    func recordPlanHistoryPersistsWindowMetadataFromSnapshot() async throws {
        let store = Self.makeStore()
        let primaryReset = Date(timeIntervalSince1970: 1_710_000_000)
        let secondaryReset = Date(timeIntervalSince1970: 1_710_086_400)
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 110,
                windowMinutes: 300,
                resetsAt: primaryReset,
                resetDescription: "5h"),
            secondary: RateWindow(
                usedPercent: -20,
                windowMinutes: 10080,
                resetsAt: secondaryReset,
                resetDescription: "7d"),
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: "alice@example.com",
                accountOrganization: nil,
                loginMethod: "free"))
        store._setSnapshotForTesting(snapshot, provider: .codex)

        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: snapshot,
            now: Date(timeIntervalSince1970: 1_700_000_000))

        let sample = try #require(store.planUtilizationHistory(for: .codex).last)
        #expect(sample.primaryUsedPercent == 100)
        #expect(sample.primaryWindowMinutes == 300)
        #expect(sample.primaryResetsAt == primaryReset)
        #expect(sample.secondaryUsedPercent == 0)
        #expect(sample.secondaryWindowMinutes == 10080)
        #expect(sample.secondaryResetsAt == secondaryReset)
    }

    @MainActor
    @Test
    func recordPlanHistoryKeepsMissingWindowValuesNil() async throws {
        let store = Self.makeStore()
        let snapshot = Self.makeSnapshot(provider: .codex, email: "alice@example.com")
        store._setSnapshotForTesting(snapshot, provider: .codex)

        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: snapshot,
            now: Date(timeIntervalSince1970: 1_700_000_000))

        let sample = try #require(store.planUtilizationHistory(for: .codex).last)
        #expect(sample.primaryWindowMinutes == nil)
        #expect(sample.primaryResetsAt == nil)
        #expect(sample.secondaryWindowMinutes == nil)
        #expect(sample.secondaryResetsAt == nil)
    }

    @MainActor
    @Test
    func concurrentPlanHistoryWritesCoalesceWithinSingleHourBucket() async throws {
        let store = Self.makeStore()
        let snapshot = Self.makeSnapshot(provider: .codex, email: "alice@example.com")
        store._setSnapshotForTesting(snapshot, provider: .codex)
        let calendar = Calendar(identifier: .gregorian)
        let hourStart = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone(secondsFromGMT: 0),
            year: 2026,
            month: 3,
            day: 17,
            hour: 10)))
        let writeTimes = [
            hourStart.addingTimeInterval(5 * 60),
            hourStart.addingTimeInterval(25 * 60),
            hourStart.addingTimeInterval(45 * 60),
        ]

        await withTaskGroup(of: Void.self) { group in
            for writeTime in writeTimes {
                group.addTask {
                    await store.recordPlanUtilizationHistorySample(
                        provider: .codex,
                        snapshot: snapshot,
                        now: writeTime)
                }
            }
        }

        let history = try #require(store.planUtilizationHistory[.codex]?.accounts.values.first)
        #expect(history.count == 1)
        let recordedAt = try #require(history.last?.capturedAt)
        #expect(writeTimes.contains(recordedAt))
    }

    @MainActor
    @Test
    func codexPlanHistoryFallsBackToUnscopedBucketWhenIdentityIsUnavailable() {
        let store = Self.makeStore()
        let sample = makePlanSample(at: Date(timeIntervalSince1970: 1_700_000_000), primary: 20, secondary: 30)

        store.planUtilizationHistory[.codex] = PlanUtilizationHistoryBuckets(unscoped: [sample])
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: nil,
                secondary: nil,
                updatedAt: Date()),
            provider: .codex)

        #expect(store.planUtilizationHistory(for: .codex) == [sample])
    }

    @MainActor
    @Test
    func firstResolvedCodexIdentityAdoptsUnscopedHistory() throws {
        let store = Self.makeStore()
        let unscopedSample = makePlanSample(
            at: Date(timeIntervalSince1970: 1_700_000_000),
            primary: 15,
            secondary: 25)
        store.planUtilizationHistory[.codex] = PlanUtilizationHistoryBuckets(unscoped: [unscopedSample])

        let resolvedSnapshot = Self.makeSnapshot(provider: .codex, email: "alice@example.com")
        let resolvedKey = try #require(
            UsageStore._planUtilizationAccountKeyForTesting(
                provider: .codex,
                snapshot: resolvedSnapshot))
        store._setSnapshotForTesting(resolvedSnapshot, provider: .codex)

        let history = store.planUtilizationHistory(for: .codex)

        #expect(history == [unscopedSample])
        let buckets = try #require(store.planUtilizationHistory[.codex])
        #expect(buckets.unscoped.isEmpty)
        #expect(buckets.accounts[resolvedKey] == [unscopedSample])
    }

    @MainActor
    @Test
    func codexHistoryWithoutIdentityFallsBackToLastResolvedAccount() async {
        let store = Self.makeStore()
        let resolvedSnapshot = Self.makeSnapshot(provider: .codex, email: "alice@example.com")
        store._setSnapshotForTesting(resolvedSnapshot, provider: .codex)

        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: resolvedSnapshot,
            now: Date(timeIntervalSince1970: 1_700_000_000))

        let identitylessSnapshot = UsageSnapshot(
            primary: resolvedSnapshot.primary,
            secondary: resolvedSnapshot.secondary,
            updatedAt: resolvedSnapshot.updatedAt)
        store._setSnapshotForTesting(identitylessSnapshot, provider: .codex)

        let history = store.planUtilizationHistory(for: .codex)

        #expect(history.count == 1)
        #expect(history.first?.primaryUsedPercent == 10)
        #expect(history.first?.secondaryUsedPercent == 20)
    }

    @Test
    func runtimeDoesNotLoadUnsupportedPlanHistoryFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = root
            .appendingPathComponent("com.steipete.codexbar", isDirectory: true)
            .appendingPathComponent("plan-utilization-history.json")
        let store = PlanUtilizationHistoryStore(fileURL: url)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)

        let unsupportedJSON = """
        {
          "version": 999,
          "providers": {
            "codex": {
              "unscoped": [],
              "accounts": {}
            }
          }
        }
        """
        try Data(unsupportedJSON.utf8).write(to: url, options: Data.WritingOptions.atomic)

        let loaded = store.load()

        #expect(loaded.isEmpty)
    }

    @Test
    func storeRoundTripsAccountBucketsWithWindowMetadata() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = root
            .appendingPathComponent("com.steipete.codexbar", isDirectory: true)
            .appendingPathComponent("plan-utilization-history.json")
        let store = PlanUtilizationHistoryStore(fileURL: url)
        let primaryReset = Date(timeIntervalSince1970: 1_710_000_000)
        let secondaryReset = Date(timeIntervalSince1970: 1_710_086_400)
        let aliceSample = makePlanSample(
            at: Date(timeIntervalSince1970: 1_700_000_000),
            primary: 10,
            secondary: 20,
            primaryWindowMinutes: 300,
            primaryResetsAt: primaryReset,
            secondaryWindowMinutes: 10080,
            secondaryResetsAt: secondaryReset)
        let legacySample = makePlanSample(
            at: Date(timeIntervalSince1970: 1_699_913_600),
            primary: 50,
            secondary: 60)
        let buckets = PlanUtilizationHistoryBuckets(
            preferredAccountKey: "alice",
            unscoped: [legacySample],
            accounts: ["alice": [aliceSample]])

        store.save([.codex: buckets])
        let loaded = store.load()

        #expect(loaded == [.codex: buckets])
    }
}

extension UsageStorePlanUtilizationTests {
    @MainActor
    static func makeStore() -> UsageStore {
        let suiteName = "UsageStorePlanUtilizationTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Failed to create isolated UserDefaults suite for tests")
        }
        defaults.removePersistentDomain(forName: suiteName)
        let configStore = testConfigStore(suiteName: suiteName)
        let planHistoryStore = testPlanUtilizationHistoryStore(suiteName: suiteName)
        let temporaryRoot = FileManager.default.temporaryDirectory.standardizedFileURL.path
        precondition(configStore.fileURL.standardizedFileURL.path.hasPrefix(temporaryRoot))
        precondition(configStore.fileURL.standardizedFileURL != CodexBarConfigStore.defaultURL().standardizedFileURL)
        if let historyURL = planHistoryStore.fileURL?.standardizedFileURL {
            precondition(historyURL.path.hasPrefix(temporaryRoot))
        }
        let isolatedSettings = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            tokenAccountStore: InMemoryTokenAccountStore())
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: isolatedSettings,
            planUtilizationHistoryStore: planHistoryStore,
            startupBehavior: .testing)
        store.planUtilizationHistory = [:]
        return store
    }

    static func makeSnapshot(provider: UsageProvider, email: String) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(usedPercent: 10, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 20, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: provider,
                accountEmail: email,
                accountOrganization: nil,
                loginMethod: "plus"))
    }
}

func makePlanSample(
    at capturedAt: Date,
    primary: Double?,
    secondary: Double?,
    primaryWindowMinutes: Int? = nil,
    primaryResetsAt: Date? = nil,
    secondaryWindowMinutes: Int? = nil,
    secondaryResetsAt: Date? = nil) -> PlanUtilizationHistorySample
{
    PlanUtilizationHistorySample(
        capturedAt: capturedAt,
        primaryUsedPercent: primary,
        primaryWindowMinutes: primaryWindowMinutes,
        primaryResetsAt: primaryResetsAt,
        secondaryUsedPercent: secondary,
        secondaryWindowMinutes: secondaryWindowMinutes,
        secondaryResetsAt: secondaryResetsAt)
}
