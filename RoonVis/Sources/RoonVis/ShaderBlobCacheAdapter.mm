#import "ShaderBlobCacheAdapter.h"

#import "RoonVisCrashReporter.h"

#include "ShaderBlobStore.h"

#import <EGL/eglext.h>

#include <atomic>
#include <cstring>
#include <thread>

#include <pthread/qos.h>

// The EGL blob callbacks carry no user parameter, so the process-lifetime singleton's
// store is reached through this file-static pointer. It is set BEFORE
// eglSetBlobCacheFuncsANDROID is called (callbacks may fire immediately afterwards,
// on ANGLE worker threads or the GL thread) and never cleared while EGL is live.
static RoonVis::ShaderBlobStore *gBlobStore = nullptr;

// EGLSetBlobFuncANDROID: memcpy into the store's bounded queue only — SQLite work
// happens on the writer thread (never inline on ANGLE/GL threads).
static void RoonVisShaderBlobCacheSet(const void *key, EGLsizeiANDROID keySize,
                                      const void *value, EGLsizeiANDROID valueSize)
{
    if (gBlobStore == nullptr || key == nullptr || keySize <= 0 || value == nullptr ||
        valueSize <= 0)
    {
        return;
    }
    gBlobStore->EnqueuePut(key, static_cast<size_t>(keySize), value,
                           static_cast<size_t>(valueSize));
}

// EGLGetBlobFuncANDROID: ANGLE calls this twice — a size probe (value == nullptr) then
// a fill that must observe the exact probed size. The store pins the value at probe and
// consumes the pin at fill, so the pair is byte-stable against concurrent
// eviction/replacement.
static EGLsizeiANDROID RoonVisShaderBlobCacheGet(const void *key, EGLsizeiANDROID keySize,
                                                 void *value, EGLsizeiANDROID valueSize)
{
    if (gBlobStore == nullptr || key == nullptr || keySize <= 0)
    {
        return 0;
    }
    if (value == nullptr)
    {
        return static_cast<EGLsizeiANDROID>(
            gBlobStore->GetProbe(key, static_cast<size_t>(keySize)));
    }
    if (valueSize <= 0)
    {
        return 0;
    }
    size_t filledSize = 0;
    if (!gBlobStore->GetFill(key, static_cast<size_t>(keySize), value,
                             static_cast<size_t>(valueSize), &filledSize))
    {
        return 0;  // ANGLE sees a size mismatch and treats it as a miss
    }
    return static_cast<EGLsizeiANDROID>(filledSize);
}

@interface ShaderBlobCacheAdapter ()
- (RoonVis::ShaderBlobStore *)store;
@end

@implementation ShaderBlobCacheAdapter
{
    RoonVis::ShaderBlobStore *_store;
    std::thread _writerThread;
    std::atomic<bool> _writerRunning;
}

- (instancetype)init
{
    self = [super init];
    if (self == nil)
    {
        return nil;
    }

    _store = new RoonVis::ShaderBlobStore();

    NSString *cachesDir =
        NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    NSString *storeDir = [cachesDir stringByAppendingPathComponent:@"shader-blob-cache"];
    [[NSFileManager defaultManager] createDirectoryAtPath:storeDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];
    NSString *dbPath = [storeDir stringByAppendingPathComponent:@"blobs.sqlite"];
    if (!_store->Open(dbPath.UTF8String))
    {
        RoonVisLog(@"ShaderBlobCache: failed to open %@ (recreate also failed); disabled", dbPath);
        delete _store;
        _store = nullptr;
        [self release];
        return nil;
    }
    RoonVisLog(@"ShaderBlobCache: opened %@ generation=%s", dbPath, _store->Generation().c_str());

    // Dedicated low-QoS writer: drains queued puts into SQLite off the ANGLE/GL threads.
    _writerRunning.store(true, std::memory_order_relaxed);
    RoonVis::ShaderBlobStore *store = _store;
    std::atomic<bool> *running = &_writerRunning;
    _writerThread = std::thread([store, running] {
        pthread_set_qos_class_self_np(QOS_CLASS_UTILITY, 0);
        while (running->load(std::memory_order_relaxed))
        {
            if (store->WaitForWork(/*timeoutMs=*/500))
            {
                @autoreleasepool
                {
                    store->DrainOnce();
                }
            }
        }
    });
    return self;
}

