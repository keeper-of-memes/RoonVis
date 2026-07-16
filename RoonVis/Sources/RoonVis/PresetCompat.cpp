#include "PresetCompat.h"

#include "PresetFileParser.hpp"

#include <algorithm>
#include <cctype>
#include <set>
#include <sstream>

namespace RoonVis
{

namespace
{

constexpr int kMaxCustomShapes = 4;
constexpr int kMaxCustomWaves = 4;

int CountOccurrences(const std::string& haystack, const std::string& needle)
{
    if (needle.empty())
    {
        return 0;
    }
    int count = 0;
    size_t pos = 0;
    while ((pos = haystack.find(needle, pos)) != std::string::npos)
    {
        count++;
        pos += needle.size();
    }
    return count;
}

bool IsIdentifierChar(char c)
{
    return std::isalnum(static_cast<unsigned char>(c)) != 0 || c == '_';
}

// Milkdrop builtin sampler targets that never require a texture file: the
// framebuffer, blur passes, procedural noise, and the randomised slots (which
// draw from whatever textures exist — never a specific missing file).
bool IsBuiltinTextureName(const std::string& lowered)
{
    static const std::set<std::string> kExact = {
        "main", "blur1", "blur2", "blur3",
        "noise_lq", "noise_lq_lite", "noise_mq", "noise_hq",
        "noisevol_lq", "noisevol_hq",
        // HLSL keyword, not a texture: "sampler_state { ... }" blocks.
        "state",
    };
    if (kExact.count(lowered) > 0)
    {
        return true;
    }
    // rand00..rand15 with optional _smalltiled suffix.
    if (lowered.rfind("rand", 0) == 0 && lowered.size() >= 6 &&
        std::isdigit(static_cast<unsigned char>(lowered[4])) &&
        std::isdigit(static_cast<unsigned char>(lowered[5])))
    {
        return lowered.size() == 6 || lowered.substr(6) == "_smalltiled";
    }
    return false;
}

// Extracts non-builtin texture names from shader code: identifiers following
// "sampler_", with the optional wrap/filter mode prefix (fw_/fc_/pw_/pc_)
// stripped, matching Milkdrop's naming (sampler_<mode>_<texture>).
void CollectTextureRefs(const std::string& shader, std::vector<std::string>& out)
{
    static const char* kPrefix = "sampler_";

    // Presets alias samplers ("#define sampler_pic sampler_cells"); after
    // preprocessing every use of the alias resolves to the target, so the
    // alias name is never a texture file. Collect alias names first and
    // exclude them wholesale (their targets are collected normally).
    std::set<std::string> aliasNames;
    {
        size_t definePos = 0;
        while ((definePos = shader.find("#define", definePos)) != std::string::npos)
        {
            size_t namePos = shader.find(kPrefix, definePos);
            size_t lineEnd = shader.find('\n', definePos);
            if (namePos != std::string::npos && (lineEnd == std::string::npos || namePos < lineEnd))
            {
                size_t start = namePos + 8;
                size_t end = start;
                while (end < shader.size() && IsIdentifierChar(shader[end]))
                {
                    end++;
                }
                aliasNames.insert(shader.substr(start, end - start));
            }
            definePos += 7;
        }
    }

    size_t pos = 0;
    while ((pos = shader.find(kPrefix, pos)) != std::string::npos)
    {
        size_t start = pos + 8;
        size_t end = start;
        while (end < shader.size() && IsIdentifierChar(shader[end]))
        {
            end++;
        }
        pos = end;
        std::string name = shader.substr(start, end - start);
        if (aliasNames.count(name) > 0)
        {
            continue;
        }
        if (name.size() > 3)
        {
            const std::string mode = name.substr(0, 3);
            if (mode == "fw_" || mode == "fc_" || mode == "pw_" || mode == "pc_")
            {
                name = name.substr(3);
            }
        }
        if (name.empty())
        {
            continue;
        }
        std::string lowered = name;
        std::transform(lowered.begin(), lowered.end(), lowered.begin(),
                       [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
        if (IsBuiltinTextureName(lowered))
        {
            continue;
        }
        if (std::find(out.begin(), out.end(), name) == out.end())
        {
            out.push_back(name);
        }
    }
}

bool ExtractFromParser(libprojectM::MilkdropPreset::PresetFileParser& parser, PresetCompatFeatures& out)
{
    out = PresetCompatFeatures{};

    for (int i = 0; i < kMaxCustomShapes; i++)
    {
        const std::string prefix = "shapecode_" + std::to_string(i) + "_";
        if (!parser.GetBool(prefix + "enabled", false))
        {
            continue;
        }
        out.enabledShapes++;
        // CustomShape.cpp defaults num_inst to 1 when absent; mirror that.
        out.totalShapeInstances += std::max(1, parser.GetInt(prefix + "num_inst", 1));
        out.maxShapeSides = std::max(out.maxShapeSides, parser.GetInt(prefix + "sides", 4));
    }

    for (int i = 0; i < kMaxCustomWaves; i++)
    {
        const std::string prefix = "wavecode_" + std::to_string(i) + "_";
        if (!parser.GetBool(prefix + "enabled", false))
        {
            continue;
        }
        out.enabledWaves++;
        out.wavePerPointLen += parser.GetCode("wave_" + std::to_string(i) + "_per_point").size();
    }

    const std::string warp = parser.GetCode("warp_");
    const std::string comp = parser.GetCode("comp_");
    out.warpShaderLen = warp.size();
    out.compShaderLen = comp.size();
    out.perFrameLen = parser.GetCode("per_frame_").size();
    out.perPixelLen = parser.GetCode("per_pixel_").size();

    const std::string shaders = warp + "\n" + comp;
    out.blurTaps = CountOccurrences(shaders, "GetBlur1") + CountOccurrences(shaders, "GetBlur2") +
                   CountOccurrences(shaders, "GetBlur3");
    out.samplerRefs = CountOccurrences(shaders, "sampler_");
    out.shaderLoops = CountOccurrences(shaders, "for") + CountOccurrences(shaders, "while");
    out.presetVersion = parser.GetInt("MILKDROP_PRESET_VERSION", 0);

    CollectTextureRefs(shaders, out.textureRefs);
    return true;
}

} // namespace

bool ExtractPresetCompatFeatures(const std::string& path, PresetCompatFeatures& out)
{
    libprojectM::MilkdropPreset::PresetFileParser parser;
    if (!parser.Read(path))
    {
        return false;
    }
    return ExtractFromParser(parser, out);
}

bool ExtractPresetCompatFeaturesFromBuffer(const std::string& contents, PresetCompatFeatures& out)
{
    std::istringstream stream(contents);
    libprojectM::MilkdropPreset::PresetFileParser parser;
    if (!parser.Read(stream))
    {
        return false;
    }
    return ExtractFromParser(parser, out);
}

const char* PresetCompatVerdictName(PresetCompatVerdict verdict)
{
    switch (verdict)
    {
        case PresetCompatVerdict::Pass: return "pass";
        case PresetCompatVerdict::Marginal: return "marginal";
        case PresetCompatVerdict::Fail: return "fail";
    }
    return "pass";
}

// ---------------------------------------------------------------------------
// Derived rules — provenance (2026-07-08, bundled 292-pack, seed-42 stratified
// 70/30 split; docs/preset-compat-scan-prompt.md constraints):
//
// A15 fail:  totalShapeInstances >= 400.
//   Train (slow n=50 vs pass n=142): precision 0.81, recall 0.52.
//   HOLDOUT (slow n=21 vs pass n=61): precision 0.91, recall 0.48.
//   Grounded in device profiling: ~1 ms/shape-instance through ANGLE->Metal
//   (KNOWN_ISSUES.md); recall is capped ~0.5 because half the slow set is
//   audio-bound with no static signature (expected ceiling, documented).
// A15 marginal: 150 <= shapes < 400 (holdout adds recall to 0.71 at 0.83
//   precision for fail-or-marginal), OR the staticHeavy signature
//   blurTaps >= 8 && perFrameLen >= 1000 (WEAK: n=12 train, 0.67 precision /
//   0.40 recall on a 5-preset holdout — visual-quality flag, not perf).
// A8 — RETRAINED ON DEVICE LABELS (2026-07-09), replacing the earlier
//   physics-extrapolated rules. Ground truth: 160-preset stratified CotC
//   sample, 2-lap 30 s-dwell burn-in on the Apple TV HD (A8, 720p@30),
//   worst per-preset maxRenderMs across laps; fail label = catastrophic
//   (>=500 ms) or loadFail (n=110), marginal-ish = heavy (200-500 ms,
//   n=26), pass-ish = spiky/clean (<200 ms, n=24; spikes are crossfade
//   artifacts). Split: seed-42 stratified 70/30 by severity class
//   (112 train / 48 holdout), derived on train only.
//     fail     = shapes >= 100, OR shaderLen >= 1500, OR
//                (shaderLen >= 1000 && blurTaps >= 2).
//                Train (fail n=77): precision 0.93, recall 0.66.
//                HOLDOUT (fail n=33): precision 0.83, recall 0.61 — and
//                all four holdout false positives were heavy (200-500 ms);
//                zero clean/spiky presets flagged. The 29 learnedSlowSeedHD
//                positives corroborate: 11/29 caught, 0 wrongly cleared.
//     pass     = NONE. No reliable static pass rule exists for the A8:
//                69% of the sample is catastrophic, including presets with
//                no warp/comp shader at all (40% of fully shaderless
//                samples are catastrophic — e.g. "PieturP - sunflare.milk",
//                statically near-empty, 592 ms max render). The strictest
//                profile tried (shaderless, no blur, <=4 shape instances,
//                no wave per-point code, per-pixel <= 100 B) cleared only
//                6/160 and still false-cleared 1/6 (WEAK: n=6). The old
//                clean-profile pass rule cleared 18 holdout presets, 61%
//                of them heavy-or-worse on device — removed.
//     marginal = everything else (statically undecidable). Runtime
//                learned-slow remains authoritative on HD; these verdicts
//                only rank bundling risk (HD ships the curated 292 pack).
// crashing (n=1) is a fixture, not a rule.
// ---------------------------------------------------------------------------
PresetCompatResult ClassifyPresetCompat(const PresetCompatFeatures& features)
{
    PresetCompatResult result;
    const int shapes = features.totalShapeInstances;
    std::string reasons;
    auto addReason = [&reasons](const char* reason) {
        if (!reasons.empty())
        {
            reasons += ";";
        }
        reasons += reason;
    };

    if (shapes >= 400)
    {
        result.a15 = PresetCompatVerdict::Fail;
        addReason("shape-instances");
    }
    else if (shapes >= 150)
    {
        result.a15 = PresetCompatVerdict::Marginal;
        addReason("shape-instances-moderate");
    }
    else if (features.blurTaps >= 8 && features.perFrameLen >= 1000)
    {
        result.a15 = PresetCompatVerdict::Marginal;
        addReason("static-heavy-signature-weak");
    }

    // A8 — RETRAINED 2026-07-13 on a 2,565-preset device burn-in of the full
    // CotC pack (Apple TV HD, A8, 720p; perf-sweep dwell, per-preset CompatBurnIn
    // max-render outcomes). This REFUTES the earlier "no static A8 pass exists"
    // conclusion: with the custom-shader features the A8 pass/fail boundary is
    // ~perfectly separable. Two observed failure bands:
    //
    // (1) CUSTOM-SHADER CLIFF. ANY custom warp/comp HLSL shader or blur pass
    //     was ~100% "slow" on-device, and 100% of the 737 catastrophic
    //     outcomes had custom shaders. Device max-render: shader-free passes
    //     ~68ms; custom-shader presets 760ms median, up to 5,395ms.
    //       warpShaderLen>0 → 100% slow (n=907)
    //       compShaderLen>0 → 100% slow (n=927)
    //       blurTaps>0      → 100% slow (n=775)
    //     MECHANISM (measured 2026-07-13, 30s-dwell steady-state run, n=24
    //     custom-shader dwells): MOSTLY the one-time shader/PSO compile on
    //     the A8's slow CPU, NOT a GL capability issue. Load-window spike
    //     median 306ms (max 1.5s) vs settled steady-state median 37ms —
    //     UNDER the 40ms/25fps budget; 14/24 ran within budget and 17/24
    //     within 2x once settled. The screening campaign's 6s perf-sweep
    //     dwell defeated the preload lead time and charged that compile to
    //     maxRenderMs, mislabeling compile-bound presets catastrophic. A
    //     real minority (7/24, ~30%) IS sustained-slow (0.3-1.3s/frame
    //     steady) and stays excluded on merit. Context verified en route:
    //     the A8 supports ES3 (GX6450); the angle-es3-legacy-gpu.patch only
    //     changes ANGLE's *reported* ES version; ANGLE's GLSL→MSL output is
    //     family-independent for projectM's usage; Metal has no software
    //     shader-execution fallback. RECOVERY PATH: re-screen the
    //     custom-shader pool with a steady-state ship gate (long dwell,
    //     preload-respecting cadence) instead of per-dwell max.
    //
    // (2) HEAVY-CODE GRADIENT (shader-free presets). A smooth 109ms-median /
    //     422ms-max band — plausibly per-vertex/per-pixel expression
    //     evaluation cost, but likewise not mechanism-proven:
    //       totalShapeInstances>=4 → 92% slow (n=348)
    //       perPixelLen>=400       → 94% slow (n=400)
    //       wavePerPointLen>=400   → 91% slow (n=997)
    //
    // A preset with NONE of these ran acceptably (max frame <80ms = 2x the
    // 40ms/25fps budget) in 70% of cases (n=544). NOTE: this predictor is a
    // BURN-IN CANDIDATE FILTER, not the ship gate — the shipped HD catalog is
    // driven by the evidence-backed capability manifest (device-confirmed).
    //
    // SUPERSEDED FINDING (2026-07-15, steady-state re-screen of all 1,090
    // excluded custom-shader presets + W7 activation study): the "custom-shader
    // cliff" above was an ARTIFACT of the max-render metric — the spike is the
    // one-time shader compile, not steady rendering. Measured steady truth:
    //   - 72% of custom-shader presets PASS the 720p steady budget (779/1,084);
    //   - the old Fail verdict was wrong for 78% of its rejections when
    //     validated against measured steady labels (913+121 of 1,170);
    //   - NO static feature separates the 136 genuine steady-fails from the
    //     passes (feature medians nearly identical; warpShaderLen INVERTED —
    //     fails have SHORTER shaders). Steady-state failure on the A8 is not
    //     statically predictable; device screening is the only arbiter.
    //   - What custom shaders DO predict is ACTIVATION COST (sync-cold load
    //     ~245ms floor on the A8 even with all caches warm — eval-compile
    //     bound), i.e. activationMechanism=tier1-cache in manifest terms.
    // Therefore custom-shader/heavy-code presets are now MARGINAL (= "needs
    // device screening", the honest claim), not Fail. The clean-profile Pass
    // is kept: it remained 100% precise against measured truth (460/460).
    if (features.warpShaderLen > 0 || features.compShaderLen > 0 || features.blurTaps > 0)
    {
        // Custom shader: activation-cost signal + screening required — NOT a
        // steady-state verdict (78% of the old Fail rejections measured pass).
        result.a8 = PresetCompatVerdict::Marginal;
        addReason("a8-custom-shader-screen");
    }
    else if (shapes >= 100)
    {
        result.a8 = PresetCompatVerdict::Fail;
        if (result.a15 != PresetCompatVerdict::Fail)
        {
            addReason("a8-shape-instances");
        }
    }
    else if (features.totalShapeInstances >= 4 || features.perPixelLen >= 400 ||
             features.wavePerPointLen >= 400)
    {
        // Heavy-code gradient (shader-free): still a useful screening
        // prioritiser, but demoted to Marginal for the same reason — the W2
        // labels showed the old Fail overstated what statics can know.
        result.a8 = PresetCompatVerdict::Marginal;
        addReason("a8-heavy-code-screen");
    }
    else
    {
        // No fatal feature: the restored A8 Pass — 100% precise against the
        // 2026-07-15 measured steady labels (460/460 validated).
        result.a8 = PresetCompatVerdict::Pass;
        addReason("a8-clean-profile");
    }

    // Confidence: distance from the shape threshold dominates (the only
    // strong signal); rule-strength floors elsewhere. (A8 no longer has a
    // Pass verdict, so the former 0.75 clean-profile bonus is gone.)
    if (result.a15 == PresetCompatVerdict::Fail)
    {
        result.confidence = std::min(1.0, static_cast<double>(shapes) / 800.0);
    }
    else if (result.a15 == PresetCompatVerdict::Marginal)
    {
        result.confidence = 0.5;
    }
    else
    {
        result.confidence = 0.6;
    }
    if (reasons.empty())
    {
        reasons = "clean";
    }
    result.reasons = reasons;
    return result;
}

} // namespace RoonVis
