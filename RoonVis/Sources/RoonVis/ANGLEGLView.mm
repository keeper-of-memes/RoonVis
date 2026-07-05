#import "ANGLEGLViewInternal.h"

#import "ProjectMBridgeInternal.h"
#import "PresetWarmSettings.h"
#import "RoonVisCrashReporter.h"
#import "RoonVisEGLContext.h"
#import "RoonVisPerfCounters.h"
#import "RoonVisSettings.h"
#import "SnapcastClient.h"

#import <QuartzCore/CAMetalLayer.h>
#import <EGL/egl.h>
#import <EGL/eglext.h>
#import <GLES3/gl3.h>
#import <GLES2/gl2ext.h> // PFNGLMAXSHADERCOMPILERTHREADSKHRPROC (GL_KHR_parallel_shader_compile)

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <float.h>

#ifndef GL_PROGRAM_CACHE_ENABLED_ANGLE
#define GL_PROGRAM_CACHE_ENABLED_ANGLE 0x93AC
#endif

NSNotificationName const RoonVisRemoteStatusNotification = @"RoonVisRemoteStatusNotification";
NSString *const RoonVisRemoteStatusEyebrowKey = @"eyebrow";
NSString *const RoonVisRemoteStatusTitleKey = @"title";
NSString *const RoonVisRemoteStatusSymbolKey = @"symbol";
NSString *const RoonVisRemoteStatusStickyKey = @"sticky";

NSNotificationName const RoonVisPresetWarmupNotification = @"RoonVisPresetWarmupNotification";
NSString *const RoonVisPresetWarmupActiveKey = @"active";
NSString *const RoonVisPresetWarmupTextKey = @"text";

namespace
{
// Consecutive eglSwapBuffers failures before attempting EGL surface recreation, and the
// retry cadence thereafter (~0.5 s at 60 fps). Sustained swap failures usually mean the
// window surface went invalid; recreating it recovers without a full teardown.
static constexpr NSUInteger kSwapFailureRecoveryThreshold = 30;
static constexpr EGLint kAngleProgramCacheSizeBytes = 32 * 1024 * 1024;
static bool EGLDisplayExtensionAvailable(EGLDisplay display, const char *extensionName)
{
    const char *extensions = eglQueryString(display, EGL_EXTENSIONS);
    if (extensions == nullptr || extensionName == nullptr || extensionName[0] == '\0')
    {
        return false;
    }

    const size_t extensionNameLength = strlen(extensionName);
    const char *cursor = extensions;
    while ((cursor = strstr(cursor, extensionName)) != nullptr)
    {
        const bool startsAtBoundary = (cursor == extensions || cursor[-1] == ' ');
        const char after = cursor[extensionNameLength];
        const bool endsAtBoundary = (after == '\0' || after == ' ');
        if (startsAtBoundary && endsAtBoundary)
        {
            return true;
        }
        cursor += extensionNameLength;
    }

    return false;
}

static UIScreen *RoonVisScreenForView(UIView *view)
{
    if (view.window.screen != nil)
    {
        return view.window.screen;
    }
    return UIScreen.mainScreen;
}

// Resolution policy: render at 1080p, not native 4K. This is an intentional, measured
// choice (commits f27a08e / e218590 reverting the earlier 4K work): CoreAnimation
// upscales 1920x1080 to the 4K panel, and per-frame GL cost drops from ~7.7 ms at 4K
// to ~2 ms at 1080p. Preset-transition hitches are init-bound (preset load/compile),
// not resolution-bound, so 1080p buys frame-budget headroom without moving the
// transition bottleneck. UIScreen.scale is 1.0 on ATV4K, so the size is set explicitly
// rather than derived from scale. Revisit only if a transition fix makes 4K's per-frame
// cost affordable.
// Resolution-trial hook (dev/QA only): ROONVIS_DRAWABLE_SIZE overrides the render
// resolution (e.g. "3840x2160") to measure a different resolution without committing to
// a policy change. Mirrors the ROONVIS_MESH_SIZE hook in ProjectMBridge.mm: env-only,
// compile-gated to non-Release (ROONVIS_ENABLE_DIAGNOSTIC_MODES) so the shipping build
// pays no env read (this constant-folds to CGSizeZero).
//
// IMPORTANT: the override size is snapped to the 16:9 size implied by its width, and
// -initWithFrame: also sets contentsScale to width/1920. Hand-setting drawableSize alone
// is NOT enough — ANGLE recomputes the surface size from bounds x contentsScale at
// eglCreateWindowSurface (that was the historical quarter-screen bug, commit 6d06761),
// so the scale must carry the override for the surface to actually change size.
static CGSize RoonVisDrawableSizeOverride(void)
{
#if ROONVIS_ENABLE_DIAGNOSTIC_MODES
    NSString *sizeOverride = NSProcessInfo.processInfo.environment[@"ROONVIS_DRAWABLE_SIZE"];
    if (sizeOverride.length > 0)
    {
        NSArray<NSString *> *parts = [sizeOverride componentsSeparatedByString:@"x"];
        if (parts.count == 2 && parts[0].integerValue > 0 && parts[1].integerValue > 0)
        {
            const CGFloat width = static_cast<CGFloat>(parts[0].integerValue);
            return CGSizeMake(width, floor(width * (1080.0 / 1920.0)));
        }
    }
#endif
    return CGSizeZero;
}

static CGSize RoonVisTargetDrawableSize(UIView *view)
{
    (void)view;
    // 1080p (1920x1080) native render. 1440p was trialled 2026-07-05 with the 128x96 mesh
    // and ran visibly poorly on device (regression), so the render stays at 1080p; the mesh
    // bump is independent and kept. 4K remains deferred (transition-frame collapse). ATV4K
    // UIScreen.scale is 1.0, so the size is set explicitly (carried by contentsScale in
    // -initWithFrame:; width 1920 -> scale 1.0).
    CGSize target = CGSizeMake(1920.0, 1080.0);
    CGSize overrideSize = RoonVisDrawableSizeOverride();
    if (overrideSize.width > 0.0 && overrideSize.height > 0.0)
    {
        RoonVisLog(@"ANGLE drawable override: %.0fx%.0f (ROONVIS_DRAWABLE_SIZE)",
                   overrideSize.width,
                   overrideSize.height);
        return overrideSize;
    }
    RoonVisLog(@"ANGLE target drawable: %.0fx%.0f (1080p fullscreen presentation)",
               target.width,
               target.height);
    return target;
}

static NSInteger RoonVisDisplayRefreshRate(UIView *view)
{
    NSInteger refreshRate = RoonVisScreenForView(view).maximumFramesPerSecond;
    return refreshRate > 0 ? refreshRate : 60;
}

static BOOL RoonVisPerfDiagnosticsEnabled()
{
#if defined(NDEBUG)
    NSString *envValue = NSProcessInfo.processInfo.environment[@"ROONVIS_PERF_DIAGNOSTICS"];
    if (envValue.length > 0)
    {
        return envValue.boolValue;
    }
    return [[NSUserDefaults standardUserDefaults] boolForKey:@"RoonVisPerfDiagnosticsEnabled"] ||
           [RoonVisSettings sharedSettings].diagnosticsOverlayEnabled;
#else
    return YES;
#endif
}

static BOOL RoonVisDisableSlowPresetSkip()
{
    NSString *envValue = NSProcessInfo.processInfo.environment[@"ROONVIS_DISABLE_SLOW_PRESET_SKIP"];
    if (envValue.length > 0)
    {
        return envValue.boolValue;
    }
    return [[NSUserDefaults standardUserDefaults] boolForKey:@"RoonVisDisableSlowPresetSkip"];
}

}

