#include "TestHarness.h"

#include "PresetRotationScheduler.h"

using namespace RoonVis;

namespace
{

using Action = PresetRotationScheduler::FailureAction;

void TestSkipsUntilCapThenReverts()
{
    PresetRotationScheduler s(/*skipCap=*/8);
    // First 8 failures skip to the next preset; skip counter climbs 1..8.
    for (unsigned i = 1; i <= 8; ++i)
    {
        CHECK(s.NoteSwitchFailed(/*reverting=*/false, /*hasLastGood=*/true) == Action::SkipToNext);
        CHECK(s.FailureSkips() == i);
    }
    // 9th failure: cap reached, a last-good exists -> revert.
    CHECK(s.NoteSwitchFailed(false, true) == Action::RevertToLastGood);
    CHECK(s.FailuresTotal() == 9);
}

void TestCapReachedNoLastGoodHolds()
{
    PresetRotationScheduler s(2);
    CHECK(s.NoteSwitchFailed(false, false) == Action::SkipToNext);  // skips=1
    CHECK(s.NoteSwitchFailed(false, false) == Action::SkipToNext);  // skips=2 (== cap)
    // Cap reached, no last-good target -> hold confirmed.
    CHECK(s.NoteSwitchFailed(false, false) == Action::HoldConfirmed);
    CHECK(s.FailuresTotal() == 3);
}

void TestRevertReentrantFailureHolds()
{
    PresetRotationScheduler s(1);
    CHECK(s.NoteSwitchFailed(false, true) == Action::SkipToNext);      // skips=1 (== cap)
    CHECK(s.NoteSwitchFailed(false, true) == Action::RevertToLastGood);  // cap reached -> revert
    // The revert load itself fails, re-entering with reverting=true -> hold.
    CHECK(s.NoteSwitchFailed(/*reverting=*/true, /*hasLastGood=*/true) == Action::HoldConfirmed);
}

void TestSwitchRequestedResetsSkipsNotTotal()
{
    PresetRotationScheduler s(8);
    s.NoteSwitchFailed(false, true);  // skips=1
    s.NoteSwitchFailed(false, true);  // skips=2
    CHECK(s.FailureSkips() == 2);
    CHECK(s.FailuresTotal() == 2);
    s.NoteSwitchRequested();          // a new timed/beat request clears the skip run
    CHECK(s.FailureSkips() == 0);
    CHECK(s.FailuresTotal() == 2);    // cumulative total is NOT reset
    // After reset, failures skip again from zero until the cap.
    CHECK(s.NoteSwitchFailed(false, true) == Action::SkipToNext);
    CHECK(s.FailureSkips() == 1);
}

void TestSkipsPersistAcrossSuccessfulSkip()
{
    // A successful skip-to-next load does NOT reset the counter (matches the bridge:
    // only NoteSwitchRequested resets it). Failures keep accumulating toward the cap.
    PresetRotationScheduler s(3);
    CHECK(s.NoteSwitchFailed(false, true) == Action::SkipToNext);  // skips=1
    CHECK(s.NoteSwitchFailed(false, true) == Action::SkipToNext);  // skips=2
    CHECK(s.NoteSwitchFailed(false, true) == Action::SkipToNext);  // skips=3 (== cap)
    CHECK(s.NoteSwitchFailed(false, true) == Action::RevertToLastGood);  // cap -> revert
}

void TestSkipCapAccessor()
{
    PresetRotationScheduler s(8);
    CHECK(s.SkipCap() == 8);
    PresetRotationScheduler def;  // default cap
    CHECK(def.SkipCap() == 8);
}

void TestParseFixedRotationList()
{
    // Basic split, order preserved.
    std::vector<std::string> expected{"a.milk", "b.milk", "c.milk"};
    CHECK(ParseFixedRotationList("a.milk,b.milk,c.milk") == expected);
    // Whitespace trimmed; empty entries (double/leading/trailing commas) dropped.
    CHECK(ParseFixedRotationList(" a.milk , b.milk ,, c.milk ,") == expected);
    // Edges: empty / whitespace-or-comma-only inputs produce an empty list.
    CHECK(ParseFixedRotationList("").empty());
    CHECK(ParseFixedRotationList(" , ,\t").empty());
    // Single entry, no comma.
    CHECK(ParseFixedRotationList("solo.milk") == std::vector<std::string>{"solo.milk"});
    // Pipe delimiter when present: comma-containing filenames pass losslessly
    // (Milkdrop names frequently contain commas; no pack filename contains '|').
    std::vector<std::string> commaNames{"271 nz, m1, i love life.milk", "b.milk"};
    CHECK(ParseFixedRotationList("271 nz, m1, i love life.milk|b.milk") == commaNames);
    CHECK(ParseFixedRotationList(" a.milk | b.milk || c.milk |") == expected);
    // Comma stays the default when no pipe is present (backwards compatibility).
    CHECK(ParseFixedRotationList("a.milk,b.milk,c.milk") == expected);
}

void TestResolveFixedRotationIndexes()
{
    const std::vector<std::string> paths{
        "/bundle/presets/a.milk",
        "/bundle/presets/b.milk",
        "/bundle/presets/c.milk",
    };
    // List order wins over path order; unknown names silently dropped; duplicates kept.
    std::vector<size_t> expected{2, 0, 2};
    CHECK(ResolveFixedRotationIndexes({"c.milk", "missing.milk", "a.milk", "c.milk"}, paths) == expected);
    // Match is on the final path component only — a bare filename path also matches.
    CHECK(ResolveFixedRotationIndexes({"b.milk"}, {"b.milk"}) == std::vector<size_t>{0});
    // No suffix/partial matches.
    CHECK(ResolveFixedRotationIndexes({".milk"}, paths).empty());
    // Edges: empty list / empty paths.
    CHECK(ResolveFixedRotationIndexes({}, paths).empty());
    CHECK(ResolveFixedRotationIndexes({"a.milk"}, {}).empty());
}

}  // namespace

void RunPresetRotationSchedulerTests()
{
    TestSkipsUntilCapThenReverts();
    TestCapReachedNoLastGoodHolds();
    TestRevertReentrantFailureHolds();
    TestSwitchRequestedResetsSkipsNotTotal();
    TestSkipsPersistAcrossSuccessfulSkip();
    TestSkipCapAccessor();
    TestParseFixedRotationList();
    TestResolveFixedRotationIndexes();
}
