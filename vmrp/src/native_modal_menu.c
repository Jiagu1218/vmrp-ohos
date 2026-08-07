/*
 * native_modal_menu.c — mr_menuCreate/SetItem/Show 的平台模态 UI。
 *
 * 与 native_text_widget 平级:被 native_dsm_funcs.c 的 .mr_menuShow 回调
 * 调用,runtime 通过 native_modal_menu_filter_event 拦截平台输入。本模块不
 * 改 wrapper 任何状态、不动 ARM ext 表;mr_menuShow 只负责显示并返回，
 * 后续选择由 runtime 通过 event(MR_MENU_SELECT, idx, 0) 通知 wrapper。
 *
 * 与 native_text_widget 的关键差异:
 * - 两者都非阻塞，由公共 runtime event filter 接管平台 UI 输入
 * - text widget 一次性投递 MR_DIALOG_EVENT;菜单投递 MR_MENU_SELECT idx
 * - text widget 反复渲染;菜单在按键或触摸改变焦点时重绘
 */

#include "./include/native_modal_menu.h"
#include "./include/native_text_widget.h"   /* 复用 UCS2 字库与 draw_string */
#include "./include/bridge.h"               /* guiDrawBitmap 上屏 */
#include "./include/skyengine.h"            /* event() 主线程事件漏斗 */
#include "./include/types.h"                /* MR_KEY_* / MR_* event ABI */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ------ 布局 ------ */
#define MENU_COLOR_BG       0x0000  /* 纯黑背景 */
#define MENU_COLOR_TEXT     0x07E0  /* RGB565 绿(与 text widget 一致) */
#define MENU_COLOR_HIBG     0x001F  /* 高亮项:深蓝底 */
#define MENU_COLOR_HITXT    0xFFFF  /* 高亮项:白字 */
#define MENU_COLOR_BORDER   0x07E0  /* 边框绿 */
#define MENU_TITLE_Y        8       /* 标题基线 */
#define MENU_ITEM_Y         40      /* 第一项基线 */
#define MENU_ITEM_DY        22      /* 行距 */
#define MENU_ITEM_X         16
#define MENU_MAX_ITEMS      32      /* 上限避免 wrapper 乱塞 */
#define MENU_SOFTBAR_H      26
#define MENU_LABEL_MARGIN_X 4

/* ------ 单例状态 ------ */
typedef struct {
    int         active;
    int32_t     handle;
    uint16_t   *title;       /* 主机序码点,NUL 结尾 */
    int32_t     item_count;
    uint16_t   *items[MENU_MAX_ITEMS];  /* 每项主机序码点 */
    int         selected;    /* 当前高亮 0..count-1 */
} ModalMenu;

static ModalMenu g_menu;
/* 菜单关闭发生在 MR_KEY_PRESS 回调内；保存平台已接管的键，确保随后到达
 * 的配对 MR_KEY_RELEASE 仍由同一平台层消费，不泄漏给 guest。 */
static int32_t g_captured_key = -1;

enum {
    MENU_TOUCH_TARGET_BACK = -3,
    MENU_TOUCH_TARGET_OK = -2,
    MENU_TOUCH_TARGET_NONE = -1
};
/* 与按键相同，触摸所有权从 DOWN 延续到 UP。目标另存是为了只让完整落在
 * 同一控件内的手势生效；菜单在手势中途刷新时仍消费 UP，但取消旧目标动作。 */
static int g_captured_touch_active;
static int g_captured_touch_target = MENU_TOUCH_TARGET_NONE;

/* 选中时高亮背景矩形;非选中时不画高亮背景。 */
static void menu_fill_rect(uint16_t *page, int pw, int ph,
                            int x, int y, int w, int h, uint16_t color) {
    int x_end = x + w; if (x_end > pw) x_end = pw;
    int y_end = y + h; if (y_end > ph) y_end = ph;
    if (x < 0) x = 0;
    if (y < 0) y = 0;
    for (int yy = y; yy < y_end; yy++) {
        for (int xx = x; xx < x_end; xx++) {
            page[yy * pw + xx] = color;
        }
    }
}

/* 画一条水平线(画框用)。 */
static void menu_hline(uint16_t *page, int pw, int ph,
                       int x, int y, int w, uint16_t color) {
    if (y < 0 || y >= ph) return;
    int x_end = x + w; if (x_end > pw) x_end = pw;
    if (x < 0) x = 0;
    for (int xx = x; xx < x_end; xx++) page[y * pw + xx] = color;
}

/* 转换 UCS2-BE 字节流 → 主机序 uint16 数组(NUL 结尾)。
 * 失败返回 NULL。 */