@implementation ANGLEGLView
+ (Class)layerClass
{
    return [CAMetalLayer class];
}

- (ProjectMBridge *)bridge
{
    return _projectMBridge;
}

- (instancetype)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (self)
    {
        self.backgroundColor = UIColor.blackColor;
        self.isAccessibilityElement = YES;
        self.accessibilityLabel = @"RoonVis visualizer";
        self.accessibilityHint = @"Press Menu to browse presets. Swipe down for quick settings.";
        self.contentScaleFactor = 1.0;
        CAMetalLayer *metalLayer = (CAMetalLayer *)self.layer;
        metalLayer.opaque = YES;
        metalLayer.contentsScale = 1.0;
        metalLayer.contentsGravity = kCAGravityResize;
        metalLayer.magnificationFilter = kCAFilterLinear;
        metalLayer.minificationFilter = kCAFilterLinear;
        CGSize targetDrawableSize = RoonVisTargetDrawableSize(self);
        if (targetDrawableSize.width > 0.0 && targetDrawableSize.height > 0.0)
        {
            // ANGLE derives the EGL surface size from bounds x contentsScale, so the render
            // target (default 1440p, or the ROONVIS_DRAWABLE_SIZE override) must be carried by
            // the scale, not just the drawableSize assignment. width=1920 -> 1.0 (1080p),
            // 2560 -> 1.333 (1440p), 3840 -> 2.0 (4K). Without this ANGLE resets to a
            // quarter-screen surface (historical bug 6d06761).
            const CGFloat scale = targetDrawableSize.width / 1920.0;
            self.contentScaleFactor = scale;
            metalLayer.contentsScale = scale;
            metalLayer.drawableSize = targetDrawableSize;
        }
        RoonVisLog(@"ANGLE display mode chosen: drawable %.0fx%.0f fps=%ld",
                   metalLayer.drawableSize.width,
                   metalLayer.drawableSize.height,
                   static_cast<long>(RoonVisDisplayRefreshRate(self)));
        self.eglDisplay = EGL_NO_DISPLAY;
        self.eglSurface = EGL_NO_SURFACE;
        self.eglContext = EGL_NO_CONTEXT;
        self.eglConfig = nullptr;
        self.surfaceDrawableSize = CGSizeZero;
        _perfDiagnosticsEnabled = RoonVisPerfDiagnosticsEnabled();
        RoonVisPerfCountersSetEnabled(_perfDiagnosticsEnabled);
        _disableSlowPresetSkip = RoonVisDisableSlowPresetSkip();
        _presetWarmStrategy = RoonVis::PresetWarmStrategy::IdleFrame;
        [self applyPresetWarmCacheSettings];
        _wouldSkipSlowPresetNames = [[NSMutableOrderedSet alloc] init];
        if (_disableSlowPresetSkip)
        {
            [self logTransitionDiagnosticLine:@"PerfDiagTransition: slow preset auto-skip disabled for measurement; would-skip events will be logged"];
        }
        [self resetPerformanceDiagnostics];
        if (![self setupEGL])
        {
            RoonVisLog(@"ANGLE Step A EGL setup failed; rendering disabled");
            self.backgroundColor = [UIColor colorWithRed:0.25f green:0.0f blue:0.0f alpha:1.0f];
            return self;
        }

        self.projectMBridge = [[[ProjectMBridge alloc] initWithDrawableSize:metalLayer.drawableSize] autorelease];
        if (!self.projectMBridge.isReady)
        {
            RoonVisLog(@"ProjectM Step B bridge not ready; rendering disabled");
            self.backgroundColor = [UIColor colorWithRed:0.35f green:0.16f blue:0.0f alpha:1.0f];
            return self;
        }
        [self applyPresetWarmCacheSettings];

        NSDictionary *info = NSBundle.mainBundle.infoDictionary;
        NSString *snapcastHost = info[@"SnapcastServerHost"];
        if (snapcastHost.length == 0)
        {
            snapcastHost = @"192.0.2.10";
        }
        NSNumber *snapcastPortNumber = info[@"SnapcastServerPort"];
        uint16_t snapcastPort = snapcastPortNumber != nil ? static_cast<uint16_t>(snapcastPortNumber.unsignedShortValue) : 1704;
        self.snapcastClient = [[[SnapcastClient alloc] initWithHost:snapcastHost port:snapcastPort bridge:self.projectMBridge] autorelease];
        [self.snapcastClient start];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(screenModeDidChange:)
                                                     name:UIScreenModeDidChangeNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(settingsDidChange:)
                                                     name:RoonVisSettingsDidChangeNotification
                                                   object:[RoonVisSettings sharedSettings]];
        [self installOverlayViews];
        self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(drawFrame)];
        [self applyDisplayTimingToDisplayLink];
        [self.displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
        RoonVisLog(@"Render loop start");
    }
    return self;
}

