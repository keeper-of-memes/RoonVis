#import "ProjectMBridgeInternal.h"

#include "PresetRotationCursor.h"

#import "RoonVisCrashReporter.h"

#import <EGL/egl.h>
#import <UIKit/UIScreen.h>
#import <projectM-4/logging.h>

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <random>

NSNotificationName const RoonVisEngineStateDidChangeNotification = @"RoonVisEngineStateDidChangeNotification";

@interface ProjectMBridge (PresetSwitchCallbacks)
- (void)handlePresetSwitchRequested:(bool)isHardCut;
- (void)handlePresetSwitchFailed:(const char *)presetFilename message:(const char *)message;
@end

@interface ProjectMBridge (PresetDisplayNamePrivate)
- (NSString *)presetDisplayNameForPath:(const std::string &)path;
@end

@interface ProjectMBridge (SelfHealing)
+ (void)recoverFromPriorCrashIfNeeded;
@end

namespace
{
// kPerfSweepPresetDurationSeconds / kPerfSweepSoftCutDurationSeconds moved to
// ProjectMBridgeInternal.h (shared with the +Warm category).
static FILE *gProjectMTransitionProfileLog = nullptr;
static std::mutex gProjectMTransitionProfileLogMutex;

static constexpr double kSelfHealingCrashWindowSeconds = 10.0;
static NSString *const kSelfHealingRunningKey = @"RoonVisProjectMBridgeRunning";
static NSString *const kSelfHealingActivePresetFilenameKey = @"RoonVisProjectMBridgeActivePresetFilename";
// kLearnedSlow* keys moved to ProjectMBridge+Warm.mm alongside the learned-slow load/
// persist methods that use them.
static NSString *const kSelfHealingActivePresetLoadedAtKey = @"RoonVisProjectMBridgeActivePresetLoadedAt";
// The preset shown when the app last closed, restored on next launch (rotation order is
// otherwise randomised per launch).
static NSString *const kLastShownPresetFilenameKey = @"RoonVisLastShownPresetFilename";

static void ProjectMLogCallback(const char *message, projectm_log_level logLevel, void *)
{
    if (message == nullptr)
    {
        return;
    }

    std::lock_guard<std::mutex> lock(gProjectMTransitionProfileLogMutex);
    if (gProjectMTransitionProfileLog != nullptr)
    {
        fprintf(gProjectMTransitionProfileLog, "projectM[%d]: %s\n", static_cast<int>(logLevel), message);
        fflush(gProjectMTransitionProfileLog);
    }

    if (std::strncmp(message, "ProjectMTransition", 18) != 0)
    {
        RoonVisLog(@"projectM[%d]: %s", static_cast<int>(logLevel), message);
    }
}

static BOOL RoonVisProjectMTransitionProfileEnabled()
{
    NSString *envValue = NSProcessInfo.processInfo.environment[@"ROONVIS_PROJECTM_TRANSITION_PROFILE"];
    if (envValue.length > 0)
    {
        return envValue.boolValue;
    }
    return [[NSUserDefaults standardUserDefaults] boolForKey:@"RoonVisProjectMTransitionProfileEnabled"] ||
           [RoonVisSettings sharedSettings].diagnosticsOverlayEnabled;
}

// Opt-in per-frame eval/draw cost breakdown probes in the vendored projectM
// (ProjectMFrameBreakdown: lines). Env-only by design; shares the transition
// profiler's file sink.
static BOOL RoonVisProjectMEvalProfileEnabled()
{
    NSString *envValue = NSProcessInfo.processInfo.environment[@"ROONVIS_PROJECTM_EVAL_PROFILE"];
    return envValue.length > 0 && envValue.boolValue;
}

static void RoonVisOpenProjectMTransitionProfileLog()
{
    std::lock_guard<std::mutex> lock(gProjectMTransitionProfileLogMutex);
    if (gProjectMTransitionProfileLog != nullptr)
    {
        return;
    }

    NSArray<NSString *> *cacheDirectories = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString *cacheDirectory = cacheDirectories.firstObject;
    if (cacheDirectory.length == 0)
    {
        RoonVisLog(@"ProjectM transition profiler file sink unavailable: no Caches directory");
        return;
    }

    NSString *path = [cacheDirectory stringByAppendingPathComponent:@"projectm-transition-profile.log"];
    gProjectMTransitionProfileLog = fopen(path.fileSystemRepresentation, "w");
    if (gProjectMTransitionProfileLog == nullptr)
    {
        RoonVisLog(@"ProjectM transition profiler file sink failed: %@", path);
        return;
    }

    RoonVisLog(@"ProjectM transition profiler file sink: %@", path);
}

static void PresetSwitchRequestedCallback(bool isHardCut, void *userData)
{
    ProjectMBridge *bridge = static_cast<ProjectMBridge *>(userData);
    [bridge handlePresetSwitchRequested:isHardCut];
}

static void PresetSwitchFailedCallback(const char *presetFilename, const char *message, void *userData)
{
    ProjectMBridge *bridge = static_cast<ProjectMBridge *>(userData);
    [bridge handlePresetSwitchFailed:presetFilename message:message];
}

// Preprocessed-HLSL cache bridge. `user` is the RoonVis::PreprocessCache owned by the
// bridge. projectM invokes these only on the GL/render thread (transpile runs there), so
// the non-thread-safe cache needs no locking.
static bool PreprocessCacheGet(void *user, const char *key, size_t keylen,
                               void *sinkctx, void (*sink)(void *sinkctx, const char *data, size_t len))
{
    auto *cache = static_cast<RoonVis::PreprocessCache *>(user);
    std::string value;
    if (!cache->Get(std::string(key, keylen), value))
    {
        return false;
    }
    sink(sinkctx, value.data(), value.size());
    return true;
}

static void PreprocessCachePut(void *user, const char *key, size_t keylen,
                               const char *value, size_t vallen)
{
    auto *cache = static_cast<RoonVis::PreprocessCache *>(user);
    cache->Put(std::string(key, keylen), std::string(value, vallen));
}

// Seed the runtime cache from the build-time-generated resource so the FIRST load of any
// bundled preset is a cache hit (no transpile stutter). Little-endian format written by the
// PreprocessCacheGen host tool:
//   magic "RVPP" · u32 version(=1) · u32 saltLen+salt · u32 entryCount ·
//   (u32 keyLen+key · u32 valLen+val)*
// Staleness-safe: a stale entry (salt bump / preset edit) just yields a runtime key miss ->
// live transpile. So a missing / malformed / short file is a warning and no-op, never wrong.
static void SeedPreprocessCacheFromResource(RoonVis::PreprocessCache &cache)
{
    NSString *path = [NSBundle.mainBundle.resourcePath
        stringByAppendingPathComponent:@"preprocess-cache/preprocess-cache.bin"];
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data == nil)
    {
        RoonVisLog(@"Preprocess cache: resource missing at %@ (no prepopulation)", path);
        return;
    }

