#include "PresetRotationCursor.h"

#include <algorithm>
#include <cstdint>
#include <cstdio>

namespace RoonVis
{

namespace
{

// First eligible entry scanning forward from `start` (inclusive), wrapping.
// Returns order.size() when everything is excluded.
size_t FirstEligibleFrom(const std::vector<size_t> &order,
                         size_t start,
                         long step,
                         const std::function<bool(size_t)> &excluded)
{
    const size_t n = order.size();
    size_t position = start % n;
    for (size_t scanned = 0; scanned < n; scanned++)
    {
        if (!excluded(order[position]))
        {
            return position;
        }
        position = step < 0 ? (position + n - 1) % n : (position + 1) % n;
    }
    return n;
}

} // namespace

RotationAdvanceResult AdvanceRotationCursor(const std::vector<size_t> &order,
                                            size_t anchorIndex,
                                            long offset,
                                            const std::function<bool(size_t)> &excluded)
{
    RotationAdvanceResult result;
    const size_t n = order.size();
    if (n == 0)
    {
        return result;
    }

    // Locate the anchor in the full order (it may itself be excluded; that is
    // fine and expected right after a hide/slow-mark on the active preset).
    size_t anchorPosition = n;
    for (size_t position = 0; position < n; position++)
    {
        if (order[position] == anchorIndex)
        {
            anchorPosition = position;
            break;
        }
    }

    if (anchorPosition == n)
    {
        // Anchor left the pack entirely: degrade to first/last eligible.
        const size_t start = offset < 0 ? n - 1 : 0;
        const size_t position = FirstEligibleFrom(order, start, offset < 0 ? -1 : 1, excluded);
        if (position == n)
        {
            return result;
        }
        result.valid = true;
        result.index = order[position];
        return result;
    }

    if (offset == 0)
    {
        // The anchor itself when eligible, else the next eligible forward.
        const size_t position = FirstEligibleFrom(order, anchorPosition, 1, excluded);
        if (position == n)
        {
            return result;
        }
        result.valid = true;
        result.index = order[position];
        return result;
    }

    // Walk |offset| ELIGIBLE steps from the anchor's order position. Each raw
    // step moves one order slot; only landing on a non-excluded entry consumes
    // an eligible step. A full lap with no eligible entry -> invalid.
    const long step = offset < 0 ? -1 : 1;
    long remaining = offset < 0 ? -offset : offset;
    size_t position = anchorPosition;
    size_t rawSteps = 0;
    const size_t maxRawSteps = n * static_cast<size_t>(remaining) + n; // generous lap bound
    while (remaining > 0 && rawSteps <= maxRawSteps)
    {
        position = step < 0 ? (position + n - 1) % n : (position + 1) % n;
        rawSteps++;
        if (!excluded(order[position]))
        {
            remaining--;
        }
        else if (rawSteps >= n && remaining == (offset < 0 ? -offset : offset))
        {
            // One full lap without a single eligible entry.
            return result;
        }
    }
    if (remaining > 0)
    {
        return result;
    }
    result.valid = true;
    result.index = order[position];
    return result;
}

namespace
{

uint64_t Fnv1a64Accumulate(uint64_t hash, const std::string &data)
{
    constexpr uint64_t prime = 1099511628211ull;
    for (const char c : data)
    {
        hash ^= static_cast<uint64_t>(static_cast<unsigned char>(c));
        hash *= prime;
    }
    // Separator so {"ab","c"} and {"a","bc"} differ.
    hash ^= 0x1f;
    hash *= prime;
    return hash;
}

} // namespace

std::string ShuffleOrderFingerprint(const std::vector<std::string> &packFilenames,
                                    const std::vector<std::string> &learnedSlowConfirmed)
{
    std::vector<std::string> pack = packFilenames;
    std::vector<std::string> slow = learnedSlowConfirmed;
    std::sort(pack.begin(), pack.end());
    std::sort(slow.begin(), slow.end());

    uint64_t hash = 14695981039346656037ull;
    for (const std::string &name : pack)
    {
        hash = Fnv1a64Accumulate(hash, name);
    }
    hash = Fnv1a64Accumulate(hash, "|learned-slow|");
    for (const std::string &name : slow)
    {
        hash = Fnv1a64Accumulate(hash, name);
    }

    char buffer[24];
    std::snprintf(buffer, sizeof(buffer), "sfp1-%016llx", static_cast<unsigned long long>(hash));
    return std::string(buffer);
}

std::vector<size_t> RestoreShuffleOrder(const std::vector<std::string> &storedOrder,
                                        const std::function<size_t(const std::string &)> &indexForFilename)
{
    std::vector<size_t> order;
    order.reserve(storedOrder.size());
    for (const std::string &filename : storedOrder)
    {
        const size_t index = indexForFilename(filename);
        if (index != SIZE_MAX)
        {
            order.push_back(index);
        }
    }
    return order;
}

} // namespace RoonVis
