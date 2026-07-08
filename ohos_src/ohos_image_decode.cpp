/* 鸿蒙原生 Image C API 实现 SkyEngine platEx 图片接口(3001/3002/3004/3005/3009/3010/3011)。
 * + mr_plat(3012) 停止 GIF 动画。
 * 独立编译单元，放在 ohos_src/ 下，不污染 vmrp 上游源码树。
 * 仅 OHOS 构建时编译（由 scripts/CMakeLists.txt 注入 vmrp-shared）。
 *
 * 依赖: libimage_source.so, libpixelmap.so (API 12+)
 * 编译时需 -I 指向 OHOS SDK sysroot/usr/include
 *
 * 数据结构对齐 SkyEngine 定义（mrporting.h）:
 *   MRAPP_IMAGE_ORIGIN_T { char* src; int32 len; int32 src_type; }
 *   MRAPP_IMAGE_SIZE_T   { int32 width; int32 height; }
 *   T_DRAW_DIRECT_REQ    { char* src; int32 src_len; int32 src_type; int32 ox; int32 oy; int32 w; int32 h; }
 *   src_type: SRC_NAME=0(文件名), SRC_STREAM=1(内存数据流)
 *
 * ARM ext 路径(table[38]):
 *   case 38 已有通用的 mr_platEx 桥接逻辑:
 *   r1=ARM input → arm_ptr → host input; mr_platEx 返回 host output → arm_alloc + uc_mem_write。
 *   3002 的 output 是 RGB565 大缓冲，arm_alloc+memcpy 自动完成 host→ARM 转写，
 *   无需在 arm_ext_executor.c 中做特殊拦截。
 *
 * 3009 在 ARM ext 模式下需特殊处理（直接写 mr_screenBuf 的 ARM 地址），
 * 目前由 dsm.c host 路径实现，arm_ext case38 桥接会自动转写 output。
 *
 * 用 C++ 编译：鸿蒙 image_source_native.h 包含 rawfile/raw_file.h，
 * 后者的 deprecated 函数用 C++ 引用语法(&)，纯 C 编译不过。
 */

#include "ohos_image_decode.h"

#include <multimedia/image_framework/image/image_source_native.h>
#include <multimedia/image_framework/image/pixelmap_native.h>
#include <multimedia/image_framework/image/image_common.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* dsm.c 中的 mr_screenBuf 声明为全局变量，此处通过 extern 引用。
 * 非 OHOS 构建时此文件不被编译，无链接冲突。
 * C 链接：dsm.c 是 C 代码，这些 extern 必须用 C 链接声明。 */
extern "C" {
extern uint16_t *mr_screenBuf;
extern int32_t mr_screen_w;
extern int32_t mr_screen_h;
}

/* 日志宏：用 fprintf(stderr, ...) 输出，与 vmrp_core: 标签一致，
 * OHOS 构建时 stderr 已被重定向到 hilog。 */
#define IMG_LOG(fmt, ...) fprintf(stderr, "[ohos_img] " fmt "\n", ##__VA_ARGS__)
#define IMG_LOGW(fmt, ...) fprintf(stderr, "[ohos_img] WARN: " fmt "\n", ##__VA_ARGS__)
#define IMG_LOGE(fmt, ...) fprintf(stderr, "[ohos_img] ERROR: " fmt "\n", ##__VA_ARGS__)

/* 从 MRAPP_IMAGE_ORIGIN_T 读取源数据。
 * dsm.c 已做 SRC_NAME→SRC_STREAM 预处理（mr_open/read 到内存），
 * 此处只处理 SRC_STREAM（src 直接指向内存中的图片数据）。 */
static int read_image_origin(const char *src, int32_t len, int32_t src_type,
                             uint8_t **data_out, size_t *size_out, int *is_copy) {
    *data_out = NULL;
    *size_out = 0;
    *is_copy = 0;

    if (src_type == 1 && src && len > 0) {
        *data_out = (uint8_t *)src;
        *size_out = (size_t)len;
        *is_copy = 0;
        return 0;
    }

    IMG_LOGE("read_image_origin: unsupported src_type=%d (expected SRC_STREAM=1)", src_type);
    return -1;
}

/* 用鸿蒙 Image C API 从内存数据创建 ImageSource 并获取宽高 */
static int get_image_size_from_data(const uint8_t *data, size_t data_size,
                                    uint32_t *out_w, uint32_t *out_h) {
    OH_ImageSourceNative *source = NULL;
    Image_ErrorCode err = OH_ImageSourceNative_CreateFromData((uint8_t *)data, data_size, &source);
    if (err != IMAGE_SUCCESS || !source) {
        IMG_LOGE("OH_ImageSourceNative_CreateFromData failed: %d", err);
        return -1;
    }

    OH_ImageSource_Info *info = NULL;
    err = OH_ImageSourceInfo_Create(&info);
    if (err != IMAGE_SUCCESS || !info) {
        IMG_LOGE("OH_ImageSourceInfo_Create failed: %d", err);
        OH_ImageSourceNative_Release(source);
        return -1;
    }

    err = OH_ImageSourceNative_GetImageInfo(source, 0, info);
    if (err != IMAGE_SUCCESS) {
        IMG_LOGE("OH_ImageSourceNative_GetImageInfo failed: %d", err);
        OH_ImageSourceInfo_Release(info);
        OH_ImageSourceNative_Release(source);
        return -1;
    }

    *out_w = 0;
    *out_h = 0;
    OH_ImageSourceInfo_GetWidth(info, out_w);
    OH_ImageSourceInfo_GetHeight(info, out_h);

    OH_ImageSourceInfo_Release(info);
    OH_ImageSourceNative_Release(source);
    return 0;
}

