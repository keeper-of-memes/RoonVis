#import "ProjectMBridge.h"
#import "PresetBlocklist.h"
#import "SnapPCM.h"

#include <string>

NS_ASSUME_NONNULL_BEGIN

@interface RoonVisPresetShelf (ProjectMPresetSupport)
- (instancetype)initWithTitle:(NSString *)title category:(nullable NSString *)category presetIndexes:(NSArray<NSNumber *> *)presetIndexes;
@end

NSString *RoonVisHumanPresetTitle(NSString *title, NSUInteger index);
std::string RoonVisNSStringToUTF8(NSString *string);
std::string RoonVisPresetFilenameKey(NSString *filename);
const RoonVis::PresetBlocklists &RoonVisBundlePresetBlocklists();
bool RoonVisIsKnownSlowPresetFilename(NSString *filename);
bool RoonVisIsKnownCrashingPresetFilename(NSString *filename);
bool RoonVisIsStaticHeavyPresetFilename(NSString *filename);
bool RoonVisLoadPCM16Wav(NSString *path, RoonVis::WavData &wav);
int16_t RoonVisScalePCM16Sample(int16_t sample, double gain);

NS_ASSUME_NONNULL_END
