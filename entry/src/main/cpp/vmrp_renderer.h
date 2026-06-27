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

    // window 由 XComponent 的 OnSurfaceCreated 回调传入（EGLNativeWindowType）。
    int OnSurfaceCreated(void *window, int32_t screen_w, int32_t screen_h);
    void OnSurfaceDestroyed();

    // 渲染一帧。src 是 RGB565 缓冲（screen_w * screen_h 个 uint16）。
    // 若 src 为空或未就绪则返回 -1。
    int Render(const uint16_t *src, int32_t screen_w, int32_t screen_h);

    // surface 尺寸变化时重新查询（由 OnSurfaceChanged 调用）。
    void UpdateSurfaceSize();

    bool Ready() const { return egl_display_ != EGL_NO_DISPLAY && texture_ != 0; }

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
