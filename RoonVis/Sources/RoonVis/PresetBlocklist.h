#pragma once

#include <cstddef>
#include <string>
#include <unordered_set>

namespace RoonVis
{

struct PresetBlocklists
{
    std::unordered_set<std::string> slow;
    std::unordered_set<std::string> crashing;
    std::unordered_set<std::string> staticHeavy;
};

const PresetBlocklists &DefaultPresetBlocklists();
bool ParsePresetBlocklistJSON(const char *bytes, size_t length, PresetBlocklists &out);

bool IsSlowPreset(const PresetBlocklists &blocklists, const std::string &filename);
bool IsCrashingPreset(const PresetBlocklists &blocklists, const std::string &filename);
bool IsStaticHeavyPreset(const PresetBlocklists &blocklists, const std::string &filename);

}  // namespace RoonVis
