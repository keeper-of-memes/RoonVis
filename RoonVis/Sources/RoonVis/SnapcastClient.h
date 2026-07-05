#import <Foundation/Foundation.h>

@class ProjectMBridge;

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SnapcastClientConnectionState) {
    SnapcastClientConnectionStateWaitingForConnection = 0,
    SnapcastClientConnectionStateConnectedWaitingForAudio = 1,
    SnapcastClientConnectionStateReceivingAudio = 2,
    SnapcastClientConnectionStateReconnecting = 3,
};

FOUNDATION_EXPORT NSNotificationName const SnapcastClientConnectionStateDidChangeNotification;
FOUNDATION_EXPORT NSString *const SnapcastClientConnectionStateKey;

@interface SnapcastClient : NSObject

@property(nonatomic, assign, readonly) SnapcastClientConnectionState connectionState;

- (instancetype)initWithHost:(NSString *)host port:(uint16_t)port bridge:(ProjectMBridge *)bridge;
- (void)start;
- (void)stop;
- (void)reconnectNow;

@end

NS_ASSUME_NONNULL_END
