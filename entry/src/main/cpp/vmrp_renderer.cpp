/*
 * vmrp_renderer.cpp - XComponent + EGL/GLES 屏幕渲染器实现。
 *
 * 渲染管线：RGB565（vmrp 屏幕缓冲）→ RGBA8888（CPU 转换）→ GL 纹理 → 全屏四边形。
 *
 * 选 RGB565→RGBA CPU 转换而非 GL_RGB565 纹理的原因：OHOS GLES3 对 16 位纹理
 * 采样的一致性依赖驱动，CPU 转换最稳定可靠，且 240x320 数据量小（约 300KB），
 * 性能完全足够。
 */
#include "vmrp_renderer.h"

#include <hilog/log.h>
#include <cstdio>
#include <cstring>
#include <malloc.h>
#include <native_window/external_window.h>

#undef LOG_TAG
#define LOG_TAG "vmrp_renderer"
#define LOGI(...) OH_LOG_INFO(LOG_APP, __VA_ARGS__)
#define LOGE(...) OH_LOG_ERROR(LOG_APP, __VA_ARGS__)

// 全屏三角形对（覆盖整个 NDC 空间），无需 VBO 数据，位置在 shader 内用顶点 id 计算。
static const char *kVertShader =
    "#version 300 es\n"
    "out vec2 v_uv;\n"
    "void main() {\n"
    "  // 顶点 0..3 构成覆盖屏幕的两个三角形\n"
    "  vec2 p = vec2((gl_VertexID == 1) ? 3.0 : -1.0, (gl_VertexID == 2) ? 3.0 : -1.0);\n"
    "  gl_Position = vec4(p, 0.0, 1.0);\n"
    "  v_uv = p * 0.5 + 0.5;\n"   // [0,1]，左上原点
    "  v_uv.y = 1.0 - v_uv.y;\n"   // 翻转 V，使纹理正向显示
    "}\n";

static const char *kFragShader =
    "#version 300 es\n"
    "precision mediump float;\n"
    "in vec2 v_uv;\n"
    "out vec4 frag;\n"
    "uniform sampler2D u_tex;\n"
    "void main() {\n"
    "  frag = texture(u_tex, v_uv);\n"
    "}\n";

static GLuint CompileShader(GLenum type, const char *src) {
    GLuint sh = glCreateShader(type);
    glShaderSource(sh, 1, &src, nullptr);
    glCompileShader(sh);
    GLint ok = 0;
    glGetShaderiv(sh, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char log[512] = {0};
        glGetShaderInfoLog(sh, sizeof(log), nullptr, log);
        LOGE("shader compile failed: %s", log);
        glDeleteShader(sh);
        return 0;
    }
    return sh;
}

int VmrpRenderer::InitGL() {
    GLint vsh = CompileShader(GL_VERTEX_SHADER, kVertShader);
    GLint fsh = CompileShader(GL_FRAGMENT_SHADER, kFragShader);
    if (!vsh || !fsh) return -1;
    program_ = glCreateProgram();
    glAttachShader(program_, vsh);
    glAttachShader(program_, fsh);
    glLinkProgram(program_);
    glDeleteShader(vsh);
    glDeleteShader(fsh);
    GLint ok = 0;
    glGetProgramiv(program_, GL_LINK_STATUS, &ok);
    if (!ok) {
        char log[512] = {0};
        glGetProgramInfoLog(program_, sizeof(log), nullptr, log);
        LOGE("program link failed: %s", log);
        return -1;
    }
    glGenTextures(1, &texture_);
    glBindTexture(GL_TEXTURE_2D, texture_);
    // MRP 是像素艺术，用 GL_NEAREST 保持像素清晰（GL_LINEAR 会模糊）。
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glGenVertexArrays(1, &vao_);
    LOGI("GL init OK (program=%u tex=%u vao=%u)", program_, texture_, vao_);
    return 0;
}

