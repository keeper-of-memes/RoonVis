#pragma once

#import <Foundation/Foundation.h>

#import <EGL/egl.h>

// Tier-2 EGL_ANDROID_blob_cache adapter: owns the SQLite-backed ShaderBlobStore and its
// dedicated low-QoS writer thread, and exposes the EGL blob callbacks. Registering the
// callbacks makes ANGLE route blob get/put EXCLUSIVELY to the app (its internal LRU and
// in-process program cache stop being consulted), so the store carries its own
// in-memory front cache.
//
// Threading: the EGL callbacks may fire on ANGLE worker threads AND the GL thread; the
// underlying store is fully thread-safe and puts never touch SQLite inline (they are
// queued and drained on the writer thread).
@interface ShaderBlobCacheAdapter : NSObject

// Registers the blob callbacks with `dpy` at most once per process (a second
// eglSetBlobCacheFuncsANDROID call is an EGL error; setupEGL partially re-runs on
// surface recreation). Safe to call repeatedly — subsequent calls are no-ops.
// Returns YES if the callbacks are registered (now or by an earlier call). NO when the
// RoonVisShaderBlobCacheEnabled kill switch is off (read once here, at registration),
// the display extension is unavailable, or the backing store failed to open.
+ (BOOL)registerWithEGLDisplayOnce:(EGLDisplay)dpy;

@end
