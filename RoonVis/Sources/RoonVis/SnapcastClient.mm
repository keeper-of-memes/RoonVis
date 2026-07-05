#import "SnapcastClient.h"

#import "ProjectMBridge.h"
#import "SnapPCM.h"

#import <Network/Network.h>

#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <string>
#include <sys/time.h>
#include <vector>

NSNotificationName const SnapcastClientConnectionStateDidChangeNotification = @"SnapcastClientConnectionStateDidChangeNotification";
NSString *const SnapcastClientConnectionStateKey = @"SnapcastClientConnectionState";

namespace
{
constexpr uint16_t kMessageCodecHeader = 1;
constexpr uint16_t kMessageWireChunk = 2;
constexpr uint16_t kMessageServerSettings = 3;
constexpr uint16_t kMessageHello = 5;
constexpr CFTimeInterval kConnectAttemptTimeoutSeconds = 5.0;
constexpr CFTimeInterval kPCMWatchdogTimeoutSeconds = 5.0;

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
}  // namespace

@interface SnapcastClient ()
@property(nonatomic, copy) NSString *host;
@property(nonatomic, assign) uint16_t port;
@property(nonatomic, assign) ProjectMBridge *bridge;
@end

@implementation SnapcastClient
{
    dispatch_queue_t _queue;
    nw_connection_t _connection;
    BOOL _started;
    BOOL _stopping;
    BOOL _connected;
    BOOL _reconnectScheduled;
    RoonVis::WaveFormat _format;
    BOOL _formatSupported;
    std::vector<uint8_t> _pendingBytes;
    uint64_t _chunkCount;
    uint64_t _frameCount;
    int _reconnectDelaySeconds;
    CFTimeInterval _lastPCMReceiveTime;
    uint64_t _pcmWatchdogGeneration;
    uint64_t _connectAttemptGeneration;
    BOOL _connectionReceivedPCM;
    SnapcastClientConnectionState _connectionState;
}

@synthesize connectionState = _connectionState;

- (instancetype)initWithHost:(NSString *)host port:(uint16_t)port bridge:(ProjectMBridge *)bridge
{
    self = [super init];
    if (self)
    {
        _host = [host copy];
        _port = port;
        _bridge = bridge;
        _queue = dispatch_queue_create("local.roon-vis.snapcast", DISPATCH_QUEUE_SERIAL);
        _reconnectDelaySeconds = 1;
        _connectionState = SnapcastClientConnectionStateWaitingForConnection;
    }
    return self;
}

- (void)dealloc
{
    _stopping = YES;
    _bridge = nil;
    if (_connection != nil)
    {
        nw_connection_cancel(_connection);
        _connection = nil;
    }
    [_host release];
    [super dealloc];
}

- (void)start
{
    dispatch_async(_queue, ^{
        if (self->_started)
        {
            return;
        }
        self->_started = YES;
        self->_stopping = NO;
        [self connect];
    });
}

- (void)stop
{
    // Close the use-after-free window on the assign'd bridge. `bridge` is `assign`
    // (this is an MRC target — a zeroing `weak` ref needs ARC), so nothing stops a
    // chunk mid-flight on _queue from calling into a ProjectMBridge the owner is about
    // to release. Drain synchronously: after -stop returns, any in-flight
    // -handleWireChunk has completed and _bridge is nil, so the owner can release the
    // bridge safely. Serial-queue dispatch_sync is deadlock-free here — -stop is only
    // ever called off _queue (ANGLEGLView -dealloc, main thread), and the only
    // main-queue hop on _queue (state-change notify) is dispatch_async.
    self.bridge = nil;
    dispatch_sync(_queue, ^{
        self->_stopping = YES;
        self->_started = NO;
        self->_bridge = nil;
        self->_connected = NO;
        self->_connectionReceivedPCM = NO;
        [self setConnectionStateOnQueue:SnapcastClientConnectionStateWaitingForConnection];
        self->_pcmWatchdogGeneration++;
        self->_connectAttemptGeneration++;
        if (self->_connection != nil)
        {
            nw_connection_cancel(self->_connection);
            self->_connection = nil;
        }
        self->_pendingBytes.clear();
    });
}

