#import "ProjectMBridgeInternal.h"

#import "RoonVisPerfCounters.h"
#import "RoonVisCrashReporter.h"

static NSString *const kLastShownPresetFilenameKey = @"RoonVisLastShownPresetFilename";

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

@implementation ProjectMBridge (Presets)

- (NSString *)presetDisplayNameForPath:(const std::string &)path
{
    NSString *presetPath = [NSString stringWithUTF8String:path.c_str()];
    return presetPath.lastPathComponent;
}

- (NSUInteger)presetCount
{
    return static_cast<NSUInteger>(_presetPaths.size());
}

- (NSString *)presetFilenameAtIndex:(NSUInteger)index
{
    if (index >= _presetPaths.size())
    {
        return @"";
    }
    return [self presetDisplayNameForPath:_presetPaths[index]];
}

- (NSString *)presetDisplayNameAtIndex:(NSUInteger)index
{
    if (index >= _presetPaths.size())
    {
        return @"";
    }

    NSString *filename = [self presetDisplayNameForPath:_presetPaths[index]];
    NSString *name = [filename stringByDeletingPathExtension];
    NSCharacterSet *separators = [NSCharacterSet characterSetWithCharactersInString:@"_-"];
    NSArray<NSString *> *parts = [name componentsSeparatedByCharactersInSet:separators];
    NSMutableArray<NSString *> *nonEmptyParts = [NSMutableArray arrayWithCapacity:parts.count];
    for (NSString *part in parts)
    {
        if (part.length > 0)
        {
            [nonEmptyParts addObject:part];
        }
    }
    if (nonEmptyParts.count == 0)
    {
        return name;
    }
    return [nonEmptyParts componentsJoinedByString:@" "];
}

- (NSString *)presetPathAtIndex:(NSUInteger)index
{
    if (index >= _presetPaths.size())
    {
        return @"";
    }
    return [NSString stringWithUTF8String:_presetPaths[index].c_str()] ?: @"";
}

- (NSString *)presetBrowserTitleAtIndex:(NSUInteger)index
{
    return RoonVisHumanPresetTitle([self presetDisplayNameAtIndex:index], index);
}

- (NSString *)presetPathForUIAtIndex:(NSUInteger)index
{
    return [self presetPathAtIndex:index];
}

- (BOOL)isFavoriteAtIndex:(NSUInteger)index
{
    NSString *filename = [self presetFilenameAtIndex:index];
    return filename.length > 0 && [self isFavorite:filename];
}

- (NSArray<RoonVisPresetShelf *> *)presetShelvesFavoritesOnly:(BOOL)favoritesOnly
{
    BOOL perfCountersEnabled = RoonVisPerfCountersEnabled();
    CFTimeInterval startTime = perfCountersEnabled ? CACurrentMediaTime() : 0;
    std::vector<RoonVis::PresetShelfInput> inputs = [self presetShelfInputsFavoritesOnly:favoritesOnly];

    std::vector<RoonVis::PresetShelf> shelves = RoonVis::BuildPresetShelves(inputs, favoritesOnly, 3);
    NSMutableArray<RoonVisPresetShelf *> *result = [NSMutableArray arrayWithCapacity:shelves.size()];
    for (const RoonVis::PresetShelf &shelf : shelves)
    {
        NSMutableArray<NSNumber *> *presetIndexes = [NSMutableArray arrayWithCapacity:shelf.indexes.size()];
        for (size_t presetIndex : shelf.indexes)
        {
            [presetIndexes addObject:[NSNumber numberWithUnsignedLong:static_cast<unsigned long>(presetIndex)]];
        }
        NSString *title = [NSString stringWithUTF8String:shelf.title.c_str()] ?: @"Other";
        RoonVisPresetShelf *value = [[RoonVisPresetShelf alloc] initWithTitle:title presetIndexes:presetIndexes];
        [result addObject:value];
        [value release];
    }
    if (perfCountersEnabled)
    {
        RoonVisPerfCountShelvesRecompute((CACurrentMediaTime() - startTime) * 1000.0);
    }
    return result;
}

- (NSInteger)currentPresetIndex
{
    if (_confirmedPresetIndex == SIZE_MAX || _confirmedPresetIndex >= _presetPaths.size())
    {
        return -1;
    }
    return static_cast<NSInteger>(_confirmedPresetIndex);
}