void VmrpRenderer::DestroyGL() {
    if (texture_) { glDeleteTextures(1, &texture_); texture_ = 0; }
    if (vao_) { glDeleteVertexArrays(1, &vao_); vao_ = 0; }
    if (program_) { glDeleteProgram(program_); program_ = 0; }
    tex_w_ = tex_h_ = 0;
}

int VmrpRenderer::OnSurfaceCreated(void *window) {
    native_window_ = reinterpret_cast<EGLNativeWindowType>(window);

    egl_display_ = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (egl_display_ == EGL_NO_DISPLAY) { LOGE("eglGetDisplay failed"); return -1; }
    EGLint major = 0, minor = 0;
    if (!eglInitialize(egl_display_, &major, &minor)) { LOGE("eglInitialize failed"); return -1; }

    EGLint cfg_attr[] = {
        EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
        EGL_NONE
    };
    EGLint num = 0;
    if (!eglChooseConfig(egl_display_, cfg_attr, &egl_config_, 1, &num) || num < 1) {
        LOGE("eglChooseConfig failed num=%d", num);
        return -1;
    }
    // 用 OHOS 的 native window 创建 EGLSurface（SurfaceHolder 的 GetNativeWindow 传入）。
    // Created 时布局可能未完成，surface 尺寸可能是中间态（如 384x384），
    // 最终正确尺寸由 OnSurfaceChanged → RebuildSurface 兜底重建。
    egl_surface_ = eglCreateWindowSurface(egl_display_, egl_config_, native_window_, nullptr);
    if (egl_surface_ == EGL_NO_SURFACE) { LOGE("eglCreateWindowSurface failed"); return -1; }

    EGLint ctx_attr[] = { EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE };
    egl_context_ = eglCreateContext(egl_display_, egl_config_, EGL_NO_CONTEXT, ctx_attr);
    if (egl_context_ == EGL_NO_CONTEXT) { LOGE("eglCreateContext failed"); return -1; }

    if (!eglMakeCurrent(egl_display_, egl_surface_, egl_surface_, egl_context_)) {
        LOGE("eglMakeCurrent failed"); return -1;
    }
    eglSwapInterval(egl_display_, 0); // 不限制 vsync，按脏标记驱动

    // 查询 EGL surface 当前像素尺寸（可能为中间态，Changed 后会更新）。
    EGLint sw = 0, sh = 0;
    eglQuerySurface(egl_display_, egl_surface_, EGL_WIDTH, &sw);
    eglQuerySurface(egl_display_, egl_surface_, EGL_HEIGHT, &sh);
    surface_w_ = sw;
    surface_h_ = sh;

    if (InitGL() != 0) return -1;
    glDisable(GL_DEPTH_TEST);
    LOGI("surface created, EGL %d.%d, surface %dx%d (may resize on SurfaceChanged)",
         major, minor, surface_w_, surface_h_);
    return 0;
}