/* 用鸿蒙 Image C API 解码图片为 RGB565 像素数据。
 * 返回 malloc 分配的 RGB565 缓冲（调用方负责 free），失败返回 NULL。
 * *out_size 设置为 width*height*2。 */
static uint8_t *decode_image_to_rgb565(const uint8_t *data, size_t data_size,
                                       uint32_t *out_w, uint32_t *out_h,
                                       size_t *out_size) {
    OH_ImageSourceNative *source = NULL;
    Image_ErrorCode err = OH_ImageSourceNative_CreateFromData((uint8_t *)data, data_size, &source);
    if (err != IMAGE_SUCCESS || !source) {
        IMG_LOGE("decode: OH_ImageSourceNative_CreateFromData failed: %d", err);
        return NULL;
    }

    /* 先获取原始尺寸 */
    OH_ImageSource_Info *info = NULL;
    err = OH_ImageSourceInfo_Create(&info);
    if (err != IMAGE_SUCCESS || !info) {
        OH_ImageSourceNative_Release(source);
        return NULL;
    }
    err = OH_ImageSourceNative_GetImageInfo(source, 0, info);
    uint32_t img_w = 0, img_h = 0;
    if (err == IMAGE_SUCCESS) {
        OH_ImageSourceInfo_GetWidth(info, &img_w);
        OH_ImageSourceInfo_GetHeight(info, &img_h);
    }
    OH_ImageSourceInfo_Release(info);
    if (img_w == 0 || img_h == 0) {
        IMG_LOGE("decode: image size 0x0");
        OH_ImageSourceNative_Release(source);
        return NULL;
    }

    /* 请求 RGB_565 格式解码 */
    OH_DecodingOptions *opts = NULL;
    err = OH_DecodingOptions_Create(&opts);
    if (err != IMAGE_SUCCESS || !opts) {
        IMG_LOGE("decode: OH_DecodingOptions_Create failed: %d", err);
        OH_ImageSourceNative_Release(source);
        return NULL;
    }
    /* PIXEL_FORMAT_RGB_565 = 2 */
    OH_DecodingOptions_SetPixelFormat(opts, 2);

    OH_PixelmapNative *pixelmap = NULL;
    err = OH_ImageSourceNative_CreatePixelmap(source, opts, &pixelmap);
    OH_DecodingOptions_Release(opts);
    OH_ImageSourceNative_Release(source);

    if (err != IMAGE_SUCCESS || !pixelmap) {
        IMG_LOGW("decode: RGB565 decode failed (err=%d), trying RGBA_8888 fallback", err);
        /* RGB565 不支持时 fallback 到 RGBA_8888，后转 RGB565 */
        source = NULL;
        err = OH_ImageSourceNative_CreateFromData((uint8_t *)data, data_size, &source);
        if (err != IMAGE_SUCCESS || !source) return NULL;

        opts = NULL;
        err = OH_DecodingOptions_Create(&opts);
        if (err != IMAGE_SUCCESS || !opts) {
            OH_ImageSourceNative_Release(source);
            return NULL;
        }
        /* PIXEL_FORMAT_RGBA_8888 = 3 */
        OH_DecodingOptions_SetPixelFormat(opts, 3);

        err = OH_ImageSourceNative_CreatePixelmap(source, opts, &pixelmap);
        OH_DecodingOptions_Release(opts);
        OH_ImageSourceNative_Release(source);

        if (err != IMAGE_SUCCESS || !pixelmap) {
            IMG_LOGE("decode: RGBA_8888 also failed: %d", err);
            return NULL;
        }

        /* 获取像素数据，转 RGB565 */
        OH_Pixelmap_ImageInfo *pinfo = NULL;
        err = OH_PixelmapImageInfo_Create(&pinfo);
        if (err != IMAGE_SUCCESS || !pinfo) {
            OH_PixelmapNative_Release(pixelmap);
            return NULL;
        }
        err = OH_PixelmapNative_GetImageInfo(pixelmap, pinfo);
        if (err == IMAGE_SUCCESS) {
            OH_PixelmapImageInfo_GetWidth(pinfo, &img_w);
            OH_PixelmapImageInfo_GetHeight(pinfo, &img_h);
        }
        OH_PixelmapImageInfo_Release(pinfo);

        size_t rgba_size = (size_t)img_w * (size_t)img_h * 4;
        uint8_t *rgba_buf = (uint8_t *)malloc(rgba_size);
        if (!rgba_buf) {
            OH_PixelmapNative_Release(pixelmap);
            return NULL;
        }
        size_t read_size = rgba_size;
        err = OH_PixelmapNative_ReadPixels(pixelmap, rgba_buf, &read_size);
        OH_PixelmapNative_Release(pixelmap);

        if (err != IMAGE_SUCCESS) {
            IMG_LOGE("decode: OH_PixelmapNative_ReadPixels(RGBA) failed: %d", err);
            free(rgba_buf);
            return NULL;
        }

        /* RGBA8888 → RGB565 转换 */
        size_t rgb565_size = (size_t)img_w * (size_t)img_h * 2;
        uint8_t *rgb565_buf = (uint8_t *)calloc(1, rgb565_size);
        if (!rgb565_buf) {
            free(rgba_buf);
            return NULL;
        }

        for (uint32_t i = 0; i < img_w * img_h; i++) {
            uint8_t r = rgba_buf[i * 4 + 0];
            uint8_t g = rgba_buf[i * 4 + 1];
            uint8_t b = rgba_buf[i * 4 + 2];
            uint16_t px = ((uint16_t)(r >> 3) << 11) |
                          ((uint16_t)(g >> 2) << 5) |
                          ((uint16_t)(b >> 3));
            rgb565_buf[i * 2 + 0] = (uint8_t)(px & 0xFF);
            rgb565_buf[i * 2 + 1] = (uint8_t)(px >> 8);
        }
        free(rgba_buf);

        *out_w = img_w;
        *out_h = img_h;
        *out_size = rgb565_size;
        return rgb565_buf;
    }

    /* RGB565 解码成功，直接读像素 */
    OH_Pixelmap_ImageInfo *pinfo = NULL;
    err = OH_PixelmapImageInfo_Create(&pinfo);
    if (err != IMAGE_SUCCESS || !pinfo) {
        OH_PixelmapNative_Release(pixelmap);
        return NULL;
    }
    err = OH_PixelmapNative_GetImageInfo(pixelmap, pinfo);
    if (err == IMAGE_SUCCESS) {
        OH_PixelmapImageInfo_GetWidth(pinfo, &img_w);
        OH_PixelmapImageInfo_GetHeight(pinfo, &img_h);
    }
    OH_PixelmapImageInfo_Release(pinfo);

    size_t rgb565_size = (size_t)img_w * (size_t)img_h * 2;
    uint8_t *rgb565_buf = (uint8_t *)calloc(1, rgb565_size);
    if (!rgb565_buf) {
        OH_PixelmapNative_Release(pixelmap);
        return NULL;
    }

    size_t read_size = rgb565_size;
    err = OH_PixelmapNative_ReadPixels(pixelmap, rgb565_buf, &read_size);
    OH_PixelmapNative_Release(pixelmap);

    if (err != IMAGE_SUCCESS) {
        IMG_LOGE("decode: OH_PixelmapNative_ReadPixels(RGB565) failed: %d", err);
        free(rgb565_buf);
        return NULL;
    }

    *out_w = img_w;
    *out_h = img_h;
    *out_size = read_size;
    return rgb565_buf;
}

