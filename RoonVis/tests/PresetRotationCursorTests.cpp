#include "TestHarness.h"

#include "PresetRotationCursor.h"

#include <set>

using namespace RoonVis;

namespace
{

std::function<bool(size_t)> ExcludeSet(std::set<size_t> excluded)
{
    return [excluded](size_t index) { return excluded.count(index) > 0; };
}

void TestBasicAdvance()
{
    const std::vector<size_t> order = {0, 1, 2, 3, 4};
    auto none = ExcludeSet({});

    auto r = AdvanceRotationCursor(order, 2, 1, none);
    CHECK(r.valid && r.index == 3);
    r = AdvanceRotationCursor(order, 2, -1, none);
    CHECK(r.valid && r.index == 1);
    r = AdvanceRotationCursor(order, 4, 1, none); // wrap forward
    CHECK(r.valid && r.index == 0);
    r = AdvanceRotationCursor(order, 0, -1, none); // wrap backward
    CHECK(r.valid && r.index == 4);
    r = AdvanceRotationCursor(order, 1, 2, none); // multi-step
    CHECK(r.valid && r.index == 3);
    r = AdvanceRotationCursor(order, 3, 0, none); // offset 0 = anchor when eligible
    CHECK(r.valid && r.index == 3);
}

// THE bug fix: advancing from an anchor that has just been excluded must
// continue from the anchor's ORDER POSITION, not reset to the front.
void TestExcludedAnchorContinuesInOrder()
{
    const std::vector<size_t> order = {10, 11, 12, 13, 14, 15};

    // Anchor 13 marked slow (excluded); +1 must land on 14 - NOT 10.
    auto r = AdvanceRotationCursor(order, 13, 1, ExcludeSet({13}));
    CHECK(r.valid && r.index == 14);

    // Same, backwards: -1 from excluded anchor lands on 12 - NOT 15.
    r = AdvanceRotationCursor(order, 13, -1, ExcludeSet({13}));
    CHECK(r.valid && r.index == 12);

    // The successor itself is also excluded: skip over it.
    r = AdvanceRotationCursor(order, 13, 1, ExcludeSet({13, 14}));
    CHECK(r.valid && r.index == 15);

    // offset 0 with an excluded anchor resolves forward.
    r = AdvanceRotationCursor(order, 13, 0, ExcludeSet({13}));
    CHECK(r.valid && r.index == 14);
}

// The slow-skip ratchet regression: mark-then-advance repeatedly must WALK the
// order, not loop the head.
void TestMarkThenAdvanceDoesNotRatchet()
{
    const std::vector<size_t> order = {0, 1, 2, 3, 4, 5};
    std::set<size_t> slow;

    size_t anchor = 0;
    std::vector<size_t> visited;
    for (int i = 0; i < 5; i++)
    {
        // Simulate: current preset is marked slow, then we advance.
        slow.insert(anchor);
        auto r = AdvanceRotationCursor(order, anchor, 1,
                                       [&slow](size_t idx) { return slow.count(idx) > 0; });
        REQUIRE(r.valid);
        visited.push_back(r.index);
        anchor = r.index;
    }
    // Must visit 1,2,3,4,5 in order - the historical bug visited 1,2,... only
    // after resetting to the front each time (0-was-gone -> front()).
    CHECK((visited == std::vector<size_t>{1, 2, 3, 4, 5}));
}

void TestAllExcludedInvalid()
{
    const std::vector<size_t> order = {7, 8, 9};
    auto r = AdvanceRotationCursor(order, 8, 1, ExcludeSet({7, 8, 9}));
    CHECK(!r.valid);
    r = AdvanceRotationCursor(order, 8, -1, ExcludeSet({7, 8, 9}));
    CHECK(!r.valid);
    r = AdvanceRotationCursor({}, 0, 1, ExcludeSet({}));
    CHECK(!r.valid);
}

// Anchor left the pack entirely (not merely excluded): degrade to first/last
// eligible - the only remaining reset path.
void TestAnchorGoneFallback()
{
    const std::vector<size_t> order = {3, 4, 5};
    auto r = AdvanceRotationCursor(order, 99, 1, ExcludeSet({}));
    CHECK(r.valid && r.index == 3);
    r = AdvanceRotationCursor(order, 99, -1, ExcludeSet({}));
    CHECK(r.valid && r.index == 5);
    // Fallback still respects exclusion.
    r = AdvanceRotationCursor(order, 99, 1, ExcludeSet({3}));
    CHECK(r.valid && r.index == 4);
    r = AdvanceRotationCursor(order, 99, -1, ExcludeSet({5, 4}));
    CHECK(r.valid && r.index == 3);
}

// loadInitialPreset boundary: anchor at the last order slot, excluded, +1
// wraps cleanly to the first eligible.
void TestBoundaryAnchorExcludedWraps()
{
    const std::vector<size_t> order = {0, 1, 2, 3};
    auto r = AdvanceRotationCursor(order, 3, 1, ExcludeSet({3}));
    CHECK(r.valid && r.index == 0);
    // And if the head is also excluded, keep walking.
    r = AdvanceRotationCursor(order, 3, 1, ExcludeSet({3, 0}));
    CHECK(r.valid && r.index == 1);
}

// Re-eligibility: an entry that was excluded and later un-excluded is reachable
// again at its ORIGINAL order position (the modulo-over-filtered-list approach
// could mis-place it).
void TestReEligibleEntryKeepsPosition()
{
    const std::vector<size_t> order = {0, 1, 2, 3, 4};
    // 2 excluded: 1 -> 3.
    auto r = AdvanceRotationCursor(order, 1, 1, ExcludeSet({2}));
    CHECK(r.valid && r.index == 3);
    // 2 re-eligible: 1 -> 2 again.
    r = AdvanceRotationCursor(order, 1, 1, ExcludeSet({}));
    CHECK(r.valid && r.index == 2);
}

void TestShuffleFingerprint()
{
    // Order-insensitive over both inputs.
    CHECK(ShuffleOrderFingerprint({"a.milk", "b.milk"}, {"s.milk"}) ==
          ShuffleOrderFingerprint({"b.milk", "a.milk"}, {"s.milk"}));
    // Pack change invalidates.
    CHECK(ShuffleOrderFingerprint({"a.milk", "b.milk"}, {}) !=
          ShuffleOrderFingerprint({"a.milk", "c.milk"}, {}));
    // Learned-slow confirmed-set change invalidates.
    CHECK(ShuffleOrderFingerprint({"a.milk", "b.milk"}, {}) !=
          ShuffleOrderFingerprint({"a.milk", "b.milk"}, {"a.milk"}));
    // Concatenation ambiguity guarded ({"ab"} vs {"a","b"}).
    CHECK(ShuffleOrderFingerprint({"ab"}, {}) != ShuffleOrderFingerprint({"a", "b"}, {}));
}

void TestRestoreShuffleOrder()
{
    auto indexFor = [](const std::string &name) -> size_t {
        if (name == "a.milk") return 0;
        if (name == "b.milk") return 1;
        if (name == "c.milk") return 2;
        return SIZE_MAX;
    };

    // Order preserved; entries gone from the pack dropped (filter, not reseed).
    auto order = RestoreShuffleOrder({"c.milk", "gone.milk", "a.milk", "b.milk"}, indexFor);
    CHECK((order == std::vector<size_t>{2, 0, 1}));

    // Hidden/slow entries are NOT the restorer's concern: they stay in the
    // order (exclusion is the advance predicate's job).
    order = RestoreShuffleOrder({"b.milk", "a.milk"}, indexFor);
    CHECK((order == std::vector<size_t>{1, 0}));

    CHECK(RestoreShuffleOrder({}, indexFor).empty());
    CHECK(RestoreShuffleOrder({"gone.milk"}, indexFor).empty());
}

// Mid-session hide against a persisted permutation: the order is untouched,
// the predicate filters, and the cursor keeps walking in order.
void TestPersistedOrderSurvivesMidSessionHide()
{
    auto indexFor = [](const std::string &name) -> size_t {
        if (name == "a.milk") return 0;
        if (name == "b.milk") return 1;
        if (name == "c.milk") return 2;
        if (name == "d.milk") return 3;
        return SIZE_MAX;
    };
    auto order = RestoreShuffleOrder({"c.milk", "a.milk", "d.milk", "b.milk"}, indexFor);
    CHECK((order == std::vector<size_t>{2, 0, 3, 1}));

    // Hide "a.milk" (index 0) mid-session; advancing from it continues to d (3).
    auto r = AdvanceRotationCursor(order, 0, 1, ExcludeSet({0}));
    CHECK(r.valid && r.index == 3);
    // And backwards to c (2).
    r = AdvanceRotationCursor(order, 0, -1, ExcludeSet({0}));
    CHECK(r.valid && r.index == 2);
}

} // namespace

void RunPresetRotationCursorTests()
{
    TestBasicAdvance();
    TestExcludedAnchorContinuesInOrder();
    TestMarkThenAdvanceDoesNotRatchet();
    TestAllExcludedInvalid();
    TestAnchorGoneFallback();
    TestBoundaryAnchorExcludedWraps();
    TestReEligibleEntryKeepsPosition();
    TestShuffleFingerprint();
    TestRestoreShuffleOrder();
    TestPersistedOrderSurvivesMidSessionHide();
}
