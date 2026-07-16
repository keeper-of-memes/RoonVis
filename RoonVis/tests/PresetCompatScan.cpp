// PresetCompatScan.cpp
//
// HOST-SIDE static compatibility scanner for Milkdrop presets on Apple TV
// hardware tiers (A15-class 4K vs A8-class HD). Walks a directory tree
// (recursive - Cream of the Crop uses theme subdirectories), extracts static
// features per preset (PresetCompat.cpp), and prints a TSV:
//   path, a15, a8, confidence, shapeInst, shaders, blurTaps, waves, textures, reasons
//
// Modes:
//   PresetCompatScan <dir>                 TSV over every .milk under <dir>
//   PresetCompatScan --features <dir>      raw feature dump (rule derivation input)
//   PresetCompatScan --explain <file.milk> one-preset human-readable feature dump
//
// Verdict rules and their training provenance live in PresetCompat.cpp.
// Confusion matrices (bundled 292-pack, stratified holdout) are recorded in
// docs/cotc-compat-report.md once derived.
//
// Constraints (docs/preset-compat-scan-prompt.md): predictions are NEVER
// merged into device-confirmed blocklist labels; this tool reports.

#include "PresetCompat.h"

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <string>
#include <vector>

namespace fs = std::filesystem;
using namespace RoonVis;

namespace
{

std::vector<std::string> CollectPresets(const std::string& root)
{
    std::vector<std::string> files;
    std::error_code ec;
    for (auto it = fs::recursive_directory_iterator(root, ec); it != fs::recursive_directory_iterator(); it.increment(ec))
    {
        if (!ec && it->is_regular_file() && it->path().extension() == ".milk")
        {
            files.push_back(it->path().string());
        }
    }
    std::sort(files.begin(), files.end());
    return files;
}

std::string JoinTextures(const std::vector<std::string>& refs)
{
    std::string out;
    for (const auto& t : refs)
    {
        if (!out.empty())
        {
            out += ",";
        }
        out += t;
    }
    return out;
}

void PrintFeatureRow(const std::string& path, const PresetCompatFeatures& f)
{
    std::printf("%s\t%d\t%d\t%zu\t%zu\t%zu\t%zu\t%d\t%d\t%d\t%zu\t%d\t%d\t%s\n",
                path.c_str(), f.totalShapeInstances, f.enabledShapes, f.warpShaderLen,
                f.compShaderLen, f.perFrameLen, f.perPixelLen, f.blurTaps, f.samplerRefs,
                f.enabledWaves, f.wavePerPointLen, f.shaderLoops, f.presetVersion,
                JoinTextures(f.textureRefs).c_str());
}

} // namespace

int main(int argc, char** argv)
{
    if (argc < 2)
    {
        std::fprintf(stderr,
                     "usage: %s <presets-dir> | --features <presets-dir> | --explain <file.milk>\n",
                     argv[0]);
        return 2;
    }

    if (std::strcmp(argv[1], "--explain") == 0 && argc >= 3)
    {
        PresetCompatFeatures f;
        if (!ExtractPresetCompatFeatures(argv[2], f))
        {
            std::fprintf(stderr, "parse failed: %s\n", argv[2]);
            return 1;
        }
        std::printf("preset: %s\n", argv[2]);
        std::printf("  totalShapeInstances: %d (enabled shapes %d, max sides %d)\n",
                    f.totalShapeInstances, f.enabledShapes, f.maxShapeSides);
        std::printf("  shaders: warp %zu B, comp %zu B, per_frame %zu B, per_pixel %zu B\n",
                    f.warpShaderLen, f.compShaderLen, f.perFrameLen, f.perPixelLen);
        std::printf("  blurTaps: %d, samplerRefs: %d, loops: %d, version: %d\n",
                    f.blurTaps, f.samplerRefs, f.shaderLoops, f.presetVersion);
        std::printf("  waves: %d enabled, per_point %zu B\n", f.enabledWaves, f.wavePerPointLen);
        std::printf("  textures: %s\n", f.textureRefs.empty() ? "(none)" : JoinTextures(f.textureRefs).c_str());
        const PresetCompatResult r = ClassifyPresetCompat(f);
        std::printf("  verdict: a15=%s a8=%s confidence=%.2f reasons=%s\n",
                    PresetCompatVerdictName(r.a15), PresetCompatVerdictName(r.a8), r.confidence,
                    r.reasons.c_str());
        return 0;
    }

    const bool featuresOnly = std::strcmp(argv[1], "--features") == 0;
    const std::string root = featuresOnly ? (argc >= 3 ? argv[2] : "") : argv[1];
    if (root.empty())
    {
        std::fprintf(stderr, "missing directory\n");
        return 2;
    }

    const auto files = CollectPresets(root);
    int parsed = 0;
    int failed = 0;

    if (featuresOnly)
    {
        std::printf("path\tshapeInst\tshapes\twarpLen\tcompLen\tperFrameLen\tperPixelLen\tblurTaps\tsamplers\twaves\twavePerPointLen\tloops\tversion\ttextures\n");
    }
    else
    {
        std::printf("path\ta15\ta8\tconfidence\tshapeInst\twarpLen\tcompLen\tblurTaps\twaves\ttextures\treasons\n");
    }

    for (const auto& path : files)
    {
        PresetCompatFeatures f;
        if (!ExtractPresetCompatFeatures(path, f))
        {
            failed++;
            std::fprintf(stderr, "parse failed: %s\n", path.c_str());
            continue;
        }
        parsed++;
        if (featuresOnly)
        {
            PrintFeatureRow(path, f);
            continue;
        }
        const PresetCompatResult r = ClassifyPresetCompat(f);
        std::printf("%s\t%s\t%s\t%.2f\t%d\t%zu\t%zu\t%d\t%d\t%s\t%s\n", path.c_str(),
                    PresetCompatVerdictName(r.a15), PresetCompatVerdictName(r.a8), r.confidence,
                    f.totalShapeInstances, f.warpShaderLen, f.compShaderLen, f.blurTaps,
                    f.enabledWaves, JoinTextures(f.textureRefs).c_str(), r.reasons.c_str());
    }

    std::fprintf(stderr, "PresetCompatScan: %d parsed, %d failed under %s\n", parsed, failed,
                 root.c_str());
    return failed > 0 && parsed == 0 ? 1 : 0;
}
