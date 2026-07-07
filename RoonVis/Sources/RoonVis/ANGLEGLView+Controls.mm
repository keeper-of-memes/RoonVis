#import "ANGLEGLViewInternal.h"

#import "ProjectMBridge.h"
#import "RoonVis-Swift.h"
#import "RoonVisCrashReporter.h"
#import "RoonVisTheme.h"

static NSString * const kVisualizerHintSeenDefaultsKey = @"RoonVisVisualizerContextHintSeen";

@implementation ANGLEGLView (Controls)

- (void)postRemoteStatusWithEyebrow:(NSString *)eyebrow
                               title:(NSString *)title
                              symbol:(nullable NSString *)symbol
                              sticky:(BOOL)sticky
{
    if (title.length == 0)
    {
        return;
    }

    NSMutableDictionary *userInfo = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                                     eyebrow ?: @"Now Playing", RoonVisRemoteStatusEyebrowKey,
                                     title, RoonVisRemoteStatusTitleKey,
                                     [NSNumber numberWithBool:sticky], RoonVisRemoteStatusStickyKey,
                                     nil];
    if (symbol.length > 0)
    {
        userInfo[RoonVisRemoteStatusSymbolKey] = symbol;
    }

    void (^post)(void) = ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:RoonVisRemoteStatusNotification object:self userInfo:userInfo];
    };
    if (NSThread.isMainThread)
    {
        post();
    }
    else
    {
        dispatch_async(dispatch_get_main_queue(), post);
    }
}

- (void)postPresetWarmupActive:(BOOL)active text:(NSString *)text
{
    NSDictionary *userInfo = @{
        RoonVisPresetWarmupActiveKey: [NSNumber numberWithBool:active],
        RoonVisPresetWarmupTextKey: text ?: @"Preparing..."
    };
    void (^post)(void) = ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:RoonVisPresetWarmupNotification object:self userInfo:userInfo];
    };
    if (NSThread.isMainThread)
    {
        post();
    }
    else
    {
        dispatch_async(dispatch_get_main_queue(), post);
    }
}

- (NSString *)currentPresetStatusTitle
{
    return self.projectMBridge.confirmedPresetName ?: self.projectMBridge.requestedPresetName ?: @"No preset loaded";
}

- (void)selectNextPresetFromRemote
{
    RoonVisLog(@"Remote UI: next preset requested");
    if (![self.projectMBridge selectNextPresetSmooth:NO])
    {
        [self postRemoteStatusWithEyebrow:@"Preset" title:@"No next preset" symbol:@"forward.fill" sticky:NO];
        return;
    }
    [self postRemoteStatusWithEyebrow:@"Next Preset" title:[self currentPresetStatusTitle] symbol:@"forward.fill" sticky:NO];
}

- (void)selectPreviousPresetFromRemote
{
    RoonVisLog(@"Remote UI: previous preset requested");
    if (![self.projectMBridge selectPreviousPresetSmooth:NO])
    {
        [self postRemoteStatusWithEyebrow:@"Preset" title:@"No previous preset" symbol:@"backward.fill" sticky:NO];
        return;
    }
    [self postRemoteStatusWithEyebrow:@"Previous Preset" title:[self currentPresetStatusTitle] symbol:@"backward.fill" sticky:NO];
}

- (void)togglePresetHoldFromRemote
{
    BOOL held = !self.projectMBridge.presetRotationHeld;
    RoonVisLog(@"Remote UI: preset rotation %@", held ? @"held" : @"resumed");
    [self.projectMBridge setPresetRotationHeld:held];
    [self postRemoteStatusWithEyebrow:(held ? @"Rotation Held" : @"Rotation Resumed")
                                title:[self currentPresetStatusTitle]
                               symbol:(held ? @"pause.fill" : @"play.fill")
                               sticky:held];
}

- (void)resumePresetRotationFromRemote
{
    RoonVisLog(@"Remote UI: preset rotation resumed");
    [self.projectMBridge setPresetRotationHeld:NO];
    [self postRemoteStatusWithEyebrow:@"Rotation Resumed" title:[self currentPresetStatusTitle] symbol:@"play.fill" sticky:NO];
}

