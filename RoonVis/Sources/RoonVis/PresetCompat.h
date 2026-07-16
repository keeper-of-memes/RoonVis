#pragma once

#include <string>
#include <vector>

namespace RoonVis
{

// Static .milk feature extraction + per-tier compatibility verdicts for the
// Apple TV hardware tiers. Host-side analysis only in this pass — NOT linked
// into the tvOS app. Design + constraints: docs/preset-compat-scan-prompt.md.
//
// The tier-1 feature is totalShapeInstances: on-device profiling attributed
// 86-99% of catastrophic slow frames to custom-shape rendering at ~1 ms per
// shape instance (KNOWN_ISSUES.md) — per-draw-call pipeline overhead through
// ANGLE->Metal, linear in instance count.
struct PresetCompatFeatures
{
    // Shape cost (tier 1)
    int totalShapeInstances = 0; // sum of num_inst over ENABLED shapes only
    int enabledShapes = 0;
    int maxShapeSides = 0;

    // Shader cost (tier 2) — byte volume of assembled code blocks
    size_t warpShaderLen = 0;
    size_t compShaderLen = 0;
    size_t perFrameLen = 0;
    size_t perPixelLen = 0;
    int blurTaps = 0;    // GetBlur1/2/3 call sites in warp+comp
    int samplerRefs = 0; // sampler_ occurrences in warp+comp

    // Wave cost (tier 3)
    int enabledWaves = 0;
    size_t wavePerPointLen = 0; // per-point code across enabled waves

    // Structural (tier 4)
    int shaderLoops = 0; // "for"/"while" tokens in warp+comp (lexer-level)
    int presetVersion = 0;

    // Assets (tier 5): non-builtin texture basenames referenced by shaders
    // (case preserved; Milkdrop matching is case-sensitive on disk).
    std::vector<std::string> textureRefs;
};

// Parses `path` with projectM's PresetFileParser and fills `out`.
// Returns false if the file cannot be read/parsed.
bool ExtractPresetCompatFeatures(const std::string& path, PresetCompatFeatures& out);

// Same extraction from an already-loaded buffer (host tests use this).
bool ExtractPresetCompatFeaturesFromBuffer(const std::string& contents, PresetCompatFeatures& out);

enum class PresetCompatVerdict
{
    Pass,
    Marginal,
    Fail,
};

struct PresetCompatResult
{
    PresetCompatVerdict a15 = PresetCompatVerdict::Pass;
    PresetCompatVerdict a8 = PresetCompatVerdict::Pass;
    // 0..1; how far inside/outside the decision thresholds the preset sits.
    double confidence = 0.0;
    std::string reasons; // semicolon-joined dominant features
};

// Applies the derived rules (thresholds documented at each rule site in the
// .cpp, with their training provenance). Pure function of the features.
PresetCompatResult ClassifyPresetCompat(const PresetCompatFeatures& features);

const char* PresetCompatVerdictName(PresetCompatVerdict verdict);

} // namespace RoonVis
