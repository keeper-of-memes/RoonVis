#import "LegacyNameMigrationSupport.h"

#import "RoonVisCrashReporter.h"

#include "LegacyNameMigration.h"

#include <map>
#include <set>
#include <string>

namespace
{

// One-shot guard: set after a successful migration pass.
NSString *const kMigrationAppliedKey = @"RoonVisLegacyNameMigrationApplied";

// Store keys mirrored from their owners (same keys, same persisted formats):
// favourites/hidden — RoonVisSettings.mm (NSArray of basename strings);
// learned-slow confirmed + pending counts — ProjectMBridge+Warm.mm
// (NSArray of basenames / NSDictionary basename -> count).
NSString *const kFavoritePresetFilenamesKey = @"favoritePresetFilenames";
NSString *const kHiddenPresetFilenamesKey = @"hiddenPresetFilenames";
NSString *const kLearnedSlowPresetsKey = @"RoonVisLearnedSlowPresets";
NSString *const kLearnedSlowPendingCountsKey = @"RoonVisSlowPresetPendingCounts";

std::set<std::string> NameSetFromDefaultsArray(NSArray *array)
{
    std::set<std::string> names;
    for (id item in array)
    {
        if (![item isKindOfClass:NSString.class])
        {
            continue;
        }
        const char *cname = [(NSString *)item fileSystemRepresentation];
        if (cname != nullptr && cname[0] != '\0')
        {
            names.insert(cname);
        }
    }
    return names;
}

NSArray<NSString *> *SortedArrayFromNameSet(const std::set<std::string> &names)
{
    NSMutableArray<NSString *> *array = [NSMutableArray arrayWithCapacity:names.size()];
    for (const std::string &name : names)
    {
        NSString *value = [NSString stringWithUTF8String:name.c_str()];
        if (value != nil)
        {
            [array addObject:value];
        }
    }
    // Match RoonVisSettings' SortedFilenameArrayFromSet persisted ordering.
    return [array sortedArrayUsingSelector:@selector(compare:)];
}

RoonVis::MigratedNameSet MigrateArrayStore(NSUserDefaults *defaults,
                                           NSString *key,
                                           const std::map<std::string, std::string> &nameMap)
{
    RoonVis::MigratedNameSet result =
        RoonVis::MigrateNameSet(NameSetFromDefaultsArray([defaults arrayForKey:key]), nameMap);
    if (result.mappedCount > 0 || result.droppedCount > 0)
    {
        [defaults setObject:SortedArrayFromNameSet(result.names) forKey:key];
    }
    return result;
}

}  // namespace

void RoonVisApplyLegacyNameMigrationIfNeeded(void)
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults boolForKey:kMigrationAppliedKey])
    {
        return;
    }

    NSString *path = [NSBundle.mainBundle pathForResource:@"LegacyNameMap" ofType:@"json"];
    NSData *data = path.length > 0 ? [NSData dataWithContentsOfFile:path] : nil;
    std::map<std::string, std::string> nameMap;
    if (data.length > 0)
    {
        nameMap = RoonVis::ParseLegacyNameMapJSON(
            std::string(static_cast<const char *>(data.bytes), static_cast<size_t>(data.length)));
    }
    if (nameMap.empty())
    {
        // Leave the flag unset so a fixed bundle can still migrate on a later launch.
        RoonVisLog(@"Legacy name migration: LegacyNameMap.json missing or unparseable; skipping");
        return;
    }

    RoonVis::MigratedNameSet favorites =
        MigrateArrayStore(defaults, kFavoritePresetFilenamesKey, nameMap);
    RoonVis::MigratedNameSet hidden = MigrateArrayStore(defaults, kHiddenPresetFilenamesKey, nameMap);
    RoonVis::MigratedNameSet learnedSlow =
        MigrateArrayStore(defaults, kLearnedSlowPresetsKey, nameMap);

    std::map<std::string, int> pendingCounts;
    NSDictionary *storedCounts = [defaults dictionaryForKey:kLearnedSlowPendingCountsKey];
    for (id key in storedCounts)
    {
        if (![key isKindOfClass:NSString.class])
        {
            continue;
        }
        id value = storedCounts[key];
        if (![value isKindOfClass:NSNumber.class])
        {
            continue;
        }
        const char *cname = [(NSString *)key fileSystemRepresentation];
        if (cname != nullptr && cname[0] != '\0')
        {
            pendingCounts[cname] = [(NSNumber *)value intValue];
        }
    }
    RoonVis::MigratedNameCounts pending = RoonVis::MigrateNameCounts(pendingCounts, nameMap);
    if (pending.mappedCount > 0 || pending.droppedCount > 0)
    {
        NSMutableDictionary<NSString *, NSNumber *> *migratedCounts =
            [NSMutableDictionary dictionaryWithCapacity:pending.counts.size()];
        for (const auto &entry : pending.counts)
        {
            NSString *name = [NSString stringWithUTF8String:entry.first.c_str()];
            if (name != nil)
            {
                migratedCounts[name] = @(entry.second);
            }
        }
        [defaults setObject:migratedCounts forKey:kLearnedSlowPendingCountsKey];
    }

    [defaults setBool:YES forKey:kMigrationAppliedKey];
    [defaults synchronize];

    RoonVisLog(@"Legacy name migration applied (map=%zu): favorites mapped=%zu dropped=%zu, "
               @"hidden mapped=%zu dropped=%zu, learnedSlow mapped=%zu dropped=%zu, "
               @"pendingCounts mapped=%zu dropped=%zu",
               nameMap.size(),
               favorites.mappedCount, favorites.droppedCount,
               hidden.mappedCount, hidden.droppedCount,
               learnedSlow.mappedCount, learnedSlow.droppedCount,
               pending.mappedCount, pending.droppedCount);
}
