// MilkdropTranspilePrep.h
//
// HOST-SIDE (GL-free) reusable core that reproduces the exact parse-stage input text
// projectM composes on-device for a preset's warp/composite shaders — the productionized
// form of the W4 tier1-fidelity spike replica (ParseInputHashGen), which matched the live
// app 100.000% across the full 7,732-preset pack (11,896 shader records, 0 mismatches).
//
// Given (.milk parse products + a texture-scan catalog), it produces per shader the
// byte-exact string that MilkdropShader::TranspileHLSLShader hands to parser.Parse(...)
// (the POST-insertion parse input: [sampler decls][texsize decls][stripped preprocessed
// source]) plus its second-stage cache key (ComputeParseGenCacheKey), and can run the real
// HLSL parse + GLSL generation host-side with the exact device configuration.
//
// Consumers:
//   - tests/ParseInputHashGen.cpp   (the proven reference; now a thin wrapper over this core)
//   - tests/PreprocessCacheGen.cpp  (RVPP v2 stage-2 entry generation)
//   - tests/ShaderTranspileGolden.cpp (determinism + key-fidelity assertions)
//
// The vendor file:line citations for every replicated stage live in the .cpp; keep them in
// lockstep with vendor/projectm (any vendor change to the transpile path invalidates this
// replica AND the parse-gen cache salt — see kParseGenCacheSalt in
// MilkdropShaderPreprocess.cpp).
//
// Pure C++17, no GL. NOT compiled into the tvOS app (host tools/tests only): it needs
// hlslparser and the projectm-build generated MilkdropStaticShaders.

#pragma once

#include "MilkdropShader.hpp"
#include "PresetFileParser.hpp"

#include <map>
#include <string>
#include <vector>

namespace RoonVis {
namespace TranspilePrep {

// Byte-exact copy of the default composite shader body (FinalComposite.cpp:13), used when
// a preset declares a composite shader version but has an empty (or failing) comp body.
extern const std::string kDefaultCompositeShaderBody;

// ---------------------------------------------------------------------------------------
// Texture catalog: the lower-cased basenames (stem minus extension) of every texture file
// found under the search paths, with projectM's extension rules and scan order
// (TextureManager::ScanTextures + FileScanner::Scan). Search paths must be given in the
// app's registration order (ProjectMBridge.mm: [Resources/textures, Resources]).
// ---------------------------------------------------------------------------------------
struct TextureCatalog
{
    std::vector<std::string> baseNames;
};

TextureCatalog BuildTextureCatalog(const std::vector<std::string>& searchPaths);

// ---------------------------------------------------------------------------------------
// Host-side stand-in for Renderer::TextureSamplerDescriptor: only what declaration text
// generation needs. `null` models "m_texture == nullptr" (the empty descriptor {}), which
// makes both declarations empty.
// ---------------------------------------------------------------------------------------
struct HostDescriptor
{
    bool null{true};
    bool is3D{false};
    std::string samplerName;
    std::string sizeName;
};

// Cumulative counters across PrepareParseInputs/ComposeParseInput calls (tool summaries).
struct Stats
{
    int presetsScanned{0};
    int presetReadFailures{0};
    int warpEmitted{0};
    int compEmitted{0};
    int warpGatedVersion{0};    // warp shader version <= 0
    int warpGatedEmpty{0};      // version > 0 but empty warp body (PerPixelMesh.cpp:133)
    int compGatedVersion{0};    // composite shader version <= 0
    int compDefaultBody{0};     // version > 0, empty comp body -> default shader
    int compFallbacks{0};       // preset comp body failed assemble/preprocess -> default
    int warpDropped{0};         // warp body failed assemble/preprocess -> shader dropped
    int randEmptyDescriptors{0};// GetRandomTexture returned the empty descriptor
};

// ---------------------------------------------------------------------------------------
// Compose the byte-exact parser.Parse() input for ONE shader body.
// Mirrors LoadCode + LoadTexturesAndCompile + TranspileHLSLShader up to parser.Parse.
// `randomTextureDescriptors` is the per-preset rand-slot cache (PresetState.hpp), shared
// warp -> comp: pass the SAME map for both shaders of one preset, warp first.
// Returns false if the device would never reach parser.Parse for this body (assembly or
// preprocess failure).
// ---------------------------------------------------------------------------------------
bool ComposeParseInput(libprojectM::MilkdropPreset::MilkdropShader::ShaderType type,
                       const std::string& rawBody,
                       std::map<int, HostDescriptor>& randomTextureDescriptors,
                       const TextureCatalog& catalog,
                       Stats& stats,
                       std::string& outComposed);

// One prepared shader: the exact post-insertion parse-input text and its second-stage
// (parse/generate) cache key.
struct PreparedShaderInput
{
    bool present{false};
    std::string text;        // exact bytes handed to HLSLParser::Parse on-device
    std::string parseGenKey; // ComputeParseGenCacheKey(text)
};

// Per-preset result: which shaders the device would transpile, their texts/keys, and how
// each outcome was reached (for tool logging / coverage metadata).
struct PreparedParseInputs
{
    PreparedShaderInput warp;
    PreparedShaderInput comp;

    bool warpGatedVersion{false};  // warp shader version <= 0 -> no warp transpile
    bool warpGatedEmpty{false};    // version > 0 but empty warp body -> no warp transpile
    bool warpDropped{false};       // warp body failed assemble/preprocess -> shader dropped
    bool compGatedVersion{false};  // composite shader version <= 0 -> no comp transpile
    bool compUsedDefaultBody{false}; // empty comp body -> default composite shader
    bool compFallback{false};      // preset comp body failed -> fell back to the default
    bool compDefaultFailed{false}; // unexpected: even the default composite failed
};

// Prepare both shaders of one preset from an already-Read PresetFileParser (shader gating,
// warp-then-comp ordering, shared rand-slot cache, comp default/fallback semantics).
PreparedParseInputs PrepareParseInputsFromParser(libprojectM::MilkdropPreset::PresetFileParser& parser,
                                                 const TextureCatalog& catalog,
                                                 Stats& stats);

// Convenience wrapper over the full bytes of a .milk file. `readOk` (optional) reports
// whether PresetFileParser accepted the buffer; on a read failure the result is empty.
PreparedParseInputs PrepareParseInputs(const std::string& presetFileBuffer,
                                       const TextureCatalog& catalog,
                                       Stats& stats,
                                       bool* readOk = nullptr);

// ---------------------------------------------------------------------------------------
// Runs the real HLSL parse + GLSL generation over a composed parse input, exactly as the
// device does (fresh allocator/tree/parser/generator per call; Target_FragmentShader,
// entry point "PS", Flag_AlternateNanPropagation, and GLSL version 300 es — the value
// MilkdropStaticShaders::Get()->GetGlslGeneratorVersion() returns in the tvOS app, where
// USE_GLES is defined). Returns false if parse or generate fails (the device would throw).
// ---------------------------------------------------------------------------------------
bool GenerateGlslFromParseInput(const std::string& parseInputText, std::string& glslOut);

} // namespace TranspilePrep
} // namespace RoonVis