    const uint8_t *bytes = static_cast<const uint8_t *>(data.bytes);
    const size_t size = data.length;
    size_t off = 0;

    auto readU32 = [&](uint32_t &out) -> bool {
        if (off + 4 > size)
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
    auto readStr = [&](std::string &out) -> bool {
        uint32_t len = 0;
        if (!readU32(len) || off + len > size)
        {
            return false;
        }
        out.assign(reinterpret_cast<const char *>(bytes + off), len);
        off += len;
        return true;
    };

    if (size < 4 || std::memcmp(bytes, "RVPP", 4) != 0)
    {
        RoonVisLog(@"Preprocess cache: bad magic (no prepopulation)");
        return;
    }
    off = 4;
    uint32_t version = 0;
    if (!readU32(version) || version != 1)
    {
        RoonVisLog(@"Preprocess cache: unsupported version %u (no prepopulation)", version);
        return;
    }
    std::string salt;
    uint32_t entryCount = 0;
    if (!readStr(salt) || !readU32(entryCount))
    {
        RoonVisLog(@"Preprocess cache: truncated header (no prepopulation)");
        return;
    }

    // Guarantee no seed can be evicted by later runtime Puts.
    cache.EnsureCapacity(static_cast<size_t>(entryCount) + 64);

    for (uint32_t i = 0; i < entryCount; ++i)
    {
        std::string key;
        std::string value;
        if (!readStr(key) || !readStr(value))
        {
            RoonVisLog(@"Preprocess cache: truncated at entry %u/%u (seeded %zu so far)",
                       i, entryCount, cache.Seeds());
            break;
        }
        cache.Seed(key, std::move(value));
    }
    RoonVisLog(@"Preprocess cache: salt=%s seeded %zu entries", salt.c_str(), cache.Seeds());
}
}  // namespace

// Runtime opt-in for the short-duration preset-transition timing sweep (#2.4).
// Off by default; enable for on-device Release measurement via either
//   defaults write <bundle id> RoonVisPerfSweepPresetTimingEnabled -bool YES
// or the ROONVIS_PERF_SWEEP_PRESET_TIMING env var. Mirrors
// RoonVisPerfDiagnosticsEnabled() in ANGLEGLView.mm. Declared in
// ProjectMBridgeInternal.h so the +Warm category can read the same setting.
BOOL RoonVisPerfSweepPresetTimingEnabled()
{
    // Compile-gated to non-Release (ROONVIS_ENABLE_DIAGNOSTIC_MODES). In the shipping
    // build this constant-folds to NO, so the per-frame render path (preload scheduler)
    // pays no env/NSUserDefaults read. Dev/QA preset-curation tool only.
#if ROONVIS_ENABLE_DIAGNOSTIC_MODES
    NSString *envValue = NSProcessInfo.processInfo.environment[@"ROONVIS_PERF_SWEEP_PRESET_TIMING"];
    if (envValue.length > 0)
    {
        return envValue.boolValue;
    }
    return [[NSUserDefaults standardUserDefaults] boolForKey:@"RoonVisPerfSweepPresetTimingEnabled"];
#else
    return NO;
#endif
}

// Crasher-scan mode: very fast rotation (load each preset briefly, instant cuts) to
// surface render-time SIGSEGV crashers quickly. Off by default; enable via the
// RoonVisCrasherScanMode NSUserDefaults launch arg. Measurement/ops only.
BOOL RoonVisCrasherScanModeEnabled()
{
    // Compile-gated to non-Release (ROONVIS_ENABLE_DIAGNOSTIC_MODES); constant-folds to
    // NO in the shipping build so the render tree pays no env/NSUserDefaults read.
#if ROONVIS_ENABLE_DIAGNOSTIC_MODES
    NSString *envValue = NSProcessInfo.processInfo.environment[@"ROONVIS_CRASHER_SCAN_MODE"];
    if (envValue.length > 0)
    {
        return envValue.boolValue;
    }
    return [[NSUserDefaults standardUserDefaults] boolForKey:@"RoonVisCrasherScanMode"];
#else
    return NO;
#endif
}

