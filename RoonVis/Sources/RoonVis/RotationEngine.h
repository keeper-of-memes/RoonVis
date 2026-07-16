#pragma once

#include "PresetRotationCursor.h"

#include <cstddef>
#include <cstdint>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace RoonVis
{

// Preset rotation modes, mirroring RoonVisPresetRotationMode in the bridge.
enum class RotationMode
{
    Loop,
    Shuffle,
    Favorites,
    Category,
};

// One catalog entry. `filename` is the DISPLAY NAME (lastPathComponent) the
// engine keys exclusion and fingerprints on — the same string the bridge feeds
// ShuffleOrderFingerprint / the exclusion predicate (presetDisplayNameForPath:).
struct RotationCatalogEntry
{
    std::string filename;
    std::string title;
    std::string category;
    std::string subcategory;
    bool favorite = false;
};

// Pure C++17 rotation core. OWNS rotation-order storage and selection; composes
// PresetRotationCursor (AdvanceRotationCursor, ShuffleOrderFingerprint,
// CategoryMemberIndexes, RestoreShuffleOrder, UpsertScopedRotationOrder) and
// PresetShelfModel (BuildPresetShelves, FlattenPresetShelfIndexes). No ObjC /
// Foundation / Apple headers, no time()/random_device — randomness enters only
// through ReseedShuffle(seed).
//
// Ported from ProjectMBridge.mm rotationCandidateIndexesForMode:,
// fullRotationOrderForMode:, categoryRotationOrderForCategory:,
// nextRotationIndexFrom:offset:, regenerateShuffleOrder + shuffle persist/restore.
//
// This step lands app-unused; the bridge adopts it in a later step.
class RotationEngine
{
public:
    RotationEngine() = default;

    // --- events — each dirties exactly the orders it affects -----------------
    void SetCatalog(std::vector<RotationCatalogEntry> entries);
    void SetMode(RotationMode mode);
    void SetFavorites(std::unordered_set<std::string> names);
    void SetHidden(std::unordered_set<std::string> names);
    // The exclusion set (session-slow ∪ learned-slow-confirmed), mirroring the
    // bridge's _slowPresetNames. Filters at advance time only; NEVER changes a
    // stored order's fingerprint (a transient session mark must not churn the
    // persisted permutations). Pair with SetLearnedSlowConfirmed for the piece
    // that DOES feed the fingerprint.
    void SetSlowNames(std::unordered_set<std::string> names);
    // The CONFIRMED learned-slow set, the ONLY slow input that feeds scoped-order
    // fingerprints (mirroring the bridge's _learnedSlowStore.ConfirmedNames()).
    // A confirmed-promotion changes fingerprints (may reseed + dirty orders); a
    // transient session mark (SetSlowNames only) must not. Seed this at startup
    // and on every confirmed-promotion, alongside SetSlowNames.
    void SetLearnedSlowConfirmed(std::unordered_set<std::string> names);
    // W2b capability-manifest availability: presets whose activation
    // prerequisites are not met YET this session (e.g. tier-1 cache entry
    // missing). A QUERY-time filter only — seeded permutations still include
    // these names (seed predicate stays hidden ∪ slow), so clearing the flag
    // later admits them WITHOUT a reseed. Never touches fingerprints,
    // persisted scoped orders, or the seeded shuffle validity; the fixed
    // diagnostic order (SetFixedOrder) bypasses this filter like hidden/slow.
    void SetTemporarilyUnavailable(std::unordered_set<std::string> names);
    // Drives the Category scope. confirmedIndex is the on-screen preset;
    // requestedIndex is the in-flight target. SIZE_MAX = none.
    void SetAnchor(size_t confirmedIndex, size_t requestedIndex);
    // Debug determinism hook. Non-empty order overrides mode and the hidden/slow
    // filter (listed presets rotate regardless). Empty = off.
    void SetFixedOrder(std::vector<size_t> order);
    // Deterministic reseed source. Seeds derive from this base per scope. A
    // valid persisted order still RESTORES (restore wins over reseed) — the
    // launch behavior (legacy restoreOrRegenerateShuffleOrder).
    void ReseedShuffle(uint32_t seed);
    // Force a FRESH global shuffle order (discards the stored scope-"" entry so
    // restore cannot win) — the entering-Shuffle behavior (issue #6, legacy
    // regenerateShuffleOrder). The "" scope is reseeded + marked dirty on the
    // next shuffle query; category scopes are untouched (non-clobber).
    void ForceReshuffle(uint32_t seed);
    // Startup restore of persisted scoped orders (scope "" = global shuffle).
    void LoadScopedOrders(ScopedRotationOrderStore store);

    // --- queries — cached until a dirtying event; const refs, no copies -------
    // Current mode, anchor-scoped. Empty == HOLD (nothing to rotate to).
    const std::vector<size_t> &FullOrder();
    // Current mode, exclusion-filtered (browse / warm order).
    const std::vector<size_t> &Candidates();
    // Cursor walk from `anchor` by `offset` eligible steps. SIZE_MAX == none.
    size_t NextFrom(size_t anchor, long offset);
    // Hidden ∪ slow, O(1). Empty name is excluded (matches isPresetHiddenOrSlow).
    bool IsExcludedName(const std::string &filename) const;

    // --- persistence out — the adopter drains after event batches ------------
    // Pops one dirty scope (scope, order) pair. Returns false when none remain.
    bool TakeDirtyScope(std::string &scope, ScopedRotationOrder &entry);

private:
    void InvalidateModeCaches();
    // SEED predicate (permutation membership): hidden ∪ slow. Temp-unavailable
    // names stay IN seeded orders so a later clear can admit them.
    bool IsExcludedIndex(size_t index) const;
    // QUERY predicate (selection eligibility): excluded ∪ temporarilyUnavailable.
    // Applied at the normal selection paths (Candidates, Category eligible/HOLD,
    // NextFrom) — never at seed time, never on the fixed diagnostic order.
    bool IsRotationIneligibleIndex(size_t index) const;

    // The full pack display names, in pack order (global shuffle fingerprint).
    std::vector<std::string> PackFilenames() const;
    std::vector<std::string> LearnedSlowConfirmed() const; // slow names, sorted-free set
    std::string FingerprintForScope(const std::string &scope,
                                    const std::vector<std::string> &memberFilenames) const;

    // Ensures the global shuffle permutation (scope "") exists: restores from a
    // loaded store when the fingerprint matches, else reseeds + marks "" dirty.
    void EnsureShuffleOrder();
    const std::vector<size_t> &ShuffleFullOrder();
    // The category order for `category` (scope "<category>"): restore-or-reseed,
    // memoized per scope. Marks the scope dirty on reseed only.
    const std::vector<size_t> &CategoryOrderForScope(const std::string &category);
    std::string AnchorCategoryName() const;
    const std::vector<size_t> &ShelfOrder(bool favoritesOnly, bool includeHidden);

    std::vector<RotationCatalogEntry> _catalog;
    std::unordered_map<std::string, size_t> _indexByName;

    RotationMode _mode = RotationMode::Loop;
    std::unordered_set<std::string> _favorites;
    std::unordered_set<std::string> _hidden;
    std::unordered_set<std::string> _slow;            // exclusion set (advance-time filter)
    std::unordered_set<std::string> _confirmedSlow;   // fingerprint input only
    // Query-time-only availability filter (W2b); never feeds seeds/fingerprints.
    std::unordered_set<std::string> _temporarilyUnavailable;
    size_t _confirmedIndex = SIZE_MAX;
    size_t _requestedIndex = SIZE_MAX;
    std::vector<size_t> _fixedOrder;
    uint32_t _seed = 0;

    // Persisted orders, keyed by scope ("" = global shuffle).
    ScopedRotationOrderStore _store;
    std::vector<std::string> _dirtyScopes; // FIFO of scopes needing persistence

    // Global shuffle permutation (raw, unfiltered).
    std::vector<size_t> _shuffleOrder;
    bool _shuffleValid = false;

    // Category memoization (single active scope, mirroring the bridge).
    std::string _categoryScope;
    std::vector<size_t> _categoryOrder;
    bool _categoryValid = false;

    // Query result caches.
    std::vector<size_t> _fullOrderCache;
    bool _fullOrderValid = false;
    std::vector<size_t> _candidatesCache;
    bool _candidatesValid = false;
    // Shelf-order caches keyed by (favoritesOnly, includeHidden).
    std::vector<size_t> _shelfCache[2][2];
    bool _shelfValid[2][2] = {{false, false}, {false, false}};
};

} // namespace RoonVis
