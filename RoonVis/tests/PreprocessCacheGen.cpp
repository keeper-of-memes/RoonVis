// PreprocessCacheGen.cpp
//
// HOST-SIDE build-time generator for the prepopulated preprocessed-HLSL cache.
//
// Walks a preset directory and, for every non-empty warp/comp shader body, computes the
// SAME cache key the runtime computes (AssembleApplyPreprocessorInput ->
// ComputePreprocessCacheKey) and the SAME value the runtime would store
// (M4::HLSLParser::ApplyPreprocessor over the assembled input). It writes {key, value}
// pairs to a little-endian binary resource that the app seeds into its RoonVis::PreprocessCache
// at startup, so the FIRST-ever load of any bundled preset is a cache hit (no transpile
// stutter).
//
// Staleness is SAFE: if a seeded key no longer matches the runtime key (salt bump, preset
// edit, hlslparser change), the seed simply never gets hit -> runtime falls back to live
// transpile. So no invalidation is needed; the salt is stamped into the header only for
// sanity/logging.
//
// Usage: PreprocessCacheGen <presets-dir> <output-file>
//
// Resource format (little-endian):
//   magic "RVPP" (4 bytes)
//   u32 version (=1)
//   u32 saltLen + salt bytes            (== PreprocessCacheSalt())
//   u32 entryCount
//   per entry: u32 keyLen + key bytes + u32 valLen + value bytes

#include "MilkdropShaderPreprocess.hpp"
#include "PresetFileParser.hpp"

#include "HLSLParser.h"
#include "Engine.h"
#include "HLSLTree.h"

#include <algorithm>
#include <cstdint>
#include <cstdio>
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

namespace {

constexpr uint32_t kResourceVersion = 1;

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

void PutU32LE(std::string& buf, uint32_t v)
{
    buf.push_back(static_cast<char>(v & 0xFF));
    buf.push_back(static_cast<char>((v >> 8) & 0xFF));
    buf.push_back(static_cast<char>((v >> 16) & 0xFF));
    buf.push_back(static_cast<char>((v >> 24) & 0xFF));
}

void PutLenPrefixed(std::string& buf, const std::string& s)
{
    PutU32LE(buf, static_cast<uint32_t>(s.size()));
    buf.append(s);
}

// Compute the {key, value} for one shader body and append it to `entries` on success.
// Returns true if a real entry was produced (non-empty body that assembled + preprocessed).
bool ProcessBody(MilkdropShader::ShaderType type,
                 const std::string& body,
                 std::vector<std::pair<std::string, std::string>>& entries)
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

    entries.emplace_back(ComputePreprocessCacheKey(assembled), std::move(value));
    return true;
}

} // namespace

int main(int argc, char** argv)
{
    if (argc < 3)
    {
        std::fprintf(stderr, "usage: %s <presets-dir> <output-file>\n", argv[0]);
        return 2;
    }
    const std::string presetDir = argv[1];
    const std::string outputFile = argv[2];

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

    std::vector<std::string> presetFiles;
    for (const auto& entry : fs::directory_iterator(presetDir, ec))
    {
        if (entry.is_regular_file() && entry.path().extension() == ".milk")
        {
            presetFiles.push_back(entry.path().string());
        }
    }
    std::sort(presetFiles.begin(), presetFiles.end());

    std::vector<std::pair<std::string, std::string>> entries;
    entries.reserve(presetFiles.size() * 2);

    int presetsWithEntries = 0;
    for (const auto& path : presetFiles)
    {
        PresetFileParser parser;
        if (!parser.Read(path))
        {
            continue;
        }
        bool any = false;
        any |= ProcessBody(MilkdropShader::ShaderType::WarpShader, parser.GetCode("warp_"), entries);
        any |= ProcessBody(MilkdropShader::ShaderType::CompositeShader, parser.GetCode("comp_"), entries);
        if (any)
        {
            ++presetsWithEntries;
        }
    }

    // Serialize (little-endian).
    std::string out;
    out.append("RVPP", 4);
    PutU32LE(out, kResourceVersion);
    PutLenPrefixed(out, PreprocessCacheSalt());
    PutU32LE(out, static_cast<uint32_t>(entries.size()));
    for (const auto& kv : entries)
    {
        PutLenPrefixed(out, kv.first);
        PutLenPrefixed(out, kv.second);
    }

    FILE* f = std::fopen(outputFile.c_str(), "wb");
    if (!f)
    {
        std::fprintf(stderr, "Cannot open output file: %s\n", outputFile.c_str());
        return 2;
    }
    const size_t written = std::fwrite(out.data(), 1, out.size(), f);
    std::fclose(f);
    if (written != out.size())
    {
        std::fprintf(stderr, "Short write to %s (%zu/%zu bytes)\n",
                     outputFile.c_str(), written, out.size());
        return 2;
    }

    std::printf("PreprocessCacheGen: %d presets, %zu entries -> %s (%zu bytes)\n",
                presetsWithEntries, entries.size(), outputFile.c_str(), out.size());
    return 0;
#endif
}