// Deterministic-rotation test hook for paired A/B perf runs: ROONVIS_ROTATION_FIXED_LIST
// is a comma-separated list of preset filenames. When set, rotation cycles exactly those
// presets in that order (Loop semantics, any rotation-mode setting) and the first list
// entry is shown first after launch. Dev/QA only.
static std::vector<std::string> RoonVisFixedRotationListFilenames()
{
    // Compile-gated to non-Release (ROONVIS_ENABLE_DIAGNOSTIC_MODES) like the other
    // diagnostic modes above; constant-folds to an empty list in the shipping build.
#if ROONVIS_ENABLE_DIAGNOSTIC_MODES
    NSString *envValue = NSProcessInfo.processInfo.environment[@"ROONVIS_ROTATION_FIXED_LIST"];
    if (envValue.length > 0)
    {
        return RoonVis::ParseFixedRotationList(RoonVisNSStringToUTF8(envValue));
    }
#endif
    return {};
}

unsigned int RoonVisDisplayRefreshRate()
{
    NSInteger refreshRate = UIScreen.mainScreen.maximumFramesPerSecond;
    return refreshRate > 0 ? static_cast<unsigned int>(refreshRate) : 60u;
}

// projectM's fps hint must track the same effective (capped) rate the display
// link runs at - both the init and resize paths use this so a resize never
// reintroduces the uncapped panel rate.
static unsigned int RoonVisEffectiveProjectMFPS()
{
    unsigned int screenMax = RoonVisDisplayRefreshRate();
    NSInteger cap = [RoonVisSettings sharedSettings].frameRateCap;
    if (cap > 0 && static_cast<unsigned int>(cap) < screenMax)
    {
        return static_cast<unsigned int>(cap);
    }
    return screenMax;
}

void *ProjectMANGLELoadProc(const char *name, void *)
{
    return reinterpret_cast<void *>(eglGetProcAddress(name));
}

@implementation ProjectMBridge

