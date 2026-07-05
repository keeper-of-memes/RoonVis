#import "ProjectMBridge.h"
#import "LearnedSlowPresetStore.h"
#import "ProjectMPresetSupport.h"
#import "PresetRotationScheduler.h"
#import "PresetShelfModel.h"
#import "PresetWarmCache.h"
#import "PreprocessCache.h"
#import "RoonVisSettings.h"
#import "SnapPCM.h"

#import <QuartzCore/QuartzCore.h>
#import <GLES3/gl3.h>
#import <projectM-4/projectM.h>

#include <algorithm>
#include <mutex>
#include <set>
#include <string>
#include <vector>

static constexpr unsigned int kLivePCMSampleRate = 44100;
static constexpr size_t kLivePCMMaxBufferFrames = (kLivePCMSampleRate * 1100) / 1000; // ~1.1 s cap
static constexpr CFTimeInterval kLivePCMMajorStallSeconds = 0.25;

static inline size_t LivePCMDelayFramesForMilliseconds(NSInteger delayMs)
{
    NSInteger clampedDelayMs = MAX(0, MIN(500, delayMs));
    size_t frames = (static_cast<size_t>(clampedDelayMs) * kLivePCMSampleRate) / 1000;
    return std::min(frames, kLivePCMMaxBufferFrames - 1);
}

// Shared free helpers implemented in ProjectMBridge.mm and used by both the base
// implementation and the ProjectMBridge+Warm category (behavior-neutral extraction of
// the warm-cache/preload code out of the base file). Keeping the definitions in the base
// file preserves their existing behavior; the declarations here give the category access.
inline constexpr double kPerfSweepPresetDurationSeconds = 6.0;
inline constexpr double kPerfSweepSoftCutDurationSeconds = 0.5;

BOOL RoonVisPerfSweepPresetTimingEnabled(void);
BOOL RoonVisCrasherScanModeEnabled(void);
unsigned int RoonVisDisplayRefreshRate(void);
void *ProjectMANGLELoadProc(const char *name, void *userData);

NS_ASSUME_NONNULL_BEGIN

@interface ProjectMBridge ()
{
    RoonVis::WavData _wav;
    std::mutex _livePCMMutex;
    RoonVis::LivePCMDelayBuffer _livePCMBuffer;
    std::vector<int16_t> _livePCMRenderSamples;
    std::vector<int16_t> _pcmGainBuffer;
    std::vector<std::string> _presetPaths;
    std::vector<size_t> _browsePresetOrderIndexes;
    // Debug-only deterministic-rotation test hook (ROONVIS_ROTATION_FIXED_LIST). Only
    // ever populated under ROONVIS_ENABLE_DIAGNOSTIC_MODES; always empty in Release.
    std::vector<size_t> _fixedRotationIndexes;
    // Shuffle rotation order, reseeded each time the user selects Shuffle (issue #6).
    std::vector<size_t> _shuffleOrderIndexes;
    RoonVisPresetRotationMode _lastRotationMode;
    std::set<std::string> _slowPresetNames;
    RoonVis::LearnedSlowPresetStore _learnedSlowStore;
    size_t _currentPresetIndex;
    size_t _confirmedPresetIndex;
    size_t _lastGoodPresetIndex;
    size_t _preloadedPresetIndex;
    size_t _preloadAttemptPresetIndex;
    std::string _preloadedPresetPath;
    std::string _preloadAttemptPresetPath;
    NSString *_warmedFirstFramePresetName;
    // Phase 3c diagnostics: proves the preload's shader compile actually ran in the
    // background (ready poll must read false at least once, then flip true).
    CFTimeInterval _preloadCompileStartTime;
    int _preloadCompilePollCount;
    BOOL _preloadCompileReadyLogged;
    NSInteger _presetStepDirection;
    RoonVis::PresetRotationScheduler _rotationScheduler;
    CFTimeInterval _lastPresetSwitchTime;
    NSInteger _audioInputDelayMs;
    NSInteger _effectiveAudioDelayMs;
    size_t _audioDelayFrames;
    double _audioSensitivity;
    RoonVisTransitionStyle _transitionStyle;
    double _rotationIntervalSeconds;
    double _crossfadeDurationSeconds;
    NSInteger _appliedWarpMeshWidth;   // warp mesh width currently set on projectM (GL thread)
    BOOL _warpMeshOverrideActive;      // ROONVIS_MESH_SIZE env override in force; ignore the setting
    BOOL _lastPresetLoadFailed;
    BOOL _revertingToLastGoodPreset;
    BOOL _presetRotationHeld;
    BOOL _preloadingPreset;
    bool _livePCMActive;
    bool _livePCMInFallback;
    CFTimeInterval _lastLivePCMEnqueueTime;
    CFTimeInterval _lastLivePCMRenderTime;
    NSInteger _pendingAudioInputDelayMs;
    BOOL _hasPendingAudioDelay;
    // Preprocessed-HLSL cache + the C hooks bridged to it. Both outlive the projectM
    // instance (owned here on the bridge). All access is on the GL/render thread, where
    // transpile runs, so no locking is needed. Registered via projectm_set_preprocess_cache.
    RoonVis::PreprocessCache _preprocessCache;
    projectm_preprocess_cache_hooks _preprocessCacheHooks;
}

