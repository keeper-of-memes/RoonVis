// PreprocessCacheResourceTests.cpp
//
// Round-trip tests for the RVPP prepopulated shader-cache container
// (PreprocessCacheResource.{h,cpp}): the SAME serialization helpers the PreprocessCacheGen
// host tool uses to write the resource, and the SAME parse/seed function the app's
// SeedPreprocessCacheFromResource uses at startup (extracted to pure C++ precisely so this
// round trip is host-testable).
//
// Covers: v2 (stage-tagged, both stages seed into the ONE PreprocessCache under
// salt-disambiguated keys), v1 back-compat, and the forgiving failure semantics
// (bad magic / unknown version / truncated header -> no-op; truncated entry stream or
// unknown stage tag -> partial seed kept).

#include "PreprocessCache.h"
#include "PreprocessCacheResource.h"

#include "TestHarness.h"

#include <string>

using RoonVis::kRvppStageParseGen;
using RoonVis::kRvppStagePreprocess;
using RoonVis::kRvppVersion1;
using RoonVis::kRvppVersion2;
using RoonVis::PreprocessCache;
using RoonVis::RvppAppendEntryV1;
using RoonVis::RvppAppendEntryV2;
using RoonVis::RvppAppendHeader;
using RoonVis::RvppSeedResult;
using RoonVis::SeedPreprocessCacheFromRvppBuffer;

