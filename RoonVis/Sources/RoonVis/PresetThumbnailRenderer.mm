#import "PresetThumbnailRenderer.h"

#import "ProjectMBridge.h"
#import "RoonVisCrashReporter.h"
#import "RoonVisEGLContext.h"
#import "RoonVisPerfCounters.h"
#import "SnapPCM.h"

#import <CommonCrypto/CommonDigest.h>
#import <EGL/egl.h>
#import <EGL/eglext.h>
#import <GLES3/gl3.h>
#import <projectM-4/projectM.h>

#include <algorithm>
#include <cstdint>
#include <string>
#include <vector>

namespace
{
static constexpr GLsizei kThumbnailWidth = 480;
static constexpr GLsizei kThumbnailHeight = 270;
static constexpr unsigned int kThumbnailFPS = 60;
// Render the preset at full speed for a fixed wall-clock duration (like live
// playback), feeding audio continuously and letting projectM use its own timer, then
// snapshot. Milkdrop presets are feedback/decay-based — they start black and build up
// over real time — so ~5s of development yields a representative still regardless of
// how fast/slow the GPU is. kThumbnailMaxFrames caps the pathological slow-frame case.
static constexpr double kThumbnailDurationSeconds = 5.0;
static constexpr unsigned int kThumbnailMaxFrames = 3000;
static constexpr size_t kThumbnailMeshWidth = 24;
static constexpr size_t kThumbnailMeshHeight = 18;
// The bundled fallback audio is gentle; presets react to bass/mid/treb magnitude, so
// drive them hard (near full-scale) to produce a lively, representative still.
static constexpr double kThumbnailAudioGain = 6.0;
static NSString *const kThumbnailCacheVersion = @"v2";

static void *ThumbnailProjectMGLLoadProc(const char *name, void *)
{
    return reinterpret_cast<void *>(eglGetProcAddress(name));
}

static NSString *ThumbnailCacheDirectory()
{
    NSArray<NSString *> *directories = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString *caches = directories.count > 0 ? directories[0] : NSTemporaryDirectory();
    return [caches stringByAppendingPathComponent:@"PresetThumbnails"];
}

static NSString *SHA1HexString(NSString *string)
{
    const char *utf8 = string.UTF8String;
    if (utf8 == nullptr)
    {
        utf8 = "";
    }

    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(utf8, static_cast<CC_LONG>(strlen(utf8)), digest);

    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
    for (size_t index = 0; index < CC_SHA1_DIGEST_LENGTH; index++)
    {
        [hex appendFormat:@"%02x", digest[index]];
    }
    return hex;
}

static NSString *ThumbnailCachePathForPresetPath(NSString *path)
{
    NSString *filename = path.lastPathComponent ?: @"";
    NSString *basename = [NSString stringWithFormat:@"%@-%@.png", SHA1HexString(filename), kThumbnailCacheVersion];
    return [ThumbnailCacheDirectory() stringByAppendingPathComponent:basename];
}

static BOOL LoadThumbnailWAV(RoonVis::WavData &wav)
{
    NSString *audioPath = [NSBundle.mainBundle pathForResource:@"TestAudio" ofType:@"wav"];
    NSData *data = [NSData dataWithContentsOfFile:audioPath];
    if (data.length == 0)
    {
        return NO;
    }
    const uint8_t *bytes = static_cast<const uint8_t *>(data.bytes);
    if (!(RoonVis::ParsePCM16Wav(bytes, data.length, wav) && wav.channels == 2 && wav.frameCount() > 0))
    {
        return NO;
    }
    for (int16_t &sample : wav.samples)
    {
        const double amplified = static_cast<double>(sample) * kThumbnailAudioGain;
        sample = static_cast<int16_t>(std::max(-32768.0, std::min(32767.0, amplified)));
    }
    return YES;
}

static UIImage *ImageFromGLRGBABottomLeftPixels(const std::vector<uint8_t> &pixels, GLsizei width, GLsizei height)
{
    if (pixels.empty() || width <= 0 || height <= 0)
    {
        return nil;
    }

    const size_t rowBytes = static_cast<size_t>(width) * 4;
    std::vector<uint8_t> flipped(pixels.size());
    for (GLsizei y = 0; y < height; y++)
    {
        const uint8_t *src = pixels.data() + (static_cast<size_t>(height - 1 - y) * rowBytes);
        uint8_t *dst = flipped.data() + (static_cast<size_t>(y) * rowBytes);
        std::copy(src, src + rowBytes, dst);
    }

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    if (colorSpace == nullptr)
    {
        return nil;
    }
    CGContextRef context = CGBitmapContextCreate(flipped.data(),
                                                 static_cast<size_t>(width),
                                                 static_cast<size_t>(height),
                                                 8,
                                                 rowBytes,
                                                 colorSpace,
                                                 static_cast<CGBitmapInfo>(kCGBitmapByteOrder32Big) | kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(colorSpace);
    if (context == nullptr)
    {
        return nil;
    }

    CGImageRef cgImage = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    if (cgImage == nullptr)
    {
        return nil;
    }

    UIImage *image = [UIImage imageWithCGImage:cgImage scale:1.0 orientation:UIImageOrientationUp];
    CGImageRelease(cgImage);
    return image;
}
}  // namespace

@interface PresetThumbnailRenderer ()
- (UIImage *)cachedImageForPresetPath:(NSString *)path;
- (UIImage *)renderThumbnailForPresetPath:(NSString *)path;
- (BOOL)ensureRenderer;
- (BOOL)ensureFramebuffer;
- (void)destroyRenderer;
@end

@implementation PresetThumbnailRenderer
{
    dispatch_queue_t _queue;
    EGLDisplay _eglDisplay;
    EGLSurface _eglSurface;
    EGLContext _eglContext;
    EGLConfig _eglConfig;
    projectm_handle _projectM;
    GLuint _framebuffer;
    GLuint _colorRenderbuffer;
    RoonVis::WavData _wav;
}

+ (instancetype)sharedRenderer
{
    static PresetThumbnailRenderer *renderer = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        renderer = [[PresetThumbnailRenderer alloc] init];
    });
    return renderer;
}

