/*
 * vmrp_renderer.cpp - XComponent + EGL/GLES 屏幕渲染器实现。
 *
 * 渲染管线：RGB565（vmrp 屏幕缓冲）→ RGBA8888（CPU 转换）→ GL 纹理 → 全屏四边形。
 * 支持画面滤镜：缩放滤镜（Nearest/Bilinear/EPX/xBRZ）、CRT扫描线、亮度/对比度/饱和度。
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

static const char *kVertShader =
    "#version 300 es\n"
    "out vec2 v_uv;\n"
    "void main() {\n"
    "  vec2 p = vec2((gl_VertexID == 1) ? 3.0 : -1.0, (gl_VertexID == 2) ? 3.0 : -1.0);\n"
    "  gl_Position = vec4(p, 0.0, 1.0);\n"
    "  v_uv = p * 0.5 + 0.5;\n"
    "  v_uv.y = 1.0 - v_uv.y;\n"
    "}\n";

// Fragment shader: 统一shader，通过 uniform 切换滤镜模式。
// u_filter: 0=Nearest, 1=Bilinear, 2=EPX(AdvMame2x), 3=xBRZ-approx
// EPX/AdvMame2x: 检测2x2块的边缘方向，沿非边缘方向插值。
// xBRZ-approx: 简化的单pass xBRZ，4方向边缘检测+阶梯检测。
static const char *kFragShader =
    "#version 300 es\n"
    "precision highp float;\n"
    "in vec2 v_uv;\n"
    "out vec4 frag;\n"
    "uniform sampler2D u_tex;\n"
    "uniform vec2 u_texture_size;\n"
    "uniform int u_filter;\n"
    "uniform int u_screen_effect;\n"
    "uniform float u_screen_effect_strength;\n"
    "uniform float u_brightness;\n"
    "uniform float u_contrast;\n"
    "uniform float u_saturation;\n"
    "\n"
    "vec4 tex(vec2 uv) {\n"
    "  return texture(u_tex, uv);\n"
    "}\n"
    "\n"
    "// EPX / AdvMame2x: 对每个输出像素映射回源纹理，检查2x邻域决定插值方向。\n"
    "vec4 epxSample(vec2 uv) {\n"
    "  vec2 tex_size = u_texture_size;\n"
    "  vec2 px = uv * tex_size - 0.5;\n"
    "  vec2 frac = fract(px);\n"
    "  vec2 base = (floor(px) + 0.5) / tex_size;\n"
    "  vec2 dx = vec2(1.0 / tex_size.x, 0.0);\n"
    "  vec2 dy = vec2(0.0, 1.0 / tex_size.y);\n"
    "  vec4 c  = tex(base);\n"
    "  vec4 cl = tex(base - dx);\n"
    "  vec4 cr = tex(base + dx);\n"
    "  vec4 cu = tex(base - dy);\n"
    "  vec4 cd = tex(base + dy);\n"
    "  vec4 result = c;\n"
    "  // 右下象限\n"
    "  if (frac.x >= 0.5 && frac.y >= 0.5) {\n"
    "    if (c == cr && c != cd && cr != cu) { result = cr; }\n"
    "    else if (c == cd && c != cr && cd != cl) { result = cd; }\n"
    "  }\n"
    "  // 左下象限\n"
    "  else if (frac.x < 0.5 && frac.y >= 0.5) {\n"
    "    if (c == cl && c != cd && cl != cu) { result = cl; }\n"
    "    else if (c == cd && c != cl && cd != cr) { result = cd; }\n"
    "  }\n"
    "  // 右上象限\n"
    "  else if (frac.x >= 0.5 && frac.y < 0.5) {\n"
    "    if (c == cr && c != cu && cr != cd) { result = cr; }\n"
    "    else if (c == cu && c != cr && cu != cl) { result = cu; }\n"
    "  }\n"
    "  // 左上象限\n"
    "  else {\n"
    "    if (c == cl && c != cu && cl != cd) { result = cl; }\n"
    "    else if (c == cu && c != cl && cu != cr) { result = cu; }\n"
    "  }\n"
    "  return result;\n"
    "}\n"
    "\n"
    "// xBRZ-approx: 简化单pass，4方向边缘检测+阶梯检测。\n"
    "vec4 xbrzSample(vec2 uv) {\n"
    "  vec2 tex_size = u_texture_size;\n"
    "  vec2 px = uv * tex_size - 0.5;\n"
    "  vec2 frac_v = fract(px);\n"
    "  vec2 base = (floor(px) + 0.5) / tex_size;\n"
    "  float dx = 1.0 / tex_size.x;\n"
    "  float dy = 1.0 / tex_size.y;\n"
    "  vec4 c  = tex(base);\n"
    "  vec4 tl = tex(base + vec2(-dx, -dy));\n"
    "  vec4 t  = tex(base + vec2( 0.0, -dy));\n"
    "  vec4 tr = tex(base + vec2( dx, -dy));\n"
    "  vec4 l  = tex(base + vec2(-dx,  0.0));\n"
    "  vec4 r  = tex(base + vec2( dx,  0.0));\n"
    "  vec4 bl = tex(base + vec2(-dx,  dy));\n"
    "  vec4 b  = tex(base + vec2( 0.0,  dy));\n"
    "  vec4 br = tex(base + vec2( dx,  dy));\n"
    "  float lum_c = dot(c.rgb, vec3(0.299, 0.587, 0.114));\n"
    "  float lum_tl = abs(dot(tl.rgb, vec3(0.299, 0.587, 0.114)) - lum_c);\n"
    "  float lum_t  = abs(dot(t.rgb,  vec3(0.299, 0.587, 0.114)) - lum_c);\n"
    "  float lum_tr = abs(dot(tr.rgb, vec3(0.299, 0.587, 0.114)) - lum_c);\n"
    "  float lum_l  = abs(dot(l.rgb,  vec3(0.299, 0.587, 0.114)) - lum_c);\n"
    "  float lum_r  = abs(dot(r.rgb,  vec3(0.299, 0.587, 0.114)) - lum_c);\n"
    "  float lum_bl = abs(dot(bl.rgb, vec3(0.299, 0.587, 0.114)) - lum_c);\n"
    "  float lum_b  = abs(dot(b.rgb,  vec3(0.299, 0.587, 0.114)) - lum_c);\n"
    "  float lum_br = abs(dot(br.rgb, vec3(0.299, 0.587, 0.114)) - lum_c);\n"
    "  float thr = 0.25;\n"
    "  float edge_d = (lum_tl + lum_l + lum_bl) - (lum_tr + lum_r + lum_br);\n"
    "  float edge_v = (lum_tl + lum_t + lum_tr) - (lum_bl + lum_b + lum_br);\n"
    "  float d_s1 = lum_tl + lum_br;\n"
    "  float d_s2 = lum_tr + lum_bl;\n"
    "  vec4 result = c;\n"
    "  float fx = frac_v.x;\n"
    "  float fy = frac_v.y;\n"
    "  if (abs(edge_d) > abs(edge_v) + thr) {\n"
    "    if (edge_d > 0.0) {\n"
    "      if (fx > 0.5 && fy < 0.5 && d_s1 < d_s2) { result = mix(c, tl, smoothstep(0.4, 0.6, (1.0-fx)*fy)); }\n"
    "      else if (fx < 0.5 && fy > 0.5 && d_s1 < d_s2) { result = mix(c, br, smoothstep(0.4, 0.6, fx*(1.0-fy))); }\n"
    "      else if (fx > 0.5 && fy > 0.5 && d_s2 < d_s1) { result = mix(c, tr, smoothstep(0.4, 0.6, fx*fy)); }\n"
    "      else if (fx < 0.5 && fy < 0.5 && d_s2 < d_s1) { result = mix(c, bl, smoothstep(0.4, 0.6, (1.0-fx)*(1.0-fy))); }\n"
    "    } else {\n"
    "      if (fx < 0.5 && fy < 0.5 && d_s2 < d_s1) { result = mix(c, bl, smoothstep(0.4, 0.6, (1.0-fx)*(1.0-fy))); }\n"
    "      else if (fx > 0.5 && fy > 0.5 && d_s2 < d_s1) { result = mix(c, tr, smoothstep(0.4, 0.6, fx*fy)); }\n"
    "      else if (fx < 0.5 && fy > 0.5 && d_s1 < d_s2) { result = mix(c, br, smoothstep(0.4, 0.6, fx*(1.0-fy))); }\n"
    "      else if (fx > 0.5 && fy < 0.5 && d_s1 < d_s2) { result = mix(c, tl, smoothstep(0.4, 0.6, (1.0-fx)*fy)); }\n"
    "    }\n"
    "  }\n"
    "  return result;\n"
    "}\n"
    "\n"
    "void main() {\n"
    "  vec4 c;\n"
    "  if (u_filter == 2) c = epxSample(v_uv);\n"
    "  else if (u_filter == 3) c = xbrzSample(v_uv);\n"
    "  else c = texture(u_tex, v_uv);\n"
    "  // 亮度/对比度/饱和度\n"
    "  c.rgb = (c.rgb - 0.5) * u_contrast + 0.5 + u_brightness;\n"
    "  float lum = dot(c.rgb, vec3(0.299, 0.587, 0.114));\n"
    "  c.rgb = mix(vec3(lum), c.rgb, u_saturation);\n"
    "  // 屏幕效果: 1=CRT扫描线, 2=LCD网格\n"
    "  if (u_screen_effect == 1) {\n"
    "    float line = fract(v_uv.y * u_texture_size.y);\n"
    "    float mask = smoothstep(0.3, 0.7, line);\n"
    "    c.rgb *= mix(1.0, mask, u_screen_effect_strength);\n"
    "  } else if (u_screen_effect == 2) {\n"
    "    float px_x = fract(v_uv.x * u_texture_size.x);\n"
    "    float grid = smoothstep(0.0, 0.05, px_x) * (1.0 - smoothstep(0.95, 1.0, px_x));\n"
    "    c.rgb *= mix(1.0, grid * 0.85 + 0.15, u_screen_effect_strength);\n"
    "  }\n"
    "  frag = c;\n"
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
    egl_surface_ = eglCreateWindowSurface(egl_display_, egl_config_, native_window_, nullptr);
    if (egl_surface_ == EGL_NO_SURFACE) { LOGE("eglCreateWindowSurface failed"); return -1; }

    EGLint ctx_attr[] = { EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE };
    egl_context_ = eglCreateContext(egl_display_, egl_config_, EGL_NO_CONTEXT, ctx_attr);
    if (egl_context_ == EGL_NO_CONTEXT) { LOGE("eglCreateContext failed"); return -1; }

    if (!eglMakeCurrent(egl_display_, egl_surface_, egl_surface_, egl_context_)) {
        LOGE("eglMakeCurrent failed"); return -1;
    }
    eglSwapInterval(egl_display_, 0);

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
    if (w == surface_w_ && h == surface_h_ && egl_surface_ != EGL_NO_SURFACE) return;

    OH_NativeWindow_NativeWindowHandleOpt(reinterpret_cast<OHNativeWindow*>(native_window_),
                                          SET_BUFFER_GEOMETRY, w, h);

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

void VmrpRenderer::SetDisplayFilter(int filterType, int screenEffect, float screenEffectStrength,
                                    float brightness, float contrast, float saturation) {
    filter_type_            = filterType;
    screen_effect_          = screenEffect;
    screen_effect_strength_ = screenEffectStrength;
    brightness_             = brightness;
    contrast_               = contrast;
    saturation_             = saturation;
}

// filter_type_ 变化时切换 texture min/mag filter。
// EPX/xBRZ 需 GL_NEAREST 保持精确 texel 采样；Bilinear 用 GL_LINEAR。
void VmrpRenderer::UpdateTextureFilter() {
    if (prev_filter_type_ == filter_type_) return;
    prev_filter_type_ = filter_type_;
    if (!texture_) return;
    GLenum filter = (filter_type_ == 1) ? GL_LINEAR : GL_NEAREST;
    glBindTexture(GL_TEXTURE_2D, texture_);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, filter);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, filter);
}

// 每帧渲染前设置滤镜 uniform。
void VmrpRenderer::ApplyFilterUniforms() {
    glUseProgram(program_);
    glUniform2f(glGetUniformLocation(program_, "u_texture_size"),
                static_cast<float>(tex_w_), static_cast<float>(tex_h_));
    glUniform1i(glGetUniformLocation(program_, "u_filter"), filter_type_);
    glUniform1i(glGetUniformLocation(program_, "u_screen_effect"), screen_effect_);
    glUniform1f(glGetUniformLocation(program_, "u_screen_effect_strength"), screen_effect_strength_);
    glUniform1f(glGetUniformLocation(program_, "u_brightness"), brightness_);
    glUniform1f(glGetUniformLocation(program_, "u_contrast"), contrast_);
    glUniform1f(glGetUniformLocation(program_, "u_saturation"), saturation_);
}

int VmrpRenderer::Render(const uint16_t *src, int32_t screen_w, int32_t screen_h) {
    if (!Ready() || !src || screen_w <= 0 || screen_h <= 0) {
        LOGE("Render precondition fail: ready=%d src=%p w=%d h=%d",
             Ready() ? 1 : 0, src, screen_w, screen_h);
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

    const size_t pixels = static_cast<size_t>(screen_w) * screen_h;
    uint32_t *rgba = static_cast<uint32_t *>(malloc(pixels * 4));
    if (!rgba) return -1;
    for (size_t i = 0; i < pixels; ++i) {
        uint16_t c = src[i];
        uint8_t r = static_cast<uint8_t>((c >> 11) & 0x1F);
        uint8_t g = static_cast<uint8_t>((c >> 5) & 0x3F);
        uint8_t b = static_cast<uint8_t>(c & 0x1F);
        rgba[i] = (r << 3 | r >> 2) | ((g << 2 | g >> 4) << 8) | ((b << 3 | b >> 2) << 16) | 0xFF000000u;
    }
    glBindTexture(GL_TEXTURE_2D, texture_);
    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, screen_w, screen_h, GL_RGBA, GL_UNSIGNED_BYTE, rgba);
    free(rgba);

    UpdateTextureFilter();
    ApplyFilterUniforms();

    int32_t vp_w = surface_w_ > 0 ? surface_w_ : screen_w;
    int32_t vp_h = surface_h_ > 0 ? surface_h_ : screen_h;
    glViewport(0, 0, vp_w, vp_h);
    glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
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

    UpdateTextureFilter();
    ApplyFilterUniforms();

    int32_t vp_w = surface_w_ > 0 ? surface_w_ : screen_w;
    int32_t vp_h = surface_h_ > 0 ? surface_h_ : screen_h;
    glViewport(0, 0, vp_w, vp_h);
    glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
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
