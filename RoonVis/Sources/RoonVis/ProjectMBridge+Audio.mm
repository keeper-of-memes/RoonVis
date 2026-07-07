#import "ProjectMBridgeInternal.h"
#import "RoonVisSettings.h"

#include "SyncCalibrationMath.h"

#import "RoonVisCrashReporter.h"

#include <algorithm>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

@implementation ProjectMBridge (Audio)

- (void)setEffectiveAudioDelayMs:(NSInteger)effectiveAudioDelayMs
{
    // Clamp to [0, user target] — the lock only ever trims the buffer below the
    // target, never beyond it. Runs on the GL thread (same as feedLivePCM), so the
    // _audioDelayFrames read/write is not contended; rebase takes _livePCMMutex.
    // The lock may budget above the user-visible setting by the internal render
    // compensation (the user aligned WITH render cost in the chain).
    NSInteger ceiling = _audioInputDelayMs + _syncRenderCompensationMs;
    NSInteger clamped = MAX((NSInteger)0, MIN(ceiling, effectiveAudioDelayMs));
    if (clamped == _effectiveAudioDelayMs)
    {
        return;
    }
    _effectiveAudioDelayMs = clamped;
    _audioDelayFrames = LivePCMDelayFramesForMilliseconds(clamped);
    [self rebaseLivePCMBufferToDelay];
}

- (BOOL)isLivePCMActive
{
#if ROONVIS_ENABLE_DIAGNOSTIC_MODES
    // Sim/UITest bypass: the simulator has no Snapcast, so the entry gate would
    // make the calibration UI untestable there. Never set outside test runs.
    static BOOL bypass = NSProcessInfo.processInfo.environment[@"ROONVIS_ALLOW_SYNC_CAL_WITHOUT_LIVE_PCM"].boolValue;
    if (bypass)
    {
        return YES;
    }
#endif
    bool active;
    CFTimeInterval lastEnqueue;
    {
        std::lock_guard<std::mutex> lock(_livePCMMutex);
        active = _livePCMActive;
        lastEnqueue = _lastLivePCMEnqueueTime;
    }
    // Same 3 s enqueue-staleness rule renderFrame uses; the WAV fallback never
    // sets _livePCMActive, so it can never pass this gate.
    return active && !_livePCMInFallback && lastEnqueue > 0 &&
           (CACurrentMediaTime() - lastEnqueue) <= 3.0;
}

- (BOOL)syncCalibrationActive
{
    return _syncCalibrationActive;
}

- (NSInteger)syncCalibrationDelayMs
{
    return _audioInputDelayMs;
}

- (BOOL)syncCalibrationOnsetThisFrame
{
    return _syncCalibrationOnsetThisFrame;
}

- (NSInteger)syncRenderCompensationMs
{
    return _syncRenderCompensationMs;
}

// Pins target == effective == ms and rebases the ring; the shared direct-apply
// core for nudges, save (step 2b) and cancel-restore.
- (void)syncCalApplyDelayMsDirect:(NSInteger)ms
{
    NSInteger clamped = MAX((NSInteger)0, MIN((NSInteger)500, ms));
    _audioInputDelayMs = clamped;
    _effectiveAudioDelayMs = clamped;
    _audioDelayFrames = LivePCMDelayFramesForMilliseconds(clamped);
    [self rebaseLivePCMBufferToDelay];
}

- (void)beginSyncCalibration
{
    NSAssert(NSThread.isMainThread, @"sync calibration is main/GL-thread only");
    if (_syncCalibrationActive)
    {
        return;
    }
    _syncCalStashedTargetMs = _audioInputDelayMs;
    _syncCalStashedEffectiveMs = _effectiveAudioDelayMs;
    _syncCalStashedRotationHeld = _presetRotationHeld;
    [self setPresetRotationHeld:YES];
    _onsetDetector.Configure(kLivePCMSampleRate, 2);
    _syncCalibrationActive = YES;
    _syncCalibrationOnsetThisFrame = NO;
    // Pin effective to the target so the user starts nudging from the number
    // Settings shows (the lock may have been holding effective below it).
    [self syncCalApplyDelayMsDirect:_audioInputDelayMs];
    RoonVisLog(@"Sync calibration: begin (target=%ldms effective-was=%ldms)",
               static_cast<long>(_syncCalStashedTargetMs),
               static_cast<long>(_syncCalStashedEffectiveMs));
}

