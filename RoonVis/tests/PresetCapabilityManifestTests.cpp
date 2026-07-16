#include "TestHarness.h"

#include "PresetCapabilityManifest.h"

#include <string>

using namespace RoonVis;

namespace
{

// The profile every valid-manifest test writes into the JSON.
CapabilityProfile ManifestProfile()
{
    CapabilityProfile profile;
    profile.deviceTier = "A8";
    profile.drawable = "720p";
    profile.fps = 30;
    profile.projectMRevision = "pm-abc123";
    profile.angleRevision = "angle-def456";
    profile.rvppVersion = 2;
    profile.transpileSalts = "salt-v3";
    profile.tier1CacheFingerprint = "t1-fp-789";
    return profile;
}

std::string ProfileJSON()
{
    return R"({"deviceTier": "A8", "drawable": "720p", "fps": 30,
               "projectMRevision": "pm-abc123", "angleRevision": "angle-def456",
               "rvppVersion": 2, "transpileSalts": "salt-v3",
               "tier1CacheFingerprint": "t1-fp-789"})";
}

std::string ValidManifestJSON()
{
    return std::string(R"({"schema": 1, "profile": )") + ProfileJSON() + R"(,
        "presets": [
          {"name": "a.milk", "path": "Cat/Sub/a.milk", "safety": "safe",
           "steadyState": "pass", "activationMechanism": "tier1-cache",
           "activationVerdict": "sufficient",
           "evidence": {"settledP50Ms": 4.25, "settledP95Ms": 9.5,
                        "settledP99Ms": 15.125, "overBudgetRate": 0.0125,
                        "sampleCount": 1800}},
          {"name": "b.milk", "path": "Cat/b.milk", "safety": "known-crash",
           "steadyState": "unknown", "activationMechanism": "none",
           "activationVerdict": "unknown",
           "evidence": {"settledP50Ms": 0.0, "settledP95Ms": 0.0,
                        "settledP99Ms": 0.0, "overBudgetRate": 0.0,
                        "sampleCount": 0}},
          {"name": "c.milk", "path": "c.milk", "safety": "unsupported",
           "steadyState": "fail", "activationMechanism": "program-blob",
           "activationVerdict": "insufficient"}
        ]})";
}

// (1) A valid manifest parses into records with every field decoded.
void TestValidManifestParses()
{
    CapabilityManifest manifest;
    REQUIRE(ParseCapabilityManifest(ValidManifestJSON(), ManifestProfile(), manifest) ==
            ManifestLoadStatus::Valid);
    CHECK(manifest.schema == 1);
    CHECK(manifest.profile.deviceTier == "A8");
    CHECK(manifest.profile.drawable == "720p");
    CHECK(manifest.profile.fps == 30);
    CHECK(manifest.profile.projectMRevision == "pm-abc123");
    CHECK(manifest.profile.angleRevision == "angle-def456");
    CHECK(manifest.profile.rvppVersion == 2);
    CHECK(manifest.profile.transpileSalts == "salt-v3");
    CHECK(manifest.profile.tier1CacheFingerprint == "t1-fp-789");

    REQUIRE(manifest.presets.size() == 3);
    const CapabilityRecord &a = manifest.presets[0];
    CHECK(a.name == "a.milk");
    CHECK(a.path == "Cat/Sub/a.milk");
    CHECK(a.safety == PresetSafety::Safe);
    CHECK(a.steadyState == SteadyStateVerdict::Pass);
    CHECK(a.activationMechanism == ActivationMechanism::Tier1Cache);
    CHECK(a.activationVerdict == ActivationVerdict::Sufficient);

    const CapabilityRecord &b = manifest.presets[1];
    CHECK(b.safety == PresetSafety::KnownCrash);
    CHECK(b.steadyState == SteadyStateVerdict::Unknown);
    CHECK(b.activationMechanism == ActivationMechanism::None);
    CHECK(b.activationVerdict == ActivationVerdict::Unknown);

    const CapabilityRecord &c = manifest.presets[2];
    CHECK(c.safety == PresetSafety::Unsupported);
    CHECK(c.steadyState == SteadyStateVerdict::Fail);
    CHECK(c.activationMechanism == ActivationMechanism::ProgramBlob);
    CHECK(c.activationVerdict == ActivationVerdict::Insufficient);
    // Absent evidence object -> zero defaults.
    CHECK(c.evidence.settledP50Ms == 0.0);
    CHECK(c.evidence.sampleCount == 0);
}

// (2) Evidence numbers round-trip exactly (binary-exact doubles chosen).
void TestEvidenceNumbersRoundTrip()
{
    CapabilityManifest manifest;
    REQUIRE(ParseCapabilityManifest(ValidManifestJSON(), ManifestProfile(), manifest) ==
            ManifestLoadStatus::Valid);
    REQUIRE(manifest.presets.size() == 3);
    const CapabilityEvidence &evidence = manifest.presets[0].evidence;
    CHECK(evidence.settledP50Ms == 4.25);
    CHECK(evidence.settledP95Ms == 9.5);
    CHECK(evidence.settledP99Ms == 15.125);
    CHECK(evidence.overBudgetRate == 0.0125);
    CHECK(evidence.sampleCount == 1800);
}

