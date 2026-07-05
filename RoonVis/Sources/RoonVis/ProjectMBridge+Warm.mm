#import "ProjectMBridgeInternal.h"

#import "RoonVisCrashReporter.h"
#import "RoonVisPerfCounters.h"

#include <map>

@interface ProjectMBridge (PresetDisplayNamePrivate)
- (NSString *)presetDisplayNameForPath:(const std::string &)path;
@end

@interface ProjectMBridge (WarmTimingPrivate)
- (BOOL)canWarmPresetAtTime:(CFTimeInterval)now
    postTransitionSettleSeconds:(CFTimeInterval)postTransitionSettleSeconds
                 minLeadSeconds:(CFTimeInterval)minLeadSeconds;
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
    _preloadAttemptPresetPath.clear();
    _preloadedPresetIndex = SIZE_MAX;
    _preloadAttemptPresetIndex = SIZE_MAX;
}

- (void)schedulePresetPreloadIfReadyAtTime:(CFTimeInterval)now
{
    // Phase 3c diagnostics: track the background compile of an in-flight preload
    // (direct-preload path; the warm-cache path polls from the render loop).
    [self notePreloadCompileProgressAtTime:now];

    if (![self canWarmPresetAtTime:now
        postTransitionSettleSeconds:kPresetDirectPreloadPostTransitionSettleSeconds
                      minLeadSeconds:kPresetDirectPreloadMinLeadSeconds])
    {
        return;
    }

    std::vector<RoonVis::PresetWarmCandidate> candidates = [self presetWarmCandidatesWithDepth:1];
    if (candidates.empty())
    {
        return;
    }
    [self warmPresetOnRenderThread:candidates.front()];
}

- (BOOL)canWarmPresetAtTime:(CFTimeInterval)now
{
    return [self canWarmPresetAtTime:now
        postTransitionSettleSeconds:kPresetPreloadPostTransitionSettleSeconds
                      minLeadSeconds:kPresetPreloadMinLeadSeconds];
}

- (BOOL)canWarmPresetAtTime:(CFTimeInterval)now
    postTransitionSettleSeconds:(CFTimeInterval)postTransitionSettleSeconds
                 minLeadSeconds:(CFTimeInterval)minLeadSeconds
{
    if (self.projectM == nullptr || _presetPaths.empty() || _confirmedPresetIndex == SIZE_MAX)
    {
        return NO;
    }

    double smoothWindow = 0.0;
    if ([self settingsTransitionUsesSmoothCut])
    {
        smoothWindow = RoonVisPerfSweepPresetTimingEnabled() ? kPerfSweepSoftCutDurationSeconds : _crossfadeDurationSeconds;
    }

    // Preload only once the active transition has ended and a short settle has elapsed.
    // If the rotation interval is too short to reach that point and still leave lead
    // before the next switch, skip preloading this cycle and fall back to normal load.
    double settleWindow = smoothWindow + postTransitionSettleSeconds;
    double rotationInterval = _rotationIntervalSeconds;
    if (RoonVisPerfSweepPresetTimingEnabled())
    {
        rotationInterval = kPerfSweepPresetDurationSeconds;
    }
    else if (RoonVisCrasherScanModeEnabled())
    {
        rotationInterval = 0.6;
    }
    if (rotationInterval - settleWindow < minLeadSeconds)
    {
        return NO;
    }
    if (_lastPresetSwitchTime <= 0 || now - _lastPresetSwitchTime < settleWindow)
    {
        return NO;
    }
    return YES;
}

- (std::vector<RoonVis::PresetWarmCandidate>)presetWarmCandidatesWithDepth:(size_t)depth
{
    return [self presetWarmCandidatesWithDepth:depth includePreloadAttempt:NO];
}

- (std::vector<RoonVis::PresetWarmCandidate>)presetWarmCandidatesWithDepth:(size_t)depth
                                                      includePreloadAttempt:(BOOL)includePreloadAttempt
{
    std::vector<RoonVis::PresetWarmCandidate> candidates;
    if (self.projectM == nullptr || _presetPaths.empty() || _confirmedPresetIndex == SIZE_MAX)
    {
        return candidates;
    }

    const size_t candidateDepth = std::max<size_t>(1, depth);
    candidates.reserve(candidateDepth);
    for (size_t offset = 1; offset <= candidateDepth; offset++)
    {
        size_t nextIndex = [self nextRotationIndexFrom:_confirmedPresetIndex offset:static_cast<NSInteger>(offset)];
        if (nextIndex == SIZE_MAX || nextIndex >= _presetPaths.size() || nextIndex == _confirmedPresetIndex)
        {
            break;
        }

        const std::string &nextPath = _presetPaths[nextIndex];
        if (!includePreloadAttempt &&
            _preloadAttemptPresetIndex == _confirmedPresetIndex &&
            _preloadAttemptPresetPath == nextPath)
        {
            continue;
        }

        bool duplicate = std::any_of(candidates.begin(), candidates.end(), [&](const RoonVis::PresetWarmCandidate &candidate) {
            return candidate.index == nextIndex && candidate.path == nextPath;
        });
        if (!duplicate)
        {
            candidates.push_back({nextIndex, nextPath});
        }
    }
    return candidates;
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

    if (_preloadAttemptPresetIndex == _confirmedPresetIndex && _preloadAttemptPresetPath == candidate.path)
    {
        return NO;
    }

    NSString *presetName = [self presetDisplayNameForPath:candidate.path];
    _preloadAttemptPresetIndex = _confirmedPresetIndex;
    _preloadAttemptPresetPath = candidate.path;
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
    size_t nextIndex = [self nextRotationIndexFrom:_confirmedPresetIndex offset:1];
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
