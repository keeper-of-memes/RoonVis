#include "PresetWarmCache.h"

#include <algorithm>

namespace RoonVis
{

namespace
{
// Only the single library preload slot exists, so remember at most one warm entry and
// one failed entry (the most recent of each).
constexpr size_t kPresetWarmEntryCap = 1;
}  // namespace

bool PresetWarmCandidateIsValid(const PresetWarmCandidate& candidate)
{
    return candidate.index != SIZE_MAX && !candidate.path.empty();
}

void PresetWarmCache::Reset()
{
    warmEntries_.clear();
    failedEntries_.clear();
    inFlight_ = Entry();
    hasInFlight_ = false;
    clock_ = 0;
}

void PresetWarmCache::NoteActivePreset(size_t index, const std::string& path)
{
    Remove(index, path);
    if (hasInFlight_ && Matches(inFlight_, index, path))
    {
        inFlight_ = Entry();
        hasInFlight_ = false;
    }
}

bool PresetWarmCache::IsWarm(size_t index, const std::string& path) const
{
    return std::any_of(warmEntries_.begin(), warmEntries_.end(), [&](const Entry& entry) {
        return Matches(entry, index, path);
    });
}

bool PresetWarmCache::IsInFlight(size_t index, const std::string& path) const
{
    return hasInFlight_ && Matches(inFlight_, index, path);
}

bool PresetWarmCache::IsFailed(size_t index, const std::string& path) const
{
    return std::any_of(failedEntries_.begin(), failedEntries_.end(), [&](const Entry& entry) {
        return Matches(entry, index, path);
    });
}

PresetWarmCandidate PresetWarmCache::InFlightCandidate() const
{
    if (!hasInFlight_)
    {
        return {};
    }
    return {inFlight_.index, inFlight_.path};
}

PresetWarmCandidate PresetWarmCache::ChooseNextCandidate(const std::vector<PresetWarmCandidate>& upcoming) const
{
    for (const PresetWarmCandidate& candidate : upcoming)
    {
        if (!PresetWarmCandidateIsValid(candidate))
        {
            continue;
        }
        if (IsInFlight(candidate.index, candidate.path) ||
            IsWarm(candidate.index, candidate.path) ||
            IsFailed(candidate.index, candidate.path))
        {
            continue;
        }
        return candidate;
    }
    return {};
}

void PresetWarmCache::MarkWarmStarted(size_t index, const std::string& path)
{
    if (index == SIZE_MAX || path.empty())
    {
        return;
    }

    inFlight_.index = index;
    inFlight_.path = path;
    inFlight_.stamp = ++clock_;
    hasInFlight_ = true;
}

void PresetWarmCache::MarkWarmFinished(size_t index, const std::string& path, bool success)
{
    if (hasInFlight_ && Matches(inFlight_, index, path))
    {
        inFlight_ = Entry();
        hasInFlight_ = false;
    }
    if (index == SIZE_MAX || path.empty())
    {
        return;
    }
    if (!success)
    {
        TouchFailed(index, path);
        EvictFailuresIfNeeded();
        return;
    }

    TouchWarm(index, path);
    EvictIfNeeded();
}

bool PresetWarmCache::Matches(const Entry& entry, size_t index, const std::string& path)
{
    return entry.index == index && entry.path == path;
}

void PresetWarmCache::Remove(size_t index, const std::string& path)
{
    warmEntries_.erase(std::remove_if(warmEntries_.begin(), warmEntries_.end(), [&](const Entry& entry) {
        return Matches(entry, index, path);
    }), warmEntries_.end());
    failedEntries_.erase(std::remove_if(failedEntries_.begin(), failedEntries_.end(), [&](const Entry& entry) {
        return Matches(entry, index, path);
    }), failedEntries_.end());
}

void PresetWarmCache::TouchWarm(size_t index, const std::string& path)
{
    failedEntries_.erase(std::remove_if(failedEntries_.begin(), failedEntries_.end(), [&](const Entry& entry) {
        return Matches(entry, index, path);
    }), failedEntries_.end());
    for (Entry& entry : warmEntries_)
    {
        if (Matches(entry, index, path))
        {
            entry.stamp = ++clock_;
            return;
        }
    }

    Entry entry;
    entry.index = index;
    entry.path = path;
    entry.stamp = ++clock_;
    warmEntries_.push_back(entry);
}

void PresetWarmCache::TouchFailed(size_t index, const std::string& path)
{
    for (Entry& entry : failedEntries_)
    {
        if (Matches(entry, index, path))
        {
            entry.stamp = ++clock_;
            return;
        }
    }

    Entry entry;
    entry.index = index;
    entry.path = path;
    entry.stamp = ++clock_;
    failedEntries_.push_back(entry);
}

void PresetWarmCache::EvictIfNeeded()
{
    while (warmEntries_.size() > kPresetWarmEntryCap)
    {
        auto oldest = std::min_element(warmEntries_.begin(), warmEntries_.end(), [](const Entry& lhs, const Entry& rhs) {
            return lhs.stamp < rhs.stamp;
        });
        if (oldest == warmEntries_.end())
        {
            return;
        }
        warmEntries_.erase(oldest);
    }
}

void PresetWarmCache::EvictFailuresIfNeeded()
{
    while (failedEntries_.size() > kPresetWarmEntryCap)
    {
        auto oldest = std::min_element(failedEntries_.begin(), failedEntries_.end(), [](const Entry& lhs, const Entry& rhs) {
            return lhs.stamp < rhs.stamp;
        });
        if (oldest == failedEntries_.end())
        {
            return;
        }
        failedEntries_.erase(oldest);
    }
}

PresetIdleWarmBudget::PresetIdleWarmBudget(double frameBudgetSeconds,
                                           double warmAttemptBudgetSeconds,
                                           unsigned requiredIdleFrames)
    : frameBudgetSeconds_(std::max(0.001, frameBudgetSeconds)),
      warmAttemptBudgetSeconds_(std::max(0.0, warmAttemptBudgetSeconds)),
      requiredIdleFrames_(std::max(1u, requiredIdleFrames))
{
}

void PresetIdleWarmBudget::Reset()
{
    accumulatedBudgetSeconds_ = 0.0;
    idleFrames_ = 0;
}

bool PresetIdleWarmBudget::RecordFrame(double actualFrameIntervalSeconds,
                                       double targetFrameIntervalSeconds,
                                       double renderDurationSeconds,
                                       double swapDurationSeconds,
                                       bool transitionActive)
{
    if (transitionActive)
    {
        return false;
    }

    const double targetFrameSeconds = targetFrameIntervalSeconds > 0.0 ? targetFrameIntervalSeconds : frameBudgetSeconds_;
    const double actualFrameSeconds = actualFrameIntervalSeconds > 0.0 ? actualFrameIntervalSeconds : targetFrameSeconds;
    if (actualFrameSeconds > targetFrameSeconds * 1.10)
    {
        Reset();
        return false;
    }

    const double usedSeconds = std::max(0.0, renderDurationSeconds) + std::max(0.0, swapDurationSeconds);
    if (usedSeconds >= targetFrameSeconds)
    {
        Reset();
        return false;
    }

    ++idleFrames_;
    accumulatedBudgetSeconds_ += targetFrameSeconds - usedSeconds;
    return idleFrames_ >= requiredIdleFrames_ && accumulatedBudgetSeconds_ >= warmAttemptBudgetSeconds_;
}

void PresetIdleWarmBudget::ConsumeWarmAttempt()
{
    accumulatedBudgetSeconds_ = 0.0;
    idleFrames_ = 0;
}

}  // namespace RoonVis