- (void)notifyEngineStateDidChange
{
    void (^post)(void) = ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:RoonVisEngineStateDidChangeNotification object:self];
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

- (BOOL)loadInitialPreset
{
    if (self.projectM == nullptr || _presetPaths.empty())
    {
        return NO;
    }
    if (_confirmedPresetIndex != SIZE_MAX)
    {
        return YES;
    }

    // Debug determinism hook (ROONVIS_ROTATION_FIXED_LIST): every run starts on the
    // first list entry, overriding the persisted last-shown restore below.
    if (!_fixedRotationIndexes.empty() &&
        [self selectPresetAtIndex:_fixedRotationIndexes.front() smooth:NO])
    {
        RoonVisLog(@"Fixed rotation list: starting at first list entry");
        return YES;
    }

    // Restore the preset shown when the app last closed, if it's still present in the
    // (freshly randomised) rotation. Falls through to the first shuffled preset on a
    // first-ever launch, or if that preset was removed/blocklisted since.
    NSString *lastShown = [[NSUserDefaults standardUserDefaults] stringForKey:kLastShownPresetFilenameKey];
    if (lastShown.length > 0)
    {
        for (size_t i = 0; i < _presetPaths.size(); i++)
        {
            if ([[self presetDisplayNameForPath:_presetPaths[i]] isEqualToString:lastShown])
            {
                if ([self selectPresetAtIndex:i smooth:NO])
                {
                    RoonVisLog(@"ProjectM: restored last-shown preset %@", lastShown);
                    return YES;
                }
                break;
            }
        }
    }

    _currentPresetIndex = _presetPaths.size() - 1;
    return [self advancePresetByOffset:1 smooth:NO];
}

- (BOOL)selectPresetAtIndex:(NSUInteger)index smooth:(BOOL)smooth
{
    if (self.projectM == nullptr || index >= _presetPaths.size())
    {
        return NO;
    }

    const std::string &path = _presetPaths[index];
    NSString *presetName = [self presetDisplayNameForPath:path];
    // Fixed-rotation-list presets bypass the hidden/slow refusal (debug determinism
    // hook; the list is always empty in Release).
    const bool inFixedRotationList =
        std::find(_fixedRotationIndexes.begin(), _fixedRotationIndexes.end(), static_cast<size_t>(index)) !=
        _fixedRotationIndexes.end();
    if (!inFixedRotationList && [self isPresetHiddenOrSlow:presetName])
    {
        RoonVisLog(@"ProjectM hardening: refusing direct load of hidden/slow preset %@", presetName);
        return NO;
    }

    _lastGoodPresetIndex = _confirmedPresetIndex;
    if (_currentPresetIndex != SIZE_MAX && index < _currentPresetIndex)
    {
        _presetStepDirection = -1;
    }
    else
    {
        _presetStepDirection = 1;
    }
    _currentPresetIndex = static_cast<size_t>(index);
    self.requestedPresetName = presetName;
    _lastPresetLoadFailed = NO;
    [self invalidatePreloadedPresetTracking];
    [self notifyEngineStateDidChange];
    RoonVisLog(@"Preset switch requested: direct index=%lu smooth=%@ preset=%@",
               static_cast<unsigned long>(index),
               smooth ? @"YES" : @"NO",
               presetName);
    [self recordPresetLoadAttemptForFilename:presetName];
    projectm_load_preset_file(self.projectM, path.c_str(), smooth);

    if (!_lastPresetLoadFailed && [self.requestedPresetName isEqualToString:presetName])
    {
        _confirmedPresetIndex = _currentPresetIndex;
        self.confirmedPresetName = presetName;
        _lastPresetSwitchTime = CACurrentMediaTime();
        _preloadAttemptPresetIndex = SIZE_MAX;
        _preloadAttemptPresetPath.clear();
        RoonVisLog(@"Preset switch confirmed: %@", presetName);
        [self notifyEngineStateDidChange];
        return YES;
    }
    [self notifyEngineStateDidChange];
    return NO;
}