@property(nonatomic, assign, nullable) projectm_handle projectM;
@property(nonatomic, assign) CGSize drawableSize;
@property(nonatomic, assign) CFTimeInterval lastFeedTime;
@property(nonatomic, assign) double pendingSampleFrames;
@property(nonatomic, assign) size_t wavFrameOffset;
@property(nonatomic, assign) uint64_t renderedFrames;
@property(nonatomic, copy, readwrite, nullable) NSString *confirmedPresetName;
@property(nonatomic, copy, readwrite, nullable) NSString *requestedPresetName;

- (void)applySettings;
- (BOOL)settingsTransitionUsesSmoothCut;
- (void)recordPresetLoadAttemptForFilename:(NSString *)presetFilename;
- (BOOL)isPresetHiddenOrSlow:(NSString *)presetName;
- (void)loadLearnedSlowPresets;
- (void)persistLearnedSlowState;
- (std::vector<RoonVis::PresetShelfInput>)presetShelfInputsFavoritesOnly:(BOOL)favoritesOnly;
- (std::vector<size_t>)rotationCandidateIndexesForMode:(RoonVisPresetRotationMode)mode;
- (size_t)nextRotationIndexFrom:(size_t)index offset:(NSInteger)offset;
- (void)notifyEngineStateDidChange;
- (void)invalidatePreloadedPresetTracking;
- (void)schedulePresetPreloadIfReadyAtTime:(CFTimeInterval)now;
- (BOOL)canWarmPresetAtTime:(CFTimeInterval)now;
- (std::vector<RoonVis::PresetWarmCandidate>)presetWarmCandidatesWithDepth:(size_t)depth;
- (std::vector<RoonVis::PresetWarmCandidate>)presetWarmCandidatesWithDepth:(size_t)depth
                                                       includePreloadAttempt:(BOOL)includePreloadAttempt;
- (BOOL)warmPresetOnRenderThread:(const RoonVis::PresetWarmCandidate &)candidate;
- (void)notePreloadCompileProgressAtTime:(CFTimeInterval)now;
- (BOOL)warmPresetCacheEntryOnRenderThread:(const RoonVis::PresetWarmCandidate &)candidate complete:(BOOL *)complete;
- (BOOL)consumeWarmedFirstActivationForPresetName:(NSString *)presetName;
- (BOOL)advancePresetByOffset:(NSInteger)offset smooth:(BOOL)smooth;
- (void)feedLivePCM;
- (void)feedElapsedPCM;
- (BOOL)drainLivePCMInto:(std::vector<int16_t> &)samples;
- (void)applyPendingAudioDelay;
- (void)rebaseLivePCMBufferToDelay;

@end

NS_ASSUME_NONNULL_END
