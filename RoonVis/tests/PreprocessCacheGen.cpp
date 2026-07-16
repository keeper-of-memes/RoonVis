// PreprocessCacheGen.cpp
//
// HOST-SIDE build-time generator for the prepopulated shader-transpile cache (RVPP v2).
//
// Stage 1 (preprocess, unchanged semantics from v1): for every non-empty warp/comp shader
// body, computes the SAME cache key the runtime computes (AssembleApplyPreprocessorInput ->
// ComputePreprocessCacheKey) and the SAME value the runtime would store
// (M4::HLSLParser::ApplyPreprocessor over the assembled input).
//
// Stage 2 (Tier-1 parse/generate): via the proven MilkdropTranspilePrep core (the W4
// fidelity-spike replica, 100.000% match vs the live app across the full pack), composes
// the exact POST-insertion parse-input text per shader the device would transpile, runs
// the REAL HLSL parse + GLSL generation host-side (device configuration: 300 es, "PS",
// AlternateNanPropagation), and stores key=ComputeParseGenCacheKey(text), value=GLSL.
//
// Both stages are written stage-tagged into one RVPP v2 container that the app seeds into
// its single RoonVis::PreprocessCache at startup (keys are salt-disambiguated), so the
// FIRST-ever load of any bundled preset skips BOTH the preprocess and the parse/generate
// stages of the transpile.
//
// Entries are deduplicated by key (identical shaders across presets collapse; v1 wrote
// duplicates that the seeder overwrote anyway) and emitted in sorted-key order per stage,
// so the output is byte-deterministic for a given pack.
//
// A coverage sidecar (JSON) is also written for later tier1EntryPresent consumption:
//   { "cacheFingerprint": "<hash of all serialized entries>",
//     "presets": { "<relPath>": { "warp": bool, "comp": bool }, ... } }
// warp/comp = a stage-2 entry exists for the shader the device would load (comp counts
// the shared default-composite entry when the preset uses/falls back to the default).
//
// Staleness is SAFE: if a seeded key no longer matches the runtime key (salt bump, preset
// edit, hlslparser change), the seed simply never gets hit -> runtime falls back to live
// transpile. So no invalidation is needed; the salt is stamped into the header only for
// sanity/logging.
//
// Usage: PreprocessCacheGen <presets-dir> <output-file> <coverage-json> <texture-dir> [<extra-search-dir>...]
//   (texture search dirs in the app's registration order: Resources/textures, Resources)

#include "MilkdropTranspilePrep.h"
#include "PreprocessCacheResource.h"

#include "MilkdropShaderPreprocess.hpp"
#include "PresetFileParser.hpp"

#include "Engine.h"
#include "HLSLParser.h"
#include "HLSLTree.h"

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <map>
#include <string>
#include <vector>

#if __has_include(<filesystem>)
#include <filesystem>
namespace fs = std::filesystem;
#endif

using libprojectM::MilkdropPreset::AssembleApplyPreprocessorInput;
using libprojectM::MilkdropPreset::ComputePreprocessCacheKey;
using libprojectM::MilkdropPreset::MilkdropShader;
using libprojectM::MilkdropPreset::PreprocessCacheSalt;
using libprojectM::MilkdropPreset::PresetFileParser;

using RoonVis::TranspilePrep::BuildTextureCatalog;
using RoonVis::TranspilePrep::GenerateGlslFromParseInput;
using RoonVis::TranspilePrep::PreparedParseInputs;
using RoonVis::TranspilePrep::PrepareParseInputsFromParser;
using RoonVis::TranspilePrep::TextureCatalog;

