// ParseInputHashGen.cpp
//
// HOST-SIDE (GL-free) reproduction of the exact parse-stage input text projectM composes
// on-device for every bundled preset shader — the "Tier-1 fidelity spike" tool.
//
// For each preset (.milk) and each of its shaders (warp, composite) that the device would
// actually transpile, this tool computes the byte-exact string that
// MilkdropShader::TranspileHLSLShader hands to parser.Parse(...), and emits a TSV record
// on stdout:
//
//   bundleRelativePath \t shaderType \t key
//
// where key = ComputePreprocessCacheKey(composedParseInput) (the existing dual-FNV1a
// helper in MilkdropShaderPreprocess.cpp — reused, not reimplemented; NOTE: the TSV
// deliberately keeps the FIRST-stage salt so historical spike runs stay diffable). One
// extra record (type "comp-default") is emitted for the default composite shader so
// device-side fallback compiles can be classified.
//
// W5 refactor: the replica logic this tool proved (100.000% match against the live app
// across the full 7,732-preset pack, 11,896 shader records, 0 mismatches) was extracted
// VERBATIM into the reusable core Sources/RoonVis/MilkdropTranspilePrep.{h,cpp}; this tool
// is now a thin wrapper over that core and MUST keep byte-identical stdout output — it is
// the proven reference implementation (re-proof: diff a full-pack run against the
// known-good TSV whenever the core changes).
//
// Usage: ParseInputHashGen <presets-dir> <textures-dir> [<extra-search-dir>] [--dump=<substr>]
//   TSV on stdout; progress + summary on stderr.
//   --dump=<substr> prints the fully composed parse input of every shader whose preset
//   relative path contains <substr> (and of the comp-default record if <substr> is
//   "comp-default") to stderr, for manual layout eyeballing.

#include "MilkdropTranspilePrep.h"

#include "MilkdropShaderPreprocess.hpp"
#include "PresetFileParser.hpp"

#include <algorithm>
#include <cstdio>
#include <map>
#include <string>
#include <vector>

#if __has_include(<filesystem>)
#include <filesystem>
namespace fs = std::filesystem;
#endif

using libprojectM::MilkdropPreset::ComputePreprocessCacheKey;
using libprojectM::MilkdropPreset::MilkdropShader;
using libprojectM::MilkdropPreset::PresetFileParser;

using RoonVis::TranspilePrep::BuildTextureCatalog;
using RoonVis::TranspilePrep::ComposeParseInput;
using RoonVis::TranspilePrep::HostDescriptor;
using RoonVis::TranspilePrep::kDefaultCompositeShaderBody;
using RoonVis::TranspilePrep::PreparedParseInputs;
using RoonVis::TranspilePrep::PrepareParseInputsFromParser;
using RoonVis::TranspilePrep::Stats;
using RoonVis::TranspilePrep::TextureCatalog;

namespace {

void EmitRecord(const std::string& relPath, const char* shaderType, const std::string& composed)
{
    std::printf("%s\t%s\t%s\n", relPath.c_str(), shaderType, ComputePreprocessCacheKey(composed).c_str());
}

void MaybeDump(const std::string& dumpSubstr, const std::string& relPath,
               const char* shaderType, const std::string& composed)
{
    if (dumpSubstr.empty() || relPath.find(dumpSubstr) == std::string::npos)
    {
        return;
    }
    std::fprintf(stderr, "==== DUMP %s [%s] (%zu bytes) ====\n%s\n==== END DUMP ====\n",
                 relPath.c_str(), shaderType, composed.size(), composed.c_str());
}

} // namespace

