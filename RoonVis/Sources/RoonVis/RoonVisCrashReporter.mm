#import "RoonVisCrashReporter.h"

#import <execinfo.h>
#import <mach-o/dyld.h>
#import <signal.h>
#import <stdarg.h>
#import <stdatomic.h>
#import <stdbool.h>
#import <stdint.h>
#import <stdio.h>
#import <string.h>
#import <sys/stat.h>
#import <sys/time.h>
#import <time.h>
#import <unistd.h>
#import <fcntl.h>
#import <limits.h>

namespace
{
static constexpr size_t kBreadcrumbCapacity = 200;
static constexpr size_t kBreadcrumbLength = 512;
static constexpr size_t kMaxSignalFrames = 128;

static char gBreadcrumbs[kBreadcrumbCapacity][kBreadcrumbLength];
static atomic_uint gBreadcrumbSequence;
static int gCrashFd = -1;
static char gCrashPath[PATH_MAX];
static char gMainImageInfo[256];
static char gInstallTimestamp[64];

static const char *SignalName(int signalNumber)
{
    switch (signalNumber)
    {
        case SIGSEGV: return "SIGSEGV";
        case SIGABRT: return "SIGABRT";
        case SIGBUS: return "SIGBUS";
        case SIGILL: return "SIGILL";
        case SIGFPE: return "SIGFPE";
        case SIGTRAP: return "SIGTRAP";
        default: return "UNKNOWN";
    }
}

static void SafeWrite(const char *text)
{
    if (gCrashFd < 0 || text == nullptr)
    {
        return;
    }
    size_t length = strlen(text);
    while (length > 0)
    {
        ssize_t written = write(gCrashFd, text, length);
        if (written <= 0)
        {
            return;
        }
        text += written;
        length -= static_cast<size_t>(written);
    }
}

static void SafeWriteDecimal(uint64_t value)
{
    char buffer[32];
    size_t index = sizeof(buffer);
    buffer[--index] = '\0';
    do
    {
        buffer[--index] = static_cast<char>('0' + (value % 10));
        value /= 10;
    } while (value > 0 && index > 0);
    SafeWrite(&buffer[index]);
}

static void SafeWriteHex(uintptr_t value)
{
    char buffer[(sizeof(uintptr_t) * 2) + 3];
    buffer[0] = '0';
    buffer[1] = 'x';
    for (size_t i = 0; i < sizeof(uintptr_t) * 2; i++)
    {
        unsigned int shift = static_cast<unsigned int>((sizeof(uintptr_t) * 2 - 1 - i) * 4);
        unsigned int nibble = static_cast<unsigned int>((value >> shift) & 0xf);
        buffer[2 + i] = static_cast<char>(nibble < 10 ? ('0' + nibble) : ('a' + nibble - 10));
    }
    buffer[sizeof(buffer) - 1] = '\0';
    SafeWrite(buffer);
}

static void WriteBreadcrumbsToCrashFd()
{
    SafeWrite("\nBreadcrumbs (oldest to newest):\n");
    unsigned int sequence = atomic_load_explicit(&gBreadcrumbSequence, memory_order_relaxed);
    unsigned int count = sequence < kBreadcrumbCapacity ? sequence : static_cast<unsigned int>(kBreadcrumbCapacity);
    unsigned int start = sequence > kBreadcrumbCapacity ? sequence - static_cast<unsigned int>(kBreadcrumbCapacity) : 0;
    for (unsigned int i = 0; i < count; i++)
    {
        unsigned int breadcrumbSequence = start + i;
        const char *line = gBreadcrumbs[breadcrumbSequence % kBreadcrumbCapacity];
        SafeWrite("  ");
        SafeWrite(line);
        SafeWrite("\n");
    }
}

static void WriteRawFrames(void *const *frames, int frameCount)
{
    SafeWrite("\nRaw frame addresses:\n");
    for (int i = 0; i < frameCount; i++)
    {
        SafeWrite("  [");
        SafeWriteDecimal(static_cast<uint64_t>(i));
        SafeWrite("] ");
        SafeWriteHex(reinterpret_cast<uintptr_t>(frames[i]));
        SafeWrite("\n");
    }
}

static void WriteSignalCrash(int signalNumber)
{
    SafeWrite("\n\n===== RoonVis Crash =====\n");
    SafeWrite("type=signal signal=");
    SafeWrite(SignalName(signalNumber));
    SafeWrite(" number=");
    SafeWriteDecimal(static_cast<uint64_t>(signalNumber));
    struct timespec crashTime;
    if (clock_gettime(CLOCK_REALTIME, &crashTime) == 0)
    {
        SafeWrite("\ncrash_timestamp_unix=");
        SafeWriteDecimal(static_cast<uint64_t>(crashTime.tv_sec));
        SafeWrite(".");
        SafeWriteDecimal(static_cast<uint64_t>(crashTime.tv_nsec));
    }
    SafeWrite("\nlast_breadcrumb_timestamp=");
    SafeWrite(gInstallTimestamp);
    SafeWrite("\ncrash_file=");
    SafeWrite(gCrashPath);
    SafeWrite("\n");
    SafeWrite(gMainImageInfo);
    SafeWrite("\n");

    void *frames[kMaxSignalFrames];
    int frameCount = backtrace(frames, static_cast<int>(kMaxSignalFrames));
    WriteRawFrames(frames, frameCount);
    SafeWrite("\nSymbolic backtrace:\n");
    backtrace_symbols_fd(frames, frameCount, gCrashFd);
    SafeWrite("\n");
    WriteBreadcrumbsToCrashFd();
    fsync(gCrashFd);
}

static void SignalHandler(int signalNumber)
{
    WriteSignalCrash(signalNumber);
    signal(signalNumber, SIG_DFL);
    raise(signalNumber);
}

static void AppendBreadcrumbLine(const char *line)
{
    if (line == nullptr)
    {
        return;
    }
    unsigned int sequence = atomic_fetch_add_explicit(&gBreadcrumbSequence, 1, memory_order_relaxed);
    char *slot = gBreadcrumbs[sequence % kBreadcrumbCapacity];
    strlcpy(slot, line, kBreadcrumbLength);
}

static void FormatTimestamp(char *buffer, size_t length)
{
    struct timeval now;
    gettimeofday(&now, nullptr);
    struct tm tmValue;
    localtime_r(&now.tv_sec, &tmValue);
    snprintf(buffer,
             length,
             "%04d-%02d-%02d %02d:%02d:%02d.%03d unix=%lld",
             tmValue.tm_year + 1900,
             tmValue.tm_mon + 1,
             tmValue.tm_mday,
             tmValue.tm_hour,
             tmValue.tm_min,
             tmValue.tm_sec,
             static_cast<int>(now.tv_usec / 1000),
             static_cast<long long>(now.tv_sec));
}

static void ExceptionHandler(NSException *exception)
{
    NSFileHandle *handle = [[NSFileHandle alloc] initWithFileDescriptor:gCrashFd closeOnDealloc:NO];
    [handle seekToEndOfFile];
    NSString *header = [NSString stringWithFormat:@"\n\n===== RoonVis Crash =====\ntype=objc-exception name=%@ reason=%@\ntimestamp=%@\ncrash_file=%s\n%s\n",
                        exception.name ?: @"(nil)",
                        exception.reason ?: @"(nil)",
                        [[NSDate date] description],
                        gCrashPath,
                        gMainImageInfo];
    NSData *headerData = [header dataUsingEncoding:NSUTF8StringEncoding];
    if (headerData != nil)
    {
        [handle writeData:headerData];
    }

    NSString *symbols = [NSString stringWithFormat:@"\nException callStackSymbols:\n%@\n", [[exception callStackSymbols] componentsJoinedByString:@"\n"]];
    NSData *symbolsData = [symbols dataUsingEncoding:NSUTF8StringEncoding];
    if (symbolsData != nil)
    {
        [handle writeData:symbolsData];
    }

    NSString *addresses = [NSString stringWithFormat:@"\nException callStackReturnAddresses:\n%@\n", [[exception callStackReturnAddresses] componentsJoinedByString:@"\n"]];
    NSData *addressesData = [addresses dataUsingEncoding:NSUTF8StringEncoding];
    if (addressesData != nil)
    {
        [handle writeData:addressesData];
    }

    void *frames[kMaxSignalFrames];
    int frameCount = backtrace(frames, static_cast<int>(kMaxSignalFrames));
    WriteRawFrames(frames, frameCount);
    SafeWrite("\nSymbolic backtrace:\n");
    backtrace_symbols_fd(frames, frameCount, gCrashFd);
    SafeWrite("\n");
    WriteBreadcrumbsToCrashFd();
    fsync(gCrashFd);
    [handle release];
}

static NSString *CrashReportsDirectory()
{
    // tvOS does NOT reliably allow writes to Documents (persistent storage is
    // restricted to Caches/iCloud). Caches IS writable on-device, so dumps go there.
    NSArray<NSString *> *directories = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString *caches = directories.count > 0 ? directories[0] : NSTemporaryDirectory();
    return [caches stringByAppendingPathComponent:@"CrashReports"];
}

static void PrecomputeMainImageInfo()
{
    const struct mach_header *header = _dyld_get_image_header(0);
    intptr_t slide = _dyld_get_image_vmaddr_slide(0);
    snprintf(gMainImageInfo,
             sizeof(gMainImageInfo),
             "main_image_header=%p main_image_vmaddr_slide=0x%llx",
             header,
             static_cast<unsigned long long>(slide));
}

static NSArray<NSString *> *CrashDumpFiles(NSString *directory)
{
    const char *marker = "===== RoonVis Crash =====";
    const size_t markerLength = strlen(marker);
    NSArray<NSString *> *contents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:directory error:nil];
    NSMutableArray<NSString *> *dumps = [NSMutableArray array];
    for (NSString *filename in contents)
    {
        if ([filename hasPrefix:@"crash-"] && [filename hasSuffix:@".log"])
        {
            NSString *path = [directory stringByAppendingPathComponent:filename];
            NSData *data = [NSData dataWithContentsOfFile:path];
            const char *bytes = static_cast<const char *>(data.bytes);
            BOOL containsCrashMarker = NO;
            if (bytes != nullptr && data.length >= markerLength)
            {
                for (NSUInteger i = 0; i <= data.length - markerLength; i++)
                {
                    if (memcmp(bytes + i, marker, markerLength) == 0)
                    {
                        containsCrashMarker = YES;
                        break;
                    }
                }
            }
            if (containsCrashMarker)
            {
                [dumps addObject:path];
            }
        }
    }
    [dumps sortUsingSelector:@selector(compare:)];
    return dumps;
}
}

