#import "ANGLEGLViewInternal.h"

#import "ProjectMBridgeInternal.h"
#import "RoonVisCrashReporter.h"
#import "RoonVisPerfCounters.h"
#import "RoonVisPerfDiagnosticsSink.h"

#import <EGL/eglext.h>

#include <algorithm>
#include <cstdio>
#include <float.h>
#include <math.h>

namespace
{
static constexpr CFTimeInterval kPerfDiagnosticsLogInterval = 5.0;

// PerfDiag file sink — mirrors the projectm-transition-profile.log pattern in
// ProjectMBridge.mm. Opened once (truncating, "w") on first use, then appended
// one PerfDiag line per ~5 s window. All access is on the main/GL thread (same
// thread that logs the PerfDiag line), so no additional locking is required.
static FILE *gPerfDiagnosticsLog = nullptr;
static BOOL gPerfDiagnosticsLogOpenAttempted = NO;

// The file sink is active when perf diagnostics is enabled (the PerfDiag line is
// only produced in that case) OR when ROONVIS_PERF_DIAG_FILE=1 is set.
static BOOL RoonVisPerfDiagnosticsFileEnvForced()
{
    NSString *envValue = NSProcessInfo.processInfo.environment[@"ROONVIS_PERF_DIAG_FILE"];
    if (envValue.length > 0)
    {
        return envValue.boolValue;
    }
    return NO;
}

// Returns the (lazily opened, truncated-at-launch) PerfDiag log file, or nullptr
// if unavailable. The single open-attempt guard ensures the file is truncated
// exactly once per process lifetime.
static FILE *RoonVisPerfDiagnosticsLogFile()
{
    if (gPerfDiagnosticsLogOpenAttempted)
    {
        return gPerfDiagnosticsLog;
    }
    gPerfDiagnosticsLogOpenAttempted = YES;

    NSArray<NSString *> *cacheDirectories = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString *cacheDirectory = cacheDirectories.firstObject;
    if (cacheDirectory.length == 0)
    {
        RoonVisLog(@"PerfDiag file sink unavailable: no Caches directory");
        return nullptr;
    }

    NSString *path = [cacheDirectory stringByAppendingPathComponent:@"perf-diagnostics.log"];
    gPerfDiagnosticsLog = fopen(path.fileSystemRepresentation, "w");
    if (gPerfDiagnosticsLog == nullptr)
    {
        RoonVisLog(@"PerfDiag file sink failed: %@", path);
        return nullptr;
    }

    RoonVisLog(@"PerfDiag file sink: %@", path);
    return gPerfDiagnosticsLog;
}

// Appends one PerfDiag line to the file sink, prefixed with a wall-clock epoch
// timestamp (ms) so runs can be segmented by elapsed time. Only writes when the
// sink gate is satisfied (perf diagnostics enabled OR the env override).
static void RoonVisAppendPerfDiagnosticsLine(NSString *line, BOOL perfDiagnosticsEnabled)
{
    if (!perfDiagnosticsEnabled && !RoonVisPerfDiagnosticsFileEnvForced())
    {
        return;
    }
    FILE *file = RoonVisPerfDiagnosticsLogFile();
    if (file == nullptr)
    {
        return;
    }
    double epochMs = [NSDate date].timeIntervalSince1970 * 1000.0;
    fprintf(file, "%.0f %s\n", epochMs, line.UTF8String);
    fflush(file);
}
static constexpr CFTimeInterval kCatastrophicPresetRenderSeconds = 0.5;
static constexpr CFTimeInterval kSlowPresetRenderSeconds = 0.08;
static constexpr NSUInteger kSlowPresetFrameSkipThreshold = 3;
static constexpr NSUInteger kTransitionDiagnosticFrames = 30;

static NSInteger RoonVisDisplayRefreshRate(UIView *view)
{
    UIScreen *screen = view.window.screen ?: UIScreen.mainScreen;
    NSInteger refreshRate = screen.maximumFramesPerSecond;
    return refreshRate > 0 ? refreshRate : 60;
}
}