- (void)reconnectNow
{
    dispatch_async(_queue, ^{
        if (self->_stopping || !self->_started)
        {
            return;
        }
        if (self->_connected)
        {
            return;
        }
        if (self->_reconnectScheduled)
        {
            NSLog(@"Snapcast Step 1 reconnect already scheduled; foreground reconnect skipped");
            return;
        }

        NSLog(@"Snapcast Step 1 foreground reconnect requested");
        if (self->_connection != nil)
        {
            nw_connection_cancel(self->_connection);
            self->_connection = nil;
        }
        [self connect];
    });
}

- (void)connect
{
    if (_stopping)
    {
        return;
    }

    NSLog(@"Snapcast Step 1 connecting to %@:%u (retry delay %ds)", self.host, self.port, _reconnectDelaySeconds);
    [self setConnectionStateOnQueue:SnapcastClientConnectionStateWaitingForConnection];
    _reconnectScheduled = NO;
    _pendingBytes.clear();
    _chunkCount = 0;
    _frameCount = 0;
    _formatSupported = NO;
    _format = RoonVis::WaveFormat();
    _connected = NO;
    _connectionReceivedPCM = NO;
    _lastPCMReceiveTime = 0;
    _pcmWatchdogGeneration++;
    uint64_t connectGeneration = ++_connectAttemptGeneration;

    NSString *portString = [NSString stringWithFormat:@"%u", self.port];
    nw_endpoint_t endpoint = nw_endpoint_create_host(self.host.UTF8String, portString.UTF8String);
    // Plain TCP (no TLS). Disable Nagle so our small ~10 ms PCM chunks are sent
    // immediately rather than coalesced — shaves latency toward the sub-100 ms target.
    nw_parameters_t parameters = nw_parameters_create_secure_tcp(
        NW_PARAMETERS_DISABLE_PROTOCOL,
        ^(nw_protocol_options_t tcp_options) {
            nw_tcp_options_set_no_delay(tcp_options, true);
        });
    _connection = nw_connection_create(endpoint, parameters);
    nw_connection_set_queue(_connection, _queue);

    nw_connection_t connection = _connection;
    nw_connection_set_state_changed_handler(_connection, ^(nw_connection_state_t state, nw_error_t error) {
        if (connection != self->_connection)
        {
            return;
        }

        switch (state)
        {
            case nw_connection_state_ready:
                self->_connected = YES;
                self->_connectAttemptGeneration++;
                NSLog(@"Snapcast Step 1 connected");
                [self setConnectionStateOnQueue:SnapcastClientConnectionStateConnectedWaitingForAudio];
                [self sendHello];
                [self receiveNext];
                break;
            case nw_connection_state_failed:
                self->_connected = NO;
                NSLog(@"Snapcast Step 1 connection failed: %@", error);
                [self reconnectSoon];
                break;
            case nw_connection_state_cancelled:
                self->_connected = NO;
                NSLog(@"Snapcast Step 1 connection cancelled");
                if (!self->_stopping)
                {
                    [self reconnectSoon];
                }
                break;
            default:
                break;
        }
    });

    nw_connection_start(_connection);
    [self scheduleConnectAttemptTimeout:connectGeneration];
}

- (void)reconnectSoon
{
    if (_stopping || _reconnectScheduled)
    {
        return;
    }

    _reconnectScheduled = YES;
    _connected = NO;
    _connectionReceivedPCM = NO;
    [self setConnectionStateOnQueue:SnapcastClientConnectionStateReconnecting];
    _pcmWatchdogGeneration++;
    _connectAttemptGeneration++;
    if (_connection != nil)
    {
        nw_connection_cancel(_connection);
        _connection = nil;
    }

    int delaySeconds = _reconnectDelaySeconds;
    _reconnectDelaySeconds = RoonVis::NextReconnectDelay(_reconnectDelaySeconds);
    NSLog(@"Snapcast Step 1 reconnecting in %ds", delaySeconds);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>(delaySeconds) * NSEC_PER_SEC), _queue, ^{
        [self connect];
    });
}

