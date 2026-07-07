#import "ANGLEGLView.h"

#import "PresetWarmCache.h"

#import <EGL/egl.h>
#import <QuartzCore/CADisplayLink.h>

@class ProjectMBridge;
@class SnapcastClient;

NS_ASSUME_NONNULL_BEGIN

// Effective render rate: the user's frame-rate cap bounded by the panel's
// refresh rate. Defined in ANGLEGLView.mm; shared with the Diagnostics
// category so the slow-preset thresholds scale with the capped rate.
FOUNDATION_EXPORT NSInteger RoonVisEffectiveFrameRate(UIView *view);

@interface ANGLEGLView ()
{
    BOOL _perfDiagnosticsEnabled;
    CFTimeInterval _perfWindowStartTime;
    CFTimeInterval _perfLastFrameStartTime;
    double _perfTotalFrameInterval;
    double _perfMinFrameInterval;
    double _perfMaxFrameInterval;
    double _perfTotalRenderDuration;
    double _perfMaxRenderDuration;
    double _perfTotalSwapDuration;
    double _perfMaxSwapDuration;
    NSUInteger _perfFrameIntervals;
    NSUInteger _perfSuccessfulRenderedFrames;
    NSUInteger _perfSkippedFrames;
    NSUInteger _perfSwapFailures;
    NSUInteger _perfMakeCurrentFailures;
    // A/V latency lock — runs unconditionally (independent of _perfDiagnosticsEnabled)
    // so the lock is active in Release with diagnostics off. Fed every successful
    // render; applied once per window in -updateLatencyLockWithRender:swap:atTime:.
    CFTimeInterval _latencyLockWindowStartTime;
    double _latencyLockTotalRenderDuration;
    double _latencyLockTotalSwapDuration;
    NSUInteger _latencyLockFrames;
    BOOL _latencyLockDidLogFirstWindow;
    double _diagnosticsFPS;
    double _diagnosticsFrameTimeMs;
    NSUInteger _consecutiveSwapFailures;
    CFTimeInterval _currentFrameInterval;
    NSUInteger _slowPresetFrameCount;
    NSString *_slowPresetName;
    BOOL _disableSlowPresetSkip;
    NSMutableOrderedSet *_wouldSkipSlowPresetNames;
    NSString *_lastDiagnosticPresetName;
    NSUInteger _presetChangeDiagnosticFramesRemaining;
    BOOL _angleProgramCacheControlAvailable;
    BOOL _presetWarmupComplete;
    CFTimeInterval _presetWarmupStartTime;
    BOOL _presetWarmCacheEnabled;
    RoonVis::PresetWarmStrategy _presetWarmStrategy;
    uint64_t _presetWarmGeneration;
    CFTimeInterval _presetWarmLastFrameStartTime;
    CFTimeInterval _presetWarmCurrentFrameInterval;
    RoonVis::PresetWarmCache _presetWarmCache;
    RoonVis::PresetIdleWarmBudget _presetIdleWarmBudget;
    NSString *_appliedSnapcastHost; //!< Host the running SnapcastClient was created with (MRC: copied).
    uint16_t _appliedSnapcastPort;  //!< Port from Info.plist (not user-settable).
    // Select/PlayPause went down and has not yet been consumed by the long-press
    // recognizer: the hold-toggle fires on press RELEASE (pressesEnded) so a long
    // press can open the preset-options overlay instead.
    BOOL _selectPressPending;
}


@property(nonatomic, assign, nullable) EGLDisplay eglDisplay;
@property(nonatomic, assign, nullable) EGLSurface eglSurface;
@property(nonatomic, assign, nullable) EGLContext eglContext;
@property(nonatomic, assign, nullable) EGLConfig eglConfig;
@property(nonatomic, assign) CGSize surfaceDrawableSize;
@property(nonatomic, retain) CADisplayLink *displayLink;
@property(nonatomic, retain) ProjectMBridge *projectMBridge;
@property(nonatomic, retain) SnapcastClient *snapcastClient;
@property(nonatomic, retain, nullable) UIViewController *browseController;
@property(nonatomic, retain, nullable) UIViewController *quickSettingsController;
@property(nonatomic, retain, nullable) UIViewController *presetOptionsController;
@property(nonatomic, retain, nullable) UIViewController *syncCalibrationController;

- (BOOL)setupEGL;
- (BOOL)recreateSurfaceIfNeededForDrawableSize:(CGSize)drawableSize;
- (void)applyDisplayTimingToDisplayLink;
- (void)screenModeDidChange:(NSNotification *)notification;
- (void)installOverlayViews;
- (void)runPresetWarmupStep;
- (void)applyPresetWarmCacheSettings;
- (void)resetPresetWarmCacheState;
- (void)noteActivePresetForWarmCache;
- (void)runPresetWarmCacheAfterFrameWithInterval:(CFTimeInterval)frameInterval
                                  renderDuration:(CFTimeInterval)renderDuration
                                    swapDuration:(CFTimeInterval)swapDuration
                                          atTime:(CFTimeInterval)now;
- (void)settingsDidChange:(NSNotification *)notification;
- (void)resetPerformanceDiagnostics;
- (void)recordFrameStartForDiagnostics:(CFTimeInterval)frameStart;
- (void)recordPresetChangeFrameWithInterval:(CFTimeInterval)frameInterval
                             renderDuration:(CFTimeInterval)renderDuration
                               swapDuration:(CFTimeInterval)swapDuration;
- (void)updateLatencyLockWithRender:(double)renderDuration swap:(double)swapDuration atTime:(CFTimeInterval)now;
- (void)logPerformanceDiagnosticsIfNeededAtTime:(CFTimeInterval)now;
- (void)recordPresetRenderDuration:(CFTimeInterval)renderDuration;

@end

@interface ANGLEGLView (ControlsInternal)

- (void)postRemoteStatusWithEyebrow:(NSString *)eyebrow
                              title:(NSString *)title
                             symbol:(nullable NSString *)symbol
                             sticky:(BOOL)sticky;
- (void)postPresetWarmupActive:(BOOL)active text:(NSString *)text;
- (NSString *)currentPresetStatusTitle;
- (void)selectNextPresetFromRemote;
- (void)selectPreviousPresetFromRemote;
- (void)togglePresetHoldFromRemote;
- (void)resumePresetRotationFromRemote;
- (void)showCurrentPresetFromRemote;
- (void)presentBrowseFromRemote;
- (void)swipeDownRecognized:(UISwipeGestureRecognizer *)recognizer;
- (void)swipeUpRecognized:(UISwipeGestureRecognizer *)recognizer;
- (void)longPressRecognized:(UILongPressGestureRecognizer *)recognizer;
- (void)presentQuickSettingsFromRemote;
- (void)dismissQuickSettings;
- (void)presentPresetOptionsFromRemote;
- (void)dismissPresetOptions;
- (void)dismissBrowse;
- (void)showVisualizerHintIfNeeded;

// Latency-lock running averages + window reset (defined in the Diagnostics
// category; used by the sync-calibration dismiss path in Controls).
- (void)readLatencyLockRunningAveragesRenderMs:(double *)renderMs swapMs:(double *)swapMs;
- (void)resetLatencyLockWindow;

@end

NS_ASSUME_NONNULL_END