namespace {

// Run the M4 preprocessor once, with a fresh parser/tree/allocator, exactly like
// MilkdropShader::TranspileHLSLShader does before the cache-store hook fires.
bool RunPreprocessorOnce(const std::string& input, std::string& out)
{
    M4::Allocator allocator;
    M4::HLSLTree tree(&allocator);
    M4::HLSLParser parser(&allocator, &tree);
    out.clear();
    return parser.ApplyPreprocessor("", input.c_str(), input.size(), out);
}

// Compute the stage-1 {key, value} for one raw shader body and insert it (dedup by key).
// Returns true if a real entry was produced (non-empty body that assembled + preprocessed).
bool ProcessPreprocessBody(MilkdropShader::ShaderType type,
                           const std::string& body,
                           std::map<std::string, std::string>& entries)
{
    if (body.empty())
    {
        return false;  // empty shader -> projectM defaults, no custom transpile.
    }

    std::string assembled;
    try
    {
        assembled = AssembleApplyPreprocessorInput(type, body);
    }
    catch (...)
    {
        return false;  // malformed body -> runtime would throw too; nothing to cache.
    }

    std::string key = ComputePreprocessCacheKey(assembled);
    if (entries.find(key) != entries.end())
    {
        return true;  // identical shader already cached (dedup).
    }

    std::string value;
    bool ok = false;
    try
    {
        ok = RunPreprocessorOnce(assembled, value);
    }
    catch (...)
    {
        return false;
    }
    if (!ok)
    {
        return false;
    }

    entries.emplace(std::move(key), std::move(value));
    return true;
}

// Stage-2: run the real parse+generate over a composed parse input and insert the entry
// (dedup by key). Returns true if an entry exists for this key afterwards.
bool ProcessParseGenText(const std::string& text,
                         const std::string& key,
                         std::map<std::string, std::string>& entries,
                         int& parseGenFailures)
{
    if (entries.find(key) != entries.end())
    {
        return true;  // identical parse input already cached (dedup).
    }

    std::string glsl;
    bool ok = false;
    try
    {
        ok = GenerateGlslFromParseInput(text, glsl);
    }
    catch (...)
    {
        ok = false;
    }
    if (!ok)
    {
        // The device would throw ShaderException for this shader too — nothing to cache.
        ++parseGenFailures;
        return false;
    }

    entries.emplace(key, std::move(glsl));
    return true;
}

uint64_t Fnv1a64(const std::string& data, uint64_t offsetBasis)
{
    constexpr uint64_t prime = 1099511628211ull;
    uint64_t hash = offsetBasis;
    for (const char c : data)
    {
        hash ^= static_cast<uint64_t>(static_cast<unsigned char>(c));
        hash *= prime;
    }
    return hash;
}

// Minimal JSON string escaper (quotes, backslashes, control chars).
std::string JsonEscape(const std::string& s)
{
    std::string out;
    out.reserve(s.size() + 8);
    for (const char c : s)
    {
        const auto uc = static_cast<unsigned char>(c);
        if (c == '"' || c == '\\')
        {
            out.push_back('\\');
            out.push_back(c);
        }
        else if (uc < 0x20)
        {
            char buffer[8];
            std::snprintf(buffer, sizeof(buffer), "\\u%04x", uc);
            out.append(buffer);
        }
        else
        {
            out.push_back(c);
        }
    }
    return out;
}

struct CoverageFlags
{
    bool warp{false};
    bool comp{false};
};

bool WriteFile(const std::string& path, const std::string& contents)
{
    FILE* f = std::fopen(path.c_str(), "wb");
    if (!f)
    {
        std::fprintf(stderr, "Cannot open output file: %s\n", path.c_str());
        return false;
    }
    const size_t written = std::fwrite(contents.data(), 1, contents.size(), f);
    std::fclose(f);
    if (written != contents.size())
    {
        std::fprintf(stderr, "Short write to %s (%zu/%zu bytes)\n",
                     path.c_str(), written, contents.size());
        return false;
    }
    return true;
}

} // namespace

