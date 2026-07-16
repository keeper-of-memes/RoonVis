// ShaderTranspileGolden.cpp
//
// HOST-SIDE golden determinism test for projectM's GL-free HLSL transpile pipeline.
//
// Section 1 (stage 1, unchanged): proves that the shared, GL-free text assembly
// (AssembleApplyPreprocessorInput) plus the M4 HLSL preprocessor
// (HLSLParser::ApplyPreprocessor) can run entirely host-side (no GL/EGL context, no
// textures, no PresetState) over the REAL preset pack, and that running the preprocessor
// twice on the same input is byte-identical. Byte-identical output is the hard gate: it is
// what makes a build-time precompute cache safe to reuse at runtime.
//
// Section 2 (stage 2, W5 Tier-1 parse/generate cache): over a sample of presets WITH
// custom shaders, proves
//   (a) parse/generate determinism — running the real HLSL parse + GLSL generation twice
//       over the same composed parse input yields byte-identical GLSL, and
//   (b) key fidelity — MilkdropTranspilePrep's post-insertion text is exactly
//       [declaration blocks] + [stripped preprocessed source], where the stripped
//       preprocessed source is recomputed INDEPENDENTLY here from the vendor-linkable
//       pieces (AssembleApplyPreprocessorInput + ApplyPreprocessor + the verbatim strip
//       regexes from MilkdropShader::TranspileHLSLShader), and the reported key is
//       ComputeParseGenCacheKey(text) with the second-stage salt (distinct from the
//       stage-1 salt). The declaration-block bytes themselves are covered by the
//       full-pack ParseInputHashGen TSV equivalence re-proof (W4 spike: 100% device
//       match), which exercises the same core.
//
// Exit nonzero if any shader is nondeterministic, any tier-1 fidelity check fails, or if
// assembly/preprocess throws unexpectedly (malformed presets that legitimately throw are
// counted and skipped, not failed).
//
// Usage: ShaderTranspileGolden [<presets-dir>] [<textures-dir> [<extra-search-dir>...]]

#include "MilkdropTranspilePrep.h"

#include "MilkdropShaderPreprocess.hpp"
#include "PresetFileParser.hpp"

#include "Engine.h"
#include "HLSLParser.h"
#include "HLSLTree.h"

#include <algorithm>
#include <cstdio>
#include <regex>
#include <string>
#include <vector>

#if __has_include(<filesystem>)
#include <filesystem>
namespace fs = std::filesystem;
#endif

using libprojectM::MilkdropPreset::AssembleApplyPreprocessorInput;
using libprojectM::MilkdropPreset::ComputeParseGenCacheKey;
using libprojectM::MilkdropPreset::ComputePreprocessCacheKey;
using libprojectM::MilkdropPreset::MilkdropShader;
using libprojectM::MilkdropPreset::ParseGenCacheSalt;
using libprojectM::MilkdropPreset::PreprocessCacheSalt;
using libprojectM::MilkdropPreset::PresetFileParser;

using RoonVis::TranspilePrep::BuildTextureCatalog;
using RoonVis::TranspilePrep::GenerateGlslFromParseInput;
using RoonVis::TranspilePrep::PreparedParseInputs;
using RoonVis::TranspilePrep::PreparedShaderInput;
using RoonVis::TranspilePrep::PrepareParseInputsFromParser;
using RoonVis::TranspilePrep::TextureCatalog;

