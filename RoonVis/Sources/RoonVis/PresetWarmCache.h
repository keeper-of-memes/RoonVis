#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace RoonVis
{

inline constexpr double kPresetIdleWarmFrameBudgetSeconds = 1.0 / 60.0;
inline constexpr double kPresetIdleWarmAttemptBudgetSeconds = 0.008;
inline constexpr unsigned kPresetIdleWarmRequiredFrames = 4;

enum class PresetWarmStrategy
{
    IdleFrame,
};

struct PresetWarmCandidate
{
    size_t index = SIZE_MAX;
    std::string path;
};

bool PresetWarmCandidateIsValid(const PresetWarmCandidate& candidate);

// Bookkeeping for the single primary-preload warm target. The warm/failed entry lists
// are capped at one entry each: the library exposes exactly one preload slot, so only
// the most recent warm (and most recent failure) is worth remembering.
class PresetWarmCache
{
public:
    PresetWarmCache() = default;

    void Reset();
    void NoteActivePreset(size_t index, const std::string& path);

    bool IsWarm(size_t index, const std::string& path) const;
    bool IsInFlight(size_t index, const std::string& path) const;
    bool IsFailed(size_t index, const std::string& path) const;
    bool HasInFlight() const { return hasInFlight_; }
    PresetWarmCandidate InFlightCandidate() const;

    PresetWarmCandidate ChooseNextCandidate(const std::vector<PresetWarmCandidate>& upcoming) const;

    void MarkWarmStarted(size_t index, const std::string& path);
    void MarkWarmFinished(size_t index, const std::string& path, bool success);

    size_t WarmCount() const { return warmEntries_.size(); }
    size_t FailedCount() const { return failedEntries_.size(); }

private:
    struct Entry
    {
        size_t index = SIZE_MAX;
        std::string path;
        uint64_t stamp = 0;
    };

    static bool Matches(const Entry& entry, size_t index, const std::string& path);
    void Remove(size_t index, const std::string& path);
    void TouchWarm(size_t index, const std::string& path);
    void TouchFailed(size_t index, const std::string& path);
    void EvictIfNeeded();
    void EvictFailuresIfNeeded();

    uint64_t clock_ = 0;
    std::vector<Entry> warmEntries_;
    std::vector<Entry> failedEntries_;
    Entry inFlight_;
    bool hasInFlight_ = false;
};

class PresetIdleWarmBudget
{
public:
    PresetIdleWarmBudget(double frameBudgetSeconds = kPresetIdleWarmFrameBudgetSeconds,
                         double warmAttemptBudgetSeconds = kPresetIdleWarmAttemptBudgetSeconds,
                         unsigned requiredIdleFrames = kPresetIdleWarmRequiredFrames);

    void Reset();
    bool RecordFrame(double actualFrameIntervalSeconds,
                     double targetFrameIntervalSeconds,
                     double renderDurationSeconds,
                     double swapDurationSeconds,
                     bool transitionActive);
    void ConsumeWarmAttempt();

    double AccumulatedBudgetSeconds() const { return accumulatedBudgetSeconds_; }
    unsigned IdleFrames() const { return idleFrames_; }
    double WarmAttemptBudgetSeconds() const { return warmAttemptBudgetSeconds_; }

private:
    double frameBudgetSeconds_;
    double warmAttemptBudgetSeconds_;
    unsigned requiredIdleFrames_;
    double accumulatedBudgetSeconds_ = 0.0;
    unsigned idleFrames_ = 0;
};

}  // namespace RoonVis
