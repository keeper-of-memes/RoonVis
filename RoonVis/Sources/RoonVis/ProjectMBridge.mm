#import "ProjectMBridgeInternal.h"

// The bridge is deliberately split across category files (+Audio/+Presets/+Warm);
// methods declared in the class extension are defined there, which this file's
// @implementation cannot see — a structural false positive of the split, not a
// missing definition (the linker catches genuinely missing ones).
#pragma clang diagnostic ignored "-Wincomplete-implementation"

#include "PresetRotationCursor.h"
#include "PreprocessCacheResource.h"

#import "RoonVisCapabilityCatalog.h"
#import "RoonVisCrashReporter.h"
#import "RoonVisPerfDiagnosticsSink.h"

#import <EGL/egl.h>
#import <UIKit/UIScreen.h>
#import <projectM-4/logging.h>

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <random>
#include <unordered_map>

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
// bundled preset is a cache hit (no transpile stutter). RVPP container written by the
// PreprocessCacheGen host tool — v1 (preprocess-only) and v2 (stage-tagged: preprocessed
// HLSL + Tier-1 parse/generate GLSL) both seed into the ONE cache; the binary parse lives
// in the shared, host-testable PreprocessCacheResource.cpp (format doc there).
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

    const RoonVis::RvppSeedResult result = RoonVis::SeedPreprocessCacheFromRvppBuffer(
        static_cast<const uint8_t *>(data.bytes), data.length, cache);
    if (!result.ok)
    {
        RoonVisLog(@"Preprocess cache: %s (no prepopulation)",
                   result.error != nullptr ? result.error : "malformed resource");
        return;
    }
    if (result.truncated)
    {
        RoonVisLog(@"Preprocess cache: %s (partial seed kept)",
                   result.error != nullptr ? result.error : "truncated");
    }
    RoonVisLog(@"Preprocess cache: v%u salt=%s seeded %zu preprocess + %zu parse-gen entries (%zu total)",
               result.version, result.salt.c_str(),
               result.preprocessEntries, result.parseGenEntries, cache.Seeds());
#if ROONVIS_ENABLE_DIAGNOSTIC_MODES
    // Campaign/verification visibility: RoonVisLog only reaches NSLog, which
    // headless captures cannot pull — mirror the seed result into the
    // perf-diagnostics file sink (same mechanism as FixedRotation/Thermal).
    RoonVisPerfDiagnosticsSinkAppendLine(
        [NSString stringWithFormat:@"PreprocessCacheSeed: v%u preprocess=%zu parseGen=%zu",
                                   result.version, result.preprocessEntries, result.parseGenEntries]);
#endif
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

#if ROONVIS_ENABLE_DIAGNOSTIC_MODES
// Campaign-harness mirror support: the names in `filenames` that
// ResolveFixedRotationIndexes would silently drop (no catalog basename match).
// Reimplements its exact basename-match rule bridge-side (the scheduler helper
// stays untouched); pass the same inputs the resolve call received.
static std::vector<std::string> RoonVisUnresolvedFixedRotationFilenames(
    const std::vector<std::string> &filenames,
    const std::vector<std::string> &presetPaths)
{
    std::vector<std::string> unresolved;
    for (const std::string &filename : filenames)
    {
        bool found = false;
        for (const std::string &path : presetPaths)
        {
            const size_t slash = path.find_last_of('/');
            const size_t nameStart = slash == std::string::npos ? 0 : slash + 1;
            if (path.compare(nameStart, std::string::npos, filename) == 0)
            {
                found = true;
                break;
            }
        }
        if (!found)
        {
            unresolved.push_back(filename);
        }
    }
    return unresolved;
}

// One-shot machine-readable thermal breadcrumb into the perf-diagnostics sink so
// campaign logs record the chip's starting thermal state (a hot A8 skews render
// timings). Diagnostic builds only, like the other campaign hooks.
static void RoonVisEmitThermalStateBreadcrumbOnce(void)
{
    static BOOL emitted = NO;
    if (emitted)
    {
        return;
    }
    emitted = YES;
    const char *state = "nominal";
    switch (NSProcessInfo.processInfo.thermalState)
    {
        case NSProcessInfoThermalStateNominal:
            state = "nominal";
            break;
        case NSProcessInfoThermalStateFair:
            state = "fair";
            break;
        case NSProcessInfoThermalStateSerious:
            state = "serious";
            break;
        case NSProcessInfoThermalStateCritical:
            state = "critical";
            break;
    }
    RoonVisPerfDiagnosticsSinkAppendLine([NSString stringWithFormat:@"Thermal: state=%s", state]);
}
#endif

// Maps the ObjC settings enum to the engine's RotationMode. The 4 values map 1:1;
// any unexpected value degrades to Loop (the safe default).
static RoonVis::RotationMode RoonVisEngineRotationMode(RoonVisPresetRotationMode mode)
{
    switch (mode)
    {
        case RoonVisPresetRotationModeShuffle:
            return RoonVis::RotationMode::Shuffle;
        case RoonVisPresetRotationModeFavorites:
            return RoonVis::RotationMode::Favorites;
        case RoonVisPresetRotationModeCategory:
            return RoonVis::RotationMode::Category;
        case RoonVisPresetRotationModeLoop:
        default:
            return RoonVis::RotationMode::Loop;
    }
}

