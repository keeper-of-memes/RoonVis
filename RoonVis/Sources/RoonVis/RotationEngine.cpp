#include "RotationEngine.h"

#include "PresetShelfModel.h"
#include "SnapPCM.h" // RoonVis::ShuffledOrder (tested deterministic shuffle)

#include <utility>

namespace RoonVis
{

namespace
{

// Empty display names are excluded, matching isPresetHiddenOrSlow: (a zero-length
// name returns YES). Also guards out-of-range indexes at the call sites.
bool NameIsEmpty(const std::string &name)
{
    return name.empty();
}

} // namespace

// --- events ------------------------------------------------------------------

void RotationEngine::SetCatalog(std::vector<RotationCatalogEntry> entries)
{
    _catalog = std::move(entries);
    _indexByName.clear();
    _indexByName.reserve(_catalog.size());
    for (size_t i = 0; i < _catalog.size(); ++i)
    {
        // First-write-wins on duplicate display names, matching the bridge's
        // indexByName.emplace (which also keeps the first insertion).
        _indexByName.emplace(_catalog[i].filename, i);
    }
    // Catalog change invalidates everything (membership, fingerprints, shelves).
    _shuffleValid = false;
    _categoryValid = false;
    _categoryScope.clear();
    for (int a = 0; a < 2; ++a)
    {
        for (int b = 0; b < 2; ++b)
        {
            _shelfValid[a][b] = false;
        }
    }
    InvalidateModeCaches();
}

void RotationEngine::SetMode(RotationMode mode)
{
    if (_mode == mode)
    {
        return;
    }
    _mode = mode;
    InvalidateModeCaches();
}

void RotationEngine::SetFavorites(std::unordered_set<std::string> names)
{
    _favorites = std::move(names);
    // Favorites only affect the favorites shelf; category / shuffle orders and
    // their fingerprints are unaffected (learned-slow, not favorites, feeds the
    // fingerprint — see ShuffleOrderFingerprint). Invalidate the shelf caches
    // and the mode-view caches, but NOT the shuffle/category stored orders.
    for (int b = 0; b < 2; ++b)
    {
        _shelfValid[1][b] = false; // favoritesOnly == true
    }
    InvalidateModeCaches();
}

void RotationEngine::SetHidden(std::unordered_set<std::string> names)
{
    _hidden = std::move(names);
    // Hidden filters at advance time; the stored shuffle/category orders keep
    // their entries. But it DOES change which entries survive the shelf builders
    // (includeHidden:NO) and the candidate filter, so invalidate those views.
    for (int a = 0; a < 2; ++a)
    {
        for (int b = 0; b < 2; ++b)
        {
            _shelfValid[a][b] = false;
        }
    }
    InvalidateModeCaches();
}

void RotationEngine::SetSlowNames(std::unordered_set<std::string> names)
{
    _slow = std::move(names);
    // The exclusion set (session-slow ∪ learned-slow-confirmed) filters at advance
    // time and does NOT invalidate the stored orders: the fingerprint uses the
    // CONFIRMED learned-slow set (SetLearnedSlowConfirmed), never this set, so a
    // transient session mark cannot churn persisted permutations. Only the
    // candidate / next views change.
    InvalidateModeCaches();
}

void RotationEngine::SetLearnedSlowConfirmed(std::unordered_set<std::string> names)
{
    if (_confirmedSlow == names)
    {
        return;
    }
    _confirmedSlow = std::move(names);
    // The confirmed set feeds every scoped-order fingerprint. A promotion changes
    // the fingerprint, so a restore may no longer match -> reseed + dirty. Mirror
    // the catalog-change invalidation for the stored orders (but not the shelves,
    // which never depend on learned-slow).
    _shuffleValid = false;
    _categoryValid = false;
    InvalidateModeCaches();
}

void RotationEngine::SetTemporarilyUnavailable(std::unordered_set<std::string> names)
{
    if (_temporarilyUnavailable == names)
    {
        return;
    }
    _temporarilyUnavailable = std::move(names);
    // QUERY-time filter only: invalidate the mode/candidate views and nothing
    // else. Fingerprints never see this set, persisted scoped orders keep their
    // entries, and the seeded shuffle permutation stays valid — so clearing the
    // flag later re-admits a preset without any reseed or re-persist.
    InvalidateModeCaches();
}

void RotationEngine::SetAnchor(size_t confirmedIndex, size_t requestedIndex)
{
    if (_confirmedIndex == confirmedIndex && _requestedIndex == requestedIndex)
    {
        return;
    }
    _confirmedIndex = confirmedIndex;
    _requestedIndex = requestedIndex;
    // The anchor drives the Category scope; a scope switch invalidates the
    // category memo and the mode views. Shuffle / shelves are anchor-independent.
    _categoryValid = false;
    InvalidateModeCaches();
}

void RotationEngine::SetFixedOrder(std::vector<size_t> order)
{
    _fixedOrder = std::move(order);
    InvalidateModeCaches();
}

void RotationEngine::ReseedShuffle(uint32_t seed)
{
    _seed = seed;
    _shuffleValid = false;
    _categoryValid = false;
    InvalidateModeCaches();
}

void RotationEngine::ForceReshuffle(uint32_t seed)
{
    _seed = seed;
    // Discard the persisted global order so EnsureShuffleOrder cannot restore it:
    // entering Shuffle must produce a FRESH sequence (issue #6, mirroring the
    // legacy regenerateShuffleOrder). Only the "" scope is dropped — category
    // scopes are preserved (non-clobber contract).
    _store.erase(std::string());
    _shuffleValid = false;
    InvalidateModeCaches();
}

void RotationEngine::LoadScopedOrders(ScopedRotationOrderStore store)
{
    _store = std::move(store);
    _shuffleValid = false;
    _categoryValid = false;
    InvalidateModeCaches();
}

// --- exclusion ---------------------------------------------------------------

bool RotationEngine::IsExcludedName(const std::string &filename) const
{
    if (NameIsEmpty(filename))
    {
        return true;
    }
    return _hidden.count(filename) > 0 || _slow.count(filename) > 0;
}

bool RotationEngine::IsExcludedIndex(size_t index) const
{
    if (index >= _catalog.size())
    {
        return true;
    }
    return IsExcludedName(_catalog[index].filename);
}

bool RotationEngine::IsRotationIneligibleIndex(size_t index) const
{
    if (IsExcludedIndex(index))
    {
        return true;
    }
    // IsExcludedIndex returning false guarantees index < _catalog.size().
    return _temporarilyUnavailable.count(_catalog[index].filename) > 0;
}

// --- fingerprint helpers -----------------------------------------------------

std::vector<std::string> RotationEngine::PackFilenames() const
{
    std::vector<std::string> names;
    names.reserve(_catalog.size());
    for (const RotationCatalogEntry &entry : _catalog)
    {
        names.push_back(entry.filename);
    }
    return names;
}

std::vector<std::string> RotationEngine::LearnedSlowConfirmed() const
{
    // The bridge fingerprints over the learned-slow CONFIRMED set only
    // (_learnedSlowStore.ConfirmedNames()), NOT the full exclusion set. Session
    // slow marks (in _slow but not _confirmedSlow) must not change fingerprints.
    return std::vector<std::string>(_confirmedSlow.begin(), _confirmedSlow.end());
}

std::string RotationEngine::FingerprintForScope(const std::string &scope,
                                                const std::vector<std::string> &memberFilenames) const
{
    return ShuffleOrderFingerprint(memberFilenames, LearnedSlowConfirmed(), scope);
}

// --- global shuffle ----------------------------------------------------------

void RotationEngine::EnsureShuffleOrder()
{
    if (_shuffleValid)
    {
        return;
    }

    // Try restore from the loaded store (scope "") when the fingerprint (full
    // pack display names + learned-slow) still matches.
    const std::string fingerprint = FingerprintForScope(std::string(), PackFilenames());
    auto found = _store.find(std::string());
    if (found != _store.end() && found->second.fingerprint == fingerprint)
    {
        std::vector<size_t> restored = RestoreShuffleOrder(
            found->second.filenames, [this](const std::string &name) -> size_t {
                auto it = _indexByName.find(name);
                return it != _indexByName.end() ? it->second : SIZE_MAX;
            });
        if (!restored.empty())
        {
            _shuffleOrder = std::move(restored);
            _shuffleValid = true;
            return;
        }
    }

    // Reseed: shuffle the VISIBLE (non-excluded) indexes, matching
    // regenerateShuffleOrder, then persist (mark "" dirty).
    std::vector<size_t> visible;
    visible.reserve(_catalog.size());
    for (size_t i = 0; i < _catalog.size(); ++i)
    {
        if (!IsExcludedIndex(i))
        {
            visible.push_back(i);
        }
    }
    _shuffleOrder = ShuffledOrder(visible, _seed);
    _shuffleValid = true;

    ScopedRotationOrder entry;
    entry.fingerprint = fingerprint;
    entry.filenames.reserve(_shuffleOrder.size());
    for (size_t index : _shuffleOrder)
    {
        if (index < _catalog.size())
        {
            entry.filenames.push_back(_catalog[index].filename);
        }
    }
    _store = UpsertScopedRotationOrder(_store, std::string(), entry);
    _dirtyScopes.push_back(std::string());
}

const std::vector<size_t> &RotationEngine::ShuffleFullOrder()
{
    EnsureShuffleOrder();
    return _shuffleOrder;
}

// --- category ----------------------------------------------------------------

std::string RotationEngine::AnchorCategoryName() const
{
    // The CONFIRMED preset's category normally; the requested one while a load
    // is in flight (rotationAnchorCategoryName: uses confirmed, falling back to
    // the requested/current anchor).
    size_t index = _confirmedIndex != SIZE_MAX ? _confirmedIndex : _requestedIndex;
    if (index == SIZE_MAX || index >= _catalog.size())
    {
        return {};
    }
    return _catalog[index].category;
}

const std::vector<size_t> &RotationEngine::CategoryOrderForScope(const std::string &category)
{
    if (_categoryValid && _categoryScope == category && !_categoryOrder.empty())
    {
        return _categoryOrder;
    }

    std::vector<std::string> categories;
    categories.reserve(_catalog.size());
    for (const RotationCatalogEntry &entry : _catalog)
    {
        categories.push_back(entry.category);
    }
    std::vector<size_t> members = CategoryMemberIndexes(categories, category);
    if (members.size() <= 1)
    {
        // Too small to rotate; never persist a degenerate scope.
        _categoryScope = category;
        _categoryOrder = members;
        _categoryValid = true;
        return _categoryOrder;
    }

    std::vector<std::string> memberFilenames;
    memberFilenames.reserve(members.size());
    for (size_t index : members)
    {
        memberFilenames.push_back(_catalog[index].filename);
    }
    const std::string fingerprint = FingerprintForScope(category, memberFilenames);

    std::vector<size_t> order;
    auto found = _store.find(category);
    if (found != _store.end() && found->second.fingerprint == fingerprint)
    {
        order = RestoreShuffleOrder(found->second.filenames, [this](const std::string &name) -> size_t {
            auto it = _indexByName.find(name);
            return it != _indexByName.end() ? it->second : SIZE_MAX;
        });
    }

    if (order.empty())
    {
        order = ShuffledOrder(members, _seed);
        ScopedRotationOrder entry;
        entry.fingerprint = fingerprint;
        entry.filenames.reserve(order.size());
        for (size_t index : order)
        {
            entry.filenames.push_back(_catalog[index].filename);
        }
        _store = UpsertScopedRotationOrder(_store, category, entry);
        _dirtyScopes.push_back(category);
    }

    _categoryScope = category;
    _categoryOrder = std::move(order);
    _categoryValid = true;
    return _categoryOrder;
}

// --- shelves -----------------------------------------------------------------

const std::vector<size_t> &RotationEngine::ShelfOrder(bool favoritesOnly, bool includeHidden)
{
    const int a = includeHidden ? 1 : 0;
    const int f = favoritesOnly ? 1 : 0;
    if (_shelfValid[f][a])
    {
        return _shelfCache[f][a];
    }

    std::vector<PresetShelfInput> inputs;
    inputs.reserve(_catalog.size());
    for (size_t i = 0; i < _catalog.size(); ++i)
    {
        const RotationCatalogEntry &entry = _catalog[i];
        if (entry.filename.empty())
        {
            continue;
        }
        if (!includeHidden && _hidden.count(entry.filename) > 0)
        {
            continue;
        }
        if (favoritesOnly && !entry.favorite && _favorites.count(entry.filename) == 0)
        {
            continue;
        }
        PresetShelfInput input;
        input.index = i;
        input.filename = entry.filename;
        input.title = entry.title;
        // favorite reflects the catalog flag OR a runtime favorite override.
        input.favorite = entry.favorite || _favorites.count(entry.filename) > 0;
        input.category = entry.category;
        input.subcategory = entry.subcategory;
        inputs.push_back(input);
    }

    std::vector<PresetShelf> shelves = BuildPresetShelves(inputs, favoritesOnly, 3);
    std::vector<size_t> indexes = FlattenPresetShelfIndexes(shelves);
    if (favoritesOnly && indexes.empty())
    {
        // Empty-favorites -> Loop fallback (same includeHidden semantics).
        std::vector<PresetShelfInput> loopInputs;
        loopInputs.reserve(_catalog.size());
        for (size_t i = 0; i < _catalog.size(); ++i)
        {
            const RotationCatalogEntry &entry = _catalog[i];
            if (entry.filename.empty())
            {
                continue;
            }
            if (!includeHidden && _hidden.count(entry.filename) > 0)
            {
                continue;
            }
            PresetShelfInput input;
            input.index = i;
            input.filename = entry.filename;
            input.title = entry.title;
            input.favorite = entry.favorite || _favorites.count(entry.filename) > 0;
            input.category = entry.category;
            input.subcategory = entry.subcategory;
            loopInputs.push_back(input);
        }
        shelves = BuildPresetShelves(loopInputs, false, 3);
        indexes = FlattenPresetShelfIndexes(shelves);
    }

    _shelfCache[f][a] = std::move(indexes);
    _shelfValid[f][a] = true;
    return _shelfCache[f][a];
}

// --- queries -----------------------------------------------------------------

const std::vector<size_t> &RotationEngine::FullOrder()
{
    if (_fullOrderValid)
    {
        return _fullOrderCache;
    }

    // Debug determinism hook: a fixed list overrides mode entirely.
    if (!_fixedOrder.empty())
    {
        _fullOrderCache = _fixedOrder;
        _fullOrderValid = true;
        return _fullOrderCache;
    }

    if (_catalog.empty())
    {
        _fullOrderCache.clear();
        _fullOrderValid = true;
        return _fullOrderCache;
    }

    if (_mode == RotationMode::Shuffle)
    {
        _fullOrderCache = ShuffleFullOrder();
        _fullOrderValid = true;
        return _fullOrderCache;
    }

    if (_mode == RotationMode::Category)
    {
        const std::string category = AnchorCategoryName();
        if (category.empty())
        {
            // No anchor / uncategorised -> degrade to Shuffle.
            _fullOrderCache = ShuffleFullOrder();
            _fullOrderValid = true;
            return _fullOrderCache;
        }
        const std::vector<size_t> &order = CategoryOrderForScope(category);
        size_t eligible = 0;
        for (size_t index : order)
        {
            // QUERY predicate: temp-unavailable members can't be rotated to, so
            // they count toward the HOLD/degrade ladder like hidden/slow.
            if (!IsRotationIneligibleIndex(index))
            {
                ++eligible;
            }
        }
        if (eligible <= 1)
        {
            if (_confirmedIndex == SIZE_MAX)
            {
                // Nothing confirmed yet -> degrade to Shuffle (don't black-screen).
                _fullOrderCache = ShuffleFullOrder();
                _fullOrderValid = true;
                return _fullOrderCache;
            }
            // HOLD: empty order -> advance yields no successor.
            _fullOrderCache.clear();
            _fullOrderValid = true;
            return _fullOrderCache;
        }
        _fullOrderCache = order;
        _fullOrderValid = true;
        return _fullOrderCache;
    }

    // Loop / Favorites: shelf order INCLUDING hidden (includeHidden:YES); hidden
    // entries are excluded at advance time by the predicate, not removed.
    _fullOrderCache = ShelfOrder(_mode == RotationMode::Favorites, /*includeHidden=*/true);
    _fullOrderValid = true;
    return _fullOrderCache;
}

const std::vector<size_t> &RotationEngine::Candidates()
{
    if (_candidatesValid)
    {
        return _candidatesCache;
    }

    if (_catalog.empty())
    {
        _candidatesCache.clear();
        _candidatesValid = true;
        return _candidatesCache;
    }

    if (_mode == RotationMode::Shuffle)
    {
        // Reseeded shuffle order, re-filtered for hidden/slow/availability changes.
        const std::vector<size_t> &order = ShuffleFullOrder();
        std::vector<size_t> indexes;
        indexes.reserve(order.size());
        for (size_t index : order)
        {
            if (!IsRotationIneligibleIndex(index))
            {
                indexes.push_back(index);
            }
        }
        _candidatesCache = std::move(indexes);
        _candidatesValid = true;
        return _candidatesCache;
    }

    if (_mode == RotationMode::Category)
    {
        // Full category order minus the exclusion predicate. Reuses FullOrder's
        // degrade/hold ladder (which may itself return a Shuffle order).
        const std::vector<size_t> &order = FullOrder();
        std::vector<size_t> indexes;
        indexes.reserve(order.size());
        for (size_t index : order)
        {
            if (!IsRotationIneligibleIndex(index))
            {
                indexes.push_back(index);
            }
        }
        _candidatesCache = std::move(indexes);
        _candidatesValid = true;
        return _candidatesCache;
    }

    // Loop / Favorites: shelf-flattened VISIBLE order (includeHidden:NO), with
    // the empty-favorites -> Loop fallback baked into ShelfOrder. The shelf
    // keeps its legacy filter (hidden only — slow stays browsable); the W2b
    // availability filter is applied on top, NOT baked into the shelf caches.
    const std::vector<size_t> &shelf =
        ShelfOrder(_mode == RotationMode::Favorites, /*includeHidden=*/false);
    if (_temporarilyUnavailable.empty())
    {
        _candidatesCache = shelf;
    }
    else
    {
        std::vector<size_t> indexes;
        indexes.reserve(shelf.size());
        for (size_t index : shelf)
        {
            if (index < _catalog.size() &&
                _temporarilyUnavailable.count(_catalog[index].filename) > 0)
            {
                continue;
            }
            indexes.push_back(index);
        }
        _candidatesCache = std::move(indexes);
    }
    _candidatesValid = true;
    return _candidatesCache;
}

size_t RotationEngine::NextFrom(size_t anchor, long offset)
{
    if (_catalog.empty())
    {
        return SIZE_MAX;
    }

    std::function<bool(size_t)> excluded;
    std::vector<size_t> order;

    if (!_fixedOrder.empty())
    {
        // Fixed diagnostic list rotates regardless of hidden/slow AND
        // temp-unavailable (only bounds-check) — the diagnostic path must be
        // able to load any listed preset.
        order = _fixedOrder;
        excluded = [this](size_t index) { return index >= _catalog.size(); };
    }
    else
    {
        order = FullOrder();
        excluded = [this](size_t index) { return IsRotationIneligibleIndex(index); };
    }

    if (order.empty())
    {
        return SIZE_MAX;
    }

    RotationAdvanceResult advance = AdvanceRotationCursor(order, anchor, offset, excluded);
    return advance.valid ? advance.index : SIZE_MAX;
}

// --- persistence out ---------------------------------------------------------

bool RotationEngine::TakeDirtyScope(std::string &scope, ScopedRotationOrder &entry)
{
    if (_dirtyScopes.empty())
    {
        return false;
    }
    scope = _dirtyScopes.front();
    _dirtyScopes.erase(_dirtyScopes.begin());
    auto found = _store.find(scope);
    if (found == _store.end())
    {
        // Scope was superseded/removed before drain; skip to the next.
        return TakeDirtyScope(scope, entry);
    }
    entry = found->second;
    return true;
}

// --- cache invalidation ------------------------------------------------------

void RotationEngine::InvalidateModeCaches()
{
    _fullOrderValid = false;
    _candidatesValid = false;
}

} // namespace RoonVis