- (instancetype)initWithDrawableSize:(CGSize)drawableSize
{
    self = [super init];
    if (self)
    {
        [ProjectMBridge recoverFromPriorCrashIfNeeded];
        [ProjectMBridge markApplicationRunning];

        _drawableSize = drawableSize;
        _livePCMBuffer = RoonVis::LivePCMDelayBuffer(kLivePCMMaxBufferFrames, 2);
        _currentPresetIndex = SIZE_MAX;
        _confirmedPresetIndex = SIZE_MAX;
        _lastGoodPresetIndex = SIZE_MAX;
        _preloadedPresetIndex = SIZE_MAX;
        _preloadAttemptPresetIndex = SIZE_MAX;
        _presetStepDirection = 1;
        _audioInputDelayMs = 255;
        _effectiveAudioDelayMs = _audioInputDelayMs;
        _syncRenderCompensationMs = [[NSUserDefaults standardUserDefaults] integerForKey:@"RoonVisSyncRenderCompensationMs"];
        _syncRenderCompensationMs = MAX((NSInteger)0, MIN((NSInteger)200, _syncRenderCompensationMs));
        _audioDelayFrames = LivePCMDelayFramesForMilliseconds(_audioInputDelayMs);
        _audioSensitivity = 1.0;
        _transitionStyle = RoonVisTransitionStyleInstant;
        _rotationIntervalSeconds = [RoonVisSettings sharedSettings].rotationIntervalSeconds;
        _crossfadeDurationSeconds = [RoonVisSettings sharedSettings].crossfadeDurationSeconds;
        [self loadLearnedSlowPresets];
        NSString *audioPath = [NSBundle.mainBundle pathForResource:@"TestAudio" ofType:@"wav"];

        if (!RoonVisLoadPCM16Wav(audioPath, _wav))
        {
            NSLog(@"ProjectM Step B no fallback WAV; live PCM only: %@", audioPath);
        }

        setenv("PROJECTM_GLRESOLVER_STRICT_CONTEXT_GATE", "0", 1);
        const BOOL transitionProfileEnabled = RoonVisProjectMTransitionProfileEnabled();
        const BOOL evalProfileEnabled = RoonVisProjectMEvalProfileEnabled();
        if (transitionProfileEnabled || evalProfileEnabled)
        {
            if (transitionProfileEnabled)
            {
                setenv("ROONVIS_PROJECTM_TRANSITION_PROFILE", "1", 1);
            }
            RoonVisOpenProjectMTransitionProfileLog();
            projectm_set_log_callback(ProjectMLogCallback, true, nullptr);
            projectm_set_log_level(PROJECTM_LOG_LEVEL_INFO, true);
            RoonVisLog(@"ProjectM %s profiler enabled",
                       transitionProfileEnabled && evalProfileEnabled ? "transition+eval"
                       : transitionProfileEnabled                     ? "transition"
                                                                      : "eval");
        }

        self.projectM = projectm_create_with_opengl_load_proc(ProjectMANGLELoadProc, nullptr);
        if (self.projectM == nullptr)
        {
            RoonVisLog(@"ProjectM Step B projectm_create failed");
            return self;
        }

        char *version = projectm_get_version_string();
        RoonVisLog(@"ProjectM Step B initialized libprojectM %@", version ? @(version) : @"(unknown)");
        if (version != nullptr)
        {
            projectm_free_string(version);
        }

        unsigned int displayRefreshRate = RoonVisEffectiveProjectMFPS();
        // User-adjustable warp mesh (Settings > Rendering > Warp detail; height = width*3/4).
        // The per-vertex warp equations run on the CPU and scale linearly with vertex count,
        // so per-pixel-heavy presets are the most sensitive to this. Milkdrop's default is
        // 48x36; the ceiling is 128x96. Live changes are re-applied in -applySettings.
        _warpMeshOverrideActive = NO;
        _appliedWarpMeshWidth = [RoonVisSettings sharedSettings].warpMeshWidth;
        size_t meshWidth = static_cast<size_t>(_appliedWarpMeshWidth);
        size_t meshHeight = static_cast<size_t>(_appliedWarpMeshWidth) * 3 / 4;
#if ROONVIS_ENABLE_DIAGNOSTIC_MODES
        // Perf-attribution hook: override the warp mesh (e.g. "16x12") to test whether a
        // slow preset is per-vertex/CPU-bound (mesh-sensitive) or pixel/shader-bound. When
        // set, it wins over the setting and -applySettings leaves the mesh alone.
        NSString *meshOverride = NSProcessInfo.processInfo.environment[@"ROONVIS_MESH_SIZE"];
        if (meshOverride.length > 0)
        {
            NSArray<NSString *> *parts = [meshOverride componentsSeparatedByString:@"x"];
            if (parts.count == 2 && parts[0].integerValue > 0 && parts[1].integerValue > 0)
            {
                meshWidth = static_cast<size_t>(parts[0].integerValue);
                meshHeight = static_cast<size_t>(parts[1].integerValue);
                _warpMeshOverrideActive = YES;
                RoonVisLog(@"ProjectM mesh override: %zux%zu", meshWidth, meshHeight);
            }
        }
#endif
        projectm_set_mesh_size(self.projectM, meshWidth, meshHeight);
        projectm_set_fps(self.projectM, displayRefreshRate);
        RoonVisLog(@"ProjectM Step B display fps=%u", displayRefreshRate);
        [self resizeToDrawableSize:drawableSize];

        NSString *resourcePath = NSBundle.mainBundle.resourcePath;
        NSString *texturesPath = [resourcePath stringByAppendingPathComponent:@"textures"];
        const char *texturePaths[] = {
            texturesPath.fileSystemRepresentation,
            resourcePath.fileSystemRepresentation,
        };
        projectm_set_texture_search_paths(self.projectM, texturePaths, 2);

        NSArray<NSString *> *presetPaths =
            [[NSBundle mainBundle] pathsForResourcesOfType:@"milk" inDirectory:@"presets"];
        presetPaths = [presetPaths sortedArrayUsingSelector:@selector(compare:)];
        _presetPaths.reserve(presetPaths.count);
        NSUInteger slowPresetSkips = 0;
        NSUInteger crashPresetSkips = 0;
        NSUInteger staticHeavySkips = 0;
        NSUInteger hiddenPresetSkips = 0;
        RoonVisSettings *settings = [RoonVisSettings sharedSettings];
        for (NSString *path in presetPaths)
        {
            NSString *filename = path.lastPathComponent;
            if (RoonVisIsKnownSlowPresetFilename(filename))
            {
                slowPresetSkips++;
                continue;
            }
            if (RoonVisIsKnownCrashingPresetFilename(filename))
            {
                crashPresetSkips++;
                continue;
            }
            if (RoonVisIsStaticHeavyPresetFilename(filename))
            {
                staticHeavySkips++;
                continue;
            }
            if ([settings isHiddenPresetFilename:filename])
            {
                hiddenPresetSkips++;
                continue;
            }
            _presetPaths.emplace_back(path.fileSystemRepresentation);
        }
        // Randomise the rotation order per launch (was a fixed seed, which made every
        // session open on the same preset and follow the same order). The last-shown
        // preset is restored explicitly in loadInitialPreset. Loop mode derives its
        // traversal from the Browse shelves, so this remains Shuffle-only behavior.
        std::mt19937 rng(arc4random());
        std::shuffle(_presetPaths.begin(), _presetPaths.end(), rng);
        const std::vector<std::string> fixedRotationFilenames = RoonVisFixedRotationListFilenames();
        if (!fixedRotationFilenames.empty())
        {
            _fixedRotationIndexes = RoonVis::ResolveFixedRotationIndexes(fixedRotationFilenames, _presetPaths);
            RoonVisLog(@"Fixed rotation list: %zu/%zu presets resolved",
                       _fixedRotationIndexes.size(),
                       fixedRotationFilenames.size());
        }
        _browsePresetOrderIndexes = [self rotationCandidateIndexesForMode:RoonVisPresetRotationModeLoop];
        [self restoreOrRegenerateShuffleOrder];
        _lastRotationMode = [RoonVisSettings sharedSettings].presetRotationMode;
        RoonVisLog(@"ProjectM hardening: found %zu bundled presets (%lu known slow, %lu known crashing, %lu static-heavy, %lu hidden filtered)",
                   _presetPaths.size(),
                   static_cast<unsigned long>(slowPresetSkips),
                   static_cast<unsigned long>(crashPresetSkips),
                   static_cast<unsigned long>(staticHeavySkips),
                   static_cast<unsigned long>(hiddenPresetSkips));

        projectm_set_preset_locked(self.projectM, false);
        projectm_set_hard_cut_enabled(self.projectM, true);
        [self applySettings];
        projectm_set_preset_switch_requested_event_callback(self.projectM, PresetSwitchRequestedCallback, self);
        projectm_set_preset_switch_failed_event_callback(self.projectM, PresetSwitchFailedCallback, self);

        // Register the preprocessed-HLSL cache. The hooks struct and the cache both live on
        // the bridge (ivars), so they outlive the projectM instance destroyed in -shutdown.
        _preprocessCacheHooks.get = PreprocessCacheGet;
        _preprocessCacheHooks.put = PreprocessCachePut;
        _preprocessCacheHooks.user = &_preprocessCache;
        projectm_set_preprocess_cache(self.projectM, &_preprocessCacheHooks);

        // Prepopulate the cache from the bundled build-time resource so the first load of any
        // bundled preset is a hit (no live-transpile stutter). Single-threaded here (init,
        // before rotation starts); staleness-safe (stale keys just miss at runtime).
        SeedPreprocessCacheFromResource(_preprocessCache);
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(settingsDidChange:)
                                                     name:RoonVisSettingsDidChangeNotification
                                                   object:nil];

        if (_presetPaths.empty())
        {
            RoonVisLog(@"ProjectM hardening: no bundled presets found");
        }

        if (_wav.frameCount() > 0)
        {
            RoonVisLog(@"ProjectM Step B loaded WAV: %u Hz, %u channels, %zu frames",
                       _wav.sampleRate,
                       _wav.channels,
                       _wav.frameCount());
        }
        self.lastFeedTime = CACurrentMediaTime();
    }
    return self;
}