/* platEx(3001): 获取图片信息 */
int32_t ohos_image_get_info(uint8_t *input, int32_t input_len,
                            uint8_t **output, int32_t *output_len) {
    /* input 指向 MRAPP_IMAGE_ORIGIN_T{char* src; int32 len; int32 src_type;} */
    if (!input || input_len < 12) {
        IMG_LOGE("3001: input too short (%d)", input_len);
        return -1;
    }

    char *src = NULL;
    int32_t src_len = 0;
    int32_t src_type = 0;

    /* 读取 MRAPP_IMAGE_ORIGIN_T 字段（注意对齐，按 4 字节读取） */
    memcpy(&src, input + 0, 4);
    memcpy(&src_len, input + 4, 4);
    memcpy(&src_type, input + 8, 4);

    IMG_LOG("3001: src=%p src_len=%d src_type=%d", src, src_len, src_type);

    uint8_t *img_data = NULL;
    size_t img_data_size = 0;
    int is_copy = 0;
    if (read_image_origin(src, src_len, src_type, &img_data, &img_data_size, &is_copy) != 0) {
        return -1;
    }

    uint32_t w = 0, h = 0;
    int rc = get_image_size_from_data(img_data, img_data_size, &w, &h);

    if (is_copy) free(img_data);

    if (rc != 0) return -1;

    /* 输出 MRAPP_IMAGE_SIZE_T{int32 width; int32 height;} */
    static int32_t size_result[2];
    size_result[0] = (int32_t)w;
    size_result[1] = (int32_t)h;
    *output = (uint8_t *)size_result;
    *output_len = 8;

    IMG_LOG("3001: %dx%d", w, h);
    return 0;
}

/* platEx(3002): 图片解码→RGB565 */
int32_t ohos_image_decode(uint8_t *input, int32_t input_len,
                          uint8_t **output, int32_t *output_len) {
    /* input 指向 MRAPP_IMAGE_DECODE_T{char* src; int32 len; int32 width; int32 height; int32 src_type; char* dest;}
     * dest 是调用方提供的输出缓冲区指针。但 SkyEngine 规范中 dest 可为 NULL，
     * 此时由平台分配（通过 output 返回）。
     * 实测 MRP 应用通常 dest 非 NULL，指定了足够大的缓冲。 */
    if (!input || input_len < 24) {
        IMG_LOGE("3002: input too short (%d)", input_len);
        return -1;
    }

    char *src = NULL;
    int32_t src_len = 0;
    int32_t req_w = 0;
    int32_t req_h = 0;
    int32_t src_type = 0;
    char *dest = NULL;

    memcpy(&src, input + 0, 4);
    memcpy(&src_len, input + 4, 4);
    memcpy(&req_w, input + 8, 4);
    memcpy(&req_h, input + 12, 4);
    memcpy(&src_type, input + 16, 4);
    memcpy(&dest, input + 20, 4);

    IMG_LOG("3002: src=%p len=%d req=%dx%d type=%d dest=%p", src, src_len, req_w, req_h, src_type, dest);

    uint8_t *img_data = NULL;
    size_t img_data_size = 0;
    int is_copy = 0;
    if (read_image_origin(src, src_len, src_type, &img_data, &img_data_size, &is_copy) != 0) {
        return -1;
    }

    uint32_t w = 0, h = 0;
    size_t rgb565_size = 0;
    uint8_t *rgb565 = decode_image_to_rgb565(img_data, img_data_size, &w, &h, &rgb565_size);

    if (is_copy) free(img_data);

    if (!rgb565) {
        IMG_LOGE("3002: decode failed");
        return -1;
    }

    if (dest) {
        /* 调用方提供了缓冲，直接拷贝 */
        int32_t copy_size = req_w * req_h * 2;
        if (copy_size <= 0) copy_size = (int32_t)rgb565_size;
        if (copy_size > (int32_t)rgb565_size) copy_size = (int32_t)rgb565_size;
        memcpy(dest, rgb565, (size_t)copy_size);
        free(rgb565);
        *output = (uint8_t *)dest;
        *output_len = copy_size;
    } else {
        /* 调用方未提供缓冲，通过 output 返回（调用方负责 free） */
        *output = rgb565;
        *output_len = (int32_t)rgb565_size;
    }

    IMG_LOG("3002: decoded %dx%d -> %zu bytes, dest=%p", w, h, rgb565_size, dest);
    return 0;
}