- (BOOL)advancePresetByOffset:(NSInteger)offset smooth:(BOOL)smooth
{
    if (self.projectM == nullptr || _presetPaths.empty())
    {
        return NO;
    }

    _lastGoodPresetIndex = _confirmedPresetIndex;
    size_t nextIndex = [self nextRotationIndexFrom:_currentPresetIndex offset:offset];
    if (nextIndex != SIZE_MAX && nextIndex < _presetPaths.size())
    {
        const std::string &path = _presetPaths[nextIndex];
        NSString *presetName = [self presetDisplayNameForPath:path];

        _currentPresetIndex = nextIndex;
        self.requestedPresetName = presetName;
        _lastPresetLoadFailed = NO;
        [self notifyEngineStateDidChange];
        RoonVisLog(@"Preset switch requested: offset=%ld smooth=%@ preset=%@",
                   static_cast<long>(offset),
                   smooth ? @"YES" : @"NO",
                   presetName);
        [self recordPresetLoadAttemptForFilename:presetName];

        BOOL activatedPreload = NO;
        BOOL perfCountersEnabled = RoonVisPerfCountersEnabled();
        BOOL preloadUsable = offset == 1 &&
                             _preloadedPresetIndex == nextIndex &&
                             _preloadedPresetPath == path &&
                             projectm_has_preloaded_preset(self.projectM);
        // Phase 3c: the preload's shader compile runs in the background. Normally the
        // ~6 s pre-warm lead means it's long done by switch time; if it isn't, skip the
        // warm activation and take the synchronous load below rather than block the
        // finalize on an in-flight compile (correctness > smoothness).
        if (preloadUsable && !projectm_preloaded_preset_compile_ready(self.projectM))
        {
            RoonVisLog(@"ProjectM preload not compile-ready at switch; falling back to load %@", presetName);
            [self invalidatePreloadedPresetTracking];
            preloadUsable = NO;
        }
        if (preloadUsable)
        {
            CFTimeInterval activateStart = perfCountersEnabled ? CACurrentMediaTime() : 0;
            activatedPreload = projectm_activate_preloaded_preset(self.projectM, smooth) ? YES : NO;
            if (perfCountersEnabled && activatedPreload)
            {
                RoonVisPerfCountWarmActivation(true, (CACurrentMediaTime() - activateStart) * 1000.0);
            }
            if (!activatedPreload)
            {
                RoonVisLog(@"ProjectM preload dropped before activate; falling back to load %@", presetName);
                [self invalidatePreloadedPresetTracking];
            }
        }

        if (!activatedPreload)
        {
            if (offset != 1 || _preloadedPresetIndex != nextIndex || _preloadedPresetPath != path)
            {
                [self invalidatePreloadedPresetTracking];
            }
            CFTimeInterval loadStart = perfCountersEnabled ? CACurrentMediaTime() : 0;
            projectm_load_preset_file(self.projectM, path.c_str(), smooth);
            if (perfCountersEnabled)
            {
                RoonVisPerfCountWarmActivation(false, (CACurrentMediaTime() - loadStart) * 1000.0);
            }
        }
        else
        {
            [self invalidatePreloadedPresetTracking];
        }

        if (!_lastPresetLoadFailed && [self.requestedPresetName isEqualToString:presetName])
        {
            _confirmedPresetIndex = _currentPresetIndex;
            self.confirmedPresetName = presetName;
            _lastPresetSwitchTime = CACurrentMediaTime();
            _preloadAttemptPresetIndex = SIZE_MAX;
            _preloadAttemptPresetPath.clear();
            if (activatedPreload)
            {
                // A primary-preload activation IS the warm hit: mark the preset so the
                // slow-preset guard ignores its (expected-slow, full-res PSO compile)
                // first frame — PerfDiagTransitionWarmFirstFrameIgnored.
                [_warmedFirstFramePresetName release];
                _warmedFirstFramePresetName = [presetName copy];
                RoonVisLog(@"Preset warm cache: activated warmed preset %@", presetName);
            }
            RoonVisLog(@"Preset switch confirmed: %@", presetName);
            [self notifyEngineStateDidChange];
            return YES;
        }
        [self notifyEngineStateDidChange];
        return NO;
    }

    RoonVisLog(@"ProjectM hardening: no eligible presets available for requested direction");
    return NO;
}

- (void)advanceToNextPresetSmooth:(BOOL)smooth
{
    _presetStepDirection = 1;
    [self advancePresetByOffset:1 smooth:smooth];
}

- (BOOL)selectNextPresetSmooth:(BOOL)smooth
{
    _presetStepDirection = 1;
    return [self advancePresetByOffset:1 smooth:smooth];
}

- (BOOL)selectPreviousPresetSmooth:(BOOL)smooth
{
    _presetStepDirection = -1;
    return [self advancePresetByOffset:-1 smooth:smooth];
}

