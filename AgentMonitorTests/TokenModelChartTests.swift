import Foundation
import XCTest
@testable import AgentMonitor

final class TokenModelChartTests: XCTestCase {
    func testFilterSelectionTogglesBackToOverviewAndKeepsModesExclusive() {
        XCTAssertEqual(TokenUsageFilter.toggling(.gpt, current: nil), .family(.gpt))
        XCTAssertNil(TokenUsageFilter.toggling(.gpt, current: .family(.gpt)))
        XCTAssertEqual(
            TokenUsageFilter.toggling(modelID: "openai/gpt-6-astra", current: .family(.gpt)),
            .model("gpt-6-astra")
        )
        XCTAssertNil(TokenUsageFilter.toggling(modelID: "gpt-6-astra", current: .model("gpt-6-astra")))
    }

    func testObservedProviderNamesHavePresetFamilies() {
        XCTAssertEqual(TokenModelCatalog.canonicalID("google-antigravity/gemini-3.8-flash-high"), "gemini-3.8-flash")
        XCTAssertEqual(TokenModelCatalog.family(for: "google-antigravity/gemini-future"), .gemini)
        XCTAssertEqual(TokenModelCatalog.family(for: "k3-256k"), .kimi)
        XCTAssertEqual(TokenModelCatalog.family(for: "codex-auto-review"), .unknown)
    }

    func testKnownButUnrankedModelsUseFamilyMidpoint() {
        for id in ["gpt-5.4", "claude-sonnet", "gemini-2.5-pro", "gpt-future"] {
            XCTAssertEqual(TokenModelCatalog.normalizedRank(for: id), 0.5)
        }
    }

    func testCatalogKeepsExplicitProviderAliasesAndUnknownRawIDs() {
        XCTAssertEqual(
            TokenModelCatalog.canonicalID("openai/gpt-5.4-2026-03-05"),
            "gpt-5.4"
        )
        XCTAssertEqual(
            TokenModelCatalog.canonicalID("gemini-3.7-flash"),
            "gemini-3.7-flash"
        )
        XCTAssertEqual(
            TokenModelCatalog.canonicalID("deepseek-v4-flash-vision-exp"),
            "deepseek-v4-vision"
        )
        XCTAssertEqual(
            TokenModelCatalog.canonicalID("codex-auto-review"),
            "codex-auto-review"
        )
        XCTAssertEqual(TokenModelCatalog.family(for: "codex-auto-review"), .unknown)
    }

    func testCatalogKeepsSameDepthVariantsDistinct() {
        XCTAssertNotEqual(
            TokenModelCatalog.canonicalID("grok-4.6"),
            TokenModelCatalog.canonicalID("grok-4.6-build")
        )
        XCTAssertEqual(
            TokenModelCatalog.rank(for: "grok-4.6"),
            TokenModelCatalog.rank(for: "grok-4.6-build")
        )
        XCTAssertNotEqual(
            TokenModelCatalog.canonicalID("deepseek-v4-flash"),
            TokenModelCatalog.canonicalID("deepseek-v4-flash-vision-exp")
        )
        XCTAssertEqual(
            TokenModelCatalog.rank(for: "deepseek-v4-flash"),
            TokenModelCatalog.rank(for: "deepseek-v4-flash-vision-exp")
        )
    }

