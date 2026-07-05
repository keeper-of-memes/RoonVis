#import "RoonVisEGLContext.h"

// The real ANGLE token (0x3459) comes from this header. A prior local #define guessed
// 0x345D, which made eglCreateContext fail with EGL_BAD_ATTRIBUTE and disabled rendering.
#import <EGL/eglext.h>

EGLBoolean RoonVisChooseEGLConfig(EGLDisplay display,
                                  EGLint surfaceTypeBit,
                                  EGLConfig *outConfig,
                                  EGLint *outCount)
{
    const EGLint configAttributes[] = {
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
        EGL_SURFACE_TYPE, surfaceTypeBit,
        EGL_RED_SIZE, 8,
        EGL_GREEN_SIZE, 8,
        EGL_BLUE_SIZE, 8,
        EGL_ALPHA_SIZE, 8,
        EGL_DEPTH_SIZE, 0,
        EGL_STENCIL_SIZE, 0,
        EGL_NONE,
    };

    EGLint count = 0;
    EGLBoolean chose = eglChooseConfig(display, configAttributes, outConfig, 1, &count);
    if (outCount != nullptr)
    {
        *outCount = count;
    }
    return (chose && count >= 1) ? EGL_TRUE : EGL_FALSE;
}

EGLBoolean RoonVisCreateGLES3Context(EGLDisplay display,
                                     EGLConfig config,
                                     EGLContext shareContext,
                                     EGLBoolean enableProgramCache,
                                     EGLContext *outContext)
{
    if (outContext == nullptr)
    {
        return EGL_FALSE;
    }
    *outContext = EGL_NO_CONTEXT;

    EGLint contextAttributes[5] = {
        EGL_CONTEXT_CLIENT_VERSION, 3,
        EGL_NONE,
        EGL_NONE,
        EGL_NONE,
    };
    if (enableProgramCache)
    {
        contextAttributes[2] = EGL_CONTEXT_PROGRAM_BINARY_CACHE_ENABLED_ANGLE;
        contextAttributes[3] = EGL_TRUE;
    }

    EGLContext context = eglCreateContext(display, config, shareContext, contextAttributes);
    if (context == EGL_NO_CONTEXT)
    {
        return EGL_FALSE;
    }

    *outContext = context;
    return EGL_TRUE;
}
