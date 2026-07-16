#import "ProjectMBridge.h"
#import "LearnedSlowPresetStore.h"
#import "ProjectMPresetSupport.h"
#import "PresetRotationScheduler.h"
#import "PresetShelfModel.h"
#import "RotationEngine.h"
#import "PresetWarmCache.h"
#import "PresetDwellPlan.h"
#include "AudioOnsetDetector.h"
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

// The real delay ceiling the latency lock can budget: the user's audio-input delay (UI
// range 0..500) plus the internal sync-render compensation (clamped 0..200 in
// ProjectMBridge.mm and ProjectMBridge+Audio.mm). A bare MIN(500, ...) silently truncated
// values in 501..700 while _effectiveAudioDelayMs reported the larger number.
static constexpr NSInteger kLivePCMDelayClampMs = 500 + 200;

static inline size_t LivePCMDelayFramesForMilliseconds(NSInteger delayMs)
{
    return RoonVis::LivePCMDelayFramesForMs(delayMs, kLivePCMDelayClampMs, kLivePCMSampleRate, kLivePCMMaxBufferFrames);
}

// Shared free helpers implemented in ProjectMBridge.mm and used by both the base
// implementation and the ProjectMBridge+Warm category (behavior-neutral extraction of
// the warm-cache/preload code out of the base file). Keeping the definitions in the base
// file preserves their existing behavior; the declarations here give the category access.
inline constexpr double kPerfSweepPresetDurationSeconds = 6.0;
inline constexpr double kPerfSweepSoftCutDurationSeconds = 0.5;

BOOL RoonVisPerfSweepPresetTimingEnabled(void);
BOOL RoonVisCrasherScanModeEnabled(void);
// Diagnostic-only ROONVIS_ROTATION_MODE launch override (loop|shuffle|favorites|
// category) for headless 4-mode matrix runs; identity in Release / when unset.
// Defined in ProjectMBridge.mm; shared with the +Presets category.
RoonVisPresetRotationMode RoonVisEffectiveRotationMode(RoonVisPresetRotationMode settingsMode);
unsigned int RoonVisDisplayRefreshRate(void);
void *_Nullable ProjectMANGLELoadProc(const char *_Nullable name, void *_Nullable userData);

NS_ASSUME_NONNULL_BEGIN