- (void)setConnectionStateOnQueue:(SnapcastClientConnectionState)connectionState
{
    if (_connectionState == connectionState)
    {
        return;
    }

    _connectionState = connectionState;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:SnapcastClientConnectionStateDidChangeNotification
                                                            object:self
                                                          userInfo:@{ SnapcastClientConnectionStateKey : @(connectionState) }];
    });
}

- (void)scheduleConnectAttemptTimeout:(uint64_t)generation
{
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>(kConnectAttemptTimeoutSeconds * NSEC_PER_SEC)), _queue, ^{
        if (generation != self->_connectAttemptGeneration || self->_stopping || !self->_started || self->_connected)
        {
            return;
        }

        NSLog(@"Snapcast Step 1 connection attempt timed out after %.1fs", kConnectAttemptTimeoutSeconds);
        [self reconnectSoon];
    });
}

- (void)schedulePCMWatchdog
{
    uint64_t generation = ++_pcmWatchdogGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>(kPCMWatchdogTimeoutSeconds * NSEC_PER_SEC)), _queue, ^{
        if (generation != self->_pcmWatchdogGeneration || self->_stopping || !self->_started ||
            !self->_connected || !self->_connectionReceivedPCM)
        {
            return;
        }

        CFTimeInterval now = CFAbsoluteTimeGetCurrent();
        CFTimeInterval idleSeconds = now - self->_lastPCMReceiveTime;
        if (idleSeconds >= kPCMWatchdogTimeoutSeconds)
        {
            NSLog(@"Snapcast Step 1 no PCM for %.1fs; reconnecting", idleSeconds);
            [self reconnectSoon];
            return;
        }

        [self schedulePCMWatchdog];
    });
}

- (NSData *)helloBody
{
    NSDictionary *hello = @{
        @"Arch": @"arm64",
        @"ClientName": @"RoonVis",
        @"HostName": @"AppleTV",
        @"ID": @"roonvis:appletv:01",
        @"Instance": @1,
        @"MAC": @"02:00:00:00:00:01",
        @"OS": @"tvOS",
        @"SnapStreamProtocolVersion": @2,
        @"Version": @"0.1.0",
    };

    NSError *error = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:hello options:0 error:&error];
    if (json == nil)
    {
        NSLog(@"Snapcast Step 1 failed to encode Hello JSON: %@", error);
        return nil;
    }

    std::vector<uint8_t> body;
    AppendLE32(body, static_cast<uint32_t>(json.length));
    const uint8_t *jsonBytes = static_cast<const uint8_t *>(json.bytes);
    body.insert(body.end(), jsonBytes, jsonBytes + json.length);
    return [NSData dataWithBytes:body.data() length:body.size()];
}

- (void)sendHello
{
    NSData *bodyData = [self helloBody];
    if (bodyData == nil)
    {
        return;
    }

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
    AppendLE32(message, static_cast<uint32_t>(bodyData.length));

    const uint8_t *body = static_cast<const uint8_t *>(bodyData.bytes);
    message.insert(message.end(), body, body + bodyData.length);

    void *bytes = std::malloc(message.size());
    if (bytes == nullptr)
    {
        NSLog(@"Snapcast Step 1 Hello allocation failed");
        return;
    }
    std::memcpy(bytes, message.data(), message.size());

    dispatch_data_t data = dispatch_data_create(bytes, message.size(), _queue, DISPATCH_DATA_DESTRUCTOR_FREE);
    nw_connection_send(_connection, data, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, true, ^(nw_error_t error) {
        if (error != nil)
        {
            NSLog(@"Snapcast Step 1 Hello send failed: %@", error);
        }
        else
        {
            NSLog(@"Snapcast Step 1 sent Hello");
        }
    });
}

