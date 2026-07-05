#include "SnapPCM.h"

#include <Audio/PCM.hpp>

#include <algorithm>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <iomanip>
#include <fstream>
#include <iostream>
#include <limits>
#include <numeric>
#include <string>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>
#include <vector>

#include <netdb.h>

namespace
{
constexpr uint16_t kMessageCodecHeader = 1;
constexpr uint16_t kMessageWireChunk = 2;
constexpr uint16_t kMessageHello = 5;
constexpr int kLivePCMTargetPeak = 14000;
constexpr double kLivePCMMaxGain = 24.0;

struct AnalyzerSummary
{
    double minVol = std::numeric_limits<double>::max();
    double maxVol = 0;
    double totalVol = 0;
    double totalBass = 0;
    double totalMid = 0;
    double totalTreb = 0;
    double totalWaveRMS = 0;
    double totalSpectrum = 0;
    double totalSpectrumDelta = 0;
    double previousSpectrum = 0;
    size_t frames = 0;
};

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

std::vector<uint8_t> HelloMessage()
{
    const std::string json =
        "{\"Arch\":\"arm64\",\"ClientName\":\"RoonVisProbe\",\"HostName\":\"Mac\","
        "\"ID\":\"roonvis:mac:probe\",\"Instance\":1,\"MAC\":\"02:00:00:00:00:02\","
        "\"OS\":\"macOS\",\"SnapStreamProtocolVersion\":2,\"Version\":\"0.1.0\"}";

    std::vector<uint8_t> body;
    AppendLE32(body, static_cast<uint32_t>(json.size()));
    body.insert(body.end(), json.begin(), json.end());

    timeval now = {};
    gettimeofday(&now, nullptr);

    std::vector<uint8_t> message;
    AppendLE16(message, kMessageHello);
    AppendLE16(message, 0);
    AppendLE16(message, 0);
    AppendLE32(message, static_cast<uint32_t>(now.tv_sec));
    AppendLE32(message, static_cast<uint32_t>(now.tv_usec));
    AppendLE32(message, 0);
    AppendLE32(message, 0);
    AppendLE32(message, static_cast<uint32_t>(body.size()));
    message.insert(message.end(), body.begin(), body.end());
    return message;
}

bool WriteAll(int fd, const std::vector<uint8_t> &bytes)
{
    size_t written = 0;
    while (written < bytes.size())
    {
        ssize_t result = send(fd, bytes.data() + written, bytes.size() - written, 0);
        if (result < 0)
        {
            if (errno == EINTR)
            {
                continue;
            }
            return false;
        }
        if (result == 0)
        {
            return false;
        }
        written += static_cast<size_t>(result);
    }
    return true;
}

int ConnectTCP(const std::string &host, const std::string &port)
{
    addrinfo hints = {};
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;

    addrinfo *results = nullptr;
    int gai = getaddrinfo(host.c_str(), port.c_str(), &hints, &results);
    if (gai != 0)
    {
        std::cerr << "getaddrinfo failed: " << gai_strerror(gai) << "\n";
        return -1;
    }

    int fd = -1;
    for (addrinfo *candidate = results; candidate != nullptr; candidate = candidate->ai_next)
    {
        fd = socket(candidate->ai_family, candidate->ai_socktype, candidate->ai_protocol);
        if (fd < 0)
        {
            continue;
        }
        if (connect(fd, candidate->ai_addr, candidate->ai_addrlen) == 0)
        {
            break;
        }
        close(fd);
        fd = -1;
    }

    freeaddrinfo(results);
    return fd;
}

double RMSInt16(const int16_t *samples, size_t count)
{
    if (samples == nullptr || count == 0)
    {
        return 0;
    }

    long double sumSquares = 0;
    for (size_t i = 0; i < count; i++)
    {
        long double sample = samples[i];
        sumSquares += sample * sample;
    }
    return std::sqrt(static_cast<double>(sumSquares / static_cast<long double>(count)));
}

int PeakInt16(const int16_t *samples, size_t count)
{
    int peak = 0;
    for (size_t i = 0; i < count; i++)
    {
        peak = std::max(peak, std::abs(static_cast<int>(samples[i])));
    }
    return peak;
}

int16_t ScalePCM16Sample(int16_t sample, double gain)
{
    double scaled = std::round(static_cast<double>(sample) * gain);
    scaled = std::max<double>(std::numeric_limits<int16_t>::min(),
                              std::min<double>(std::numeric_limits<int16_t>::max(), scaled));
    return static_cast<int16_t>(scaled);
}

void ApplyAppLiveGain(std::vector<int16_t> &samples, int peak, double &gain)
{
    gain = 1.0;
    if (peak <= 0 || peak >= kLivePCMTargetPeak)
    {
        return;
    }

    gain = std::min(kLivePCMMaxGain, static_cast<double>(kLivePCMTargetPeak) / static_cast<double>(peak));
    for (int16_t &sample : samples)
    {
        sample = ScalePCM16Sample(sample, gain);
    }
}

float PCM16ToFloat(int16_t sample)
{
    return std::max(-1.0f, std::min(1.0f, static_cast<float>(sample) / 32768.0f));
}

std::vector<float> PCM16ToFloatSamples(const int16_t *samples, size_t count)
{
    std::vector<float> floats;
    floats.reserve(count);
    for (size_t i = 0; i < count; i++)
    {
        floats.push_back(PCM16ToFloat(samples[i]));
    }
    return floats;
}

double ArrayRMS(const std::array<float, libprojectM::Audio::WaveformSamples> &values)
{
    double sumSquares = 0;
    for (float value : values)
    {
        sumSquares += static_cast<double>(value) * static_cast<double>(value);
    }
    return std::sqrt(sumSquares / static_cast<double>(values.size()));
}

double SpectrumSum(const std::array<float, libprojectM::Audio::SpectrumSamples> &values)
{
    double sum = 0;
    for (float value : values)
    {
        sum += std::abs(static_cast<double>(value));
    }
    return sum;
}

void FeedAnalyzer(libprojectM::Audio::PCM &pcm,
                  const int16_t *samples,
                  size_t frames,
                  AnalyzerSummary &summary)
{
    pcm.Add(samples, 2, frames);
    pcm.UpdateFrameAudioData(1.0 / 60.0, static_cast<uint32_t>(summary.frames));
    libprojectM::Audio::FrameAudioData data = pcm.GetFrameAudioData();

    double spectrum = SpectrumSum(data.spectrumLeft) + SpectrumSum(data.spectrumRight);
    summary.minVol = std::min(summary.minVol, static_cast<double>(data.vol));
    summary.maxVol = std::max(summary.maxVol, static_cast<double>(data.vol));
    summary.totalVol += data.vol;
    summary.totalBass += data.bass;
    summary.totalMid += data.mid;
    summary.totalTreb += data.treb;
    summary.totalWaveRMS += 0.5 * (ArrayRMS(data.waveformLeft) + ArrayRMS(data.waveformRight));
    summary.totalSpectrum += spectrum;
    if (summary.frames > 0)
    {
        summary.totalSpectrumDelta += std::abs(spectrum - summary.previousSpectrum);
    }
    summary.previousSpectrum = spectrum;
    summary.frames++;
}

void FeedAnalyzer(libprojectM::Audio::PCM &pcm,
                  const float *samples,
                  size_t frames,
                  AnalyzerSummary &summary)
{
    pcm.Add(samples, 2, frames);
    pcm.UpdateFrameAudioData(1.0 / 60.0, static_cast<uint32_t>(summary.frames));
    libprojectM::Audio::FrameAudioData data = pcm.GetFrameAudioData();

    double spectrum = SpectrumSum(data.spectrumLeft) + SpectrumSum(data.spectrumRight);
    summary.minVol = std::min(summary.minVol, static_cast<double>(data.vol));
    summary.maxVol = std::max(summary.maxVol, static_cast<double>(data.vol));
    summary.totalVol += data.vol;
    summary.totalBass += data.bass;
    summary.totalMid += data.mid;
    summary.totalTreb += data.treb;
    summary.totalWaveRMS += 0.5 * (ArrayRMS(data.waveformLeft) + ArrayRMS(data.waveformRight));
    summary.totalSpectrum += spectrum;
    if (summary.frames > 0)
    {
        summary.totalSpectrumDelta += std::abs(spectrum - summary.previousSpectrum);
    }
    summary.previousSpectrum = spectrum;
    summary.frames++;
}

AnalyzerSummary SilenceSummary(size_t frames)
{
    libprojectM::Audio::PCM pcm;
    AnalyzerSummary summary;
    std::vector<int16_t> silence(libprojectM::Audio::WaveformSamples * 2, 0);
    for (size_t i = 0; i < frames; i++)
    {
        FeedAnalyzer(pcm, silence.data(), libprojectM::Audio::WaveformSamples, summary);
    }
    return summary;
}

void PrintSummary(const char *label, const AnalyzerSummary &summary)
{
    double frames = static_cast<double>(std::max<size_t>(1, summary.frames));
    std::cout << label
              << " analyzerFrames=" << summary.frames
              << " volAvg=" << summary.totalVol / frames
              << " volRange=" << (summary.maxVol - summary.minVol)
              << " bassAvg=" << summary.totalBass / frames
              << " midAvg=" << summary.totalMid / frames
              << " trebAvg=" << summary.totalTreb / frames
              << " waveRmsAvg=" << summary.totalWaveRMS / frames
              << " spectrumAvg=" << summary.totalSpectrum / frames
              << " spectrumDeltaAvg=" << summary.totalSpectrumDelta / frames
              << "\n";
}

bool HandleCodecHeader(const uint8_t *body, uint32_t size, RoonVis::WaveFormat &format)
{
    if (size < 8)
    {
        return false;
    }

    uint32_t codecLength = RoonVis::ReadLE32(body);
    if (codecLength > size - 4)
    {
        return false;
    }

    std::string codec(reinterpret_cast<const char *>(body + 4), codecLength);
    size_t payloadLengthOffset = 4 + codecLength;
    if (payloadLengthOffset + 4 > size)
    {
        return false;
    }

    uint32_t payloadLength = RoonVis::ReadLE32(body + payloadLengthOffset);
    if (payloadLength > size - payloadLengthOffset - 4)
    {
        return false;
    }

    RoonVis::WaveFormat parsed;
    if (codec == "pcm" &&
        RoonVis::ParseWaveFormat(body + payloadLengthOffset + 4, payloadLength, parsed) &&
        RoonVis::IsSupportedPCM16StereoFormat(parsed))
    {
        format = parsed;
        std::cout << "CodecHeader accepted: codec=pcm"
                  << " sampleRate=" << format.sampleRate
                  << " channels=" << format.channels
                  << " bits=" << format.bitsPerSample
                  << "\n";
        return true;
    }

    std::cout << "CodecHeader unsupported: codec=" << codec << "\n";
    return false;
}

int RunWavProbe(const std::string &path)
{
    std::ifstream input(path, std::ios::binary);
    if (!input)
    {
        std::cerr << "failed to open WAV: " << path << "\n";
        return 2;
    }
    std::vector<uint8_t> bytes((std::istreambuf_iterator<char>(input)), std::istreambuf_iterator<char>());

    RoonVis::WavData wav;
    if (!RoonVis::ParsePCM16Wav(bytes.data(), bytes.size(), wav))
    {
        std::cerr << "failed to parse PCM16 stereo WAV: " << path << "\n";
        return 2;
    }

    AnalyzerSummary silence = SilenceSummary(180);
    PrintSummary("silence", silence);

    libprojectM::Audio::PCM rawPCM;
    libprojectM::Audio::PCM appScaledPCM;
    libprojectM::Audio::PCM appFloatPCM;
    AnalyzerSummary rawSummary;
    AnalyzerSummary appScaledSummary;
    AnalyzerSummary appFloatSummary;
    uint64_t chunks = 0;
    uint64_t nonzeroSamples = 0;
    int maxPeak = 0;
    double totalRMS = 0;
    double totalGain = 0;
    constexpr size_t kFramesPerAnalyzerUpdate = libprojectM::Audio::WaveformSamples;

    for (size_t frameOffset = 0; frameOffset < wav.frameCount(); frameOffset += kFramesPerAnalyzerUpdate)
    {
        size_t frames = std::min(kFramesPerAnalyzerUpdate, wav.frameCount() - frameOffset);
        const int16_t *samples = wav.samples.data() + frameOffset * wav.channels;
        size_t sampleCount = frames * wav.channels;
        int peak = PeakInt16(samples, sampleCount);
        double rms = RMSInt16(samples, sampleCount);
        std::vector<int16_t> scaled(samples, samples + sampleCount);
        double gain = 1.0;
        ApplyAppLiveGain(scaled, peak, gain);
        std::vector<float> scaledFloat = PCM16ToFloatSamples(scaled.data(), scaled.size());

        FeedAnalyzer(rawPCM, samples, frames, rawSummary);
        FeedAnalyzer(appScaledPCM, scaled.data(), frames, appScaledSummary);
        FeedAnalyzer(appFloatPCM, scaledFloat.data(), frames, appFloatSummary);

        chunks++;
        maxPeak = std::max(maxPeak, peak);
        totalRMS += rms;
        totalGain += gain;
        nonzeroSamples += static_cast<uint64_t>(std::count_if(samples, samples + sampleCount, [](int16_t value) {
            return value != 0;
        }));
    }

    double chunkDivisor = static_cast<double>(std::max<uint64_t>(1, chunks));
    std::cout << "wav path=" << path
              << " sampleRate=" << wav.sampleRate
              << " channels=" << wav.channels
              << " frames=" << wav.frameCount()
              << " maxPeak=" << maxPeak
              << " rmsAvg=" << totalRMS / chunkDivisor
              << " nonzero=" << nonzeroSamples << "/" << wav.samples.size()
              << " appGainAvg=" << totalGain / chunkDivisor
              << "\n";
    PrintSummary("projectM raw", rawSummary);
    PrintSummary("projectM appScaled", appScaledSummary);
    PrintSummary("projectM appFloat", appFloatSummary);

    double silenceSpectrum = silence.totalSpectrum / static_cast<double>(std::max<size_t>(1, silence.frames));
    double liveSpectrum = appFloatSummary.totalSpectrum / static_cast<double>(std::max<size_t>(1, appFloatSummary.frames));
    double liveWave = appFloatSummary.totalWaveRMS / static_cast<double>(std::max<size_t>(1, appFloatSummary.frames));
    bool pass = maxPeak > 0 && liveWave > 0.01 && liveSpectrum > silenceSpectrum + 0.01;
    std::cout << (pass ? "PASS" : "FAIL")
              << ": projectM audio analyzer "
              << (pass ? "responded to WAV PCM" : "did not respond to WAV PCM")
              << "\n";
    return pass ? 0 : 1;
}
}  // namespace

