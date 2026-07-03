/*
 * vmrp_renderer.h - XComponent + EGL/GLES 屏幕渲染器
 *
 * 把 vmrp 的 RGB565 屏幕缓冲（默认 240x320）转成 RGBA8888 纹理，通过
 * OpenGL ES 渲染到 XComponent 提供的 native window（EGLSurface）上。
 *
 * 渲染时机：每次引擎线程 StepTimer/SendEvent 之后，若 ScreenDirty() 为真，
 * 则调用 Render() 重新上传纹理并绘制一帧。
 */
#ifndef VMRP_RENDERER_H
#define VMRP_RENDERER_H

#include <EGL/egl.h>
#include <GLES3/gl3.h>
#include <cstdint>

class VmrpRenderer {
public:
    VmrpRenderer() = default;
    ~VmrpRenderer();

    // window 由 SurfaceHolder 的 OnSurfaceCreated 回调传入（OHNativeWindow*）。
    // Created 时布局可能未完成（尺寸不可靠），只建 EGL context/surface；
    // 最终尺寸由 OnSurfaceChanged → RebuildSurface 兜底（官方双回调分工）。
    int OnSurfaceCreated(void *window);
    // OnSurfaceChanged(w,h) 回调时调用：重设 native window buffer geometry
    // 并重建 EGL surface，纠正 Created 时拿到的布局中间态尺寸（如 384x384）。
    // 必须在渲染线程（帧回调线程）调用，配合 g_render_mtx 保护。
    void RebuildSurface(int32_t w, int32_t h);
    void OnSurfaceDestroyed();

    // 渲染一帧。src 是 RGB565 缓冲（screen_w * screen_h 个 uint16）。
    // 若 src 为空或未就绪则返回 -1。
    int Render(const uint16_t *src, int32_t screen_w, int32_t screen_h);
    // 渲染一帧（RGBA8888 路径，src 已是 RGBA8888，直接上传纹理，无需转换）。
    // 用于 async worker 模型：vmrp 内部 screen_lock 保证读屏线程安全。
    int Render(const uint8_t *rgba, int32_t screen_w, int32_t screen_h);

    bool Ready() const { return egl_display_ != EGL_NO_DISPLAY && texture_ != 0; }
    // 当前 EGL surface 像素尺寸（触屏坐标归一化用）。0 表示尚未就绪。
    int32_t SurfaceWidth() const { return surface_w_; }
    int32_t SurfaceHeight() const { return surface_h_; }

private:
    int InitGL();   // 编译 shader、生成纹理/vao
    void DestroyGL();

    EGLDisplay egl_display_ = EGL_NO_DISPLAY;
    EGLConfig  egl_config_  = nullptr;
    EGLContext egl_context_ = EGL_NO_CONTEXT;
    EGLSurface egl_surface_ = EGL_NO_SURFACE;
    // EGLNativeWindowType 在 OHOS 上是 unsigned long（窗口句柄），不能用 nullptr。
    EGLNativeWindowType native_window_ = 0;

    GLuint program_  = 0;
    GLuint texture_  = 0;
    GLuint vao_      = 0;
    int32_t tex_w_   = 0;   // 纹理已分配的宽度（用于判断是否需重建）
    int32_t tex_h_   = 0;
    int32_t surface_w_ = 0; // EGL surface 实际像素宽（绘制视口，铺满用）
    int32_t surface_h_ = 0;
};

#endif // VMRP_RENDERER_H
