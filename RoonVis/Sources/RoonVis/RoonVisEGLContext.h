#import <EGL/egl.h>

#ifdef __cplusplus
extern "C" {
#endif

// Selects the single RGBA8888 / OpenGL ES 3 / depth-0 / stencil-0 EGLConfig shared by
// both EGL sites — the on-screen window surface (ANGLEGLView) and the offscreen
// thumbnail pbuffer (PresetThumbnailRenderer). The only per-site difference is the
// surface type, passed as surfaceTypeBit (EGL_WINDOW_BIT or EGL_PBUFFER_BIT).
//
// On success sets *outConfig and returns EGL_TRUE. *outCount, if non-NULL, receives the
// matched config count for the caller's diagnostics/logging. Returns EGL_FALSE if
// eglChooseConfig fails or matches zero configs.
EGLBoolean RoonVisChooseEGLConfig(EGLDisplay display,
                                  EGLint surfaceTypeBit,
                                  EGLConfig *outConfig,
                                  EGLint *outCount);

// Creates an OpenGL ES 3 context, optionally sharing with an existing context and
// enabling ANGLE's program-binary cache on that context. The shared-context warmer
// uses this so it cannot accidentally diverge from the primary render context setup.
EGLBoolean RoonVisCreateGLES3Context(EGLDisplay display,
                                     EGLConfig config,
                                     EGLContext shareContext,
                                     EGLBoolean enableProgramCache,
                                     EGLContext *outContext);

#ifdef __cplusplus
}
#endif
