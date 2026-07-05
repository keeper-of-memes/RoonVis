#import "PresetValidator.h"

// QA-only. The entire translation unit is compiled out of the shipping Release binary
// so its EGL/GLES/projectM validation stack contributes no symbols there.
#if ROONVIS_ENABLE_PRESET_VALIDATOR

#import <QuartzCore/CAMetalLayer.h>
#import <EGL/egl.h>
#import <EGL/eglext.h>
#import <GLES3/gl3.h>
#import <projectM-4/projectM.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <string>
#include <vector>

@interface PresetValidator ()
@property(nonatomic, assign) EGLDisplay eglDisplay;
@property(nonatomic, assign) EGLSurface eglSurface;
@property(nonatomic, assign) EGLContext eglContext;
@property(nonatomic, assign) EGLConfig eglConfig;
@property(nonatomic, assign) CGSize surfaceDrawableSize;
@property(nonatomic, assign) projectm_handle projectM;
@property(nonatomic, strong) CADisplayLink *displayLink;
@property(nonatomic, strong) NSArray<NSString *> *presetPaths;
@property(nonatomic, strong) NSMutableArray<NSString *> *reportLines;
@property(nonatomic, assign) NSInteger currentPresetIndex;
@property(nonatomic, assign) NSUInteger currentFrameCount;
@property(nonatomic, assign) BOOL currentCompileFailed;
@property(nonatomic, assign) BOOL currentGLErrorFailed;
@property(nonatomic, assign) double currentMaxMean;
@property(nonatomic, assign) double currentMaxDelta;
@property(nonatomic, assign) double previousMean;
@property(nonatomic, assign) NSUInteger passCount;
@property(nonatomic, assign) NSUInteger failCompileCount;
@property(nonatomic, assign) NSUInteger failGLErrorCount;
@property(nonatomic, assign) NSUInteger failBlackCount;
@property(nonatomic, assign) NSUInteger failStaticCount;
- (BOOL)setupEGL;
- (BOOL)setupProjectMWithDrawableSize:(CGSize)drawableSize;
- (BOOL)recreateSurfaceIfNeededForDrawableSize:(CGSize)drawableSize;
- (void)handlePresetSwitchFailed:(const char *)presetFilename message:(const char *)message;
@end

namespace
{
static constexpr NSUInteger kFramesPerPreset = 12;
static constexpr double kBlackThreshold = 2.0 / 255.0;
static constexpr double kStaticThreshold = 0.5 / 255.0;
static constexpr size_t kPCMFrames = 1024;

static void PresetSwitchFailedCallback(const char *presetFilename, const char *message, void *userData)
{
    PresetValidator *validator = static_cast<PresetValidator *>(userData);
    [validator handlePresetSwitchFailed:presetFilename message:message];
}
}  // namespace

@implementation PresetValidator
{
    std::vector<int16_t> _pcm;
    std::vector<uint8_t> _readPixels;
}

+ (Class)layerClass
{
    return [CAMetalLayer class];
}

- (instancetype)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (self)
    {
        self.backgroundColor = UIColor.blackColor;
        self.contentScaleFactor = UIScreen.mainScreen.scale;
        CAMetalLayer *metalLayer = (CAMetalLayer *)self.layer;
        metalLayer.opaque = YES;
        metalLayer.contentsScale = UIScreen.mainScreen.scale;
        metalLayer.drawableSize = CGSizeMake(CGRectGetWidth(frame) * UIScreen.mainScreen.scale,
                                             CGRectGetHeight(frame) * UIScreen.mainScreen.scale);

        self.eglDisplay = EGL_NO_DISPLAY;
        self.eglSurface = EGL_NO_SURFACE;
        self.eglContext = EGL_NO_CONTEXT;
        self.eglConfig = nullptr;
        self.surfaceDrawableSize = CGSizeZero;
        self.projectM = nullptr;
        self.currentPresetIndex = -1;
        self.previousMean = -1.0;
        self.reportLines = [NSMutableArray array];

        NSArray<NSString *> *paths = [[NSBundle mainBundle] pathsForResourcesOfType:@"milk" inDirectory:@"presets"];
        self.presetPaths = [paths sortedArrayUsingSelector:@selector(compare:)];
        NSLog(@"PresetValidate: found %lu bundled presets", static_cast<unsigned long>(self.presetPaths.count));

        _pcm.resize(kPCMFrames * 2);
        for (size_t i = 0; i < kPCMFrames; ++i)
        {
            double t = static_cast<double>(i) / 44100.0;
            double tone = sin(2.0 * M_PI * 440.0 * t);
            double mod = sin(2.0 * M_PI * 7.0 * t);
            int16_t sample = static_cast<int16_t>(std::max(-1.0, std::min(1.0, tone * 0.65 + mod * 0.25)) * 32767.0);
            _pcm[(i * 2) + 0] = sample;
            _pcm[(i * 2) + 1] = static_cast<int16_t>(-sample);
        }

        if (![self setupEGL] || ![self setupProjectMWithDrawableSize:metalLayer.drawableSize])
        {
            NSLog(@"PresetValidate: setup failed; validator idle");
            self.backgroundColor = [UIColor colorWithRed:0.25f green:0.0f blue:0.0f alpha:1.0f];
            return self;
        }

        self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(stepValidation)];
        [self.displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    }
    return self;
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    CAMetalLayer *metalLayer = (CAMetalLayer *)self.layer;
    CGFloat scale = UIScreen.mainScreen.scale;
    metalLayer.drawableSize = CGSizeMake(CGRectGetWidth(self.bounds) * scale,
                                          CGRectGetHeight(self.bounds) * scale);
    if ([self recreateSurfaceIfNeededForDrawableSize:metalLayer.drawableSize] && self.projectM != nullptr)
    {
        size_t width = static_cast<size_t>(std::max<CGFloat>(1, metalLayer.drawableSize.width));
        size_t height = static_cast<size_t>(std::max<CGFloat>(1, metalLayer.drawableSize.height));
        projectm_set_window_size(self.projectM, width, height);
    }
}

