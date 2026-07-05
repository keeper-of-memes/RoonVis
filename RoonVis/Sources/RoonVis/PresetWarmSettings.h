#pragma once

#import <Foundation/Foundation.h>

#import "PresetWarmCache.h"

// Runtime readers for the preset warm-cache configuration (env vars / NSUserDefaults),
// extracted from ANGLEGLView.mm. Warm cache default-ON, idle-frame strategy. The warm
// target is always the single primary preload slot (projectm_preload_preset_file).
BOOL RoonVisPresetWarmCacheEnabledSetting(void);
RoonVis::PresetWarmStrategy RoonVisPresetWarmStrategySetting(void);
