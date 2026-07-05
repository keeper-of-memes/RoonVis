#import <UIKit/UIKit.h>

#import "AppDelegate.h"
#import "RoonVisCrashReporter.h"

int main(int argc, char *argv[])
{
    RoonVisInstallCrashReporter();
    @autoreleasepool
    {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(AppDelegate.class));
    }
}