- (instancetype)init
{
    self = [super init];
    if (self)
    {
        _queue = dispatch_queue_create("local.roon-vis.preset-thumbnails", DISPATCH_QUEUE_SERIAL);
        _eglDisplay = EGL_NO_DISPLAY;
        _eglSurface = EGL_NO_SURFACE;
        _eglContext = EGL_NO_CONTEXT;
        _eglConfig = nullptr;
    }
    return self;
}

- (void)thumbnailForPresetPath:(NSString *)path completion:(void (^)(UIImage *image))completion
{
    if (completion == nil)
    {
        return;
    }

    if (path.length == 0 || RoonVisShouldSkipPresetThumbnail(path.lastPathComponent))
    {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(nil);
        });
        return;
    }

    NSString *presetPath = [path copy];
    void (^completionCopy)(UIImage *) = [completion copy];
    dispatch_async(_queue, ^{
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        UIImage *image = [self cachedImageForPresetPath:presetPath];
        if (image == nil)
        {
            image = [self renderThumbnailForPresetPath:presetPath];
        }
        UIImage *result = [image retain];
        dispatch_async(dispatch_get_main_queue(), ^{
            completionCopy(result);
            [result release];
            [completionCopy release];
            [presetPath release];
        });
        [pool drain];
    });
}

