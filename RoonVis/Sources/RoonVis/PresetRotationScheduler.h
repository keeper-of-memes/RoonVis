#pragma once

#include <cstddef>
#include <string>
#include <vector>

namespace RoonVis
{

// Parses the ROONVIS_ROTATION_FIXED_LIST debug env value: a comma-separated list of
// preset filenames. Entries are whitespace-trimmed; empty entries are dropped; order is
// preserved. Pure helper so the deterministic-rotation test hook stays host-testable.
std::vector<std::string> ParseFixedRotationList(const std::string &value);

// Resolves parsed fixed-rotation filenames against the loaded preset paths (matching on
// the path's final component). Unresolved filenames are silently dropped; the returned
// indexes keep the list's order (duplicates allowed, mirroring the list).
std::vector<size_t> ResolveFixedRotationIndexes(const std::vector<std::string> &filenames,
                                                const std::vector<std::string> &presetPaths);

// Pure failure-recovery policy for preset rotation. Owns the consecutive-failure and
// total-failure counters and, on each failed preset load, decides whether to skip past
// the failed preset, revert to the last known-good preset, or hold the current confirmed
// one. Preset indices, the projectM load itself, and the transient "reverting"
// re-entrancy guard stay in the ObjC bridge (ProjectMBridge) — this class is the tested
// decision core. Not thread-safe; the bridge drives it on the render/GL thread only.
class PresetRotationScheduler
{
public:
    enum class FailureAction
    {
        SkipToNext,        // advance past the failed preset (still under the skip cap)
        RevertToLastGood,  // skip cap reached: load the last known-good preset
        HoldConfirmed,     // skip cap reached with no recoverable target: keep confirmed
    };

    explicit PresetRotationScheduler(unsigned skipCap = 8);

    // A timed/beat switch was requested: clear the consecutive-failure run.
    void NoteSwitchRequested();

    // A preset load failed. `reverting` is the bridge's transient flag (a last-good
    // revert load is currently in flight, so this is a re-entrant failure); `hasLastGood`
    // is whether a valid last-good preset index exists. Increments the failure counters
    // and returns the action the bridge should perform.
    FailureAction NoteSwitchFailed(bool reverting, bool hasLastGood);

    unsigned FailureSkips() const { return failureSkips_; }
    unsigned long FailuresTotal() const { return failuresTotal_; }
    unsigned SkipCap() const { return skipCap_; }

private:
    unsigned skipCap_;
    unsigned failureSkips_ = 0;
    unsigned long failuresTotal_ = 0;
};

}  // namespace RoonVis