int main(int argc, char **argv)
{
    if (argc > 2 && std::string(argv[1]) == "--wav")
    {
        std::cout << std::fixed << std::setprecision(3);
        return RunWavProbe(argv[2]);
    }

    std::string host = argc > 1 ? argv[1] : "127.0.0.1";
    std::string port = argc > 2 ? argv[2] : "1704";
    double seconds = argc > 3 ? std::stod(argv[3]) : 8.0;

    std::cout << std::fixed << std::setprecision(3);
    AnalyzerSummary silence = SilenceSummary(180);
    PrintSummary("silence", silence);

    int fd = ConnectTCP(host, port);
    if (fd < 0)
    {
        std::cerr << "connect failed for " << host << ":" << port << ": " << std::strerror(errno) << "\n";
        return 2;
    }

    std::vector<uint8_t> hello = HelloMessage();
    if (!WriteAll(fd, hello))
    {
        std::cerr << "failed to send Hello: " << std::strerror(errno) << "\n";
        close(fd);
        return 2;
    }

    libprojectM::Audio::PCM rawPCM;
    libprojectM::Audio::PCM appScaledPCM;
    libprojectM::Audio::PCM appFloatPCM;
    AnalyzerSummary rawSummary;
    AnalyzerSummary appScaledSummary;
    AnalyzerSummary appFloatSummary;
    RoonVis::WaveFormat format;
    bool formatSupported = false;
    std::vector<uint8_t> pending;
    uint64_t chunks = 0;
    uint64_t frames = 0;
    uint64_t nonzeroSamples = 0;
    uint64_t totalSamples = 0;
    int maxPeak = 0;
    double totalRMS = 0;
    double totalGain = 0;

    auto deadline = std::chrono::steady_clock::now() + std::chrono::duration<double>(seconds);
    while (std::chrono::steady_clock::now() < deadline)
    {
        fd_set readSet;
        FD_ZERO(&readSet);
        FD_SET(fd, &readSet);
        timeval timeout = {};
        timeout.tv_sec = 0;
        timeout.tv_usec = 250000;

        int ready = select(fd + 1, &readSet, nullptr, nullptr, &timeout);
        if (ready < 0)
        {
            if (errno == EINTR)
            {
                continue;
            }
            std::cerr << "select failed: " << std::strerror(errno) << "\n";
            close(fd);
            return 2;
        }
        if (ready == 0)
        {
            continue;
        }

        uint8_t buffer[65536];
        ssize_t received = recv(fd, buffer, sizeof(buffer), 0);
        if (received < 0)
        {
            if (errno == EINTR)
            {
                continue;
            }
            std::cerr << "recv failed: " << std::strerror(errno) << "\n";
            close(fd);
            return 2;
        }
        if (received == 0)
        {
            std::cerr << "server closed connection\n";
            break;
        }

        pending.insert(pending.end(), buffer, buffer + received);
        while (pending.size() >= RoonVis::kSnapcastBaseHeaderSize)
        {
            RoonVis::PendingBytesResult decision = RoonVis::DecidePendingBytes(pending.data(), pending.size());
            if (decision.decision == RoonVis::PendingBytesDecision::InvalidSize)
            {
                std::cerr << "invalid Snapcast message size " << decision.bodySize << "\n";
                close(fd);
                return 2;
            }
            if (decision.decision == RoonVis::PendingBytesDecision::NeedMore)
            {
                break;
            }

            const uint8_t *body = pending.data() + RoonVis::kSnapcastBaseHeaderSize;
            if (decision.type == kMessageCodecHeader)
            {
                formatSupported = HandleCodecHeader(body, decision.bodySize, format);
            }
            else if (decision.type == kMessageWireChunk && formatSupported)
            {
                RoonVis::WireChunkPCM chunk;
                RoonVis::WireChunkResult result = RoonVis::ParseWireChunkPCM16Stereo(body, decision.bodySize, chunk);
                if (result == RoonVis::WireChunkResult::Enqueue)
                {
                    const int16_t *samples = reinterpret_cast<const int16_t *>(chunk.payload);
                    size_t sampleCount = chunk.frames * 2;
                    int peak = PeakInt16(samples, sampleCount);
                    double rms = RMSInt16(samples, sampleCount);
                    std::vector<int16_t> scaled(samples, samples + sampleCount);
                    double gain = 1.0;
                    ApplyAppLiveGain(scaled, peak, gain);
                    std::vector<float> scaledFloat = PCM16ToFloatSamples(scaled.data(), scaled.size());

                    FeedAnalyzer(rawPCM, samples, chunk.frames, rawSummary);
                    FeedAnalyzer(appScaledPCM, scaled.data(), chunk.frames, appScaledSummary);
                    FeedAnalyzer(appFloatPCM, scaledFloat.data(), chunk.frames, appFloatSummary);

                    chunks++;
                    frames += chunk.frames;
                    totalSamples += sampleCount;
                    nonzeroSamples += static_cast<uint64_t>(std::count_if(samples, samples + sampleCount, [](int16_t value) {
                        return value != 0;
                    }));
                    maxPeak = std::max(maxPeak, peak);
                    totalRMS += rms;
                    totalGain += gain;
                }
            }

            pending.erase(pending.begin(), pending.begin() + decision.messageSize);
        }
    }

    close(fd);

    double chunkDivisor = static_cast<double>(std::max<uint64_t>(1, chunks));
    std::cout << "stream chunks=" << chunks
              << " frames=" << frames
              << " maxPeak=" << maxPeak
              << " rmsAvg=" << totalRMS / chunkDivisor
              << " nonzero=" << nonzeroSamples << "/" << totalSamples
              << " appGainAvg=" << totalGain / chunkDivisor
              << "\n";
    PrintSummary("projectM raw", rawSummary);
    PrintSummary("projectM appScaled", appScaledSummary);
    PrintSummary("projectM appFloat", appFloatSummary);

    double silenceSpectrum = silence.totalSpectrum / static_cast<double>(std::max<size_t>(1, silence.frames));
    double liveSpectrum = appFloatSummary.totalSpectrum / static_cast<double>(std::max<size_t>(1, appFloatSummary.frames));
    double liveWave = appFloatSummary.totalWaveRMS / static_cast<double>(std::max<size_t>(1, appFloatSummary.frames));
    bool pass = formatSupported && chunks > 0 && maxPeak > 0 && liveWave > 0.01 && liveSpectrum > silenceSpectrum + 0.01;
    std::cout << (pass ? "PASS" : "FAIL")
              << ": projectM audio analyzer "
              << (pass ? "received non-silent music-derived waveform/spectrum data" : "did not see usable live audio")
              << "\n";
    return pass ? 0 : 1;
}