- (UIImage *)cachedImageForPresetPath:(NSString *)path
{
    BOOL perfCountersEnabled = RoonVisPerfCountersEnabled();
    // Prefer a thumbnail bundled with the app (pre-rendered on the sim, keyed by the
    // same sha1(filename)-v<N> scheme under Resources/PresetThumbnails). This makes the
    // grid populate instantly on first launch with no on-device generation.
    NSString *filename = path.lastPathComponent ?: @"";
    NSString *basename = [NSString stringWithFormat:@"%@-%@", SHA1HexString(filename), kThumbnailCacheVersion];
    NSString *bundled = [NSBundle.mainBundle pathForResource:basename ofType:@"png" inDirectory:@"PresetThumbnails"];
    if (bundled.length > 0)
    {
        UIImage *bundledImage = [UIImage imageWithContentsOfFile:bundled];
        if (bundledImage != nil)
        {
            if (perfCountersEnabled)
            {
                RoonVisPerfCountThumbnail(RoonVisPerfThumbnailOutcomeBundleHit, 0.0);
            }
            return bundledImage;
        }
    }

    NSString *cachePath = ThumbnailCachePathForPresetPath(path);
    if (![[NSFileManager defaultManager] fileExistsAtPath:cachePath])
    {
        return nil;
    }
    UIImage *cachedImage = [UIImage imageWithContentsOfFile:cachePath];
    if (cachedImage != nil && perfCountersEnabled)
    {
        RoonVisPerfCountThumbnail(RoonVisPerfThumbnailOutcomeDiskHit, 0.0);
    }
    return cachedImage;
}

- (BOOL)ensureRenderer
{
    if (_projectM != nullptr)
    {
        return YES;
    }

    if (!LoadThumbnailWAV(_wav))
    {
        RoonVisLog(@"Preset thumbnails: fallback WAV unavailable");
        return NO;
    }

    _eglDisplay = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (_eglDisplay == EGL_NO_DISPLAY)
    {
        RoonVisLog(@"Preset thumbnails: eglGetDisplay failed 0x%04x", eglGetError());
        return NO;
    }

    EGLint major = 0;
    EGLint minor = 0;
    if (!eglInitialize(_eglDisplay, &major, &minor))
    {
        RoonVisLog(@"Preset thumbnails: eglInitialize failed 0x%04x", eglGetError());
        return NO;
    }

    EGLint configCount = 0;
    if (!RoonVisChooseEGLConfig(_eglDisplay, EGL_PBUFFER_BIT, &_eglConfig, &configCount))
    {
        RoonVisLog(@"Preset thumbnails: eglChooseConfig failed 0x%04x count=%d", eglGetError(), configCount);
        return NO;
    }

    EGLint pbufferAttributes[] = {
        EGL_WIDTH, kThumbnailWidth,
        EGL_HEIGHT, kThumbnailHeight,
        EGL_NONE,
    };
    _eglSurface = eglCreatePbufferSurface(_eglDisplay, _eglConfig, pbufferAttributes);
    if (_eglSurface == EGL_NO_SURFACE)
    {
        RoonVisLog(@"Preset thumbnails: eglCreatePbufferSurface failed 0x%04x", eglGetError());
        return NO;
    }

    EGLint contextAttributes[] = {
        EGL_CONTEXT_CLIENT_VERSION, 3,
        EGL_NONE,
    };
    _eglContext = eglCreateContext(_eglDisplay, _eglConfig, EGL_NO_CONTEXT, contextAttributes);
    if (_eglContext == EGL_NO_CONTEXT)
    {
        RoonVisLog(@"Preset thumbnails: eglCreateContext failed 0x%04x", eglGetError());
        return NO;
    }

    if (!eglMakeCurrent(_eglDisplay, _eglSurface, _eglSurface, _eglContext))
    {
        RoonVisLog(@"Preset thumbnails: eglMakeCurrent failed 0x%04x", eglGetError());
        return NO;
    }

    if (![self ensureFramebuffer])
    {
        return NO;
    }

    setenv("PROJECTM_GLRESOLVER_STRICT_CONTEXT_GATE", "0", 1);
    _projectM = projectm_create_with_opengl_load_proc(ThumbnailProjectMGLLoadProc, nullptr);
    if (_projectM == nullptr)
    {
        RoonVisLog(@"Preset thumbnails: projectm_create failed");
        return NO;
    }

    NSString *resourcePath = NSBundle.mainBundle.resourcePath;
    NSString *texturesPath = [resourcePath stringByAppendingPathComponent:@"textures"];
    const char *texturePaths[] = {
        texturesPath.fileSystemRepresentation,
        resourcePath.fileSystemRepresentation,
    };
    projectm_set_texture_search_paths(_projectM, texturePaths, 2);
    projectm_set_mesh_size(_projectM, kThumbnailMeshWidth, kThumbnailMeshHeight);
    projectm_set_fps(_projectM, kThumbnailFPS);
    projectm_set_window_size(_projectM, kThumbnailWidth, kThumbnailHeight);
    RoonVisLog(@"Preset thumbnails: EGL %d.%d renderer=%s", major, minor, glGetString(GL_RENDERER));
    return YES;
}