    func testFamilyRankNormalizationDoesNotDependOnCurrentRange() {
        let claudeBefore = TokenModelCatalog.normalizedRank(rank: 2, familyRanks: [4, 3, 2])
        let claudeAfter = TokenModelCatalog.normalizedRank(rank: 2, familyRanks: [4, 3, 2])
        let gptWithNewStrongest = TokenModelCatalog.normalizedRank(
            rank: 2,
            familyRanks: [8, 4, 3, 2, 1]
        )

        XCTAssertEqual(claudeBefore, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(claudeAfter, claudeBefore, accuracy: 0.000_001)
        XCTAssertEqual(gptWithNewStrongest, 0.25, accuracy: 0.000_001)
        XCTAssertEqual(TokenModelCatalog.normalizedRank(for: "gpt-future-preview"), 0.5, accuracy: 0.000_001)
        XCTAssertEqual(TokenModelCatalog.normalizedRank(for: "codex-auto-review"), 0, accuracy: 0.000_001)
        XCTAssertEqual(
            TokenModelCatalog.normalizedRank(rank: 99, familyRanks: [4, 3, 2]),
            1,
            accuracy: 0.000_001
        )
    }

    func testUnitGeometryPreservesPartialFinalCellAndMixedModelCrossings() {
        XCTAssertEqual(TokenUsageChartGeometry.unitCellRanges(for: 0), [])
        XCTAssertEqual(
            TokenUsageChartGeometry.unitCellRanges(for: 30_000_000),
            [0.0...30_000_000.0]
        )
        XCTAssertEqual(
            TokenUsageChartGeometry.unitCellRanges(for: 100_000_000),
            [0.0...100_000_000.0]
        )
        XCTAssertEqual(
            TokenUsageChartGeometry.unitCellRanges(for: 240_000_000),
            [
                0.0...100_000_000.0,
                100_000_000.0...200_000_000.0,
                200_000_000.0...240_000_000.0
            ]
        )

        let mixed = TokenUsageChartGeometry.modelRanges([
            (modelID: "gpt-6-astra", tokens: 240_000_000),
            (modelID: "claude-opus-5", tokens: 70_000_000)
        ])
        XCTAssertEqual(mixed, [
            TokenUsageModelRange(
                modelID: "gpt-6-astra",
                lowerBound: 0,
                upperBound: 240_000_000
            ),
            TokenUsageModelRange(
                modelID: "claude-opus-5",
                lowerBound: 240_000_000,
                upperBound: 310_000_000
            )
        ])
        XCTAssertEqual(
            TokenUsageChartGeometry.unitBoundaries(upTo: 300_000_000),
            [100_000_000, 200_000_000, 300_000_000]
        )
    }

    func testModelFilterUsesPerModelTotalsAndLeavesAbsentModelEmpty() {
        let start = Date(timeIntervalSince1970: 0)
        let astra = TokenUsageModelTotals(inputTokens: 80, cacheTokens: 10, outputTokens: 10)
        let claude = TokenUsageModelTotals(inputTokens: 30, cacheTokens: 5, outputTokens: 5)
        let bucket = TokenUsageBucket(
            start: start,
            inputTokens: 110,
            cacheTokens: 15,
            outputTokens: 15,
            models: [
                "gpt-6-astra": astra,
                "claude-opus-5": claude
            ]
        )
        let snapshot = TokenUsageSnapshot(
            range: .today,
            buckets: [bucket],
            collectedAt: start
        )

        XCTAssertEqual(snapshot.filtered(model: "gpt-6-astra").totalTokens, 100)
        XCTAssertEqual(snapshot.filtered(model: "claude-opus-5").totalTokens, 40)
        XCTAssertEqual(snapshot.filtered(model: "gpt-5.6-luna").totalTokens, 0)
        XCTAssertEqual(snapshot.filtered(model: "gpt-6-astra").modelIDs, ["gpt-6-astra"])
    }

    func testFamilyFilterAggregatesModelsAndPendingReviewWithinFamily() {
        let start = Date(timeIntervalSince1970: 0)
        let bucket = TokenUsageBucket(
            start: start,
            inputTokens: 150,
            cacheTokens: 20,
            outputTokens: 15,
            models: [
                "gpt-6-astra": TokenUsageModelTotals(inputTokens: 80, cacheTokens: 10, outputTokens: 10),
                "gpt-5.6-sol": TokenUsageModelTotals(inputTokens: 40, cacheTokens: 5, outputTokens: 5),
                "claude-opus-5": TokenUsageModelTotals(inputTokens: 30, cacheTokens: 5, outputTokens: 0)
            ],
            pendingModels: [
                "gpt-6-astra": TokenUsageModelTotals(inputTokens: 7, cacheTokens: 2, outputTokens: 1),
                "claude-opus-5": TokenUsageModelTotals(inputTokens: 20, cacheTokens: 0, outputTokens: 0)
            ],
            pendingCount: 3,
            pendingReasons: ["review": 3],
            pendingCountsByModel: ["gpt-6-astra": 1, "claude-opus-5": 2],
            pendingReasonsByModel: [
                "gpt-6-astra": ["review": 1],
                "claude-opus-5": ["review": 2]
            ]
        )
        let snapshot = TokenUsageSnapshot(range: .today, buckets: [bucket], collectedAt: start)
        let filtered = snapshot.filtered(family: .gpt)

        XCTAssertEqual(filtered.totalTokens, 150)
        XCTAssertEqual(Set(filtered.modelIDs), ["gpt-6-astra", "gpt-5.6-sol"])
        XCTAssertEqual(
            filtered.pendingReviewSummary,
            TokenUsageReviewSummary(count: 1, tokens: 10, reasons: ["review": 1])
        )
    }

    @MainActor
    func testDisplayYUpperBoundUsesWholeTokenCells() {
        let start = Date(timeIntervalSince1970: 0)
        let bucket = TokenUsageBucket(start: start, inputTokens: 240_000_000)
        XCTAssertEqual(
            TokenUsageChartView.chartDisplayYUpperBound(for: [bucket]),
            300_000_000
        )
    }

    @MainActor
    func testTooltipPositionCentersInsideVeryNarrowMenu() {
        let position = TokenUsageChartView.tooltipPosition(
            for: CGPoint(x: 20, y: 10),
            in: CGSize(width: 120, height: 70)
        )
        XCTAssertEqual(position.x, 60)
        XCTAssertEqual(position.y, 35)
    }
}
