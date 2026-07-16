#pragma once

#import <Foundation/Foundation.h>

// One-shot migration of persisted per-preset state (favourites, hidden, learned-slow
// confirmed, slow-pending counts) from the legacy flat-292 basenames to the CotC pack
// basenames, via the bundled LegacyNameMap.json. Guarded by the
// RoonVisLegacyNameMigrationApplied defaults flag; subsequent calls are no-ops.
// Must run BEFORE any preset enumeration / settings reads by ProjectMBridge.
void RoonVisApplyLegacyNameMigrationIfNeeded(void);
