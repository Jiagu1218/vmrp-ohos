#ifndef __VMRP_NATIVE_MODAL_MENU_H__
#define __VMRP_NATIVE_MODAL_MENU_H__

#include <stdint.h>

/* 原生菜单 UI 接管 dsm.c mr_menuShow 的回调宿主。
 *
 * 数据流:
 *   mr_menuCreate(title, num)        ─► dsmInFuncs 创建并保存 handle
 *   mr_menuSetItem(handle, text, idx) ─► dsmInFuncs 写入 item
 *   mr_menuShow(handle)              ─► dsmInFuncs 调本模块弹模态
 *   用户选择 ENTER/SELECT             ─► runtime 平台事件过滤器拦截
 *                                       投递 event(MR_MENU_SELECT, idx, 0)
 *                                       或 event(MR_MENU_RETURN, 0, 0) 取消
 *
 * 与 native_text_widget 一样是单例(同一时刻只允许一个菜单)。 */

/* 显示或刷新指定 handle 的模态菜单；成功返回该 handle，失败返回 <0。
 * title 是 UCS-2BE 字符串(以 0x0000 结尾)。
 * items / count 是 UCS-2BE 文本列表,count>0。 */
int32_t native_modal_menu_show(int32_t handle, const char *title_ucs2be,
                               const char *const *items_ucs2be,
                               int32_t item_count);

/* 若 handle 正在显示则关闭对应平台层；未显示返回 MR_IGNORE。 */
int32_t native_modal_menu_release(int32_t handle);

/* guest 事件入口前置过滤。返回 1 表示输入已由平台菜单消费，调用方不得
 * 再投递给应用；返回 0 表示非菜单输入，应继续正常事件路径。 */
int native_modal_menu_filter_event(int32_t code, int32_t p0);

/* 当前是否有菜单在显示(供主循环 / e2e 探测用)。 */
int native_modal_menu_active(void);

/* 释放当前菜单(由 skyengine_request_exit 或测试清理时调用)。
 * 不投递任何事件;只是清掉 active 标志、释放内存。 */
void native_modal_menu_dismiss(void);

/* runtime 销毁时清理菜单和尚未到达的配对 release，避免同进程重启继承状态。 */
void native_modal_menu_destroy(void);

#endif
