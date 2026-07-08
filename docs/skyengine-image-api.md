# SkyEngine 图片接口适配 — OHOS_IMAGE_DECODE

## 概述

SkyEngine 平台定义了 14 个图片相关接口（`mr_platEx` 3001~3015），用于图片解码、GIF 动画、图层操作等。vmrp-ohos 使用鸿蒙原生 Image C API（OH_ImageSourceNative / OH_PixelmapNative）实现了其中 10 个接口。

参考文档: https://gddhy.net/2022/skyengine-api/ (图片接口章节)

## 接口清单

| code | 名称 | 用途 | OHOS 实现状态 | 备注 |
|------|------|------|:------------:|------|
| 3001 | 获取图片信息 | 返回图片宽高 | ✅ | OH_ImageSourceNative_GetImageInfo |
| 3002 | 图片解码 | 解码为 RGB565 像素 | ✅ | RGB565 直出 + RGBA8888→RGB565 fallback |
| 3003 | 查询解码状态 | 异步解码状态查询 | ⏭️ | SkyEngine 自身标记"未实现" |
| 3004 | GIF 解码 | 解码 GIF 所有帧 | ✅ | CreatePixelmapList + 逐帧 fallback |
| 3005 | 释放 GIF 资源 | 释放 3004 返回的数据 | ✅ | 释放 header + 帧链表 |
| 3007 | 绘制 BUFFER | GDI 图层 blt 到屏幕 | ✅ | 空操作（渲染循环已自动刷新） |
| 3008 | 获取 ACTIVE LAYER | 返回 gdi_layer_struct | ⏭️ | MR_IGNORE（无 MTK GDI 层） |
| 3009 | DMA 刷屏 | 将像素写入屏幕缓冲 | ✅ | blit 到 mr_screenBuf |
| 3010 | 直接绘制图片 | 解码+绘制一步完成 | ✅ | 解码后 blit 到 mr_screenBuf |
| 3011 | 显示 GIF 动画 | 自动播放 GIF 到屏幕 | ✅ | ohos_gif_tick 逐帧驱动 |
| 3012 | 停止动画 | 停止 3011 的动画 | ✅ | mr_plat 按句柄停止+释放 |
| 3013 | — | — | ⏭️ | SkyEngine 自身标记"未实现" |
| 3014 | 绘制 MTK 资源图片 | MTK 专有资源格式 | ⏳ | 低优先级 |
| 3015 | 绘制 MTK 资源 GIF | MTK 专有资源格式 | ⏳ | 低优先级 |

## 实现架构

### 源码位置

```
ohos_src/
  ├─ ohos_image_decode.h   # 头文件，extern "C" 声明 9 个函数
  └─ ohos_image_decode.cpp # 实现文件（C++ 编译，因 SDK 头文件含 C++ 引用语法）

vmrp/src/mythroad/dsm.c    # case 3001/3002/3004/3005/3007/3008/3009/3010/3011 + mr_plat case 3012
vmrp/src/mythroad/mythroad.c # mr_timer() 末尾调 ohos_gif_tick() (CMake patch OHOS_GIF_TICK)

scripts/CMakeLists.txt     # 注入 ohos_image_decode.cpp + __OHOS__ 宏 + 链接 image_source/pixelmap
```

### 为什么用 C++ 而不是 C

鸿蒙 SDK 的 `image_source_native.h` 包含 `rawfile/raw_file.h`，后者的 deprecated 函数使用 C++ 引用语法（`RawFileDescriptor &descriptor`），纯 C 编译不过。因此 `ohos_image_decode.cpp` 必须用 C++ 编译，但通过 `extern "C"` 导出 C 链接符号供 dsm.c 调用。

### 双路径设计

图片接口在 ARM ext 模式和非 ext 模式下走不同路径：

```
MRP ARM 代码调 table[38] (mr_platEx)
    ↓
arm_ext_executor.c 的 table[38] handler
    ├─ r0==3001~3011 → 通用桥接：arm_ptr 读 ARM input → host mr_platEx → arm_alloc + uc_mem_write 写回
    └─ 3002 的 RGB565 大缓冲自动通过 arm_alloc+memcpy 完成 host→ARM 转写

MRP Lua/VM 代码调 dsm.c mr_platEx()
    ↓
dsm.c switch(code) case 3001~3011
    └─ #ifdef __OHOS__ → 调 ohos_image_* / ohos_gif_* 函数
```

