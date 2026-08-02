#ifndef __OHOS_NATIVE_MENU_STATE_H__
#define __OHOS_NATIVE_MENU_STATE_H__

#include <stdint.h>

/*
 * 平台菜单状态管理(OHOS 移植)。
 * title/text 参数为 UCS2-BE(网络字节序),与 SkyEngine mr_menuCreate 一致。
 * 状态由 ARM ext(aex_table table[63-68])写入,由 skyengine_api 导出给前端读取。
 */

/* 生命周期(由 aex_table handler 调用) */
int32_t native_menu_create(const char *title_ucs2be, int16_t num);
int32_t native_menu_set_item(int32_t menu, const char *text_ucs2be, int32_t index);
int32_t native_menu_show(int32_t menu);
int32_t native_menu_release(int32_t menu);
int32_t native_menu_refresh(int32_t menu);

/* event 执行上下文标志:set 1 时 menuShow 延迟激活(避免 event 内部破坏 timer owner) */
extern int native_menu_in_event;
void native_menu_flush_pending(void);

/* 引擎停止/销毁时清理(防多 MRP 切换残留) */
void native_menu_reset(void);

/* 状态查询(由 skyengine_api 导出给 OHOS 前端) */
int native_menu_is_active(void);
const char *native_menu_get_title(void);
int native_menu_get_item_count(void);
const char *native_menu_get_item(int index);

#endif
