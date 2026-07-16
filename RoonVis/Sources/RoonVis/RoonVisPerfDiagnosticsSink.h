#pragma once

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

// Appends one line to the perf-diagnostics file sink
// (Library/Caches/perf-diagnostics.log, owned by ANGLEGLView+Diagnostics.mm).
// Forced write: bypasses the perf-diagnostics-enabled gate the same way the
// CompatBurnIn ground-truth lines do, so campaign-critical breadcrumbs
// (FixedRotation resolve, Thermal state) from other translation units always
// reach the on-device log that campaign harnesses pull. Main/GL thread only
// (the sink's FILE* is unlocked; all existing writers are on that thread).
void RoonVisPerfDiagnosticsSinkAppendLine(NSString *line);

#ifdef __cplusplus
}
#endif