- (BOOL)isReady
{
    return self.projectM != nullptr;
}

- (BOOL)presetRotationHeld
{
    return _presetRotationHeld;
}

- (NSInteger)audioInputDelayMs
{
    return _audioInputDelayMs;
}

- (NSInteger)effectiveAudioDelayMs
{
    return _effectiveAudioDelayMs;
}

+ (void)markApplicationRunning
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:YES forKey:kSelfHealingRunningKey];
    [defaults synchronize];
}

+ (void)markApplicationCleanShutdown
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:NO forKey:kSelfHealingRunningKey];
    [defaults synchronize];
}

+ (void)recoverFromPriorCrashIfNeeded
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (![defaults boolForKey:kSelfHealingRunningKey])
    {
        return;
    }

    NSString *presetFilename = [defaults stringForKey:kSelfHealingActivePresetFilenameKey];
    NSTimeInterval loadedAt = [defaults doubleForKey:kSelfHealingActivePresetLoadedAtKey];
    NSTimeInterval age = [[NSDate date] timeIntervalSince1970] - loadedAt;
    if (presetFilename.length == 0 || loadedAt <= 0 || age < 0 || age > kSelfHealingCrashWindowSeconds)
    {
        RoonVisLog(@"ProjectM hardening: prior run did not cleanly shut down, but no recent preset load matched self-heal window");
        return;
    }

    NSMutableOrderedSet<NSString *> *blocklist = [NSMutableOrderedSet orderedSet];
    NSString *raw = [defaults stringForKey:@"RoonVisExtraCrashBlocklist"];
    for (NSString *name in [raw componentsSeparatedByString:@","])
    {
        NSString *trimmed = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length > 0)
        {
            [blocklist addObject:trimmed];
        }
    }
    if (![blocklist containsObject:presetFilename])
    {
        [blocklist addObject:presetFilename];
        [defaults setObject:[[blocklist array] componentsJoinedByString:@","] forKey:@"RoonVisExtraCrashBlocklist"];
        [defaults synchronize];
        RoonVisLog(@"ProjectM hardening: self-healed: blocklisted %@", presetFilename);
    }
}

- (void)settingsDidChange:(NSNotification *)notification
{
    [self invalidatePreloadedPresetTracking];
    // Reseed the Shuffle order only when the user transitions INTO Shuffle, so selecting
    // Shuffle produces a fresh sequence rather than the launch order (issue #6).
    RoonVisPresetRotationMode newMode = [RoonVisSettings sharedSettings].presetRotationMode;
    if (newMode == RoonVisPresetRotationModeShuffle && _lastRotationMode != RoonVisPresetRotationModeShuffle)
    {
        [self regenerateShuffleOrder];
    }
    _lastRotationMode = newMode;
    // Rebuild the browse order only for membership/order-affecting keys; a
    // missing key (programmatic notification) rebuilds as before. Hygiene only:
    // the rotation cursor no longer depends on this list staying stable.
    NSString *changedKey = notification.userInfo[@"key"];
    const BOOL orderAffecting = changedKey == nil ||
        [changedKey isEqualToString:RoonVisSettingsHiddenPresetFilenamesKey] ||
        [changedKey isEqualToString:RoonVisSettingsFavoritePresetFilenamesKey] ||
        [changedKey isEqualToString:RoonVisSettingsFavoritesOnlyRotationKey] ||
        [changedKey isEqualToString:RoonVisSettingsPresetRotationModeKey];
    if (orderAffecting)
    {
        _browsePresetOrderIndexes = [self rotationCandidateIndexesForMode:RoonVisPresetRotationModeLoop];
    }
    [self applySettings];
}

