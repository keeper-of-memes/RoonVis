#pragma once

#include <cstddef>
#include <functional>
#include <map>
#include <string>
#include <vector>

namespace RoonVis
{

// Result of a rotation-cursor advance. `valid == false` means no eligible
// successor exists (empty order, or every entry excluded).
struct RotationAdvanceResult
{
    bool valid = false;
    size_t index = 0;
};

// Advances a rotation cursor over the FULL mode order (loop shelf order,
// shuffle permutation, or favourites list), skipping excluded entries.
//
// Contract (the fix for the historical front-reset bug):
// - `order` is the full order for the mode. It must retain excluded entries;
//   exclusion is expressed only through the `excluded` predicate, never by
//   removing entries. That keeps the anchor findable even when the anchor
//   itself has just been hidden or marked slow, so an advance from an excluded
//   anchor continues from the anchor's ORDER POSITION instead of resetting to
//   the front of a shrunken list.
// - `anchorIndex` is the preset index the cursor is anchored to (the confirmed
//   preset; or the requested one while a load is in flight).
// - `offset` counts ELIGIBLE steps (+1 = next non-excluded after the anchor,
//   -1 = previous). |offset| > 1 walks further; 0 returns the anchor itself
//   when eligible, else the next eligible forward.
// - If the anchor is not present in `order` at all (pack changed), the walk
//   degrades to the historical behaviour: first eligible entry for forward
//   advances, last eligible for backward. This is the only remaining reset
//   path and requires the preset to have left the pack entirely.
RotationAdvanceResult AdvanceRotationCursor(const std::vector<size_t> &order,
                                            size_t anchorIndex,
                                            long offset,
                                            const std::function<bool(size_t)> &excluded);

// --- Shuffle-order persistence -------------------------------------------------
//
// Shuffled orders are persisted across launches (as filenames, which are
// stable across pack reordering) so short viewing sessions continue the walk
// instead of resampling the head of a fresh permutation every launch. Orders
// are SCOPED: scope "" is the single global Shuffle order; scope
// "<CategoryName>" is that category's order (Category rotation mode). Each
// scope is independent - reading or reseeding one scope never touches another.
//
// Invalidation policy: a stored order is reseeded only when its FINGERPRINT
// changes - the scope's member filename set or the learned-slow CONFIRMED set.
// Hidden/favourite changes and runtime slow promotions do NOT invalidate:
// those filter at advance time (the exclusion predicate) while the stored
// order and cursor semantics are preserved.

// Order-insensitive fingerprint over the scope's member filenames and the
// learned-slow confirmed set. Printable ASCII. `scope` is part of the
// fingerprint identity so equal member sets in different scopes never validate
// each other's stored orders; scope "" (the global Shuffle order) hashes
// exactly as the historical two-argument form did, so orders migrated from the
// legacy single-shuffle keys keep validating.
std::string ShuffleOrderFingerprint(const std::vector<std::string> &packFilenames,
                                    const std::vector<std::string> &learnedSlowConfirmed,
                                    const std::string &scope);

// One persisted rotation order: the shuffled filename sequence plus the
// fingerprint it was seeded against.
struct ScopedRotationOrder
{
    std::vector<std::string> filenames;
    std::string fingerprint;
};

// The scoped store persisted in Caches/ScopedRotationOrders.plist (NOT
// NSUserDefaults - tvOS kills apps whose preferences exceed ~1MB, and one
// CotC-scale order is ~550KB): {scope -> order}. Scope "" = global Shuffle;
// scope "<CategoryName>" = that category (Category rotation mode).
using ScopedRotationOrderStore = std::map<std::string, ScopedRotationOrder>;

// Returns a copy of `store` with `entry` written at `scope`. NON-CLOBBER
// CONTRACT: every other scope's entry is preserved verbatim - in particular,
// entering/leaving Category mode (writes to category scopes) never touches the
// global Shuffle entry at scope "".
ScopedRotationOrderStore UpsertScopedRotationOrder(const ScopedRotationOrderStore &store,
                                                   const std::string &scope,
                                                   const ScopedRotationOrder &entry);

// All preset indexes whose categories[index] == category, in pack order.
// No hidden/slow filtering here: the FULL rotation order retains excluded
// entries (rotation-cursor invariant above); exclusion is the advance
// predicate's job. An empty `category` never matches (uncategorised packs
// have no category membership).
std::vector<size_t> CategoryMemberIndexes(const std::vector<std::string> &categories,
                                          const std::string &category);

// Maps a stored filename order back to current preset indexes via `indexForFilename`
// (returning SIZE_MAX for unknown). Entries no longer in the pack are dropped;
// order is preserved (filter-on-invalid, never reseed here).
std::vector<size_t> RestoreShuffleOrder(const std::vector<std::string> &storedOrder,
                                        const std::function<size_t(const std::string &)> &indexForFilename);

} // namespace RoonVis
