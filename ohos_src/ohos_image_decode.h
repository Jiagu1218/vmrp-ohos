#ifndef OHOS_IMAGE_DECODE_H
#define OHOS_IMAGE_DECODE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* SkyEngine platEx 图片接口实现（鸿蒙原生 Image C API）。
 * 被神话层 dsm.c 的 mr_platEx case 3001/3002/3004/3005/3009/3010/3011
 * 和 mr_plat case 3012 调用。
 * 独立编译单元，不依赖 vmrp 内部头文件，避免冲突。 */

/* platEx(3001): 获取图片信息。
 * input 指向 MRAPP_IMAGE_ORIGIN_T{src,len,src_type}。
 * output 指向 MRAPP_IMAGE_SIZE_T{width,height}。
 * src_type: 0=SRC_NAME(文件名), 1=SRC_STREAM(内存数据流)。
 * 成功返回 0(MR_SUCCESS)，不实现返回 -1(MR_IGNORE)。 */
int32_t ohos_image_get_info(uint8_t *input, int32_t input_len,
                            uint8_t **output, int32_t *output_len);

/* platEx(3002): 图片解码→RGB565 像素数据。
 * input 指向 MRAPP_IMAGE_DECODE_T{src,len,width,height,src_type,dest}。
 * dest 是输出缓冲区指针，大小 = width*height*2。
 * 成功返回 0，不实现返回 -1。 */
int32_t ohos_image_decode(uint8_t *input, int32_t input_len,
                          uint8_t **output, int32_t *output_len);

/* platEx(3009): DMA 刷屏（将 RGB565 像素写入屏幕缓冲）。
 * input 指向 {src_ptr(4B), src_len(4B), src_type(4B), ox(4B), oy(4B), w(4B), h(4B)}。
 * 在 ARM ext 模式下此接口由 table[38] 拦截处理，dsm.c 不需要实现。
 * 非 ext 模式下：将解码后的像素直接绘制到 mr_screenBuf。 */
int32_t ohos_image_display_lcd(uint8_t *input, int32_t input_len,
                               uint8_t **output, int32_t *output_len);

/* platEx(3010): 直接绘制图片（解码+绘制一步完成）。
 * input 指向 T_DRAW_DIRECT_REQ{src,src_len,src_type,ox,oy,w,h}。
 * 解码图片并将 (ox,oy,w,h) 区域绘制到 mr_screenBuf。 */
int32_t ohos_image_draw_direct(uint8_t *input, int32_t input_len,
                                uint8_t **output, int32_t *output_len);

/* platEx(3004): GIF 解码——解码 GIF 动图的所有帧。
 * input 指向 MRAPP_IMAGE_DECODE_T{src,len,width,height,src_type,dest}。
 * output 指向 MRAPP_GIF_HEADER*（host malloc 分配，含帧链表）。
 * MRAPP_GIF_HEADER{ id,width,height,bg_color,frame_count,first→链表 }
 * 每帧 MRAPP_GIF_FRAME_INFO_T{ fwidth,fheight,ox,oy,
 *   transparent_flag,transparent_color,delay_time,pdata,next }
 * pdata 为 RGB565 像素(fwidth*fheight*2 字节)。
 * 调用方用完后须调 ohos_gif_release(3005) 释放。 */
int32_t ohos_gif_decode(uint8_t *input, int32_t input_len,
                        uint8_t **output, int32_t *output_len);

/* platEx(3005): 释放 GIF 解码资源。
 * input 指向 MRAPP_GIF_HEADER*（3004 返回的指针）。
 * 释放所有帧的 pdata、帧结构体、以及 header 自身。 */
int32_t ohos_gif_release(uint8_t *input, int32_t input_len,
                         uint8_t **output, int32_t *output_len);

/* platEx(3011): 显示 GIF 动画（自动播放到屏幕）。
 * input 指向 T_DRAW_DIRECT_REQ{src,src_len,src_type,ox,oy,w,h}。
 * output 指向 T_DSM_COMMON_RSP{p1=动画句柄}。
 * 内部解码 GIF 后启动定时器，按 delay_time 逐帧绘制到 mr_screenBuf。
 * 停止动画用 ohos_gif_stop(3012)。 */
int32_t ohos_gif_display(uint8_t *input, int32_t input_len,
                         uint8_t **output, int32_t *output_len);

/* mr_plat(3012): 停止 GIF 动画。
 * param = 动画句柄（3011 返回的 p1）。
 * 停止定时器并释放动画内部资源。 */
int32_t ohos_gif_stop(int32_t handle);

/* GIF 动画帧推进函数。由 dsm.c 的 mr_timer 回调每 tick 调用一次。
 * 遍历所有活动动画(3011 创建的)，将到期动画绘制下一帧到 mr_screenBuf。
 * 必须在 vmrp worker/timer 线程上下文调用。 */
void ohos_gif_tick(void);

#ifdef __cplusplus
}
#endif

#endif