- (void)showCurrentPresetFromRemote
{
    RoonVisLog(@"Remote UI: current preset shown");
    NSString *eyebrow = self.projectMBridge.presetRotationHeld ? @"Rotation Held" : @"Now Playing";
    [self postRemoteStatusWithEyebrow:eyebrow
                                title:[self currentPresetStatusTitle]
                               symbol:@"sparkles"
                               sticky:self.projectMBridge.presetRotationHeld];
}

- (void)presentBrowseFromRemote
{
    if (self.browseController != nil || self.projectMBridge == nil)
    {
        return;
    }

    UIViewController *presentingController = self.window.rootViewController;
    if (presentingController == nil || presentingController.presentedViewController != nil)
    {
        return;
    }

    // Menu from Now Playing opens the playlist (Presets tab) focused on the current
    // preset — not the last-viewed tab (user issue #1).
    UIViewController *browse = [BrowseModalFactory makePlaylistFocusedWithGlView:self];
    browse.modalPresentationStyle = UIModalPresentationOverFullScreen;
    browse.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    self.browseController = browse;
    RoonVisLog(@"Browse present (playlist focused)");
    self.displayLink.paused = YES;
    [presentingController presentViewController:browse animated:![RoonVisTheme reduceMotionEnabled] completion:nil];
}

- (void)swipeDownRecognized:(UISwipeGestureRecognizer *)recognizer
{
    if (recognizer.state == UIGestureRecognizerStateRecognized)
    {
        RoonVisLog(@"Remote UI: swipe down quick settings requested");
        [self presentQuickSettingsFromRemote];
    }
}

- (void)swipeUpRecognized:(UISwipeGestureRecognizer *)recognizer
{
    if (recognizer.state == UIGestureRecognizerStateRecognized && self.quickSettingsController != nil)
    {
        RoonVisLog(@"Remote UI: swipe up quick settings dismiss");
        [self dismissQuickSettings];
    }
}

- (void)longPressRecognized:(UILongPressGestureRecognizer *)recognizer
{
    if (recognizer.state != UIGestureRecognizerStateBegan)
    {
        return;
    }
    // The long press consumed this Select press: releasing it must not toggle
    // the rotation hold in pressesEnded.
    _selectPressPending = NO;
    if (self.browseController != nil || self.quickSettingsController != nil || self.presetOptionsController != nil)
    {
        return;
    }
    RoonVisLog(@"Remote UI: long press select preset options requested");
    [self presentPresetOptionsFromRemote];
}

- (void)presentPresetOptionsFromRemote
{
    if (self.presetOptionsController != nil || self.projectMBridge == nil)
    {
        return;
    }

    UIViewController *presentingController = self.window.rootViewController;
    if (presentingController == nil || presentingController.presentedViewController != nil)
    {
        return;
    }

    // Same modal pattern as quick settings: a real modal gets its own focus
    // environment. The displayLink keeps running — the visualizer stays live
    // behind the scrim.
    UIViewController *options = [PresetOptionsOverlayFactory makeWithGlView:self];
    options.modalPresentationStyle = UIModalPresentationOverFullScreen;
    options.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    self.presetOptionsController = options;
    RoonVisLog(@"Preset options present");
    [presentingController presentViewController:options animated:![RoonVisTheme reduceMotionEnabled] completion:nil];
}

- (void)dismissPresetOptions
{
    UIViewController *options = self.presetOptionsController;
    if (options == nil)
    {
        return;
    }
    RoonVisLog(@"Preset options dismiss");
    self.presetOptionsController = nil;
    [options dismissViewControllerAnimated:![RoonVisTheme reduceMotionEnabled] completion:nil];
}

- (void)dismissPresetOptionsFromUI
{
    RoonVisLog(@"Preset options requested dismiss");
    [self dismissPresetOptions];
}