- (void)setSyncCalibrationDelayMs:(NSInteger)ms
{
    NSAssert(NSThread.isMainThread, @"sync calibration is main/GL-thread only");
    if (!_syncCalibrationActive)
    {
        return;
    }
    [self syncCalApplyDelayMsDirect:ms];
}

- (void)endSyncCalibrationSaving:(BOOL)save avgRenderMs:(double)avgRenderMs avgSwapMs:(double)avgSwapMs
{
    NSAssert(NSThread.isMainThread, @"sync calibration is main/GL-thread only");
    if (!_syncCalibrationActive)
    {
        return;
    }
    if (save)
    {
        const long aligned = static_cast<long>(_audioInputDelayMs);
        // The user-visible setting IS the aligned number; the render trim moves
        // into the internal compensation the lock budgets on top. Total latency
        // behaviour is identical to persisting (aligned + trim) as the target.
        const long fullTarget = RoonVis::SyncCalibrationSaveTarget(aligned, avgRenderMs, avgSwapMs);
        _syncRenderCompensationMs = MAX((NSInteger)0, static_cast<NSInteger>(fullTarget - aligned));
        [[NSUserDefaults standardUserDefaults] setInteger:_syncRenderCompensationMs
                                                   forKey:@"RoonVisSyncRenderCompensationMs"];
        // Land the aligned value in the ivars BEFORE clearing the flag, so no
        // frame runs against stale state with the lock re-armed.
        [self syncCalApplyDelayMsDirect:aligned];
        _syncCalibrationActive = NO;
        [self setPresetRotationHeld:_syncCalStashedRotationHeld];
        // Persist via the normal settings path (Settings now shows the aligned
        // number; the queued pending value applies next frame to the same value).
        [RoonVisSettings sharedSettings].audioInputDelayMs = aligned;
        RoonVisLog(@"Sync calibration: saved (aligned=%ldms compensation=%ldms avgRender=%.1f avgSwap=%.1f)",
                   aligned, static_cast<long>(_syncRenderCompensationMs), avgRenderMs, avgSwapMs);
    }
    else
    {
        _syncCalibrationActive = NO;
        [self setPresetRotationHeld:_syncCalStashedRotationHeld];
        // Dual-stash restore: target first, then the (possibly lock-trimmed)
        // effective value the session started with.
        [self syncCalApplyDelayMsDirect:_syncCalStashedTargetMs];
        [self setEffectiveAudioDelayMs:_syncCalStashedEffectiveMs];
        RoonVisLog(@"Sync calibration: cancelled (restored target=%ldms effective=%ldms)",
                   static_cast<long>(_syncCalStashedTargetMs),
                   static_cast<long>(_syncCalStashedEffectiveMs));
    }
}

- (void)clearLivePCMBuffer
{
    std::lock_guard<std::mutex> lock(_livePCMMutex);
    _livePCMBuffer.Clear();
    _lastLivePCMRenderTime = 0;
}

- (void)rebaseLivePCMBufferToDelay
{
    std::lock_guard<std::mutex> lock(_livePCMMutex);
    _livePCMBuffer.RebaseToDelay(_audioDelayFrames);
}