void VmrpRenderer::RebuildSurface(int32_t w, int32_t h) {
    if (egl_display_ == EGL_NO_DISPLAY || native_window_ == 0 || w <= 0 || h <= 0) return;
    // 若尺寸未变则跳过（避免每帧重建）。
    if (w == surface_w_ && h == surface_h_ && egl_surface_ != EGL_NO_SURFACE) return;

    // 1) 设 native window buffer geometry：决定 surface buffer 的真实分配尺寸。
    //    必须在重建 eglSurface 之前设，新的 surface dequeue 时生效。
    OH_NativeWindow_NativeWindowHandleOpt(reinterpret_cast<OHNativeWindow*>(native_window_),
                                          SET_BUFFER_GEOMETRY, w, h);

    // 2) 销毁旧 eglSurface（其 buffer 尺寸在创建时就定了，无法动态改），
    //    用新 geometry 重建。eglConfig/context 可复用。
    if (egl_surface_ != EGL_NO_SURFACE) {
        eglMakeCurrent(egl_display_, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        eglDestroySurface(egl_display_, egl_surface_);
        egl_surface_ = EGL_NO_SURFACE;
    }
    egl_surface_ = eglCreateWindowSurface(egl_display_, egl_config_, native_window_, nullptr);
    if (egl_surface_ == EGL_NO_SURFACE) {
        LOGE("RebuildSurface: eglCreateWindowSurface failed");
        surface_w_ = surface_h_ = 0;
        return;
    }
    eglMakeCurrent(egl_display_, egl_surface_, egl_surface_, egl_context_);
    EGLint sw = 0, sh = 0;
    eglQuerySurface(egl_display_, egl_surface_, EGL_WIDTH, &sw);
    eglQuerySurface(egl_display_, egl_surface_, EGL_HEIGHT, &sh);
    surface_w_ = sw;
    surface_h_ = sh;
    LOGI("surface rebuilt to %dx%d (eglQuery=%dx%d)", w, h, sw, sh);
}

void VmrpRenderer::OnSurfaceDestroyed() {
    if (egl_display_ == EGL_NO_DISPLAY) return;
    eglMakeCurrent(egl_display_, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    DestroyGL();
    if (egl_surface_ != EGL_NO_SURFACE) { eglDestroySurface(egl_display_, egl_surface_); egl_surface_ = EGL_NO_SURFACE; }
    if (egl_context_ != EGL_NO_CONTEXT) { eglDestroyContext(egl_display_, egl_context_); egl_context_ = EGL_NO_CONTEXT; }
    eglTerminate(egl_display_);
    egl_display_ = EGL_NO_DISPLAY;
    surface_w_ = surface_h_ = 0;
    native_window_ = 0;
    LOGI("surface destroyed");
}

int VmrpRenderer::Render(const uint16_t *src, int32_t screen_w, int32_t screen_h) {
    if (!Ready() || !src || screen_w <= 0 || screen_h <= 0) {
        LOGE("Render precondition fail: ready=%d src=%p w=%d h=%d",
             Ready() ? 1 : 0, src, screen_w, screen_h);
        return -1;
    }
    // EGL context 通常绑定在创建它的线程；跨线程渲染需重新 MakeCurrent。
    EGLBoolean mc = eglMakeCurrent(egl_display_, egl_surface_, egl_surface_, egl_context_);
    if (!mc) {
        OH_LOG_ERROR(LOG_APP, "eglMakeCurrent failed: 0x%{public}x", eglGetError());
        return -1;
    }

    // 尺寸变化时重建纹理（texStorage2D 一次性分配，glTexSubImage2D 更新）。
    if (tex_w_ != screen_w || tex_h_ != screen_h) {
        glBindTexture(GL_TEXTURE_2D, texture_);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, screen_w, screen_h, 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
        tex_w_ = screen_w;
        tex_h_ = screen_h;
    }

    // RGB565 → RGBA8888。malloc 对齐满足 GLES 上传要求。
    const size_t pixels = static_cast<size_t>(screen_w) * screen_h;
    uint32_t *rgba = static_cast<uint32_t *>(malloc(pixels * 4));
    if (!rgba) return -1;
    for (size_t i = 0; i < pixels; ++i) {
        uint16_t c = src[i];
        uint8_t r = static_cast<uint8_t>((c >> 11) & 0x1F);
        uint8_t g = static_cast<uint8_t>((c >> 5) & 0x3F);
        uint8_t b = static_cast<uint8_t>(c & 0x1F);
        // 扩展到 8 位：高位填到低位。
        rgba[i] = (r << 3 | r >> 2) | ((g << 2 | g >> 4) << 8) | ((b << 3 | b >> 2) << 16) | 0xFF000000u;
    }
    glBindTexture(GL_TEXTURE_2D, texture_);
    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, screen_w, screen_h, GL_RGBA, GL_UNSIGNED_BYTE, rgba);
    free(rgba);

    // 视口铺满整个 EGL surface：纹理（240x320）通过 shader 的 uv[0,1] 映射
    // 到全屏三角形，自动缩放到 surface 尺寸（如 840x1120）。
    // 注意：之前用 screen_w/screen_h(240x320) 作 viewport，导致画面只占左上角。
    int32_t vp_w = surface_w_ > 0 ? surface_w_ : screen_w;
    int32_t vp_h = surface_h_ > 0 ? surface_h_ : screen_h;
    glViewport(0, 0, vp_w, vp_h);
    glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
    glUseProgram(program_);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, texture_);
    glUniform1i(glGetUniformLocation(program_, "u_tex"), 0);
    glBindVertexArray(vao_);
    glDrawArrays(GL_TRIANGLES, 0, 3); // 一个大三角形覆盖整个 surface
    GLenum glerr = glGetError();
    if (glerr != GL_NO_ERROR) {
        OH_LOG_ERROR(LOG_APP, "GL error after draw: 0x%{public}x", glerr);
    }
    glBindVertexArray(0);
    EGLBoolean swapped = eglSwapBuffers(egl_display_, egl_surface_);
    if (!swapped) {
        OH_LOG_ERROR(LOG_APP, "eglSwapBuffers failed: 0x%{public}x", eglGetError());
    }
    return 0;
}