- (void)applySettings
{
    if (self.projectM == nullptr)
    {
        return;
    }

    RoonVisSettings *settings = [RoonVisSettings sharedSettings];
    const BOOL crasherScanMode = RoonVisCrasherScanModeEnabled();
    const BOOL perfSweepTiming = RoonVisPerfSweepPresetTimingEnabled();
    double presetDuration = settings.rotationIntervalSeconds;
    double softCutDuration = settings.crossfadeDurationSeconds;
#if ROONVIS_ENABLE_DIAGNOSTIC_MODES
    // Burn-in dwell override (dev/QA): rotation interval in seconds, below the
    // settings floor if needed (e.g. 30 s full-pack passes). Loop coverage comes
    // from ROONVIS_ROTATION_FIXED_LIST; this only shortens the dwell.
    {
        NSString *burninDwell = NSProcessInfo.processInfo.environment[@"ROONVIS_ROTATION_SECONDS"];
        if (burninDwell.length > 0 && burninDwell.doubleValue > 0.0)
        {
            presetDuration = burninDwell.doubleValue;
        }
    }
#endif
    if (perfSweepTiming)
    {
        presetDuration = kPerfSweepPresetDurationSeconds;
        softCutDuration = kPerfSweepSoftCutDurationSeconds;
    }
    if (crasherScanMode)
    {
        presetDuration = 0.6;   // load each preset briefly to surface load-crashers
        softCutDuration = 0.0;  // instant cuts; no double-render blend
    }

    _transitionStyle = settings.transitionStyle;
    _audioSensitivity = settings.audioSensitivity;
    _rotationIntervalSeconds = settings.rotationIntervalSeconds;
    _crossfadeDurationSeconds = settings.crossfadeDurationSeconds;
    // Live frame-rate cap changes: keep projectM's fps hint in step with the
    // (capped) display-link rate applied by ANGLEGLView's settings observer.
    projectm_set_fps(self.projectM, RoonVisEffectiveProjectMFPS());
    // Queue the audio-delay target for the render/GL thread. All writes to the delay
    // ivars (_audioInputDelayMs/_effectiveAudioDelayMs/_audioDelayFrames) happen in
    // -applyPendingAudioDelay on the render thread; the latency lock re-trims the
    // effective delay from the new target on the next diagnostics window. Recording
    // intent under the lock keeps the drain path from racing an ivar write.
    {
        std::lock_guard<std::mutex> lock(_livePCMMutex);
        _pendingAudioInputDelayMs = settings.audioInputDelayMs;
        _hasPendingAudioDelay = YES;
    }
    projectm_set_preset_duration(self.projectM, presetDuration);
    projectm_set_soft_cut_duration(self.projectM,
                                   _transitionStyle == RoonVisTransitionStyleCrossfade ? softCutDuration : 0.0);
    projectm_set_hard_cut_duration(self.projectM, 60.0);
    projectm_set_hard_cut_sensitivity(self.projectM, static_cast<float>(settings.beatHardCutSensitivity));
    // Live-apply the warp mesh. -applySettings runs on the main/GL thread (settings-change
    // notification + init), so a direct projectm_set_mesh_size is safe and serialized against
    // the render loop. The ROONVIS_MESH_SIZE diagnostic override keeps ownership when active.
    if (!_warpMeshOverrideActive)
    {
        NSInteger desiredMeshWidth = settings.warpMeshWidth;
        if (desiredMeshWidth != _appliedWarpMeshWidth)
        {
            projectm_set_mesh_size(self.projectM,
                                   static_cast<size_t>(desiredMeshWidth),
                                   static_cast<size_t>(desiredMeshWidth) * 3 / 4);
            _appliedWarpMeshWidth = desiredMeshWidth;
            RoonVisLog(@"ProjectM warp mesh updated: %ldx%ld",
                       static_cast<long>(desiredMeshWidth),
                       static_cast<long>(desiredMeshWidth * 3 / 4));
        }
    }
    if (perfSweepTiming || crasherScanMode)
    {
        RoonVisLog(@"ProjectM diagnostics: %@ timing (duration %.1fs soft cut %.1fs)",
                   crasherScanMode ? @"crasher-scan" : @"perf sweep",
                   presetDuration,
                   softCutDuration);
    }
    else
    {
        RoonVisLog(@"ProjectM settings: rotation=%lds presetRotationMode=%ld transition=%@ crossfade=%.1fs hardCutSensitivity=%.2f audioSensitivity=%.1f audioInputDelay=%ldms (%zu frames)",
                   static_cast<long>(settings.rotationIntervalSeconds),
                   static_cast<long>(settings.presetRotationMode),
                   _transitionStyle == RoonVisTransitionStyleCrossfade ? @"crossfade" : @"instant",
                   settings.crossfadeDurationSeconds,
                   settings.beatHardCutSensitivity,
                   _audioSensitivity,
                   static_cast<long>(settings.audioInputDelayMs),
                   LivePCMDelayFramesForMilliseconds(settings.audioInputDelayMs));
    }
}

- (BOOL)settingsTransitionUsesSmoothCut
{
    return _transitionStyle == RoonVisTransitionStyleCrossfade && !RoonVisCrasherScanModeEnabled();
}

- (void)recordPresetLoadAttemptForFilename:(NSString *)presetFilename
{
    if (presetFilename.length == 0)
    {
        return;
    }

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:presetFilename forKey:kSelfHealingActivePresetFilenameKey];
    [defaults setObject:presetFilename forKey:kLastShownPresetFilenameKey];
    [defaults setDouble:[[NSDate date] timeIntervalSince1970] forKey:kSelfHealingActivePresetLoadedAtKey];
    [defaults synchronize];
}

- (BOOL)isPresetHiddenOrSlow:(NSString *)presetName
{
    if (presetName.length == 0)
    {
        return YES;
    }
    if ([[RoonVisSettings sharedSettings] isHiddenPresetFilename:presetName])
    {
        return YES;
    }

    const char *presetFileSystemName = presetName.fileSystemRepresentation;
    return presetFileSystemName != nullptr && _slowPresetNames.find(presetFileSystemName) != _slowPresetNames.end();
}

- (std::vector<RoonVis::PresetShelfInput>)presetShelfInputsFavoritesOnly:(BOOL)favoritesOnly
{
    return [self presetShelfInputsFavoritesOnly:favoritesOnly includeHidden:NO];
}