- (void)receiveNext
{
    if (_connection == nil || _stopping)
    {
        return;
    }

    nw_connection_receive(_connection, 1, 65536, ^(dispatch_data_t content, nw_content_context_t context, bool isComplete, nw_error_t error) {
        if (error != nil)
        {
            NSLog(@"Snapcast Step 1 receive failed: %@", error);
            [self reconnectSoon];
            return;
        }

        if (content != nil)
        {
            dispatch_data_apply(content, ^bool(dispatch_data_t region, size_t offset, const void *buffer, size_t size) {
                const uint8_t *bytes = static_cast<const uint8_t *>(buffer);
                self->_pendingBytes.insert(self->_pendingBytes.end(), bytes, bytes + size);
                return true;
            });
            [self parsePendingBytes];
        }

        if (isComplete)
        {
            NSLog(@"Snapcast Step 1 server disconnected");
            [self reconnectSoon];
            return;
        }

        [self receiveNext];
    });
}

- (void)parsePendingBytes
{
    while (_pendingBytes.size() >= RoonVis::kSnapcastBaseHeaderSize)
    {
        RoonVis::PendingBytesResult pending = RoonVis::DecidePendingBytes(_pendingBytes.data(), _pendingBytes.size());
        if (pending.decision == RoonVis::PendingBytesDecision::InvalidSize)
        {
            NSLog(@"Snapcast Step 1 invalid message size %u; reconnecting", pending.bodySize);
            [self reconnectSoon];
            return;
        }
        if (pending.decision == RoonVis::PendingBytesDecision::NeedMore)
        {
            return;
        }

        [self dispatchMessageType:pending.type
                             body:_pendingBytes.data() + RoonVis::kSnapcastBaseHeaderSize
                             size:pending.bodySize];
        _pendingBytes.erase(_pendingBytes.begin(), _pendingBytes.begin() + pending.messageSize);
    }
}

- (void)dispatchMessageType:(uint16_t)type body:(const uint8_t *)body size:(uint32_t)size
{
    switch (type)
    {
        case kMessageServerSettings:
            [self handleServerSettings:body size:size];
            break;
        case kMessageCodecHeader:
            [self handleCodecHeader:body size:size];
            break;
        case kMessageWireChunk:
            [self handleWireChunk:body size:size];
            break;
        default:
            break;
    }
}

- (void)handleServerSettings:(const uint8_t *)body size:(uint32_t)size
{
    if (size < 4)
    {
        NSLog(@"Snapcast Step 1 malformed ServerSettings: size %u < 4", size);
        return;
    }

    uint32_t jsonLength = RoonVis::ReadLE32(body);
    if (jsonLength > size - 4)
    {
        NSLog(@"Snapcast Step 1 malformed ServerSettings: jsonLength %u > available %u", jsonLength, size - 4);
        return;
    }

    NSString *json = [[[NSString alloc] initWithBytes:body + 4 length:jsonLength encoding:NSUTF8StringEncoding] autorelease];
    NSLog(@"Snapcast Step 1 ServerSettings: %@", json ?: @"(invalid UTF-8)");
}

