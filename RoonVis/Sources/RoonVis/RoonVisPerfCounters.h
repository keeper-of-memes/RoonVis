#pragma once

#import <Foundation/Foundation.h>

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

enum
{
    RoonVisPerfThumbnailOutcomeBundleHit = 0,
    RoonVisPerfThumbnailOutcomeDiskHit = 1,
    RoonVisPerfThumbnailOutcomeLiveRender = 2,
};

// Warm-path stages whose main-thread block time is attributed cumulatively in the
// PerfCounters summary line. Only the primary preload remains (the secondary 64x64 warm
// instance was removed); the summary line still prints secondary*Ms=0.0 fields so soak
// logs stay format-compatible with earlier runs.
enum
{
    RoonVisPerfWarmStagePrimaryPreload = 0,
};

bool RoonVisPerfCountersEnabled(void);
void RoonVisPerfCountersSetEnabled(bool enabled);
void RoonVisPerfCountShelvesRecompute(double ms);
void RoonVisPerfCountThumbnail(int outcome, double ms);
void RoonVisPerfCountWarmActivation(bool warmHit, double loadMs);
// Adds one warm-stage attempt's main-thread block duration (ms) to the cumulative
// per-stage totals. `stage` is one of RoonVisPerfWarmStage*.
void RoonVisPerfCountWarmStage(int stage, double ms);
// Records one measured frame interval (ms); counts spikes >50ms and >200ms
// (a >200ms frame increments both counters).
void RoonVisPerfCountFrameInterval(double intervalMs);
NSString *RoonVisPerfCountersSummaryLine(void);

#ifdef __cplusplus
}
#endif