int main(int argc, char** argv)
{
    if (argc < 5)
    {
        std::fprintf(stderr,
                     "usage: %s <presets-dir> <output-file> <coverage-json> <texture-dir> [<extra-search-dir>...]\n",
                     argv[0]);
        return 2;
    }
    const std::string presetDir = argv[1];
    const std::string outputFile = argv[2];
    const std::string coverageFile = argv[3];
    std::vector<std::string> searchPaths;
    for (int i = 4; i < argc; ++i)
    {
        searchPaths.emplace_back(argv[i]);
    }

#if !defined(__cpp_lib_filesystem) && !__has_include(<filesystem>)
    std::fprintf(stderr, "std::filesystem unavailable\n");
    return 2;
#else
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
    // Recursive: the CotC pack ships as presets/<Top>/<Sub>/ trees.
    for (auto it = fs::recursive_directory_iterator(presetDir, ec); it != fs::recursive_directory_iterator(); it.increment(ec))
    {
        if (!ec && it->is_regular_file() && it->path().extension() == ".milk")
        {
            presetFiles.push_back(it->path().string());
        }
    }
    std::sort(presetFiles.begin(), presetFiles.end());

    std::map<std::string, std::string> preprocessEntries; // stage 1, dedup by key
    std::map<std::string, std::string> parseGenEntries;   // stage 2, dedup by key
    std::map<std::string, CoverageFlags> coverage;        // relPath -> stage-2 coverage

    RoonVis::TranspilePrep::Stats stats;
    const fs::path presetRoot(presetDir);
    int presetsWithEntries = 0;
    int presetReadFailures = 0;
    int parseGenFailures = 0;

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
            ++presetReadFailures;
            continue;
        }

        // --- Stage 1 (preprocess), unchanged semantics from the v1 generator. ---
        bool any = false;
        any |= ProcessPreprocessBody(MilkdropShader::ShaderType::WarpShader, parser.GetCode("warp_"), preprocessEntries);
        any |= ProcessPreprocessBody(MilkdropShader::ShaderType::CompositeShader, parser.GetCode("comp_"), preprocessEntries);

        // --- Stage 2 (Tier-1 parse/generate), via the fidelity-proven core. ---
        const PreparedParseInputs prepared = PrepareParseInputsFromParser(parser, catalog, stats);
        CoverageFlags flags;
        if (prepared.warp.present)
        {
            flags.warp = ProcessParseGenText(prepared.warp.text, prepared.warp.parseGenKey,
                                             parseGenEntries, parseGenFailures);
            any |= flags.warp;
            if (!flags.warp)
            {
                std::fprintf(stderr, "NOTE stage-2 warp parse/generate failed: %s\n", relPath.c_str());
            }
        }
        if (prepared.comp.present)
        {
            flags.comp = ProcessParseGenText(prepared.comp.text, prepared.comp.parseGenKey,
                                             parseGenEntries, parseGenFailures);
            any |= flags.comp;
            if (!flags.comp)
            {
                std::fprintf(stderr, "NOTE stage-2 comp parse/generate failed: %s\n", relPath.c_str());
            }
        }
        coverage.emplace(relPath, flags);

        if (any)
        {
            ++presetsWithEntries;
        }
    }

    // --- Serialize RVPP v2 (deterministic: sorted-key order, stage 1 then stage 2). ---
    const size_t totalEntries = preprocessEntries.size() + parseGenEntries.size();
    std::string out;
    RoonVis::RvppAppendHeader(out, RoonVis::kRvppVersion2, PreprocessCacheSalt(),
                              static_cast<uint32_t>(totalEntries));
    const size_t entriesStart = out.size();
    size_t preprocessBytes = 0;
    size_t parseGenBytes = 0;
    for (const auto& kv : preprocessEntries)
    {
        RoonVis::RvppAppendEntryV2(out, RoonVis::kRvppStagePreprocess, kv.first, kv.second);
        preprocessBytes += kv.second.size();
    }
    for (const auto& kv : parseGenEntries)
    {
        RoonVis::RvppAppendEntryV2(out, RoonVis::kRvppStageParseGen, kv.first, kv.second);
        parseGenBytes += kv.second.size();
    }

    // Fingerprint of the serialized entries region (dual FNV-1a, same pattern as the cache
    // keys) — identifies this exact cache build in the coverage sidecar.
    const std::string entriesRegion = out.substr(entriesStart);
    char fingerprint[48];
    std::snprintf(fingerprint, sizeof(fingerprint), "%016llx%016llx-%zx",
                  static_cast<unsigned long long>(Fnv1a64(entriesRegion, 14695981039346656037ull)),
                  static_cast<unsigned long long>(Fnv1a64(entriesRegion, 0x84222325cbf29ce4ull)),
                  entriesRegion.size());

    if (!WriteFile(outputFile, out))
    {
        return 2;
    }

    // --- Coverage sidecar (JSON; std::map iteration keeps it deterministic). ---
    std::string json;
    json.reserve(coverage.size() * 64 + 128);
    json.append("{\n  \"cacheFingerprint\": \"");
    json.append(fingerprint);
    json.append("\",\n  \"presets\": {");
    bool first = true;
    for (const auto& kv : coverage)
    {
        json.append(first ? "\n" : ",\n");
        first = false;
        json.append("    \"");
        json.append(JsonEscape(kv.first));
        json.append("\": {\"warp\": ");
        json.append(kv.second.warp ? "true" : "false");
        json.append(", \"comp\": ");
        json.append(kv.second.comp ? "true" : "false");
        json.append("}");
    }
    json.append("\n  }\n}\n");

    if (!WriteFile(coverageFile, json))
    {
        return 2;
    }

    std::printf("PreprocessCacheGen: %d presets (%d unreadable), %d with entries -> %s (%zu bytes)\n"
                "  stage 1 (preprocess): %zu entries, %zu value bytes\n"
                "  stage 2 (parse-gen):  %zu entries, %zu value bytes (%d parse/gen failures)\n"
                "  coverage sidecar: %s (%zu presets, fingerprint %s)\n",
                stats.presetsScanned, presetReadFailures, presetsWithEntries,
                outputFile.c_str(), out.size(),
                preprocessEntries.size(), preprocessBytes,
                parseGenEntries.size(), parseGenBytes, parseGenFailures,
                coverageFile.c_str(), coverage.size(), fingerprint);
    return 0;
#endif
}
