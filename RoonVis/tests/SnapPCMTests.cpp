#include "TestHarness.h"

#include "SnapPCM.h"

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <initializer_list>
#include <string>
#include <utility>
#include <vector>

using namespace RoonVis;

void RunPresetShelfModelTests();
void RunPresetBlocklistTests();
void RunLivePCMDelayBufferTests();
void RunPresetRotationSchedulerTests();
void RunPresetWarmCacheTests();
void RunLearnedSlowPresetStoreTests();
void RunPreprocessCacheTests();

namespace
{

void AppendLE16(std::vector<uint8_t> &bytes, uint16_t value)
{
    bytes.push_back(static_cast<uint8_t>(value & 0xff));
    bytes.push_back(static_cast<uint8_t>((value >> 8) & 0xff));
}

void AppendLE32(std::vector<uint8_t> &bytes, uint32_t value)
{
    bytes.push_back(static_cast<uint8_t>(value & 0xff));
    bytes.push_back(static_cast<uint8_t>((value >> 8) & 0xff));
    bytes.push_back(static_cast<uint8_t>((value >> 16) & 0xff));
    bytes.push_back(static_cast<uint8_t>((value >> 24) & 0xff));
}

void AppendChunk(std::vector<uint8_t> &bytes, const char id[4], const std::vector<uint8_t> &payload)
{
    bytes.insert(bytes.end(), id, id + 4);
    AppendLE32(bytes, static_cast<uint32_t>(payload.size()));
    bytes.insert(bytes.end(), payload.begin(), payload.end());
    if ((payload.size() & 1u) != 0)
    {
        bytes.push_back(0);
    }
}

std::vector<uint8_t> FmtChunk(uint16_t audioFormat, uint16_t channels, uint32_t sampleRate, uint16_t bits)
{
    std::vector<uint8_t> fmt;
    AppendLE16(fmt, audioFormat);
    AppendLE16(fmt, channels);
    AppendLE32(fmt, sampleRate);
    uint32_t byteRate = sampleRate * channels * bits / 8;
    uint16_t blockAlign = static_cast<uint16_t>(channels * bits / 8);
    AppendLE32(fmt, byteRate);
    AppendLE16(fmt, blockAlign);
    AppendLE16(fmt, bits);
    return fmt;
}

std::vector<uint8_t> PCMBytes(std::initializer_list<int16_t> samples)
{
    std::vector<uint8_t> bytes;
    for (int16_t sample : samples)
    {
        AppendLE16(bytes, static_cast<uint16_t>(sample));
    }
    return bytes;
}

std::vector<uint8_t> WavFromChunks(const std::vector<std::pair<std::string, std::vector<uint8_t>>> &chunks)
{
    std::vector<uint8_t> wav;
    wav.insert(wav.end(), {'R', 'I', 'F', 'F'});
    AppendLE32(wav, 0);
    wav.insert(wav.end(), {'W', 'A', 'V', 'E'});
    for (const auto &chunk : chunks)
    {
        AppendChunk(wav, chunk.first.c_str(), chunk.second);
    }
    return wav;
}

std::vector<uint8_t> ValidWav()
{
    return WavFromChunks({
        {"fmt ", FmtChunk(1, 2, 48000, 16)},
        {"data", PCMBytes({1, 2, 3, 4})},
    });
}

std::vector<uint8_t> Message(uint16_t type, uint32_t bodySize)
{
    std::vector<uint8_t> message(kSnapcastBaseHeaderSize, 0);
    message[0] = static_cast<uint8_t>(type & 0xff);
    message[1] = static_cast<uint8_t>((type >> 8) & 0xff);
    message[22] = static_cast<uint8_t>(bodySize & 0xff);
    message[23] = static_cast<uint8_t>((bodySize >> 8) & 0xff);
    message[24] = static_cast<uint8_t>((bodySize >> 16) & 0xff);
    message[25] = static_cast<uint8_t>((bodySize >> 24) & 0xff);
    for (uint32_t i = 0; i < bodySize; ++i)
    {
        message.push_back(static_cast<uint8_t>(i));
    }
    return message;
}

std::vector<uint8_t> Header(uint16_t type, uint32_t bodySize)
{
    std::vector<uint8_t> header = Message(type, 0);
    header.resize(kSnapcastBaseHeaderSize);
    header[22] = static_cast<uint8_t>(bodySize & 0xff);
    header[23] = static_cast<uint8_t>((bodySize >> 8) & 0xff);
    header[24] = static_cast<uint8_t>((bodySize >> 16) & 0xff);
    header[25] = static_cast<uint8_t>((bodySize >> 24) & 0xff);
    return header;
}

int DrainDispatches(std::vector<uint8_t> &pending)
{
    int dispatches = 0;
    while (true)
    {
        PendingBytesResult result = DecidePendingBytes(pending.data(), pending.size());
        if (result.decision != PendingBytesDecision::Dispatch)
        {
            break;
        }
        ++dispatches;
        pending.erase(pending.begin(), pending.begin() + result.messageSize);
    }
    return dispatches;
}

std::vector<uint8_t> WireChunk(uint32_t payloadLength, size_t actualPayloadBytes)
{
    std::vector<uint8_t> body(12, 0);
    body[8] = static_cast<uint8_t>(payloadLength & 0xff);
    body[9] = static_cast<uint8_t>((payloadLength >> 8) & 0xff);
    body[10] = static_cast<uint8_t>((payloadLength >> 16) & 0xff);
    body[11] = static_cast<uint8_t>((payloadLength >> 24) & 0xff);
    for (size_t i = 0; i < actualPayloadBytes; ++i)
    {
        body.push_back(static_cast<uint8_t>(i + 1));
    }
    return body;
}

void TestReadLE()
{
    uint8_t bytes[] = {0x34, 0x12, 0xef, 0xcd};
    CHECK(ReadLE16(bytes) == 0x1234);
    CHECK(ReadLE32(bytes) == 0xcdef1234u);
}

void TestBaseHeaderFraming()
{
    std::vector<uint8_t> message = Message(2, 3);
    for (size_t split = 0; split <= message.size(); ++split)
    {
        std::vector<uint8_t> pending;
        pending.insert(pending.end(), message.begin(), message.begin() + split);
        int dispatches = DrainDispatches(pending);
        CHECK(dispatches == (split == message.size() ? 1 : 0));
        pending.insert(pending.end(), message.begin() + split, message.end());
        dispatches += DrainDispatches(pending);
        CHECK(dispatches == 1);
        CHECK(pending.empty());
    }

    std::vector<uint8_t> coalesced = Message(1, 1);
    std::vector<uint8_t> second = Message(2, 2);
    coalesced.insert(coalesced.end(), second.begin(), second.end());
    CHECK(DrainDispatches(coalesced) == 2);
    CHECK(coalesced.empty());

    std::vector<uint8_t> truncated = Message(1, 1);
    std::vector<uint8_t> partial = Message(2, 4);
    partial.pop_back();
    truncated.insert(truncated.end(), partial.begin(), partial.end());
    CHECK(DrainDispatches(truncated) == 1);
    CHECK(truncated.size() == partial.size());

    std::vector<uint8_t> maxHeader = Message(9, 0);
    maxHeader.resize(kSnapcastBaseHeaderSize);
    maxHeader[22] = 0;
    maxHeader[23] = 0;
    maxHeader[24] = 0;
    maxHeader[25] = 1;
    CHECK(DecidePendingBytes(maxHeader.data(), maxHeader.size()).decision == PendingBytesDecision::NeedMore);
    maxHeader[22] = 1;
    CHECK(DecidePendingBytes(maxHeader.data(), maxHeader.size()).decision == PendingBytesDecision::InvalidSize);
}

void TestBaseHeaderMalformedAndBoundaryCases()
{
    uint16_t type = 99;
    uint32_t bodySize = 99;
    CHECK(!ParseBaseHeader(nullptr, kSnapcastBaseHeaderSize, type, bodySize));
    CHECK(!ParseBaseHeader(Header(1, 0).data(), kSnapcastBaseHeaderSize - 1, type, bodySize));

    std::vector<uint8_t> header = Header(0x1234, 0x01020304);
    REQUIRE(ParseBaseHeader(header.data(), header.size(), type, bodySize));
    CHECK(type == 0x1234);
    CHECK(bodySize == 0x01020304u);

    CHECK(DecidePendingBytes(nullptr, kSnapcastBaseHeaderSize).decision == PendingBytesDecision::NeedMore);

    std::vector<uint8_t> zeroBody = Header(7, 0);
    PendingBytesResult pending = DecidePendingBytes(zeroBody.data(), zeroBody.size());
    CHECK(pending.decision == PendingBytesDecision::Dispatch);
    CHECK(pending.type == 7);
    CHECK(pending.bodySize == 0);
    CHECK(pending.messageSize == kSnapcastBaseHeaderSize);

    std::vector<uint8_t> maxBody = Header(8, kMaxSnapcastBodySize);
    CHECK(DecidePendingBytes(maxBody.data(), maxBody.size()).decision == PendingBytesDecision::NeedMore);
    maxBody.resize(kSnapcastBaseHeaderSize + static_cast<size_t>(kMaxSnapcastBodySize), 0xaa);
    pending = DecidePendingBytes(maxBody.data(), maxBody.size());
    CHECK(pending.decision == PendingBytesDecision::Dispatch);
    CHECK(pending.messageSize == maxBody.size());

    std::vector<uint8_t> tooLarge = Header(9, kMaxSnapcastBodySize + 1u);
    pending = DecidePendingBytes(tooLarge.data(), tooLarge.size());
    CHECK(pending.decision == PendingBytesDecision::InvalidSize);
    CHECK(pending.bodySize == kMaxSnapcastBodySize + 1u);
    CHECK(pending.messageSize == 0);
}

void TestFragmentedCoalescedSnapcastMessages()
{
    std::vector<uint8_t> stream;
    std::vector<uint8_t> first = Message(1, 0);
    std::vector<uint8_t> second = Message(2, 5);
    std::vector<uint8_t> third = Message(3, 1);
    stream.insert(stream.end(), first.begin(), first.end());
    stream.insert(stream.end(), second.begin(), second.end());
    stream.insert(stream.end(), third.begin(), third.end());

    std::vector<uint8_t> pending;
    int dispatches = 0;
    for (uint8_t byte : stream)
    {
        pending.push_back(byte);
        dispatches += DrainDispatches(pending);
        CHECK(pending.size() < kSnapcastBaseHeaderSize || dispatches < 3);
    }
    CHECK(dispatches == 3);
    CHECK(pending.empty());

    std::vector<uint8_t> invalidAfterValid = Message(4, 2);
    std::vector<uint8_t> invalid = Header(5, kMaxSnapcastBodySize + 1u);
    invalidAfterValid.insert(invalidAfterValid.end(), invalid.begin(), invalid.end());
    CHECK(DrainDispatches(invalidAfterValid) == 1);
    PendingBytesResult result = DecidePendingBytes(invalidAfterValid.data(), invalidAfterValid.size());
    CHECK(result.decision == PendingBytesDecision::InvalidSize);
    CHECK(invalidAfterValid.size() == kSnapcastBaseHeaderSize);
}

void TestWavParser()
{
    WavData wav;
    std::vector<uint8_t> bytes = ValidWav();
    REQUIRE(ParsePCM16Wav(bytes.data(), bytes.size(), wav));
    CHECK(wav.sampleRate == 48000);
    CHECK(wav.channels == 2);
    CHECK(wav.frameCount() == 2);
    CHECK(wav.samples[0] == 1);
    CHECK(wav.samples[3] == 4);

    bytes = WavFromChunks({{"fmt ", FmtChunk(3, 2, 48000, 16)}, {"data", PCMBytes({1, 2, 3, 4})}});
    CHECK(!ParsePCM16Wav(bytes.data(), bytes.size(), wav));
    bytes = WavFromChunks({{"fmt ", FmtChunk(1, 2, 48000, 8)}, {"data", {1, 2, 3, 4}}});
    CHECK(!ParsePCM16Wav(bytes.data(), bytes.size(), wav));
    bytes = WavFromChunks({{"fmt ", FmtChunk(1, 2, 48000, 24)}, {"data", {1, 2, 3, 4, 5, 6}}});
    CHECK(!ParsePCM16Wav(bytes.data(), bytes.size(), wav));
    bytes = WavFromChunks({{"fmt ", FmtChunk(1, 1, 48000, 16)}, {"data", PCMBytes({1, 2})}});
    CHECK(!ParsePCM16Wav(bytes.data(), bytes.size(), wav));
    bytes = WavFromChunks({{"fmt ", FmtChunk(1, 2, 0, 16)}, {"data", PCMBytes({1, 2, 3, 4})}});
    CHECK(!ParsePCM16Wav(bytes.data(), bytes.size(), wav));
    bytes = WavFromChunks({{"fmt ", FmtChunk(1, 2, 48000, 16)}, {"data", {1, 2, 3}}});
    CHECK(!ParsePCM16Wav(bytes.data(), bytes.size(), wav));
    bytes = WavFromChunks({{"fmt ", FmtChunk(1, 2, 48000, 16)}, {"data", {1, 2, 3, 4, 5, 6}}});
    CHECK(!ParsePCM16Wav(bytes.data(), bytes.size(), wav));

    bytes = WavFromChunks({
        {"fmt ", FmtChunk(1, 2, 44100, 16)},
        {"data", PCMBytes({10, 11, 12, 13})},
        {"fmt ", FmtChunk(1, 1, 0, 8)},
        {"data", PCMBytes({90, 91, 92, 93})},
    });
    REQUIRE(ParsePCM16Wav(bytes.data(), bytes.size(), wav));
    CHECK(wav.sampleRate == 44100);
    CHECK(wav.channels == 2);
    CHECK(wav.samples[0] == 10);
    CHECK(wav.samples[3] == 13);

    bytes = WavFromChunks({{"data", PCMBytes({1, 2, 3, 4})}, {"fmt ", FmtChunk(1, 2, 48000, 16)}});
    CHECK(ParsePCM16Wav(bytes.data(), bytes.size(), wav));
    bytes = WavFromChunks({{"fmt ", FmtChunk(1, 2, 48000, 16)}});
    CHECK(!ParsePCM16Wav(bytes.data(), bytes.size(), wav));
    bytes = WavFromChunks({{"data", PCMBytes({1, 2, 3, 4})}});
    CHECK(!ParsePCM16Wav(bytes.data(), bytes.size(), wav));

    bytes = {'R', 'I', 'F', 'F', 0, 0, 0, 0, 'W', 'A', 'V', 'E', 'J', 'U', 'N', 'K'};
    AppendLE32(bytes, 0xffffffffu);
    CHECK(!ParsePCM16Wav(bytes.data(), bytes.size(), wav));
    bytes = WavFromChunks({{"fmt ", FmtChunk(1, 2, 48000, 16)}, {"JUNK", {1}}, {"data", PCMBytes({1, 2, 3, 4})}});
    CHECK(ParsePCM16Wav(bytes.data(), bytes.size(), wav));
}

void TestSupportedPCM16StereoFormat()
{
    WaveFormat format;
    format.audioFormat = 1;
    format.channels = 2;
    format.sampleRate = 48000;
    format.bitsPerSample = 16;
    CHECK(IsSupportedPCM16StereoFormat(format));

    format.audioFormat = 3;
    CHECK(!IsSupportedPCM16StereoFormat(format));
    format.audioFormat = 1;
    format.channels = 1;
    CHECK(!IsSupportedPCM16StereoFormat(format));
    format.channels = 2;
    format.sampleRate = 0;
    CHECK(!IsSupportedPCM16StereoFormat(format));
    format.sampleRate = 48000;
    format.bitsPerSample = 24;
    CHECK(!IsSupportedPCM16StereoFormat(format));
}

void TestWireChunk()
{
    WireChunkPCM chunk;
    std::vector<uint8_t> body = WireChunk(8, 8);
    CHECK(ParseWireChunkPCM16Stereo(body.data(), body.size(), chunk) == WireChunkResult::Enqueue);
    CHECK(chunk.frames == 2);
    CHECK(chunk.payload == body.data() + 12);

    body = WireChunk(4, 8);
    CHECK(ParseWireChunkPCM16Stereo(body.data(), body.size(), chunk) == WireChunkResult::Enqueue);
    CHECK(chunk.frames == 1);
    body = WireChunk(9, 8);
    CHECK(ParseWireChunkPCM16Stereo(body.data(), body.size(), chunk) == WireChunkResult::Malformed);
    body = WireChunk(5, 5);
    CHECK(ParseWireChunkPCM16Stereo(body.data(), body.size(), chunk) == WireChunkResult::Malformed);
    body = WireChunk(0, 0);
    CHECK(ParseWireChunkPCM16Stereo(body.data(), body.size(), chunk) == WireChunkResult::NoSamples);
    body = WireChunk(2, 2);
    CHECK(ParseWireChunkPCM16Stereo(body.data(), body.size(), chunk) == WireChunkResult::Malformed);
    body = WireChunk(0, 4);
    CHECK(ParseWireChunkPCM16Stereo(body.data(), body.size(), chunk) == WireChunkResult::NoSamples);
    body = WireChunk(4, 3);
    CHECK(ParseWireChunkPCM16Stereo(body.data(), body.size(), chunk) == WireChunkResult::Malformed);
    body.resize(11);
    CHECK(ParseWireChunkPCM16Stereo(body.data(), body.size(), chunk) == WireChunkResult::Malformed);
    CHECK(ParseWireChunkPCM16Stereo(nullptr, 12, chunk) == WireChunkResult::Malformed);
}

void TestRingBuffer()
{
    std::vector<int16_t> buffer;
    int16_t a[] = {1, 2, 3, 4};
    AppendCapInterleaved(buffer, a, 2, 4, 2);
    CHECK(buffer.size() == 4);
    int16_t b[] = {5, 6, 7, 8};
    AppendCapInterleaved(buffer, b, 2, 4, 2);
    CHECK((buffer == std::vector<int16_t>{1, 2, 3, 4, 5, 6, 7, 8}));
    int16_t c[] = {9, 10};
    AppendCapInterleaved(buffer, c, 1, 4, 2);
    CHECK((buffer == std::vector<int16_t>{3, 4, 5, 6, 7, 8, 9, 10}));

    int16_t ramp[] = {0, 100, 1, 101, 2, 102, 3, 103, 4, 104, 5, 105};
    AppendCapInterleaved(buffer, ramp, 6, 4, 2);
    CHECK((buffer == std::vector<int16_t>{2, 102, 3, 103, 4, 104, 5, 105}));
    CHECK((buffer.size() % 2) == 0);
    AppendCapInterleaved(buffer, nullptr, 2, 4, 2);
    CHECK((buffer == std::vector<int16_t>{2, 102, 3, 103, 4, 104, 5, 105}));
    AppendCapInterleaved(buffer, ramp, 0, 4, 2);
    CHECK((buffer == std::vector<int16_t>{2, 102, 3, 103, 4, 104, 5, 105}));
}

void TestBackoff()
{
    CHECK(NextReconnectDelay(-5) == 2);
    CHECK(NextReconnectDelay(0) == 2);
    int current = 1;
    CHECK(current == 1);
    current = NextReconnectDelay(current);
    CHECK(current == 2);
    current = NextReconnectDelay(current);
    CHECK(current == 4);
    current = NextReconnectDelay(current);
    CHECK(current == 8);
    current = NextReconnectDelay(current);
    CHECK(current == 10);
    current = NextReconnectDelay(current);
    CHECK(current == 10);
}

void TestShuffledOrder()
{
    std::vector<size_t> input;
    for (size_t i = 0; i < 100; ++i)
    {
        input.push_back(i);
    }

    // Deterministic per seed.
    std::vector<size_t> a = ShuffledOrder(input, 12345);
    std::vector<size_t> b = ShuffledOrder(input, 12345);
    CHECK(a == b);

    // Result is a permutation of the input (same multiset, same size).
    std::vector<size_t> sorted = a;
    std::sort(sorted.begin(), sorted.end());
    CHECK(sorted == input);
    CHECK(a.size() == input.size());

    // A fresh seed produces a different order (collision prob ~1/100! for 100 elements).
    std::vector<size_t> c = ShuffledOrder(input, 999);
    CHECK(a != c);

    // Edges: empty and single-element are stable.
    CHECK(ShuffledOrder({}, 7).empty());
    std::vector<size_t> single{42};
    CHECK(ShuffledOrder(single, 7) == single);
}

}  // namespace

int main()
{
    TestReadLE();
    TestBaseHeaderFraming();
    TestBaseHeaderMalformedAndBoundaryCases();
    TestFragmentedCoalescedSnapcastMessages();
    TestWavParser();
    TestSupportedPCM16StereoFormat();
    TestWireChunk();
    TestRingBuffer();
    TestBackoff();
    TestShuffledOrder();
    RunPresetShelfModelTests();
    RunPresetBlocklistTests();
    RunLivePCMDelayBufferTests();
    RunPresetRotationSchedulerTests();
    RunPresetWarmCacheTests();
    RunLearnedSlowPresetStoreTests();
    RunPreprocessCacheTests();

    std::printf("RoonVisTests: %d passed, %d failed\n", Stats().passed, Stats().failed);
    return Stats().failed == 0 ? 0 : 1;
}
