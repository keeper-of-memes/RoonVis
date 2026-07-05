#import "AppDelegate.h"

#import "ANGLEGLView.h"
#import "PresetValidator.h"  // QA-only; body compiled out in Release
#import "ProjectMBridge.h"
#import "RoonVisCrashReporter.h"
#import "RoonVis-Swift.h"

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    RoonVisLog(@"App launch: didFinishLaunching validatePresets=%@", [NSBundle.mainBundle.infoDictionary[@"RoonVisValidatePresets"] boolValue] ? @"YES" : @"NO");
    // MRC: `window` is a retain property and `rootViewController`/`view` retain their
    // assignees, so the alloc's +1 must be balanced — autorelease each here.
    self.window = [[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds] autorelease];
    UIViewController *viewController = [[[UIViewController alloc] init] autorelease];
#if ROONVIS_ENABLE_PRESET_VALIDATOR
    BOOL validatePresets = [NSBundle.mainBundle.infoDictionary[@"RoonVisValidatePresets"] boolValue];
    if (validatePresets)
    {
        PresetValidator *validator = [[[PresetValidator alloc] initWithFrame:self.window.bounds] autorelease];
        validator.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        viewController.view = validator;
    }
    else
#endif
    {
        ANGLEGLView *angleView = [[[ANGLEGLView alloc] initWithFrame:self.window.bounds] autorelease];
        angleView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        viewController.view = angleView;

        UIViewController *chromeController = [RootChromeFactory makeWithGlView:angleView];
        [viewController addChildViewController:chromeController];
        chromeController.view.frame = angleView.bounds;
        chromeController.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        chromeController.view.backgroundColor = UIColor.clearColor;
        [angleView addSubview:chromeController.view];
        [chromeController didMoveToParentViewController:viewController];
    }
    self.window.rootViewController = viewController;
    [self.window makeKeyAndVisible];
    // A visualizer should run continuously — keep tvOS from sleeping/screensaving
    // while the app is foreground.
    application.idleTimerDisabled = YES;
    return YES;
}

- (ANGLEGLView *)angleGLView
{
    UIView *view = self.window.rootViewController.view;
    if (![view isKindOfClass:[ANGLEGLView class]])
    {
        return nil;
    }
    return (ANGLEGLView *)view;
}

#if ROONVIS_ENABLE_PRESET_VALIDATOR
- (PresetValidator *)presetValidator
{
    UIView *view = self.window.rootViewController.view;
    if (![view isKindOfClass:[PresetValidator class]])
    {
        return nil;
    }
    return (PresetValidator *)view;
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
