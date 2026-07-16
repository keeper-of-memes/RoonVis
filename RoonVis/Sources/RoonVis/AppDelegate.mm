#import "AppDelegate.h"

#import "ANGLEGLView.h"
#import "LegacyNameMigrationSupport.h"
#import "PresetValidator.h"  // QA-only; body compiled out in Release
#import "ProjectMBridge.h"
#import "RoonVisCrashReporter.h"
#import "RoonVis-Swift.h"

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    RoonVisLog(@"App launch: didFinishLaunching validatePresets=%@", [NSBundle.mainBundle.infoDictionary[@"RoonVisValidatePresets"] boolValue] ? @"YES" : @"NO");
    // One-shot legacy 292->CotC preset-name migration. INVARIANT: must run BEFORE the
    // ANGLEGLView (or PresetValidator) is allocated (in -buildRootVisualizerContent) —
    // the view constructs ProjectMBridge, which reads favourites/hidden/learned-slow
    // during preset enumeration; migrating later would race the filtered load. It runs
    // here, synchronously, so it still precedes the deferred construction below.
    RoonVisApplyLegacyNameMigrationIfNeeded();
    // MRC: `window` is a retain property and `rootViewController`/`view` retain their
    // assignees, so the alloc's +1 must be balanced — autorelease each here.
    self.window = [[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds] autorelease];
    UIViewController *viewController = [[[UIViewController alloc] init] autorelease];
    // Show a lightweight black container immediately and build the real
    // ANGLE/projectM view one runloop tick later. On the Apple TV HD (A8) the
    // first-launch ANGLE-Metal shader warm blocks the main thread ~18s;
    // constructing the view inside -didFinishLaunching pushed launch past tvOS's
    // ~20s launch watchdog and the app was SIGKILLed (first launch after every
    // install). Returning fast with a placeholder frame satisfies the launch
    // checkpoint and demotes the warm to a tolerated post-launch hang. The A15
    // never hit this (its warm is sub-second) but takes the same path harmlessly.
    UIView *container = [[[UIView alloc] initWithFrame:self.window.bounds] autorelease];
    container.backgroundColor = UIColor.blackColor;
    container.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    viewController.view = container;
    self.window.rootViewController = viewController;
    [self.window makeKeyAndVisible];
    // A visualizer should run continuously — keep tvOS from sleeping/screensaving
    // while the app is foreground.
    application.idleTimerDisabled = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self buildRootVisualizerContent];
    });
    return YES;
}

// Builds the heavy visualizer view hierarchy into the root container. Deferred
// off -didFinishLaunching (see the watchdog note there); runs on the main thread.
- (void)buildRootVisualizerContent
{
    UIViewController *viewController = self.window.rootViewController;
    UIView *container = viewController.view;
#if ROONVIS_ENABLE_PRESET_VALIDATOR
    BOOL validatePresets = [NSBundle.mainBundle.infoDictionary[@"RoonVisValidatePresets"] boolValue];
    if (validatePresets)
    {
        PresetValidator *validator = [[[PresetValidator alloc] initWithFrame:container.bounds] autorelease];
        validator.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [container addSubview:validator];
        return;
    }
#endif
    ANGLEGLView *angleView = [[[ANGLEGLView alloc] initWithFrame:container.bounds] autorelease];
    angleView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [container addSubview:angleView];

    UIViewController *chromeController = [RootChromeFactory makeWithGlView:angleView];
    [viewController addChildViewController:chromeController];
    chromeController.view.frame = angleView.bounds;
    chromeController.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    chromeController.view.backgroundColor = UIColor.clearColor;
    [angleView addSubview:chromeController.view];
    [chromeController didMoveToParentViewController:viewController];
    // The initial didBecomeActive fired before this view existed, so its
    // resume/reconnect no-op'd. The view's own init starts the render loop and
    // snapcast, so nothing further is needed here; subsequent lifecycle events
    // find the view via -angleGLView.
    [viewController setNeedsFocusUpdate];
}

- (ANGLEGLView *)angleGLView
{
    // The view is a subview of the root container (built lazily in
    // -buildRootVisualizerContent), so search rather than cast rootVC.view.
    // Returns nil until the deferred construction runs — lifecycle callers
    // no-op safely on nil.
    for (UIView *view in self.window.rootViewController.view.subviews)
    {
        if ([view isKindOfClass:[ANGLEGLView class]])
        {
            return (ANGLEGLView *)view;
        }
    }
    return nil;
}

#if ROONVIS_ENABLE_PRESET_VALIDATOR
- (PresetValidator *)presetValidator
{
    for (UIView *view in self.window.rootViewController.view.subviews)
    {
        if ([view isKindOfClass:[PresetValidator class]])
        {
            return (PresetValidator *)view;
        }
    }
    return nil;
}
#endif

- (void)applicationDidEnterBackground:(UIApplication *)application
{
    RoonVisLog(@"App lifecycle: didEnterBackground");
    [[self angleGLView] pause];
#if ROONVIS_ENABLE_PRESET_VALIDATOR
    [[self presetValidator] pause];
#endif
    [ProjectMBridge markApplicationCleanShutdown];
}

- (void)applicationWillEnterForeground:(UIApplication *)application
{
    RoonVisLog(@"App lifecycle: willEnterForeground");
    [ProjectMBridge markApplicationRunning];
    ANGLEGLView *view = [self angleGLView];
    [view resume];
    [view reconnectSnapcastNow];
#if ROONVIS_ENABLE_PRESET_VALIDATOR
    [[self presetValidator] resume];
#endif
}

- (void)applicationDidBecomeActive:(UIApplication *)application
{
    RoonVisLog(@"App lifecycle: didBecomeActive");
    [ProjectMBridge markApplicationRunning];
    ANGLEGLView *view = [self angleGLView];
    [view resume];
    [view reconnectSnapcastNow];
#if ROONVIS_ENABLE_PRESET_VALIDATOR
    [[self presetValidator] resume];
#endif
}

- (void)applicationWillTerminate:(UIApplication *)application
{
    RoonVisLog(@"App lifecycle: willTerminate");
    [ProjectMBridge markApplicationCleanShutdown];
}

- (void)dealloc
{
    [_window release];
    [super dealloc];
}

@end