NSString *RoonVisCrashReportsDirectory(void)
{
    return CrashReportsDirectory();
}

void RoonVisLogC(const char *message)
{
    if (message == nullptr)
    {
        return;
    }

    char timestamp[64];
    FormatTimestamp(timestamp, sizeof(timestamp));
    strlcpy(gInstallTimestamp, timestamp, sizeof(gInstallTimestamp));

    char line[kBreadcrumbLength];
    snprintf(line, sizeof(line), "%s %s", timestamp, message);
    AppendBreadcrumbLine(line);
    NSLog(@"%s", message);
}

void RoonVisLog(NSString *format, ...)
{
    va_list args;
    va_start(args, format);
    NSString *message = [[[NSString alloc] initWithFormat:format arguments:args] autorelease];
    va_end(args);

    const char *utf8 = message.UTF8String;
    if (utf8 == nullptr)
    {
        utf8 = "(non-UTF8 log message)";
    }
    RoonVisLogC(utf8);
}

void RoonVisInstallCrashReporter(void)
{
    FormatTimestamp(gInstallTimestamp, sizeof(gInstallTimestamp));
    PrecomputeMainImageInfo();

    NSString *directory = CrashReportsDirectory();
    [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];

    NSArray<NSString *> *dumps = CrashDumpFiles(directory);
    NSString *latestDump = dumps.lastObject;
    NSLog(@"RoonVis crash reports dir: %@ (%lu dump%@)",
          directory,
          static_cast<unsigned long>(dumps.count),
          dumps.count == 1 ? @"" : @"s");
    if (latestDump.length > 0)
    {
        NSLog(@"PREVIOUS RUN CRASHED - see %@", latestDump);
    }

    time_t unixTime = time(nullptr);
    NSString *path = [directory stringByAppendingPathComponent:[NSString stringWithFormat:@"crash-%lld.log", static_cast<long long>(unixTime)]];
    strlcpy(gCrashPath, path.fileSystemRepresentation, sizeof(gCrashPath));
    gCrashFd = open(gCrashPath, O_CREAT | O_TRUNC | O_WRONLY | O_CLOEXEC, 0644);
    if (gCrashFd >= 0)
    {
        dprintf(gCrashFd, "RoonVis crash dump initialized at %s\n%s\n", gInstallTimestamp, gMainImageInfo);
    }
    else
    {
        NSLog(@"RoonVis crash reporter failed to open %@", path);
    }

    RoonVisLog(@"App launch: crash reporter installed; reports dir=%@ existing_dumps=%lu",
               directory,
               static_cast<unsigned long>(dumps.count));

    NSSetUncaughtExceptionHandler(&ExceptionHandler);
    signal(SIGPIPE, SIG_IGN);
    signal(SIGSEGV, SignalHandler);
    signal(SIGABRT, SignalHandler);
    signal(SIGBUS, SignalHandler);
    signal(SIGILL, SignalHandler);
    signal(SIGFPE, SignalHandler);
    signal(SIGTRAP, SignalHandler);
}