- (BOOL)ensureFramebuffer
{
    if (_framebuffer != 0 && _colorRenderbuffer != 0)
    {
        return YES;
    }

    glGenFramebuffers(1, &_framebuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, _framebuffer);
    glGenRenderbuffers(1, &_colorRenderbuffer);
    glBindRenderbuffer(GL_RENDERBUFFER, _colorRenderbuffer);
    glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8, kThumbnailWidth, kThumbnailHeight);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, _colorRenderbuffer);
    GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    if (status != GL_FRAMEBUFFER_COMPLETE)
    {
        RoonVisLog(@"Preset thumbnails: FBO incomplete 0x%04x", status);
        return NO;
    }
    return YES;
}

- (UIImage *)renderThumbnailForPresetPath:(NSString *)path
{
    BOOL perfCountersEnabled = RoonVisPerfCountersEnabled();
    CFAbsoluteTime liveRenderStart = perfCountersEnabled ? CFAbsoluteTimeGetCurrent() : 0;
    if (![self ensureRenderer])
    {
        [self destroyRenderer];
        return nil;
    }
    if (!eglMakeCurrent(_eglDisplay, _eglSurface, _eglSurface, _eglContext))
    {
        RoonVisLog(@"Preset thumbnails: eglMakeCurrent render failed 0x%04x", eglGetError());
        [self destroyRenderer];
        return nil;
    }

    glBindFramebuffer(GL_FRAMEBUFFER, _framebuffer);
    glViewport(0, 0, kThumbnailWidth, kThumbnailHeight);
    glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);

    projectm_load_preset_file(_projectM, path.fileSystemRepresentation, false);

    size_t wavOffset = 0;
    const size_t framesPerAudioTick = std::max<size_t>(1, _wav.sampleRate / kThumbnailFPS);
    const unsigned int maxFramesPerCall = std::max(1u, projectm_pcm_get_max_samples());
    const CFAbsoluteTime renderStart = CFAbsoluteTimeGetCurrent();
    unsigned int frames = 0;
    while (CFAbsoluteTimeGetCurrent() - renderStart < kThumbnailDurationSeconds && frames < kThumbnailMaxFrames)
    {
        frames++;
        size_t framesRemaining = framesPerAudioTick;
        while (framesRemaining > 0)
        {
            size_t framesUntilLoop = _wav.frameCount() - wavOffset;
            size_t chunkFrames = std::min(framesRemaining, framesUntilLoop);
            chunkFrames = std::min(chunkFrames, static_cast<size_t>(maxFramesPerCall));
            const int16_t *chunk = _wav.samples.data() + (wavOffset * _wav.channels);
            projectm_pcm_add_int16(_projectM, chunk, static_cast<unsigned int>(chunkFrames), PROJECTM_STEREO);
            wavOffset += chunkFrames;
            if (wavOffset >= _wav.frameCount())
            {
                wavOffset = 0;
            }
            framesRemaining -= chunkFrames;
        }
        // No projectm_set_frame_time: let projectM advance on its own system timer so
        // the preset animates at real time, exactly like live playback.
        projectm_opengl_render_frame_fbo(_projectM, _framebuffer);
    }

    std::vector<uint8_t> pixels(static_cast<size_t>(kThumbnailWidth) * static_cast<size_t>(kThumbnailHeight) * 4);
    glReadPixels(0, 0, kThumbnailWidth, kThumbnailHeight, GL_RGBA, GL_UNSIGNED_BYTE, pixels.data());
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    glFinish();

    GLenum error = glGetError();
    if (error != GL_NO_ERROR)
    {
        RoonVisLog(@"Preset thumbnails: GL error 0x%04x for %@", error, path.lastPathComponent);
        return nil;
    }

    UIImage *image = ImageFromGLRGBABottomLeftPixels(pixels, kThumbnailWidth, kThumbnailHeight);
    if (image == nil)
    {
        return nil;
    }

    NSString *directory = ThumbnailCacheDirectory();
    NSError *directoryError = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:directory
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:&directoryError];
    if (directoryError != nil)
    {
        RoonVisLog(@"Preset thumbnails: cache directory error %@", directoryError.localizedDescription);
        if (perfCountersEnabled)
        {
            RoonVisPerfCountThumbnail(RoonVisPerfThumbnailOutcomeLiveRender,
                                      (CFAbsoluteTimeGetCurrent() - liveRenderStart) * 1000.0);
        }
        return image;
    }

    NSData *png = UIImagePNGRepresentation(image);
    NSString *cachePath = ThumbnailCachePathForPresetPath(path);
    if (png.length > 0 && ![png writeToFile:cachePath atomically:YES])
    {
        RoonVisLog(@"Preset thumbnails: failed to write %@", cachePath.lastPathComponent);
    }
    else
    {
        RoonVisLog(@"Preset thumbnails: rendered %@", path.lastPathComponent);
    }
    if (perfCountersEnabled)
    {
        RoonVisPerfCountThumbnail(RoonVisPerfThumbnailOutcomeLiveRender,
                                  (CFAbsoluteTimeGetCurrent() - liveRenderStart) * 1000.0);
    }
    return image;
}