- (BOOL)canBecomeFocused
{
    return YES;
}

- (NSArray<id<UIFocusEnvironment>> *)preferredFocusEnvironments
{
    // When the quick-settings overlay is up, focus must move into it so its own
    // controls are reachable and its Menu->dismiss handler receives the press.
    // Without this, focus stayed on the visualizer and Menu opened Browse instead
    // of dismissing quick settings (the overlay couldn't be dismissed).
    if (self.quickSettingsController != nil)
    {
        return @[ self.quickSettingsController.view ];
    }
    return [super preferredFocusEnvironments];
}

- (void)didMoveToWindow
{
    [super didMoveToWindow];
    if (self.window != nil)
    {
        [self setNeedsFocusUpdate];
        [self updateFocusIfNeeded];
    }
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    CAMetalLayer *metalLayer = (CAMetalLayer *)self.layer;
    metalLayer.drawableSize = RoonVisTargetDrawableSize(self);
    if (![self recreateSurfaceIfNeededForDrawableSize:metalLayer.drawableSize])
    {
        return;
    }
    [self.projectMBridge resizeToDrawableSize:metalLayer.drawableSize];
    [self drawFrame];
}

- (void)applyDisplayTimingToDisplayLink
{
    NSInteger refreshRate = RoonVisDisplayRefreshRate(self);
    self.displayLink.preferredFramesPerSecond = refreshRate;
}

- (void)screenModeDidChange:(NSNotification *)notification
{
    [self applyDisplayTimingToDisplayLink];
    CAMetalLayer *metalLayer = (CAMetalLayer *)self.layer;
    metalLayer.drawableSize = RoonVisTargetDrawableSize(self);
    RoonVisLog(@"ANGLE display mode changed: drawable %.0fx%.0f fps=%ld",
               metalLayer.drawableSize.width,
               metalLayer.drawableSize.height,
               static_cast<long>(RoonVisDisplayRefreshRate(self)));
    if ([self recreateSurfaceIfNeededForDrawableSize:metalLayer.drawableSize])
    {
        [self.projectMBridge resizeToDrawableSize:metalLayer.drawableSize];
        [self drawFrame];
    }
}

- (void)pause
{
    RoonVisLog(@"Render loop pause");
    self.displayLink.paused = YES;
    [self resetPerformanceDiagnostics];
    [self resetPresetWarmCacheState];
}

- (void)resume
{
    RoonVisLog(@"Render loop resume");
    [self resetPerformanceDiagnostics];
    [self resetPresetWarmCacheState];
    [self.projectMBridge clearLivePCMBuffer];
    self.displayLink.paused = (self.browseController != nil);
}

- (void)reconnectSnapcastNow
{
    [self.snapcastClient reconnectNow];
}

