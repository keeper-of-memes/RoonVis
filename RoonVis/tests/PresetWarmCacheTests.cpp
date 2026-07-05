#include "TestHarness.h"

#include "PresetWarmCache.h"

#include <string>
#include <vector>

using namespace RoonVis;

namespace
{

PresetWarmCandidate Candidate(size_t index)
{
    return {index, "preset-" + std::to_string(index) + ".milk"};
}

void TestChoosesFirstUnwarmedUpcomingPreset()
{
    PresetWarmCache cache;
    std::vector<PresetWarmCandidate> upcoming{Candidate(2), Candidate(3), Candidate(4)};
    PresetWarmCandidate first = cache.ChooseNextCandidate(upcoming);
    CHECK(first.index == 2);

    cache.MarkWarmStarted(first.index, first.path);
    CHECK(cache.ChooseNextCandidate(upcoming).index == 3);
    cache.MarkWarmFinished(first.index, first.path, true);
    CHECK(cache.ChooseNextCandidate(upcoming).index == 3);
}

void TestInFlightDoesNotBecomeWarmOnFailure()
{
    PresetWarmCache cache;
    PresetWarmCandidate preset = Candidate(7);
    cache.MarkWarmStarted(preset.index, preset.path);
    CHECK(cache.IsInFlight(preset.index, preset.path));
    CHECK(cache.InFlightCandidate().index == preset.index);
    CHECK(cache.InFlightCandidate().path == preset.path);
    cache.MarkWarmFinished(preset.index, preset.path, false);
    CHECK(!cache.HasInFlight());
    CHECK(!PresetWarmCandidateIsValid(cache.InFlightCandidate()));
    CHECK(!cache.IsWarm(preset.index, preset.path));
    CHECK(cache.IsFailed(preset.index, preset.path));
    CHECK(!PresetWarmCandidateIsValid(cache.ChooseNextCandidate({preset})));
}

void TestWarmBookkeepingKeepsOnlyMostRecentEntry()
{
    // Only one primary-preload slot exists, so warming a newer preset must evict the
    // older warm entry.
    PresetWarmCache cache;
    PresetWarmCandidate a = Candidate(1);
    PresetWarmCandidate b = Candidate(2);

    cache.MarkWarmFinished(a.index, a.path, true);
    CHECK(cache.WarmCount() == 1);
    CHECK(cache.IsWarm(a.index, a.path));

    cache.MarkWarmFinished(b.index, b.path, true);
    CHECK(cache.WarmCount() == 1);
    CHECK(!cache.IsWarm(a.index, a.path));
    CHECK(cache.IsWarm(b.index, b.path));
}

void TestFailedBookkeepingKeepsOnlyMostRecentEntry()
{
    // The failed list is capped at one entry too: a newer failure evicts the older
    // one, so the older preset becomes eligible for a retry later.
    PresetWarmCache cache;
    PresetWarmCandidate a = Candidate(1);
    PresetWarmCandidate b = Candidate(2);

    cache.MarkWarmFinished(a.index, a.path, false);
    CHECK(cache.FailedCount() == 1);
    CHECK(cache.IsFailed(a.index, a.path));

    cache.MarkWarmFinished(b.index, b.path, false);
    CHECK(cache.FailedCount() == 1);
    CHECK(!cache.IsFailed(a.index, a.path));
    CHECK(cache.IsFailed(b.index, b.path));
    CHECK(cache.ChooseNextCandidate({b, a}).index == a.index);
}

void TestActivePresetIsRemovedFromWarmCache()
{
    PresetWarmCache cache;
    PresetWarmCandidate a = Candidate(1);
    PresetWarmCandidate b = Candidate(2);
    cache.MarkWarmFinished(a.index, a.path, true);
    cache.MarkWarmStarted(b.index, b.path);

    cache.NoteActivePreset(a.index, a.path);
    CHECK(!cache.IsWarm(a.index, a.path));
    CHECK(!cache.IsFailed(a.index, a.path));
    CHECK(cache.HasInFlight());

    cache.NoteActivePreset(b.index, b.path);
    CHECK(!cache.HasInFlight());
}

void TestInvalidCandidatesAreIgnored()
{
    PresetWarmCache cache;
    std::vector<PresetWarmCandidate> upcoming{
        {},
        {5, ""},
        Candidate(6),
    };
    CHECK(cache.ChooseNextCandidate(upcoming).index == 6);

    cache.MarkWarmFinished(6, upcoming[2].path, true);
    CHECK(!PresetWarmCandidateIsValid(cache.ChooseNextCandidate(upcoming)));
}

void TestIdleFrameBudgetAccumulatesSpareTime()
{
    PresetIdleWarmBudget budget(/*frameBudgetSeconds=*/0.016,
                                /*warmAttemptBudgetSeconds=*/0.020,
                                /*requiredIdleFrames=*/3);
    CHECK(!budget.RecordFrame(0.016, 0.016, 0.006, 0.002, false));
    CHECK(!budget.RecordFrame(0.016, 0.016, 0.006, 0.002, false));
    CHECK(budget.RecordFrame(0.016, 0.016, 0.006, 0.002, false));
    CHECK(budget.IdleFrames() == 3);
    CHECK(budget.AccumulatedBudgetSeconds() > 0.020);

    budget.ConsumeWarmAttempt();
    CHECK(budget.IdleFrames() == 0);
    CHECK(budget.AccumulatedBudgetSeconds() == 0.0);
}

void TestIdleFrameBudgetDefaultRequiresNamedFrameCount()
{
    PresetIdleWarmBudget budget;
    const double frameSeconds = kPresetIdleWarmFrameBudgetSeconds;
    for (unsigned frame = 1; frame < kPresetIdleWarmRequiredFrames; frame++)
    {
        CHECK(!budget.RecordFrame(frameSeconds, frameSeconds, frameSeconds * 0.25, frameSeconds * 0.25, false));
    }
    CHECK(budget.IdleFrames() == kPresetIdleWarmRequiredFrames - 1);
    CHECK(budget.RecordFrame(frameSeconds, frameSeconds, frameSeconds * 0.25, frameSeconds * 0.25, false));
    CHECK(budget.IdleFrames() == kPresetIdleWarmRequiredFrames);
}

void TestIdleFrameBudgetPausesDuringTransitionWithoutLosingProgress()
{
    PresetIdleWarmBudget budget(0.016, 0.020, 3);
    CHECK(!budget.RecordFrame(0.016, 0.016, 0.006, 0.002, false));
    CHECK(!budget.RecordFrame(0.016, 0.016, 0.006, 0.002, true));
    CHECK(budget.IdleFrames() == 1);
    CHECK(budget.AccumulatedBudgetSeconds() > 0.0);

    CHECK(!budget.RecordFrame(0.016, 0.016, 0.006, 0.002, false));
    CHECK(budget.RecordFrame(0.016, 0.016, 0.006, 0.002, false));
    CHECK(budget.IdleFrames() == 3);
    CHECK(budget.AccumulatedBudgetSeconds() > 0.020);
}

void TestIdleFrameBudgetResetsOnOverBudgetFrame()
{
    PresetIdleWarmBudget budget(0.016, 0.010, 2);
    CHECK(!budget.RecordFrame(0.016, 0.016, 0.006, 0.002, false));
    CHECK(!budget.RecordFrame(0.016, 0.016, 0.020, 0.001, false));
    CHECK(budget.IdleFrames() == 0);
    CHECK(budget.AccumulatedBudgetSeconds() == 0.0);

    CHECK(!budget.RecordFrame(0.016, 0.016, 0.006, 0.002, false));
    CHECK(!budget.RecordFrame(0.024, 0.016, 0.006, 0.002, false));
    CHECK(budget.IdleFrames() == 0);
    CHECK(budget.AccumulatedBudgetSeconds() == 0.0);
}

}  // namespace

void RunPresetWarmCacheTests()
{
    TestChoosesFirstUnwarmedUpcomingPreset();
    TestInFlightDoesNotBecomeWarmOnFailure();
    TestWarmBookkeepingKeepsOnlyMostRecentEntry();
    TestFailedBookkeepingKeepsOnlyMostRecentEntry();
    TestActivePresetIsRemovedFromWarmCache();
    TestInvalidCandidatesAreIgnored();
    TestIdleFrameBudgetAccumulatesSpareTime();
    TestIdleFrameBudgetDefaultRequiresNamedFrameCount();
    TestIdleFrameBudgetPausesDuringTransitionWithoutLosingProgress();
    TestIdleFrameBudgetResetsOnOverBudgetFrame();
}
