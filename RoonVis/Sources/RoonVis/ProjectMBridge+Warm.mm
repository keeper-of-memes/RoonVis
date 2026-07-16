#import "ProjectMBridgeInternal.h"

#import "ProjectMPresetSupport.h"
#import "RoonVisCrashReporter.h"
#import "RoonVisDeviceTier.h"
#import "RoonVisPerfCounters.h"

#include <map>

@interface ProjectMBridge (PresetDisplayNamePrivate)
- (NSString *)presetDisplayNameForPath:(const std::string &)path;
@end

@interface ProjectMBridge (DwellPlanPrivate)
// Compute one dwell plan with the given settle/lead constants, porting the perf-sweep /
// crasher-scan overrides that used to live inside canWarmPresetAtTime into the smoothWindow
// and rotationInterval fed to the pure ComputeDwellPlan core (so ROONVIS perf-sweep /
// crasher-scan burn-ins still exercise their short timings).
- (RoonVis::PresetDwellPlan)computeDwellPlanWithSettleSeconds:(CFTimeInterval)settleSeconds
                                              minLeadSeconds:(CFTimeInterval)minLeadSeconds
                                                      atTime:(CFTimeInterval)now;
@end

namespace
{
// Wait this long AFTER the active crossfade before preloading the next preset. The
// render-loop idle budget is the primary hitch guard; this short settle keeps warming
// out of the double-render transition itself while giving the preload more of the
// rotation interval to finish before the next switch.
static constexpr CFTimeInterval kPresetPreloadPostTransitionSettleSeconds = 2.0;
// Require at least this much lead between the preload point and the next scheduled
// switch; if the rotation interval is too short to fit a budgeted preload with margin,
// skip preloading and let the normal load path handle that switch.
static constexpr CFTimeInterval kPresetPreloadMinLeadSeconds = 2.0;
// The legacy direct preload path runs before rendering, outside the after-frame idle
// budget. Keep its conservative timing so warm-cache-off behavior and hitch risk do not
// change; the earlier timing above is only for the budget-gated retained warm cache.
static constexpr CFTimeInterval kPresetDirectPreloadPostTransitionSettleSeconds = 12.0;
static constexpr CFTimeInterval kPresetDirectPreloadMinLeadSeconds = 5.0;
// Runtime-learned slow presets, persisted across launches (additive to the static
// compiled/JSON PresetBlocklist). `Learned` = confirmed, excluded from rotation on every
// launch. `Pending` = per-preset non-catastrophic detection counts backing the
// over-exclusion guard (promote at kLearnedSlowDetectionThreshold). `Clear` is a startup
// escape hatch that wipes the learned list.
static NSString *const kLearnedSlowPresetsKey = @"RoonVisLearnedSlowPresets";
static NSString *const kLearnedSlowPendingCountsKey = @"RoonVisSlowPresetPendingCounts";
static NSString *const kLearnedSlowHDSeedAppliedKey = @"RoonVisLearnedSlowHDSeedApplied";
static NSString *const kClearLearnedSlowPresetsKey = @"RoonVisClearLearnedSlowPresets";
}  // namespace

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

@implementation ProjectMBridge (Warm)

