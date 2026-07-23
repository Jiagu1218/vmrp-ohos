/*
 * vmrp_renderer.h - XComponent + EGL/GLES 多pass屏幕渲染器
 *
 * 3-pass FBO 渲染管线：
 *   Pass1 (缩放): 源纹理 → FBO_A (含 Nearest/Bilinear/EPX/xBRZ/FSRCNNX)
 *   Pass2 (后处理): FBO_A → FBO_B (亮度/对比度/饱和度/gamma/子像素/CRT/LCD)
 *   Pass3 (输出): FBO_B → 屏幕 (copy + barrel distortion)
 *
 * 源缓冲为 RGB565（默认 240x320），CPU 转 RGBA8888 后上传 GL 纹理。
 * 渲染时机：引擎线程 StepTimer/SendEvent 后，若 ScreenDirty() 为真则调用 Render()。
 */
#ifndef VMRP_RENDERER_H
#define VMRP_RENDERER_H

#include <EGL/egl.h>
#include <GLES3/gl3.h>
#include <cstdint>
#ifdef HAS_XENGINE
#include <native_buffer/native_buffer.h>
#endif

class VmrpRenderer {
public:
    VmrpRenderer() = default;
    ~VmrpRenderer();

    int OnSurfaceCreated(void *window);
    void RebuildSurface(int32_t w, int32_t h);
    void OnSurfaceDestroyed();

    // RGB565 路径：src 行宽 display_w, 纹理尺寸 display_w×display_h
    int Render(const uint16_t *src, int32_t display_w, int32_t display_h, int rotation);
    // RGBA8888 路径：rgba 行宽 display_w, 纹理尺寸 display_w×display_h
    int Render(const uint8_t *rgba, int32_t display_w, int32_t display_h, int rotation);
    // RGB565 直传路径：GPU自动565→888位扩展，省CPU转换+减半带宽
    int RenderRgb565(const uint16_t *src, int32_t display_w, int32_t display_h, int rotation);

    bool Ready() const { return egl_display_ != EGL_NO_DISPLAY && texture_ != 0; }
    int32_t SurfaceWidth() const { return surface_w_; }
    int32_t SurfaceHeight() const { return surface_h_; }

    // 画面滤镜设置，运行时即时生效。
    // filterType: 0=Nearest, 1=Bilinear, 2=EPX, 3=xBRZ, 4=FSRCNNX
    // screenEffect: 0=关闭, 1=完整CRT, 2=LCD网格, 3=仅扫描线
    // screenEffectStrength: 0.0~1.0
    // brightness: -0.3~0.3, contrast: 0.5~2.0, saturation: 0.0~2.0
    // subpixelRender: 0=关, 1=开
    // gammaCorrect: 0=关, 1=开
    // dither: 0=关, 1=开
    void SetDisplayFilter(int filterType, int screenEffect, float screenEffectStrength,
                          float brightness, float contrast, float saturation,
                          int subpixelRender, int gammaCorrect, int dither);

    void SetDirty() { last_frame_dirty_ = true; idle_swap_count_ = 0; }

    // XEngine 超分模式：0=自研shader, 1=GPU超分, 2=AI超分
    int XengineUpscaleMode() const { return xengine_mode_; }
    void ProbeXengine();

private:
    int InitGL();
    void DestroyGL();
    void CreateFBOs(int32_t w, int32_t h);
    void DestroyFBOs();
    void ApplyUpscaleUniforms();
    void ApplyPostprocUniforms();
    void ApplyOutputUniforms();
    void UpdateTextureFilter();
    bool CanBypass() const;
    void RenderBypass(int32_t display_w, int32_t display_h);
#ifdef HAS_XENGINE
    void EnsureFboXeg(int32_t w, int32_t h);
    void DestroyFboXeg();
    void CreateAiInputBuffer(int32_t w, int32_t h);
    void DestroyAiInputBuffer();
    int RenderRgb565Xengine(const uint16_t *src, int32_t display_w, int32_t display_h, int rotation);
#endif

    // RGB565→RGBA CPU 转换（含可选 Bayer 抖动）
    void ConvertRgb565ToRgba(const uint16_t *src, uint32_t *dst, int32_t pixels);