- (void)handleCodecHeader:(const uint8_t *)body size:(uint32_t)size
{
    if (size < 8)
    {
        NSLog(@"Snapcast Step 1 malformed CodecHeader: size %u < 8", size);
        return;
    }

    uint32_t codecLength = RoonVis::ReadLE32(body);
    if (codecLength > size - 4)
    {
        NSLog(@"Snapcast Step 1 malformed CodecHeader: codecLength %u > available %u", codecLength, size - 4);
        return;
    }

    NSString *codec = [[[NSString alloc] initWithBytes:body + 4 length:codecLength encoding:NSUTF8StringEncoding] autorelease];
    size_t payloadLengthOffset = 4 + codecLength;
    if (payloadLengthOffset + 4 > size)
    {
        NSLog(@"Snapcast Step 1 malformed CodecHeader: payloadLengthOffset %zu + 4 > size %u", payloadLengthOffset, size);
        return;
    }

    uint32_t payloadLength = RoonVis::ReadLE32(body + payloadLengthOffset);
    const uint8_t *payload = body + payloadLengthOffset + 4;
    if (payloadLength > size - payloadLengthOffset - 4)
    {
        NSLog(@"Snapcast Step 1 malformed CodecHeader: payloadLength %u > available %zu",
              payloadLength,
              static_cast<size_t>(size) - payloadLengthOffset - 4);
        return;
    }

    _formatSupported = NO;
    _format = RoonVis::WaveFormat();
    RoonVis::WaveFormat format;
    if ([codec isEqualToString:@"pcm"] && RoonVis::ParseWaveFormat(payload, payloadLength, format) &&
        RoonVis::IsSupportedPCM16StereoFormat(format))
    {
        _format = format;
        _formatSupported = YES;
        NSLog(@"Snapcast Step 1 accepted CodecHeader: codec=%@ samplerate=%u channels=%u bits=%u",
              codec,
              _format.sampleRate,
              _format.channels,
              _format.bitsPerSample);
    }
    else
    {
        if ([codec isEqualToString:@"pcm"] && RoonVis::ParseWaveFormat(payload, payloadLength, format))
        {
            NSLog(@"Snapcast Step 1 unsupported codec/format: codec=%@ samplerate=%u channels=%u bits=%u",
                  codec,
                  format.sampleRate,
                  format.channels,
                  format.bitsPerSample);
        }
        else
        {
            NSLog(@"Snapcast Step 1 unsupported codec/format: codec=%@ payload=%u bytes", codec ?: @"(invalid)", payloadLength);
        }
    }
}

- (void)handleWireChunk:(const uint8_t *)body size:(uint32_t)size
{
    if (!_formatSupported)
    {
        return;
    }

    if (size < 12)
    {
        NSLog(@"Snapcast Step 1 malformed WireChunk: size %u < 12", size);
        return;
    }

    RoonVis::WireChunkPCM chunk;
    RoonVis::WireChunkResult chunkResult = RoonVis::ParseWireChunkPCM16Stereo(body, size, chunk);
    if (chunkResult == RoonVis::WireChunkResult::Malformed)
    {
        uint32_t payloadLength = size >= 12 ? RoonVis::ReadLE32(body + 8) : 0;
        NSLog(@"Snapcast Step 1 malformed WireChunk: payloadLength %u size %u; dropping", payloadLength, size);
        return;
    }
    if (chunkResult == RoonVis::WireChunkResult::NoSamples)
    {
        return;
    }

    _lastPCMReceiveTime = CFAbsoluteTimeGetCurrent();
    if (!_connectionReceivedPCM)
    {
        _connectionReceivedPCM = YES;
        [self setConnectionStateOnQueue:SnapcastClientConnectionStateReceivingAudio];
        [self schedulePCMWatchdog];
    }

    NSUInteger frames = static_cast<NSUInteger>(chunk.frames);
    ProjectMBridge *bridge = self.bridge;
    if (bridge == nil)
    {
        return;
    }
    // Feed the wire payload straight through — no intermediate int16 buffer.
    // chunk.payload is body+12 inside _pendingBytes, whose storage is 16-aligned; the
    // payload offset (26-byte base header + 12-byte chunk header = 38) is even, so the
    // int16 reinterpret is 2-byte aligned. -enqueueLivePCMInt16: copies into its ring
    // under _livePCMMutex before this call returns and before _pendingBytes is erased.
    [bridge enqueueLivePCMInt16:reinterpret_cast<const int16_t *>(chunk.payload) frameCount:frames];
    if (_reconnectDelaySeconds != 1)
    {
        NSLog(@"Snapcast Step 1 received PCM; reconnect delay reset to 1s");
        _reconnectDelaySeconds = 1;
    }
    _chunkCount++;
    _frameCount += frames;
    if ((_chunkCount % 120) == 0)
    {
        NSLog(@"Snapcast Step 1 received %llu chunks, %llu frames", _chunkCount, _frameCount);
    }
}

@end