/* 将 RGB565 像素数据绘制到 mr_screenBuf 的指定区域 */
static void blit_rgb565_to_screen(const uint8_t *src, uint32_t src_w, uint32_t src_h,
                                  int32_t ox, int32_t oy, int32_t w, int32_t h) {
    if (!mr_screenBuf || !src) return;
    if (w <= 0 || h <= 0) {
        w = (int32_t)src_w;
        h = (int32_t)src_h;
    }
    if (ox < 0) ox = 0;
    if (oy < 0) oy = 0;
    if (ox + w > mr_screen_w) w = mr_screen_w - ox;
    if (oy + h > mr_screen_h) h = mr_screen_h - oy;
    if (w <= 0 || h <= 0) return;

    for (int32_t y = 0; y < h; y++) {
        int32_t dst_y = oy + y;
        if (dst_y >= mr_screen_h) break;
        const uint16_t *src_row = (const uint16_t *)(src + (size_t)y * (size_t)src_w * 2);
        uint16_t *dst_row = mr_screenBuf + (size_t)dst_y * (size_t)mr_screen_w;
        for (int32_t x = 0; x < w; x++) {
            int32_t dst_x = ox + x;
            if (dst_x >= mr_screen_w) break;
            dst_row[dst_x] = src_row[x];
        }
    }
}

/* platEx(3009): DMA 刷屏 */
int32_t ohos_image_display_lcd(uint8_t *input, int32_t input_len,
                               uint8_t **output, int32_t *output_len) {
    /* input: {src_ptr(4B), src_len(4B), src_type(4B), ox(4B), oy(4B), w(4B), h(4B)}
     * 语义与 T_DRAW_DIRECT_REQ 类似，但 src 指向已解码的 RGB565 数据或图片文件。
     * 如果 src_type==1 且 src 指向 RGB565 数据(src_len=w*h*2)，直接刷屏。
     * 否则先解码再刷。 */
    if (!input || input_len < 28) {
        IMG_LOGE("3009: input too short (%d)", input_len);
        return -1;
    }

    char *src = NULL;
    int32_t src_len = 0;
    int32_t src_type = 0;
    int32_t ox = 0, oy = 0, w = 0, h = 0;

    memcpy(&src, input + 0, 4);
    memcpy(&src_len, input + 4, 4);
    memcpy(&src_type, input + 8, 4);
    memcpy(&ox, input + 12, 4);
    memcpy(&oy, input + 16, 4);
    memcpy(&w, input + 20, 4);
    memcpy(&h, input + 24, 4);

    IMG_LOG("3009: src=%p len=%d type=%d ox=%d oy=%d %dx%d", src, src_len, src_type, ox, oy, w, h);

    if (src_type == 1 && src && src_len > 0 && w > 0 && h > 0) {
        /* SRC_STREAM: src 可能是已解码的 RGB565 数据 */
        int32_t expected = w * h * 2;
        if (src_len >= expected) {
            blit_rgb565_to_screen((const uint8_t *)src, (uint32_t)w, (uint32_t)h, ox, oy, w, h);
            return 0;
        }
    }

    /* 未解码的数据，先解码再刷屏 */
    uint8_t *img_data = NULL;
    size_t img_data_size = 0;
    int is_copy = 0;
    if (read_image_origin(src, src_len, src_type, &img_data, &img_data_size, &is_copy) != 0) {
        return -1;
    }

    uint32_t dw = 0, dh = 0;
    size_t rgb565_size = 0;
    uint8_t *rgb565 = decode_image_to_rgb565(img_data, img_data_size, &dw, &dh, &rgb565_size);

    if (is_copy) free(img_data);

    if (!rgb565) return -1;

    blit_rgb565_to_screen(rgb565, dw, dh, ox, oy, w, h);
    free(rgb565);
    return 0;
}