### SRC_NAME → SRC_STREAM 预处理

SkyEngine 定义两种图片来源：
- `SRC_NAME=0`：文件名（MRP 包内路径）
- `SRC_STREAM=1`：内存数据流指针

鸿蒙原生 Image C API 只接受内存数据（`OH_ImageSourceNative_CreateFromData`），不接受文件名。因此 dsm.c 在调用 ohos_image_* 前做预处理：

```c
// dsm.c case 3001 (其他 case 类似)
if (src_type == 0) {  // SRC_NAME
    int32 fd = mr_open(filename, MR_FILE_RDONLY);
    mr_seek(fd, 0, 2);  // seek to end
    int32 len = mr_seek(fd, 0, 1);  // get size
    mr_seek(fd, 0, 0);  // seek to start
    uint8_t *buf = calloc(1, len);
    mr_read(fd, buf, len);
    mr_close(fd);
    // 将 src_type 改为 1 (SRC_STREAM)，src/len 改为 buf/len
    ohos_image_get_info(modified_input, 12, output, output_len);
    free(buf);
}
```

这样 ohos_image_decode.cpp 内部只处理 SRC_STREAM，不依赖 vmrp 的文件系统函数。

### RGB565 解码策略

SkyEngine 的屏幕缓冲格式是 RGB565（uint16_t *），鸿蒙 Image API 支持 `PIXEL_FORMAT_RGB_565=2`，但并非所有图片格式都支持 RGB565 直出。解码策略：

1. 先尝试 `OH_DecodingOptions_SetPixelFormat(opts, 2)` (RGB_565) 解码
2. 若失败，fallback 到 `PIXEL_FORMAT_RGBA_8888=3` 解码
3. RGBA8888→RGB565 软件转换：

```c
uint16_t px = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3);
```

4. RGB565 字节序：低字节在前（little-endian），与 ARM CPU 一致

## GIF 动画实现

### 3004: GIF 解码

使用鸿蒙原生多帧解码 API：

```
OH_ImageSourceNative_CreateFromData(data, size, &source)
OH_ImageSourceNative_GetFrameCount(source, &frame_count)
OH_ImageSourceNative_GetDelayTimeList(source, delay_list, frame_count)
OH_ImageSourceNative_CreatePixelmapList(source, opts, pm_list, frame_count)  ← 一次性解码所有帧
```

若 `CreatePixelmapList` 失败，fallback 为逐帧解码：

```
for (i = 0; i < frame_count; i++) {
    OH_DecodingOptions_SetIndex(opts, i);
    OH_ImageSourceNative_CreatePixelmap(source, opts, &pm_list[i]);
}
```

每帧 PixelmapNative 通过 `pixelmap_to_rgb565()` 转为 RGB565 像素，构建 SkyEngine 兼容的链表结构：

```c
// SkyEngine 兼容结构体（host 侧分配）
typedef struct _OhosGifFrameInfo {
    int32_t fwidth, fheight;
    int32_t ox, oy;
    int32_t transparent_flag, transparent_color;
    int32_t delay_time;          // 单位: 10ms (GIF 标准百秒)
    char *pdata;                 // RGB565 像素 (fwidth*fheight*2)
    struct _OhosGifFrameInfo *next;
} OhosGifFrameInfo;

typedef struct {
    int32_t id;
    int32_t width, height;       // GIF 逻辑屏幕尺寸
    int bg_color;
    int frame_count;
    OhosGifFrameInfo *first;     // 帧链表头
} OhosGifHeader;
```

### 3005: 释放 GIF 资源

遍历帧链表释放每个 `frame->pdata`（RGB565 缓冲）和 `frame` 自身，最后释放 `header`。

### 3011: 显示 GIF 动画

1. 调用 `ohos_gif_decode` 解码 GIF
2. 分配动画槽（最多 8 个并行动画）
3. 绘制第一帧到 mr_screenBuf
4. 返回动画句柄（`T_DSM_COMMON_RSP{p1=handle}`）

