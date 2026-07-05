#import "ProjectMBridgeInternal.h"

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
    NSInteger clamped = MAX((NSInteger)0, MIN(_audioInputDelayMs, effectiveAudioDelayMs));
    if (clamped == _effectiveAudioDelayMs)
    {
        return;
    }
    _effectiveAudioDelayMs = clamped;
    _audioDelayFrames = LivePCMDelayFramesForMilliseconds(clamped);
    [self rebaseLivePCMBufferToDelay];
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
