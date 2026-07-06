#include "TestHarness.h"

#include "DeviceTier.h"

using namespace RoonVis;

namespace
{

void TestParseAppleTVModelTier()
{
    // Known models.
    CHECK(ParseAppleTVModelTier("AppleTV5,3") == DeviceTier::HD);
    CHECK(ParseAppleTVModelTier("AppleTV6,2") == DeviceTier::FourKGen1);
    CHECK(ParseAppleTVModelTier("AppleTV11,1") == DeviceTier::FourKGen2);
    CHECK(ParseAppleTVModelTier("AppleTV14,1") == DeviceTier::FourKGen3OrLater);

    // Future hardware maps to the top tier (never accidentally throttled).
    CHECK(ParseAppleTVModelTier("AppleTV15,1") == DeviceTier::FourKGen3OrLater);
    CHECK(ParseAppleTVModelTier("AppleTV99,9") == DeviceTier::FourKGen3OrLater);

    // Intermediate majors bucket with the nearest older generation.
    CHECK(ParseAppleTVModelTier("AppleTV7,1") == DeviceTier::FourKGen2);
    CHECK(ParseAppleTVModelTier("AppleTV12,1") == DeviceTier::FourKGen3OrLater);

    // Malformed / non-AppleTV strings map to the top tier.
    CHECK(ParseAppleTVModelTier("") == DeviceTier::FourKGen3OrLater);
    CHECK(ParseAppleTVModelTier("iPhone16,1") == DeviceTier::FourKGen3OrLater);
    CHECK(ParseAppleTVModelTier("AppleTV") == DeviceTier::FourKGen3OrLater);
    CHECK(ParseAppleTVModelTier("AppleTV,") == DeviceTier::FourKGen3OrLater);
    CHECK(ParseAppleTVModelTier("AppleTVx,1") == DeviceTier::FourKGen3OrLater);
    CHECK(ParseAppleTVModelTier("arm64") == DeviceTier::FourKGen3OrLater);
}

void TestTierPolicyValues()
{
    // Drawable cap: HD tops out at 1080p, everything else may select 4K.
    CHECK(MaxDrawablePresetForTier(DeviceTier::HD) == DrawableSizePreset::P1080);
    CHECK(MaxDrawablePresetForTier(DeviceTier::FourKGen1) == DrawableSizePreset::P2160);
    CHECK(MaxDrawablePresetForTier(DeviceTier::FourKGen2) == DrawableSizePreset::P2160);
    CHECK(MaxDrawablePresetForTier(DeviceTier::FourKGen3OrLater) == DrawableSizePreset::P2160);

    // Defaults: HD 720p@30, everything else 1080p@60.
    CHECK(DefaultDrawablePresetForTier(DeviceTier::HD) == DrawableSizePreset::P720);
    CHECK(DefaultDrawablePresetForTier(DeviceTier::FourKGen1) == DrawableSizePreset::P1080);
    CHECK(DefaultDrawablePresetForTier(DeviceTier::FourKGen3OrLater) == DrawableSizePreset::P1080);
    CHECK(DefaultFrameRateForTier(DeviceTier::HD) == 30);
    CHECK(DefaultFrameRateForTier(DeviceTier::FourKGen1) == 60);
    CHECK(DefaultFrameRateForTier(DeviceTier::FourKGen3OrLater) == 60);
    CHECK(DefaultWarpMeshWidthForTier(DeviceTier::HD) == 64);
    CHECK(DefaultWarpMeshWidthForTier(DeviceTier::FourKGen1) == 96);
    CHECK(DefaultWarpMeshWidthForTier(DeviceTier::FourKGen3OrLater) == 96);

    // Preset ordering supports <= capping.
    CHECK(DrawableSizePreset::P720 < DrawableSizePreset::P1080);
    CHECK(DrawableSizePreset::P1080 < DrawableSizePreset::P1440);
    CHECK(DrawableSizePreset::P1440 < DrawableSizePreset::P2160);
}

void TestSnapFrameRateCap()
{
    // Exact values pass through.
    CHECK(SnapFrameRateCap(25) == 25);
    CHECK(SnapFrameRateCap(30) == 30);
    CHECK(SnapFrameRateCap(50) == 50);
    CHECK(SnapFrameRateCap(60) == 60);

    // Nearest-neighbour snapping.
    CHECK(SnapFrameRateCap(0) == 25);
    CHECK(SnapFrameRateCap(24) == 25);
    CHECK(SnapFrameRateCap(28) == 30);
    CHECK(SnapFrameRateCap(45) == 50);
    CHECK(SnapFrameRateCap(56) == 60);
    CHECK(SnapFrameRateCap(120) == 60);
    CHECK(SnapFrameRateCap(-10) == 25);

    // Equidistant keeps the lower candidate.
    CHECK(SnapFrameRateCap(40) == 30);
    CHECK(SnapFrameRateCap(55) == 50);
}

} // namespace

void RunDeviceTierTests()
{
    TestParseAppleTVModelTier();
    TestTierPolicyValues();
    TestSnapFrameRateCap();
}