// Render/GL-thread only. Applies a delay target queued by -applySettings so the
// delay ivars are never written off the render thread. Must not hold _livePCMMutex
// when calling -rebaseLivePCMBufferToDelay (that method takes it; std::mutex is
// non-recursive).
- (void)applyPendingAudioDelay
{
    // Calibration owns the delay ivars while active: a settings write (or any
    // notification-triggered applySettings) must not stomp the live draft. The
    // pending value stays queued and is re-examined after calibration ends.
    if (_syncCalibrationActive)
    {
        return;
    }
    NSInteger target;
    {
        std::lock_guard<std::mutex> lock(_livePCMMutex);
        if (!_hasPendingAudioDelay)
        {
            return;
        }
        _hasPendingAudioDelay = NO;
        target = _pendingAudioInputDelayMs;
    }
    _audioInputDelayMs = target;
    _effectiveAudioDelayMs = target;
    _audioDelayFrames = LivePCMDelayFramesForMilliseconds(target);
    [self rebaseLivePCMBufferToDelay];
}

- (void)enqueueLivePCMInt16:(const int16_t *)interleaved frameCount:(NSUInteger)frameCount
{
    if (interleaved == nullptr || frameCount == 0)
    {
        return;
    }

    // Append under the lock; the delay-line ring holds the user-tuned backlog and drops
    // the oldest audio past the ~1.1 s cap (see LivePCMDelayBuffer).
    std::lock_guard<std::mutex> lock(_livePCMMutex);
    _livePCMActive = true;
    _lastLivePCMEnqueueTime = CACurrentMediaTime();
    _livePCMBuffer.Append(interleaved, frameCount);
}

- (BOOL)drainLivePCMInto:(std::vector<int16_t> &)samples
{
    std::lock_guard<std::mutex> lock(_livePCMMutex);
    if (!_livePCMActive)
    {
        return NO;
    }

    // Delay-line: retain the newest configured delay in the buffer and release only the
    // audio older than that to projectM. In steady state this feeds ~one frame's worth
    // per call while holding a constant backlog; after a slow render frame the excess is
    // released as a catch-up burst, keeping the audio->visual offset fixed.
    return _livePCMBuffer.Drain(_audioDelayFrames, samples) ? YES : NO;
}

- (void)feedLivePCM
{
    if (self.projectM == nullptr)
    {
        return;
    }

    if (![self drainLivePCMInto:_livePCMRenderSamples] || _livePCMRenderSamples.empty())
    {
        return;
    }

    // Sync calibration: detect onsets in the exact (pre-sensitivity-scaling)
    // samples projectM is about to render, so the pulse is time-aligned with
    // the visuals at the currently pinned delay.
    if (_syncCalibrationActive)
    {
        if (_onsetDetector.ProcessChunk(_livePCMRenderSamples.data(), _livePCMRenderSamples.size() / 2))
        {
            _syncCalibrationOnsetThisFrame = YES;
        }
    }

    if (_audioSensitivity != 1.0)
    {
        for (int16_t &sample : _livePCMRenderSamples)
        {
            sample = RoonVisScalePCM16Sample(sample, _audioSensitivity);
        }
    }

    static constexpr size_t kChannels = 2;
    unsigned int maxFramesPerCall = std::max(1u, projectm_pcm_get_max_samples());
    size_t totalFrames = _livePCMRenderSamples.size() / kChannels;

    size_t frameOffset = 0;
    while (frameOffset < totalFrames)
    {
        size_t chunkFrames = std::min(totalFrames - frameOffset, static_cast<size_t>(maxFramesPerCall));
        const int16_t *chunk = _livePCMRenderSamples.data() + (frameOffset * kChannels);
        projectm_pcm_add_int16(self.projectM, chunk, static_cast<unsigned int>(chunkFrames), PROJECTM_STEREO);
        frameOffset += chunkFrames;
    }

#if !defined(NDEBUG)
    if ((self.renderedFrames % 120) == 0)
    {
        NSLog(@"ProjectM hardening: live PCM fed %zu frames", totalFrames);
    }
#endif
}

