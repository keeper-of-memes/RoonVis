#pragma once

#include "PreprocessCache.h"

#include <cstddef>
#include <cstdint>
#include <string>

namespace RoonVis
{

// RVPP: the little-endian binary container for the build-time prepopulated shader-cache
// resource (Resources/preprocess-cache/preprocess-cache.bin), written by the
// PreprocessCacheGen host tool and seeded into the runtime PreprocessCache at startup.
//
//   v1 (legacy):  "RVPP" · u32 version(=1) · u32 saltLen+salt · u32 entryCount ·
//                 (u32 keyLen+key · u32 valLen+val)*                 [all preprocess-stage]
//   v2 (Tier-1):  "RVPP" · u32 version(=2) · u32 saltLen+salt · u32 entryCount ·
//                 (u8 stage · u32 keyLen+key · u32 valLen+val)*
//                 stage 1 = preprocessed HLSL (key salt "pmpp-v1:")
//                 stage 2 = parse/generate GLSL (key salt "pmpp-parse-v1:")
//
// Keys are salt-disambiguated per stage, so both stages seed into the ONE PreprocessCache
// (single LRU map). Staleness is SAFE by construction: a stale entry (salt bump / preset
// edit / vendor change) simply never gets hit -> runtime falls back to live transpile. A
// missing / malformed / unknown-version file is a warn + no-op, never wrong.

inline constexpr uint32_t kRvppVersion1 = 1;
inline constexpr uint32_t kRvppVersion2 = 2;
inline constexpr uint8_t kRvppStagePreprocess = 1;
inline constexpr uint8_t kRvppStageParseGen = 2;

// --- Serialization (generator + tests) -------------------------------------------------

void RvppAppendU32(std::string& out, uint32_t v);
void RvppAppendLenPrefixed(std::string& out, const std::string& s);

// Header: magic + version + salt + entryCount. Works for v1 and v2 (same header layout).
void RvppAppendHeader(std::string& out, uint32_t version, const std::string& salt, uint32_t entryCount);

// v1 entry: key + value (implicitly preprocess-stage).
void RvppAppendEntryV1(std::string& out, const std::string& key, const std::string& value);

// v2 entry: stage tag byte + key + value.
void RvppAppendEntryV2(std::string& out, uint8_t stage, const std::string& key, const std::string& value);

// --- Seeding (app startup + tests) -----------------------------------------------------

struct RvppSeedResult
{
    bool ok{false};                //!< Header accepted and entries seeded (possibly truncated).
    bool truncated{false};         //!< Entry stream ended early / bad stage tag; partial seed kept.
    uint32_t version{0};
    std::string salt;
    size_t preprocessEntries{0};   //!< Stage-1 entries seeded.
    size_t parseGenEntries{0};     //!< Stage-2 entries seeded.
    const char* error{nullptr};    //!< Reason when !ok (static string), or truncation note.
};

// Parses an RVPP buffer (v1 or v2) and seeds every entry into `cache` via Seed(). Raises
// the cache capacity first (entryCount + headroom) so no seed can be evicted by later
// runtime Puts. Unknown version / bad magic / truncated header: returns ok=false and
// leaves the cache untouched. A truncated entry stream keeps what was seeded so far
// (ok=true, truncated=true) — same forgiving semantics the v1 in-app seeder had.
RvppSeedResult SeedPreprocessCacheFromRvppBuffer(const uint8_t* bytes, size_t size, PreprocessCache& cache);

}  // namespace RoonVis
