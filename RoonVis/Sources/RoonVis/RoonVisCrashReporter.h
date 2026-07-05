#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

void RoonVisInstallCrashReporter(void);
void RoonVisLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
void RoonVisLogC(const char *message);
NSString *RoonVisCrashReportsDirectory(void);

NS_ASSUME_NONNULL_END