- (void)destroyRenderer
{
    if (_eglDisplay != EGL_NO_DISPLAY)
    {
        BOOL hasCurrentContext = NO;
        if (_eglSurface != EGL_NO_SURFACE && _eglContext != EGL_NO_CONTEXT)
        {
            hasCurrentContext = eglMakeCurrent(_eglDisplay, _eglSurface, _eglSurface, _eglContext) ? YES : NO;
        }
        if (_framebuffer != 0)
        {
            if (hasCurrentContext)
            {
                glDeleteFramebuffers(1, &_framebuffer);
            }
            _framebuffer = 0;
        }
        if (_colorRenderbuffer != 0)
        {
            if (hasCurrentContext)
            {
                glDeleteRenderbuffers(1, &_colorRenderbuffer);
            }
            _colorRenderbuffer = 0;
        }
        if (_projectM != nullptr)
        {
            projectm_destroy(_projectM);
            _projectM = nullptr;
        }
        eglMakeCurrent(_eglDisplay, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        if (_eglSurface != EGL_NO_SURFACE)
        {
            eglDestroySurface(_eglDisplay, _eglSurface);
            _eglSurface = EGL_NO_SURFACE;
        }
        if (_eglContext != EGL_NO_CONTEXT)
        {
            eglDestroyContext(_eglDisplay, _eglContext);
            _eglContext = EGL_NO_CONTEXT;
        }
        _eglDisplay = EGL_NO_DISPLAY;
    }
    _eglConfig = nullptr;
}

- (void)dealloc
{
    if (_queue != nullptr)
    {
        dispatch_sync(_queue, ^{
            [self destroyRenderer];
        });
#if !OS_OBJECT_USE_OBJC
        dispatch_release(_queue);
#endif
    }
    [super dealloc];
}

@end