- (void)dealloc
{
    // Clean shutdown: stop + join the writer, then a final drain so queued puts land.
    // (The registered singleton lives for the process; this path matters for tests and
    // for the failed-registration case.)
    _writerRunning.store(false, std::memory_order_relaxed);
    if (_store != nullptr)
    {
        _store->NotifyShutdown();
    }
    if (_writerThread.joinable())
    {
        _writerThread.join();
    }
    if (_store != nullptr)
    {
        _store->DrainOnce();
        if (gBlobStore == _store)
        {
            gBlobStore = nullptr;
        }
        delete _store;
        _store = nullptr;
    }
    [super dealloc];
}

- (RoonVis::ShaderBlobStore *)store
{
    return _store;
}

+ (BOOL)registerWithEGLDisplayOnce:(EGLDisplay)dpy
{
    static BOOL registered = NO;
    static dispatch_once_t onceToken;
    // At most one eglSetBlobCacheFuncsANDROID call per process: setupEGL partially
    // re-runs on surface recreation and a second call is an EGL_BAD_PARAMETER error.
    dispatch_once(&onceToken, ^{
        registered = [self registerBlobCacheFuncsWithDisplay:dpy];
    });
    return registered;
}

// Runs exactly once (under the dispatch_once above).
+ (BOOL)registerBlobCacheFuncsWithDisplay:(EGLDisplay)dpy
{
    // Kill switch, read ONCE at registration (init-time defaults read; the file is in
    // scripts/guardrail-allowlist.txt). Default ON.
    NSNumber *enabledValue =
        [[NSUserDefaults standardUserDefaults] objectForKey:@"RoonVisShaderBlobCacheEnabled"];
    const BOOL enabled = enabledValue != nil ? enabledValue.boolValue : YES;
    if (!enabled)
    {
        RoonVisLog(@"ShaderBlobCache: disabled by RoonVisShaderBlobCacheEnabled=NO");
        return NO;
    }

    if (dpy == EGL_NO_DISPLAY)
    {
        RoonVisLog(@"ShaderBlobCache: no EGLDisplay; not registering");
        return NO;
    }
    const char *extensions = eglQueryString(dpy, EGL_EXTENSIONS);
    if (extensions == nullptr || std::strstr(extensions, "EGL_ANDROID_blob_cache") == nullptr)
    {
        RoonVisLog(@"ShaderBlobCache: EGL_ANDROID_blob_cache unavailable; not registering");
        return NO;
    }

    ShaderBlobCacheAdapter *adapter = [[ShaderBlobCacheAdapter alloc] init];
    if (adapter == nil)
    {
        return NO;  // store open failed (already logged); stays off for this process
    }
    // Intentionally retained for the life of the process: ANGLE holds the raw callback
    // pointers and there is no EGL API to unregister them.
    gBlobStore = [adapter store];

    eglSetBlobCacheFuncsANDROID(dpy, &RoonVisShaderBlobCacheSet, &RoonVisShaderBlobCacheGet);
    const EGLint error = eglGetError();
    if (error != EGL_SUCCESS)
    {
        RoonVisLog(@"ShaderBlobCache: eglSetBlobCacheFuncsANDROID failed: 0x%04x", error);
        gBlobStore = nullptr;
        [adapter release];
        return NO;
    }
    RoonVisLog(@"ShaderBlobCache: registered EGL_ANDROID_blob_cache callbacks");
    return YES;
}

@end