// (3) Malformed JSON -> Malformed, out reset.
void TestMalformedJSON()
{
    const CapabilityProfile expected = ManifestProfile();
    CapabilityManifest manifest;

    CHECK(ParseCapabilityManifest("", expected, manifest) == ManifestLoadStatus::Malformed);
    CHECK(ParseCapabilityManifest("not json", expected, manifest) == ManifestLoadStatus::Malformed);
    CHECK(ParseCapabilityManifest("{", expected, manifest) == ManifestLoadStatus::Malformed);
    CHECK(ParseCapabilityManifest("[]", expected, manifest) == ManifestLoadStatus::Malformed);
    CHECK(ParseCapabilityManifest("{}", expected, manifest) == ManifestLoadStatus::Malformed);
    // Truncated mid-array.
    std::string valid = ValidManifestJSON();
    CHECK(ParseCapabilityManifest(valid.substr(0, valid.size() / 2), expected, manifest) ==
          ManifestLoadStatus::Malformed);
    // Trailing garbage after the root object.
    CHECK(ParseCapabilityManifest(valid + "x", expected, manifest) ==
          ManifestLoadStatus::Malformed);
    // out is reset on failure.
    CHECK(manifest.presets.empty());
    CHECK(manifest.schema == 0);

    // Wrong schema version fails closed.
    std::string schema2 = valid;
    schema2.replace(schema2.find("\"schema\": 1"), 11, "\"schema\": 2");
    CHECK(ParseCapabilityManifest(schema2, expected, manifest) == ManifestLoadStatus::Malformed);

    // Mistyped required field (fps as string).
    std::string badFps = valid;
    badFps.replace(badFps.find("\"fps\": 30"), 9, "\"fps\": \"30\"");
    CHECK(ParseCapabilityManifest(badFps, expected, manifest) == ManifestLoadStatus::Malformed);

    // Missing per-record required field (no safety).
    std::string missing = std::string(R"({"schema": 1, "profile": )") + ProfileJSON() + R"(,
        "presets": [{"name": "a.milk", "steadyState": "pass",
                     "activationMechanism": "none", "activationVerdict": "sufficient"}]})";
    CHECK(ParseCapabilityManifest(missing, expected, manifest) == ManifestLoadStatus::Malformed);
}

// (4) Unknown enum strings -> Malformed (fail closed), for every enum field.
void TestUnknownEnumStringsFailClosed()
{
    const CapabilityProfile expected = ManifestProfile();
    const char *fields[][2] = {
        {"\"safety\": \"safe\"", "\"safety\": \"mostly-safe\""},
        {"\"steadyState\": \"pass\"", "\"steadyState\": \"passed\""},
        {"\"activationMechanism\": \"tier1-cache\"", "\"activationMechanism\": \"tier2-cache\""},
        {"\"activationVerdict\": \"sufficient\"", "\"activationVerdict\": \"maybe\""},
    };
    for (const auto &field : fields)
    {
        std::string json = ValidManifestJSON();
        const size_t at = json.find(field[0]);
        REQUIRE(at != std::string::npos);
        json.replace(at, std::string(field[0]).size(), field[1]);
        CapabilityManifest manifest;
        CHECK(ParseCapabilityManifest(json, expected, manifest) == ManifestLoadStatus::Malformed);
        CHECK(manifest.presets.empty());
    }
}

// (5) Profile mismatch: deviceTier and fps always gate.
void TestProfileMismatchTierAndFps()
{
    CapabilityManifest manifest;

    CapabilityProfile wrongTier = ManifestProfile();
    wrongTier.deviceTier = "A15";
    CHECK(ParseCapabilityManifest(ValidManifestJSON(), wrongTier, manifest) ==
          ManifestLoadStatus::ProfileMismatch);
    // Mismatch still hands back the parsed manifest for logging.
    CHECK(manifest.presets.size() == 3);
    CHECK(manifest.profile.deviceTier == "A8");

    CapabilityProfile wrongFps = ManifestProfile();
    wrongFps.fps = 60;
    CHECK(ParseCapabilityManifest(ValidManifestJSON(), wrongFps, manifest) ==
          ManifestLoadStatus::ProfileMismatch);
}