- (void)feedElapsedPCM
{
    if (self.projectM == nullptr || _wav.frameCount() == 0)
    {
        return;
    }

    CFTimeInterval now = CACurrentMediaTime();
    CFTimeInterval elapsed = now - self.lastFeedTime;
    self.lastFeedTime = now;
    if (elapsed <= 0)
    {
        return;
    }

    self.pendingSampleFrames += elapsed * _wav.sampleRate;
    unsigned int maxFramesPerCall = std::max(1u, projectm_pcm_get_max_samples());
    size_t framesToFeed = static_cast<size_t>(self.pendingSampleFrames);
    if (framesToFeed == 0)
    {
        return;
    }
    self.pendingSampleFrames -= framesToFeed;

    size_t fedFrames = 0;
    while (framesToFeed > 0)
    {
        size_t framesUntilLoop = _wav.frameCount() - self.wavFrameOffset;
        size_t chunkFrames = std::min(framesToFeed, framesUntilLoop);
        chunkFrames = std::min(chunkFrames, static_cast<size_t>(maxFramesPerCall));

        const int16_t *chunk = _wav.samples.data() + (self.wavFrameOffset * _wav.channels);
        if (_audioSensitivity != 1.0)
        {
            size_t sampleCount = chunkFrames * _wav.channels;
            _pcmGainBuffer.resize(sampleCount);
            for (size_t sampleIndex = 0; sampleIndex < sampleCount; sampleIndex++)
            {
                _pcmGainBuffer[sampleIndex] = RoonVisScalePCM16Sample(chunk[sampleIndex], _audioSensitivity);
            }
            chunk = _pcmGainBuffer.data();
        }
        projectm_pcm_add_int16(self.projectM, chunk, static_cast<unsigned int>(chunkFrames), PROJECTM_STEREO);

        self.wavFrameOffset += chunkFrames;
        if (self.wavFrameOffset >= _wav.frameCount())
        {
            self.wavFrameOffset = 0;
        }
        framesToFeed -= chunkFrames;
        fedFrames += chunkFrames;
    }

    if (self.renderedFrames == 0 || (self.renderedFrames % 120) == 0)
    {
        NSLog(@"ProjectM Step B fed %zu PCM frames, offset %zu", fedFrames, self.wavFrameOffset);
    }
}

- (BOOL)renderFrame
{
    if (self.projectM == nullptr)
    {
        return NO;
    }

    _syncCalibrationOnsetThisFrame = NO;
    [self applyPendingAudioDelay];

    BOOL livePCMActive = NO;
    CFTimeInterval lastLivePCMEnqueueTime = 0;
    {
        std::lock_guard<std::mutex> lock(_livePCMMutex);
        livePCMActive = _livePCMActive ? YES : NO;
        lastLivePCMEnqueueTime = _lastLivePCMEnqueueTime;
    }

    CFTimeInterval now = CACurrentMediaTime();
    if (livePCMActive && _lastLivePCMRenderTime > 0)
    {
        CFTimeInterval stall = now - _lastLivePCMRenderTime;
        if (stall > kLivePCMMajorStallSeconds)
        {
            [self rebaseLivePCMBufferToDelay];
            RoonVisLog(@"ProjectM hardening: rebased live PCM after %.0fms render stall", stall * 1000.0);
        }
    }
    _lastLivePCMRenderTime = now;
    BOOL livePCMStale = livePCMActive && lastLivePCMEnqueueTime > 0 && (now - lastLivePCMEnqueueTime) > 3.0;
    if (livePCMActive && !livePCMStale)
    {
        if (_livePCMInFallback)
        {
            NSLog(@"ProjectM hardening: live PCM resumed; leaving fallback WAV feed");
            _livePCMInFallback = false;
        }
        [self feedLivePCM];
    }
    else
    {
        if (livePCMStale && !_livePCMInFallback)
        {
            NSLog(@"ProjectM hardening: live PCM stale for %.1fs; using fallback WAV feed", now - lastLivePCMEnqueueTime);
            _livePCMInFallback = true;
            self.lastFeedTime = now;
            self.pendingSampleFrames = 0;
        }
        else if (!livePCMActive)
        {
            _livePCMInFallback = false;
        }
        [self feedElapsedPCM];
    }
    [self schedulePresetPreloadIfReadyAtTime:now];
    projectm_opengl_render_frame(self.projectM);
    self.renderedFrames++;
    return YES;
}

@end

#pragma clang diagnostic pop