- (void)loadLearnedSlowPresets
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    // Escape hatch: wipe the learned list on request (set the key, relaunch once).
    if ([defaults boolForKey:kClearLearnedSlowPresetsKey])
    {
        [defaults removeObjectForKey:kLearnedSlowPresetsKey];
        [defaults removeObjectForKey:kLearnedSlowPendingCountsKey];
        [defaults removeObjectForKey:kLearnedSlowHDSeedAppliedKey];
        [defaults setBool:NO forKey:kClearLearnedSlowPresetsKey];
        [defaults synchronize];
        _learnedSlowStore.Clear();
        RoonVisLog(@"ProjectM hardening: cleared learned-slow preset list on request");
        return;
    }

    std::vector<std::string> confirmed;
    for (id obj in [defaults arrayForKey:kLearnedSlowPresetsKey])
    {
        if (![obj isKindOfClass:[NSString class]])
        {
            continue;
        }
        const char *cname = [(NSString *)obj fileSystemRepresentation];
        if (cname != nullptr)
        {
            confirmed.emplace_back(cname);
        }
    }
    _learnedSlowStore.LoadConfirmed(confirmed);

    std::map<std::string, int> pending;
    NSDictionary *counts = [defaults dictionaryForKey:kLearnedSlowPendingCountsKey];
    for (id key in counts)
    {
        if (![key isKindOfClass:[NSString class]])
        {
            continue;
        }
        id value = counts[key];
        if (![value isKindOfClass:[NSNumber class]])
        {
            continue;
        }
        const char *cname = [(NSString *)key fileSystemRepresentation];
        if (cname != nullptr)
        {
            pending[cname] = [(NSNumber *)value intValue];
        }
    }
    _learnedSlowStore.LoadPendingCounts(pending);

    // One-time tier seed: on the Apple TV HD, pre-populate the learned-slow store with
    // the presets that failed the full-pack A8 burn-in, sparing new installs the
    // first-lap discovery stutters. Union into any existing learned state; the clear
    // escape hatch above resets the flag so a factory reset re-seeds.
    if (RoonVisCurrentDeviceTier() == RoonVisDeviceTierHD &&
        ![defaults boolForKey:kLearnedSlowHDSeedAppliedKey])
    {
        const RoonVis::PresetBlocklists &blocklists = RoonVisBundlePresetBlocklists();
        if (!blocklists.learnedSlowSeedHD.empty())
        {
            std::vector<std::string> seed(blocklists.learnedSlowSeedHD.begin(),
                                          blocklists.learnedSlowSeedHD.end());
            _learnedSlowStore.LoadConfirmed(seed);
            [self persistLearnedSlowState];
            RoonVisLog(@"ProjectM hardening: applied HD learned-slow seed (%zu presets)", seed.size());
        }
        [defaults setBool:YES forKey:kLearnedSlowHDSeedAppliedKey];
    }

    // Seed the session-only rotation-exclusion set so learned-slow presets are skipped
    // from the very first rotation this launch.
    for (const std::string &name : _learnedSlowStore.ConfirmedNames())
    {
        _slowPresetNames.insert(name);
    }
    if (!_learnedSlowStore.ConfirmedNames().empty())
    {
        RoonVisLog(@"ProjectM hardening: loaded %zu learned-slow preset(s) from prior runs",
                   _learnedSlowStore.ConfirmedNames().size());
    }
}

- (void)persistLearnedSlowState
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (const std::string &name : _learnedSlowStore.ConfirmedNames())
    {
        NSString *value = [NSString stringWithUTF8String:name.c_str()];
        if (value != nil)
        {
            [names addObject:value];
        }
    }
    [defaults setObject:names forKey:kLearnedSlowPresetsKey];

    NSMutableDictionary<NSString *, NSNumber *> *pending = [NSMutableDictionary dictionary];
    for (const auto &entry : _learnedSlowStore.PendingCounts())
    {
        NSString *key = [NSString stringWithUTF8String:entry.first.c_str()];
        if (key != nil)
        {
            pending[key] = @(entry.second);
        }
    }
    [defaults setObject:pending forKey:kLearnedSlowPendingCountsKey];
    [defaults synchronize];
}

- (void)invalidatePreloadedPresetTracking
{
    _preloadedPresetPath.clear();
    _preloadedPresetIndex = SIZE_MAX;
}

- (RoonVis::PresetDwellPlan)computeDwellPlanWithSettleSeconds:(CFTimeInterval)settleSeconds
                                              minLeadSeconds:(CFTimeInterval)minLeadSeconds
                                                      atTime:(CFTimeInterval)now
{
    // No projectM / no presets / nothing confirmed yet -> Idle (never ready). The pure
    // core treats SIZE_MAX nextIndex as Exhausted; return a plain Idle plan here so an
    // uninitialized bridge is distinguishable from a genuine HOLD.
    (void)now;
    if (self.projectM == nullptr || _presetPaths.empty() || _confirmedPresetIndex == SIZE_MAX)
    {
        return RoonVis::PresetDwellPlan{};
    }

    // Smooth (crossfade) window contribution, with the perf-sweep override that used to
    // live inside canWarmPresetAtTime ported here.
    double smoothWindow = 0.0;
    if ([self settingsTransitionUsesSmoothCut])
    {
        smoothWindow = RoonVisPerfSweepPresetTimingEnabled() ? kPerfSweepSoftCutDurationSeconds
                                                             : _crossfadeDurationSeconds;
    }

    // Rotation interval, with the perf-sweep / crasher-scan overrides ported here so the
    // diagnostic burn-ins keep their short cadence.
    double rotationInterval = _rotationIntervalSeconds;
    if (RoonVisPerfSweepPresetTimingEnabled())
    {
        rotationInterval = kPerfSweepPresetDurationSeconds;
    }
    else if (RoonVisCrasherScanModeEnabled())
    {
        rotationInterval = 0.6;
    }

    // The single rotation walk that used to run every frame now runs once per recompute.
    size_t nextIndex = [self nextRotationIndexFrom:[self rotationAnchorIndex] offset:1];
    std::string nextPath;
    if (nextIndex != SIZE_MAX && nextIndex < _presetPaths.size() && nextIndex != _confirmedPresetIndex)
    {
        nextPath = _presetPaths[nextIndex];
    }
    else
    {
        // Same-index / out-of-range -> nothing to preload -> HOLD (Exhausted).
        nextIndex = SIZE_MAX;
    }

    return RoonVis::ComputeDwellPlan(nextIndex, nextPath, _lastPresetSwitchTime, rotationInterval,
                                     smoothWindow, settleSeconds, minLeadSeconds);
}