- (std::vector<RoonVis::PresetShelfInput>)presetShelfInputsFavoritesOnly:(BOOL)favoritesOnly includeHidden:(BOOL)includeHidden
{
    std::vector<RoonVis::PresetShelfInput> inputs;
    for (NSUInteger index = 0; index < [self presetCount]; index++)
    {
        NSString *filename = [self presetFilenameAtIndex:index];
        if (filename.length == 0 || (!includeHidden && [self isHidden:filename]))
        {
            continue;
        }
        BOOL favorite = [self isFavorite:filename];
        if (favoritesOnly && !favorite)
        {
            continue;
        }

        RoonVis::PresetShelfInput input;
        input.index = index;
        input.filename = RoonVisNSStringToUTF8(filename);
        input.title = RoonVisNSStringToUTF8(RoonVisHumanPresetTitle([self presetDisplayNameAtIndex:index], index));
        input.favorite = favorite;
        inputs.push_back(input);
    }
    return inputs;
}

static NSString *const kShuffleOrderFilenamesKey = @"RoonVisShuffleOrderFilenames";
static NSString *const kShuffleOrderFingerprintKey = @"RoonVisShuffleOrderFingerprint";

- (std::string)shuffleOrderFingerprint
{
    std::vector<std::string> pack;
    pack.reserve(_presetPaths.size());
    for (size_t index = 0; index < _presetPaths.size(); index++)
    {
        pack.push_back(RoonVisNSStringToUTF8([self presetDisplayNameForPath:_presetPaths[index]]));
    }
    const std::set<std::string> &confirmed = _learnedSlowStore.ConfirmedNames();
    std::vector<std::string> slow(confirmed.begin(), confirmed.end());
    return RoonVis::ShuffleOrderFingerprint(pack, slow);
}

- (void)persistShuffleOrder
{
    NSMutableArray<NSString *> *filenames = [NSMutableArray arrayWithCapacity:_shuffleOrderIndexes.size()];
    for (size_t index : _shuffleOrderIndexes)
    {
        if (index < _presetPaths.size())
        {
            [filenames addObject:[self presetDisplayNameForPath:_presetPaths[index]]];
        }
    }
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:filenames forKey:kShuffleOrderFilenamesKey];
    [defaults setObject:[NSString stringWithUTF8String:[self shuffleOrderFingerprint].c_str()]
                 forKey:kShuffleOrderFingerprintKey];
}

// Restores the persisted shuffle permutation when its fingerprint (pack filename
// set + learned-slow confirmed set) still matches; otherwise reseeds. Entries
// hidden or runtime-slow-marked are RETAINED in the order and filtered by the
// advance predicate, so short sessions continue the walk across launches
// instead of resampling the head of a fresh permutation every time.
- (void)restoreOrRegenerateShuffleOrder
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *storedFingerprint = [defaults stringForKey:kShuffleOrderFingerprintKey];
    NSArray *storedOrder = [defaults arrayForKey:kShuffleOrderFilenamesKey];
    if (storedFingerprint.length > 0 && [storedOrder isKindOfClass:NSArray.class] && storedOrder.count > 0 &&
        [self shuffleOrderFingerprint] == RoonVisNSStringToUTF8(storedFingerprint))
    {
        std::vector<std::string> stored;
        stored.reserve(storedOrder.count);
        for (id item in storedOrder)
        {
            if ([item isKindOfClass:NSString.class])
            {
                stored.push_back(RoonVisNSStringToUTF8(static_cast<NSString *>(item)));
            }
        }
        std::vector<size_t> restored = RoonVis::RestoreShuffleOrder(stored, [self](const std::string &filename) {
            NSString *name = [NSString stringWithUTF8String:filename.c_str()];
            for (size_t index = 0; index < self->_presetPaths.size(); index++)
            {
                if ([[self presetDisplayNameForPath:self->_presetPaths[index]] isEqualToString:name])
                {
                    return index;
                }
            }
            return static_cast<size_t>(SIZE_MAX);
        });
        if (!restored.empty())
        {
            _shuffleOrderIndexes = std::move(restored);
            RoonVisLog(@"ProjectM rotation: restored persisted shuffle order (%zu entries)", _shuffleOrderIndexes.size());
            return;
        }
    }
    [self regenerateShuffleOrder];
}

- (void)regenerateShuffleOrder
{
    std::vector<size_t> visible;
    visible.reserve(_presetPaths.size());
    for (size_t index = 0; index < _presetPaths.size(); index++)
    {
        NSString *presetName = [self presetDisplayNameForPath:_presetPaths[index]];
        if (![self isPresetHiddenOrSlow:presetName])
        {
            visible.push_back(index);
        }
    }
    _shuffleOrderIndexes = RoonVis::ShuffledOrder(visible, arc4random());
    [self persistShuffleOrder];
    RoonVisLog(@"ProjectM settings: shuffle order reseeded (%zu presets)", _shuffleOrderIndexes.size());
}

- (std::vector<size_t>)rotationCandidateIndexesForMode:(RoonVisPresetRotationMode)mode
{
    if (_presetPaths.empty())
    {
        return {};
    }

    if (mode == RoonVisPresetRotationModeShuffle)
    {
        if (_shuffleOrderIndexes.empty())
        {
            [self regenerateShuffleOrder];
        }
        // Return the reseeded shuffle order, re-filtered in case hidden/slow presets
        // changed since it was generated.
        std::vector<size_t> indexes;
        indexes.reserve(_shuffleOrderIndexes.size());
        for (size_t index : _shuffleOrderIndexes)
        {
            if (index >= _presetPaths.size())
            {
                continue;
            }
            NSString *presetName = [self presetDisplayNameForPath:_presetPaths[index]];
            if (![self isPresetHiddenOrSlow:presetName])
            {
                indexes.push_back(index);
            }
        }
        return indexes;
    }

    std::vector<RoonVis::PresetShelfInput> inputs = [self presetShelfInputsFavoritesOnly:(mode == RoonVisPresetRotationModeFavorites)];
    std::vector<RoonVis::PresetShelf> shelves = RoonVis::BuildPresetShelves(inputs, mode == RoonVisPresetRotationModeFavorites, 3);
    std::vector<size_t> indexes = RoonVis::FlattenPresetShelfIndexes(shelves);
    if (mode == RoonVisPresetRotationModeFavorites && indexes.empty())
    {
        RoonVisLog(@"ProjectM settings: favourites rotation requested but no favourites exist; using Loop rotation");
        inputs = [self presetShelfInputsFavoritesOnly:NO];
        shelves = RoonVis::BuildPresetShelves(inputs, false, 3);
        indexes = RoonVis::FlattenPresetShelfIndexes(shelves);
    }
    return indexes;
}