static uint16_t *ucs2be_to_host(const char *s) {
    if (s == NULL) {
        uint16_t *z = (uint16_t *)malloc(sizeof(uint16_t));
        if (z) z[0] = 0;
        return z;
    }
    const uint8_t *p = (const uint8_t *)s;
    size_t n = 0;
    while (((uint16_t)(p[n * 2] << 8) | p[n * 2 + 1]) != 0) n++;
    uint16_t *out = (uint16_t *)malloc((n + 1) * sizeof(uint16_t));
    if (out == NULL) return NULL;
    for (size_t i = 0; i < n; i++) {
        out[i] = (uint16_t)((p[i * 2] << 8) | p[i * 2 + 1]);
    }
    out[n] = 0;
    return out;
}

/* 把当前菜单渲染到 RGB565 page 并上屏。空字符串安全。 */
static int menu_render_and_present(void) {
    int pw = skyengine_display_width();
    int ph = skyengine_display_height();
    if (pw <= 0 || ph <= 0) return 0;
    uint16_t *page = (uint16_t *)calloc((size_t)pw * (size_t)ph, sizeof(uint16_t));
    if (page == NULL) return 0;

    if (getenv("SKYENGINE_DEBUG_MENU")) {
        fprintf(stderr, "DBG menu_render title=%p items=%d selected=%d pw=%d ph=%d\n",
                (void *)g_menu.title, g_menu.item_count, g_menu.selected, pw, ph);
        if (g_menu.title != NULL) {
            fprintf(stderr, "DBG title[0..3] = %04x %04x %04x %04x\n",
                    g_menu.title[0], g_menu.title[1], g_menu.title[2], g_menu.title[3]);
        }
    }

    /* 背景:纯黑。菜单用不透明底色，关闭后恢复最后一帧 guest 镜像。 */
    for (int i = 0; i < pw * ph; i++) page[i] = MENU_COLOR_BG;

    /* 边框:上下两条线,左右不画(节省) */
    menu_hline(page, pw, ph, 0, 0, pw, MENU_COLOR_BORDER);
    menu_hline(page, pw, ph, 0, ph - 1, pw, MENU_COLOR_BORDER);

    /* 标题 */
    int title_drawn_x = MENU_ITEM_X;
    if (g_menu.title != NULL && g_menu.title[0] != 0) {
        title_drawn_x = native_text_widget_draw_string(page, pw, ph,
                                        g_menu.title, MENU_ITEM_X, MENU_TITLE_Y);
    }
    if (getenv("SKYENGINE_DEBUG_MENU")) {
        fprintf(stderr, "DBG title_drawn_x=%d (>= item_x means rendered)\n", title_drawn_x);
    }

    /* 选项:每项占 MENU_ITEM_DY 高度,选中项画蓝底白字 */
    for (int i = 0; i < g_menu.item_count; i++) {
        int y = MENU_ITEM_Y + i * MENU_ITEM_DY;
        if (i == g_menu.selected) {
            menu_fill_rect(page, pw, ph, 0, y - 2, pw, MENU_ITEM_DY, MENU_COLOR_HIBG);
        }
        const uint16_t *s = g_menu.items[i];
        if (s == NULL) continue;
        uint16_t *tmp = (i == g_menu.selected)
            ? NULL  /* 暂存无所谓颜色,直接逐字符画 */
            : NULL;
        (void)tmp;
        /* 选中项用白色,其他用绿色;绘制 API 不支持颜色参数,
         * 所以这里直接在 page 上覆盖绘制。文字位置 y 是基线,
         * 字模 16px 往上,所以背景范围要延伸到 y-2 到 y+14。 */
        if (i != g_menu.selected) {
            native_text_widget_draw_string(page, pw, ph, s, MENU_ITEM_X, y);
        }
    }
    /* 第二遍画选中项(背景已是蓝,文字覆盖即可,但默认字模是绿色会被蓝底吞) */
    if (g_menu.selected >= 0 && g_menu.selected < g_menu.item_count) {
        const uint16_t *s = g_menu.items[g_menu.selected];
        if (s != NULL) {
            int y = MENU_ITEM_Y + g_menu.selected * MENU_ITEM_DY;
            /* 高亮项字体颜色是绿(0x07E0)在蓝底上对比度还行;
             * 想精确白色可以另写,但这里用现成 draw_string 简单实现。 */
            native_text_widget_draw_string(page, pw, ph, s, MENU_ITEM_X, y);
        }
    }

    /* 平台菜单软键栏：清掉可能延伸到底部的选项背景，再绘制分隔线和
     * 固定操作标签。字形与 dialog/text widget 使用同一平台 UCS2 字库。 */
    int bar_y = ph - MENU_SOFTBAR_H;
    if (bar_y >= 0) {
        static const uint16_t label_ok[] = {0x786E, 0x5B9A, 0};   /* 确定 */
        static const uint16_t label_back[] = {0x8FD4, 0x56DE, 0}; /* 返回 */
        menu_fill_rect(page, pw, ph, 0, bar_y, pw, MENU_SOFTBAR_H, MENU_COLOR_BG);
        menu_hline(page, pw, ph, 0, bar_y, pw, MENU_COLOR_BORDER);
        int label_y = bar_y + 5;
        native_text_widget_draw_string(page, pw, ph, label_ok,
                                       MENU_LABEL_MARGIN_X, label_y);
        int back_x = pw - native_text_widget_string_width(label_back) - MENU_LABEL_MARGIN_X;
        native_text_widget_draw_string(page, pw, ph, label_back, back_x, label_y);
    }

    /* 平台 overlay 上屏，不把菜单页写进共享的 guest 显示镜像。 */
    native_text_widget_present_platform_frame(page, pw, ph);
    free(page);
    return 1;
}