namespace {

// Run the M4 preprocessor once, with a fresh parser/tree/allocator, exactly like
// MilkdropShader::TranspileHLSLShader does. Returns true on success and fills `out`.
bool RunPreprocessorOnce(const std::string& input, std::string& out)
{
    M4::Allocator allocator;
    M4::HLSLTree tree(&allocator);
    M4::HLSLParser parser(&allocator, &tree);
    out.clear();
    return parser.ApplyPreprocessor("", input.c_str(), input.size(), out);
}

struct Counters
{
    int presets = 0;
    int shaders = 0;         // non-empty shader bodies successfully assembled + preprocessed
    int nondeterministic = 0;
    int skippedPresets = 0;  // presets that failed to parse / had no shaders
    int assemblyThrows = 0;  // bodies where assembly threw (malformed) -> skipped
    int preprocessFail = 0;  // ApplyPreprocessor returned false
};

// Process a single shader body of a given type. Returns true if it contributed a shader.
void ProcessBody(MilkdropShader::ShaderType type,
                 const std::string& body,
                 const std::string& presetName,
                 const char* label,
                 Counters& c)
{
    if (body.empty())
    {
        return;
    }

    std::string assembled;
    try
    {
        assembled = AssembleApplyPreprocessorInput(type, body);
    }
    catch (const std::exception& e)
    {
        // Malformed shader body (missing shader_body / braces / empty). Count + skip.
        c.assemblyThrows++;
        std::printf("  [skip] %s %s: assembly threw: %s\n", presetName.c_str(), label, e.what());
        return;
    }
    catch (...)
    {
        c.assemblyThrows++;
        std::printf("  [skip] %s %s: assembly threw (unknown)\n", presetName.c_str(), label);
        return;
    }

    std::string a;
    std::string b;
    bool okA = false;
    bool okB = false;
    try
    {
        okA = RunPreprocessorOnce(assembled, a);
        okB = RunPreprocessorOnce(assembled, b);
    }
    catch (const std::exception& e)
    {
        c.preprocessFail++;
        std::printf("  [warn] %s %s: preprocess threw: %s\n", presetName.c_str(), label, e.what());
        return;
    }

    if (!okA || !okB)
    {
        c.preprocessFail++;
        std::printf("  [warn] %s %s: ApplyPreprocessor returned false\n", presetName.c_str(), label);
        return;
    }

    c.shaders++;
    if (a != b)
    {
        c.nondeterministic++;
        std::printf("  [FAIL] %s %s: NONDETERMINISTIC preprocessor output (%zu vs %zu bytes)\n",
                    presetName.c_str(), label, a.size(), b.size());
    }
}

// ---------------------------------------------------------------------------------------
// Section 2: Tier-1 parse/generate checks.
// ---------------------------------------------------------------------------------------
struct Tier1Counters
{
    int presets = 0;             // sampled presets with at least one custom shader
    int shaders = 0;             // prepared shaders checked
    int generated = 0;           // shaders whose parse+generate succeeded
    int parseGenFail = 0;        // shaders the device would also fail to transpile (throw)
    int nondeterministic = 0;    // FAIL: generate x2 differed
    int textMismatches = 0;      // FAIL: core text != declarations + independent strip
    int keyMismatches = 0;       // FAIL: reported key wrong / salts not disambiguated
};

// Independently recompute the stripped preprocessed source from the vendor-linkable
// pieces: AssembleApplyPreprocessorInput + ApplyPreprocessor + the strip regexes copied
// VERBATIM from MilkdropShader::TranspileHLSLShader (the one non-linkable fragment).
bool IndependentStrippedPreprocessed(MilkdropShader::ShaderType type,
                                     const std::string& rawBody,
                                     std::string& out)
{
    std::string assembled;
    try
    {
        assembled = AssembleApplyPreprocessorInput(type, rawBody);
    }
    catch (...)
    {
        return false;
    }
    if (!RunPreprocessorOnce(assembled, out))
    {
        return false;
    }

    std::smatch matches;
    while (std::regex_search(out, matches, std::regex("sampler(2D|3D|)(\\s+|\\().*")))
    {
        out.replace(matches.position(), matches.length(), "");
    }
    while (std::regex_search(out, matches, std::regex("float4\\s+texsize_.*")))
    {
        out.replace(matches.position(), matches.length(), "");
    }
    return true;
}

void CheckPreparedShader(const PreparedShaderInput& prepared,
                         MilkdropShader::ShaderType type,
                         const std::string& rawBody,
                         const std::string& presetName,
                         const char* label,
                         Tier1Counters& c)
{
    if (!prepared.present)
    {
        return;
    }
    c.shaders++;

    // (b) Text fidelity: the composed text must be [declarations] + [stripped source],
    // with the stripped source recomputed independently from vendor-linkable pieces.
    std::string independentStripped;
    if (!IndependentStrippedPreprocessed(type, rawBody, independentStripped))
    {
        // The core produced a text for a body the independent path cannot preprocess —
        // impossible by construction (same assembly + preprocessor). Flag it.
        c.textMismatches++;
        std::printf("  [FAIL] %s %s: independent preprocess failed but core composed text\n",
                    presetName.c_str(), label);
        return;
    }
    const std::string& text = prepared.text;
    const bool suffixMatches =
        text.size() >= independentStripped.size() &&
        std::equal(independentStripped.begin(), independentStripped.end(),
                   text.end() - static_cast<std::ptrdiff_t>(independentStripped.size()));
    if (!suffixMatches)
    {
        c.textMismatches++;
        std::printf("  [FAIL] %s %s: composed text does not end with the independently stripped source\n",
                    presetName.c_str(), label);
    }
    else
    {
        // The declaration prefix must consist only of "uniform ..." lines.
        const std::string prefix = text.substr(0, text.size() - independentStripped.size());
        size_t pos = 0;
        bool prefixOk = true;
        while (pos < prefix.size())
        {
            if (prefix.compare(pos, 8, "uniform ") != 0)
            {
                prefixOk = false;
                break;
            }
            const size_t eol = prefix.find('\n', pos);
            if (eol == std::string::npos)
            {
                prefixOk = false;
                break;
            }
            pos = eol + 1;
        }
        if (!prefixOk)
        {
            c.textMismatches++;
            std::printf("  [FAIL] %s %s: declaration prefix contains non-uniform lines\n",
                        presetName.c_str(), label);
        }
    }

    // (b) Key fidelity: reported key == ComputeParseGenCacheKey(text), carries the
    // second-stage salt, and differs from the stage-1 key over the same text.
    const std::string recomputedKey = ComputeParseGenCacheKey(text);
    const std::string stage1Key = ComputePreprocessCacheKey(text);
    const std::string parseSalt = ParseGenCacheSalt();
    if (prepared.parseGenKey != recomputedKey ||
        prepared.parseGenKey.compare(0, parseSalt.size(), parseSalt) != 0 ||
        prepared.parseGenKey == stage1Key ||
        parseSalt == PreprocessCacheSalt())
    {
        c.keyMismatches++;
        std::printf("  [FAIL] %s %s: parse-gen key mismatch or salt not disambiguated\n",
                    presetName.c_str(), label);
    }

    // (a) Parse/generate determinism: run the REAL parse + GLSL generation twice.
    std::string glslA;
    std::string glslB;
    const bool okA = GenerateGlslFromParseInput(text, glslA);
    const bool okB = GenerateGlslFromParseInput(text, glslB);
    if (okA != okB)
    {
        c.nondeterministic++;
        std::printf("  [FAIL] %s %s: NONDETERMINISTIC parse/generate success (%d vs %d)\n",
                    presetName.c_str(), label, okA ? 1 : 0, okB ? 1 : 0);
        return;
    }
    if (!okA)
    {
        // The device would throw ShaderException for this shader (parse/generate failure)
        // and fall back — legitimately uncacheable, not a fidelity failure.
        c.parseGenFail++;
        std::printf("  [note] %s %s: parse/generate failed (device would throw too)\n",
                    presetName.c_str(), label);
        return;
    }
    c.generated++;
    if (glslA != glslB || glslA.empty())
    {
        c.nondeterministic++;
        std::printf("  [FAIL] %s %s: NONDETERMINISTIC GLSL generation (%zu vs %zu bytes)\n",
                    presetName.c_str(), label, glslA.size(), glslB.size());
    }
}

} // namespace