- (std::vector<size_t>)fullRotationOrderForMode:(RoonVisPresetRotationMode)mode
{
    if (_presetPaths.empty())
    {
        return {};
    }

    if (mode == RoonVisPresetRotationModeShuffle)
    {
        if (_shuffleOrderIndexes.empty())
        {
            [self regenerateShuffleOrder];
        }
        // The raw permutation, unfiltered: entries hidden or slow-marked since
        // the seed stay in place and are skipped by the advance predicate.
        return _shuffleOrderIndexes;
    }

    std::vector<RoonVis::PresetShelfInput> inputs = [self presetShelfInputsFavoritesOnly:(mode == RoonVisPresetRotationModeFavorites) includeHidden:YES];
    std::vector<RoonVis::PresetShelf> shelves = RoonVis::BuildPresetShelves(inputs, mode == RoonVisPresetRotationModeFavorites, 3);
    std::vector<size_t> indexes = RoonVis::FlattenPresetShelfIndexes(shelves);
    if (mode == RoonVisPresetRotationModeFavorites && indexes.empty())
    {
        RoonVisLog(@"ProjectM settings: favourites rotation requested but no favourites exist; using Loop rotation");
        inputs = [self presetShelfInputsFavoritesOnly:NO includeHidden:YES];
        shelves = RoonVis::BuildPresetShelves(inputs, false, 3);
        indexes = RoonVis::FlattenPresetShelfIndexes(shelves);
    }
    return indexes;
}

- (size_t)rotationAnchorIndex
{
    // While a load is in flight (requested differs from confirmed), anchor on
    // the requested preset so rotation advance and warm-preload candidates
    // agree on where the walk continues from.
    if (_currentPresetIndex != SIZE_MAX && _currentPresetIndex != _confirmedPresetIndex)
    {
        return _currentPresetIndex;
    }
    return _confirmedPresetIndex != SIZE_MAX ? _confirmedPresetIndex : _currentPresetIndex;
}

- (size_t)nextRotationIndexFrom:(size_t)index offset:(NSInteger)offset
{
    if (_presetPaths.empty())
    {
        return SIZE_MAX;
    }

    RoonVisSettings *settings = [RoonVisSettings sharedSettings];
    RoonVisPresetRotationMode mode = settings.presetRotationMode;
    // Debug determinism hook: a fixed list overrides mode and skips the hidden/slow
    // filter (listed presets rotate regardless; always empty in Release).
    std::vector<size_t> order = _fixedRotationIndexes;
    std::function<bool(size_t)> excluded;
    if (!order.empty())
    {
        excluded = [self](size_t candidateIndex) {
            return candidateIndex >= self->_presetPaths.size();
        };
    }
    else
    {
        // The FULL mode order (hidden/slow entries retained) + an exclusion
        // predicate. The cursor continues from the anchor's order position even
        // when the anchor itself was just hidden or slow-marked; the historical
        // filtered-list search reset to the front in that case, looping the head
        // of the pack and starving the tail.
        order = [self fullRotationOrderForMode:mode];
        excluded = [self](size_t candidateIndex) {
            if (candidateIndex >= self->_presetPaths.size())
            {
                return true;
            }
            NSString *presetName = [self presetDisplayNameForPath:self->_presetPaths[candidateIndex]];
            return static_cast<bool>([self isPresetHiddenOrSlow:presetName]);
        };
    }
    if (order.empty())
    {
        return SIZE_MAX;
    }

    RoonVis::RotationAdvanceResult advance = RoonVis::AdvanceRotationCursor(order, index, offset, excluded);
    return advance.valid ? advance.index : SIZE_MAX;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    if (self.projectM != nullptr)
    {
        projectm_set_preset_switch_requested_event_callback(self.projectM, nullptr, nullptr);
        projectm_set_preset_switch_failed_event_callback(self.projectM, nullptr, nullptr);
        projectm_set_preprocess_cache(self.projectM, nullptr);
        projectm_destroy(self.projectM);
    }
    [_confirmedPresetName release];
    [_requestedPresetName release];
    [_warmedFirstFramePresetName release];
    [super dealloc];
}

- (void)resizeToDrawableSize:(CGSize)drawableSize
{
    self.drawableSize = drawableSize;
    RoonVisLog(@"ProjectM resize: drawable %.0fx%.0f", drawableSize.width, drawableSize.height);
    if (self.projectM == nullptr)
    {
        return;
    }

    size_t width = static_cast<size_t>(std::max<CGFloat>(1, drawableSize.width));
    size_t height = static_cast<size_t>(std::max<CGFloat>(1, drawableSize.height));
    projectm_set_fps(self.projectM, RoonVisEffectiveProjectMFPS());
    [self invalidatePreloadedPresetTracking];
    projectm_set_window_size(self.projectM, width, height);
}

@end
