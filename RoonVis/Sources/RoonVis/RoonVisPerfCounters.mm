#import "RoonVisPerfCounters.h"

#include <atomic>
#include <cmath>
#include <cstdint>
#include <limits>

namespace
{
std::atomic<uint64_t> gShelvesRecomputeCount{0};
std::atomic<uint64_t> gShelvesRecomputeMicros{0};
std::atomic<uint64_t> gThumbnailBundleHits{0};
std::atomic<uint64_t> gThumbnailDiskHits{0};
std::atomic<uint64_t> gThumbnailLiveRenders{0};
std::atomic<uint64_t> gThumbnailLiveMicros{0};
std::atomic<uint64_t> gWarmActivationHits{0};
std::atomic<uint64_t> gWarmActivationColdMisses{0};
std::atomic<uint64_t> gWarmActivationColdLoadMicros{0};
std::atomic<uint64_t> gWarmStagePrimaryPreloadMicros{0};
std::atomic<uint64_t> gFrameIntervalGt50{0};
std::atomic<uint64_t> gFrameIntervalGt200{0};
#if defined(NDEBUG)
std::atomic<bool> gCountersEnabled{false};
#else
std::atomic<bool> gCountersEnabled{true};
#endif

uint64_t MicrosForMilliseconds(double ms)
{
    if (!std::isfinite(ms) || ms <= 0.0)
    {
        return 0;
    }
    double micros = ms * 1000.0;
    if (micros >= static_cast<double>(std::numeric_limits<uint64_t>::max()))
    {
        return std::numeric_limits<uint64_t>::max();
    }
    return static_cast<uint64_t>(llround(micros));
}

double AverageMilliseconds(uint64_t totalMicros, uint64_t count)
{
    if (count == 0)
    {
        return 0.0;
    }
    return static_cast<double>(totalMicros) / static_cast<double>(count) / 1000.0;
}
}  // namespace

bool RoonVisPerfCountersEnabled(void)
{
    return gCountersEnabled.load(std::memory_order_relaxed);
}

void RoonVisPerfCountersSetEnabled(bool enabled)
{
    gCountersEnabled.store(enabled, std::memory_order_relaxed);
}

void RoonVisPerfCountShelvesRecompute(double ms)
{
    if (!RoonVisPerfCountersEnabled())
    {
        return;
    }
    gShelvesRecomputeCount.fetch_add(1, std::memory_order_relaxed);
    gShelvesRecomputeMicros.fetch_add(MicrosForMilliseconds(ms), std::memory_order_relaxed);
}

void RoonVisPerfCountThumbnail(int outcome, double ms)
{
    if (!RoonVisPerfCountersEnabled())
    {
        return;
    }

    switch (outcome)
    {
        case RoonVisPerfThumbnailOutcomeBundleHit:
            gThumbnailBundleHits.fetch_add(1, std::memory_order_relaxed);
            break;
        case RoonVisPerfThumbnailOutcomeDiskHit:
            gThumbnailDiskHits.fetch_add(1, std::memory_order_relaxed);
            break;
        case RoonVisPerfThumbnailOutcomeLiveRender:
            gThumbnailLiveRenders.fetch_add(1, std::memory_order_relaxed);
            gThumbnailLiveMicros.fetch_add(MicrosForMilliseconds(ms), std::memory_order_relaxed);
            break;
        default:
            break;
    }
}

void RoonVisPerfCountWarmActivation(bool warmHit, double loadMs)
{
    if (!RoonVisPerfCountersEnabled())
    {
        return;
    }

    if (warmHit)
    {
        gWarmActivationHits.fetch_add(1, std::memory_order_relaxed);
        return;
    }

    gWarmActivationColdMisses.fetch_add(1, std::memory_order_relaxed);
    gWarmActivationColdLoadMicros.fetch_add(MicrosForMilliseconds(loadMs), std::memory_order_relaxed);
}

void RoonVisPerfCountWarmStage(int stage, double ms)
{
    if (!RoonVisPerfCountersEnabled())
    {
        return;
    }

    uint64_t micros = MicrosForMilliseconds(ms);
    switch (stage)
    {
        case RoonVisPerfWarmStagePrimaryPreload:
            gWarmStagePrimaryPreloadMicros.fetch_add(micros, std::memory_order_relaxed);
            break;
        default:
            break;
    }
}

void RoonVisPerfCountFrameInterval(double intervalMs)
{
    if (!RoonVisPerfCountersEnabled())
    {
        return;
    }
    if (!std::isfinite(intervalMs))
    {
        return;
    }
    if (intervalMs > 50.0)
    {
        gFrameIntervalGt50.fetch_add(1, std::memory_order_relaxed);
    }
    if (intervalMs > 200.0)
    {
        gFrameIntervalGt200.fetch_add(1, std::memory_order_relaxed);
    }
}

NSString *RoonVisPerfCountersSummaryLine(void)
{
    uint64_t shelves = gShelvesRecomputeCount.load(std::memory_order_relaxed);
    uint64_t shelvesMicros = gShelvesRecomputeMicros.load(std::memory_order_relaxed);
    uint64_t thumbBundle = gThumbnailBundleHits.load(std::memory_order_relaxed);
    uint64_t thumbDisk = gThumbnailDiskHits.load(std::memory_order_relaxed);
    uint64_t thumbLive = gThumbnailLiveRenders.load(std::memory_order_relaxed);
    uint64_t thumbLiveMicros = gThumbnailLiveMicros.load(std::memory_order_relaxed);
    uint64_t warmHit = gWarmActivationHits.load(std::memory_order_relaxed);
    uint64_t coldMiss = gWarmActivationColdMisses.load(std::memory_order_relaxed);
    uint64_t coldLoadMicros = gWarmActivationColdLoadMicros.load(std::memory_order_relaxed);
    uint64_t primaryPreloadMicros = gWarmStagePrimaryPreloadMicros.load(std::memory_order_relaxed);
    uint64_t intervalGt50 = gFrameIntervalGt50.load(std::memory_order_relaxed);
    uint64_t intervalGt200 = gFrameIntervalGt200.load(std::memory_order_relaxed);

    return [NSString stringWithFormat:@"PerfCounters: shelvesRecompute=%llu avgMs=%.2f thumbBundle=%llu thumbDisk=%llu thumbLive=%llu avgLiveMs=%.2f warmHit=%llu coldMiss=%llu avgLoadMs=%.2f primaryPreloadMs=%.1f secondaryCreateMs=%.1f secondaryLoadMs=%.1f secondaryRenderMs=%.1f intervalGt50=%llu intervalGt200=%llu",
                                      static_cast<unsigned long long>(shelves),
                                      AverageMilliseconds(shelvesMicros, shelves),
                                      static_cast<unsigned long long>(thumbBundle),
                                      static_cast<unsigned long long>(thumbDisk),
                                      static_cast<unsigned long long>(thumbLive),
                                      AverageMilliseconds(thumbLiveMicros, thumbLive),
                                      static_cast<unsigned long long>(warmHit),
                                      static_cast<unsigned long long>(coldMiss),
                                      AverageMilliseconds(coldLoadMicros, coldMiss),
                                      static_cast<double>(primaryPreloadMicros) / 1000.0,
                                      // The secondary warm stages were removed; keep the
                                      // fields (always 0.0) for soak-log format stability.
                                      0.0,
                                      0.0,
                                      0.0,
                                      static_cast<unsigned long long>(intervalGt50),
                                      static_cast<unsigned long long>(intervalGt200)];
}