- (void)markPresetNameSlow:(NSString *)presetName catastrophic:(BOOL)catastrophic
{
    const char *fileSystemName = presetName.fileSystemRepresentation;
    if (fileSystemName == nullptr)
    {
        return;
    }

    // Session-only rotation exclusion: always drop the preset for the rest of this run.
    _slowPresetNames.insert(fileSystemName);

    // Persistent learned-slow bookkeeping. The over-exclusion guard (in the store) only
    // promotes to the cross-launch list on a catastrophic frame or a second distinct
    // detection, so a single transient first-cold-load flag does not ban permanently.
    RoonVis::LearnedSlowDecision decision =
        _learnedSlowStore.RecordDetection(fileSystemName, catastrophic ? true : false);
    if (decision.stateChanged)
    {
        [self persistLearnedSlowState];
        if (decision.nowLearnedSlow)
        {
            RoonVisLog(@"ProjectM hardening: learned-slow preset persisted %@ (catastrophic=%d)",
                       presetName, catastrophic);
        }
    }
}

- (void)setPresetRotationHeld:(BOOL)held
{
    if (self.projectM == nullptr)
    {
        return;
    }
    _presetRotationHeld = held;
    projectm_set_preset_locked(self.projectM, held);
    RoonVisLog(@"ProjectM hardening: preset rotation %@", held ? @"held" : @"resumed");
    [self notifyEngineStateDidChange];
}

- (BOOL)isFavorite:(NSString *)presetFilename
{
    return [[RoonVisSettings sharedSettings] isFavoritePresetFilename:presetFilename];
}

- (BOOL)toggleFavorite:(NSString *)presetFilename
{
    if (presetFilename.length == 0)
    {
        return NO;
    }

    RoonVisSettings *settings = [RoonVisSettings sharedSettings];
    if ([settings isFavoritePresetFilename:presetFilename])
    {
        [settings removeFavoritePresetFilename:presetFilename];
        RoonVisLog(@"Preset favorite removed: %@", presetFilename);
        return NO;
    }

    [settings addFavoritePresetFilename:presetFilename];
    RoonVisLog(@"Preset favorite added: %@", presetFilename);
    return YES;
}

- (BOOL)isHidden:(NSString *)presetFilename
{
    return [[RoonVisSettings sharedSettings] isHiddenPresetFilename:presetFilename];
}

- (void)hidePreset:(NSString *)presetFilename
{
    if (presetFilename.length == 0)
    {
        return;
    }

    [[RoonVisSettings sharedSettings] addHiddenPresetFilename:presetFilename];
    RoonVisLog(@"Preset hidden: %@", presetFilename);
    _browsePresetOrderIndexes = [self rotationCandidateIndexesForMode:RoonVisPresetRotationModeLoop];
    if ([self.confirmedPresetName isEqualToString:presetFilename])
    {
        [self selectNextPresetSmooth:[self settingsTransitionUsesSmoothCut]];
    }
}

- (void)handlePresetSwitchRequested:(bool)isHardCut
{
    _rotationScheduler.NoteSwitchRequested();
    if (isHardCut)
    {
        // Beat-detected hard cut: honor at most once per rotation interval. projectM
        // re-requests a hard cut on every strong beat, and because we service every
        // request as a crossfade (never performing projectM's own hard cut) its
        // internal anti-spam gate never resets — so a loud passage fires a burst of
        // switches and the visualizer flails through presets. Sensitivity alone can't
        // fix this; rate-limit on our side against the last confirmed switch so a beat
        // can nudge the rotation onto a musical moment but never faster than the
        // configured cadence.
        CFTimeInterval now = CACurrentMediaTime();
        double minInterval = _rotationIntervalSeconds;
        if (_lastPresetSwitchTime > 0 && (now - _lastPresetSwitchTime) < minInterval)
        {
            // Suppress this beat-driven hard cut to prevent the flail — but first reset
            // projectM's switch-notification flag. projectM sets m_presetChangeNotified =
            // true IMMEDIATELY BEFORE invoking this callback; returning without loading a
            // preset strands that flag, after which projectM never fires ANY further switch
            // event (soft or hard) and rotation dies completely. set_preset_locked()
            // rewrites the flag, so pass the current hold state to clear it (when not held)
            // and let the timed soft rotation keep firing.
            projectm_set_preset_locked(self.projectM, _presetRotationHeld);
            return;
        }
    }
    RoonVisLog(@"ProjectM hardening: preset switch requested (%@)", isHardCut ? @"hard cut" : @"soft cut");
    [self advanceToNextPresetSmooth:[self settingsTransitionUsesSmoothCut]];
    // Diagnostic recording removed (see PR history for details).
}