// Exported wrapper over the file-static sink helper so other translation units
// (ProjectMBridge's FixedRotation resolve / Thermal breadcrumbs) can force-write
// campaign-critical lines exactly the way the CompatBurnIn lines below do
// (perfDiagnosticsEnabled=YES bypasses the enabled/env gate). Declared in
// RoonVisPerfDiagnosticsSink.h.
extern "C" void RoonVisPerfDiagnosticsSinkAppendLine(NSString *line)
{
    RoonVisAppendPerfDiagnosticsLine(line, YES);
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

@implementation ANGLEGLView (Diagnostics)

- (void)resetPerformanceDiagnostics
{
    _perfWindowStartTime = 0;
    _perfLastFrameStartTime = 0;
    _perfTotalFrameInterval = 0;
    _perfMinFrameInterval = DBL_MAX;
    _perfMaxFrameInterval = 0;
    _perfTotalRenderDuration = 0;
    _perfMaxRenderDuration = 0;
    _perfTotalSwapDuration = 0;
    _perfMaxSwapDuration = 0;
    _perfFrameIntervals = 0;
    _perfSuccessfulRenderedFrames = 0;
    _perfSkippedFrames = 0;
    _perfSwapFailures = 0;
    _perfMakeCurrentFailures = 0;
    _consecutiveSwapFailures = 0;
    _currentFrameInterval = 0;
    _diagnosticsFPS = 0.0;
    _diagnosticsFrameTimeMs = 0.0;
}

- (void)recordFrameStartForDiagnostics:(CFTimeInterval)frameStart
{
    if (!_perfDiagnosticsEnabled)
    {
        return;
    }

    if (_perfWindowStartTime <= 0)
    {
        _perfWindowStartTime = frameStart;
        _perfLastFrameStartTime = frameStart;
        return;
    }

    CFTimeInterval frameInterval = frameStart - _perfLastFrameStartTime;
    _currentFrameInterval = frameInterval;
    _perfLastFrameStartTime = frameStart;
    if (frameInterval > 0)
    {
        double interval = static_cast<double>(frameInterval);
        _perfTotalFrameInterval += interval;
        _perfMinFrameInterval = std::min(_perfMinFrameInterval, interval);
        _perfMaxFrameInterval = std::max(_perfMaxFrameInterval, interval);
        _perfFrameIntervals++;
        // Cumulative spike attribution (intervalGt50/intervalGt200 in the
        // PerfCounters summary line): same measured interval as the min/max above.
        RoonVisPerfCountFrameInterval(interval * 1000.0);
    }
}

- (void)logTransitionDiagnosticLine:(NSString *)format, ...
{
    va_list args;
    va_start(args, format);
    NSString *line = [[[NSString alloc] initWithFormat:format arguments:args] autorelease];
    va_end(args);

    NSLog(@"%@", line);
}

- (void)recordPresetChangeFrameWithInterval:(CFTimeInterval)frameInterval
                             renderDuration:(CFTimeInterval)renderDuration
                               swapDuration:(CFTimeInterval)swapDuration
{
    if (!_perfDiagnosticsEnabled)
    {
        return;
    }

    NSString *presetName = self.projectMBridge.confirmedPresetName ?: @"(none)";
    if (_lastDiagnosticPresetName == nil || ![_lastDiagnosticPresetName isEqualToString:presetName])
    {
        [_lastDiagnosticPresetName release];
        _lastDiagnosticPresetName = [presetName copy];
        _presetChangeDiagnosticFramesRemaining = kTransitionDiagnosticFrames;
        [self logTransitionDiagnosticLine:@"PerfDiagTransitionStart: preset=%@", presetName];
    }
    if (_presetChangeDiagnosticFramesRemaining == 0)
    {
        return;
    }

    NSUInteger frameNumber = kTransitionDiagnosticFrames - _presetChangeDiagnosticFramesRemaining + 1;
    [self logTransitionDiagnosticLine:@"PerfDiagTransitionFrame: frame=%lu interval=%.2fms render=%.2fms swap=%.2fms preset=%@",
                                  static_cast<unsigned long>(frameNumber),
                                  frameInterval * 1000.0,
                                  renderDuration * 1000.0,
                                  swapDuration * 1000.0,
                                  presetName];
    _presetChangeDiagnosticFramesRemaining--;
}

// Runs every successful frame regardless of _perfDiagnosticsEnabled, so the A/V
// latency lock is active in Release with the diagnostics overlay off. Accumulates
// render/swap cost over a window and, once per kPerfDiagnosticsLogInterval, trims the
// audio buffer so total A/V latency (buffer + render + swap + display) holds at the
// dialed-in target.
- (void)updateLatencyLockWithRender:(double)renderDuration swap:(double)swapDuration atTime:(CFTimeInterval)now
{
    if (_latencyLockWindowStartTime <= 0)
    {
        _latencyLockWindowStartTime = now;
    }
    _latencyLockTotalRenderDuration += renderDuration;
    _latencyLockTotalSwapDuration += swapDuration;
    _latencyLockFrames++;

    if (now - _latencyLockWindowStartTime < kPerfDiagnosticsLogInterval || _latencyLockFrames == 0)
    {
        return;
    }

    // Sync calibration: keep ACCUMULATING (the save path reads the running
    // averages) but never apply trims - the effective delay is pinned to the
    // user's draft for the whole session. The window also does not reset, so
    // a save N seconds in sees exactly the frames since it last reset.
    if (self.projectMBridge.syncCalibrationActive)
    {
        return;
    }

    double avgRenderMs = (_latencyLockTotalRenderDuration / _latencyLockFrames) * 1000.0;
    double avgSwapMs = (_latencyLockTotalSwapDuration / _latencyLockFrames) * 1000.0;
    // Trim the buffer by render/swap's excess over a nominal baseline so total holds at
    // (target + kNominalRenderMs + display) regardless of render time — the dialed-in
    // Roon offset stays valid. Adapt on the smoothed window average so transient
    // per-switch spikes are absorbed, not chased. Never grow past the user target,
    // never shrink below a jitter-cushion floor.
    static const double kNominalRenderMs = 5.0;
    static const double kMinAdaptiveBufferMs = 100.0;
    NSInteger targetBufferMs = self.projectMBridge.audioInputDelayMs + self.projectMBridge.syncRenderCompensationMs;
    double desiredBufferMs = static_cast<double>(targetBufferMs) + kNominalRenderMs - avgRenderMs - avgSwapMs;
    NSInteger effectiveBufferMs = static_cast<NSInteger>(llround(
        MAX(kMinAdaptiveBufferMs, MIN(static_cast<double>(targetBufferMs), desiredBufferMs))));
    NSInteger before = self.projectMBridge.effectiveAudioDelayMs;
    [self.projectMBridge setEffectiveAudioDelayMs:effectiveBufferMs];
    NSInteger after = self.projectMBridge.effectiveAudioDelayMs;
    // Log every change; also log the first window unconditionally so the lock is
    // observably active in Release/diagnostics-off even when render is cheap enough
    // that no trim is needed (effective == target).
    if (after != before || !_latencyLockDidLogFirstWindow)
    {
        _latencyLockDidLogFirstWindow = YES;
        RoonVisLog(@"A/V latency lock: effective audio delay %ld -> %ld ms (render avg %.2fms swap avg %.2fms target %ldms)",
                   static_cast<long>(before), static_cast<long>(after), avgRenderMs, avgSwapMs, static_cast<long>(targetBufferMs));
    }

    _latencyLockWindowStartTime = 0;
    _latencyLockTotalRenderDuration = 0;
    _latencyLockTotalSwapDuration = 0;
    _latencyLockFrames = 0;
}

// Running (partial-window) latency-lock averages for the sync-calibration save
// path, plus a reset so the first post-save trim starts a clean window.
- (void)readLatencyLockRunningAveragesRenderMs:(double *)renderMs swapMs:(double *)swapMs
{
    const double frames = _latencyLockFrames > 0 ? static_cast<double>(_latencyLockFrames) : 0.0;
    *renderMs = frames > 0 ? (_latencyLockTotalRenderDuration / frames) * 1000.0 : 0.0;
    *swapMs = frames > 0 ? (_latencyLockTotalSwapDuration / frames) * 1000.0 : 0.0;
}

- (void)resetLatencyLockWindow
{
    _latencyLockWindowStartTime = 0;
    _latencyLockTotalRenderDuration = 0;
    _latencyLockTotalSwapDuration = 0;
    _latencyLockFrames = 0;
}

- (void)logPerformanceDiagnosticsIfNeededAtTime:(CFTimeInterval)now
{
    if (!_perfDiagnosticsEnabled || _perfWindowStartTime <= 0)
    {
        return;
    }

    CFTimeInterval elapsed = now - _perfWindowStartTime;
    if (elapsed < kPerfDiagnosticsLogInterval)
    {
        return;
    }

    double avgFps = elapsed > 0 ? _perfSuccessfulRenderedFrames / static_cast<double>(elapsed) : 0.0;
    double avgFrameMs = _perfFrameIntervals > 0 ? (_perfTotalFrameInterval / _perfFrameIntervals) * 1000.0 : 0.0;
    double minFrameMs = _perfMinFrameInterval == DBL_MAX ? 0.0 : _perfMinFrameInterval * 1000.0;
    double maxFrameMs = _perfMaxFrameInterval * 1000.0;
    double avgRenderMs = _perfSuccessfulRenderedFrames > 0 ? (_perfTotalRenderDuration / _perfSuccessfulRenderedFrames) * 1000.0 : 0.0;
    double avgSwapMs = _perfSuccessfulRenderedFrames > 0 ? (_perfTotalSwapDuration / _perfSuccessfulRenderedFrames) * 1000.0 : 0.0;
    double displayLatencyMs = 1000.0 / static_cast<double>(RoonVisDisplayRefreshRate(self));
    // The A/V latency lock now runs unconditionally in
    // -updateLatencyLockWithRender:swap:atTime: (active in Release with diagnostics
    // off); here we only read the current effective delay for the diagnostics line.
    NSInteger audioInputDelayMs = self.projectMBridge.effectiveAudioDelayMs;
    double totalSoftwareLatencyMs = static_cast<double>(audioInputDelayMs) + avgRenderMs + avgSwapMs + displayLatencyMs;
    NSString *confirmedPreset = self.projectMBridge.confirmedPresetName ?: @"(none)";
    NSString *requestedPreset = self.projectMBridge.requestedPresetName ?: @"(none)";
    EGLint programCacheEntries = _angleProgramCacheControlAvailable ? eglProgramCacheGetAttribANGLE(self.eglDisplay, EGL_PROGRAM_CACHE_SIZE_ANGLE) : -1;
    _diagnosticsFPS = avgFps;
    _diagnosticsFrameTimeMs = avgRenderMs;
    NSString *perfDiagLine = [NSString stringWithFormat:@"PerfDiag: fps=%.1f successful=%lu skipped=%lu interval avg/min/max=%.2f/%.2f/%.2fms render avg/max=%.2f/%.2fms swap avg/max=%.2f/%.2fms AVLatency: buffer=%ldms render=%.2fms swap=%.2fms display=%.2fms total=%.2fms (+TV panel lag, measure externally) swapFailures=%lu makeCurrentFailures=%lu programCacheEntries=%d transpileCache=%lu/%lu preset confirmed=%@ requested=%@",
          avgFps,
          static_cast<unsigned long>(_perfSuccessfulRenderedFrames),
          static_cast<unsigned long>(_perfSkippedFrames),
          avgFrameMs,
          minFrameMs,
          maxFrameMs,
          avgRenderMs,
          _perfMaxRenderDuration * 1000.0,
          avgSwapMs,
          _perfMaxSwapDuration * 1000.0,
          static_cast<long>(audioInputDelayMs),
          avgRenderMs,
          avgSwapMs,
          displayLatencyMs,
          totalSoftwareLatencyMs,
          static_cast<unsigned long>(_perfSwapFailures),
          static_cast<unsigned long>(_perfMakeCurrentFailures),
          programCacheEntries,
          static_cast<unsigned long>(self.projectMBridge.transpileCacheHits),
          static_cast<unsigned long>(self.projectMBridge.transpileCacheMisses),
          confirmedPreset,
          requestedPreset];
    NSLog(@"%@", perfDiagLine);
    RoonVisAppendPerfDiagnosticsLine(perfDiagLine, _perfDiagnosticsEnabled);
    RoonVisAppendPerfDiagnosticsLine(RoonVisPerfCountersSummaryLine(), _perfDiagnosticsEnabled);
    [self resetPerformanceDiagnostics];
    _diagnosticsFPS = avgFps;
    _diagnosticsFrameTimeMs = avgRenderMs;
}

// Compat burn-in ground truth (Phase 4 of the compat scan): one line per
// preset at dwell end with the max render time seen, so predictions can be
// joined against real outcomes. PerfDiag's 5-second windows cannot provide
// this. Diagnostic builds only; enabled via ROONVIS_COMPAT_BURNIN=1. Presets
// that never confirm produce NO line - the join script counts absence as
// loadFail (the same absence rule the original HD burn-in used).
#if ROONVIS_ENABLE_DIAGNOSTIC_MODES
static BOOL RoonVisCompatBurnInEnabled()
{
    static BOOL enabled = NSProcessInfo.processInfo.environment[@"ROONVIS_COMPAT_BURNIN"].boolValue;
    return enabled;
}

// W2 steady-state extension (ROONVIS_COMPAT_BURNIN_STEADY, requires COMPAT_BURNIN):
// per-preset render-time DISTRIBUTION over the settled window (first
// kCompatSteadySettleSeconds of each dwell skipped — that window holds the one-time
// shader-compile spike that the plain maxRenderMs outcome is dominated by). The D1
// ship gate (p95 <= budget, over-budget rate, sample floor) is applied OFFLINE by
// the join script; the app only reports evidence. File-static rather than ivars:
// diagnostics-only mode, exactly one ANGLEGLView instance exists (composition
// root), and the per-dwell Reset makes any theoretical stale state self-correct
// after one preset switch.
static BOOL RoonVisCompatBurnInSteadyEnabled()
{
    static BOOL enabled =
        NSProcessInfo.processInfo.environment[@"ROONVIS_COMPAT_BURNIN_STEADY"].boolValue;
    return enabled;
}

namespace
{
constexpr double kCompatSteadySettleSeconds = 3.0;
// 1 ms bins; the last bin absorbs everything >= (kCompatSteadyBinCount-1) ms. A
// 511 ms+ settled frame is far past catastrophic, so overflow precision is moot.
constexpr size_t kCompatSteadyBinCount = 512;

struct CompatSteadyStats
{
    uint32_t bins[kCompatSteadyBinCount];
    uint32_t samples;
    uint32_t overBudget; // settled frames > 1x frame budget
    uint32_t over2x;     // settled frames > the slow threshold (2x frame, >=80ms floor)
    double maxSeconds;
    CFTimeInterval dwellStart;

    void Reset(CFTimeInterval now)
    {
        memset(bins, 0, sizeof(bins));
        samples = 0;
        overBudget = 0;
        over2x = 0;
        maxSeconds = 0.0;
        dwellStart = now;
    }

    void Record(double seconds, double budgetSeconds, double slowSeconds)
    {
        size_t bin = static_cast<size_t>(seconds * 1000.0);
        bin = std::min(bin, kCompatSteadyBinCount - 1);
        bins[bin]++;
        samples++;
        if (seconds > budgetSeconds)
        {
            overBudget++;
        }
        if (seconds > slowSeconds)
        {
            over2x++;
        }
        maxSeconds = std::max(maxSeconds, seconds);
    }

    // q in (0,1]; returns the bin upper edge in ms of the ceil(q*samples)-th
    // ordered sample (1 ms resolution — ample for a 40 ms budget gate).
    double PercentileMs(double q) const
    {
        if (samples == 0)
        {
            return 0.0;
        }
        const uint64_t rank = static_cast<uint64_t>(std::ceil(q * samples));
        uint64_t seen = 0;
        for (size_t i = 0; i < kCompatSteadyBinCount; i++)
        {
            seen += bins[i];
            if (seen >= rank)
            {
                return static_cast<double>(i + 1);
            }
        }
        return static_cast<double>(kCompatSteadyBinCount);
    }
};

CompatSteadyStats gCompatSteady; // zero-initialized (static storage)
} // namespace
#endif

- (void)recordCompatBurnInPreset:(NSString *)presetName renderDuration:(CFTimeInterval)renderDuration slowThreshold:(CFTimeInterval)slowThresholdSeconds frameBudget:(CFTimeInterval)frameBudgetSeconds
{
#if ROONVIS_ENABLE_DIAGNOSTIC_MODES
    if (!RoonVisCompatBurnInEnabled() || presetName.length == 0)
    {
        return;
    }
    const CFTimeInterval now = CACurrentMediaTime();
    if (_compatBurnInPresetName != nil && ![_compatBurnInPresetName isEqualToString:presetName])
    {
        const char *outcome = "pass";
        if (_compatBurnInMaxRenderSeconds >= kCatastrophicPresetRenderSeconds)
        {
            outcome = "catastrophic";
        }
        else if (_compatBurnInMaxRenderSeconds > slowThresholdSeconds)
        {
            outcome = "slow";
        }
        RoonVisAppendPerfDiagnosticsLine(
            [NSString stringWithFormat:@"CompatBurnIn: preset=%@ maxRenderMs=%.1f outcome=%s audio=%s",
                                       _compatBurnInPresetName,
                                       _compatBurnInMaxRenderSeconds * 1000.0, outcome,
                                       self.projectMBridge.isLivePCMActive ? "live" : "wav"],
            YES);
        if (RoonVisCompatBurnInSteadyEnabled())
        {
            // Settled-window distribution for the outgoing preset. samples=0 means
            // the dwell never outlived the settle skip - the join script treats
            // that as insufficient evidence, never as a pass.
            RoonVisAppendPerfDiagnosticsLine(
                [NSString stringWithFormat:
                              @"CompatBurnInSteady: preset=%@ samples=%u p50Ms=%.0f p95Ms=%.0f "
                              @"p99Ms=%.0f maxMs=%.1f overBudget=%u over2x=%u budgetMs=%.1f",
                              _compatBurnInPresetName,
                              gCompatSteady.samples,
                              gCompatSteady.PercentileMs(0.50),
                              gCompatSteady.PercentileMs(0.95),
                              gCompatSteady.PercentileMs(0.99),
                              gCompatSteady.maxSeconds * 1000.0,
                              gCompatSteady.overBudget,
                              gCompatSteady.over2x,
                              frameBudgetSeconds * 1000.0],
                YES);
        }
        _compatBurnInMaxRenderSeconds = 0;
    }
    if (_compatBurnInPresetName == nil || ![_compatBurnInPresetName isEqualToString:presetName])
    {
        [_compatBurnInPresetName release];
        _compatBurnInPresetName = [presetName copy];
        _compatBurnInMaxRenderSeconds = 0;
        gCompatSteady.Reset(now);
    }
    _compatBurnInMaxRenderSeconds = MAX(_compatBurnInMaxRenderSeconds, renderDuration);
    if (RoonVisCompatBurnInSteadyEnabled() &&
        (now - gCompatSteady.dwellStart) >= kCompatSteadySettleSeconds)
    {
        gCompatSteady.Record(renderDuration, frameBudgetSeconds, slowThresholdSeconds);
    }
#else
    (void)presetName;
    (void)renderDuration;
    (void)slowThresholdSeconds;
    (void)frameBudgetSeconds;
#endif
}

// Live HUD sampler (RC feedback): runs unconditionally per completed frame on
// the GL thread. The old HUD read the 5s diagnostics window, so after toggling
// the overlay it showed 0 for up to 5s and then a 5s-stale average - "the fps
// counter doesn't work". This path is window-free.
- (void)recordHUDFrameAtTime:(CFTimeInterval)now renderedFrame:(BOOL)rendered
{
    _hudFrameCount++;
    if (_hudSampleStartTime <= 0)
    {
        _hudSampleStartTime = now;
    }
    const NSInteger effectiveRate = RoonVisEffectiveFrameRate(self);
    const CFTimeInterval target = effectiveRate > 0 ? 1.0 / static_cast<CFTimeInterval>(effectiveRate) : 1.0 / 60.0;
    if (_hudLastFrameTime > 0)
    {
        const CFTimeInterval interval = now - _hudLastFrameTime;
        if (!rendered || interval > target * 1.5)
        {
            _hudDroppedFrames++;
        }
    }
    _hudLastFrameTime = now;
    const NSInteger presetIndex = self.projectMBridge.currentPresetIndex;
    if (presetIndex != _hudDropPresetIndex)
    {
        _hudDropPresetIndex = presetIndex;
        _hudDroppedFrames = 0;
    }
}

- (double)hudCurrentFPS
{
    const CFTimeInterval now = CACurrentMediaTime();
    const CFTimeInterval elapsed = now - _hudSampleStartTime;
    if (_hudSampleStartTime <= 0 || elapsed <= 0)
    {
        return 0.0;
    }
    const double fps = static_cast<double>(_hudFrameCount) / elapsed;
    _hudFrameCount = 0;
    _hudSampleStartTime = now;
    return fps;
}

- (NSUInteger)droppedFramesSincePresetChange
{
    return _hudDroppedFrames;
}

- (void)recordPresetRenderDuration:(CFTimeInterval)renderDuration
{
    // Scale the slow threshold with the capped frame rate: 80 ms is ~5 frames
    // at 60 fps but only 2 at 25 fps, so a fixed threshold over-triggers under
    // low caps. Two missed frame periods is the equivalent yardstick.
    const NSInteger effectiveFrameRate = RoonVisEffectiveFrameRate(self);
    const CFTimeInterval frameDuration = effectiveFrameRate > 0 ? 1.0 / static_cast<CFTimeInterval>(effectiveFrameRate) : 1.0 / 60.0;
    const CFTimeInterval slowThresholdSeconds = MAX(kSlowPresetRenderSeconds, 2.0 * frameDuration);
    NSString *presetName = self.projectMBridge.confirmedPresetName ?: self.projectMBridge.requestedPresetName ?: @"";
    [self recordCompatBurnInPreset:presetName renderDuration:renderDuration slowThreshold:slowThresholdSeconds frameBudget:frameDuration];
    if ([self.projectMBridge consumeWarmedFirstActivationForPresetName:presetName])
    {
        _slowPresetFrameCount = 0;
        [_slowPresetName release];
        _slowPresetName = nil;
        [self logTransitionDiagnosticLine:@"PerfDiagTransitionWarmFirstFrameIgnored: preset=%@ render=%.1fms",
                                      presetName,
                                      renderDuration * 1000.0];
        return;
    }
    if (presetName.length == 0 || renderDuration <= slowThresholdSeconds)
    {
        _slowPresetFrameCount = 0;
        [_slowPresetName release];
        _slowPresetName = nil;
        return;
    }

    if (_slowPresetName == nil || ![_slowPresetName isEqualToString:presetName])
    {
        [_slowPresetName release];
        _slowPresetName = [presetName copy];
        _slowPresetFrameCount = 0;
    }
    _slowPresetFrameCount++;

    BOOL catastrophic = renderDuration >= kCatastrophicPresetRenderSeconds;
    if (!catastrophic && _slowPresetFrameCount < kSlowPresetFrameSkipThreshold)
    {
        return;
    }

    if (_disableSlowPresetSkip)
    {
        [_wouldSkipSlowPresetNames addObject:presetName];
        [self logTransitionDiagnosticLine:@"PerfDiagTransitionWouldSkipSlowPreset: preset=%@ render=%.1fms slowFrames=%lu autoSkip=disabled",
                                          presetName,
                                          renderDuration * 1000.0,
                                          static_cast<unsigned long>(_slowPresetFrameCount)];
        _slowPresetFrameCount = 0;
        [_slowPresetName release];
        _slowPresetName = nil;
        return;
    }
    NSLog(@"ProjectM hardening: skipping slow preset %@ render=%.1fms slowFrames=%lu",
          presetName,
          renderDuration * 1000.0,
          static_cast<unsigned long>(_slowPresetFrameCount));
    [self.projectMBridge markPresetNameSlow:presetName catastrophic:catastrophic];
    [self.projectMBridge selectNextPresetSmooth:NO];
    _slowPresetFrameCount = 0;
    [_slowPresetName release];
    _slowPresetName = nil;
}


@end

#pragma clang diagnostic pop