// (6) Revisions / salts / fingerprint / rvppVersion gate only when pinned
//     (non-empty / non-zero) in `expected`.
void TestProfileRevisionPinningRules()
{
    CapabilityManifest manifest;

    // Unpinned expected (only tier+fps set): manifest revisions don't matter.
    CapabilityProfile loose;
    loose.deviceTier = "A8";
    loose.fps = 30;
    CHECK(ParseCapabilityManifest(ValidManifestJSON(), loose, manifest) ==
          ManifestLoadStatus::Valid);

    // Pinned-and-matching: Valid (the all-fields case is TestValidManifestParses).
    // Pinned-and-different: each pinned field alone forces ProfileMismatch.
    {
        CapabilityProfile pinned = loose;
        pinned.projectMRevision = "pm-OTHER";
        CHECK(ParseCapabilityManifest(ValidManifestJSON(), pinned, manifest) ==
              ManifestLoadStatus::ProfileMismatch);
    }
    {
        CapabilityProfile pinned = loose;
        pinned.angleRevision = "angle-OTHER";
        CHECK(ParseCapabilityManifest(ValidManifestJSON(), pinned, manifest) ==
              ManifestLoadStatus::ProfileMismatch);
    }
    {
        CapabilityProfile pinned = loose;
        pinned.transpileSalts = "salt-OTHER";
        CHECK(ParseCapabilityManifest(ValidManifestJSON(), pinned, manifest) ==
              ManifestLoadStatus::ProfileMismatch);
    }
    {
        CapabilityProfile pinned = loose;
        pinned.tier1CacheFingerprint = "t1-OTHER";
        CHECK(ParseCapabilityManifest(ValidManifestJSON(), pinned, manifest) ==
              ManifestLoadStatus::ProfileMismatch);
    }
    {
        CapabilityProfile pinned = loose;
        pinned.drawable = "1080p";
        CHECK(ParseCapabilityManifest(ValidManifestJSON(), pinned, manifest) ==
              ManifestLoadStatus::ProfileMismatch);
    }
    {
        CapabilityProfile pinned = loose;
        pinned.rvppVersion = 3; // manifest says 2
        CHECK(ParseCapabilityManifest(ValidManifestJSON(), pinned, manifest) ==
              ManifestLoadStatus::ProfileMismatch);
    }
}

// (7) Extra/unknown JSON fields are ignored at every level (forward compat).
void TestExtraFieldsIgnored()
{
    const std::string json = R"({"schema": 1, "futureTopLevel": {"x": [1, 2]},
        "profile": {"deviceTier": "A8", "drawable": "720p", "fps": 30,
                    "projectMRevision": "pm-abc123", "angleRevision": "angle-def456",
                    "rvppVersion": 2, "transpileSalts": "salt-v3",
                    "tier1CacheFingerprint": "t1-fp-789", "futureProfileField": true},
        "presets": [
          {"name": "a.milk", "path": "a.milk", "safety": "safe",
           "steadyState": "pass", "activationMechanism": "none",
           "activationVerdict": "sufficient", "futureRecordField": null,
           "evidence": {"settledP50Ms": 1.5, "settledP95Ms": 2.5, "settledP99Ms": 3.5,
                        "overBudgetRate": 0.25, "sampleCount": 42,
                        "futureEvidenceField": "yes"}}
        ]})";
    CapabilityManifest manifest;
    REQUIRE(ParseCapabilityManifest(json, ManifestProfile(), manifest) ==
            ManifestLoadStatus::Valid);
    REQUIRE(manifest.presets.size() == 1);
    CHECK(manifest.presets[0].name == "a.milk");
    CHECK(manifest.presets[0].evidence.sampleCount == 42);
    CHECK(manifest.presets[0].evidence.overBudgetRate == 0.25);
}

// (8) Empty presets array is a valid manifest (fresh device, nothing measured).
void TestEmptyPresetsArrayValid()
{
    const std::string json =
        std::string(R"({"schema": 1, "profile": )") + ProfileJSON() + R"(, "presets": []})";
    CapabilityManifest manifest;
    CHECK(ParseCapabilityManifest(json, ManifestProfile(), manifest) ==
          ManifestLoadStatus::Valid);
    CHECK(manifest.presets.empty());
}

// (9) String escapes in names survive decoding (preset filenames are wild).
void TestStringEscapesDecoded()
{
    const std::string json = std::string(R"({"schema": 1, "profile": )") + ProfileJSON() + R"(,
        "presets": [{"name": "a \"quoted\" \\ é.milk", "path": "p",
                     "safety": "safe", "steadyState": "pass",
                     "activationMechanism": "none", "activationVerdict": "sufficient"}]})";
    CapabilityManifest manifest;
    REQUIRE(ParseCapabilityManifest(json, ManifestProfile(), manifest) ==
            ManifestLoadStatus::Valid);
    REQUIRE(manifest.presets.size() == 1);
    CHECK(manifest.presets[0].name == "a \"quoted\" \\ \xc3\xa9.milk");
}

} // namespace

void RunPresetCapabilityManifestTests()
{
    TestValidManifestParses();
    TestEvidenceNumbersRoundTrip();
    TestMalformedJSON();
    TestUnknownEnumStringsFailClosed();
    TestProfileMismatchTierAndFps();
    TestProfileRevisionPinningRules();
    TestExtraFieldsIgnored();
    TestEmptyPresetsArrayValid();
    TestStringEscapesDecoded();
}