// Diagnostic-only launch override of the rotation mode so the on-device 4-mode
// matrix can be driven headlessly (mirrors ROONVIS_ROTATION_FIXED_LIST). Returns
// the settings mode unchanged in Release / when unset or unrecognized. Non-static:
// declared in ProjectMBridgeInternal.h so the +Presets category's structured
// category-rotation log follows the effective mode too.
RoonVisPresetRotationMode RoonVisEffectiveRotationMode(RoonVisPresetRotationMode settingsMode)
{
#if ROONVIS_ENABLE_DIAGNOSTIC_MODES
    NSString *envValue = NSProcessInfo.processInfo.environment[@"ROONVIS_ROTATION_MODE"];
    NSString *key = [[envValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    if (key.length > 0)
    {
        if ([key isEqualToString:@"loop"])
        {
            return RoonVisPresetRotationModeLoop;
        }
        if ([key isEqualToString:@"shuffle"])
        {
            return RoonVisPresetRotationModeShuffle;
        }
        if ([key isEqualToString:@"favorites"] || [key isEqualToString:@"favourites"])
        {
            return RoonVisPresetRotationModeFavorites;
        }
        if ([key isEqualToString:@"category"])
        {
            return RoonVisPresetRotationModeCategory;
        }
        RoonVisLog(@"ProjectM rotation: ignoring unrecognized ROONVIS_ROTATION_MODE=%@", envValue);
    }
#endif
    return settingsMode;
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

        NSString *presetsRoot = [resourcePath stringByAppendingPathComponent:@"presets"];

        // Apple TV HD: device-verified allowlist only (no static A8 pass rule
        // exists; the list grows exclusively via burn-in - HDVerifiedPresets.json).
        // Loaded up front so its "paths" mirror can drive a direct catalog build
        // (below) that SKIPS the full 7.7k-file tree walk - ~6.6s on the A8,
        // otherwise all behind the launch screen. "presets" (names) stays the
        // source of truth and the filter net in the loop further down.
        NSSet<NSString *> *hdAllowlist = nil;
        NSArray *hdAllowlistPaths = nil;
        BOOL hdFullCatalogOverride = NO;
#if ROONVIS_ENABLE_DIAGNOSTIC_MODES
        // Compat-campaign hook: expose the FULL pack on the HD tier so burn-in
        // validation can test allowlist candidates (mirrors the other diagnostic
        // env hooks; compiled out of Release). Rotation stays governed by
        // ROONVIS_ROTATION_FIXED_LIST during campaigns.
        hdFullCatalogOverride =
            NSProcessInfo.processInfo.environment[@"ROONVIS_HD_FULL_CATALOG"].boolValue;
        if (hdFullCatalogOverride)
        {
            RoonVisLog(@"ProjectM pack: HD allowlist BYPASSED (ROONVIS_HD_FULL_CATALOG)");
        }
#endif
        // W2b: on the HD tier the evidence-backed capability manifest
        // (HDCapabilityManifest.json) supersedes the flat verified allowlist when
        // — and ONLY when — it loads Valid against this tier's expected profile.
        // FAIL-CLOSED: any other status (missing/malformed/profile-mismatch)
        // falls through to the legacy HDVerifiedPresets.json path below, which is
        // EXACTLY today's behavior. (Known hazard kept as-is, not widened: in the
        // legacy path a nil allowlist still means the tree walk runs
        // unrestricted; capability mode can never yield that state because
        // capabilityMode == YES implies the populated visibleNames net applies.)
        RoonVisCapabilityCatalog capabilityCatalog;
        BOOL capabilityMode = NO;
        if (RoonVisCurrentDeviceTier() == RoonVisDeviceTierHD && !hdFullCatalogOverride)
        {
            capabilityMode = RoonVisLoadHDCapabilityCatalog(capabilityCatalog);
            if (capabilityMode)
            {
                RoonVisLog(@"Capability manifest valid: %zu records, %zu browse-visible, %zu rotation-eligible, %zu safety-excluded (load+eval %.1f ms)",
                           capabilityCatalog.recordCount,
                           capabilityCatalog.visibleNames.size(),
                           capabilityCatalog.rotationEligibleCount,
                           capabilityCatalog.safetyExcludedCount,
                           capabilityCatalog.loadMillis);
            }
            else
            {
                RoonVisLog(@"Capability manifest %s: falling back to verified allowlist",
                           RoonVisManifestLoadStatusLabel(capabilityCatalog.status));
                NSString *allowPath = [[NSBundle mainBundle] pathForResource:@"HDVerifiedPresets" ofType:@"json"];
                NSData *allowData = allowPath != nil ? [NSData dataWithContentsOfFile:allowPath] : nil;
                NSDictionary *allowDict = allowData != nil
                    ? [NSJSONSerialization JSONObjectWithData:allowData options:0 error:nil]
                    : nil;
                NSArray *allowNames = [allowDict isKindOfClass:[NSDictionary class]] ? allowDict[@"presets"] : nil;
                NSArray *allowPaths = [allowDict isKindOfClass:[NSDictionary class]] ? allowDict[@"paths"] : nil;
                if ([allowNames isKindOfClass:[NSArray class]] && allowNames.count > 0)
                {
                    hdAllowlist = [NSSet setWithArray:allowNames];
                }
                if ([allowPaths isKindOfClass:[NSArray class]] && allowPaths.count > 0)
                {
                    hdAllowlistPaths = allowPaths;
                }
                RoonVisLog(@"ProjectM pack: HD tier allowlist %lu presets",
                           static_cast<unsigned long>(hdAllowlist.count));
            }
        }

        // Build the raw path list. HD fast path: resolve the allowlist "paths"
        // mirror directly (a handful of stats) when every entry exists on disk.
        // Otherwise a recursive tree walk - the CotC pack ships as
        // presets/<Top>/<Sub>/*.milk (NSBundle's pathsForResourcesOfType: does
        // not recurse). The fallback also covers a stale mirror after a burn-in
        // grows the name list without regenerating paths.
        NSMutableArray<NSString *> *treePaths = [NSMutableArray array];
        BOOL usedHDPathMirror = NO;
        if (capabilityMode)
        {
            // Capability fast path: the manifest's pack-relative paths for the
            // browse-visible records ARE the catalog universe (absent from the
            // manifest = not included, so nothing outside them could pass the
            // visibleNames net below anyway). A record whose file is missing
            // from the bundle (manifest/pack drift) is simply skipped —
            // fail-closed — so no full-tree-walk fallback is needed here.
            NSFileManager *fm = [NSFileManager defaultManager];
            NSUInteger missingOnDisk = 0;
            for (const std::string &relative : capabilityCatalog.visibleRelativePaths)
            {
                NSString *relString = [NSString stringWithUTF8String:relative.c_str()];
                NSString *full = relString != nil ? [presetsRoot stringByAppendingPathComponent:relString] : nil;
                if (full != nil && [fm fileExistsAtPath:full])
                {
                    [treePaths addObject:full];
                }
                else
                {
                    missingOnDisk++;
                }
            }
            usedHDPathMirror = YES;
            RoonVisLog(@"ProjectM pack: HD capability catalog resolved %lu paths (%lu missing on disk; skipped full tree walk)",
                       static_cast<unsigned long>(treePaths.count),
                       static_cast<unsigned long>(missingOnDisk));
        }
        if (hdAllowlistPaths != nil)
        {
            NSFileManager *fm = [NSFileManager defaultManager];
            NSMutableArray<NSString *> *resolved = [NSMutableArray arrayWithCapacity:hdAllowlistPaths.count];
            BOOL allPresent = YES;
            for (id rel in hdAllowlistPaths)
            {
                if (![rel isKindOfClass:[NSString class]]) { allPresent = NO; break; }
                NSString *full = [presetsRoot stringByAppendingPathComponent:(NSString *)rel];
                if (![fm fileExistsAtPath:full]) { allPresent = NO; break; }
                [resolved addObject:full];
            }
            if (allPresent && resolved.count > 0)
            {
                [treePaths addObjectsFromArray:resolved];
                usedHDPathMirror = YES;
                RoonVisLog(@"ProjectM pack: HD tier used path mirror (%lu presets, skipped full tree walk)",
                           static_cast<unsigned long>(resolved.count));
            }
        }
        if (!usedHDPathMirror)
        {
            NSDirectoryEnumerator<NSString *> *treeEnum = [[NSFileManager defaultManager] enumeratorAtPath:presetsRoot];
            for (NSString *relative in treeEnum)
            {
                if ([relative.pathExtension isEqualToString:@"milk"])
                {
                    [treePaths addObject:[presetsRoot stringByAppendingPathComponent:relative]];
                }
            }
        }
        // Sorted by full path = (category, subcategory, name): Loop mode walks
        // category order (intentional semantics change from author-cluster order).
        NSArray<NSString *> *presetPaths = [treePaths sortedArrayUsingSelector:@selector(compare:)];
        _presetPaths.reserve(presetPaths.count);
        NSUInteger slowPresetSkips = 0;
        NSUInteger crashPresetSkips = 0;
        NSUInteger staticHeavySkips = 0;
        NSUInteger hiddenPresetSkips = 0;
        RoonVisSettings *settings = [RoonVisSettings sharedSettings];
        for (NSString *path in presetPaths)
        {
            NSString *filename = path.lastPathComponent;
            // W2b: a capability-manifest record supersedes the legacy known-slow /
            // static-heavy verdicts for that filename (measured evidence wins);
            // no record -> the legacy verdict stands. The known-crash static list
            // stays a hard block either way.
            const std::string filenameKey =
                capabilityMode ? RoonVisNSStringToUTF8(filename) : std::string();
            const bool manifestHasRecord =
                capabilityMode && capabilityCatalog.recordNames.count(filenameKey) > 0;
            if (!manifestHasRecord && RoonVisIsKnownSlowPresetFilename(filename))
            {
                slowPresetSkips++;
                continue;
            }
            if (RoonVisIsKnownCrashingPresetFilename(filename))
            {
                crashPresetSkips++;
                continue;
            }
            if (!manifestHasRecord && RoonVisIsStaticHeavyPresetFilename(filename))
            {
                staticHeavySkips++;
                continue;
            }
            if ([settings isHiddenPresetFilename:filename])
            {
                hiddenPresetSkips++;
                continue;
            }
            if (capabilityMode && capabilityCatalog.visibleNames.count(filenameKey) == 0)
            {
                // safety != safe, or absent from the manifest (fail-closed: the
                // manifest covers verified + campaign presets; never-screened
                // presets keep the pre-manifest "not included" behavior).
                continue;
            }
            if (hdAllowlist != nil && ![hdAllowlist containsObject:filename])
            {
                continue;
            }
            _presetPaths.emplace_back(path.fileSystemRepresentation);
            // Category metadata from the tree: presets/<Top>/<Sub>/name.milk.
            NSString *relDir = [[path stringByDeletingLastPathComponent]
                substringFromIndex:MIN(presetsRoot.length + 1, [path stringByDeletingLastPathComponent].length)];
            NSArray<NSString *> *dirParts = relDir.pathComponents;
            _presetCategories.emplace_back(dirParts.count >= 1 && dirParts[0].length > 0
                                               ? RoonVisNSStringToUTF8(dirParts[0]) : std::string());
            _presetSubcategories.emplace_back(dirParts.count >= 2
                                                  ? RoonVisNSStringToUTF8(dirParts[1]) : std::string());
        }
        // NOTE: the historical per-launch std::shuffle of _presetPaths is REMOVED -
        // Shuffle mode owns permutation; the stable (category, subcategory, name)
        // order is what Loop mode and the category metadata rely on.
#if ROONVIS_ENABLE_DIAGNOSTIC_MODES
        // Startup breadcrumb for campaign harnesses (W1): thermal state into the
        // pullable perf-diagnostics sink, once per process.
        RoonVisEmitThermalStateBreadcrumbOnce();
#endif
        const std::vector<std::string> fixedRotationFilenames = RoonVisFixedRotationListFilenames();
        if (!fixedRotationFilenames.empty())
        {
            _fixedRotationIndexes = RoonVis::ResolveFixedRotationIndexes(fixedRotationFilenames, _presetPaths);
            RoonVisLog(@"Fixed rotation list: %zu/%zu presets resolved",
                       _fixedRotationIndexes.size(),
                       fixedRotationFilenames.size());
#if ROONVIS_ENABLE_DIAGNOSTIC_MODES
            // Mirror the resolve result into the perf-diagnostics file sink: device
            // campaigns can only pull Library/Caches/perf-diagnostics.log, not NSLog.
            // The harness verifies requested==its list count and resolved==requested
            // before burning a session on a mis-set ROONVIS_ROTATION_FIXED_LIST.
            RoonVisPerfDiagnosticsSinkAppendLine(
                [NSString stringWithFormat:@"FixedRotation: requested=%zu resolved=%zu",
                                           fixedRotationFilenames.size(),
                                           _fixedRotationIndexes.size()]);
            if (_fixedRotationIndexes.size() < fixedRotationFilenames.size())
            {
                // Name the drops (ResolveFixedRotationIndexes discards them silently).
                // Pipe-joined to match the list's own delimiter; capped so one bad
                // batch cannot flood the log.
                const size_t kMaxUnresolvedNames = 20;
                const std::vector<std::string> unresolved =
                    RoonVisUnresolvedFixedRotationFilenames(fixedRotationFilenames, _presetPaths);
                std::string joined;
                const size_t reportCount = std::min(unresolved.size(), kMaxUnresolvedNames);
                for (size_t i = 0; i < reportCount; i++)
                {
                    if (i > 0)
                    {
                        joined += '|';
                    }
                    joined += unresolved[i];
                }
                RoonVisPerfDiagnosticsSinkAppendLine(
                    [NSString stringWithFormat:@"FixedRotationUnresolved: %s", joined.c_str()]);
            }
#endif
        }
        // One-time migration of the legacy single-shuffle pair into the scoped
        // store BEFORE the engine loads it (formerly the first step of
        // restoreOrRegenerateShuffleOrder).
        [self migrateLegacyShuffleOrderIfNeeded];
        // Adopt the RotationEngine: seed its catalog + favorites/hidden/slow/
        // mode/fixed-order/store from current bridge state, then provide a reseed
        // source so it can regenerate an order whose persisted fingerprint is
        // stale (restore-or-reseed happens lazily, on the first order query).
        // ReseedShuffle mirrors regenerateShuffleOrder's arc4random() source.
        [self seedRotationEngine];
        if (capabilityMode)
        {
            // W2b: the manual-only/warmup set — browse-visible but not yet
            // rotation-eligible under the all-false W5 readiness stub. A
            // query-time filter only: seeded orders keep these names, so when
            // W5/W7a later clears a name it joins rotation WITHOUT a reseed.
            // Manual picks bypass this by design (selectPresetAtIndex: never
            // consults the engine's query predicate; fixed-order ditto).
            const size_t temporarilyUnavailableCount = capabilityCatalog.temporarilyUnavailable.size();
            _rotationEngine.SetTemporarilyUnavailable(std::move(capabilityCatalog.temporarilyUnavailable));
            RoonVisLog(@"Capability manifest: catalog=%zu rotation-eligible=%zu temporarily-unavailable=%zu",
                       _presetPaths.size(),
                       capabilityCatalog.rotationEligibleCount,
                       temporarilyUnavailableCount);
        }
        _rotationEngine.ReseedShuffle(arc4random());
        [self drainRotationEngineDirtyScopes];
        // Router memory for the entering-Shuffle reseed rule (NOT engine state).
        _lastRotationMode = RoonVisEffectiveRotationMode([RoonVisSettings sharedSettings].presetRotationMode);
        // A5: establish a defined dwell-plan state after the engine is seeded (packLoaded/
        // fixed-list). Nothing is confirmed yet so both plans are Idle; the first confirm's
        // funnel arms them. (Kept explicit so init order is self-documenting.)
        [self recomputeDwellPlansAtTime:CACurrentMediaTime()];
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
    // settingsDidChange is a key -> RotationEngine event router. A5: the former
    // unconditional invalidatePreloadedPresetTracking is narrowed to exactly the recompute
    // legs below. Rationale: the dwell plan's event set now covers everything that affects
    // the next preset OR the settle/lead windows (favorites/hidden -> which next preset;
    // mode -> which next preset + reseed; rotation interval / transition style / crossfade
    // -> the settle window and fit). Keys that touch none of that (audioInputDelayMs,
    // diagnosticsOverlay, warpMeshWidth, frameRateCap, drawableSize, snapcastHost,
    // audio/beat sensitivity) must NOT invalidate a valid preload — invalidating on them
    // was pure churn that dropped a good warm for no reason. Each recompute leg sets
    // needsDwellRecompute; recomputeDwellPlansAtTime: (which invalidates) runs ONCE after
    // applySettings so the new window values are in place.
    BOOL needsDwellRecompute = NO;

    NSString *changedKey = notification.userInfo[@"key"];

    // Favorites key -> SetFavorites. (nil key = programmatic notification: push all.)
    if (changedKey == nil || [changedKey isEqualToString:RoonVisSettingsFavoritePresetFilenamesKey])
    {
        [self pushRotationEngineFavorites];
        needsDwellRecompute = YES; // listsChanged
    }
    // Hidden key -> SetHidden.
    if (changedKey == nil || [changedKey isEqualToString:RoonVisSettingsHiddenPresetFilenamesKey])
    {
        [self pushRotationEngineHidden];
        needsDwellRecompute = YES; // listsChanged
    }
    // Order/timing keys -> the settle window / fit inputs of the dwell plan changed.
    if (changedKey == nil ||
        [changedKey isEqualToString:RoonVisSettingsRotationIntervalSecondsKey] ||
        [changedKey isEqualToString:RoonVisSettingsTransitionStyleKey] ||
        [changedKey isEqualToString:RoonVisSettingsCrossfadeDurationSecondsKey])
    {
        needsDwellRecompute = YES; // order/timing
    }
    // Rotation-mode key (and the favorites-only toggle, a mode change under the
    // hood) -> SetMode + the EXACT existing reseed rule.
    if (changedKey == nil ||
        [changedKey isEqualToString:RoonVisSettingsPresetRotationModeKey] ||
        [changedKey isEqualToString:RoonVisSettingsFavoritesOnlyRotationKey])
    {
        needsDwellRecompute = YES; // modeChanged
        RoonVisPresetRotationMode newMode =
            RoonVisEffectiveRotationMode([RoonVisSettings sharedSettings].presetRotationMode);
        [self pushRotationEngineMode];
        // Reseed the Shuffle order only when the user transitions INTO Shuffle, so
        // selecting Shuffle produces a fresh sequence rather than the launch order
        // (issue #6). EXCEPT when returning from Category mode: a Category detour must
        // never touch the global Shuffle entry (scoped-store non-clobber contract), so
        // Shuffle resumes the persisted sequence exactly where it left off.
        // _lastRotationMode is the router's memory of the previous mode; it survives
        // the A4b deletions because the engine has no "previous mode" concept.
        if (newMode == RoonVisPresetRotationModeShuffle &&
            _lastRotationMode != RoonVisPresetRotationModeShuffle &&
            _lastRotationMode != RoonVisPresetRotationModeCategory)
        {
            // ForceReshuffle == legacy regenerateShuffleOrder: a FRESH sequence
            // even when a fingerprint-valid persisted order exists (plain
            // ReseedShuffle would restore it — launch semantics, not this).
            _rotationEngine.ForceReshuffle(arc4random());
            (void)_rotationEngine.FullOrder(); // materialize + mark "" dirty
        }
        _lastRotationMode = newMode;
    }

    // R3: drain after the full event batch (a reseed above dirties scope "";
    // no-op otherwise). Anchor state is untouched by settings keys (R2).
    [self drainRotationEngineDirtyScopes];
    [self applySettings];
    // A5: recompute the dwell plans AFTER applySettings so the new rotation interval /
    // crossfade / transition style are already in the ivars the plan reads. This also
    // invalidates the preloaded-preset tracking (only on the recompute legs).
    if (needsDwellRecompute)
    {
        [self recomputeDwellPlansAtTime:CACurrentMediaTime()];
    }
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
    BOOL burninDwellOverridden = NO;
    {
        NSString *burninDwell = NSProcessInfo.processInfo.environment[@"ROONVIS_ROTATION_SECONDS"];
        if (burninDwell.length > 0 && burninDwell.doubleValue > 0.0)
        {
            presetDuration = burninDwell.doubleValue;
            burninDwellOverridden = YES;
        }
    }
    // Crossfade override (dev/QA): forces the soft-cut duration, 0 allowed
    // (instant cuts — no dual-render — for screening campaigns); 2-5 s for
    // transition-cost studies. Below/above the settings clamp by design.
    {
        NSString *xfade = NSProcessInfo.processInfo.environment[@"ROONVIS_CROSSFADE_SECONDS"];
        if (xfade.length > 0 && xfade.doubleValue >= 0.0)
        {
            softCutDuration = xfade.doubleValue;
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
#if ROONVIS_ENABLE_DIAGNOSTIC_MODES
    // The dwell override must ALSO reach the app-owned rotation scheduler: dwell
    // plans and rotation advance consume _rotationIntervalSeconds, not projectM's
    // preset duration, so overriding only presetDuration leaves campaigns rotating
    // at the settings default (the "ROONVIS_ROTATION_SECONDS ignored" bug, re-hit
    // by W2 batch 1 which ran 60 s dwells against a requested 30 s).
    if (burninDwellOverridden)
    {
        _rotationIntervalSeconds = presetDuration;
    }
#endif
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
    // A4b: the engine owns exclusion (hidden ∪ slow; empty name excluded). Its
    // sets stay synced by the settingsDidChange router (hidden) and
    // pushRotationEngineSlow (slow), both of which fire synchronously on the
    // main/GL thread before any caller can observe stale state.
    return _rotationEngine.IsExcludedName(RoonVisNSStringToUTF8(presetName)) ? YES : NO;
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
        if (index < _presetCategories.size())
        {
            input.category = _presetCategories[index];
            input.subcategory = _presetSubcategories[index];
        }
        inputs.push_back(input);
    }
    return inputs;
}

// Scoped rotation-order store: {scope -> {filenames, fingerprint}}. Scope "" is
// the global Shuffle order (migrated once from the legacy pair below); scope
// "<CategoryName>" is that category's order (Category rotation mode). Writes go
// through RoonVis::UpsertScopedRotationOrder, whose host-tested contract is that
// writing one scope never touches another - entering/leaving Category mode can
// never clobber the global Shuffle sequence.
static NSString *const kScopedRotationOrdersKey = @"RoonVisScopedRotationOrders";
static NSString *const kScopedRotationOrderFilenamesField = @"filenames";
static NSString *const kScopedRotationOrderFingerprintField = @"fingerprint";
static NSString *const kGlobalShuffleScope = @"";
// The scoped store lives in a Caches plist, NOT NSUserDefaults: tvOS
// SIGKILLs any app whose preferences exceed ~1MB, and one CotC-scale order is
// ~550KB of filenames (7.7k names) - the global scope plus a couple of
// category scopes crossed the limit and the app was killed at launch on the
// very write that persisted them. Caches because tvOS apps may only write to
// Caches and tmp (a Documents write fails on device); the system purging the
// file only costs a reseed.
static NSString *RoonVisScopedRotationOrdersFilePath(void)
{
    NSArray<NSString *> *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    if (caches.count == 0)
    {
        return nil;
    }
    return [caches.firstObject stringByAppendingPathComponent:@"ScopedRotationOrders.plist"];
}
// Legacy single-shuffle keys, superseded by the scoped store.
static NSString *const kLegacyShuffleOrderFilenamesKey = @"RoonVisShuffleOrderFilenames";
static NSString *const kLegacyShuffleOrderFingerprintKey = @"RoonVisShuffleOrderFingerprint";

// A4b: fingerprint computation moved into RotationEngine (FingerprintForScope,
// fed by SetLearnedSlowConfirmed — the confirmed set only, per R1). The methods
// below are the thin plist load/drain adapters the engine persists through
// (byte-identical serialization, host-tested UpsertScopedRotationOrder merge).

- (void)writeScopedRotationOrdersFile:(NSDictionary *)serialized
{
    NSString *path = RoonVisScopedRotationOrdersFilePath();
    if (path == nil)
    {
        return;
    }
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:serialized
                                                              format:NSPropertyListBinaryFormat_v1_0
                                                             options:0
                                                               error:NULL];
    if (data == nil || ![data writeToFile:path atomically:YES])
    {
        RoonVisLog(@"ProjectM rotation: FAILED to write scoped order store (%lu scopes)",
                   static_cast<unsigned long>(serialized.count));
    }
}

- (NSDictionary *)scopedRotationOrders
{
    NSString *path = RoonVisScopedRotationOrdersFilePath();
    NSData *data = path != nil ? [NSData dataWithContentsOfFile:path] : nil;
    id store = data != nil
        ? [NSPropertyListSerialization propertyListWithData:data
                                                    options:NSPropertyListImmutable
                                                     format:NULL
                                                      error:NULL]
        : nil;
    // One-shot rescue of the store from NSUserDefaults (where it originally
    // lived and could grow past the tvOS ~1MB kill threshold): adopt it into
    // the file if the file has nothing, and remove the oversized key either
    // way so the preferences plist shrinks back under the limit.
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSDictionary *defaultsStore = [defaults dictionaryForKey:kScopedRotationOrdersKey];
    if (defaultsStore != nil)
    {
        if (![store isKindOfClass:NSDictionary.class] || [store count] == 0)
        {
            store = defaultsStore;
            [self writeScopedRotationOrdersFile:defaultsStore];
        }
        [defaults removeObjectForKey:kScopedRotationOrdersKey];
        RoonVisLog(@"ProjectM rotation: moved scoped order store out of NSUserDefaults (%lu scopes)",
                   static_cast<unsigned long>(defaultsStore.count));
    }
    return [store isKindOfClass:NSDictionary.class] ? store : @{};
}

// The validated {filenames, fingerprint} entry for `scope`, or nil when absent
// or malformed.
- (nullable NSDictionary *)scopedRotationOrderEntryForScope:(NSString *)scope
{
    NSDictionary *entry = [self scopedRotationOrders][scope];
    if (![entry isKindOfClass:NSDictionary.class])
    {
        return nil;
    }
    NSArray *filenames = entry[kScopedRotationOrderFilenamesField];
    NSString *fingerprint = entry[kScopedRotationOrderFingerprintField];
    if (![filenames isKindOfClass:NSArray.class] || filenames.count == 0 ||
        ![fingerprint isKindOfClass:NSString.class] || fingerprint.length == 0)
    {
        return nil;
    }
    return entry;
}

- (void)persistScopedRotationOrderFilenames:(NSArray<NSString *> *)filenames
                                fingerprint:(NSString *)fingerprint
                                   forScope:(NSString *)scope
{
    // Round-trip through the pure C++ store so the merge semantics (write one
    // scope, preserve every other verbatim) are the host-tested ones.
    RoonVis::ScopedRotationOrderStore store;
    NSDictionary *existing = [self scopedRotationOrders];
    for (NSString *existingScope in existing)
    {
        if (![existingScope isKindOfClass:NSString.class])
        {
            continue;
        }
        NSDictionary *entry = existing[existingScope];
        if (![entry isKindOfClass:NSDictionary.class])
        {
            continue;
        }
        NSArray *entryFilenames = entry[kScopedRotationOrderFilenamesField];
        NSString *entryFingerprint = entry[kScopedRotationOrderFingerprintField];
        if (![entryFilenames isKindOfClass:NSArray.class] || ![entryFingerprint isKindOfClass:NSString.class])
        {
            continue;
        }
        RoonVis::ScopedRotationOrder order;
        order.filenames.reserve(entryFilenames.count);
        for (id item in entryFilenames)
        {
            if ([item isKindOfClass:NSString.class])
            {
                order.filenames.push_back(RoonVisNSStringToUTF8(static_cast<NSString *>(item)));
            }
        }
        order.fingerprint = RoonVisNSStringToUTF8(entryFingerprint);
        store[RoonVisNSStringToUTF8(existingScope)] = std::move(order);
    }

    RoonVis::ScopedRotationOrder entry;
    entry.filenames.reserve(filenames.count);
    for (NSString *filename in filenames)
    {
        entry.filenames.push_back(RoonVisNSStringToUTF8(filename));
    }
    entry.fingerprint = RoonVisNSStringToUTF8(fingerprint);
    store = RoonVis::UpsertScopedRotationOrder(store, RoonVisNSStringToUTF8(scope), entry);

    NSMutableDictionary *serialized = [NSMutableDictionary dictionaryWithCapacity:store.size()];
    for (const auto &pair : store)
    {
        NSMutableArray<NSString *> *entryFilenames = [NSMutableArray arrayWithCapacity:pair.second.filenames.size()];
        for (const std::string &filename : pair.second.filenames)
        {
            [entryFilenames addObject:[NSString stringWithUTF8String:filename.c_str()]];
        }
        serialized[[NSString stringWithUTF8String:pair.first.c_str()]] = @{
            kScopedRotationOrderFilenamesField : entryFilenames,
            kScopedRotationOrderFingerprintField : [NSString stringWithUTF8String:pair.second.fingerprint.c_str()],
        };
    }
    [self writeScopedRotationOrdersFile:serialized];
}

// One-time migration of the legacy single-shuffle pair into scope "" of the
// scoped store. The legacy keys are removed either way; an existing scope ""
// entry is never overwritten.
- (void)migrateLegacyShuffleOrderIfNeeded
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSArray *legacyOrder = [defaults arrayForKey:kLegacyShuffleOrderFilenamesKey];
    NSString *legacyFingerprint = [defaults stringForKey:kLegacyShuffleOrderFingerprintKey];
    if (legacyOrder == nil && legacyFingerprint == nil)
    {
        return;
    }
    if ([self scopedRotationOrderEntryForScope:kGlobalShuffleScope] == nil &&
        [legacyOrder isKindOfClass:NSArray.class] && legacyOrder.count > 0 && legacyFingerprint.length > 0)
    {
        [self persistScopedRotationOrderFilenames:legacyOrder
                                      fingerprint:legacyFingerprint
                                         forScope:kGlobalShuffleScope];
        RoonVisLog(@"ProjectM rotation: migrated legacy shuffle order (%lu entries) into scoped store",
                   static_cast<unsigned long>(legacyOrder.count));
    }
    [defaults removeObjectForKey:kLegacyShuffleOrderFilenamesKey];
    [defaults removeObjectForKey:kLegacyShuffleOrderFingerprintKey];
}

// --- RotationEngine adoption plumbing -----------------------------------------
// A4b: the legacy restore/persist/reseed helpers (restoredScopedOrderForScope,
// persistShuffleOrder, restoreOrRegenerateShuffleOrder, regenerateShuffleOrder,
// rotationAnchorCategoryName, categoryRotationOrderForCategory) are deleted —
// RotationEngine owns restore-or-reseed, fingerprints, and the Category scope.
// What remains bridge-side is the plist file adapter (scopedRotationOrders /
// persistScopedRotationOrderFilenames, byte-identical serialization) plus the
// event pushers and the dirty-scope drain below.

// Convert an NSSet<NSString*> of preset filenames to a display-name key set,
// matching the engine catalog keys (path.lastPathComponent == filename here).
static std::unordered_set<std::string> RoonVisFilenameSetToUnordered(NSSet<NSString *> *names)
{
    std::unordered_set<std::string> result;
    result.reserve(names.count);
    for (NSString *name in names)
    {
        if ([name isKindOfClass:NSString.class] && name.length > 0)
        {
            result.insert(RoonVisNSStringToUTF8(name));
        }
    }
    return result;
}

- (void)pushRotationEngineFavorites
{
    _rotationEngine.SetFavorites(RoonVisFilenameSetToUnordered([RoonVisSettings sharedSettings].favoritePresetFilenames));
}

- (void)pushRotationEngineHidden
{
    _rotationEngine.SetHidden(RoonVisFilenameSetToUnordered([RoonVisSettings sharedSettings].hiddenPresetFilenames));
}

- (void)pushRotationEngineSlow
{
    // Exclusion set: session-slow ∪ learned-slow-confirmed (mirrors _slowPresetNames,
    // which loadLearnedSlowPresets seeds with the confirmed set and markPresetNameSlow
    // grows at runtime). Fingerprint input: the learned-slow CONFIRMED set ONLY.
    std::unordered_set<std::string> exclusion(_slowPresetNames.begin(), _slowPresetNames.end());
    _rotationEngine.SetSlowNames(std::move(exclusion));
    const std::set<std::string> &confirmed = _learnedSlowStore.ConfirmedNames();
    _rotationEngine.SetLearnedSlowConfirmed(std::unordered_set<std::string>(confirmed.begin(), confirmed.end()));
}

- (void)pushRotationEngineMode
{
    RoonVisPresetRotationMode mode =
        RoonVisEffectiveRotationMode([RoonVisSettings sharedSettings].presetRotationMode);
    _rotationEngine.SetMode(RoonVisEngineRotationMode(mode));
}

- (void)updateRotationEngineAnchor
{
    // Confirmed = on-screen preset; requested = the in-flight target (the bridge's
    // rotationAnchorIndex when a load is mid-flight, else the confirmed index).
    _rotationEngine.SetAnchor(_confirmedPresetIndex, [self rotationAnchorIndex]);
}

- (void)drainRotationEngineDirtyScopes
{
    std::string scope;
    RoonVis::ScopedRotationOrder entry;
    while (_rotationEngine.TakeDirtyScope(scope, entry))
    {
        NSString *scopeStr = [NSString stringWithUTF8String:scope.c_str()] ?: @"";
        NSMutableArray<NSString *> *filenames = [NSMutableArray arrayWithCapacity:entry.filenames.size()];
        for (const std::string &filename : entry.filenames)
        {
            NSString *value = [NSString stringWithUTF8String:filename.c_str()];
            if (value != nil)
            {
                [filenames addObject:value];
            }
        }
        NSString *fingerprint = [NSString stringWithUTF8String:entry.fingerprint.c_str()] ?: @"";
        [self persistScopedRotationOrderFilenames:filenames fingerprint:fingerprint forScope:scopeStr];
    }
}

- (void)seedRotationEngine
{
    // Catalog: display name (path.lastPathComponent), human title, top/sub category
    // from the parallel vectors. favorite=false always (R5: favorites are a runtime
    // set fed via SetFavorites, never baked into the fixed catalog).
    std::vector<RoonVis::RotationCatalogEntry> catalog;
    catalog.reserve(_presetPaths.size());
    for (size_t index = 0; index < _presetPaths.size(); index++)
    {
        RoonVis::RotationCatalogEntry entry;
        entry.filename = RoonVisNSStringToUTF8([self presetDisplayNameForPath:_presetPaths[index]]);
        entry.title = RoonVisNSStringToUTF8(RoonVisHumanPresetTitle([self presetDisplayNameAtIndex:index], index));
        if (index < _presetCategories.size())
        {
            entry.category = _presetCategories[index];
        }
        if (index < _presetSubcategories.size())
        {
            entry.subcategory = _presetSubcategories[index];
        }
        entry.favorite = false;
        catalog.push_back(std::move(entry));
    }
    _rotationEngine.SetCatalog(std::move(catalog));

    // Favorites / hidden / slow(+confirmed) / mode.
    [self pushRotationEngineFavorites];
    [self pushRotationEngineHidden];
    [self pushRotationEngineSlow];
    [self pushRotationEngineMode];

    // Fixed-order debug hook (parsed ObjC-side into _fixedRotationIndexes above).
    _rotationEngine.SetFixedOrder(_fixedRotationIndexes);

    // Load the persisted scoped-order store (the whole store, not per-scope) so the
    // engine can restore-or-reseed each scope on demand.
    RoonVis::ScopedRotationOrderStore store;
    NSDictionary *existing = [self scopedRotationOrders];
    for (NSString *existingScope in existing)
    {
        if (![existingScope isKindOfClass:NSString.class])
        {
            continue;
        }
        NSDictionary *entry = existing[existingScope];
        if (![entry isKindOfClass:NSDictionary.class])
        {
            continue;
        }
        NSArray *entryFilenames = entry[kScopedRotationOrderFilenamesField];
        NSString *entryFingerprint = entry[kScopedRotationOrderFingerprintField];
        if (![entryFilenames isKindOfClass:NSArray.class] || ![entryFingerprint isKindOfClass:NSString.class])
        {
            continue;
        }
        RoonVis::ScopedRotationOrder order;
        order.filenames.reserve(entryFilenames.count);
        for (id item in entryFilenames)
        {
            if ([item isKindOfClass:NSString.class])
            {
                order.filenames.push_back(RoonVisNSStringToUTF8(static_cast<NSString *>(item)));
            }
        }
        order.fingerprint = RoonVisNSStringToUTF8(entryFingerprint);
        store[RoonVisNSStringToUTF8(existingScope)] = std::move(order);
    }
    _rotationEngine.LoadScopedOrders(std::move(store));
    // LoadScopedOrders is a restore, not a reseed: it must not dirty. No drain here.
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

    // A4b: the engine owns selection for ALL modes. Its NextFrom handles the fixed
    // list (mode override + bounds-only exclusion), the shuffle/loop/favorites/
    // category full order, and the hidden/slow exclusion predicate identically to
    // the former legacy walk (FULL order retained so the cursor's anchor stays
    // findable after an exclusion; exclusion is a predicate at advance time). The
    // Category order is anchor-driven, so sync the engine anchor from the current
    // confirmed/requested indexes BEFORE the query (R2: anchor batched before any
    // drain). A shuffle/category query may reseed, so drain afterward (R3).
    [self updateRotationEngineAnchor];
    size_t next = _rotationEngine.NextFrom(index, offset);
    [self drainRotationEngineDirtyScopes];
    return next;
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
    if (self.projectM == nullptr)
    {
        RoonVisLog(@"ProjectM resize: drawable %.0fx%.0f", drawableSize.width, drawableSize.height);
        return;
    }

    size_t width = static_cast<size_t>(std::max<CGFloat>(1, drawableSize.width));
    size_t height = static_cast<size_t>(std::max<CGFloat>(1, drawableSize.height));
    // W0 same-size guard: re-applying an unchanged size (layout passes, settings
    // notifications) must not drop a valid preset preload — the dwell recompute below
    // invalidates preload tracking — nor re-run projectm_set_window_size. A genuine EGL
    // surface recreation at the SAME size still invalidates the preload slot; that path
    // calls -noteEGLSurfaceRecreated, which forces the recompute this guard skips.
    if (width == _appliedProjectMWindowWidth && height == _appliedProjectMWindowHeight)
    {
        RoonVisLog(@"Drawable config skipped: size unchanged (%zux%zu)", width, height);
        return;
    }
    RoonVisLog(@"ProjectM resize: drawable %.0fx%.0f", drawableSize.width, drawableSize.height);
    // A5: a resize drops the compiled preload slot (surface recreated). Recompute the dwell
    // plans (which invalidates the preload tracking) so a plan left Satisfied by an earlier
    // warm re-arms and re-warms against the new surface instead of thinking it is done.
    // (fps hint is decoupled: see -refreshProjectMFPSHint.)
    [self recomputeDwellPlansAtTime:CACurrentMediaTime()];
    projectm_set_window_size(self.projectM, width, height);
    _appliedProjectMWindowWidth = width;
    _appliedProjectMWindowHeight = height;
}

- (NSUInteger)transpileCacheHits
{
    return static_cast<NSUInteger>(_preprocessCache.Hits());
}

- (NSUInteger)transpileCacheMisses
{
    return static_cast<NSUInteger>(_preprocessCache.Misses());
}

- (void)refreshProjectMFPSHint
{
    if (self.projectM == nullptr)
    {
        return;
    }
    projectm_set_fps(self.projectM, RoonVisEffectiveProjectMFPS());
}

- (void)noteEGLSurfaceRecreated
{
    if (self.projectM == nullptr)
    {
        return;
    }
    // A recreated surface invalidates the compiled preload slot even when the drawable
    // size is unchanged (so -resizeToDrawableSize:'s guard will skip). Re-arm the dwell
    // plans so a Satisfied plan re-warms against the new surface. This also covers the
    // swap-failure recovery recreate, which never went through resize at all.
    [self recomputeDwellPlansAtTime:CACurrentMediaTime()];
}

@end
