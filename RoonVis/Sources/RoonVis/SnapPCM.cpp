#include "SnapPCM.h"

#include <algorithm>
#include <cstring>
#include <limits>
#include <random>

namespace RoonVis
{

uint16_t ReadLE16(const uint8_t *data)
{
    return static_cast<uint16_t>(data[0] | (data[1] << 8));
}

uint32_t ReadLE32(const uint8_t *data)
{
    return static_cast<uint32_t>(data[0] | (data[1] << 8) | (data[2] << 16) | (data[3] << 24));
}

size_t WavData::frameCount() const
{
    return channels == 0 ? 0 : samples.size() / channels;
}

bool ParseWaveFormat(const uint8_t *bytes, size_t length, WaveFormat &format)
{
    format = WaveFormat();
    if (bytes == nullptr || length < 12 || std::memcmp(bytes, "RIFF", 4) != 0 ||
        std::memcmp(bytes + 8, "WAVE", 4) != 0)
    {
        return false;
    }

    bool sawFormat = false;
    bool sawData = false;
    size_t offset = 12;
    while (offset + 8 <= length)
    {
        const uint8_t *chunk = bytes + offset;
        uint32_t chunkSize = ReadLE32(chunk + 4);
        size_t chunkDataOffset = offset + 8;
        if (chunkSize > length - chunkDataOffset)
        {
            return false;
        }

        if (!sawFormat && std::memcmp(chunk, "fmt ", 4) == 0)
        {
            if (chunkSize < 16)
            {
                return false;
            }
            const uint8_t *fmt = bytes + chunkDataOffset;
            format.audioFormat = ReadLE16(fmt);
            format.channels = ReadLE16(fmt + 2);
            format.sampleRate = ReadLE32(fmt + 4);
            format.bitsPerSample = ReadLE16(fmt + 14);
            sawFormat = true;
        }
        else if (!sawData && std::memcmp(chunk, "data", 4) == 0)
        {
            format.dataOffset = chunkDataOffset;
            format.dataByteCount = chunkSize;
            sawData = true;
        }

        size_t paddedSize = static_cast<size_t>(chunkSize) + (chunkSize & 1u);
        if (chunkDataOffset > std::numeric_limits<size_t>::max() - paddedSize)
        {
            return false;
        }
        offset = chunkDataOffset + paddedSize;
    }

    return sawFormat && sawData;
}

bool ParsePCM16Wav(const uint8_t *bytes, size_t length, WavData &wav)
{
    wav = WavData();

    WaveFormat format;
    if (!ParseWaveFormat(bytes, length, format))
    {
        return false;
    }

    size_t bytesPerFrame = static_cast<size_t>(format.channels) * sizeof(int16_t);
    if (format.audioFormat != 1 || format.bitsPerSample != 16 || format.channels != 2 ||
        format.sampleRate == 0 || bytesPerFrame == 0 || (format.dataByteCount % bytesPerFrame) != 0)
    {
        return false;
    }

    wav.channels = format.channels;
    wav.sampleRate = format.sampleRate;
    wav.samples.resize(format.dataByteCount / sizeof(int16_t));
    std::memcpy(wav.samples.data(), bytes + format.dataOffset, format.dataByteCount);
    return wav.frameCount() > 0;
}

bool IsSupportedPCM16StereoFormat(const WaveFormat &format)
{
    return format.audioFormat == 1 && format.channels == 2 && format.sampleRate > 0 && format.bitsPerSample == 16;
}

bool ParseBaseHeader(const uint8_t *bytes, size_t length, uint16_t &type, uint32_t &bodySize)
{
    if (bytes == nullptr || length < kSnapcastBaseHeaderSize)
    {
        return false;
    }

    type = ReadLE16(bytes);
    bodySize = ReadLE32(bytes + 22);
    return true;
}

PendingBytesResult DecidePendingBytes(const uint8_t *bytes, size_t length)
{
    PendingBytesResult result;
    if (length < kSnapcastBaseHeaderSize)
    {
        return result;
    }

    if (!ParseBaseHeader(bytes, length, result.type, result.bodySize))
    {
        return result;
    }

    if (result.bodySize > kMaxSnapcastBodySize)
    {
        result.decision = PendingBytesDecision::InvalidSize;
        return result;
    }

    result.messageSize = kSnapcastBaseHeaderSize + static_cast<size_t>(result.bodySize);
    result.decision = length < result.messageSize ? PendingBytesDecision::NeedMore : PendingBytesDecision::Dispatch;
    return result;
}

WireChunkResult ParseWireChunkPCM16Stereo(const uint8_t *body, size_t size, WireChunkPCM &chunk)
{
    chunk = WireChunkPCM();
    if (body == nullptr || size < 12)
    {
        return WireChunkResult::Malformed;
    }

    uint32_t payloadLength = ReadLE32(body + 8);
    if (payloadLength > size - 12)
    {
        return WireChunkResult::Malformed;
    }

    if (payloadLength == 0)
    {
        return WireChunkResult::NoSamples;
    }

    if ((payloadLength % (2u * sizeof(int16_t))) != 0)
    {
        return WireChunkResult::Malformed;
    }

    chunk.payload = body + 12;
    chunk.frames = payloadLength / (2u * sizeof(int16_t));
    return chunk.frames == 0 ? WireChunkResult::NoSamples : WireChunkResult::Enqueue;
}

void AppendCapInterleaved(std::vector<int16_t> &buffer,
                          const int16_t *interleaved,
                          size_t frames,
                          size_t maxFrames,
                          size_t channels)
{
    if (interleaved == nullptr || frames == 0 || maxFrames == 0 || channels == 0)
    {
        return;
    }

    size_t incomingSamples = frames * channels;
    size_t maxSamples = maxFrames * channels;
    if (incomingSamples >= maxSamples)
    {
        buffer.assign(interleaved + (incomingSamples - maxSamples), interleaved + incomingSamples);
        return;
    }

    buffer.insert(buffer.end(), interleaved, interleaved + incomingSamples);
    if (buffer.size() > maxSamples)
    {
        size_t dropSamples = buffer.size() - maxSamples;
        dropSamples -= dropSamples % channels;
        buffer.erase(buffer.begin(), buffer.begin() + dropSamples);
    }
}

int NextReconnectDelay(int current)
{
    if (current <= 1)
    {
        return 2;
    }
    if (current <= 2)
    {
        return 4;
    }
    if (current <= 4)
    {
        return 8;
    }
    if (current <= 8)
    {
        return 10;
    }
    return 10;
}

std::vector<size_t> ShuffledOrder(const std::vector<size_t> &input, uint32_t seed)
{
    std::vector<size_t> out = input;
    std::mt19937 rng(seed);
    std::shuffle(out.begin(), out.end(), rng);
    return out;
}

LivePCMDelayBuffer::LivePCMDelayBuffer(size_t maxFrames, size_t channels)
    : maxFrames_(maxFrames), channels_(channels)
{
}

size_t LivePCMDelayBuffer::BufferedSamples() const
{
    return samples_.size() - std::min(readOffset_, samples_.size());
}

size_t LivePCMDelayBuffer::BufferedFrames() const
{
    return channels_ == 0 ? 0 : BufferedSamples() / channels_;
}

void LivePCMDelayBuffer::Clear()
{
    samples_.clear();
    readOffset_ = 0;
}

void LivePCMDelayBuffer::Append(const int16_t *interleaved, size_t frames)
{
    if (interleaved == nullptr || frames == 0 || channels_ == 0 || maxFrames_ == 0)
    {
        return;
    }
    samples_.insert(samples_.end(), interleaved, interleaved + (frames * channels_));

    const size_t maxSamples = maxFrames_ * channels_;
    const size_t bufferedSamples = BufferedSamples();
    if (bufferedSamples > maxSamples)
    {
        size_t dropSamples = bufferedSamples - maxSamples;
        dropSamples -= dropSamples % channels_;
        readOffset_ += dropSamples;
    }
    if (readOffset_ >= maxSamples)
    {
        samples_.erase(samples_.begin(), samples_.begin() + readOffset_);
        readOffset_ = 0;
    }
}

bool LivePCMDelayBuffer::Drain(size_t delayFrames, std::vector<int16_t> &out)
{
    if (channels_ == 0)
    {
        out.clear();
        return false;
    }
    const size_t delaySamples = delayFrames * channels_;
    const size_t bufferSamples = BufferedSamples();
    if (bufferSamples <= delaySamples)
    {
        out.clear();
        return false;  // still filling the delay buffer; nothing due yet
    }

    const size_t feedSamples = bufferSamples - delaySamples;  // older-than-delay audio
    auto feedBegin = samples_.begin() + readOffset_;
    out.assign(feedBegin, feedBegin + feedSamples);
    readOffset_ += feedSamples;
    if (readOffset_ >= maxFrames_ * channels_)
    {
        samples_.erase(samples_.begin(), samples_.begin() + readOffset_);
        readOffset_ = 0;
    }
    return true;
}

void LivePCMDelayBuffer::RebaseToDelay(size_t delayFrames)
{
    size_t readOffset = std::min(readOffset_, samples_.size());
    const size_t bufferedSamples = samples_.size() - readOffset;
    const size_t delaySamples = delayFrames * channels_;
    if (bufferedSamples > delaySamples)
    {
        readOffset += bufferedSamples - delaySamples;
    }
    if (readOffset > 0)
    {
        samples_.erase(samples_.begin(), samples_.begin() + readOffset);
        readOffset_ = 0;
    }
}

}  // namespace RoonVis