- (void)recomputeDwellPlansAtTime:(CFTimeInterval)now
{
    // A recompute event has changed what/whether the next preset is; the previously
    // preloaded target may now be stale. Invalidate preload tracking, then recompute both
    // plans (direct-preload path constants and warm-cache-driver constants).
    [self invalidatePreloadedPresetTracking];
    _dwellPlanDirect = [self computeDwellPlanWithSettleSeconds:kPresetDirectPreloadPostTransitionSettleSeconds
                                               minLeadSeconds:kPresetDirectPreloadMinLeadSeconds
                                                       atTime:now];
    _dwellPlanWarm = [self computeDwellPlanWithSettleSeconds:kPresetPreloadPostTransitionSettleSeconds
                                             minLeadSeconds:kPresetPreloadMinLeadSeconds
                                                     atTime:now];
}

- (void)noteSwitchConfirmedAtTime:(CFTimeInterval)now
{
    _lastPresetSwitchTime = now;
    [self recomputeDwellPlansAtTime:now];
}

- (void)schedulePresetPreloadIfReadyAtTime:(CFTimeInterval)now
{
    // Phase 3c diagnostics: track the background compile of an in-flight preload
    // (direct-preload path; the warm-cache path polls from the render loop).
    [self notePreloadCompileProgressAtTime:now];

    // Per-frame cost is now one comparison (A5). No rotation walk, no window math.
    if (!RoonVis::DwellPlanReady(_dwellPlanDirect, now))
    {
        return;
    }

    RoonVis::PresetWarmCandidate candidate{_dwellPlanDirect.targetIndex, _dwellPlanDirect.targetPath};
    BOOL warmed = [self warmPresetOnRenderThread:candidate];
    // Satisfaction/exhaustion is plan state now: a success ends this dwell's direct-preload
    // work; a failure must not retry until a recompute replaces the plan (equivalence to the
    // legacy depth-1 attempt-filter is argued in PresetDwellPlanTests).
    _dwellPlanDirect.state = warmed ? RoonVis::PresetDwellPlan::State::Satisfied
                                    : RoonVis::PresetDwellPlan::State::Exhausted;
}

- (BOOL)dwellPlanWarmCandidateReadyAtTime:(CFTimeInterval)now
                                candidate:(RoonVis::PresetWarmCandidate *)out
{
    if (!RoonVis::DwellPlanReady(_dwellPlanWarm, now))
    {
        return NO;
    }
    if (out != nullptr)
    {
        *out = RoonVis::PresetWarmCandidate{_dwellPlanWarm.targetIndex, _dwellPlanWarm.targetPath};
    }
    return YES;
}

- (BOOL)warmPresetOnRenderThread:(const RoonVis::PresetWarmCandidate &)candidate
{
    if (self.projectM == nullptr ||
        candidate.index == SIZE_MAX ||
        candidate.index >= _presetPaths.size() ||
        candidate.path.empty() ||
        _presetPaths[candidate.index] != candidate.path)
    {
        return NO;
    }

    bool libHasPreload = projectm_has_preloaded_preset(self.projectM);
    bool cachedTargetMatches = libHasPreload &&
                               _preloadedPresetIndex == candidate.index &&
                               _preloadedPresetPath == candidate.path;
    if (cachedTargetMatches)
    {
        return YES;
    }

    // A5: the "don't re-attempt within this dwell" guard is now the dwell plan's
    // Satisfied/Exhausted state (set by the callers after this returns), not a
    // (_preloadAttemptPresetIndex, _preloadAttemptPresetPath) filter.
    NSString *presetName = [self presetDisplayNameForPath:candidate.path];
    _preloadedPresetIndex = candidate.index;
    _preloadedPresetPath = candidate.path;
    _preloadingPreset = YES;
    projectm_preload_preset_file(self.projectM, candidate.path.c_str());
    _preloadingPreset = NO;
    if (!projectm_has_preloaded_preset(self.projectM))
    {
        _preloadedPresetPath.clear();
        _preloadedPresetIndex = SIZE_MAX;
        return NO;
    }

    // Phase 3c: the preset's shader compile is now running on ANGLE's worker pool.
    // Track the ready transition (polled per frame) as proof the work went async.
    _preloadCompileStartTime = CACurrentMediaTime();
    _preloadCompilePollCount = 0;
    _preloadCompileReadyLogged = NO;

    RoonVisLog(@"ProjectM preload confirmed: %@", presetName);
    return YES;
}

