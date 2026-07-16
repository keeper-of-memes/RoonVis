// MilkdropTranspilePrep.cpp
//
// See the header for scope. This is the productionized extraction of the W4 fidelity-spike
// replica (tests/ParseInputHashGen.cpp) — the logic below was moved here VERBATIM from that
// tool (which is now a thin wrapper) after the spike proved it matches the live app
// byte-for-byte across the full preset pack. Where vendor logic could not be #included
// GL-free, it is COPIED with a comment citing the vendor file:line it mirrors; keep those
// copies in lockstep with vendor/projectm.
//
// The device pipeline replicated here, stage by stage:
//   1. Shader gating          PresetState.cpp:117-134, PerPixelMesh.cpp:128-149,
//                             FinalComposite.cpp:35-61
//   2. Preprocess             AssembleApplyPreprocessorInput + M4 ApplyPreprocessor
//                             (identical to the runtime cache-miss path)
//   3. Regex declaration strips   MilkdropShader.cpp TranspileHLSLShader (copied verbatim)
//   4. Sampler scan           MilkdropShader::GetReferencedSamplers + UpdateMaxBlurLevel
//                             (copied verbatim)
//   5. Descriptor synthesis   MilkdropShader::LoadTexturesAndCompile,
//                             TextureManager::{GetTexture,TryLoadingTexture,
//                             GetRandomTexture,ExtractTextureSettings,ScanTextures},
//                             BlurTexture::GetDescriptorsForBlurLevel,
//                             TextureSamplerDescriptor::{SamplerDeclaration,
//                             TexSizeDeclaration}
//   6. Composition            [samplers][texsizes] each front-inserted from an ascending
//                             std::set => descending blocks on top of the stripped source.

#include "MilkdropTranspilePrep.h"

#include "MilkdropShaderPreprocess.hpp"
#include "Utils.hpp"

#include <MilkdropStaticShaders.hpp>

#include "Engine.h"
#include "GLSLGenerator.h"
#include "HLSLParser.h"
#include "HLSLTree.h"

#include <algorithm>
#include <locale>
#include <regex>
#include <set>
#include <sstream>

#if __has_include(<filesystem>)
#include <filesystem>
namespace fs = std::filesystem;
#else
#error "MilkdropTranspilePrep requires std::filesystem"
#endif

using libprojectM::MilkdropPreset::AssembleApplyPreprocessorInput;
using libprojectM::MilkdropPreset::ComputeParseGenCacheKey;
using libprojectM::MilkdropPreset::MilkdropShader;
using libprojectM::MilkdropPreset::PresetFileParser;