namespace {

const uint8_t* Bytes(const std::string& s)
{
    return reinterpret_cast<const uint8_t*>(s.data());
}

// Two preprocess-stage and two parse-gen-stage entries with realistic salted keys.
std::string MakeV2Buffer()
{
    std::string buf;
    RvppAppendHeader(buf, kRvppVersion2, "pmpp-v1:", 4);
    RvppAppendEntryV2(buf, kRvppStagePreprocess, "pmpp-v1:aaaa-1", "preprocessed HLSL A");
    RvppAppendEntryV2(buf, kRvppStagePreprocess, "pmpp-v1:bbbb-2", "preprocessed HLSL B");
    RvppAppendEntryV2(buf, kRvppStageParseGen, "pmpp-parse-v1:cccc-3", "generated GLSL C");
    RvppAppendEntryV2(buf, kRvppStageParseGen, "pmpp-parse-v1:dddd-4", "generated GLSL D");
    return buf;
}

void TestV2RoundTripSeedsBothStages()
{
    const std::string buf = MakeV2Buffer();

    PreprocessCache cache(1); // tiny capacity: seeding must raise it (no seed evicted)
    const RvppSeedResult result = SeedPreprocessCacheFromRvppBuffer(Bytes(buf), buf.size(), cache);

    CHECK(result.ok);
    CHECK(!result.truncated);
    CHECK(result.version == kRvppVersion2);
    CHECK(result.salt == "pmpp-v1:");
    CHECK(result.preprocessEntries == 2);
    CHECK(result.parseGenEntries == 2);
    CHECK(cache.Seeds() == 4);
    CHECK(cache.Size() == 4);
    CHECK(cache.Capacity() >= 4 + 64);

    std::string value;
    CHECK(cache.Get("pmpp-v1:aaaa-1", value) && value == "preprocessed HLSL A");
    CHECK(cache.Get("pmpp-v1:bbbb-2", value) && value == "preprocessed HLSL B");
    CHECK(cache.Get("pmpp-parse-v1:cccc-3", value) && value == "generated GLSL C");
    CHECK(cache.Get("pmpp-parse-v1:dddd-4", value) && value == "generated GLSL D");
}

void TestV1BufferStillSeeds()
{
    std::string buf;
    RvppAppendHeader(buf, kRvppVersion1, "pmpp-v1:", 2);
    RvppAppendEntryV1(buf, "pmpp-v1:k1-5", "value one");
    RvppAppendEntryV1(buf, "pmpp-v1:k2-6", "value two");

    PreprocessCache cache(1);
    const RvppSeedResult result = SeedPreprocessCacheFromRvppBuffer(Bytes(buf), buf.size(), cache);

    CHECK(result.ok);
    CHECK(!result.truncated);
    CHECK(result.version == kRvppVersion1);
    CHECK(result.preprocessEntries == 2); // v1 entries all count as preprocess-stage
    CHECK(result.parseGenEntries == 0);
    CHECK(cache.Seeds() == 2);

    std::string value;
    CHECK(cache.Get("pmpp-v1:k1-5", value) && value == "value one");
    CHECK(cache.Get("pmpp-v1:k2-6", value) && value == "value two");
}

void TestBadMagicIsNoOp()
{
    std::string buf = MakeV2Buffer();
    buf[0] = 'X'; // corrupt the magic

    PreprocessCache cache(8);
    const RvppSeedResult result = SeedPreprocessCacheFromRvppBuffer(Bytes(buf), buf.size(), cache);

    CHECK(!result.ok);
    CHECK(result.error != nullptr);
    CHECK(cache.Size() == 0);
    CHECK(cache.Seeds() == 0);
}

void TestUnknownVersionIsNoOp()
{
    std::string buf;
    RvppAppendHeader(buf, 3 /* future version */, "pmpp-v1:", 1);
    RvppAppendEntryV2(buf, kRvppStagePreprocess, "k", "v");

    PreprocessCache cache(8);
    const RvppSeedResult result = SeedPreprocessCacheFromRvppBuffer(Bytes(buf), buf.size(), cache);

    CHECK(!result.ok);
    CHECK(result.error != nullptr);
    CHECK(cache.Size() == 0);
}

void TestTruncatedHeaderIsNoOp()
{
    const std::string full = MakeV2Buffer();

    PreprocessCache cache(8);
    // Every truncation point inside the header (magic + version + saltLen + salt +
    // entryCount = 4+4+4+8+4 = 24 bytes) must be a clean no-op.
    for (size_t len = 0; len < 24; ++len)
    {
        const RvppSeedResult result = SeedPreprocessCacheFromRvppBuffer(Bytes(full), len, cache);
        CHECK(!result.ok);
    }
    CHECK(cache.Size() == 0);

    // Null buffer, degenerate but must not crash.
    const RvppSeedResult nullResult = SeedPreprocessCacheFromRvppBuffer(nullptr, 0, cache);
    CHECK(!nullResult.ok);
}

void TestTruncatedEntryStreamKeepsPartialSeed()
{
    const std::string full = MakeV2Buffer();
    // Cut inside the FOURTH entry: keep everything but the last 5 bytes.
    const std::string cut = full.substr(0, full.size() - 5);

    PreprocessCache cache(1);
    const RvppSeedResult result = SeedPreprocessCacheFromRvppBuffer(Bytes(cut), cut.size(), cache);

    CHECK(result.ok);
    CHECK(result.truncated);
    CHECK(result.error != nullptr);
    CHECK(result.preprocessEntries == 2);
    CHECK(result.parseGenEntries == 1); // entry 4 lost, first three kept
    CHECK(cache.Seeds() == 3);

    std::string value;
    CHECK(cache.Get("pmpp-parse-v1:cccc-3", value) && value == "generated GLSL C");
    CHECK(!cache.Get("pmpp-parse-v1:dddd-4", value));
}

void TestUnknownStageTagStopsAndKeepsPartialSeed()
{
    std::string buf;
    RvppAppendHeader(buf, kRvppVersion2, "pmpp-v1:", 3);
    RvppAppendEntryV2(buf, kRvppStagePreprocess, "pmpp-v1:k1-7", "one");
    RvppAppendEntryV2(buf, 9 /* unknown stage */, "pmpp-v1:k2-8", "two");
    RvppAppendEntryV2(buf, kRvppStageParseGen, "pmpp-parse-v1:k3-9", "three");

    PreprocessCache cache(8);
    const RvppSeedResult result = SeedPreprocessCacheFromRvppBuffer(Bytes(buf), buf.size(), cache);

    // Record length is unknowable past an unknown tag: stop, keep the prefix.
    CHECK(result.ok);
    CHECK(result.truncated);
    CHECK(result.preprocessEntries == 1);
    CHECK(result.parseGenEntries == 0);
    CHECK(cache.Seeds() == 1);

    std::string value;
    CHECK(cache.Get("pmpp-v1:k1-7", value) && value == "one");
}

void TestV2StageTagDoesNotLeakIntoValues()
{
    // Values containing bytes 1/2 and length-prefix-looking data must survive intact.
    std::string binaryValue;
    binaryValue.push_back(static_cast<char>(kRvppStagePreprocess));
    binaryValue.push_back(static_cast<char>(kRvppStageParseGen));
    binaryValue.append("RVPP");
    binaryValue.push_back('\0');
    binaryValue.append("tail");

    std::string buf;
    RvppAppendHeader(buf, kRvppVersion2, "pmpp-v1:", 2);
    RvppAppendEntryV2(buf, kRvppStageParseGen, "pmpp-parse-v1:bin-1", binaryValue);
    RvppAppendEntryV2(buf, kRvppStagePreprocess, "pmpp-v1:bin-2", std::string());

    PreprocessCache cache(8);
    const RvppSeedResult result = SeedPreprocessCacheFromRvppBuffer(Bytes(buf), buf.size(), cache);

    CHECK(result.ok);
    CHECK(!result.truncated);
    CHECK(result.parseGenEntries == 1);
    CHECK(result.preprocessEntries == 1);

    std::string value;
    CHECK(cache.Get("pmpp-parse-v1:bin-1", value) && value == binaryValue);
    CHECK(cache.Get("pmpp-v1:bin-2", value) && value.empty()); // empty value round-trips
}

} // namespace

void RunPreprocessCacheResourceTests()
{
    TestV2RoundTripSeedsBothStages();
    TestV1BufferStillSeeds();
    TestBadMagicIsNoOp();
    TestUnknownVersionIsNoOp();
    TestTruncatedHeaderIsNoOp();
    TestTruncatedEntryStreamKeepsPartialSeed();
    TestUnknownStageTagStopsAndKeepsPartialSeed();
    TestV2StageTagDoesNotLeakIntoValues();
}