- (void)installOverlayViews
{
    UISwipeGestureRecognizer *swipeDown = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(swipeDownRecognized:)];
    swipeDown.direction = UISwipeGestureRecognizerDirectionDown;
    [self addGestureRecognizer:swipeDown];
    [swipeDown release];

    UISwipeGestureRecognizer *swipeUp = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(swipeUpRecognized:)];
    swipeUp.direction = UISwipeGestureRecognizerDirectionUp;
    [self addGestureRecognizer:swipeUp];
    [swipeUp release];

    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(longPressRecognized:)];
    longPress.allowedPressTypes = @[@(UIPressTypeSelect)];
    [self addGestureRecognizer:longPress];
    [longPress release];
}

- (void)applyPresetWarmCacheSettings
{
    BOOL enabled = RoonVisPresetWarmCacheEnabledSetting();
    RoonVis::PresetWarmStrategy strategy = RoonVisPresetWarmStrategySetting();

    BOOL changed = (_presetWarmCacheEnabled != enabled ||
                    _presetWarmStrategy != strategy);
    _presetWarmCacheEnabled = enabled;
    _presetWarmStrategy = strategy;

    if (changed)
    {
        [self resetPresetWarmCacheState];
        if (_presetWarmCacheEnabled)
        {
            RoonVisLog(@"Preset warm cache enabled: strategy=idle-frame-main-context");
        }
        else
        {
            RoonVisLog(@"Preset warm cache disabled");
        }
    }
}

- (void)resetPresetWarmCacheState
{
    _presetWarmGeneration++;
    _presetWarmCache.Reset();
    _presetIdleWarmBudget.Reset();
    _presetWarmLastFrameStartTime = 0;
    _presetWarmCurrentFrameInterval = 0;
}

- (void)noteActivePresetForWarmCache
{
    NSInteger currentPresetIndex = [self.projectMBridge currentPresetIndex];
    if (currentPresetIndex < 0)
    {
        return;
    }

    NSString *path = [self.projectMBridge presetPathAtIndex:static_cast<NSUInteger>(currentPresetIndex)];
    const char *fileSystemPath = path.fileSystemRepresentation;
    if (fileSystemPath == nullptr)
    {
        return;
    }
    _presetWarmCache.NoteActivePreset(static_cast<size_t>(currentPresetIndex), fileSystemPath);
}

- (void)runPresetWarmCacheAfterFrameWithInterval:(CFTimeInterval)frameInterval
                                  renderDuration:(CFTimeInterval)renderDuration
                                    swapDuration:(CFTimeInterval)swapDuration
                                          atTime:(CFTimeInterval)now
{
    if (!_presetWarmCacheEnabled || self.projectMBridge == nil || !self.projectMBridge.isReady)
    {
        return;
    }

    // Phase 3c diagnostics: track the background compile of an in-flight preload.
    [self.projectMBridge notePreloadCompileProgressAtTime:now];

    [self noteActivePresetForWarmCache];

    CFTimeInterval targetFrameInterval = self.displayLink.duration > 0 ? self.displayLink.duration : frameInterval;
    BOOL canWarmNow = [self.projectMBridge canWarmPresetAtTime:now];
    if (!canWarmNow)
    {
        _presetIdleWarmBudget.RecordFrame(frameInterval,
                                          targetFrameInterval,
                                          renderDuration,
                                          swapDuration,
                                          true);
        return;
    }

    BOOL budgetReady = _presetIdleWarmBudget.RecordFrame(frameInterval,
                                                         targetFrameInterval,
                                                         renderDuration,
                                                         swapDuration,
                                                         false);
    if (!budgetReady)
    {
        return;
    }

    RoonVis::PresetWarmCandidate candidate = _presetWarmCache.InFlightCandidate();
    if (!RoonVis::PresetWarmCandidateIsValid(candidate))
    {
        std::vector<RoonVis::PresetWarmCandidate> candidates =
            [self.projectMBridge presetWarmCandidatesWithDepth:1 includePreloadAttempt:YES];
        candidate = _presetWarmCache.ChooseNextCandidate(candidates);
        if (!RoonVis::PresetWarmCandidateIsValid(candidate))
        {
            return;
        }
        _presetWarmCache.MarkWarmStarted(candidate.index, candidate.path);
    }

    _presetIdleWarmBudget.ConsumeWarmAttempt();
    BOOL complete = NO;
    BOOL success = [self.projectMBridge warmPresetCacheEntryOnRenderThread:candidate complete:&complete];
    if (!complete)
    {
        return;
    }

    _presetWarmCache.MarkWarmFinished(candidate.index, candidate.path, success ? true : false);
}

- (void)settingsDidChange:(NSNotification *)notification
{
    _perfDiagnosticsEnabled = RoonVisPerfDiagnosticsEnabled();
    RoonVisPerfCountersSetEnabled(_perfDiagnosticsEnabled);
    _disableSlowPresetSkip = RoonVisDisableSlowPresetSkip();
    [self applyPresetWarmCacheSettings];
    if ([RoonVisSettings sharedSettings].diagnosticsOverlayEnabled)
    {
        [self resetPerformanceDiagnostics];
    }
}

- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event
{
    // While the quick-settings or preset-options overlay is up it owns remote input
    // (its focused controls + Menu->dismiss). Don't drive preset nav or open Browse
    // underneath it.
    if (self.quickSettingsController != nil || self.presetOptionsController != nil)
    {
        [super pressesBegan:presses withEvent:event];
        return;
    }

    BOOL handledPress = NO;
    for (UIPress *press in presses)
    {
        switch (press.type)
        {
            case UIPressTypeRightArrow:
                [self selectNextPresetFromRemote];
                handledPress = YES;
                break;
            case UIPressTypeLeftArrow:
                [self selectPreviousPresetFromRemote];
                handledPress = YES;
                break;
            case UIPressTypeSelect:
            case UIPressTypePlayPause:
                // Defer the hold-toggle to pressesEnded so a LONG press can open the
                // preset-options overlay instead (the recognizer clears the flag).
                _selectPressPending = YES;
                handledPress = YES;
                break;
            case UIPressTypeDownArrow:
                [self resumePresetRotationFromRemote];
                handledPress = YES;
                break;
            case UIPressTypeUpArrow:
                [self showCurrentPresetFromRemote];
                handledPress = YES;
                break;
            case UIPressTypeMenu:
                [self presentBrowseFromRemote];
                handledPress = YES;
                break;
            default:
                break;
        }
    }

    if (!handledPress)
    {
        [super pressesBegan:presses withEvent:event];
    }
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event
{
    BOOL handledPress = NO;
    for (UIPress *press in presses)
    {
        if ((press.type == UIPressTypeSelect || press.type == UIPressTypePlayPause) && _selectPressPending)
        {
            _selectPressPending = NO;
            [self togglePresetHoldFromRemote];
            handledPress = YES;
        }
    }

    if (!handledPress)
    {
        [super pressesEnded:presses withEvent:event];
    }
}

- (void)pressesCancelled:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event
{
    _selectPressPending = NO;
    [super pressesCancelled:presses withEvent:event];
}

- (void)didUpdateFocusInContext:(UIFocusUpdateContext *)context withAnimationCoordinator:(UIFocusAnimationCoordinator *)coordinator
{
    [super didUpdateFocusInContext:context withAnimationCoordinator:coordinator];
    UIView *nextView = context.nextFocusedView;
    NSString *label = nextView.accessibilityLabel;
    RoonVisLog(@"Focus changed: surface=ANGLEGLView next=%@ label=%@",
               nextView != nil ? NSStringFromClass(nextView.class) : @"(nil)",
               label.length > 0 ? label : @"(none)");
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_snapcastClient stop];
    [_displayLink invalidate];
    if (_eglDisplay != EGL_NO_DISPLAY)
    {
        if (_eglSurface != EGL_NO_SURFACE && _eglContext != EGL_NO_CONTEXT)
        {
            eglMakeCurrent(_eglDisplay, _eglSurface, _eglSurface, _eglContext);
        }
        [_projectMBridge release];
        _projectMBridge = nil;
        eglMakeCurrent(_eglDisplay, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        if (_eglSurface != EGL_NO_SURFACE)
        {
            eglDestroySurface(_eglDisplay, _eglSurface);
        }
        if (_eglContext != EGL_NO_CONTEXT)
        {
            eglDestroyContext(_eglDisplay, _eglContext);
        }
        eglTerminate(_eglDisplay);
    }
    [_projectMBridge release];
    [_snapcastClient release];
    [_displayLink release];
    [_browseController release];
    [_quickSettingsController release];
    [_presetOptionsController release];
    [_slowPresetName release];
    [_wouldSkipSlowPresetNames release];
    [_lastDiagnosticPresetName release];
    [super dealloc];
}

- (BOOL)setupEGL
{
    RoonVisLog(@"ANGLE Step A EGL setup start");
    self.eglDisplay = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (self.eglDisplay == EGL_NO_DISPLAY)
    {
        RoonVisLog(@"ANGLE Step A eglGetDisplay failed: 0x%04x", eglGetError());
        return NO;
    }

    EGLint major = 0;
    EGLint minor = 0;
    EGLBoolean initialized = eglInitialize(self.eglDisplay, &major, &minor);
    if (!initialized)
    {
        RoonVisLog(@"ANGLE Step A eglInitialize failed: 0x%04x", eglGetError());
        return NO;
    }

    const bool programCacheControlAvailable = EGLDisplayExtensionAvailable(self.eglDisplay, "EGL_ANGLE_program_cache_control");
    _angleProgramCacheControlAvailable = programCacheControlAvailable ? YES : NO;
    EGLint programCacheEntriesBeforeResize = 0;
    EGLint programCacheKeyLength = 0;
    if (programCacheControlAvailable)
    {
        programCacheEntriesBeforeResize = eglProgramCacheGetAttribANGLE(self.eglDisplay, EGL_PROGRAM_CACHE_SIZE_ANGLE);
        programCacheKeyLength = eglProgramCacheGetAttribANGLE(self.eglDisplay, EGL_PROGRAM_CACHE_KEY_LENGTH_ANGLE);
        EGLint previousProgramCacheBytes = eglProgramCacheResizeANGLE(self.eglDisplay, kAngleProgramCacheSizeBytes, EGL_PROGRAM_CACHE_RESIZE_ANGLE);
        EGLint resizeError = eglGetError();
        if (resizeError == EGL_SUCCESS)
        {
            NSLog(@"ANGLE ProgramCache: extension=YES entries_before=%d key_length=%d resized_bytes=%d previous_bytes=%d",
                  programCacheEntriesBeforeResize,
                  programCacheKeyLength,
                  kAngleProgramCacheSizeBytes,
                  previousProgramCacheBytes);
        }
        else
        {
            NSLog(@"ANGLE ProgramCache: extension=YES resize failed: 0x%04x entries_before=%d key_length=%d",
                  resizeError,
                  programCacheEntriesBeforeResize,
                  programCacheKeyLength);
        }
    }
    else
    {
        NSLog(@"ANGLE ProgramCache: EGL_ANGLE_program_cache_control unavailable; program cache disabled");
    }

    EGLint configCount = 0;
    EGLBoolean choseConfig = RoonVisChooseEGLConfig(self.eglDisplay, EGL_WINDOW_BIT, &_eglConfig, &configCount);
    if (!choseConfig)
    {
        RoonVisLog(@"ANGLE Step A eglChooseConfig failed: 0x%04x count=%d", eglGetError(), configCount);
        return NO;
    }

    EGLContext context = EGL_NO_CONTEXT;
    if (!RoonVisCreateGLES3Context(self.eglDisplay,
                                   self.eglConfig,
                                   EGL_NO_CONTEXT,
                                   programCacheControlAvailable ? EGL_TRUE : EGL_FALSE,
                                   &context))
    {
        RoonVisLog(@"ANGLE Step A eglCreateContext failed: 0x%04x", eglGetError());
        return NO;
    }
    self.eglContext = context;

    self.eglSurface = eglCreateWindowSurface(self.eglDisplay, self.eglConfig, (__bridge EGLNativeWindowType)self.layer, nullptr);
    if (self.eglSurface == EGL_NO_SURFACE)
    {
        RoonVisLog(@"ANGLE Step A eglCreateWindowSurface failed: 0x%04x", eglGetError());
        return NO;
    }
    self.surfaceDrawableSize = ((CAMetalLayer *)self.layer).drawableSize;
    RoonVisLog(@"ANGLE Step A recreated EGL surface %.0fx%.0f", self.surfaceDrawableSize.width, self.surfaceDrawableSize.height);

    EGLBoolean madeCurrent = eglMakeCurrent(self.eglDisplay, self.eglSurface, self.eglSurface, self.eglContext);
    if (!madeCurrent)
    {
        RoonVisLog(@"ANGLE Step A eglMakeCurrent failed: 0x%04x", eglGetError());
        return NO;
    }

    if (programCacheControlAvailable)
    {
        GLboolean programCacheEnabled = GL_FALSE;
        glGetBooleanv(GL_PROGRAM_CACHE_ENABLED_ANGLE, &programCacheEnabled);
        NSLog(@"ANGLE ProgramCache: context_enabled=%@ entries_after_context=%d",
              programCacheEnabled == GL_TRUE ? @"YES" : @"NO",
              eglProgramCacheGetAttribANGLE(self.eglDisplay, EGL_PROGRAM_CACHE_SIZE_ANGLE));
    }

    // Phase 3c: opt in to ANGLE's background shader compile (GL_KHR_parallel_shader_compile).
    // Any value > 0 enables the shared worker pool; the count itself is otherwise ignored.
    // projectM's preload path defers the link-resolving calls so the compile actually stays
    // in flight (see vendor Shader.cpp / docs/phase3-async-compile-design.md).
    const char *glExtensions = (const char *)glGetString(GL_EXTENSIONS);
    PFNGLMAXSHADERCOMPILERTHREADSKHRPROC maxShaderCompilerThreadsKHR =
        (PFNGLMAXSHADERCOMPILERTHREADSKHRPROC)eglGetProcAddress("glMaxShaderCompilerThreadsKHR");
    if (glExtensions != nullptr && strstr(glExtensions, "GL_KHR_parallel_shader_compile") != nullptr &&
        maxShaderCompilerThreadsKHR != nullptr)
    {
        maxShaderCompilerThreadsKHR(4);
        RoonVisLog(@"ANGLE parallel shader compile enabled");
    }
    else
    {
        RoonVisLog(@"ANGLE parallel shader compile unavailable; preset preload compiles stay synchronous");
    }

    RoonVisLog(@"ANGLE Step A EGL %d.%d", major, minor);
    RoonVisLog(@"ANGLE Step A GL_VERSION: %s", glGetString(GL_VERSION));
    RoonVisLog(@"ANGLE Step A GL_RENDERER: %s", glGetString(GL_RENDERER));
    return YES;
}

- (BOOL)recreateSurfaceIfNeededForDrawableSize:(CGSize)drawableSize
{
    if (drawableSize.width <= 0 || drawableSize.height <= 0)
    {
        return NO;
    }

    if (CGSizeEqualToSize(drawableSize, self.surfaceDrawableSize))
    {
        return YES;
    }

    if (self.eglDisplay == EGL_NO_DISPLAY || self.eglContext == EGL_NO_CONTEXT || self.eglConfig == nullptr)
    {
        return NO;
    }

    if (self.eglSurface == EGL_NO_SURFACE)
    {
        self.eglSurface = eglCreateWindowSurface(self.eglDisplay, self.eglConfig, (__bridge EGLNativeWindowType)self.layer, nullptr);
        if (self.eglSurface == EGL_NO_SURFACE)
        {
            RoonVisLog(@"ANGLE Step A recreate eglCreateWindowSurface failed: 0x%04x", eglGetError());
            return NO;
        }
        self.surfaceDrawableSize = drawableSize;
    }
    else
    {
        EGLSurface oldSurface = self.eglSurface;
        EGLBoolean releasedCurrent = eglMakeCurrent(self.eglDisplay, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        if (!releasedCurrent)
        {
            RoonVisLog(@"ANGLE Step A recreate eglMakeCurrent(no surface) failed: 0x%04x", eglGetError());
            return NO;
        }

        EGLBoolean destroyed = eglDestroySurface(self.eglDisplay, oldSurface);
        if (!destroyed)
        {
            RoonVisLog(@"ANGLE Step A recreate eglDestroySurface failed: 0x%04x", eglGetError());
            self.eglSurface = EGL_NO_SURFACE;
            return NO;
        }

        self.eglSurface = eglCreateWindowSurface(self.eglDisplay, self.eglConfig, (__bridge EGLNativeWindowType)self.layer, nullptr);
        if (self.eglSurface == EGL_NO_SURFACE)
        {
            RoonVisLog(@"ANGLE Step A recreate eglCreateWindowSurface failed: 0x%04x", eglGetError());
            self.surfaceDrawableSize = CGSizeZero;
            return NO;
        }
        self.surfaceDrawableSize = drawableSize;
    }

    EGLBoolean madeCurrent = eglMakeCurrent(self.eglDisplay, self.eglSurface, self.eglSurface, self.eglContext);
    if (!madeCurrent)
    {
        RoonVisLog(@"ANGLE Step A recreate eglMakeCurrent failed: 0x%04x", eglGetError());
        return NO;
    }

    RoonVisLog(@"ANGLE Step A recreated EGL surface %.0fx%.0f", drawableSize.width, drawableSize.height);
    [self resetPerformanceDiagnostics];
    [self resetPresetWarmCacheState];
    return YES;
}

// Recovery path for sustained eglSwapBuffers failures (as opposed to a drawable-size
// change). Forces -recreateSurfaceIfNeededForDrawableSize: past its size-equality
// early-return by clearing the cached size, so the invalid surface is destroyed and
// rebuilt at the same size. On success the consecutive-failure counter is cleared.
- (void)recreateEGLSurfaceAfterSwapFailure
{
    CGSize drawableSize = ((CAMetalLayer *)self.layer).drawableSize;
    if (drawableSize.width <= 0 || drawableSize.height <= 0)
    {
        return;
    }
    NSLog(@"ANGLE Step A recovering from %lu consecutive swap failures: recreating EGL surface",
          static_cast<unsigned long>(_consecutiveSwapFailures));
    self.surfaceDrawableSize = CGSizeZero;
    if ([self recreateSurfaceIfNeededForDrawableSize:drawableSize])
    {
        _consecutiveSwapFailures = 0;
        NSLog(@"ANGLE Step A swap-failure recovery: EGL surface recreated");
    }
    else
    {
        NSLog(@"ANGLE Step A swap-failure recovery: surface recreation failed; will retry");
    }
}

- (void)runPresetWarmupStep
{
    if (_presetWarmupStartTime <= 0)
    {
        _presetWarmupStartTime = CACurrentMediaTime();
        [self postPresetWarmupActive:YES text:@"Preparing..."];
        // Do not compile-and-discard every preset here: prior ANGLE/Metal cache
        // behavior was not reliable enough to justify the startup pause.
        RoonVisLog(@"Preset warm-up skipped: all-preset preload is disabled; relying on ANGLE program cache and instant cuts");
    }

    [self.projectMBridge loadInitialPreset];
    [self.projectMBridge clearLivePCMBuffer];
    _presetWarmupComplete = YES;
    [self postPresetWarmupActive:NO text:@"Preparing..."];
    CFTimeInterval elapsed = CACurrentMediaTime() - _presetWarmupStartTime;
    RoonVisLog(@"Preset warm-up complete: initial preset loaded in %.1fs", elapsed);
    [self resetPerformanceDiagnostics];
    // Post the first-run hint only after warm-up: the SwiftUI chrome (the toast's
    // observer) is guaranteed mounted by now, and it no longer fights the warmup card.
    [self showVisualizerHintIfNeeded];
}

- (void)drawFrame
{
    CFTimeInterval frameStart = CACurrentMediaTime();
    if (_presetWarmCacheEnabled)
    {
        if (_presetWarmLastFrameStartTime > 0)
        {
            _presetWarmCurrentFrameInterval = frameStart - _presetWarmLastFrameStartTime;
        }
        _presetWarmLastFrameStartTime = frameStart;
    }
    if (_perfDiagnosticsEnabled)
    {
        [self recordFrameStartForDiagnostics:frameStart];
    }

    if (self.eglDisplay == EGL_NO_DISPLAY || self.eglSurface == EGL_NO_SURFACE || self.eglContext == EGL_NO_CONTEXT)
    {
        if (_perfDiagnosticsEnabled)
        {
            _perfSkippedFrames++;
            [self logPerformanceDiagnosticsIfNeededAtTime:CACurrentMediaTime()];
        }
        return;
    }

    EGLBoolean madeCurrent = eglMakeCurrent(self.eglDisplay, self.eglSurface, self.eglSurface, self.eglContext);
    if (!madeCurrent)
    {
        if (_perfDiagnosticsEnabled)
        {
            _perfMakeCurrentFailures++;
            _perfSkippedFrames++;
        }
        NSLog(@"ANGLE Step A per-frame eglMakeCurrent failed: 0x%04x", eglGetError());
        if (_perfDiagnosticsEnabled)
        {
            [self logPerformanceDiagnosticsIfNeededAtTime:CACurrentMediaTime()];
        }
        return;
    }

    CGSize drawableSize = ((CAMetalLayer *)self.layer).drawableSize;
    glViewport(0, 0, (GLsizei)drawableSize.width, (GLsizei)drawableSize.height);
    if (!_presetWarmupComplete)
    {
        [self runPresetWarmupStep];
        glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT);
        if (!eglSwapBuffers(self.eglDisplay, self.eglSurface))
        {
            NSLog(@"ANGLE Step A eglSwapBuffers failed during preset warm-up: 0x%04x", eglGetError());
        }
        return;
    }

    CFTimeInterval renderStart = CACurrentMediaTime();
    BOOL renderedProjectMFrame = [self.projectMBridge renderFrame];
    CFTimeInterval renderEnd = CACurrentMediaTime();
#if DEBUG
    GLenum error = GL_NO_ERROR;
    while ((error = glGetError()) != GL_NO_ERROR)
    {
        NSLog(@"ANGLE Step A GL error after renderFrame: 0x%04x", error);
    }
#endif

    CFTimeInterval swapStart = CACurrentMediaTime();
    EGLBoolean swapped = eglSwapBuffers(self.eglDisplay, self.eglSurface);
    CFTimeInterval swapEnd = CACurrentMediaTime();
    if (!swapped)
    {
        if (_perfDiagnosticsEnabled)
        {
            _perfSwapFailures++;
            _perfSkippedFrames++;
        }
        _consecutiveSwapFailures++;
        if (_consecutiveSwapFailures == 1 || (_consecutiveSwapFailures % 60) == 0)
        {
            NSLog(@"ANGLE Step A eglSwapBuffers failed: 0x%04x consecutive=%lu",
                  eglGetError(),
                  static_cast<unsigned long>(_consecutiveSwapFailures));
        }
        // Attempt surface recreation once the failures are sustained, then retry every
        // kSwapFailureRecoveryThreshold frames so a genuinely dead display doesn't thrash.
        if (_consecutiveSwapFailures >= kSwapFailureRecoveryThreshold &&
            (_consecutiveSwapFailures % kSwapFailureRecoveryThreshold) == 0)
        {
            [self recreateEGLSurfaceAfterSwapFailure];
        }
        if (_perfDiagnosticsEnabled)
        {
            [self logPerformanceDiagnosticsIfNeededAtTime:swapEnd];
        }
        return;
    }
    _consecutiveSwapFailures = 0;
    double renderDuration = static_cast<double>(renderEnd - renderStart);
    double swapDuration = static_cast<double>(swapEnd - swapStart);
    if (renderedProjectMFrame)
    {
        [self recordPresetRenderDuration:renderDuration];
        // Unconditional — keeps the A/V latency lock active in Release/diagnostics-off.
        [self updateLatencyLockWithRender:renderDuration swap:swapDuration atTime:swapEnd];
    }

    if (_perfDiagnosticsEnabled && renderedProjectMFrame)
    {
        _perfSuccessfulRenderedFrames++;
        _perfTotalRenderDuration += renderDuration;
        _perfMaxRenderDuration = std::max(_perfMaxRenderDuration, renderDuration);
        _perfTotalSwapDuration += swapDuration;
        _perfMaxSwapDuration = std::max(_perfMaxSwapDuration, swapDuration);
    }
    else if (_perfDiagnosticsEnabled)
    {
        _perfSkippedFrames++;
    }

    if (_presetWarmCacheEnabled)
    {
        CFTimeInterval frameInterval = _presetWarmCurrentFrameInterval > 0 ? _presetWarmCurrentFrameInterval : self.displayLink.duration;
        [self runPresetWarmCacheAfterFrameWithInterval:frameInterval
                                        renderDuration:renderDuration
                                          swapDuration:swapDuration
                                                atTime:swapEnd];
    }

    if (_perfDiagnosticsEnabled)
    {
        [self recordPresetChangeFrameWithInterval:_currentFrameInterval
                                   renderDuration:renderDuration
                                     swapDuration:swapEnd - swapStart];
        [self logPerformanceDiagnosticsIfNeededAtTime:swapEnd];
    }
}

@end