namespace RoonVis {
namespace TranspilePrep {

// ---------------------------------------------------------------------------------------
// Default composite shader — byte-exact copy of FinalComposite.cpp:13.
// ---------------------------------------------------------------------------------------
const std::string kDefaultCompositeShaderBody =
    "shader_body\n{\nret = tex2D(sampler_main, uv).xyz;\n}";

// ---------------------------------------------------------------------------------------
// Texture file scan.
// Mirrors TextureManager::ScanTextures (TextureManager.cpp:403-413) with the extension
// list from TextureManager.hpp:112 and FileScanner::Scan (FileScanner.cpp:26-80):
// recursive walk of each search path in order, entries without an extension skipped,
// lower-cased extension matched against the list, then AddTextureFile
// (TextureManager.cpp:344-353) stores the LOWER-CASED stem (basename minus extension).
// ---------------------------------------------------------------------------------------
TextureCatalog BuildTextureCatalog(const std::vector<std::string>& searchPaths)
{
    // TextureManager.hpp:112 (already lower-case, FileScanner lower-cases again at :19-23).
    static const std::vector<std::string> kExtensions{".jpg", ".jpeg", ".dds", ".png", ".tga", ".bmp", ".dib"};

    TextureCatalog catalog;
    for (const auto& currentPath : searchPaths)
    {
        try
        {
            fs::path basePath(currentPath);
            if (!fs::exists(basePath))
            {
                continue;
            }
            // FileScanner.cpp:39-49: resolve symlinks, skip non-directories.
            while (fs::is_symlink(basePath))
            {
                basePath = fs::read_symlink(basePath);
            }
            if (!fs::is_directory(basePath))
            {
                continue;
            }
            for (const auto& entry : fs::recursive_directory_iterator(basePath))
            {
                // FileScanner.cpp:57 (non-boost branch), replicated as-is including its
                // odd symlink condition — regular files always pass it.
                if (!entry.path().has_extension() ||
                    (fs::is_symlink(entry.status()) && fs::is_regular_file(entry.status())))
                {
                    continue;
                }
                auto extension = libprojectM::Utils::ToLower(entry.path().extension().string());
                if (std::find(kExtensions.begin(), kExtensions.end(), extension) != kExtensions.end())
                {
                    // TextureManager::AddTextureFile lower-cases the stem (:346).
                    catalog.baseNames.push_back(libprojectM::Utils::ToLower(entry.path().stem().string()));
                }
            }
        }
        catch (...)
        {
            // FileScanner.cpp:71-78 swallows filesystem errors per root.
        }
    }
    return catalog;
}

namespace {

// TextureSamplerDescriptor::SamplerDeclaration — TextureSamplerDescriptor.cpp:79-108.
std::string SamplerDeclaration(const HostDescriptor& desc)
{
    if (desc.null)
    {
        return {};
    }
    std::string declaration = "uniform ";
    if (desc.is3D)
    {
        declaration.append("sampler3D sampler_");
    }
    else
    {
        declaration.append("sampler2D sampler_");
    }
    declaration.append(desc.samplerName);
    declaration.append(";\n");

    // Short alias for prefixed random textures (:100-105). Case-sensitive "rand" check,
    // as in the vendor code.
    if (desc.samplerName.substr(0, 4) == "rand" && desc.samplerName.length() > 7 && desc.samplerName.at(6) == '_')
    {
        declaration.append("uniform sampler2D sampler_");
        declaration.append(desc.samplerName.substr(0, 6));
        declaration.append(";\n");
    }
    return declaration;
}

// TextureSamplerDescriptor::TexSizeDeclaration — TextureSamplerDescriptor.cpp:110-135.
std::string TexSizeDeclaration(const HostDescriptor& desc)
{
    if (desc.null)
    {
        return {};
    }
    std::string declaration;
    if (!desc.sizeName.empty())
    {
        declaration.append("uniform float4 texsize_");
        declaration.append(desc.sizeName);
        declaration.append(";\n");

        // Short alias for prefixed random textures (:126-131).
        if (desc.sizeName.substr(0, 4) == "rand" && desc.sizeName.length() > 7 && desc.sizeName.at(6) == '_')
        {
            declaration.append("uniform float4 texsize_");
            declaration.append(desc.sizeName.substr(0, 6));
            declaration.append(";\n");
        }
    }
    return declaration;
}

// ---------------------------------------------------------------------------------------
// TextureManager::ExtractTextureSettings — TextureManager.cpp:355-401 (name part only;
// wrap/filter modes never influence the declaration text). Note :397: ANY "??_" prefix is
// stripped, not just the 8 known ones, so name-wise every branch is substr(3).
// ---------------------------------------------------------------------------------------
std::string ExtractUnqualifiedName(const std::string& qualifiedName)
{
    if (qualifiedName.length() <= 3 || qualifiedName.at(2) != '_')
    {
        return qualifiedName;
    }
    return qualifiedName.substr(3);
}

// TextureManager::GetTexture / TryLoadingTexture — TextureManager.cpp:38-51, 168-251.
// Declaration-relevant behaviour: descriptor is ALWAYS non-null ({texture-or-placeholder,
// sampler, fullName, unqualifiedName}; the missing-file case still returns the placeholder
// with the same names, :249-250). sampler3D only if the texture is one of the preloaded
// 3D noise volumes "noisevol_lq"/"noisevol_hq" (Preload, :101-102) — the m_textures lookup
// at :45 is CASE-SENSITIVE on the unqualified name; every file-loaded texture is 2D (:272).
HostDescriptor GetTextureDescriptor(const std::string& fullName)
{
    HostDescriptor desc;
    desc.null = false;
    desc.samplerName = fullName;
    desc.sizeName = ExtractUnqualifiedName(fullName);
    desc.is3D = (desc.sizeName == "noisevol_lq" || desc.sizeName == "noisevol_hq");
    return desc;
}

// TextureManager::GetRandomTexture — TextureManager.cpp:283-342.
// The declaration uses the REQUESTED name (:341), never the randomly chosen file, so the
// random pick itself does not affect the output. What DOES matter: an empty scan list, or
// a "randNN_<prefix>" whose prefix matches no scanned file, yields an EMPTY descriptor
// (:294-298, :331-335) => declarations omitted.
HostDescriptor GetRandomTextureDescriptor(const std::string& randomName,
                                          const std::vector<std::string>& scannedBaseNames)
{
    HostDescriptor desc; // null by default

    std::string lowerCaseName = libprojectM::Utils::ToLower(randomName);

    if (scannedBaseNames.empty())
    {
        return desc;
    }

    std::string prefix;
    if (lowerCaseName.length() > 7 && lowerCaseName.at(6) == '_')
    {
        prefix = lowerCaseName.substr(7);
    }

    if (!prefix.empty())
    {
        auto prefixLength = prefix.length();
        bool anyMatch = std::any_of(scannedBaseNames.begin(), scannedBaseNames.end(),
                                    [&prefix, prefixLength](const std::string& base) {
                                        return base.substr(0, prefixLength) == prefix;
                                    });
        if (!anyMatch)
        {
            return desc;
        }
    }

    // :341 — descriptor with the original requested name for both sampler and size names.
    desc.null = false;
    desc.is3D = false; // Chosen file textures are always 2D (TextureManager.cpp:272).
    desc.samplerName = randomName;
    desc.sizeName = randomName;
    return desc;
}

// ---------------------------------------------------------------------------------------
// Blur level (BlurTexture::BlurLevel — None=0..Blur3=3) + sampler-name side effects.
// MilkdropShader::UpdateMaxBlurLevel — MilkdropShader.cpp (copied verbatim).
// ---------------------------------------------------------------------------------------
void UpdateMaxBlurLevel(int& maxBlurLevel, std::set<std::string>& samplerNames, int requestedLevel)
{
    if (maxBlurLevel >= requestedLevel)
    {
        return;
    }
    maxBlurLevel = requestedLevel;
    if (maxBlurLevel == 3)
    {
        samplerNames.insert("blur1");
        samplerNames.insert("blur2");
        samplerNames.insert("blur3");
    }
    else if (maxBlurLevel == 2)
    {
        samplerNames.insert("blur1");
        samplerNames.insert("blur2");
    }
    else
    {
        samplerNames.insert("blur1");
    }
}

// MilkdropShader::GetReferencedSamplers — copied verbatim
// (operates on the RAW shader body; comments stripped for the scan).
void GetReferencedSamplers(const std::string& program,
                           std::set<std::string>& samplerNames,
                           int& maxBlurLevel)
{
    samplerNames.clear();

    // "main" should always be present.
    samplerNames.insert("main");

    std::string const stripped = libprojectM::Utils::StripComments(program);

    // Search for sampler usage.
    auto found = stripped.find("sampler_", 0);
    while (found != std::string::npos)
    {
        found += 8;
        size_t const end = stripped.find_first_of(" ;,\n\r)", found);

        if (end != std::string::npos)
        {
            std::string const sampler = stripped.substr(static_cast<int>(found), static_cast<int>(end - found));
            if (sampler != "state")
            {
                samplerNames.insert(sampler);
            }
        }

        found = stripped.find("sampler_", found);
    }

    // Also search for texsize usage (note '.' is an extra terminator here).
    found = stripped.find("texsize_", 0);
    while (found != std::string::npos)
    {
        found += 8;
        size_t const end = stripped.find_first_of(" ;,.\n\r)", found);

        if (end != std::string::npos)
        {
            std::string const sampler = stripped.substr(static_cast<int>(found), static_cast<int>(end - found));
            samplerNames.insert(sampler);
        }

        found = stripped.find("texsize_", found);
    }

    {
        // Dedup short "randXX" when the next set element is "randXX_<suffix>".
        auto samplerName = samplerNames.begin();
        std::locale loc;
        while (samplerName != samplerNames.end())
        {
            std::string lowerCaseName = libprojectM::Utils::ToLower(*samplerName);
            if (lowerCaseName.length() == 6 &&
                lowerCaseName.substr(0, 4) == "rand" && std::isdigit(lowerCaseName.at(4), loc) && std::isdigit(lowerCaseName.at(5), loc))
            {
                auto additionalName = samplerName;
                additionalName++;
                if (additionalName != samplerNames.end())
                {
                    std::string addLowerCaseName = libprojectM::Utils::ToLower(*additionalName);
                    if (addLowerCaseName.length() > 7 &&
                        addLowerCaseName.substr(0, 6) == lowerCaseName &&
                        addLowerCaseName[6] == '_')
                    {
                        samplerName = samplerNames.erase(samplerName);
                    }
                }
            }
            samplerName++;
        }
    }

    // Blur level from GetBlurN substrings — else-if chain, highest wins.
    if (stripped.find("GetBlur3") != std::string::npos)
    {
        UpdateMaxBlurLevel(maxBlurLevel, samplerNames, 3);
    }
    else if (stripped.find("GetBlur2") != std::string::npos)
    {
        UpdateMaxBlurLevel(maxBlurLevel, samplerNames, 2);
    }
    else if (stripped.find("GetBlur1") != std::string::npos)
    {
        UpdateMaxBlurLevel(maxBlurLevel, samplerNames, 1);
    }
    else
    {
        maxBlurLevel = 0;
    }
}

// ---------------------------------------------------------------------------------------
// Run the M4 preprocessor once, with a fresh parser/tree/allocator, exactly like
// MilkdropShader::TranspileHLSLShader (cache-miss path) and PreprocessCacheGen.
// ---------------------------------------------------------------------------------------
bool RunPreprocessorOnce(const std::string& input, std::string& out)
{
    M4::Allocator allocator;
    M4::HLSLTree tree(&allocator);
    M4::HLSLParser parser(&allocator, &tree);
    out.clear();
    return parser.ApplyPreprocessor("", input.c_str(), input.size(), out);
}

} // namespace

// ---------------------------------------------------------------------------------------
// Compose the byte-exact parser.Parse() input for one shader.
// Mirrors LoadCode + LoadTexturesAndCompile + TranspileHLSLShader up to parser.Parse.
// Returns false if the device would never reach parser.Parse for this shader body
// (assembly or preprocess failure).
// ---------------------------------------------------------------------------------------
bool ComposeParseInput(MilkdropShader::ShaderType type,
                       const std::string& rawBody,
                       std::map<int, HostDescriptor>& randomTextureDescriptors, // PresetState.hpp, shared warp->comp
                       const TextureCatalog& catalog,
                       Stats& stats,
                       std::string& outComposed)
{
    const std::vector<std::string>& scannedBaseNames = catalog.baseNames;

    // --- LoadCode stage: sampler scan on the RAW body (MilkdropShader.cpp LoadCode) ---
    std::set<std::string> samplerNames;
    int maxBlurLevel = 0;
    GetReferencedSamplers(rawBody, samplerNames, maxBlurLevel);

    // --- Preprocessor input assembly (LoadCode -> AssembleApplyPreprocessorInput).
    //     An assembly failure throws in LoadCode, so on the device LoadTexturesAndCompile
    //     never runs for this shader: bail BEFORE descriptor gathering (rand cache untouched). ---
    std::string assembled;
    try
    {
        assembled = AssembleApplyPreprocessorInput(type, rawBody);
    }
    catch (...)
    {
        return false; // Device throws in LoadCode; shader never reaches Parse.
    }

    // --- Descriptor gathering (MilkdropShader::LoadTexturesAndCompile).
    //     Runs BEFORE TranspileHLSLShader on the device, so the rand-slot cache is filled
    //     even if the preprocessor subsequently fails. ---
    // Device iterates the live std::set while UpdateMaxBlurLevel may insert "blurN" names;
    // any such insertion is only ever revisited by the no-op blur branch, so iterating a
    // sorted snapshot is behaviour-identical.
    std::vector<HostDescriptor> mainTextureDescriptors;
    std::vector<HostDescriptor> textureSamplerDescriptors;
    std::locale loc;
    std::vector<std::string> snapshot(samplerNames.begin(), samplerNames.end());
    for (const auto& name : snapshot)
    {
        // Strip a "??_" prefix for the base-name checks.
        std::string baseName = name;
        if (name.length() > 3 && name.at(2) == '_')
        {
            baseName = name.substr(3);
        }
        std::string lowerCaseName = libprojectM::Utils::ToLower(baseName);

        // "main": descriptor with the FULL name as sampler name, "main" as size name.
        if (lowerCaseName == "main")
        {
            HostDescriptor desc;
            desc.null = false; // presetState.mainTexture is assigned before compile (MilkdropPreset.cpp).
            desc.is3D = false; // Framebuffer color attachment is GL_TEXTURE_2D.
            desc.samplerName = name;
            desc.sizeName = "main";
            mainTextureDescriptors.push_back(desc);
            continue;
        }

        // Explicit blur sampler names only raise the blur level.
        if (lowerCaseName == "blur1")
        {
            UpdateMaxBlurLevel(maxBlurLevel, samplerNames, 1);
            continue;
        }
        if (lowerCaseName == "blur2")
        {
            UpdateMaxBlurLevel(maxBlurLevel, samplerNames, 2);
            continue;
        }
        if (lowerCaseName == "blur3")
        {
            UpdateMaxBlurLevel(maxBlurLevel, samplerNames, 3);
            continue;
        }

        // Random textures, with the per-preset slot cache (warp fills, comp reuses).
        if (lowerCaseName.length() >= 6 &&
            lowerCaseName.substr(0, 4) == "rand" && std::isdigit(lowerCaseName.at(4), loc) && std::isdigit(lowerCaseName.at(5), loc))
        {
            int randomSlot = -1;
            try
            {
                randomSlot = std::stoi(lowerCaseName.substr(4, 2));
            }
            catch (...)
            {
            }

            if (randomSlot >= 0 && randomSlot <= 15)
            {
                if (randomTextureDescriptors.find(randomSlot) != randomTextureDescriptors.end())
                {
                    textureSamplerDescriptors.push_back(randomTextureDescriptors.at(randomSlot));
                    continue;
                }

                auto desc = GetRandomTextureDescriptor(name, scannedBaseNames);
                if (desc.null)
                {
                    ++stats.randEmptyDescriptors;
                }
                randomTextureDescriptors.insert({randomSlot, desc});
                textureSamplerDescriptors.push_back(desc);
                continue;
            }
            // Slot out of range: fall through and treat as a normal texture.
        }

        // Named texture (placeholder still yields a declaration).
        textureSamplerDescriptors.push_back(GetTextureDescriptor(name));
    }

    // --- ApplyPreprocessor (TranspileHLSLShader; a cache hit returns identical bytes) ---
    std::string sourcePreprocessed;
    bool ok = false;
    try
    {
        ok = RunPreprocessorOnce(assembled, sourcePreprocessed);
    }
    catch (...)
    {
        ok = false;
    }
    if (!ok)
    {
        return false; // Device throws in TranspileHLSLShader before Parse.
    }

    // --- Regex strips, copied from TranspileHLSLShader. Sole deviation from the
    //     verbatim vendor text: the (immutable) std::regex objects are constructed once
    //     instead of per loop iteration — byte-identical output, ~10x faster over 7.7k
    //     presets. The one-match-at-a-time while loop is kept verbatim because removal can
    //     create NEW matches across the removed span that a single-pass scan would miss. ---
    static const std::regex kSamplerStripRegex("sampler(2D|3D|)(\\s+|\\().*");
    static const std::regex kTexsizeStripRegex("float4\\s+texsize_.*");
    std::smatch matches;
    while (std::regex_search(sourcePreprocessed, matches, kSamplerStripRegex))
    {
        sourcePreprocessed.replace(matches.position(), matches.length(), "");
    }
    while (std::regex_search(sourcePreprocessed, matches, kTexsizeStripRegex))
    {
        sourcePreprocessed.replace(matches.position(), matches.length(), "");
    }

    // --- Declaration collection (TranspileHLSLShader) ---
    std::set<std::string> samplerDeclarations;
    std::set<std::string> texSizeDeclarations;
    for (const auto& desc : mainTextureDescriptors)
    {
        samplerDeclarations.insert(SamplerDeclaration(desc));
        texSizeDeclarations.insert(TexSizeDeclaration(desc));
    }
    // Blur descriptors: BlurTexture::GetDescriptorsForBlurLevel yields textures named
    // "blur1"/"blur2"/"blur3" (ctor), always GL_TEXTURE_2D and non-null, with an EMPTY
    // size name — and only SamplerDeclaration is collected for them.
    for (int level = 1; level <= maxBlurLevel; ++level)
    {
        HostDescriptor blurDesc;
        blurDesc.null = false;
        blurDesc.is3D = false;
        blurDesc.samplerName = "blur" + std::to_string(level);
        blurDesc.sizeName = {};
        samplerDeclarations.insert(SamplerDeclaration(blurDesc));
    }
    for (const auto& desc : textureSamplerDescriptors)
    {
        samplerDeclarations.insert(SamplerDeclaration(desc));
        texSizeDeclarations.insert(TexSizeDeclaration(desc));
    }

    // --- Front-insertion (TranspileHLSLShader): ascending set iteration + insert(0)
    //     => each block ends up in DESCENDING order, samplers block above texsizes. Empty
    //     declarations (empty descriptors) insert zero bytes, exactly like the device. ---
    for (const auto& texSizeDeclaration : texSizeDeclarations)
    {
        sourcePreprocessed.insert(0, texSizeDeclaration);
    }
    for (const auto& samplerDeclaration : samplerDeclarations)
    {
        sourcePreprocessed.insert(0, samplerDeclaration);
    }

    outComposed = std::move(sourcePreprocessed);
    return true;
}

PreparedParseInputs PrepareParseInputsFromParser(PresetFileParser& parser,
                                                 const TextureCatalog& catalog,
                                                 Stats& stats)
{
    PreparedParseInputs result;

    // --- Shader gating: PresetState::Initialize versions block (PresetState.cpp:117-134),
    //     defaults presetVersion=100, warp/comp shader version=2 (PresetState.hpp:129-131). ---
    int presetVersion = parser.GetInt("MILKDROP_PRESET_VERSION", 100);
    int warpShaderVersion = 2;
    int compositeShaderVersion = 2;
    if (presetVersion < 200)
    {
        warpShaderVersion = 0;
        compositeShaderVersion = 0;
    }
    else if (presetVersion == 200)
    {
        warpShaderVersion = parser.GetInt("PSVERSION", warpShaderVersion);
        compositeShaderVersion = parser.GetInt("PSVERSION", compositeShaderVersion);
    }
    else
    {
        warpShaderVersion = parser.GetInt("PSVERSION_WARP", warpShaderVersion);
        compositeShaderVersion = parser.GetInt("PSVERSION_COMP", compositeShaderVersion);
    }

    const std::string warpBody = parser.GetCode("warp_"); // PresetState.cpp:159
    const std::string compBody = parser.GetCode("comp_"); // PresetState.cpp:160

    // Per-preset random-texture slot cache, shared warp -> comp (PresetState.hpp,
    // MilkdropShader.cpp). Warp is compiled FIRST (MilkdropPreset.cpp:116-117).
    std::map<int, HostDescriptor> randomTextureDescriptors;

    // --- Warp: compiled only if version > 0 AND non-empty code (PerPixelMesh.cpp:128-148). ---
    if (warpShaderVersion <= 0)
    {
        result.warpGatedVersion = true;
        ++stats.warpGatedVersion;
    }
    else if (warpBody.empty())
    {
        result.warpGatedEmpty = true;
        ++stats.warpGatedEmpty;
    }
    else
    {
        std::string composed;
        if (ComposeParseInput(MilkdropShader::ShaderType::WarpShader, warpBody,
                              randomTextureDescriptors, catalog, stats, composed))
        {
            result.warp.present = true;
            result.warp.text = std::move(composed);
            result.warp.parseGenKey = ComputeParseGenCacheKey(result.warp.text);
            ++stats.warpEmitted;
        }
        else
        {
            // Device: LoadCode/Transpile throws -> m_warpShader.reset(), no warp shader.
            result.warpDropped = true;
            ++stats.warpDropped;
        }
    }

    // --- Composite: version > 0 -> preset code if non-empty, else the default composite
    //     shader; a failing preset body falls back to the default (FinalComposite.cpp:35-61). ---
    if (compositeShaderVersion <= 0)
    {
        result.compGatedVersion = true;
        ++stats.compGatedVersion;
    }
    else
    {
        bool usingDefault = compBody.empty();
        if (usingDefault)
        {
            result.compUsedDefaultBody = true;
            ++stats.compDefaultBody;
        }
        std::string body = usingDefault ? kDefaultCompositeShaderBody : compBody;
        std::string composed;
        bool ok = ComposeParseInput(MilkdropShader::ShaderType::CompositeShader, body,
                                    randomTextureDescriptors, catalog, stats, composed);
        if (!ok && !usingDefault)
        {
            // FinalComposite.cpp:47-54: fall back to the default composite shader
            // (fresh MilkdropShader, same PresetState => same rand-slot cache).
            result.compFallback = true;
            ++stats.compFallbacks;
            ok = ComposeParseInput(MilkdropShader::ShaderType::CompositeShader, kDefaultCompositeShaderBody,
                                   randomTextureDescriptors, catalog, stats, composed);
        }
        if (ok)
        {
            result.comp.present = true;
            result.comp.text = std::move(composed);
            result.comp.parseGenKey = ComputeParseGenCacheKey(result.comp.text);
            ++stats.compEmitted;
        }
        else
        {
            result.compDefaultFailed = true;
        }
    }

    return result;
}

PreparedParseInputs PrepareParseInputs(const std::string& presetFileBuffer,
                                       const TextureCatalog& catalog,
                                       Stats& stats,
                                       bool* readOk)
{
    PresetFileParser parser;
    std::istringstream stream(presetFileBuffer);
    // PresetFileParser::Read(path) is a thin wrapper over Read(istream) on a binary
    // ifstream, so an istringstream over the raw file bytes is behaviour-identical.
    const bool ok = parser.Read(stream);
    if (readOk != nullptr)
    {
        *readOk = ok;
    }
    if (!ok)
    {
        ++stats.presetReadFailures;
        return PreparedParseInputs{};
    }
    return PrepareParseInputsFromParser(parser, catalog, stats);
}

bool GenerateGlslFromParseInput(const std::string& parseInputText, std::string& glslOut)
{
    // Fresh allocator/tree/parser/generator per call, exactly like
    // MilkdropShader::TranspileHLSLShader (hlslparser parse/generate is per-call isolated).
    M4::GLSLGenerator generator;
    M4::Allocator allocator;
    M4::HLSLTree tree(&allocator);
    M4::HLSLParser parser(&allocator, &tree);

    glslOut.clear();

    if (!parser.Parse("", parseInputText.c_str(), parseInputText.size()))
    {
        return false;
    }

    // GLSL version pinned to 300 es: MilkdropStaticShaders::Get()->GetGlslGeneratorVersion()
    // is #ifdef USE_GLES-dependent, and the tvOS app builds projectM with USE_GLES defined
    // (ENABLE_GLES ON). Host tools do NOT define USE_GLES, so calling Get() here would
    // silently generate desktop-GL 330 text — wrong for the device cache. Entry point,
    // target and flags mirror MilkdropShader::TranspileHLSLShader verbatim.
    if (!generator.Generate(&tree, M4::GLSLGenerator::Target_FragmentShader,
                            M4::GLSLGenerator::Version_300_ES,
                            "PS", M4::GLSLGenerator::Options(M4::GLSLGenerator::Flag_AlternateNanPropagation)))
    {
        return false;
    }

    glslOut = generator.GetResult();
    return true;
}

} // namespace TranspilePrep
} // namespace RoonVis
