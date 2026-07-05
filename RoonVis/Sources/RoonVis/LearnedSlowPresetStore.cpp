#include "LearnedSlowPresetStore.h"

namespace RoonVis
{

void LearnedSlowPresetStore::LoadConfirmed(const std::vector<std::string> &names)
{
    for (const std::string &name : names)
    {
        if (name.empty())
        {
            continue;
        }
        _confirmed.insert(name);
        _pending.erase(name);
    }
}

void LearnedSlowPresetStore::LoadPendingCounts(const std::map<std::string, int> &counts)
{
    for (const auto &entry : counts)
    {
        if (entry.first.empty() || entry.second <= 0)
        {
            continue;
        }
        if (_confirmed.find(entry.first) != _confirmed.end())
        {
            continue;
        }
        _pending[entry.first] = entry.second;
    }
}

LearnedSlowDecision LearnedSlowPresetStore::RecordDetection(const std::string &name, bool catastrophic)
{
    LearnedSlowDecision decision;
    if (name.empty())
    {
        return decision;
    }

    if (_confirmed.find(name) != _confirmed.end())
    {
        // Already permanently learned; nothing new to persist.
        decision.nowLearnedSlow = true;
        return decision;
    }

    if (catastrophic)
    {
        _confirmed.insert(name);
        _pending.erase(name);
        decision.nowLearnedSlow = true;
        decision.stateChanged = true;
        return decision;
    }

    int count = ++_pending[name];
    if (count >= kLearnedSlowDetectionThreshold)
    {
        _confirmed.insert(name);
        _pending.erase(name);
        decision.nowLearnedSlow = true;
    }
    decision.stateChanged = true;
    return decision;
}

bool LearnedSlowPresetStore::IsLearnedSlow(const std::string &name) const
{
    return _confirmed.find(name) != _confirmed.end();
}

void LearnedSlowPresetStore::Clear()
{
    _confirmed.clear();
    _pending.clear();
}

}  // namespace RoonVis