- (void)pause
{
    self.displayLink.paused = YES;
}

- (void)resume
{
    self.displayLink.paused = NO;
}

- (void)dealloc
{
    [_displayLink invalidate];
    if (_projectM != nullptr)
    {
        projectm_set_preset_switch_failed_event_callback(_projectM, nullptr, nullptr);
        projectm_destroy(_projectM);
    }
    if (_eglDisplay != EGL_NO_DISPLAY)
    {
        eglMakeCurrent(_eglDisplay, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        if (_eglSurface != EGL_NO_SURFACE)
        {
            eglDestroySurface(_eglDisplay, _eglSurface);
        }
        if (_eglContext != EGL_NO_CONTEXT)
        {
            eglDestroyContext(_eglDisplay, _eglContext);
        }
        eglTerminate(_eglDisplay);
    }
    [_presetPaths release];
    [_reportLines release];
    [_displayLink release];
    [super dealloc];
}

- (BOOL)setupEGL
{
    self.eglDisplay = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (self.eglDisplay == EGL_NO_DISPLAY)
    {
        NSLog(@"PresetValidate: eglGetDisplay failed: 0x%04x", eglGetError());
        return NO;
    }

    EGLint major = 0;
    EGLint minor = 0;
    if (!eglInitialize(self.eglDisplay, &major, &minor))
    {
        NSLog(@"PresetValidate: eglInitialize failed: 0x%04x", eglGetError());
        return NO;
    }

    EGLint configAttributes[] = {
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
        EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
        EGL_RED_SIZE, 8,
        EGL_GREEN_SIZE, 8,
        EGL_BLUE_SIZE, 8,
        EGL_ALPHA_SIZE, 8,
        EGL_DEPTH_SIZE, 0,
        EGL_STENCIL_SIZE, 0,
        EGL_NONE,
    };

    EGLint configCount = 0;
    if (!eglChooseConfig(self.eglDisplay, configAttributes, &_eglConfig, 1, &configCount) || configCount != 1)
    {
        NSLog(@"PresetValidate: eglChooseConfig failed: 0x%04x count=%d", eglGetError(), configCount);
        return NO;
    }

    EGLint contextAttributes[] = {
        EGL_CONTEXT_CLIENT_VERSION, 3,
        EGL_NONE,
    };
    self.eglContext = eglCreateContext(self.eglDisplay, self.eglConfig, EGL_NO_CONTEXT, contextAttributes);
    if (self.eglContext == EGL_NO_CONTEXT)
    {
        NSLog(@"PresetValidate: eglCreateContext failed: 0x%04x", eglGetError());
        return NO;
    }

    self.eglSurface = eglCreateWindowSurface(self.eglDisplay, self.eglConfig, (__bridge EGLNativeWindowType)self.layer, nullptr);
    if (self.eglSurface == EGL_NO_SURFACE)
    {
        NSLog(@"PresetValidate: eglCreateWindowSurface failed: 0x%04x", eglGetError());
        return NO;
    }
    self.surfaceDrawableSize = ((CAMetalLayer *)self.layer).drawableSize;

    if (!eglMakeCurrent(self.eglDisplay, self.eglSurface, self.eglSurface, self.eglContext))
    {
        NSLog(@"PresetValidate: eglMakeCurrent failed: 0x%04x", eglGetError());
        return NO;
    }

    NSLog(@"PresetValidate: EGL %d.%d GL_VERSION: %s", major, minor, glGetString(GL_VERSION));
    return YES;
}

- (BOOL)setupProjectMWithDrawableSize:(CGSize)drawableSize
{
    self.projectM = projectm_create();
    if (self.projectM == nullptr)
    {
        NSLog(@"PresetValidate: projectm_create failed");
        return NO;
    }

    projectm_set_mesh_size(self.projectM, 48, 36);
    projectm_set_fps(self.projectM, 60);
    size_t width = static_cast<size_t>(std::max<CGFloat>(1, drawableSize.width));
    size_t height = static_cast<size_t>(std::max<CGFloat>(1, drawableSize.height));
    projectm_set_window_size(self.projectM, width, height);

    NSString *resourcePath = NSBundle.mainBundle.resourcePath;
    NSString *texturesPath = [resourcePath stringByAppendingPathComponent:@"textures"];
    const char *texturePaths[] = {
        texturesPath.fileSystemRepresentation,
        resourcePath.fileSystemRepresentation,
    };
    projectm_set_texture_search_paths(self.projectM, texturePaths, 2);
    projectm_set_preset_locked(self.projectM, true);
    projectm_set_preset_switch_failed_event_callback(self.projectM, PresetSwitchFailedCallback, self);
    return YES;
}

- (BOOL)recreateSurfaceIfNeededForDrawableSize:(CGSize)drawableSize
{
    if (drawableSize.width <= 0 || drawableSize.height <= 0)
    {
        return NO;
    }
    if (CGSizeEqualToSize(drawableSize, self.surfaceDrawableSize))
    {
        return YES;
    }
    if (self.eglDisplay == EGL_NO_DISPLAY || self.eglContext == EGL_NO_CONTEXT || self.eglConfig == nullptr)
    {
        return NO;
    }

    EGLSurface oldSurface = self.eglSurface;
    eglMakeCurrent(self.eglDisplay, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    if (oldSurface != EGL_NO_SURFACE)
    {
        eglDestroySurface(self.eglDisplay, oldSurface);
    }
    self.eglSurface = eglCreateWindowSurface(self.eglDisplay, self.eglConfig, (__bridge EGLNativeWindowType)self.layer, nullptr);
    if (self.eglSurface == EGL_NO_SURFACE)
    {
        NSLog(@"PresetValidate: recreate eglCreateWindowSurface failed: 0x%04x", eglGetError());
        self.surfaceDrawableSize = CGSizeZero;
        return NO;
    }
    self.surfaceDrawableSize = drawableSize;
    if (!eglMakeCurrent(self.eglDisplay, self.eglSurface, self.eglSurface, self.eglContext))
    {
        NSLog(@"PresetValidate: recreate eglMakeCurrent failed: 0x%04x", eglGetError());
        return NO;
    }
    return YES;
}

- (void)beginNextPreset
{
    self.currentPresetIndex++;
    if (self.currentPresetIndex >= static_cast<NSInteger>(self.presetPaths.count))
    {
        [self finishValidation];
        return;
    }

    self.currentFrameCount = 0;
    self.currentCompileFailed = NO;
    self.currentGLErrorFailed = NO;
    self.currentMaxMean = 0.0;
    self.currentMaxDelta = 0.0;
    self.previousMean = -1.0;
    while (glGetError() != GL_NO_ERROR)
    {
    }

    NSString *path = self.presetPaths[self.currentPresetIndex];
    projectm_load_preset_file(self.projectM, path.fileSystemRepresentation, false);
}

- (void)stepValidation
{
    if (self.projectM == nullptr || self.eglDisplay == EGL_NO_DISPLAY || self.eglSurface == EGL_NO_SURFACE)
    {
        return;
    }
    if (self.currentPresetIndex < 0 || self.currentFrameCount >= kFramesPerPreset)
    {
        [self beginNextPreset];
        if (self.currentPresetIndex >= static_cast<NSInteger>(self.presetPaths.count))
        {
            return;
        }
    }

    if (!eglMakeCurrent(self.eglDisplay, self.eglSurface, self.eglSurface, self.eglContext))
    {
        self.currentGLErrorFailed = YES;
        return;
    }

    CGSize drawableSize = ((CAMetalLayer *)self.layer).drawableSize;
    GLsizei width = std::max<GLsizei>(1, static_cast<GLsizei>(drawableSize.width));
    GLsizei height = std::max<GLsizei>(1, static_cast<GLsizei>(drawableSize.height));
    glViewport(0, 0, width, height);
    projectm_pcm_add_int16(self.projectM, _pcm.data(), static_cast<unsigned int>(kPCMFrames), PROJECTM_STEREO);
    projectm_opengl_render_frame(self.projectM);

    GLenum error = GL_NO_ERROR;
    while ((error = glGetError()) != GL_NO_ERROR)
    {
        self.currentGLErrorFailed = YES;
    }

    double mean = [self readMeanLuminanceFromWidth:width height:height];
    self.currentMaxMean = std::max(self.currentMaxMean, mean);
    if (self.previousMean >= 0.0)
    {
        self.currentMaxDelta = std::max(self.currentMaxDelta, fabs(mean - self.previousMean));
    }
    self.previousMean = mean;

    eglSwapBuffers(self.eglDisplay, self.eglSurface);
    self.currentFrameCount++;
    if (self.currentFrameCount >= kFramesPerPreset)
    {
        [self classifyCurrentPreset];
    }
}

- (double)readMeanLuminanceFromWidth:(GLsizei)width height:(GLsizei)height
{
    GLsizei readWidth = std::min<GLsizei>(64, width);
    GLsizei readHeight = std::min<GLsizei>(36, height);
    GLint x = std::max<GLint>(0, (width - readWidth) / 2);
    GLint y = std::max<GLint>(0, (height - readHeight) / 2);
    _readPixels.resize(static_cast<size_t>(readWidth) * static_cast<size_t>(readHeight) * 4);
    glReadPixels(x, y, readWidth, readHeight, GL_RGBA, GL_UNSIGNED_BYTE, _readPixels.data());

    GLenum error = GL_NO_ERROR;
    while ((error = glGetError()) != GL_NO_ERROR)
    {
        self.currentGLErrorFailed = YES;
    }

    double sum = 0.0;
    size_t pixelCount = static_cast<size_t>(readWidth) * static_cast<size_t>(readHeight);
    for (size_t i = 0; i < pixelCount; ++i)
    {
        const uint8_t *pixel = _readPixels.data() + (i * 4);
        sum += (0.2126 * pixel[0] + 0.7152 * pixel[1] + 0.0722 * pixel[2]) / 255.0;
    }
    return pixelCount > 0 ? sum / static_cast<double>(pixelCount) : 0.0;
}

- (void)classifyCurrentPreset
{
    NSString *status = nil;
    if (self.currentCompileFailed)
    {
        status = @"FAIL_COMPILE";
        self.failCompileCount++;
    }
    else if (self.currentGLErrorFailed)
    {
        status = @"FAIL_GLERROR";
        self.failGLErrorCount++;
    }
    else if (self.currentMaxMean < kBlackThreshold)
    {
        status = @"FAIL_BLACK";
        self.failBlackCount++;
    }
    else if (self.currentMaxDelta < kStaticThreshold)
    {
        status = @"FAIL_STATIC";
        self.failStaticCount++;
    }
    else
    {
        status = @"PASS";
        self.passCount++;
    }

    NSString *filename = self.presetPaths[self.currentPresetIndex].lastPathComponent;
    [self.reportLines addObject:[NSString stringWithFormat:@"%@\t%@", status, filename]];
    if (![status isEqualToString:@"PASS"])
    {
        NSLog(@"PresetValidate: %@\t%@", status, filename);
    }
}

- (void)finishValidation
{
    [self.displayLink invalidate];
    self.displayLink = nil;

    NSUInteger total = self.presetPaths.count;
    NSString *summary = [NSString stringWithFormat:@"TOTAL=%lu PASS=%lu FAIL_COMPILE=%lu FAIL_GLERROR=%lu FAIL_BLACK=%lu FAIL_STATIC=%lu",
                         static_cast<unsigned long>(total),
                         static_cast<unsigned long>(self.passCount),
                         static_cast<unsigned long>(self.failCompileCount),
                         static_cast<unsigned long>(self.failGLErrorCount),
                         static_cast<unsigned long>(self.failBlackCount),
                         static_cast<unsigned long>(self.failStaticCount)];
    [self.reportLines addObject:summary];

    NSArray<NSString *> *documentsDirectories = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDirectory = documentsDirectories.count > 0 ? documentsDirectories[0] : NSTemporaryDirectory();
    NSString *reportPath = [documentsDirectory stringByAppendingPathComponent:@"preset_validation.txt"];
    NSError *error = nil;
    NSString *report = [self.reportLines componentsJoinedByString:@"\n"];
    report = [report stringByAppendingString:@"\n"];
    if (![report writeToFile:reportPath atomically:YES encoding:NSUTF8StringEncoding error:&error])
    {
        NSLog(@"PresetValidate: failed to write %@: %@", reportPath, error);
    }
    NSLog(@"PresetValidate: %@", summary);
}

- (void)handlePresetSwitchFailed:(const char *)presetFilename message:(const char *)message
{
    self.currentCompileFailed = YES;
    NSString *filename = presetFilename != nullptr ? [NSString stringWithUTF8String:presetFilename] : @"(unknown)";
    NSString *error = message != nullptr ? [NSString stringWithUTF8String:message] : @"(unknown)";
    NSLog(@"PresetValidate: switch failed for %@: %@", filename.lastPathComponent, error);
}

@end

#endif  // ROONVIS_ENABLE_PRESET_VALIDATOR