- (void)presentQuickSettingsFromRemote
{
    if (self.quickSettingsController != nil)
    {
        return;
    }

    UIViewController *presentingController = self.window.rootViewController;
    if (presentingController == nil || presentingController.presentedViewController != nil)
    {
        return;
    }

    // Present as a real modal (like Browse), not a subview overlay. A modal gets its
    // own focus environment, so directional focus can traverse the rows; as a plain
    // subview the focus engine seeded entry focus but could not move between rows.
    // UIKit moves focus into the modal automatically and retains it across the
    // presentation, so no manual focus update or MRC retain dance is needed here.
    UIViewController *quickSettings = [QuickSettingsPanelFactory makeWithGlView:self];
    quickSettings.modalPresentationStyle = UIModalPresentationOverFullScreen;
    quickSettings.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    self.quickSettingsController = quickSettings;
    RoonVisLog(@"Quick settings present");
    [presentingController presentViewController:quickSettings animated:![RoonVisTheme reduceMotionEnabled] completion:nil];
}

- (void)dismissQuickSettings
{
    UIViewController *quickSettings = self.quickSettingsController;
    if (quickSettings == nil)
    {
        return;
    }
    RoonVisLog(@"Quick settings dismiss");
    self.quickSettingsController = nil;
    [quickSettings dismissViewControllerAnimated:![RoonVisTheme reduceMotionEnabled] completion:nil];
}

- (void)dismissQuickSettingsFromUI
{
    RoonVisLog(@"Quick settings requested dismiss");
    [self dismissQuickSettings];
}

- (void)dismissBrowse
{
    UIViewController *browse = self.browseController;
    if (browse == nil)
    {
        return;
    }

    RoonVisLog(@"Browse dismiss");
    self.browseController = nil;
    self.displayLink.paused = NO;
    [browse dismissViewControllerAnimated:![RoonVisTheme reduceMotionEnabled] completion:nil];
}

- (void)showVisualizerHintIfNeeded
{
    if ([[NSUserDefaults standardUserDefaults] boolForKey:kVisualizerHintSeenDefaultsKey])
    {
        return;
    }
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kVisualizerHintSeenDefaultsKey];
    // Delay past the launch screen: warm-up completes while the system snapshot still
    // covers the app, so an immediate toast would show and auto-clear entirely unseen.
    // The block retains self until it fires (one-shot, at launch) — acceptable.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self postRemoteStatusWithEyebrow:@"Controls"
                                    title:@"Menu opens browse · Swipe down opens quick settings"
                                   symbol:@"sparkles"
                                   sticky:NO];
    });
}

- (void)selectPresetAtIndexFromUI:(NSUInteger)index
{
    RoonVisLog(@"Browse preset selected: index=%lu", static_cast<unsigned long>(index));
    [self.projectMBridge selectPresetAtIndex:index smooth:NO];
    [self dismissBrowse];
}

- (void)toggleFavoriteAtIndexFromUI:(NSUInteger)index
{
    NSString *filename = [self.projectMBridge presetFilenameAtIndex:index];
    if (filename.length == 0)
    {
        return;
    }
    RoonVisLog(@"Preset browser favorite action: %@", filename);
    [self.projectMBridge toggleFavorite:filename];
}

- (void)hidePresetAtIndexFromUI:(NSUInteger)index
{
    NSString *filename = [self.projectMBridge presetFilenameAtIndex:index];
    if (filename.length == 0)
    {
        return;
    }
    RoonVisLog(@"Preset browser hide action: %@", filename);
    [self.projectMBridge hidePreset:filename];
}

- (void)dismissBrowseFromUI
{
    RoonVisLog(@"Browse requested now playing");
    [self dismissBrowse];
}

// Sync calibration entry. Exact order (review-mandated): dismiss Browse ->
// unpause the display link -> gate on live PCM -> beginSyncCalibration ->
// present. beginSyncCalibration is never called while Browse is up or before
// the gate passes.
- (void)presentSyncCalibrationFromUI
{
    [self presentSyncCalibrationFromUIAttempt:0];
}

