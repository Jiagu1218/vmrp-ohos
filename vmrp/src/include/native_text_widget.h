#ifndef __VMRP_NATIVE_TEXT_WIDGET_H__
#define __VMRP_NATIVE_TEXT_WIDGET_H__

#include <stdint.h>

/*
 * 平台文本框/对话框(SKYENGINE mr_text* 与 mr_dialog* 的共用宿主实现)。
 *
 * 真机上文本框是手机平台绘制的全屏只读文本窗口:显示期间按键归平台所有,
 * 平台把软键选择转换成 mr_event(MR_DIALOG_EVENT, MR_DIALOG_KEY_OK/CANCEL)
 * 通知应用,应用收到后调用 mr_textRelease 关闭。此前宿主对 mr_textCreate
 * 直接返回 MR_FAILED,而真实应用(如 gtdgdq 帮助页)先注册模态状态再调
 * mr_textCreate 且不回滚失败,导致应用永远等不到 MR_DIALOG_EVENT,所有
 * 普通按键被模态分发器吞掉,表现为"卡死在菜单"。
 */

/* DSM 桥接:native_dsm_funcs.c 的 textCreate/Release/Refresh 委托到这里。
 * title/text 为 UCS2 大端(网络字节序)字符串,与 SKYENGINE API 手册一致。 */
int32_t native_text_widget_create(const char *title_ucs2be, const char *text_ucs2be, int32_t type);
int32_t native_text_widget_release(int32_t handle);
/* type=-1 保持创建时的按钮类型，非负值按 mr_dialogRefresh 契约更新。 */
int32_t native_text_widget_refresh(int32_t handle, const char *title_ucs2be,
                                   const char *text_ucs2be, int32_t type);

/* 文本框是否正在显示。 */
int native_text_widget_active(void);
/* Runtime 销毁时释放窗口内容、guest 镜像、字库句柄和按键所有权状态。 */
void native_text_widget_destroy(void);
/* 平台 UI 在提交 active 状态前检查共享字库，失败时不得显示空白模态层。 */
int native_text_widget_font_ready(void);

/*
 * 上屏路径钩子:所有 guest 帧上屏(guiDrawBitmapWithStride)前先经过这里。
 * 把该帧写入"guest 显示镜像"(文本框关闭时用它恢复被遮盖的画面),并在
 * 文本框显示期间返回 1 表示本帧不要上屏(真机语义:平台窗口盖在应用画面
 * 之上,应用的绘制发生在窗口之下不可见)。返回 0 表示照常上屏。
 */
int native_text_widget_capture_frame(const uint16_t *bmp, int32_t x, int32_t y,
                                     int32_t w, int32_t h, int32_t stride,
                                     int32_t sx, int32_t sy);

/* 同源平台 UI（如 native_modal_menu）复用 guest 显示镜像：平台帧上屏时
 * 不得写入镜像，关闭 overlay 后重推最后一帧 guest 画面。 */
void native_text_widget_present_platform_frame(uint16_t *bmp, int32_t w, int32_t h);
void native_text_widget_restore_guest_frame(void);

/* 平台层事件回调可能同步关闭当前层并创建下一层。事务期间延迟 guest
 * 镜像恢复，避免两个平台层之间提交一帧底层应用画面。支持嵌套调用。 */
void native_text_widget_transition_begin(void);
void native_text_widget_transition_end(void);

/*
 * 事件钩子:guest 事件入口(skyengine_runtime_event)前置过滤。
 * 返回 0=未激活不拦截;1=事件已被平台消费(不再投递给应用);
 * 2=软键命中文本框按钮,调用方应改投 MR_DIALOG_EVENT,参数写入 *dialog_param。
 */
int native_text_widget_filter_event(int32_t code, int32_t p0, int32_t *dialog_param);

/*
 * 字库/绘制工具:供 native_modal_menu 等同源 UI 复用。
 * 同一份 UCS2-BE → RGB565 解码路径,避免每个 UI 各自 fork 一份字库代码。
 * 与 native_text_widget 内部走相同字库(mythroad/system/gb16.uc2)。 */
#include <stddef.h>
struct TwRenderCtx;
/* 把 UCS2 主机序码点数组写到 RGB565 page 上；字库不可用时返回 -1。 */
int native_text_widget_draw_string(uint16_t *page, int pw, int ph,
                                    const uint16_t *s, int x, int y);
/* UCS2 字符串总宽(像素) */
int native_text_widget_string_width(const uint16_t *s);
/* 单字符宽(ASCII=8,CJK=16) */
int native_text_widget_char_width(uint16_t ch);

#endif
