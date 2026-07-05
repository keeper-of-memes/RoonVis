#include "TestHarness.h"

#include "LearnedSlowPresetStore.h"

#include <map>
#include <string>
#include <vector>

using namespace RoonVis;

namespace
{

void TestCatastrophicIsLearnedImmediately()
{
    LearnedSlowPresetStore store;
    LearnedSlowDecision d = store.RecordDetection("boom.milk", /*catastrophic=*/true);
    CHECK(d.nowLearnedSlow);
    CHECK(d.stateChanged);
    CHECK(store.IsLearnedSlow("boom.milk"));
    CHECK(store.ConfirmedNames().count("boom.milk") == 1);
    // A catastrophic detection must not leave a stray pending count.
    CHECK(store.PendingCounts().empty());
}

void TestSingleNonCatastrophicDoesNotBan()
{
    LearnedSlowPresetStore store;
    LearnedSlowDecision d = store.RecordDetection("cold.milk", /*catastrophic=*/false);
    CHECK(!d.nowLearnedSlow);
    CHECK(d.stateChanged);
    CHECK(!store.IsLearnedSlow("cold.milk"));
    CHECK(store.PendingCounts().at("cold.milk") == 1);
}

void TestTwoNonCatastrophicDetectionsPromote()
{
    LearnedSlowPresetStore store;
    CHECK(!store.RecordDetection("slow.milk", false).nowLearnedSlow);
    LearnedSlowDecision second = store.RecordDetection("slow.milk", false);
    CHECK(second.nowLearnedSlow);
    CHECK(second.stateChanged);
    CHECK(store.IsLearnedSlow("slow.milk"));
    // Once promoted, the pending count is cleared.
    CHECK(store.PendingCounts().count("slow.milk") == 0);
}

void TestAlreadyConfirmedReportsNoStateChange()
{
    LearnedSlowPresetStore store;
    store.RecordDetection("boom.milk", true);
    LearnedSlowDecision again = store.RecordDetection("boom.milk", false);
    CHECK(again.nowLearnedSlow);
    CHECK(!again.stateChanged);
}

void TestLoadSeedsConfirmedAndPending()
{
    LearnedSlowPresetStore store;
    store.LoadConfirmed({"confirmed.milk"});
    store.LoadPendingCounts({{"pending.milk", 1}, {"confirmed.milk", 1}, {"junk.milk", 0}});

    CHECK(store.IsLearnedSlow("confirmed.milk"));
    // A confirmed preset must not carry a pending count, and non-positive counts drop.
    CHECK(store.PendingCounts().count("confirmed.milk") == 0);
    CHECK(store.PendingCounts().count("junk.milk") == 0);
    CHECK(store.PendingCounts().at("pending.milk") == 1);

    // The seeded pending preset needs only one more non-catastrophic hit to promote.
    CHECK(store.RecordDetection("pending.milk", false).nowLearnedSlow);
    CHECK(store.IsLearnedSlow("pending.milk"));
}

void TestClearWipesEverything()
{
    LearnedSlowPresetStore store;
    store.RecordDetection("boom.milk", true);
    store.RecordDetection("pending.milk", false);
    store.Clear();
    CHECK(store.ConfirmedNames().empty());
    CHECK(store.PendingCounts().empty());
    CHECK(!store.IsLearnedSlow("boom.milk"));
}

void TestEmptyNameIsIgnored()
{
    LearnedSlowPresetStore store;
    LearnedSlowDecision d = store.RecordDetection("", true);
    CHECK(!d.nowLearnedSlow);
    CHECK(!d.stateChanged);
    CHECK(store.ConfirmedNames().empty());
}

}  // namespace

void RunLearnedSlowPresetStoreTests()
{
    TestCatastrophicIsLearnedImmediately();
    TestSingleNonCatastrophicDoesNotBan();
    TestTwoNonCatastrophicDetectionsPromote();
    TestAlreadyConfirmedReportsNoStateChange();
    TestLoadSeedsConfirmedAndPending();
    TestClearWipesEverything();
    TestEmptyNameIsIgnored();
}
