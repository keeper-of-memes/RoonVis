#include "TestHarness.h"

#include "PresetCompat.h"

#include <string>

using namespace RoonVis;

namespace
{

// Minimal .milk fragments crafted per the Milkdrop INI-like format.
const char kShapeHeavyPreset[] =
    "[preset00]\n"
    "MILKDROP_PRESET_VERSION=201\n"
    "shapecode_0_enabled=1\n"
    "shapecode_0_num_inst=1024\n"
    "shapecode_0_sides=32\n"
    "shapecode_1_enabled=0\n"
    "shapecode_1_num_inst=500\n"
    "shapecode_2_enabled=1\n"
    "shapecode_2_num_inst=300\n"
    "per_frame_1=zoom = 1.01;\n";

const char kShaderPreset[] =
    "[preset00]\n"
    "MILKDROP_PRESET_VERSION=201\n"
    "wavecode_0_enabled=1\n"
    "wave_0_per_point1=x = x + 0.01;\n"
    "wave_0_per_point2=y = y - 0.01;\n"
    "warp_1=`shader_body {\n"
    "warp_2=`  float3 a = GetBlur1(uv);\n"
    "warp_3=`  float3 b = GetBlur2(uv) + tex2D(sampler_pw_mytexture, uv).xyz;\n"
    "warp_4=`  ret = a + b;\n"
    "warp_5=`}\n"
    "comp_1=`shader_body {\n"
    "comp_2=`  ret = tex2D(sampler_fc_main, uv).xyz + tex2D(sampler_noise_lq, uv).xyz;\n"
    "comp_3=`  ret += tex2D(sampler_rand03_smalltiled, uv).xyz;\n"
    "comp_4=`}\n";

void TestShapeInstanceExtraction()
{
    PresetCompatFeatures f;
    REQUIRE(ExtractPresetCompatFeaturesFromBuffer(kShapeHeavyPreset, f));
    // Enabled shapes only: 1024 + 300; the disabled shape's 500 must not count.
    CHECK(f.totalShapeInstances == 1324);
    CHECK(f.enabledShapes == 2);
    CHECK(f.maxShapeSides == 32);
    CHECK(f.perFrameLen > 0);
    CHECK(f.warpShaderLen == 0);
}

void TestShaderFeatureExtraction()
{
    PresetCompatFeatures f;
    REQUIRE(ExtractPresetCompatFeaturesFromBuffer(kShaderPreset, f));
    CHECK(f.totalShapeInstances == 0);
    CHECK(f.enabledWaves == 1);
    CHECK(f.wavePerPointLen > 0);
    CHECK(f.blurTaps == 2);
    CHECK(f.warpShaderLen > 0);
    CHECK(f.compShaderLen > 0);
    // Texture refs: mytexture only. main/noise_lq are builtins; the rand
    // slot resolves to whatever textures exist, never a specific file.
    REQUIRE(f.textureRefs.size() == 1);
    CHECK(f.textureRefs[0] == "mytexture");
}

void TestDefaultInstanceCount()
{
    // Enabled shape without num_inst defaults to 1 (mirrors CustomShape.cpp).
    const char preset[] = "[preset00]\nshapecode_3_enabled=1\n";
    PresetCompatFeatures f;
    REQUIRE(ExtractPresetCompatFeaturesFromBuffer(preset, f));
    CHECK(f.totalShapeInstances == 1);
}

void TestClassifierRules()
{
    // Derived-rule fixtures (provenance in PresetCompat.cpp).
    PresetCompatFeatures f;

    // Shape-heavy: 1324 instances -> A15 fail, A8 fail.
    REQUIRE(ExtractPresetCompatFeaturesFromBuffer(kShapeHeavyPreset, f));
    PresetCompatResult r = ClassifyPresetCompat(f);
    CHECK(r.a15 == PresetCompatVerdict::Fail);
    CHECK(r.a8 == PresetCompatVerdict::Fail);
    CHECK(r.reasons.find("shape-instances") != std::string::npos);

    // Moderate shapes: A15 marginal band [150,400); A8 fail via the
    // device-derived shapes>=100 rule (HD burn-in, 2026-07-09).
    f = PresetCompatFeatures{};
    f.totalShapeInstances = 200;
    r = ClassifyPresetCompat(f);
    CHECK(r.a15 == PresetCompatVerdict::Marginal);
    CHECK(r.a8 == PresetCompatVerdict::Fail);
    CHECK(r.reasons.find("a8-shape-instances") != std::string::npos);

    // Custom shader + blur: A15 pass; A8 FAIL (2026-07-13 device observation —
    // any warp/comp shader or blur was 100% slow on-device, n=907/927/775;
    // mechanism deliberately unasserted, provenance in PresetCompat.cpp).
    f = PresetCompatFeatures{};
    f.totalShapeInstances = 0;
    f.blurTaps = 1;
    f.warpShaderLen = 300;
    f.compShaderLen = 300;
    r = ClassifyPresetCompat(f);
    CHECK(r.a15 == PresetCompatVerdict::Pass);
    CHECK(r.a8 == PresetCompatVerdict::Marginal);
    CHECK(r.reasons.find("a8-custom-shader-screen") != std::string::npos);

    // Heavy shaders but no shapes: A15 pass, A8 fail (custom shader present).
    f = PresetCompatFeatures{};
    f.blurTaps = 5;
    f.warpShaderLen = 1200;
    f.compShaderLen = 900;
    r = ClassifyPresetCompat(f);
    CHECK(r.a15 == PresetCompatVerdict::Pass);
    CHECK(r.a8 == PresetCompatVerdict::Marginal);
    CHECK(r.reasons.find("a8-custom-shader-screen") != std::string::npos);

    // staticHeavy signature (weak rule): A15 marginal.
    f = PresetCompatFeatures{};
    f.blurTaps = 10;
    f.perFrameLen = 1500;
    r = ClassifyPresetCompat(f);
    CHECK(r.a15 == PresetCompatVerdict::Marginal);
}

void TestA8DeviceRuleBoundaries()
{
    // Boundary fixtures for the RETRAINED A8 rules (2026-07-13, n=2565 device
    // burn-in; provenance in PresetCompat.cpp): FAIL if any custom warp/comp
    // shader OR blur (100% observed), OR shapes>=100, OR (shapeInst>=4 |
    // perPixelLen>=400 | wavePerPointLen>=400); else PASS.
    PresetCompatFeatures f;

    // Custom shader is the dominant reject: any warp/comp length -> fail.
    f.warpShaderLen = 1;
    PresetCompatResult r = ClassifyPresetCompat(f);
    CHECK(r.a8 == PresetCompatVerdict::Marginal);
    CHECK(r.reasons.find("a8-custom-shader-screen") != std::string::npos);

    // Blur alone (no custom shader length) -> fail.
    f = PresetCompatFeatures{};
    f.blurTaps = 1;
    r = ClassifyPresetCompat(f);
    CHECK(r.a8 == PresetCompatVerdict::Marginal);
    CHECK(r.reasons.find("a8-custom-shader-screen") != std::string::npos);

    // shapes boundary: 99 -> Marginal (heavy-code screen band), 100 -> Fail
    // (shape count is the one static rule that survived validation).
    f = PresetCompatFeatures{};
    f.totalShapeInstances = 99;
    r = ClassifyPresetCompat(f);
    CHECK(r.a8 == PresetCompatVerdict::Marginal); // shapeInst>=4 screen band
    CHECK(r.reasons.find("a8-heavy-code-screen") != std::string::npos);
    f.totalShapeInstances = 100;
    r = ClassifyPresetCompat(f);
    CHECK(r.a8 == PresetCompatVerdict::Fail);
    CHECK(r.a15 == PresetCompatVerdict::Pass); // below every A15 threshold

    // Heavy-code secondary rules (no custom shader): shapeInst>=4, perPixelLen>=400
    // — Marginal since 2026-07-15 (screening prioritiser, not a steady verdict).
    f = PresetCompatFeatures{};
    f.totalShapeInstances = 4;
    r = ClassifyPresetCompat(f);
    CHECK(r.a8 == PresetCompatVerdict::Marginal);
    CHECK(r.reasons.find("a8-heavy-code-screen") != std::string::npos);
    f = PresetCompatFeatures{};
    f.perPixelLen = 400;
    r = ClassifyPresetCompat(f);
    CHECK(r.a8 == PresetCompatVerdict::Marginal);

    // Clean profile: no custom shader, no blur, low shape/per-pixel/wave -> A8 PASS
    // (the retrained rule RESTORES the A8 pass verdict; 70% of such presets ran
    // clean on-device, and the shipped allowlist is the device-confirmed subset).
    f = PresetCompatFeatures{};
    f.totalShapeInstances = 3;
    f.perFrameLen = 300;
    r = ClassifyPresetCompat(f);
    CHECK(r.a15 == PresetCompatVerdict::Pass);
    CHECK(r.a8 == PresetCompatVerdict::Pass);
    CHECK(r.reasons.find("a8-clean-profile") != std::string::npos);

    // Statically empty preset: A15 pass, A8 pass (clean profile).
    f = PresetCompatFeatures{};
    r = ClassifyPresetCompat(f);
    CHECK(r.a15 == PresetCompatVerdict::Pass);
    CHECK(r.a8 == PresetCompatVerdict::Pass);
    CHECK(r.reasons.find("a8-clean-profile") != std::string::npos);
}

} // namespace

void RunPresetCompatTests()
{
    TestShapeInstanceExtraction();
    TestShaderFeatureExtraction();
    TestDefaultInstanceCount();
    TestClassifierRules();
    TestA8DeviceRuleBoundaries();
}
