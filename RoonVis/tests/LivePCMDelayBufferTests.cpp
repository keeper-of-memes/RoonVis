#include "TestHarness.h"

#include "SnapPCM.h"

#include <cstdint>
#include <vector>

using namespace RoonVis;

namespace
{

// Build `frames` stereo frames of sequential samples starting at `startSample`, so each
// int16 is uniquely identifiable ([startSample, startSample+frames*2)).
std::vector<int16_t> MakeFrames(size_t frames, int startSample = 0)
{
    std::vector<int16_t> v;
    v.reserve(frames * 2);
    for (size_t i = 0; i < frames * 2; ++i)
    {
        v.push_back(static_cast<int16_t>(startSample + static_cast<int>(i)));
    }
    return v;
}

void AppendFrames(LivePCMDelayBuffer &buf, const std::vector<int16_t> &samples)
{
    buf.Append(samples.data(), samples.size() / 2);
}

void TestAppendDrainDelayLine()
{
    LivePCMDelayBuffer buf(/*maxFrames=*/100, /*channels=*/2);
    AppendFrames(buf, MakeFrames(8));  // samples [0..15]
    CHECK(buf.BufferedFrames() == 8);

    std::vector<int16_t> out;
    // delay 3 frames (6 samples): release the 10 oldest samples, retain the newest 6.
    CHECK(buf.Drain(3, out) == true);
    CHECK(out.size() == 10);
    CHECK(out.front() == 0);
    CHECK(out.back() == 9);
    CHECK(buf.BufferedFrames() == 3);  // delay backlog retained
}

void TestDrainWhileFillingBacklog()
{
    LivePCMDelayBuffer buf(100, 2);
    AppendFrames(buf, MakeFrames(2));  // 4 samples, below the 3-frame delay
    std::vector<int16_t> out;
    CHECK(buf.Drain(3, out) == false);  // nothing due yet
    CHECK(out.empty());
    CHECK(buf.BufferedFrames() == 2);
}

void TestSteadyStateConstantBacklog()
{
    LivePCMDelayBuffer buf(100, 2);
    std::vector<int16_t> out;
    for (int cycle = 0; cycle < 5; ++cycle)
    {
        AppendFrames(buf, MakeFrames(5, cycle * 10));
        buf.Drain(3, out);
        // After each drain the retained backlog is exactly the delay (3 frames).
        CHECK(buf.BufferedFrames() == 3);
    }
    // Steady-state drain feeds one append's worth (5 frames = 10 samples).
    CHECK(out.size() == 10);
}

void TestCapDropsOldest()
{
    LivePCMDelayBuffer buf(/*maxFrames=*/10, /*channels=*/2);  // cap 20 samples
    AppendFrames(buf, MakeFrames(15));  // 30 samples [0..29]; 10 oldest frames dropped
    CHECK(buf.BufferedFrames() == 10);

    std::vector<int16_t> out;
    CHECK(buf.Drain(0, out) == true);
    CHECK(out.size() == 20);
    CHECK(out.front() == 10);  // oldest surviving = frame 5, sample 10
    CHECK(out.back() == 29);   // newest
}

void TestCapAcrossManyAppends()
{
    LivePCMDelayBuffer buf(10, 2);  // cap 10 frames
    for (int i = 0; i < 50; ++i)
    {
        AppendFrames(buf, MakeFrames(4, i * 8));
    }
    CHECK(buf.BufferedFrames() <= 10);  // never exceeds the cap
    CHECK(buf.BufferedFrames() > 0);
}

void TestRebaseToDelay()
{
    LivePCMDelayBuffer buf(100, 2);
    AppendFrames(buf, MakeFrames(20));  // samples [0..39]
    buf.RebaseToDelay(5);               // trim backlog to newest 5 frames
    CHECK(buf.BufferedFrames() == 5);

    std::vector<int16_t> out;
    CHECK(buf.Drain(0, out) == true);
    CHECK(out.size() == 10);
    CHECK(out.front() == 30);  // newest 5 frames = samples [30..39]
    CHECK(out.back() == 39);
}

void TestRebaseNoOpWhenBelowDelay()
{
    LivePCMDelayBuffer buf(100, 2);
    AppendFrames(buf, MakeFrames(3));
    buf.RebaseToDelay(10);  // buffered (3) < delay (10): nothing to trim
    CHECK(buf.BufferedFrames() == 3);
}

void TestRebaseAfterPartialDrain()
{
    LivePCMDelayBuffer buf(100, 2);
    AppendFrames(buf, MakeFrames(12));  // [0..23]
    std::vector<int16_t> out;
    buf.Drain(8, out);                  // release 4 oldest frames, retain 8
    CHECK(buf.BufferedFrames() == 8);
    buf.RebaseToDelay(2);               // trim retained backlog to 2 frames
    CHECK(buf.BufferedFrames() == 2);
    buf.Drain(0, out);
    CHECK(out.size() == 4);
    CHECK(out.back() == 23);            // newest sample preserved
}

void TestClear()
{
    LivePCMDelayBuffer buf(100, 2);
    AppendFrames(buf, MakeFrames(10));
    buf.Clear();
    CHECK(buf.BufferedFrames() == 0);
    std::vector<int16_t> out;
    CHECK(buf.Drain(0, out) == false);
}

void TestDefaultConstructedInert()
{
    LivePCMDelayBuffer buf;  // unconfigured: maxFrames_/channels_ == 0
    auto data = MakeFrames(5);
    buf.Append(data.data(), 5);
    CHECK(buf.BufferedFrames() == 0);  // Append no-op
    std::vector<int16_t> out;
    CHECK(buf.Drain(0, out) == false);
}

void TestEdgeCases()
{
    LivePCMDelayBuffer buf(100, 2);
    buf.Append(nullptr, 5);  // null pointer: no-op
    CHECK(buf.BufferedFrames() == 0);
    auto data = MakeFrames(5);
    buf.Append(data.data(), 0);  // zero frames: no-op
    CHECK(buf.BufferedFrames() == 0);
}

// B8: the delay math must honor the real ceiling (audio delay 0..500 + sync-render
// compensation 0..200 = 700ms), not the historical bare MIN(500, ...) that silently
// truncated 501..700 while the reported effective delay was larger.
void TestDelayFramesHonorsFullCeiling()
{
    constexpr uint32_t kSampleRate = 44100;
    constexpr int64_t kClampMs = 700;             // 500 + 200
    constexpr size_t kMaxBufferFrames = (kSampleRate * 1100) / 1000;  // ~1.1 s, 48510

    // 550ms is above the old 500 truncation point: must NOT truncate to 500ms worth.
    CHECK(LivePCMDelayFramesForMs(550, kClampMs, kSampleRate, kMaxBufferFrames)
          == (static_cast<size_t>(550) * kSampleRate) / 1000);  // 24255, not 22050
    CHECK(LivePCMDelayFramesForMs(550, kClampMs, kSampleRate, kMaxBufferFrames) != 22050);

    // 700ms = the ceiling itself: full backlog, un-truncated.
    CHECK(LivePCMDelayFramesForMs(700, kClampMs, kSampleRate, kMaxBufferFrames)
          == (static_cast<size_t>(700) * kSampleRate) / 1000);  // 30870

    // Above the clamp: truncated AT the clamp (700ms), not silently past it.
    CHECK(LivePCMDelayFramesForMs(900, kClampMs, kSampleRate, kMaxBufferFrames)
          == (static_cast<size_t>(700) * kSampleRate) / 1000);  // 30870

    // Negative clamps to 0.
    CHECK(LivePCMDelayFramesForMs(-10, kClampMs, kSampleRate, kMaxBufferFrames) == 0);

    // Frames always stay strictly below the buffer cap, even at absurd requests.
    CHECK(LivePCMDelayFramesForMs(550, kClampMs, kSampleRate, kMaxBufferFrames) < kMaxBufferFrames);
    CHECK(LivePCMDelayFramesForMs(700, kClampMs, kSampleRate, kMaxBufferFrames) < kMaxBufferFrames);
    CHECK(LivePCMDelayFramesForMs(1000000, kClampMs, kSampleRate, kMaxBufferFrames) < kMaxBufferFrames);
    // With a clamp large enough to exceed the buffer, the cap (maxBufferFrames-1) binds.
    CHECK(LivePCMDelayFramesForMs(5000, 5000, kSampleRate, kMaxBufferFrames) == kMaxBufferFrames - 1);
}

}  // namespace

void RunLivePCMDelayBufferTests()
{
    TestAppendDrainDelayLine();
    TestDrainWhileFillingBacklog();
    TestSteadyStateConstantBacklog();
    TestCapDropsOldest();
    TestCapAcrossManyAppends();
    TestRebaseToDelay();
    TestRebaseNoOpWhenBelowDelay();
    TestRebaseAfterPartialDrain();
    TestClear();
    TestDefaultConstructedInert();
    TestEdgeCases();
    TestDelayFramesHonorsFullCeiling();
}
