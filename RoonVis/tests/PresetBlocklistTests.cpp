#include "TestHarness.h"

#include "PresetBlocklist.h"

#include <cstring>

using namespace RoonVis;

namespace
{

void TestDefaultsClassifyKnownPresets()
{
    const PresetBlocklists &defaults = DefaultPresetBlocklists();
    CHECK(IsSlowPreset(defaults, "Jc_-_Quantum_Processing.milk"));
    CHECK(IsCrashingPreset(defaults, "LuX_-_Heavy_Texture_Trip_1.milk"));
    CHECK(IsStaticHeavyPreset(defaults, "rediculator_qrem_glob.milk"));
    CHECK(!IsSlowPreset(defaults, "not_blocked.milk"));
    CHECK(!IsCrashingPreset(defaults, ""));
}

void TestParseBundleJSON()
{
    const char *json =
        "{"
        "\"slow\":[\"a.milk\",\"a.milk\"],"
        "\"crashing\":[\"b.milk\"],"
        "\"staticHeavy\":[\"c.milk\"],"
        "\"learnedSlowSeedHD\":[\"d.milk\",\"e.milk\"],"
        "\"notes\":[\"ignored\"]"
        "}";
    PresetBlocklists parsed;
    REQUIRE(ParsePresetBlocklistJSON(json, std::strlen(json), parsed));
    CHECK(parsed.slow.size() == 1);
    CHECK(IsSlowPreset(parsed, "a.milk"));
    CHECK(IsCrashingPreset(parsed, "b.milk"));
    CHECK(IsStaticHeavyPreset(parsed, "c.milk"));
    CHECK(!IsStaticHeavyPreset(parsed, "ignored"));
    CHECK(parsed.learnedSlowSeedHD.size() == 2);
    CHECK(parsed.learnedSlowSeedHD.count("d.milk") == 1);
    CHECK(parsed.learnedSlowSeedHD.count("e.milk") == 1);
}

void TestParseRejectsMissingRequiredLists()
{
    const char *json = "{\"slow\":[],\"crashing\":[]}";
    PresetBlocklists parsed;
    CHECK(!ParsePresetBlocklistJSON(json, std::strlen(json), parsed));
}

void TestParseRejectsMalformedJSON()
{
    const char *json = "{\"slow\":[\"a.milk\",],\"crashing\":[],\"staticHeavy\":[]}";
    PresetBlocklists parsed;
    CHECK(!ParsePresetBlocklistJSON(json, std::strlen(json), parsed));
}

}  // namespace

void RunPresetBlocklistTests()
{
    TestDefaultsClassifyKnownPresets();
    TestParseBundleJSON();
    TestParseRejectsMissingRequiredLists();
    TestParseRejectsMalformedJSON();
}