动画帧切换由 `ohos_gif_tick()` 驱动（见下文）。

### 3012: 停止动画

按句柄查找动画槽，停止 `running` 标志，释放 GIF 资源（header + 帧链表 + 动画结构体）。

### ohos_gif_tick: 动画帧推进

GIF 动画不使用宿主 OS 定时器（因为 mr_screenBuf 写入必须与 vmrp worker 线程串行），而是集成到 vmrp 的 timer 循环中：

```
mr_timer() → ... → ohos_gif_tick()
                        ↓
                   遍历活动动画
                   anim->current_frame++
                   找到当前帧 → blit_rgb565_to_screen()
                   链表结尾 → current_frame=0 (循环播放)
```

**帧率控制**：当前实现每个 timer tick（约 50ms）推进一帧。SkyEngine 的 `delay_time` 单位是 10ms，但精确的 delay_time 控制需要更细粒度的 tick 或累加计时。对 MRP 小游戏中的 GIF 动画（通常帧数少、delay 简单），此简化足够。

**CMake patch**：`ohos_gif_tick()` 调用通过 `OHOS_GIF_TICK` 幓等 patch 注入到 `mythroad.c` 的 `mr_timer()` 末尾：

```c
// mythroad.c mr_timer() 末尾 (CMake patch)
{ extern void ohos_gif_tick(void); ohos_gif_tick(); }
return MR_SUCCESS;
```

## 3007/3008 图层接口

- **3007 (MR_DRAW_BUFFER)**：在 MTK 平台上做 GDI 图层 blt 到屏幕。vmrp 的 `mr_screenBuf` 已由渲染循环自动刷新，3007 为空操作返回 `MR_SUCCESS`。
- **3008 (MR_GET_ACT_LAYER)**：返回 MTK GDI `gdi_layer_struct`，包含大量函数指针和内部字段。vmrp 无 MTK GDI 层，无法提供有意义的结构体，返回 `MR_IGNORE`。

这两个接口在 MRP 应用中极少被直接调用（应用通常使用 3009 DMA 刷屏等更高层接口）。

## 依赖

- **鸿蒙 SDK 库**：`libimage_source.so` + `libpixelmap.so` (API 12+)
- **CMake 链接**：`target_link_libraries(vmrp-shared image_source pixelmap)` （plain signature，因 vmrp/CMakeLists.txt 使用 plain signature）
- **编译宏**：`__OHOS__`（由 scripts/CMakeLists.txt 在 vmrp-shared target 上定义）

## 导出符号

```
ohos_image_get_info      # 3001 获取图片信息
ohos_image_decode        # 3002 图片解码→RGB565
ohos_image_display_lcd   # 3009 DMA 刷屏
ohos_image_draw_direct   # 3010 直接绘制图片
ohos_gif_decode          # 3004 GIF 解码
ohos_gif_release         # 3005 释放 GIF 资源
ohos_gif_display         # 3011 显示 GIF 动画
ohos_gif_stop            # 3012 停止动画
ohos_gif_tick            # 动画帧推进（mr_timer 调用）
```

## CMake Patches

| Patch ID | 文件 | 作用 |
|----------|------|------|
| `__OHOS__` macro | vmrp-shared target | 使 dsm.c 中 `#ifdef __OHOS__` 代码生效 |
| `OHOS_GIF_TICK` | mythroad.c | mr_timer 末尾注入 ohos_gif_tick() 调用 |

## 已知限制

1. **GIF 帧率精度**：当前每 timer tick（~50ms）推进一帧，对 delay_time<5 的帧会偏慢，delay_time>5 的帧会偏快。未来可改进为累加计时精确控制。
2. **3008 图层结构体**：未实现，无法支持依赖 MTK GDI 层的 MRP 应用。
3. **3014/3015 MTK 资源格式**：未实现，MTK 专有二进制图片/动画格式，优先级低。
4. **内存开销**：GIF 全帧解码一次加载所有帧到内存，大 GIF 可能占用较多内存。每帧 RGB565 像素 = width×height×2 字节。
5. **透明色处理**：GIF 帧的 `transparent_flag` 和 `transparent_color` 字段已定义但未实现透明像素跳过逻辑。
