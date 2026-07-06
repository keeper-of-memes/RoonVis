#pragma once

#include <cstddef>
#include <functional>
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
// The shuffle permutation is persisted across launches (as filenames, which are
// stable across pack reordering) so short viewing sessions continue the walk
// instead of resampling the head of a fresh permutation every launch.
//
// Invalidation policy: the stored order is reseeded only when the FINGERPRINT
// changes - the pack's filename set or the learned-slow CONFIRMED set. Hidden/
// favourite changes and runtime slow promotions do NOT invalidate: those filter
// at advance time (the exclusion predicate) while the stored order and cursor
// semantics are preserved.

// Order-insensitive fingerprint over the pack filenames and the learned-slow
// confirmed set. Printable ASCII.
std::string ShuffleOrderFingerprint(const std::vector<std::string> &packFilenames,
                                    const std::vector<std::string> &learnedSlowConfirmed);

// Maps a stored filename order back to current preset indexes via `indexForFilename`
// (returning SIZE_MAX for unknown). Entries no longer in the pack are dropped;
// order is preserved (filter-on-invalid, never reseed here).
std::vector<size_t> RestoreShuffleOrder(const std::vector<std::string> &storedOrder,
                                        const std::function<size_t(const std::string &)> &indexForFilename);

} // namespace RoonVis