int native_modal_menu_active(void) {
    return g_menu.active;
}

static void menu_free_content(ModalMenu *menu) {
    free(menu->title);
    menu->title = NULL;
    for (int i = 0; i < menu->item_count; i++) {
        free(menu->items[i]);
        menu->items[i] = NULL;
    }
    menu->item_count = 0;
}

void native_modal_menu_dismiss(void) {
    if (!g_menu.active) return;
    menu_free_content(&g_menu);
    g_menu.selected = 0;
    g_menu.active = 0;
    g_menu.handle = 0;
    /* 平台菜单覆盖的是 guest 画面；关闭时露出镜像中的最后一帧。 */
    native_text_widget_restore_guest_frame();
}

int32_t native_modal_menu_release(int32_t handle) {
    if (!g_menu.active || g_menu.handle != handle) return MR_IGNORE;
    native_modal_menu_dismiss();
    return MR_SUCCESS;
}

void native_modal_menu_destroy(void) {
    native_modal_menu_dismiss();
    g_captured_key = -1;
    g_captured_touch_active = 0;
    g_captured_touch_target = MENU_TOUCH_TARGET_NONE;
}

/* 异步显示平台菜单。white wrapper 的 mr_menuShow veneer(cfunction.ext
 * 0x3fdc/0x42bc)直接返回平台调用结果，选择则由独立的 code 4/5 事件路径
 * (0x4168)处理；因此这里不能嵌套等待，否则调用它的 guest KEYDOWN 也无法
 * 返回，E2E 更不可能确认该按键已消费。 */
int32_t native_modal_menu_show(int32_t handle, const char *title_ucs2be,
                               const char *const *items_ucs2be,
                               int32_t item_count) {
    if (handle <= 0) return -1;
    if (g_menu.active && g_menu.handle != handle) return -2;
    if (item_count <= 0 || item_count > MENU_MAX_ITEMS) return -3;
    if (!native_text_widget_font_ready()) return -4;

    ModalMenu next = {0};
    next.title = ucs2be_to_host(title_ucs2be);
    if (next.title == NULL) return -5;
    for (int i = 0; i < item_count; i++) {
        next.items[i] = ucs2be_to_host(items_ucs2be[i]);
        if (next.items[i] == NULL) {
            menu_free_content(&next);
            return -6;
        }
        next.item_count++;
    }
    /* Refresh 当前 handle 时保留焦点；菜单缩短则夹到最后一个有效项。 */
    next.selected = g_menu.active ? g_menu.selected : 0;
    if (next.selected >= item_count) next.selected = item_count - 1;
    next.handle = handle;
    next.active = 1;

    ModalMenu previous = g_menu;
    g_menu = next;
    if (!menu_render_and_present()) {
        menu_free_content(&g_menu);
        g_menu = previous;
        return -7;
    }
    menu_free_content(&previous);
    /* Refresh 可能替换同一 handle 的文本和行数；旧 DOWN 的目标不再有效，
     * 但保留 capture 标记，使它的配对 UP 仍由平台层消费。 */
    if (g_captured_touch_active) {
        g_captured_touch_target = MENU_TOUCH_TARGET_NONE;
    }
    return handle;
}

/* 选定并通知 wrapper。返回 0 成功,<0 失败。 */
static int menu_select_and_post(int32_t idx, int cancelled) {
    /* 回调可能同步创建子菜单或 dialog；延迟 guest 镜像恢复，避免两层
     * 平台 UI 之间提交一帧底层应用画面。 */
    native_text_widget_transition_begin();
    native_modal_menu_dismiss();

    /* MR_MENU_RETURN 用 code=5 + p0=0;
     * MR_MENU_SELECT 用 code=4 + p0=idx(>=0) */
    int32_t code = cancelled ? 5 /* MR_MENU_RETURN */ : 4 /* MR_MENU_SELECT */;
    int32_t p0 = cancelled ? 0 : idx;
    /* runtime 线程同步投递:wrapper 的 mr_event_function 立即被调，
     * 完成后返回当前平台输入路径。 */
    event(code, p0, 0);
    native_text_widget_transition_end();
    return 0;
}