/* platEx(3010): 直接绘制图片 */
int32_t ohos_image_draw_direct(uint8_t *input, int32_t input_len,
                                uint8_t **output, int32_t *output_len) {
    /* input 指向 T_DRAW_DIRECT_REQ{char* src; int32 src_len; int32 src_type; int32 ox; int32 oy; int32 w; int32 h;} */
    if (!input || input_len < 28) {
        IMG_LOGE("3010: input too short (%d)", input_len);
        return -1;
    }

    char *src = NULL;
    int32_t src_len = 0;
    int32_t src_type = 0;
    int32_t ox = 0, oy = 0, w = 0, h = 0;

    memcpy(&src, input + 0, 4);
    memcpy(&src_len, input + 4, 4);
    memcpy(&src_type, input + 8, 4);
    memcpy(&ox, input + 12, 4);
    memcpy(&oy, input + 16, 4);
    memcpy(&w, input + 20, 4);
    memcpy(&h, input + 24, 4);

    IMG_LOG("3010: src=%p len=%d type=%d ox=%d oy=%d %dx%d", src, src_len, src_type, ox, oy, w, h);

    uint8_t *img_data = NULL;
    size_t img_data_size = 0;
    int is_copy = 0;
    if (read_image_origin(src, src_len, src_type, &img_data, &img_data_size, &is_copy) != 0) {
        return -1;
    }

    uint32_t dw = 0, dh = 0;
    size_t rgb565_size = 0;
    uint8_t *rgb565 = decode_image_to_rgb565(img_data, img_data_size, &dw, &dh, &rgb565_size);

    if (is_copy) free(img_data);

    if (!rgb565) return -1;

    blit_rgb565_to_screen(rgb565, dw, dh, ox, oy, w, h);
    free(rgb565);
    return 0;
}

/* ==================== GIF 动画接口 (3004/3005/3011/3012) ====================
 *
 * SkyEngine GIF 数据结构定义（与 mrporting.h 对齐，此处不依赖 vmrp 头文件）：
 *   MRAPP_GIF_HEADER       { int32 id; int32 width; int32 height; int bg_color;
 *                             int frame_count; MRAPP_GIF_FRAME_INFO_T *first; }
 *   MRAPP_GIF_FRAME_INFO_T { int32 fwidth; int32 fheight; int32 ox; int32 oy;
 *                             int32 transparent_flag; int32 transparent_color;
 *                             int32 delay_time; char *pdata;
 *                             struct _MRAPP_GIF_FRAME_INFO *next; }
 *   T_DSM_COMMON_RSP       { int32 p1; }
 *
 * 3004: 解码 GIF 所有帧为 RGB565 pdata 链表，返回 MRAPP_GIF_HEADER。
 * 3005: 释放 3004 返回的 header 及所有帧。
 * 3011: 显示 GIF 动画——解码后启动定时器逐帧绘制。
 * 3012: 停止 3011 创建的动画。
 *
 * 动画驱动模式：
 *   ohos_gif_tick() 由 dsm.c 的 mr_timer 回调每 tick 调用一次，
 *   检查活动动画并绘制下一帧到 mr_screenBuf。
 *   不依赖宿主 OS 定时器，与 vmrp 的 timer 循环完全同步。
 */

/* SkyEngine 兼容结构体（host 侧分配，不依赖 vmrp 头文件） */
typedef struct _OhosGifFrameInfo {
    int32_t fwidth;
    int32_t fheight;
    int32_t ox;
    int32_t oy;
    int32_t transparent_flag;
    int32_t transparent_color;
    int32_t delay_time;
    char *pdata;
    struct _OhosGifFrameInfo *next;
} OhosGifFrameInfo;

typedef struct {
    int32_t id;
    int32_t width;
    int32_t height;
    int bg_color;
    int frame_count;
    OhosGifFrameInfo *first;
} OhosGifHeader;

/* 动画句柄内部结构 */
typedef struct {
    OhosGifHeader *gif_header;
    int32_t ox;
    int32_t oy;
    int32_t w;
    int32_t h;
    int32_t current_frame;
    int32_t running;
    uint32_t timer_id;
} OhosGifAnimation;

#define OHOS_GIF_MAX_ANIMATIONS 8
static OhosGifAnimation *g_gif_anims[OHOS_GIF_MAX_ANIMATIONS] = {0};
static int32_t g_gif_next_handle = 1;

/* 从单帧 PixelmapNative 读取像素并转为 RGB565。
 * 成功返回 malloc 的 RGB565 缓冲，失败返回 NULL。 */
static uint8_t *pixelmap_to_rgb565(OH_PixelmapNative *pixelmap, uint32_t *out_w, uint32_t *out_h) {
    if (!pixelmap || !out_w || !out_h) return NULL;

    OH_Pixelmap_ImageInfo *pinfo = NULL;
    Image_ErrorCode err = OH_PixelmapImageInfo_Create(&pinfo);
    if (err != IMAGE_SUCCESS || !pinfo) return NULL;

    uint32_t w = 0, h = 0;
    err = OH_PixelmapNative_GetImageInfo(pixelmap, pinfo);
    if (err == IMAGE_SUCCESS) {
        OH_PixelmapImageInfo_GetWidth(pinfo, &w);
        OH_PixelmapImageInfo_GetHeight(pinfo, &h);
    }
    OH_PixelmapImageInfo_Release(pinfo);
    if (w == 0 || h == 0) return NULL;

    /* 先尝试 RGB565 直读 */
    size_t rgb565_size = (size_t)w * (size_t)h * 2;
    uint8_t *rgb565_buf = (uint8_t *)calloc(1, rgb565_size);
    if (!rgb565_buf) return NULL;

    size_t read_size = rgb565_size;
    err = OH_PixelmapNative_ReadPixels(pixelmap, rgb565_buf, &read_size);
    if (err == IMAGE_SUCCESS && read_size > 0) {
        *out_w = w;
        *out_h = h;
        return rgb565_buf;
    }
    free(rgb565_buf);

    /* RGB565 直读失败，尝试 RGBA8888 -> RGB565 转换 */
    size_t rgba_size = (size_t)w * (size_t)h * 4;
    uint8_t *rgba_buf = (uint8_t *)malloc(rgba_size);
    if (!rgba_buf) return NULL;

    read_size = rgba_size;
    err = OH_PixelmapNative_ReadPixels(pixelmap, rgba_buf, &read_size);
    if (err != IMAGE_SUCCESS) {
        free(rgba_buf);
        return NULL;
    }

    rgb565_buf = (uint8_t *)calloc(1, rgb565_size);
    if (!rgb565_buf) {
        free(rgba_buf);
        return NULL;
    }

    for (uint32_t i = 0; i < w * h; i++) {
        uint8_t r = rgba_buf[i * 4 + 0];
        uint8_t g = rgba_buf[i * 4 + 1];
        uint8_t b = rgba_buf[i * 4 + 2];
        uint16_t px = ((uint16_t)(r >> 3) << 11) |
                      ((uint16_t)(g >> 2) << 5) |
                      ((uint16_t)(b >> 3));
        rgb565_buf[i * 2 + 0] = (uint8_t)(px & 0xFF);
        rgb565_buf[i * 2 + 1] = (uint8_t)(px >> 8);
    }
    free(rgba_buf);

    *out_w = w;
    *out_h = h;
    return rgb565_buf;
}

