#pragma once

#include <map>
#include <set>
#include <string>

namespace RoonVis
{

// One-shot legacy preset-name migration (flat 292 pack -> CotC tree pack).
//
// Pure logic only (no I/O): the ObjC layer (LegacyNameMigrationSupport.mm) loads the
// bundled LegacyNameMap.json and applies these over the persisted per-preset stores
// (favourites, hidden, learned-slow confirmed, slow-pending counts), all keyed on
// basenames.

// Parses a flat JSON object of old-basename -> new-basename string pairs (the shape
// emitted by RoonVis/scripts/build_cotc_pack.py). Tolerant of whitespace; standard
// string escapes supported. All-or-nothing: any malformed input (including non-object
// payloads and garbage) yields an EMPTY map, as does an empty object. Entries with
// empty keys are skipped; entries with empty VALUES are kept (they act as explicit
// drop directives during migration).
std::map<std::string, std::string> ParseLegacyNameMapJSON(const std::string &json);

struct MigratedNameSet
{
    std::set<std::string> names;
    // Input names rewritten through the map (map key with a non-empty target).
    size_t mappedCount = 0;
    // Input names removed: map key with an empty target (explicit drop directive).
    size_t droppedCount = 0;
};

struct MigratedNameCounts
{
    std::map<std::string, int> counts;
    size_t mappedCount = 0;
    size_t droppedCount = 0;
};

// Rewrites a set of preset basenames through the legacy-name map.
//
// Pass-through rule: a name that is NOT a key in the map is kept untouched (and counted
// as neither mapped nor dropped). Unmatched OLD names therefore survive as harmless
// orphans — they never match a preset in the new pack — but names a user already stored
// in new-pack (CotC) form (e.g. favourites from the trial build) are preserved exactly.
// This is safe precisely because the migration is one-shot (guarded by the
// RoonVisLegacyNameMigrationApplied flag), so names can never be re-mapped twice.
MigratedNameSet MigrateNameSet(const std::set<std::string> &names,
                               const std::map<std::string, std::string> &nameMap);

// Same rules for a basename -> count dictionary (slow-pending counts). When two input
// names land on the same output name (mapping collision, or a mapped name colliding
// with a pass-through), the MAX count wins — pessimistic, so a nearly-promoted slow
// preset is not reset by the rename.
MigratedNameCounts MigrateNameCounts(const std::map<std::string, int> &counts,
                                     const std::map<std::string, std::string> &nameMap);

}  // namespace RoonVis
