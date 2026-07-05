#pragma once

#include <cstddef>
#include <cstdint>
#include <vector>

namespace RoonVis
{

constexpr size_t kSnapcastBaseHeaderSize = 26;
constexpr uint32_t kMaxSnapcastBodySize = 16u * 1024u * 1024u;

uint16_t ReadLE16(const uint8_t *data);
uint32_t ReadLE32(const uint8_t *data);

struct WaveFormat
{
    uint16_t audioFormat = 0;
    uint16_t channels = 0;
    uint32_t sampleRate = 0;
    uint16_t bitsPerSample = 0;
    size_t dataOffset = 0;
    uint32_t dataByteCount = 0;
};

struct WavData
{
    std::vector<int16_t> samples;
    uint32_t sampleRate = 0;
    uint16_t channels = 0;

    size_t frameCount() const;
};

// RIFF/WAVE duplicate policy: the first valid "fmt " chunk and the first "data"
// chunk win. Later duplicate chunks are ignored so malformed appendages cannot
// silently replace already-parsed audio metadata or PCM payloads.
bool ParseWaveFormat(const uint8_t *bytes, size_t length, WaveFormat &format);
bool ParsePCM16Wav(const uint8_t *bytes, size_t length, WavData &wav);
bool IsSupportedPCM16StereoFormat(const WaveFormat &format);

bool ParseBaseHeader(const uint8_t *bytes, size_t length, uint16_t &type, uint32_t &bodySize);

enum class PendingBytesDecision
{
    NeedMore,
    Dispatch,
    InvalidSize,
};

struct PendingBytesResult
{
    PendingBytesDecision decision = PendingBytesDecision::NeedMore;
    uint16_t type = 0;
    uint32_t bodySize = 0;
    size_t messageSize = 0;
};

PendingBytesResult DecidePendingBytes(const uint8_t *bytes, size_t length);

enum class WireChunkResult
{
    Enqueue,
    NoSamples,
    Malformed,
};

struct WireChunkPCM
{
    const uint8_t *payload = nullptr;
    size_t frames = 0;
};

WireChunkResult ParseWireChunkPCM16Stereo(const uint8_t *body, size_t size, WireChunkPCM &chunk);

void AppendCapInterleaved(std::vector<int16_t> &buffer,
                          const int16_t *interleaved,
                          size_t frames,
                          size_t maxFrames,
                          size_t channels);

int NextReconnectDelay(int current);

// Deterministic shuffle of `input` seeded by `seed` (same seed => same order; the
// returned vector is a permutation of `input`). Used for preset Shuffle rotation, which
// is reseeded each time the user selects Shuffle so the order is fresh.
std::vector<size_t> ShuffledOrder(const std::vector<size_t> &input, uint32_t seed);

// Interleaved int16 delay-line ring for the live-PCM path. The producer (Snapcast
// serial queue) Appends; the render/GL thread Drains audio older than the configured
// delay, holding a constant backlog so the audio->visual offset stays fixed. Oldest
// audio is dropped once the buffer exceeds the cap.
//
// NOT thread-safe by itself: the ObjC bridge (ProjectMBridge) guards every call with
// its _livePCMMutex — that is the threading invariant, kept in the wrapper. All public
// sizes are in FRAMES; the class multiplies by `channels` internally. Default-
// constructed instances are inert (Append/Drain no-op) until assigned a configured one.
class LivePCMDelayBuffer
{
public:
    LivePCMDelayBuffer() = default;
    LivePCMDelayBuffer(size_t maxFrames, size_t channels);

    // Append `frames` interleaved samples, dropping the oldest audio past the cap.
    void Append(const int16_t *interleaved, size_t frames);

    // Release audio older than `delayFrames` into `out`. Returns true with `out` filled
    // when audio is due; returns false with `out` cleared while still filling the delay
    // backlog.
    bool Drain(size_t delayFrames, std::vector<int16_t> &out);

    // Trim the held backlog down to at most `delayFrames` (used after a render stall).
    void RebaseToDelay(size_t delayFrames);

    void Clear();

    // Audio currently held (appended but not yet drained), in frames.
    size_t BufferedFrames() const;

private:
    size_t BufferedSamples() const;

    std::vector<int16_t> samples_;
    size_t readOffset_ = 0;
    size_t maxFrames_ = 0;
    size_t channels_ = 0;
};

}  // namespace RoonVis