/* platEx(3004): GIF 解码 */
int32_t ohos_gif_decode(uint8_t *input, int32_t input_len,
                        uint8_t **output, int32_t *output_len) {
    if (!input || input_len < 24) {
        IMG_LOGE("3004: input too short (%d)", input_len);
        return -1;
    }

    char *src = NULL;
    int32_t src_len = 0, req_w = 0, req_h = 0, src_type = 0;
    char *dest = NULL;
    memcpy(&src, input + 0, 4);
    memcpy(&src_len, input + 4, 4);
    memcpy(&req_w, input + 8, 4);
    memcpy(&req_h, input + 12, 4);
    memcpy(&src_type, input + 16, 4);
    memcpy(&dest, input + 20, 4);

    IMG_LOG("3004: src=%p len=%d req=%dx%d type=%d dest=%p", src, src_len, req_w, req_h, src_type, dest);

    uint8_t *img_data = NULL;
    size_t img_data_size = 0;
    int is_copy = 0;
    if (read_image_origin(src, src_len, src_type, &img_data, &img_data_size, &is_copy) != 0) {
        return -1;
    }

    OH_ImageSourceNative *source = NULL;
    Image_ErrorCode err = OH_ImageSourceNative_CreateFromData((uint8_t *)img_data, img_data_size, &source);
    if (is_copy) free(img_data);
    if (err != IMAGE_SUCCESS || !source) {
        IMG_LOGE("3004: OH_ImageSourceNative_CreateFromData failed: %d", err);
        return -1;
    }

    /* 获取帧数 */
    uint32_t frame_count = 0;
    err = OH_ImageSourceNative_GetFrameCount(source, &frame_count);
    if (err != IMAGE_SUCCESS || frame_count == 0) {
        IMG_LOGE("3004: GetFrameCount failed: %d, count=%u", err, frame_count);
        OH_ImageSourceNative_Release(source);
        return -1;
    }

    IMG_LOG("3004: frame_count=%u", frame_count);

    /* 获取每帧延迟时间 (单位: 1/100 秒 = 10ms) */
    int32_t *delay_list = (int32_t *)calloc(frame_count, sizeof(int32_t));
    if (!delay_list) {
        OH_ImageSourceNative_Release(source);
        return -1;
    }
    err = OH_ImageSourceNative_GetDelayTimeList(source, delay_list, (size_t)frame_count);
    if (err != IMAGE_SUCCESS) {
        IMG_LOGW("3004: GetDelayTimeList failed: %d, using default 10", err);
        for (uint32_t i = 0; i < frame_count; i++) delay_list[i] = 10;
    }

    /* 获取 GIF 逻辑屏幕尺寸 */
    OH_ImageSource_Info *info = NULL;
    uint32_t gif_w = 0, gif_h = 0;
    err = OH_ImageSourceInfo_Create(&info);
    if (err == IMAGE_SUCCESS && info) {
        err = OH_ImageSourceNative_GetImageInfo(source, 0, info);
        if (err == IMAGE_SUCCESS) {
            OH_ImageSourceInfo_GetWidth(info, &gif_w);
            OH_ImageSourceInfo_GetHeight(info, &gif_h);
        }
        OH_ImageSourceInfo_Release(info);
    }
    if (gif_w == 0) gif_w = (uint32_t)req_w;
    if (gif_h == 0) gif_h = (uint32_t)req_h;

    /* 尝试一次性解码所有帧 */
    OH_DecodingOptions *opts = NULL;
    err = OH_DecodingOptions_Create(&opts);
    if (err != IMAGE_SUCCESS || !opts) {
        IMG_LOGE("3004: OH_DecodingOptions_Create failed: %d", err);
        free(delay_list);
        OH_ImageSourceNative_Release(source);
        return -1;
    }
    OH_DecodingOptions_SetPixelFormat(opts, 2);

    OH_PixelmapNative **pm_list = (OH_PixelmapNative **)calloc(frame_count, sizeof(OH_PixelmapNative *));
    if (!pm_list) {
        OH_DecodingOptions_Release(opts);
        free(delay_list);
        OH_ImageSourceNative_Release(source);
        return -1;
    }

    err = OH_ImageSourceNative_CreatePixelmapList(source, opts, pm_list, (size_t)frame_count);
    OH_DecodingOptions_Release(opts);
    OH_ImageSourceNative_Release(source);

    if (err != IMAGE_SUCCESS) {
        IMG_LOGW("3004: CreatePixelmapList failed (err=%d), trying per-frame decode", err);
        free(pm_list);

        /* 重新创建 source（上面已 Release） */
        /* 注意: img_data 可能已被 free(is_copy==1)，需重新读取原始数据 */
        if (read_image_origin(src, src_len, src_type, &img_data, &img_data_size, &is_copy) != 0) {
            free(delay_list);
            return -1;
        }
        source = NULL;
        err = OH_ImageSourceNative_CreateFromData((uint8_t *)img_data, img_data_size, &source);
        if (is_copy) free(img_data);
        if (err != IMAGE_SUCCESS || !source) {
            free(delay_list);
            return -1;
        }

        pm_list = (OH_PixelmapNative **)calloc(frame_count, sizeof(OH_PixelmapNative *));
        if (!pm_list) {
            OH_ImageSourceNative_Release(source);
            free(delay_list);
            return -1;
        }

        int all_ok = 1;
        for (uint32_t i = 0; i < frame_count; i++) {
            OH_DecodingOptions *fo = NULL;
            err = OH_DecodingOptions_Create(&fo);
            if (err != IMAGE_SUCCESS || !fo) { all_ok = 0; break; }
            OH_DecodingOptions_SetPixelFormat(fo, 2);
            OH_DecodingOptions_SetIndex(fo, (int32_t)i);

            err = OH_ImageSourceNative_CreatePixelmap(source, fo, &pm_list[i]);
            OH_DecodingOptions_Release(fo);
            if (err != IMAGE_SUCCESS || !pm_list[i]) {
                IMG_LOGW("3004: per-frame decode [%u] failed: %d", i, err);
                all_ok = 0;
                break;
            }
        }
        OH_ImageSourceNative_Release(source);
        if (!all_ok) {
            for (uint32_t i = 0; i < frame_count; i++) {
                if (pm_list[i]) OH_PixelmapNative_Release(pm_list[i]);
            }
            free(pm_list);
            free(delay_list);
            return -1;
        }
    }

    /* 从 PixelmapNative 提取 RGB565 像素，构建帧链表 */
    OhosGifFrameInfo *first_frame = NULL;
    OhosGifFrameInfo *prev_frame = NULL;
    int32_t actual_count = 0;

    for (uint32_t i = 0; i < frame_count; i++) {
        if (!pm_list[i]) continue;

        uint32_t fw = 0, fh = 0;
        uint8_t *rgb565 = pixelmap_to_rgb565(pm_list[i], &fw, &fh);
        OH_PixelmapNative_Release(pm_list[i]);

        if (!rgb565) {
            IMG_LOGW("3004: frame[%u] pixelmap_to_rgb565 failed, skipping", i);
            continue;
        }

        OhosGifFrameInfo *frame = (OhosGifFrameInfo *)calloc(1, sizeof(OhosGifFrameInfo));
        if (!frame) {
            free(rgb565);
            continue;
        }

        frame->fwidth = (int32_t)fw;
        frame->fheight = (int32_t)fh;
        frame->ox = 0;
        frame->oy = 0;
        frame->transparent_flag = 0;
        frame->transparent_color = 0;
        /* SkyEngine delay_time 单位: 10ms。OH_ImageSourceNative_GetDelayTimeList
         * 返回的也是 1/100 秒(=10ms)单位，直接使用。 */
        frame->delay_time = delay_list[i];
        if (frame->delay_time <= 0) frame->delay_time = 10;
        frame->pdata = (char *)rgb565;
        frame->next = NULL;

        if (prev_frame) {
            prev_frame->next = frame;
        } else {
            first_frame = frame;
        }
        prev_frame = frame;
        actual_count++;
    }

    free(pm_list);
    free(delay_list);

    if (actual_count == 0) {
        IMG_LOGE("3004: no frames decoded successfully");
        return -1;
    }

    /* 构建 MRAPP_GIF_HEADER */
    OhosGifHeader *header = (OhosGifHeader *)calloc(1, sizeof(OhosGifHeader));
    if (!header) {
        OhosGifFrameInfo *f = first_frame;
        while (f) {
            OhosGifFrameInfo *n = f->next;
            free(f->pdata);
            free(f);
            f = n;
        }
        return -1;
    }

    header->id = 0;
    header->width = (int32_t)gif_w;
    header->height = (int32_t)gif_h;
    header->bg_color = 0;
    header->frame_count = actual_count;
    header->first = first_frame;

    *output = (uint8_t *)header;
    *output_len = sizeof(OhosGifHeader);

    IMG_LOG("3004: GIF %dx%d, %d frames, header=%p", gif_w, gif_h, actual_count, header);
    return 0;
}