- (void)handlePresetSwitchFailed:(const char *)presetFilename message:(const char *)message
{
    NSString *filename = presetFilename != nullptr ? [NSString stringWithUTF8String:presetFilename] : @"(unknown)";
    NSString *error = message != nullptr ? [NSString stringWithUTF8String:message] : @"(unknown)";
    if (_preloadingPreset)
    {
        RoonVisLog(@"ProjectM preload failed: %@: %@", filename.lastPathComponent, error);
        _preloadedPresetPath.clear();
        _preloadedPresetIndex = SIZE_MAX;
        return;
    }

    _lastPresetLoadFailed = YES;
    [self invalidatePreloadedPresetTracking];

    const bool hasLastGood = (_lastGoodPresetIndex != SIZE_MAX && _lastGoodPresetIndex < _presetPaths.size());
    const RoonVis::PresetRotationScheduler::FailureAction action =
        _rotationScheduler.NoteSwitchFailed(_revertingToLastGoodPreset ? true : false, hasLastGood);

    if ((_rotationScheduler.FailuresTotal() % 25) == 0)
    {
        RoonVisLog(@"ProjectM hardening: %lu preset loads have failed; preset pack may be partly incompatible",
                   _rotationScheduler.FailuresTotal());
    }

    switch (action)
    {
        case RoonVis::PresetRotationScheduler::FailureAction::RevertToLastGood:
        {
            _currentPresetIndex = _lastGoodPresetIndex;
            const std::string &path = _presetPaths[_currentPresetIndex];
            NSString *presetName = [self presetDisplayNameForPath:path];
            self.requestedPresetName = presetName;
            _lastPresetLoadFailed = NO;
            _revertingToLastGoodPreset = YES;
            [self invalidatePreloadedPresetTracking];
            [self notifyEngineStateDidChange];
            [self recordPresetLoadAttemptForFilename:presetName];
            projectm_load_preset_file(self.projectM, path.c_str(), [self settingsTransitionUsesSmoothCut]);
            _revertingToLastGoodPreset = NO;
            if (!_lastPresetLoadFailed && [self.requestedPresetName isEqualToString:presetName])
            {
                _confirmedPresetIndex = _currentPresetIndex;
                self.confirmedPresetName = presetName;
                _lastPresetSwitchTime = CACurrentMediaTime();
                _preloadAttemptPresetIndex = SIZE_MAX;
                _preloadAttemptPresetPath.clear();
                RoonVisLog(@"Preset switch failed: %@: %@; skip cap reached, reverting to last-good %@",
                           filename.lastPathComponent,
                           error,
                           presetName);
                [self notifyEngineStateDidChange];
            }
            else
            {
                RoonVisLog(@"Preset switch failed: %@: %@; skip cap reached, last-good revert also failed",
                           filename.lastPathComponent,
                           error);
                [self notifyEngineStateDidChange];
            }
            return;
        }

        case RoonVis::PresetRotationScheduler::FailureAction::HoldConfirmed:
        {
            if (_revertingToLastGoodPreset)
            {
                RoonVisLog(@"Preset switch failed: last-good revert failed for %@: %@; keeping confirmed preset %@",
                           filename.lastPathComponent,
                           error,
                           self.confirmedPresetName ?: @"(none)");
            }
            else
            {
                RoonVisLog(@"Preset switch failed: %@: %@; skip cap reached",
                           filename.lastPathComponent,
                           error);
            }
            return;
        }

        case RoonVis::PresetRotationScheduler::FailureAction::SkipToNext:
        {
            RoonVisLog(@"Preset switch failed: %@: %@; skipping (%lu/%u)",
                       filename.lastPathComponent,
                       error,
                       static_cast<unsigned long>(_rotationScheduler.FailureSkips()),
                       _rotationScheduler.SkipCap());
            [self advancePresetByOffset:_presetStepDirection smooth:[self settingsTransitionUsesSmoothCut]];
            return;
        }
    }
}


@end

#pragma clang diagnostic pop