@interface ProjectMBridge ()
{
    RoonVis::WavData _wav;
    std::mutex _livePCMMutex;
    RoonVis::LivePCMDelayBuffer _livePCMBuffer;
    std::vector<int16_t> _livePCMRenderSamples;
    std::vector<int16_t> _pcmGainBuffer;
    std::vector<std::string> _presetPaths;
    // Debug-only deterministic-rotation test hook (ROONVIS_ROTATION_FIXED_LIST). Only
    // ever populated under ROONVIS_ENABLE_DIAGNOSTIC_MODES; always empty in Release.
    // Parsed ObjC-side; mirrored into the engine via SetFixedOrder at seed time.
    std::vector<size_t> _fixedRotationIndexes;
    // Router memory for the entering-Shuffle reseed rule (settingsDidChange). The
    // engine has no "previous mode" concept, so this stays bridge-side.
    RoonVisPresetRotationMode _lastRotationMode;
    // Session exclusion set: learned-slow confirmed (seeded at startup) ∪ runtime
    // slow marks. Still the accumulating source of truth; mirrored into the engine
    // (SetSlowNames) which serves all exclusion queries (isPresetHiddenOrSlow).
    std::set<std::string> _slowPresetNames;
    RoonVis::LearnedSlowPresetStore _learnedSlowStore;
    size_t _currentPresetIndex;
    size_t _confirmedPresetIndex;
    size_t _lastGoodPresetIndex;
    size_t _preloadedPresetIndex;
    std::string _preloadedPresetPath;
    // Event-computed dwell plans (A5). Computed ONCE per confirm/recompute event so the
    // per-frame preload paths reduce to a single time comparison (DwellPlanReady) instead
    // of re-walking the rotation and re-checking windows every frame. Two plans because the
    // two live paths use different settle/lead constants (see -recomputeDwellPlansAtTime:):
    //   _dwellPlanDirect — the before-render direct-preload path (schedulePresetPreloadIfReadyAtTime:),
    //                      conservative 12 s settle / 5 s lead.
    //   _dwellPlanWarm   — the after-frame idle-budget warm-cache driver (ANGLEGLView),
    //                      2 s settle / 2 s lead. Both target the same next preset.
    RoonVis::PresetDwellPlan _dwellPlanDirect;
    RoonVis::PresetDwellPlan _dwellPlanWarm;
    NSString *_warmedFirstFramePresetName;
    // Phase 3c diagnostics: proves the preload's shader compile actually ran in the
    // background (ready poll must read false at least once, then flip true).
    CFTimeInterval _preloadCompileStartTime;
    int _preloadCompilePollCount;
    BOOL _preloadCompileReadyLogged;
    NSInteger _presetStepDirection;
    RoonVis::PresetRotationScheduler _rotationScheduler;
    // Owns rotation-order storage + selection for ALL modes (order caches live
    // inside it). Fed by the settingsDidChange event router, pushRotationEngineSlow,
    // and the SetAnchor sync; drained after every dirtying batch and persisted via
    // the existing plist writer. GL/main thread only, like all rotation state.
    RoonVis::RotationEngine _rotationEngine;
    // Parallel to _presetPaths: top-category and sub-category from the pack tree.
    std::vector<std::string> _presetCategories;
    std::vector<std::string> _presetSubcategories;
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
    // Sync-calibration state (GL/main thread only). The dual stash restores
    // BOTH the target and the lock-trimmed effective value on cancel.
    BOOL _syncCalibrationActive;
    BOOL _syncCalibrationOnsetThisFrame;
    NSInteger _syncCalStashedTargetMs;
    NSInteger _syncCalStashedEffectiveMs;
    // Internal render compensation: the latency lock budgets against
    // (audioInputDelayMs + this), so the user-visible setting stays the number
    // they ALIGNED during calibration while the lock still holds total latency
    // constant. Persisted (RoonVisSyncRenderCompensationMs); GL thread only.
    NSInteger _syncRenderCompensationMs;
    BOOL _syncCalStashedRotationHeld;
    RoonVis::AudioOnsetDetector _onsetDetector;
    // Preprocessed-HLSL cache + the C hooks bridged to it. Both outlive the projectM
    // instance (owned here on the bridge). All access is on the GL/render thread, where
    // transpile runs, so no locking is needed. Registered via projectm_set_preprocess_cache.
    RoonVis::PreprocessCache _preprocessCache;
    projectm_preprocess_cache_hooks _preprocessCacheHooks;
    // The window size last pushed to projectm_set_window_size (0,0 = never).
    // Backs -resizeToDrawableSize:'s same-size guard; deliberately separate from
    // the `drawableSize` property, which init sets BEFORE the first resize call.
    size_t _appliedProjectMWindowWidth;
    size_t _appliedProjectMWindowHeight;
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
- (std::vector<RoonVis::PresetShelfInput>)presetShelfInputsFavoritesOnly:(BOOL)favoritesOnly includeHidden:(BOOL)includeHidden;
// --- RotationEngine adoption plumbing -------------------------------------
// Populate the engine's catalog + favorites/hidden/slow/mode/fixed-order/store
// from current bridge state. Called once after preset enumeration.
- (void)seedRotationEngine;
// Push the current favorites / hidden / slow(+confirmed) / mode sets into the
// engine (event-router legs). Slow uses the exclusion set (_slowPresetNames) for
// SetSlowNames and the learned-slow CONFIRMED set for SetLearnedSlowConfirmed.
- (void)pushRotationEngineFavorites;
- (void)pushRotationEngineHidden;
- (void)pushRotationEngineSlow;
- (void)pushRotationEngineMode;
// Sync the engine's rotation anchor from the current confirmed/requested indexes
// (R2: batch before any drain). Called at every confirm/revert/request site and
// defensively before each engine order query.
- (void)updateRotationEngineAnchor;
// Drain every dirty scope the engine produced and persist it byte-identically
// through the existing plist writer. Call after each event batch that can dirty.
- (void)drainRotationEngineDirtyScopes;
// The next rotation index: delegates to RotationEngine::NextFrom (fixed-list
// override, FULL mode order with hidden/slow retained, exclusion predicate at
// advance time). SIZE_MAX when nothing is eligible (HOLD).
- (size_t)nextRotationIndexFrom:(size_t)index offset:(NSInteger)offset;
// The single rotation anchor shared by rotation advance AND warm-preload
// candidate selection: the confirmed preset normally, the requested one while
// a load is in flight. SIZE_MAX when nothing has been requested yet.
- (size_t)rotationAnchorIndex;
- (void)notifyEngineStateDidChange;
- (void)invalidatePreloadedPresetTracking;
// A5: record a confirmed switch (sets _lastPresetSwitchTime) and recompute both dwell
// plans from it. Every confirm site funnels through this.
- (void)noteSwitchConfirmedAtTime:(CFTimeInterval)now;
// A5: recompute both dwell plans (and invalidate preload tracking) on a recompute event —
// list/mode/slow/pack/order-timing changes — without moving _lastPresetSwitchTime.
- (void)recomputeDwellPlansAtTime:(CFTimeInterval)now;
- (void)schedulePresetPreloadIfReadyAtTime:(CFTimeInterval)now;
// A5: the ANGLEGLView warm-cache driver consumes the SAME plan. Returns YES and fills
// `out` with the warm target only when _dwellPlanWarm is Armed and ready at `now`.
- (BOOL)dwellPlanWarmCandidateReadyAtTime:(CFTimeInterval)now
                                candidate:(RoonVis::PresetWarmCandidate *)out;
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
