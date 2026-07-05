#pragma once

#include <map>
#include <set>
#include <string>
#include <vector>

namespace RoonVis
{

// Distinct non-catastrophic slow detections a preset must accumulate before it is
// promoted into the persisted learned-slow set. Because a preset is excluded from
// rotation for the rest of a session as soon as it is first flagged slow, a preset can
// only be re-flagged in a *later* launch — so this threshold is effectively "seen slow
// in N distinct sessions". A single first-cold-load 80ms x 3 flag (which can be transient
// warm-up cost) therefore only increments the count; it does not ban the preset.
constexpr int kLearnedSlowDetectionThreshold = 2;

struct LearnedSlowDecision
{
    // The preset is (now, or was already) in the persisted learned-slow set.
    bool nowLearnedSlow = false;
    // Persisted state (confirmed set or pending counts) changed and should be written out.
    bool stateChanged = false;
};

// Pure, host-testable bookkeeping for runtime-learned slow presets. Holds a "confirmed"
// set (presets excluded from rotation permanently across launches) plus per-preset
// pending detection counts used by the over-exclusion guard. Contains no I/O; the
// NSUserDefaults glue lives in the .mm and (de)serializes ConfirmedNames()/PendingCounts().
class LearnedSlowPresetStore
{
public:
    LearnedSlowPresetStore() = default;

    // Seed the confirmed set from persisted state at launch. Confirmed presets are
    // dropped from any pending counts.
    void LoadConfirmed(const std::vector<std::string> &names);
    // Seed pending detection counts from persisted state at launch. Entries already
    // confirmed, empty names, or non-positive counts are ignored.
    void LoadPendingCounts(const std::map<std::string, int> &counts);

    // Record one genuine slow detection for a preset. `catastrophic` is the >= 500ms
    // single-frame path, which promotes immediately; otherwise the pending count is
    // incremented and the preset is promoted once it reaches kLearnedSlowDetectionThreshold.
    LearnedSlowDecision RecordDetection(const std::string &name, bool catastrophic);

    bool IsLearnedSlow(const std::string &name) const;

    const std::set<std::string> &ConfirmedNames() const { return _confirmed; }
    const std::map<std::string, int> &PendingCounts() const { return _pending; }

    // Wipe all learned state (backs the clear/reset escape hatch).
    void Clear();

private:
    std::set<std::string> _confirmed;
    std::map<std::string, int> _pending;
};

}  // namespace RoonVis
