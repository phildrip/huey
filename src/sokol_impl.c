#if defined(__ANDROID__)
// Force GLES 3.1 header selection in sokol_gfx.h so we don't pull GLES 3.2
// symbols (glColorMaski, glCopyImageSubData, glDrawElementsBaseVertex) on
// Android 7.x GLES 3.1 devices such as Nexus 9.
#include <android/api-level.h>
#undef __ANDROID_API__
#define __ANDROID_API__ 21
#endif

#define SOKOL_GFX_IMPL
#define SOKOL_GLES3
#include "sokol_gfx.h"