/* platEx(3005): 释放 GIF 解码资源 */
int32_t ohos_gif_release(uint8_t *input, int32_t input_len,
                         uint8_t **output, int32_t *output_len) {
    if (!input || input_len < (int32_t)sizeof(OhosGifHeader)) {
        IMG_LOGE("3005: invalid input");
        return -1;
    }

    OhosGifHeader *header = (OhosGifHeader *)input;
    IMG_LOG("3005: releasing header=%p frame_count=%d", header, header->frame_count);

    OhosGifFrameInfo *frame = header->first;
    while (frame) {
        OhosGifFrameInfo *next = frame->next;
        if (frame->pdata) free(frame->pdata);
        free(frame);
        frame = next;
    }

    free(header);
    return 0;
}

/* 供 dsm.c mr_timer 回调调用的 GIF 帧推进函数。
 * 遍历所有活动动画，对到期的动画绘制下一帧到 mr_screenBuf。
 * 必须在 vmrp worker/timer 线程上下文调用（与 mr_screenBuf 写入串行）。
 * dsm.c 中加一行: extern void ohos_gif_tick(void); 在 mr_timer 末尾调用。 */
extern "C" void ohos_gif_tick(void) {
    for (int i = 0; i < OHOS_GIF_MAX_ANIMATIONS; i++) {
        OhosGifAnimation *anim = g_gif_anims[i];
        if (!anim || !anim->running || !anim->gif_header || !anim->gif_header->first) continue;

        anim->current_frame++;

        OhosGifFrameInfo *frame = anim->gif_header->first;
        int32_t idx = 0;
        while (frame && idx < anim->current_frame) {
            frame = frame->next;
            idx++;
        }

        if (!frame) {
            anim->current_frame = 0;
            frame = anim->gif_header->first;
        }

        if (frame && frame->pdata) {
            blit_rgb565_to_screen((const uint8_t *)frame->pdata,
                                  (uint32_t)frame->fwidth, (uint32_t)frame->fheight,
                                  anim->ox, anim->oy, anim->w, anim->h);
        }
    }
}

