#import "ProjectMPresetSupport.h"

#import "RoonVisCrashReporter.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>

@implementation RoonVisPresetShelf

- (instancetype)initWithTitle:(NSString *)title presetIndexes:(NSArray<NSNumber *> *)presetIndexes
{
    self = [super init];
    if (self)
    {
        _title = [title copy];
        _presetIndexes = [presetIndexes copy];
    }
    return self;
}

- (void)dealloc
{
    [_title release];
    [_presetIndexes release];
    [super dealloc];
}

@end

namespace
{
static NSString *RoonVisTrimmedPresetTitle(NSString *title)
{
    NSString *withoutExtension = [title stringByDeletingPathExtension];
    NSCharacterSet *trimSet = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    return [withoutExtension stringByTrimmingCharactersInSet:trimSet];
}

static BOOL RoonVisPresetTitleNeedsFallback(NSString *title)
{
    NSString *trimmed = RoonVisTrimmedPresetTitle(title);
    if (trimmed.length == 0)
    {
        return YES;
    }

    NSCharacterSet *letters = [NSCharacterSet letterCharacterSet];
    NSCharacterSet *digits = [NSCharacterSet decimalDigitCharacterSet];
    NSUInteger letterCount = 0;
    NSUInteger digitCount = 0;
    NSUInteger visibleCount = 0;
    for (NSUInteger i = 0; i < trimmed.length; i++)
    {
        unichar character = [trimmed characterAtIndex:i];
        if ([[NSCharacterSet whitespaceAndNewlineCharacterSet] characterIsMember:character])
        {
            continue;
        }
        visibleCount++;
        if ([letters characterIsMember:character])
        {
            letterCount++;
        }
        else if ([digits characterIsMember:character])
        {
            digitCount++;
        }
    }

    if (letterCount == 0)
    {
        return YES;
    }
    if (visibleCount <= 4 && digitCount > 0)
    {
        return YES;
    }
    if (digitCount >= letterCount * 2 && visibleCount <= 10)
    {
        return YES;
    }
    return NO;
}

NSSet<NSString *> *RoonVisRuntimeExtraCrashBlocklist()
{
    static NSSet *blocklist = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *raw = [[NSUserDefaults standardUserDefaults] stringForKey:@"RoonVisExtraCrashBlocklist"];
        NSMutableSet *set = [NSMutableSet set];
        for (NSString *name in [raw componentsSeparatedByString:@","])
        {
            NSString *trimmed = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (trimmed.length > 0)
            {
                [set addObject:trimmed];
            }
        }
        blocklist = [set copy];
    });
    return blocklist;
}
}  // namespace

NSString *RoonVisHumanPresetTitle(NSString *title, NSUInteger index)
{
    if (RoonVisPresetTitleNeedsFallback(title))
    {
        return [NSString stringWithFormat:@"Visualizer %lu", static_cast<unsigned long>(index + 1)];
    }
    return RoonVisTrimmedPresetTitle(title);
}

std::string RoonVisNSStringToUTF8(NSString *string)
{
    const char *utf8 = string.UTF8String;
    return utf8 != nullptr ? std::string(utf8) : std::string();
}

std::string RoonVisPresetFilenameKey(NSString *filename)
{
    if (filename.length == 0 || filename.fileSystemRepresentation == nullptr)
    {
        return {};
    }
    return filename.fileSystemRepresentation;
}

const RoonVis::PresetBlocklists &RoonVisBundlePresetBlocklists()
{
    static RoonVis::PresetBlocklists *blocklists = nullptr;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        blocklists = new RoonVis::PresetBlocklists;
        NSString *path = [NSBundle.mainBundle pathForResource:@"PresetBlocklist" ofType:@"json"];
        NSData *data = path.length > 0 ? [NSData dataWithContentsOfFile:path] : nil;
        const char *bytes = static_cast<const char *>(data.bytes);
        if (data.length > 0 && RoonVis::ParsePresetBlocklistJSON(bytes, data.length, *blocklists))
        {
            RoonVisLog(@"ProjectM hardening: loaded preset blocklists from bundle (%zu slow, %zu crashing, %zu static-heavy)",
                       blocklists->slow.size(),
                       blocklists->crashing.size(),
                       blocklists->staticHeavy.size());
        }
        else
        {
            *blocklists = RoonVis::DefaultPresetBlocklists();
            RoonVisLog(@"ProjectM hardening: using compiled preset blocklist fallback (%zu slow, %zu crashing, %zu static-heavy)",
                       blocklists->slow.size(),
                       blocklists->crashing.size(),
                       blocklists->staticHeavy.size());
        }
    });
    return *blocklists;
}

bool RoonVisIsKnownSlowPresetFilename(NSString *filename)
{
    return RoonVis::IsSlowPreset(RoonVisBundlePresetBlocklists(), RoonVisPresetFilenameKey(filename));
}

bool RoonVisIsKnownCrashingPresetFilename(NSString *filename)
{
    if (filename.length == 0)
    {
        return false;
    }

    std::string fileSystemName = RoonVisPresetFilenameKey(filename);
    if (RoonVis::IsCrashingPreset(RoonVisBundlePresetBlocklists(), fileSystemName))
    {
        return true;
    }
    return [RoonVisRuntimeExtraCrashBlocklist() containsObject:filename];
}

bool RoonVisIsStaticHeavyPresetFilename(NSString *filename)
{
    if (filename.length == 0)
    {
        return false;
    }

    return RoonVis::IsStaticHeavyPreset(RoonVisBundlePresetBlocklists(), RoonVisPresetFilenameKey(filename));
}

bool RoonVisLoadPCM16Wav(NSString *path, RoonVis::WavData &wav)
{
    NSData *data = [NSData dataWithContentsOfFile:path];
    const uint8_t *bytes = static_cast<const uint8_t *>(data.bytes);
    return RoonVis::ParsePCM16Wav(bytes, data.length, wav);
}

int16_t RoonVisScalePCM16Sample(int16_t sample, double gain)
{
    if (gain == 1.0)
    {
        return sample;
    }

    long scaled = std::lround(static_cast<double>(sample) * gain);
    scaled = std::max<long>(std::numeric_limits<int16_t>::min(), std::min<long>(std::numeric_limits<int16_t>::max(), scaled));
    return static_cast<int16_t>(scaled);
}

BOOL RoonVisShouldSkipPresetThumbnail(NSString *presetFilename)
{
    return RoonVisIsKnownSlowPresetFilename(presetFilename) ||
           RoonVisIsKnownCrashingPresetFilename(presetFilename) ||
           RoonVisIsStaticHeavyPresetFilename(presetFilename);
}