    // EGL
    EGLDisplay egl_display_ = EGL_NO_DISPLAY;
    EGLConfig  egl_config_  = nullptr;
    EGLContext egl_context_ = EGL_NO_CONTEXT;
    EGLSurface egl_surface_ = EGL_NO_SURFACE;
    EGLNativeWindowType native_window_ = 0;

    // 源纹理
    GLuint texture_  = 0;
    GLuint vao_      = 0;
    int32_t tex_w_   = 0;
    int32_t tex_h_   = 0;
    int32_t surface_w_ = 0;
    int32_t surface_h_ = 0;

    // 双PBO异步上传
    GLuint pbo_[2]   = {0, 0};
    int32_t pbo_idx_ = 0;
    int32_t pbo_size_ = 0;

    // 3-pass FBO
    GLuint fbo_a_ = 0, fbo_tex_a_ = 0;
    GLuint fbo_b_ = 0, fbo_tex_b_ = 0;
    GLuint fbo_prev_ = 0, fbo_tex_prev_ = 0;  // phosphor glow 前帧
    int32_t fbo_w_ = 0;
    int32_t fbo_h_ = 0;

    // 3-pass shader programs
    GLuint prog_upscale_  = 0;
    GLuint prog_postproc_ = 0;
    GLuint prog_output_   = 0;
    GLuint prog_bypass_   = 0;

    // bypass pass uniform locations
    GLint ul_by_u_tex_ = -1;
    GLint ul_by_u_rotation_ = -1;

    // dirty tracking: 跳过静态帧的纹理上传+渲染
    bool last_frame_dirty_ = true;
    int  idle_swap_count_  = 0;

    // XEngine 超分
    int xengine_mode_ = 0;  // 0=无, 1=GPU超分, 2=AI超分
    bool xengine_probed_ = false;

#ifdef HAS_XENGINE
    // XEngine 超分输出FBO（surface分辨率）
    GLuint fbo_xeg_ = 0, fbo_tex_xeg_ = 0;
    int32_t fbo_xeg_w_ = 0, fbo_xeg_h_ = 0;

    // AI超分需要 OH_NativeBuffer 关联的输入纹理（宽度≥448）
    OH_NativeBuffer *ai_native_buf_ = nullptr;
    EGLImage         ai_egl_image_ = nullptr;
    GLuint           ai_tex_ = 0;
    GLuint           ai_fbo_ = 0;
    int32_t          ai_w_ = 0;
    int32_t          ai_h_ = 0;
#endif

    // 滤镜参数
    int   filter_type_             = 0;
    int   screen_effect_           = 0;
    float screen_effect_strength_  = 0.5f;
    float brightness_              = 0.0f;
    float contrast_                = 1.0f;
    float saturation_              = 1.0f;
    int   subpixel_render_         = 0;
    int   gamma_correct_           = 1;
    int   dither_enabled_          = 1;
    int   prev_filter_type_        = -1;
    int   current_rotation_        = 0;

    // uniform locations - upscale pass
    GLint ul_up_u_tex_ = -1;
    GLint ul_up_u_texture_size_ = -1;
    GLint ul_up_u_filter_ = -1;

    // uniform locations - postproc pass
    GLint ul_pp_u_tex_ = -1;
    GLint ul_pp_u_prev_tex_ = -1;
    GLint ul_pp_u_texture_size_ = -1;
    GLint ul_pp_u_brightness_ = -1;
    GLint ul_pp_u_contrast_ = -1;
    GLint ul_pp_u_saturation_ = -1;
    GLint ul_pp_u_screen_effect_ = -1;
    GLint ul_pp_u_screen_effect_strength_ = -1;
    GLint ul_pp_u_gamma_correct_ = -1;
    GLint ul_pp_u_subpixel_render_ = -1;
    GLint ul_pp_u_dither_ = -1;
    GLint ul_pp_u_flip_y_ = -1;

    // uniform locations - output pass
    GLint ul_out_u_tex_ = -1;
    GLint ul_out_u_screen_effect_ = -1;
    GLint ul_out_u_screen_effect_strength_ = -1;
    GLint ul_out_u_barrel_k_ = -1;
    GLint ul_out_u_rotation_ = -1;
};

#endif // VMRP_RENDERER_H