- (void)presentSyncCalibrationFromUIAttempt:(NSInteger)attempt
{
    if (self.syncCalibrationController != nil || self.projectMBridge == nil || !self.projectMBridge.isReady)
    {
        return;
    }
    if (self.quickSettingsController != nil || self.presetOptionsController != nil)
    {
        return;
    }

    if (self.browseController != nil)
    {
        // dismissBrowse also unpauses the display link; re-enter once the
        // dismissal settles so the modal presentation slot is free.
        [self dismissBrowse];
    }

    // Correctness invariant: calibration is meaningless with a paused render
    // loop (feedLivePCM never runs). Browse dismissal restores it, but assert
    // the state explicitly rather than assuming the path.
    self.displayLink.paused = NO;

    if (![self.projectMBridge isLivePCMActive])
    {
        [self postRemoteStatusWithEyebrow:@"Sync Calibration"
                                    title:@"Connect Snapcast and play music to calibrate"
                                   symbol:@"waveform.slash"
                                   sticky:NO];
        RoonVisLog(@"Sync calibration: entry blocked (no live PCM)");
        return;
    }

    UIViewController *presentingController = self.window.rootViewController;
    if (presentingController == nil || presentingController.presentedViewController != nil)
    {
        // A modal dismissal (Browse) is still animating: retry briefly rather
        // than silently giving up. Bounded so a stuck presentation can't loop.
        if (attempt < 8)
        {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [self presentSyncCalibrationFromUIAttempt:attempt + 1];
            });
        }
        else
        {
            RoonVisLog(@"Sync calibration: entry abandoned (presentation slot never freed)");
        }
        return;
    }

    [self.projectMBridge beginSyncCalibration];
    UIViewController *calibration = [SyncCalibrationFactory makeWithGlView:self];
    self.syncCalibrationController = calibration;
    RoonVisLog(@"Sync calibration present");
    [presentingController presentViewController:calibration animated:![RoonVisTheme reduceMotionEnabled] completion:nil];
    [self setNeedsFocusUpdate];
    [self updateFocusIfNeeded];
}

- (void)dismissSyncCalibrationSaving:(BOOL)save
{
    UIViewController *calibration = self.syncCalibrationController;
    if (calibration == nil)
    {
        return;
    }

    NSInteger alignedMs = self.projectMBridge.syncCalibrationDelayMs;
    double avgRenderMs = 0.0;
    double avgSwapMs = 0.0;
    [self readLatencyLockRunningAveragesRenderMs:&avgRenderMs swapMs:&avgSwapMs];
    [self.projectMBridge endSyncCalibrationSaving:save avgRenderMs:avgRenderMs avgSwapMs:avgSwapMs];
    [self resetLatencyLockWindow];

    self.syncCalibrationController = nil;
    [calibration dismissViewControllerAnimated:![RoonVisTheme reduceMotionEnabled] completion:nil];
    [self setNeedsFocusUpdate];
    [self updateFocusIfNeeded];

    if (save)
    {
        // The saved setting IS the aligned number (render compensation is
        // internal), so one number tells the whole user-facing story.
        [self postRemoteStatusWithEyebrow:@"Sync Calibration"
                                    title:[NSString stringWithFormat:@"Sync saved · %ld ms",
                                                                     static_cast<long>(alignedMs)]
                                   symbol:@"metronome"
                                   sticky:NO];
    }
    else
    {
        [self postRemoteStatusWithEyebrow:@"Sync Calibration"
                                    title:@"Cancelled — previous sync restored"
                                   symbol:@"arrow.uturn.backward"
                                   sticky:NO];
    }
    RoonVisLog(@"Sync calibration dismissed (save=%d)", save ? 1 : 0);
}

- (void)setPresetRotationHeldFromUI:(BOOL)held
{
    RoonVisLog(@"Quick settings action: rotation %@", held ? @"paused" : @"resumed");
    [self.projectMBridge setPresetRotationHeld:held];
    [self postRemoteStatusWithEyebrow:(held ? @"Rotation Held" : @"Rotation Resumed")
                                title:[self currentPresetStatusTitle]
                               symbol:(held ? @"pause.fill" : @"play.fill")
                               sticky:held];
}

@end