/* 调整选中项并重绘,边界 wrap。 */
static void menu_move_selection(int delta) {
    int n = g_menu.item_count;
    if (n <= 0) return;
    int next = g_menu.selected + delta;
    /* Python-style modulo for negative support */
    next = ((next % n) + n) % n;
    if (next != g_menu.selected) {
        g_menu.selected = next;
        menu_render_and_present();
    }
}

/* 命中区与 menu_render_and_present 使用同一组布局常量，避免触摸区域随
 * 分辨率或软键栏位置变化后偏离可见控件。返回菜单 index 或软键目标。 */
static int menu_touch_target(int x, int y) {
    int pw = skyengine_display_width();
    int ph = skyengine_display_height();
    if (pw <= 0 || ph <= 0 || x < 0 || x >= pw || y < 0 || y >= ph) {
        return MENU_TOUCH_TARGET_NONE;
    }

    int bar_y = ph - MENU_SOFTBAR_H;
    if (bar_y >= 0 && y >= bar_y) {
        return x < pw / 2 ? MENU_TOUCH_TARGET_OK : MENU_TOUCH_TARGET_BACK;
    }

    int first_item_y = MENU_ITEM_Y - 2;
    if (y < first_item_y) return MENU_TOUCH_TARGET_NONE;
    int index = (y - first_item_y) / MENU_ITEM_DY;
    return index < g_menu.item_count ? index : MENU_TOUCH_TARGET_NONE;
}

int native_modal_menu_filter_event(int32_t code, int32_t p0, int32_t p1) {
    /* 选择回调可能已经关闭当前菜单，但该 press 的 release 仍归平台所有。 */
    if (code == MR_KEY_RELEASE && p0 == g_captured_key) {
        g_captured_key = -1;
        return 1;
    }
    /* UP 必须由捕获 DOWN 的平台层闭环；先清 capture 再同步回调，避免回调
     * 创建的子菜单继承旧手势。刷新/关闭过的目标只消费，不执行选择。 */
    if (code == MR_MOUSE_UP && g_captured_touch_active) {
        int target = g_captured_touch_target;
        int release_target = g_menu.active
            ? menu_touch_target(p0, p1)
            : MENU_TOUCH_TARGET_NONE;
        g_captured_touch_active = 0;
        g_captured_touch_target = MENU_TOUCH_TARGET_NONE;
        if (target != MENU_TOUCH_TARGET_NONE && target == release_target) {
            if (target >= 0) {
                menu_select_and_post(target, 0);
            } else if (target == MENU_TOUCH_TARGET_OK) {
                menu_select_and_post(g_menu.selected, 0);
            } else if (target == MENU_TOUCH_TARGET_BACK) {
                menu_select_and_post(0, 1);
            }
        }
        return 1;
    }
    if (code == MR_MOUSE_MOVE && g_captured_touch_active) return 1;
    if (!g_menu.active) return 0;

    switch (code) {
    case MR_KEY_PRESS:
        g_captured_key = p0;
        if (p0 == MR_KEY_DOWN) {
            menu_move_selection(+1);
        } else if (p0 == MR_KEY_UP) {
            menu_move_selection(-1);
        } else if (p0 == MR_KEY_SELECT || p0 == MR_KEY_SOFTLEFT) {
            menu_select_and_post(g_menu.selected, 0);
        } else if (p0 == MR_KEY_SOFTRIGHT || p0 == MR_KEY_POWER) {
            menu_select_and_post(0, 1);
        }
        return 1;
    case MR_KEY_RELEASE:
        /* 没有命中 g_captured_key，说明对应 press 在菜单打开前已交给 guest
         * （典型路径是该 press 自己打开菜单）；release 也必须交还 guest。 */
        return 0;
    case MR_MOUSE_DOWN: {
        int target = menu_touch_target(p0, p1);
        g_captured_touch_active = 1;
        g_captured_touch_target = target;
        if (target >= 0 && target != g_menu.selected) {
            g_menu.selected = target;
            menu_render_and_present();
        }
        return 1;
    }
    case MR_MOUSE_UP:
        /* DOWN 在菜单打开前已交给 guest 时，配对 UP 也必须交还 guest。 */
        return 0;
    case MR_MOUSE_MOVE:
        /* 平台菜单显示期间拥有全部用户输入，未使用的输入也不能穿透。 */
        return 1;
    default:
        /* 网络、dialog 和其它平台事件继续投递。 */
        return 0;
    }
}