int main(int argc, char** argv)
{
#if !defined(__cpp_lib_filesystem) && !__has_include(<filesystem>)
    std::fprintf(stderr, "std::filesystem unavailable\n");
    return 2;
#else
    std::vector<std::string> positional;
    std::string dumpSubstr;
    for (int i = 1; i < argc; ++i)
    {
        std::string arg = argv[i];
        if (arg.rfind("--dump=", 0) == 0)
        {
            dumpSubstr = arg.substr(7);
        }
        else
        {
            positional.push_back(arg);
        }
    }
    if (positional.size() < 2)
    {
        std::fprintf(stderr, "usage: %s <presets-dir> <textures-dir> [<extra-search-dir>] [--dump=<substr>]\n", argv[0]);
        return 2;
    }
    const std::string presetDir = positional[0];

    // Texture search paths, in the app's registration order (ProjectMBridge.mm).
    std::vector<std::string> searchPaths;
    for (size_t i = 1; i < positional.size(); ++i)
    {
        searchPaths.push_back(positional[i]);
    }

    std::error_code ec;
    if (!fs::is_directory(presetDir, ec))
    {
        std::fprintf(stderr, "Preset directory not found: %s\n", presetDir.c_str());
        return 2;
    }

    const TextureCatalog catalog = BuildTextureCatalog(searchPaths);
    std::fprintf(stderr, "Texture scan: %zu files across %zu search paths\n",
                 catalog.baseNames.size(), searchPaths.size());

    std::vector<std::string> presetFiles;
    for (auto it = fs::recursive_directory_iterator(presetDir, ec); it != fs::recursive_directory_iterator(); it.increment(ec))
    {
        if (!ec && it->is_regular_file() && it->path().extension() == ".milk")
        {
            presetFiles.push_back(it->path().string());
        }
    }
    std::sort(presetFiles.begin(), presetFiles.end());

    Stats stats;
    const fs::path presetRoot(presetDir);

    for (const auto& path : presetFiles)
    {
        ++stats.presetsScanned;
        if (stats.presetsScanned % 1000 == 0)
        {
            std::fprintf(stderr, "... %d/%zu presets\n", stats.presetsScanned, presetFiles.size());
        }

        const std::string relPath = fs::path(path).lexically_relative(presetRoot).generic_string();

        PresetFileParser parser;
        if (!parser.Read(path))
        {
            ++stats.presetReadFailures;
            std::fprintf(stderr, "SKIP (unreadable): %s\n", relPath.c_str());
            continue;
        }

        const PreparedParseInputs prepared = PrepareParseInputsFromParser(parser, catalog, stats);

        if (prepared.warp.present)
        {
            EmitRecord(relPath, "warp", prepared.warp.text);
            MaybeDump(dumpSubstr, relPath, "warp", prepared.warp.text);
        }
        else if (prepared.warpDropped)
        {
            std::fprintf(stderr, "NOTE warp dropped (assemble/preprocess failed): %s\n", relPath.c_str());
        }

        if (prepared.compFallback)
        {
            std::fprintf(stderr, "NOTE comp fell back to default (assemble/preprocess failed): %s\n", relPath.c_str());
        }
        if (prepared.comp.present)
        {
            EmitRecord(relPath, "comp", prepared.comp.text);
            MaybeDump(dumpSubstr, relPath, "comp", prepared.comp.text);
        }
        else if (prepared.compDefaultFailed)
        {
            std::fprintf(stderr, "NOTE comp default failed to compose (unexpected): %s\n", relPath.c_str());
        }
    }

    // --- The default composite shader as a standalone record, for fallback classification.
    //     Fresh (empty) rand-slot cache; its body references only sampler_main. ---
    {
        std::map<int, HostDescriptor> emptyCache;
        std::string composed;
        if (ComposeParseInput(MilkdropShader::ShaderType::CompositeShader, kDefaultCompositeShaderBody,
                              emptyCache, catalog, stats, composed))
        {
            EmitRecord("<default>", "comp-default", composed);
            MaybeDump(dumpSubstr, "comp-default", "comp-default", composed);
        }
        else
        {
            std::fprintf(stderr, "ERROR: default composite shader failed to compose\n");
            return 1;
        }
    }

    std::fprintf(stderr,
                 "ParseInputHashGen summary:\n"
                 "  presets scanned:            %d\n"
                 "  preset read failures:       %d\n"
                 "  warp records emitted:       %d\n"
                 "  comp records emitted:       %d\n"
                 "  warp gated (version<=0):    %d\n"
                 "  warp gated (empty body):    %d\n"
                 "  comp gated (version<=0):    %d\n"
                 "  comp using default body:    %d\n"
                 "  comp fallback after fail:   %d\n"
                 "  warp dropped after fail:    %d\n"
                 "  rand empty descriptors:     %d\n",
                 stats.presetsScanned, stats.presetReadFailures,
                 stats.warpEmitted, stats.compEmitted,
                 stats.warpGatedVersion, stats.warpGatedEmpty,
                 stats.compGatedVersion, stats.compDefaultBody,
                 stats.compFallbacks, stats.warpDropped,
                 stats.randEmptyDescriptors);
    return 0;
#endif
}