/* platEx(3011): 显示 GIF 动画 */
int32_t ohos_gif_display(uint8_t *input, int32_t input_len,
                         uint8_t **output, int32_t *output_len) {
    if (!input || input_len < 28) {
        IMG_LOGE("3011: input too short (%d)", input_len);
        return -1;
    }

    char *src = NULL;
    int32_t src_len = 0, src_type = 0, ox = 0, oy = 0, w = 0, h = 0;
    memcpy(&src, input + 0, 4);
    memcpy(&src_len, input + 4, 4);
    memcpy(&src_type, input + 8, 4);
    memcpy(&ox, input + 12, 4);
    memcpy(&oy, input + 16, 4);
    memcpy(&w, input + 20, 4);
    memcpy(&h, input + 24, 4);

    IMG_LOG("3011: src=%p len=%d type=%d ox=%d oy=%d %dx%d", src, src_len, src_type, ox, oy, w, h);

    /* 先解码 GIF */
    uint8_t *gif_output = NULL;
    int32_t gif_output_len = 0;
    uint8_t decode_input[24];
    int32_t decode_w = w, decode_h = h;
    int32_t null_dest = 0;
    memcpy(decode_input + 0, &src, 4);
    memcpy(decode_input + 4, &src_len, 4);
    memcpy(decode_input + 8, &decode_w, 4);
    memcpy(decode_input + 12, &decode_h, 4);
    memcpy(decode_input + 16, &src_type, 4);
    memcpy(decode_input + 20, &null_dest, 4);

    if (ohos_gif_decode(decode_input, 24, &gif_output, &gif_output_len) != 0) {
        IMG_LOGE("3011: GIF decode failed");
        return -1;
    }

    OhosGifHeader *header = (OhosGifHeader *)gif_output;

    int slot = -1;
    for (int i = 0; i < OHOS_GIF_MAX_ANIMATIONS; i++) {
        if (!g_gif_anims[i]) {
            slot = i;
            break;
        }
    }
    if (slot < 0) {
        IMG_LOGE("3011: no free animation slot (max %d)", OHOS_GIF_MAX_ANIMATIONS);
        ohos_gif_release(gif_output, gif_output_len, NULL, NULL);
        return -1;
    }

    OhosGifAnimation *anim = (OhosGifAnimation *)calloc(1, sizeof(OhosGifAnimation));
    if (!anim) {
        ohos_gif_release(gif_output, gif_output_len, NULL, NULL);
        return -1;
    }

    anim->gif_header = header;
    anim->ox = ox;
    anim->oy = oy;
    anim->w = w;
    anim->h = h;
    anim->current_frame = 0;
    anim->running = 1;
    anim->timer_id = 0;

    g_gif_anims[slot] = anim;
    int32_t handle = g_gif_next_handle++;
    if (handle <= 0) handle = 1;
    anim->timer_id = (uint32_t)handle;

    /* 绘制第一帧 */
    if (header->first && header->first->pdata) {
        blit_rgb565_to_screen((const uint8_t *)header->first->pdata,
                              (uint32_t)header->first->fwidth, (uint32_t)header->first->fheight,
                              ox, oy, w, h);
    }

    static int32_t rsp_buf[1];
    rsp_buf[0] = handle;
    *output = (uint8_t *)rsp_buf;
    *output_len = 4;

    IMG_LOG("3011: animation started, handle=%d, slot=%d, frames=%d", handle, slot, header->frame_count);
    return 0;
}

/* mr_plat(3012): 停止 GIF 动画 */
int32_t ohos_gif_stop(int32_t handle) {
    IMG_LOG("3012: stop animation handle=%d", handle);

    for (int i = 0; i < OHOS_GIF_MAX_ANIMATIONS; i++) {
        OhosGifAnimation *anim = g_gif_anims[i];
        if (anim && (int32_t)anim->timer_id == handle) {
            anim->running = 0;

            OhosGifHeader *header = anim->gif_header;
            if (header) {
                OhosGifFrameInfo *frame = header->first;
                while (frame) {
                    OhosGifFrameInfo *next = frame->next;
                    if (frame->pdata) free(frame->pdata);
                    free(frame);
                    frame = next;
                }
                free(header);
            }

            free(anim);
            g_gif_anims[i] = NULL;
            IMG_LOG("3012: animation stopped and freed, slot=%d", i);
            return 0;
        }
    }

    IMG_LOGW("3012: handle %d not found", handle);
    return -1;
}
