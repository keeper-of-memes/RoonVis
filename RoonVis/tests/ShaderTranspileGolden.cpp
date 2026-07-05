// ShaderTranspileGolden.cpp
//
// HOST-SIDE golden determinism test for projectM's GL-free HLSL preprocess pipeline.
//
// Proves that the shared, GL-free text assembly (AssembleApplyPreprocessorInput) plus the
// M4 HLSL preprocessor (HLSLParser::ApplyPreprocessor) can run entirely host-side (no GL/EGL
// context, no textures, no PresetState) over the REAL preset pack, and that running the
// preprocessor twice on the same input is byte-identical. Byte-identical output is the hard
// gate: it is what makes a build-time precompute cache safe to reuse at runtime.
//
// Pipeline per preset:
//   PresetFileParser::Read(.milk)
//     -> GetCode("warp_") / GetCode("comp_")                  (raw shader bodies)
//     -> AssembleApplyPreprocessorInput(type, body)           (GL-free text assembly)
//     -> HLSLParser::ApplyPreprocessor(input) x2, fresh state (determinism assertion)
//
// Exit nonzero if any shader is nondeterministic or if assembly/preprocess throws
// unexpectedly (malformed presets that legitimately throw in PresetFileParser/assembly are
// counted and skipped, not failed).

#include "MilkdropShaderPreprocess.hpp"
#include "PresetFileParser.hpp"

#include "HLSLParser.h"
#include "Engine.h"
#include "HLSLTree.h"

#include <algorithm>
#include <cstdio>
#include <string>
#include <vector>

#if __has_include(<filesystem>)
#include <filesystem>
namespace fs = std::filesystem;
#endif

using libprojectM::MilkdropPreset::AssembleApplyPreprocessorInput;
using libprojectM::MilkdropPreset::MilkdropShader;
using libprojectM::MilkdropPreset::PresetFileParser;

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

} // namespace

int main(int argc, char** argv)
{
    const std::string presetDir = (argc > 1) ? argv[1] : "RoonVis/Resources/presets";
    const size_t maxPresets = 30;

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
    for (const auto& entry : fs::directory_iterator(presetDir, ec))
    {
        if (entry.is_regular_file() && entry.path().extension() == ".milk")
        {
            presetFiles.push_back(entry.path().string());
        }
    }
    // Deterministic sampling: sort by name, take up to maxPresets.
    std::sort(presetFiles.begin(), presetFiles.end());
    if (presetFiles.size() > maxPresets)
    {
        presetFiles.resize(maxPresets);
    }

    Counters c;
    for (const auto& path : presetFiles)
    {
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

    return (c.nondeterministic == 0 && c.preprocessFail == 0) ? 0 : 1;
#endif
}