int main(int argc, char** argv)
{
    const std::string presetDir = (argc > 1) ? argv[1] : "RoonVis/Resources/presets";
    std::vector<std::string> textureSearchPaths;
    if (argc > 2)
    {
        for (int i = 2; i < argc; ++i)
        {
            textureSearchPaths.emplace_back(argv[i]);
        }
    }
    else
    {
        // App registration order (ProjectMBridge.mm): [Resources/textures, Resources].
        textureSearchPaths = {"RoonVis/Resources/textures", "RoonVis/Resources"};
    }
    const size_t maxPresets = 30;       // section 1 sample (unchanged)
    const size_t maxTier1Presets = 40;  // section 2 sample (>=30 custom-shader presets)

#if !defined(__cpp_lib_filesystem) && !__has_include(<filesystem>)
    std::fprintf(stderr, "std::filesystem unavailable\n");
    return 2;
#else
    std::vector<std::string> presetFiles;
    std::error_code ec;
    if (!fs::is_directory(presetDir, ec))
    {
        std::fprintf(stderr, "Preset directory not found: %s\n", presetDir.c_str());
        return 2;
    }
    // Recursive: the CotC pack ships as presets/<Top>/<Sub>/ trees.
    for (auto it = fs::recursive_directory_iterator(presetDir, ec); it != fs::recursive_directory_iterator(); it.increment(ec))
    {
        if (!ec && it->is_regular_file() && it->path().extension() == ".milk")
        {
            presetFiles.push_back(it->path().string());
        }
    }
    // Deterministic sampling: sort by path.
    std::sort(presetFiles.begin(), presetFiles.end());

    // ------------------------------ Section 1 (stage 1) ------------------------------
    Counters c;
    size_t sampled = 0;
    for (const auto& path : presetFiles)
    {
        if (sampled >= maxPresets)
        {
            break;
        }
        sampled++;
        const std::string name = fs::path(path).filename().string();

        PresetFileParser parser;
        if (!parser.Read(path))
        {
            c.skippedPresets++;
            std::printf("  [skip] %s: PresetFileParser::Read failed\n", name.c_str());
            continue;
        }

        const std::string warpBody = parser.GetCode("warp_");
        const std::string compBody = parser.GetCode("comp_");

        if (warpBody.empty() && compBody.empty())
        {
            c.skippedPresets++;
            continue;
        }

        c.presets++;
        ProcessBody(MilkdropShader::ShaderType::WarpShader, warpBody, name, "warp", c);
        ProcessBody(MilkdropShader::ShaderType::CompositeShader, compBody, name, "comp", c);
    }

    std::printf("ShaderTranspileGolden: %d presets, %d shaders, %d nondeterministic"
                " (skipped %d presets, %d assembly-throw, %d preprocess-fail)\n",
                c.presets, c.shaders, c.nondeterministic,
                c.skippedPresets, c.assemblyThrows, c.preprocessFail);

    // ------------------------------ Section 2 (Tier-1) -------------------------------
    const TextureCatalog catalog = BuildTextureCatalog(textureSearchPaths);
    std::printf("Tier-1: texture catalog %zu files across %zu search paths\n",
                catalog.baseNames.size(), textureSearchPaths.size());

    Tier1Counters t;
    RoonVis::TranspilePrep::Stats stats;
    for (const auto& path : presetFiles)
    {
        if (static_cast<size_t>(t.presets) >= maxTier1Presets)
        {
            break;
        }
        const std::string name = fs::path(path).filename().string();

        PresetFileParser parser;
        if (!parser.Read(path))
        {
            continue;
        }
        const std::string warpBody = parser.GetCode("warp_");
        const std::string compBody = parser.GetCode("comp_");
        if (warpBody.empty() && compBody.empty())
        {
            continue; // sample only presets with CUSTOM shaders
        }

        const PreparedParseInputs prepared = PrepareParseInputsFromParser(parser, catalog, stats);
        if (!prepared.warp.present && !prepared.comp.present)
        {
            continue; // gated by version / dropped — nothing the device would parse
        }
        t.presets++;

        CheckPreparedShader(prepared.warp, MilkdropShader::ShaderType::WarpShader,
                            warpBody, name, "warp", t);
        // The comp text may come from the preset body OR the default composite shader
        // (empty body / fallback) — pick the body the core actually composed from.
        const std::string compSourceBody =
            (prepared.compUsedDefaultBody || prepared.compFallback)
                ? RoonVis::TranspilePrep::kDefaultCompositeShaderBody
                : compBody;
        CheckPreparedShader(prepared.comp, MilkdropShader::ShaderType::CompositeShader,
                            compSourceBody, name, "comp", t);
    }

    const bool tier1SampleOk = t.presets >= 30 && t.generated >= 30;
    std::printf("Tier-1: %d presets, %d shaders, %d generated, %d parse-gen-fail, "
                "%d nondeterministic, %d text-mismatch, %d key-mismatch%s\n",
                t.presets, t.shaders, t.generated, t.parseGenFail,
                t.nondeterministic, t.textMismatches, t.keyMismatches,
                tier1SampleOk ? "" : " [FAIL: sample too small]");

    const bool ok = (c.nondeterministic == 0 && c.preprocessFail == 0 &&
                     t.nondeterministic == 0 && t.textMismatches == 0 &&
                     t.keyMismatches == 0 && tier1SampleOk);
    return ok ? 0 : 1;
#endif
}
