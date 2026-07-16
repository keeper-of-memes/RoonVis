#include "PreprocessCacheResource.h"

#include <cstring>

namespace RoonVis
{

void RvppAppendU32(std::string& out, uint32_t v)
{
    out.push_back(static_cast<char>(v & 0xFF));
    out.push_back(static_cast<char>((v >> 8) & 0xFF));
    out.push_back(static_cast<char>((v >> 16) & 0xFF));
    out.push_back(static_cast<char>((v >> 24) & 0xFF));
}

void RvppAppendLenPrefixed(std::string& out, const std::string& s)
{
    RvppAppendU32(out, static_cast<uint32_t>(s.size()));
    out.append(s);
}

void RvppAppendHeader(std::string& out, uint32_t version, const std::string& salt, uint32_t entryCount)
{
    out.append("RVPP", 4);
    RvppAppendU32(out, version);
    RvppAppendLenPrefixed(out, salt);
    RvppAppendU32(out, entryCount);
}

void RvppAppendEntryV1(std::string& out, const std::string& key, const std::string& value)
{
    RvppAppendLenPrefixed(out, key);
    RvppAppendLenPrefixed(out, value);
}

void RvppAppendEntryV2(std::string& out, uint8_t stage, const std::string& key, const std::string& value)
{
    out.push_back(static_cast<char>(stage));
    RvppAppendLenPrefixed(out, key);
    RvppAppendLenPrefixed(out, value);
}

RvppSeedResult SeedPreprocessCacheFromRvppBuffer(const uint8_t* bytes, size_t size, PreprocessCache& cache)
{
    RvppSeedResult result;
    size_t off = 0;

    auto readU32 = [&](uint32_t& out) -> bool {
        if (bytes == nullptr || off + 4 > size)
        {
            return false;
        }
        out = static_cast<uint32_t>(bytes[off]) |
              (static_cast<uint32_t>(bytes[off + 1]) << 8) |
              (static_cast<uint32_t>(bytes[off + 2]) << 16) |
              (static_cast<uint32_t>(bytes[off + 3]) << 24);
        off += 4;
        return true;
    };
    auto readStr = [&](std::string& out) -> bool {
        uint32_t len = 0;
        if (!readU32(len) || off + len > size)
        {
            return false;
        }
        out.assign(reinterpret_cast<const char*>(bytes + off), len);
        off += len;
        return true;
    };

    if (bytes == nullptr || size < 4 || std::memcmp(bytes, "RVPP", 4) != 0)
    {
        result.error = "bad magic";
        return result;
    }
    off = 4;
    if (!readU32(result.version))
    {
        result.error = "truncated header";
        return result;
    }
    if (result.version != kRvppVersion1 && result.version != kRvppVersion2)
    {
        result.error = "unsupported version";
        return result;
    }
    uint32_t entryCount = 0;
    if (!readStr(result.salt) || !readU32(entryCount))
    {
        result.error = "truncated header";
        return result;
    }

    // Guarantee no seed can be evicted by later runtime Puts.
    cache.EnsureCapacity(static_cast<size_t>(entryCount) + 64);
    result.ok = true;

    for (uint32_t i = 0; i < entryCount; ++i)
    {
        uint8_t stage = kRvppStagePreprocess;
        if (result.version == kRvppVersion2)
        {
            if (off + 1 > size)
            {
                result.truncated = true;
                result.error = "truncated entry stream";
                break;
            }
            stage = bytes[off];
            ++off;
            if (stage != kRvppStagePreprocess && stage != kRvppStageParseGen)
            {
                // Unknown stage tag: the record length is unknowable, so stop here and
                // keep what was seeded (forgiving, staleness-safe semantics).
                result.truncated = true;
                result.error = "unknown stage tag";
                break;
            }
        }

        std::string key;
        std::string value;
        if (!readStr(key) || !readStr(value))
        {
            result.truncated = true;
            result.error = "truncated entry stream";
            break;
        }

        cache.Seed(key, std::move(value));
        if (stage == kRvppStageParseGen)
        {
            ++result.parseGenEntries;
        }
        else
        {
            ++result.preprocessEntries;
        }
    }

    return result;
}

}  // namespace RoonVis