- (void)notePreloadCompileProgressAtTime:(CFTimeInterval)now
{
    if (self.projectM == nullptr || _preloadCompileReadyLogged ||
        !projectm_has_preloaded_preset(self.projectM))
    {
        return;
    }

    _preloadCompilePollCount++;
    if (!projectm_preloaded_preset_compile_ready(self.projectM))
    {
        return;
    }

    _preloadCompileReadyLogged = YES;
    RoonVisLog(@"ProjectM preload compile ready: polls=%d elapsed=%.1fms preset=%@",
               _preloadCompilePollCount,
               (now - _preloadCompileStartTime) * 1000.0,
               [self presetDisplayNameForPath:_preloadedPresetPath]);
}

- (BOOL)isImmediateNextWarmCandidate:(const RoonVis::PresetWarmCandidate &)candidate
{
    if (_confirmedPresetIndex == SIZE_MAX || candidate.index == SIZE_MAX)
    {
        return NO;
    }
    size_t nextIndex = [self nextRotationIndexFrom:[self rotationAnchorIndex] offset:1];
    return nextIndex == candidate.index &&
           nextIndex < _presetPaths.size() &&
           _presetPaths[nextIndex] == candidate.path;
}

- (BOOL)warmPresetCacheEntryOnRenderThread:(const RoonVis::PresetWarmCandidate &)candidate complete:(BOOL *)complete
{
    // Single-shot warm: the only warm target is the library's primary preload slot
    // (projectm_preload_preset_file -> projectm_activate_preloaded_preset). The former
    // secondary 64x64 instance stages were removed after a paired device A/B showed
    // zero warm-hit benefit for ~21.6s of main-thread blocking per 330s run.
    if (complete != nullptr)
    {
        *complete = YES;
    }
    if (self.projectM == nullptr ||
        candidate.index == SIZE_MAX ||
        candidate.index >= _presetPaths.size() ||
        candidate.path.empty() ||
        _presetPaths[candidate.index] != candidate.path)
    {
        return NO;
    }

    if (![self isImmediateNextWarmCandidate:candidate])
    {
        // Only the immediate next preset has a preload slot; report non-immediate
        // candidates as failed so the cache does not retry them.
        RoonVisLog(@"Preset warm cache: skipping non-immediate candidate %@",
                   [self presetDisplayNameForPath:candidate.path]);
        return NO;
    }

    NSString *presetName = [self presetDisplayNameForPath:candidate.path];
    CFTimeInterval stageStart = CACurrentMediaTime();
    BOOL stageSucceeded = [self warmPresetOnRenderThread:candidate];
    CFTimeInterval stageDuration = CACurrentMediaTime() - stageStart;
    RoonVisPerfCountWarmStage(RoonVisPerfWarmStagePrimaryPreload, stageDuration * 1000.0);
    RoonVisLog(@"Preset warm cache: stage=primary-preload preset=%@ duration=%.1fms complete=%@ success=%@",
               presetName,
               stageDuration * 1000.0,
               stageSucceeded ? @"YES" : @"NO",
               stageSucceeded ? @"YES" : @"NO");
    return stageSucceeded;
}

- (BOOL)consumeWarmedFirstActivationForPresetName:(NSString *)presetName
{
    if (_warmedFirstFramePresetName == nil || presetName.length == 0)
    {
        return NO;
    }

    BOOL matches = [_warmedFirstFramePresetName isEqualToString:presetName];
    [_warmedFirstFramePresetName release];
    _warmedFirstFramePresetName = nil;
    return matches;
}

@end

#pragma clang diagnostic pop
