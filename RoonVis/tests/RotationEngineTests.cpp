#include "TestHarness.h"

#include "RotationEngine.h"

#include <string>
#include <unordered_set>
#include <vector>

using namespace RoonVis;

namespace
{

// Build a small catalog. `filename` is the DISPLAY NAME (lastPathComponent) the
// engine keys exclusion and fingerprints on, mirroring the bridge.
RotationCatalogEntry MakeEntry(const std::string &filename,
                               const std::string &category,
                               const std::string &subcategory = "Sub",
                               bool favorite = false)
{
    RotationCatalogEntry entry;
    entry.filename = filename;
    entry.title = filename; // human title irrelevant to these tests
    entry.category = category;
    entry.subcategory = subcategory;
    entry.favorite = favorite;
    return entry;
}

std::vector<RotationCatalogEntry> ThreeCategoryCatalog()
{
    // Fractal: 0,2,4  Drawing: 1,5  Waveform: 3
    return {
        MakeEntry("f0.milk", "Fractal"),   // 0
        MakeEntry("d1.milk", "Drawing"),   // 1
        MakeEntry("f2.milk", "Fractal"),   // 2
        MakeEntry("w3.milk", "Waveform"),  // 3
        MakeEntry("f4.milk", "Fractal"),   // 4
        MakeEntry("d5.milk", "Drawing"),   // 5
    };
}

bool Contains(const std::vector<size_t> &v, size_t x)
{
    for (size_t e : v)
    {
        if (e == x)
        {
            return true;
        }
    }
    return false;
}

// (1) Category HOLD when <=1 eligible AND a preset is confirmed: FullOrder empty,
//     NextFrom SIZE_MAX.
void TestCategoryHoldOnSingleEligibleWithConfirm()
{
    // A category with a single member -> only 1 eligible -> HOLD once confirmed.
    std::vector<RotationCatalogEntry> catalog = ThreeCategoryCatalog();
    RotationEngine engine;
    engine.SetCatalog(catalog);
    engine.ReseedShuffle(1);
    engine.SetMode(RotationMode::Category);
    // Anchor on the Waveform member (index 3), which has no siblings.
    engine.SetAnchor(3, 3); // confirmed=3
    const std::vector<size_t> &order = engine.FullOrder();
    CHECK(order.empty());
    CHECK(engine.NextFrom(3, 1) == SIZE_MAX);
}

// (2) Pre-confirm (<=1 eligible, no confirmed) degrades to Shuffle.
void TestCategoryPreConfirmDegradesToShuffle()
{
    std::vector<RotationCatalogEntry> catalog = ThreeCategoryCatalog();
    RotationEngine engine;
    engine.SetCatalog(catalog);
    engine.ReseedShuffle(1);
    engine.SetMode(RotationMode::Category);
    // Anchor category = Waveform (single member) but nothing confirmed yet.
    engine.SetAnchor(SIZE_MAX, 3); // requested drives category, confirmed = none
    const std::vector<size_t> &order = engine.FullOrder();
    // Degrades to shuffle = full permutation of all 6 presets.
    CHECK(order.size() == 6);
    CHECK(engine.NextFrom(3, 1) != SIZE_MAX);
}

// (3) No-anchor-category degrade: Category mode with no anchor at all -> Shuffle.
void TestNoAnchorCategoryDegrades()
{
    std::vector<RotationCatalogEntry> catalog = ThreeCategoryCatalog();
    RotationEngine engine;
    engine.SetCatalog(catalog);
    engine.ReseedShuffle(1);
    engine.SetMode(RotationMode::Category);
    engine.SetAnchor(SIZE_MAX, SIZE_MAX); // no anchor
    const std::vector<size_t> &order = engine.FullOrder();
    CHECK(order.size() == 6); // shuffle degrade
}

// (4) Non-clobber: a Category detour never rewrites the scope-"" shuffle entry.
void TestCategoryDetourDoesNotClobberGlobalShuffle()
{
    std::vector<RotationCatalogEntry> catalog = ThreeCategoryCatalog();
    RotationEngine engine;
    engine.SetCatalog(catalog);
    engine.ReseedShuffle(7);

    // Establish the global shuffle order (scope "") first.
    engine.SetMode(RotationMode::Shuffle);
    (void)engine.FullOrder();

    // Drain any dirty scopes produced so far.
    std::string scope;
    ScopedRotationOrder entry;
    bool sawGlobal = false;
    while (engine.TakeDirtyScope(scope, entry))
    {
        if (scope.empty())
        {
            sawGlobal = true;
        }
    }
    CHECK(sawGlobal); // shuffle seed dirtied the "" scope

    // Now detour through Category (Fractal, 3 members) with a confirmed anchor.
    engine.SetMode(RotationMode::Category);
    engine.SetAnchor(0, 0); // Fractal
    (void)engine.FullOrder();

    // Drain: the only dirty scope must be "Fractal" — never "".
    bool sawCategory = false;
    bool clobberedGlobal = false;
    while (engine.TakeDirtyScope(scope, entry))
    {
        if (scope == "Fractal")
        {
            sawCategory = true;
        }
        else if (scope.empty())
        {
            clobberedGlobal = true;
        }
    }
    CHECK(sawCategory);
    CHECK(!clobberedGlobal);
}

// (5) Cursor-anchor retention: hidden/slow entries stay in FullOrder, excluded
//     only from Candidates / NextFrom walks.
void TestHiddenSlowRetainedInFullOrder()
{
    std::vector<RotationCatalogEntry> catalog = ThreeCategoryCatalog();
    RotationEngine engine;
    engine.SetCatalog(catalog);
    engine.ReseedShuffle(3);
    engine.SetMode(RotationMode::Shuffle);
    // Seed the raw permutation from the full pack BEFORE any hide/slow, mirroring
    // the bridge (order seeded once at startup; mid-session hides never reseed).
    (void)engine.FullOrder();

    engine.SetHidden({"f2.milk"}); // hide index 2 mid-session
    engine.SetSlowNames({"d5.milk"}); // slow index 5 mid-session

    const std::vector<size_t> &full = engine.FullOrder();
    CHECK(full.size() == 6); // raw permutation, unfiltered — retains hidden/slow
    CHECK(Contains(full, 2));
    CHECK(Contains(full, 5));

    const std::vector<size_t> &cand = engine.Candidates();
    CHECK(cand.size() == 4); // excluded filtered out
    CHECK(!Contains(cand, 2));
    CHECK(!Contains(cand, 5));

    // NextFrom skips excluded entries but keeps the anchor findable.
    CHECK(engine.IsExcludedName("f2.milk"));
    CHECK(engine.IsExcludedName("d5.milk"));
    CHECK(!engine.IsExcludedName("f0.milk"));
    // Advancing from the hidden anchor 2 must not land on 2 or 5.
    size_t next = engine.NextFrom(2, 1);
    CHECK(next != SIZE_MAX && next != 2 && next != 5);
}

// (6) Fingerprint restore vs reseed. Same members -> restored order; changed
//     membership -> reseed + dirty.
void TestFingerprintRestoreVsReseed()
{
    std::vector<RotationCatalogEntry> catalog = ThreeCategoryCatalog();

    // First engine: seed the Fractal category and capture its persisted order.
    RotationEngine seeder;
    seeder.SetCatalog(catalog);
    seeder.ReseedShuffle(11);
    seeder.SetMode(RotationMode::Category);
    seeder.SetAnchor(0, 0); // Fractal
    std::vector<size_t> seededOrder = seeder.FullOrder();
    CHECK(seededOrder.size() == 3);

    ScopedRotationOrderStore persisted;
    std::string scope;
    ScopedRotationOrder entry;
    while (seeder.TakeDirtyScope(scope, entry))
    {
        persisted = UpsertScopedRotationOrder(persisted, scope, entry);
    }
    CHECK(persisted.count("Fractal") == 1);

    // Second engine: identical catalog, load the persisted store -> RESTORE.
    RotationEngine restorer;
    restorer.SetCatalog(catalog);
    restorer.ReseedShuffle(999); // different seed; restore must win over reseed
    restorer.LoadScopedOrders(persisted);
    restorer.SetMode(RotationMode::Category);
    restorer.SetAnchor(0, 0);
    std::vector<size_t> restoredOrder = restorer.FullOrder();
    CHECK(restoredOrder == seededOrder);
    // No re-dirty on a clean restore.
    CHECK(!restorer.TakeDirtyScope(scope, entry));

    // Third engine: changed membership (rename a Fractal member) -> RESEED + dirty.
    std::vector<RotationCatalogEntry> changed = catalog;
    changed[4].filename = "fX.milk"; // was f4.milk
    RotationEngine reseeder;
    reseeder.SetCatalog(changed);
    reseeder.ReseedShuffle(11);
    reseeder.LoadScopedOrders(persisted); // stale fingerprint
    reseeder.SetMode(RotationMode::Category);
    reseeder.SetAnchor(0, 0);
    std::vector<size_t> reseeded = reseeder.FullOrder();
    CHECK(reseeded.size() == 3);
    bool dirtiedFractal = false;
    while (reseeder.TakeDirtyScope(scope, entry))
    {
        if (scope == "Fractal")
        {
            dirtiedFractal = true;
        }
    }
    CHECK(dirtiedFractal);
}

// (7) Fixed-order passthrough overrides mode.
void TestFixedOrderOverridesMode()
{
    std::vector<RotationCatalogEntry> catalog = ThreeCategoryCatalog();
    RotationEngine engine;
    engine.SetCatalog(catalog);
    engine.ReseedShuffle(5);
    engine.SetMode(RotationMode::Category);
    engine.SetAnchor(3, 3); // would HOLD in Category mode
    engine.SetHidden({"f0.milk"}); // hidden ignored by fixed order

    engine.SetFixedOrder({4, 2, 0});
    const std::vector<size_t> &full = engine.FullOrder();
    CHECK((full == std::vector<size_t>{4, 2, 0}));
    // Fixed order rotates regardless of hidden/slow: 4 -> 2 -> 0 -> 4.
    CHECK(engine.NextFrom(4, 1) == 2);
    CHECK(engine.NextFrom(2, 1) == 0);
    CHECK(engine.NextFrom(0, 1) == 4); // wraps, includes hidden 0

    // Turning it off restores mode behaviour (Category HOLD).
    engine.SetFixedOrder({});
    CHECK(engine.FullOrder().empty());
}

// (8) Favorites-empty -> Loop fallback for Candidates.
void TestFavoritesEmptyFallsBackToLoop()
{
    std::vector<RotationCatalogEntry> catalog = ThreeCategoryCatalog();
    // No favorites set.
    RotationEngine engine;
    engine.SetCatalog(catalog);
    engine.ReseedShuffle(2);
    engine.SetMode(RotationMode::Favorites);
    engine.SetFavorites({}); // empty
    const std::vector<size_t> &cand = engine.Candidates();
    CHECK(cand.size() == 6); // Loop fallback = all presets

    // With one favorite, only that shelf.
    engine.SetFavorites({"f2.milk"});
    const std::vector<size_t> &cand2 = engine.Candidates();
    CHECK((cand2 == std::vector<size_t>{2}));
}

// (9) Event-dirtying granularity: SetFavorites must not invalidate the Category
//     scoped order; no-op queries return the same ref.
void TestEventDirtyingGranularity()
{
    std::vector<RotationCatalogEntry> catalog = ThreeCategoryCatalog();
    RotationEngine engine;
    engine.SetCatalog(catalog);
    engine.ReseedShuffle(4);
    engine.SetMode(RotationMode::Category);
    engine.SetAnchor(0, 0); // Fractal

    const std::vector<size_t> &full1 = engine.FullOrder();
    CHECK(full1.size() == 3);
    // Repeated query with no dirtying event -> identical reference (cached).
    const std::vector<size_t> &full2 = engine.FullOrder();
    CHECK(&full1 == &full2);

    // Drain the seed dirtiness.
    std::string scope;
    ScopedRotationOrder entry;
    while (engine.TakeDirtyScope(scope, entry))
    {
    }

    // Changing favorites must NOT reshuffle / re-dirty the Category scope.
    engine.SetFavorites({"f0.milk"});
    const std::vector<size_t> &full3 = engine.FullOrder();
    CHECK((full3 == full1)); // same category order values
    // No new dirty scope produced by SetFavorites.
    CHECK(!engine.TakeDirtyScope(scope, entry));
}

// (10) R1 split: a session slow-mark (SetSlowNames only) changes the exclusion
//      filter but NOT the stored order's fingerprint — no reseed, no re-dirty.
void TestSessionSlowMarkDoesNotChangeFingerprint()
{
    std::vector<RotationCatalogEntry> catalog = ThreeCategoryCatalog();
    RotationEngine engine;
    engine.SetCatalog(catalog);
    engine.ReseedShuffle(21);
    engine.SetMode(RotationMode::Shuffle);
    const std::vector<size_t> beforeOrder = engine.FullOrder(); // seeds scope ""
    CHECK(beforeOrder.size() == 6);

    // Drain the seed dirtiness.
    std::string scope;
    ScopedRotationOrder entry;
    while (engine.TakeDirtyScope(scope, entry))
    {
    }

    // Session slow-mark: exclusion set grows, but the stored permutation is
    // retained (fingerprint unchanged) and the scope is NOT re-dirtied.
    engine.SetSlowNames({"f2.milk"});
    CHECK(engine.IsExcludedName("f2.milk"));
    const std::vector<size_t> &afterOrder = engine.FullOrder();
    CHECK(afterOrder == beforeOrder);            // raw permutation retained
    CHECK(!engine.TakeDirtyScope(scope, entry)); // no re-persist
    // Candidates ARE filtered by the new exclusion.
    const std::vector<size_t> &cand = engine.Candidates();
    CHECK(cand.size() == 5);
    CHECK(!Contains(cand, 2));
}

// (11) R1 split: a confirmed-promotion (SetLearnedSlowConfirmed) DOES change the
//      fingerprint — a stored order seeded without it no longer restores.
void TestConfirmedPromotionChangesFingerprint()
{
    std::vector<RotationCatalogEntry> catalog = ThreeCategoryCatalog();

    // Seed the global shuffle with NO confirmed-slow, capture the persisted order.
    RotationEngine seeder;
    seeder.SetCatalog(catalog);
    seeder.ReseedShuffle(33);
    seeder.SetMode(RotationMode::Shuffle);
    (void)seeder.FullOrder();
    ScopedRotationOrderStore persisted;
    std::string scope;
    ScopedRotationOrder entry;
    while (seeder.TakeDirtyScope(scope, entry))
    {
        persisted = UpsertScopedRotationOrder(persisted, scope, entry);
    }
    CHECK(persisted.count("") == 1);

    // Restorer with the SAME (empty) confirmed set restores byte-identically.
    RotationEngine matcher;
    matcher.SetCatalog(catalog);
    matcher.ReseedShuffle(999);
    matcher.LoadScopedOrders(persisted);
    matcher.SetMode(RotationMode::Shuffle);
    (void)matcher.FullOrder();
    CHECK(!matcher.TakeDirtyScope(scope, entry)); // clean restore, no re-dirty

    // Restorer with a DIFFERENT confirmed set: fingerprint mismatches -> reseed.
    RotationEngine promoter;
    promoter.SetCatalog(catalog);
    promoter.ReseedShuffle(999);
    promoter.LoadScopedOrders(persisted);
    promoter.SetLearnedSlowConfirmed({"f2.milk"}); // promotion changes fingerprint
    promoter.SetMode(RotationMode::Shuffle);
    (void)promoter.FullOrder();
    bool reseededGlobal = false;
    while (promoter.TakeDirtyScope(scope, entry))
    {
        if (scope.empty())
        {
            reseededGlobal = true;
        }
    }
    CHECK(reseededGlobal); // stale fingerprint forced a reseed + dirty
}

// (12) ForceReshuffle beats restore: entering Shuffle must produce a FRESH
//      sequence (issue #6) even when a fingerprint-valid persisted order exists,
//      re-dirtying "" — while plain ReseedShuffle lets the restore win (launch
//      semantics) and category scopes stay untouched (non-clobber).
void TestForceReshuffleBeatsRestore()
{
    std::vector<RotationCatalogEntry> catalog = ThreeCategoryCatalog();

    // Persist a global shuffle order seeded at 5.
    RotationEngine seeder;
    seeder.SetCatalog(catalog);
    seeder.ReseedShuffle(5);
    seeder.SetMode(RotationMode::Shuffle);
    std::vector<size_t> original = seeder.FullOrder();
    ScopedRotationOrderStore persisted;
    std::string scope;
    ScopedRotationOrder entry;
    while (seeder.TakeDirtyScope(scope, entry))
    {
        persisted = UpsertScopedRotationOrder(persisted, scope, entry);
    }
    CHECK(persisted.count("") == 1);

    // Plain ReseedShuffle: the valid persisted order RESTORES (launch semantics).
    RotationEngine restorer;
    restorer.SetCatalog(catalog);
    restorer.LoadScopedOrders(persisted);
    restorer.ReseedShuffle(6); // different seed; restore must still win
    restorer.SetMode(RotationMode::Shuffle);
    CHECK(restorer.FullOrder() == original);
    CHECK(!restorer.TakeDirtyScope(scope, entry));

    // ForceReshuffle: fresh sequence (seed 6 != seed 5 order), "" re-dirtied.
    RotationEngine forcer;
    forcer.SetCatalog(catalog);
    forcer.LoadScopedOrders(persisted);
    forcer.SetMode(RotationMode::Shuffle);
    forcer.ForceReshuffle(6);
    std::vector<size_t> fresh = forcer.FullOrder();
    CHECK(fresh.size() == original.size());
    CHECK(fresh != original); // deterministic: seeds 5 and 6 differ on 6 entries
    bool dirtiedGlobal = false;
    bool dirtiedCategory = false;
    while (forcer.TakeDirtyScope(scope, entry))
    {
        if (scope.empty())
        {
            dirtiedGlobal = true;
        }
        else
        {
            dirtiedCategory = true;
        }
    }
    CHECK(dirtiedGlobal);
    CHECK(!dirtiedCategory); // non-clobber: only "" was touched
}

// --- W2b: SetTemporarilyUnavailable (query-time-only availability filter) ------

// (13) Becoming available admits WITHOUT a reseed or dirtying any scope: the
//      seeded permutation (FullOrder) is untouched by availability flips and
//      TakeDirtyScope stays empty.
void TestBecomingAvailableAdmitsWithoutReseed()
{
    std::vector<RotationCatalogEntry> catalog = ThreeCategoryCatalog();
    RotationEngine engine;
    engine.SetCatalog(catalog);
    engine.ReseedShuffle(41);
    engine.SetMode(RotationMode::Shuffle);
    const std::vector<size_t> seeded = engine.FullOrder(); // seeds scope ""
    CHECK(seeded.size() == 6);

    // Drain the seed dirtiness.
    std::string scope;
    ScopedRotationOrder entry;
    while (engine.TakeDirtyScope(scope, entry))
    {
    }

    // Mark unavailable: filtered from Candidates, retained in FullOrder.
    engine.SetTemporarilyUnavailable({"f2.milk"});
    CHECK(engine.FullOrder() == seeded);
    CHECK(!Contains(engine.Candidates(), 2));
    CHECK(engine.Candidates().size() == 5);
    CHECK(!engine.TakeDirtyScope(scope, entry)); // no reseed, no re-persist

    // Clear: re-admitted with the SAME permutation, still nothing dirtied.
    engine.SetTemporarilyUnavailable({});
    CHECK(engine.FullOrder() == seeded);
    CHECK(Contains(engine.Candidates(), 2));
    CHECK(engine.Candidates().size() == 6);
    CHECK(!engine.TakeDirtyScope(scope, entry));

    // Setter no-op: an equal set must not invalidate the candidate cache.
    const std::vector<size_t> &cachedBefore = engine.Candidates();
    engine.SetTemporarilyUnavailable({});
    const std::vector<size_t> &cachedAfter = engine.Candidates();
    CHECK(&cachedBefore == &cachedAfter);
}

// (14) Unavailable at the FIRST seed: the name must still enter the seeded
//      permutation (seed predicate is hidden ∪ slow only), so a later clear
//      admits it into Candidates without any reseed.
void TestUnavailableAtFirstSeedLaterAdmitted()
{
    std::vector<RotationCatalogEntry> catalog = ThreeCategoryCatalog();
    RotationEngine engine;
    engine.SetCatalog(catalog);
    engine.ReseedShuffle(43);
    engine.SetMode(RotationMode::Shuffle);
    engine.SetTemporarilyUnavailable({"f2.milk"}); // BEFORE the first query/seed

    const std::vector<size_t> seeded = engine.FullOrder();
    CHECK(seeded.size() == 6);      // seeded WITH the unavailable name
    CHECK(Contains(seeded, 2));     // membership retained
    CHECK(!Contains(engine.Candidates(), 2));

    // Drain seed dirtiness, then flip available: admitted, no new dirtiness.
    std::string scope;
    ScopedRotationOrder entry;
    while (engine.TakeDirtyScope(scope, entry))
    {
    }
    engine.SetTemporarilyUnavailable({});
    CHECK(Contains(engine.Candidates(), 2));
    CHECK(engine.FullOrder() == seeded);
    CHECK(!engine.TakeDirtyScope(scope, entry));
}

// (15) Anchor stability across availability flips: an unavailable anchor stays
//      findable in the order (NextFrom advances from it), and flipping another
//      preset's availability doesn't perturb the walk.
void TestAnchorStableAcrossAvailabilityFlips()
{
    std::vector<RotationCatalogEntry> catalog = ThreeCategoryCatalog();
    RotationEngine engine;
    engine.SetCatalog(catalog);
    engine.ReseedShuffle(47);
    engine.SetMode(RotationMode::Shuffle);
    (void)engine.FullOrder();

    const size_t baseline = engine.NextFrom(0, 1);
    CHECK(baseline != SIZE_MAX);

    // Flip a DIFFERENT preset unavailable and back: the walk from the anchor
    // returns to the identical successor.
    const size_t other = baseline == 3 ? 1 : 3;
    engine.SetTemporarilyUnavailable({catalog[other].filename});
    const size_t whileUnavailable = engine.NextFrom(0, 1);
    CHECK(whileUnavailable != SIZE_MAX);
    CHECK(whileUnavailable != other);
    engine.SetTemporarilyUnavailable({});
    CHECK(engine.NextFrom(0, 1) == baseline);

    // The anchor ITSELF unavailable: still findable, advance skips onward
    // (mirrors the hidden-anchor semantics) — and never lands on itself.
    engine.SetTemporarilyUnavailable({"f0.milk"});
    const size_t fromUnavailableAnchor = engine.NextFrom(0, 1);
    CHECK(fromUnavailableAnchor != SIZE_MAX);
    CHECK(fromUnavailableAnchor != 0);
    engine.SetTemporarilyUnavailable({});
    CHECK(engine.NextFrom(0, 1) == baseline);
}

// (16) Temp-unavailable never feeds fingerprints: an order seeded WITH a
//      temp-unavailable set restores cleanly into an engine WITHOUT one (and
//      vice versa) — unlike SetLearnedSlowConfirmed. SetSlowNames/confirmed
//      semantics (tests 10/11) stay untouched alongside it.
void TestTempUnavailableDoesNotFeedFingerprint()
{
    std::vector<RotationCatalogEntry> catalog = ThreeCategoryCatalog();

    RotationEngine seeder;
    seeder.SetCatalog(catalog);
    seeder.ReseedShuffle(53);
    seeder.SetTemporarilyUnavailable({"f2.milk", "d5.milk"});
    seeder.SetMode(RotationMode::Shuffle);
    const std::vector<size_t> seeded = seeder.FullOrder();
    ScopedRotationOrderStore persisted;
    std::string scope;
    ScopedRotationOrder entry;
    while (seeder.TakeDirtyScope(scope, entry))
    {
        persisted = UpsertScopedRotationOrder(persisted, scope, entry);
    }
    CHECK(persisted.count("") == 1);

    // Restorer with NO temp-unavailable set: clean restore, no re-dirty.
    RotationEngine restorer;
    restorer.SetCatalog(catalog);
    restorer.ReseedShuffle(999);
    restorer.LoadScopedOrders(persisted);
    restorer.SetMode(RotationMode::Shuffle);
    CHECK(restorer.FullOrder() == seeded);
    CHECK(!restorer.TakeDirtyScope(scope, entry));

    // Restorer with a DIFFERENT temp-unavailable set: still a clean restore.
    RotationEngine flipped;
    flipped.SetCatalog(catalog);
    flipped.ReseedShuffle(999);
    flipped.LoadScopedOrders(persisted);
    flipped.SetTemporarilyUnavailable({"w3.milk"});
    flipped.SetMode(RotationMode::Shuffle);
    CHECK(flipped.FullOrder() == seeded);
    CHECK(!flipped.TakeDirtyScope(scope, entry));
}

// (17) Temp-unavailable filtered in ALL FOUR modes' Candidates + NextFrom.
void TestTempUnavailableFilteredInAllModes()
{
    std::vector<RotationCatalogEntry> catalog = ThreeCategoryCatalog();

    // Shuffle.
    {
        RotationEngine engine;
        engine.SetCatalog(catalog);
        engine.ReseedShuffle(61);
        engine.SetMode(RotationMode::Shuffle);
        (void)engine.FullOrder();
        engine.SetTemporarilyUnavailable({"f2.milk"});
        CHECK(!Contains(engine.Candidates(), 2));
        CHECK(engine.Candidates().size() == 5);
        for (size_t anchor = 0; anchor < catalog.size(); ++anchor)
        {
            CHECK(engine.NextFrom(anchor, 1) != 2);
        }
    }

    // Loop (shelf candidates keep slow browsable; unavailable IS filtered).
    {
        RotationEngine engine;
        engine.SetCatalog(catalog);
        engine.ReseedShuffle(61);
        engine.SetMode(RotationMode::Loop);
        engine.SetTemporarilyUnavailable({"f2.milk"});
        CHECK(!Contains(engine.Candidates(), 2));
        CHECK(engine.Candidates().size() == 5);
        for (size_t anchor = 0; anchor < catalog.size(); ++anchor)
        {
            CHECK(engine.NextFrom(anchor, 1) != 2);
        }
    }

    // Favorites (two favorites, one unavailable -> only the other remains).
    {
        RotationEngine engine;
        engine.SetCatalog(catalog);
        engine.ReseedShuffle(61);
        engine.SetMode(RotationMode::Favorites);
        engine.SetFavorites({"f2.milk", "d1.milk"});
        engine.SetTemporarilyUnavailable({"f2.milk"});
        const std::vector<size_t> &cand = engine.Candidates();
        CHECK((cand == std::vector<size_t>{1}));
        CHECK(engine.NextFrom(1, 1) != 2);
        CHECK(engine.NextFrom(2, 1) != 2); // even anchored on the unavailable one
    }

    // Category (Fractal members 0,2,4; f2 unavailable -> 2 eligible remain).
    {
        RotationEngine engine;
        engine.SetCatalog(catalog);
        engine.ReseedShuffle(61);
        engine.SetMode(RotationMode::Category);
        engine.SetAnchor(0, 0); // Fractal
        engine.SetTemporarilyUnavailable({"f2.milk"});
        const std::vector<size_t> &cand = engine.Candidates();
        CHECK(cand.size() == 2);
        CHECK(!Contains(cand, 2));
        CHECK(Contains(cand, 0));
        CHECK(Contains(cand, 4));
        CHECK(engine.NextFrom(0, 1) == 4);
        CHECK(engine.NextFrom(4, 1) == 0);
    }

    // Category HOLD: unavailability counts toward the eligible<=1 ladder (two
    // of three Fractal members unavailable + confirmed anchor -> HOLD).
    {
        RotationEngine engine;
        engine.SetCatalog(catalog);
        engine.ReseedShuffle(61);
        engine.SetMode(RotationMode::Category);
        engine.SetAnchor(0, 0); // Fractal
        engine.SetTemporarilyUnavailable({"f2.milk", "f4.milk"});
        CHECK(engine.FullOrder().empty()); // HOLD
        CHECK(engine.NextFrom(0, 1) == SIZE_MAX);
    }
}

// (18) EXCEPTION: the fixed diagnostic order bypasses eligibility entirely —
//      a temp-unavailable (and hidden) preset is still returned by NextFrom.
void TestFixedDiagnosticOrderCanLoadUnavailablePreset()
{
    std::vector<RotationCatalogEntry> catalog = ThreeCategoryCatalog();
    RotationEngine engine;
    engine.SetCatalog(catalog);
    engine.ReseedShuffle(67);
    engine.SetMode(RotationMode::Shuffle);
    engine.SetTemporarilyUnavailable({"f2.milk"});
    engine.SetHidden({"f0.milk"}); // fixed order already bypassed hidden/slow

    engine.SetFixedOrder({4, 2, 0});
    CHECK((engine.FullOrder() == std::vector<size_t>{4, 2, 0}));
    CHECK(engine.NextFrom(4, 1) == 2); // temp-unavailable still served
    CHECK(engine.NextFrom(2, 1) == 0); // hidden still served
    CHECK(engine.NextFrom(0, 1) == 4);

    // Fixed order off -> the normal query filter applies again.
    engine.SetFixedOrder({});
    CHECK(!Contains(engine.Candidates(), 2));
    CHECK(engine.NextFrom(4, 1) != 2);
}

} // namespace

void RunRotationEngineTests()
{
    TestCategoryHoldOnSingleEligibleWithConfirm();
    TestCategoryPreConfirmDegradesToShuffle();
    TestNoAnchorCategoryDegrades();
    TestCategoryDetourDoesNotClobberGlobalShuffle();
    TestHiddenSlowRetainedInFullOrder();
    TestFingerprintRestoreVsReseed();
    TestFixedOrderOverridesMode();
    TestFavoritesEmptyFallsBackToLoop();
    TestEventDirtyingGranularity();
    TestSessionSlowMarkDoesNotChangeFingerprint();
    TestConfirmedPromotionChangesFingerprint();
    TestForceReshuffleBeatsRestore();
    TestBecomingAvailableAdmitsWithoutReseed();
    TestUnavailableAtFirstSeedLaterAdmitted();
    TestAnchorStableAcrossAvailabilityFlips();
    TestTempUnavailableDoesNotFeedFingerprint();
    TestTempUnavailableFilteredInAllModes();
    TestFixedDiagnosticOrderCanLoadUnavailablePreset();
}