// RGBA8888 路径：src 已是 RGBA8888（vmrp 内部 screen_lock 保护下转换）。
// screen_rgba_buf 仅由渲染线程经 get_screen_rgba_buffer 写入，worker 画屏只写
// screen_buf，故 glTexSubImage2D 上传期间该 buffer 不会被并发改写。
int VmrpRenderer::Render(const uint8_t *rgba, int32_t screen_w, int32_t screen_h) {
    if (!Ready() || !rgba || screen_w <= 0 || screen_h <= 0) {
        LOGE("Render(rgba) precondition fail: ready=%d rgba=%p w=%d h=%d",
             Ready() ? 1 : 0, rgba, screen_w, screen_h);
        return -1;
    }
    EGLBoolean mc = eglMakeCurrent(egl_display_, egl_surface_, egl_surface_, egl_context_);
    if (!mc) {
        OH_LOG_ERROR(LOG_APP, "eglMakeCurrent failed: 0x%{public}x", eglGetError());
        return -1;
    }

    if (tex_w_ != screen_w || tex_h_ != screen_h) {
        glBindTexture(GL_TEXTURE_2D, texture_);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, screen_w, screen_h, 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
        tex_w_ = screen_w;
        tex_h_ = screen_h;
    }

    glBindTexture(GL_TEXTURE_2D, texture_);
    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, screen_w, screen_h, GL_RGBA, GL_UNSIGNED_BYTE, rgba);

    int32_t vp_w = surface_w_ > 0 ? surface_w_ : screen_w;
    int32_t vp_h = surface_h_ > 0 ? surface_h_ : screen_h;
    glViewport(0, 0, vp_w, vp_h);
    glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
    glUseProgram(program_);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, texture_);
    glUniform1i(glGetUniformLocation(program_, "u_tex"), 0);
    glBindVertexArray(vao_);
    glDrawArrays(GL_TRIANGLES, 0, 3);
    GLenum glerr = glGetError();
    if (glerr != GL_NO_ERROR) {
        OH_LOG_ERROR(LOG_APP, "GL error after draw: 0x%{public}x", glerr);
    }
    glBindVertexArray(0);
    EGLBoolean swapped = eglSwapBuffers(egl_display_, egl_surface_);
    if (!swapped) {
        OH_LOG_ERROR(LOG_APP, "eglSwapBuffers failed: 0x%{public}x", eglGetError());
    }
    return 0;
}

VmrpRenderer::~VmrpRenderer() { OnSurfaceDestroyed(); }
