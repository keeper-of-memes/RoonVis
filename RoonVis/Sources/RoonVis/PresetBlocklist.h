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
    // One-time learned-slow seed for the Apple TV HD tier: presets that failed to
    // render a single confirmed frame during the 2026-07-06 full-pack burn-in on an
    // A8. Applied once into the persisted learned-slow store on HD devices (NOT a
    // static blocklist - these run fine on A12+).
    std::unordered_set<std::string> learnedSlowSeedHD;
};

const PresetBlocklists &DefaultPresetBlocklists();
bool ParsePresetBlocklistJSON(const char *bytes, size_t length, PresetBlocklists &out);

bool IsSlowPreset(const PresetBlocklists &blocklists, const std::string &filename);
bool IsCrashingPreset(const PresetBlocklists &blocklists, const std::string &filename);
bool IsStaticHeavyPreset(const PresetBlocklists &blocklists, const std::string &filename);

}  // namespace RoonVis
