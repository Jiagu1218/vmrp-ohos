/*
 * native_modal_menu.c —— 通用平台模态菜单实现。
 *
 * 功能:全屏菜单列表 + 标题栏 + 选中项高亮 + 底部软键栏,
 * 支持触屏(点击选中/软键 hit-test)和键盘。
 * 视觉风格由 NativeWidgetTheme(在 native_text_widget 中定义)控制。
 *
 * 触屏:filter_event 接收 p1 作为 y 坐标(p0=x),由
 * skyengine_runtime_event 统一传入,无需全局变量。
 */
#include "./include/native_modal_menu.h"
#include "./include/native_text_widget.h"
#include "./include/bridge.h"
#include "./include/skyengine.h"
#include "./include/types.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* 布局常量 */
#define MENU_TITLE_Y        8
#define MENU_ITEM_Y         40
#define MENU_ITEM_DY        22
#define MENU_ITEM_X         16
#define MENU_MAX_ITEMS      32
#define MENU_SOFTBAR_H      26
#define MENU_LABEL_MARGIN_X 4

typedef struct {
    int         active;
    int32_t     handle;
    uint16_t   *title;
    int32_t     item_count;
    uint16_t   *items[MENU_MAX_ITEMS];
    int         selected;
} ModalMenu;

static ModalMenu g_menu;
static int32_t g_captured_key = -1;

static void menu_fill_rect(uint16_t *page, int pw, int ph,
                            int x, int y, int w, int h, uint16_t color) {
    int x_end = x + w; if (x_end > pw) x_end = pw;
    int y_end = y + h; if (y_end > ph) y_end = ph;
    if (x < 0) x = 0; if (y < 0) y = 0;
    for (int yy = y; yy < y_end; yy++)
        for (int xx = x; xx < x_end; xx++)
            page[yy * pw + xx] = color;
}

static void menu_fill_rounded_rect(uint16_t *page, int pw, int ph,
                                    int rx, int ry, int rw, int rh,
                                    int radius, uint16_t color) {
    int r = radius;
    if (r * 2 > rw) r = rw / 2;
    if (r * 2 > rh) r = rh / 2;
    int cx = rx + r, cy = ry + r;
    int r2 = r * r;
    for (int yy = ry; yy < ry + rh && yy < ph; yy++) {
        if (yy < 0) continue;
        int x_start = rx, x_end = rx + rw;
        if (x_start < 0) x_start = 0;
        if (x_end > pw) x_end = pw;
        for (int xx = x_start; xx < x_end; xx++) {
            int dx = 0, dy = 0;
            if (xx < cx) dx = cx - xx;
            else if (xx >= rx + rw - r) dx = xx - (rx + rw - r - 1);
            if (yy < cy) dy = cy - yy;
            else if (yy >= ry + rh - r) dy = yy - (ry + rh - r - 1);
            if (dx > 0 && dy > 0 && dx * dx + dy * dy > r2) continue;
            page[yy * pw + xx] = color;
        }
    }
}

static void menu_hline(uint16_t *page, int pw, int ph,
                       int x, int y, int w, uint16_t color) {
    if (y < 0 || y >= ph) return;
    int x_end = x + w; if (x_end > pw) x_end = pw;
    if (x < 0) x = 0;
    for (int xx = x; xx < x_end; xx++) page[y * pw + xx] = color;
}

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
    for (size_t i = 0; i < n; i++)
        out[i] = (uint16_t)((p[i * 2] << 8) | p[i * 2 + 1]);
    out[n] = 0;
    return out;
}

/* 渲染:主题驱动外观(标题栏+圆角高亮+灰软键栏) */
static int menu_render_and_present(void) {
    int pw = skyengine_display_width();
    int ph = skyengine_display_height();
    if (pw <= 0 || ph <= 0) return 0;
    uint16_t *page = (uint16_t *)calloc((size_t)pw * (size_t)ph, sizeof(uint16_t));
    if (page == NULL) return 0;

    const NativeWidgetTheme *theme = native_text_widget_get_theme();

    /* 标题栏:灰底 + 居中粗体/左对齐 */
    int title_bar_h = MENU_TITLE_Y + 16 + 6;
    menu_fill_rect(page, pw, ph, 0, 0, pw, title_bar_h, theme->color_bar_bg);
    if (g_menu.title != NULL && g_menu.title[0] != 0) {
        int title_x = MENU_ITEM_X;
        if (theme->title_bold) {
            int title_w = native_text_widget_string_width_bold(g_menu.title);
            if (theme->title_centered) title_x = (pw - title_w) / 2;
            if (title_x < 0) title_x = 0;
            native_text_widget_draw_string_bold(page, pw, ph, g_menu.title, title_x, MENU_TITLE_Y);
        } else {
            int title_w = native_text_widget_string_width(g_menu.title);
            if (theme->title_centered) title_x = (pw - title_w) / 2;
            if (title_x < 0) title_x = 0;
            native_text_widget_draw_string(page, pw, ph, g_menu.title, title_x, MENU_TITLE_Y);
        }
    }
    menu_hline(page, pw, ph, 0, title_bar_h, pw, theme->color_separator);

    /* 选项:选中项圆角高亮底 */
    for (int i = 0; i < g_menu.item_count; i++) {
        int y = MENU_ITEM_Y + i * MENU_ITEM_DY;
        if (i == g_menu.selected) {
            menu_fill_rounded_rect(page, pw, ph, 4, y - 2, pw - 8, MENU_ITEM_DY, 4,
                                   theme->color_highlight_bg);
        }
    }
    /* 文字(使用主题文字色) */
    for (int i = 0; i < g_menu.item_count; i++) {
        int y = MENU_ITEM_Y + i * MENU_ITEM_DY;
        const uint16_t *s = g_menu.items[i];
        if (s != NULL) native_text_widget_draw_string(page, pw, ph, s, MENU_ITEM_X, y);
    }

    /* 软键栏:灰底 + 分隔线 + 标签 */
    int bar_y = ph - MENU_SOFTBAR_H;
    if (bar_y >= 0) {
        static const uint16_t label_ok[] = {0x786E, 0x5B9A, 0};
        static const uint16_t label_back[] = {0x8FD4, 0x56DE, 0};
        menu_fill_rect(page, pw, ph, 0, bar_y, pw, MENU_SOFTBAR_H, theme->color_bar_bg);
        menu_hline(page, pw, ph, 0, bar_y, pw, theme->color_separator);
        int label_y = bar_y + 5;
        native_text_widget_draw_string(page, pw, ph, label_ok, MENU_LABEL_MARGIN_X, label_y);
        int back_x = pw - native_text_widget_string_width(label_back) - MENU_LABEL_MARGIN_X;
        native_text_widget_draw_string(page, pw, ph, label_back, back_x, label_y);
    }

    native_text_widget_present_platform_frame(page, pw, ph);
    free(page);
    return 1;
}

int native_modal_menu_active(void) { return g_menu.active; }

static void menu_free_content(ModalMenu *menu) {
    free(menu->title); menu->title = NULL;
    for (int i = 0; i < menu->item_count; i++) { free(menu->items[i]); menu->items[i] = NULL; }
    menu->item_count = 0;
}

void native_modal_menu_dismiss(void) {
    if (!g_menu.active) return;
    menu_free_content(&g_menu);
    g_menu.selected = 0; g_menu.active = 0; g_menu.handle = 0;
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
}

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
        if (next.items[i] == NULL) { menu_free_content(&next); return -6; }
        next.item_count++;
    }
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
    return handle;
}

static int menu_select_and_post(int32_t idx, int cancelled) {
    native_text_widget_transition_begin();
    native_modal_menu_dismiss();
    int32_t code = cancelled ? 5 : 4;
    int32_t p0 = cancelled ? 0 : idx;
    event(code, p0, 0);
    native_text_widget_transition_end();
    return 0;
}

static void menu_move_selection(int delta) {
    int n = g_menu.item_count;
    if (n <= 0) return;
    int next = (((g_menu.selected + delta) % n) + n) % n;
    if (next != g_menu.selected) {
        g_menu.selected = next;
        menu_render_and_present();
    }
}

/* 触屏 hit-test + 键盘 */
int native_modal_menu_filter_event(int32_t code, int32_t p0, int32_t p1) {
    if (code == MR_KEY_RELEASE && p0 == g_captured_key) {
        g_captured_key = -1;
        return 1;
    }
    if (!g_menu.active) return 0;

    if (code == MR_MOUSE_DOWN) {
        int x = p0;
        int y = p1;
        int ph = skyengine_display_height();
        int pw = skyengine_display_width();
        int bar_y = ph - MENU_SOFTBAR_H;
        if (y >= bar_y) {
            if (x < pw / 2) {
                menu_select_and_post(g_menu.selected, 0);
            } else {
                menu_select_and_post(0, 1);
            }
        } else if (y >= MENU_ITEM_Y - 2) {
            int idx = (y - (MENU_ITEM_Y - 2)) / MENU_ITEM_DY;
            if (idx >= 0 && idx < g_menu.item_count) {
                g_menu.selected = idx;
                menu_render_and_present();
                menu_select_and_post(idx, 0);
            }
        }
        return 1;
    }
    if (code == MR_MOUSE_UP || code == MR_MOUSE_MOVE) return 1;

    switch (code) {
    case MR_KEY_PRESS:
        g_captured_key = p0;
        if (p0 == MR_KEY_DOWN) menu_move_selection(+1);
        else if (p0 == MR_KEY_UP) menu_move_selection(-1);
        else if (p0 == MR_KEY_SELECT || p0 == MR_KEY_SOFTLEFT) menu_select_and_post(g_menu.selected, 0);
        else if (p0 == MR_KEY_SOFTRIGHT || p0 == MR_KEY_POWER) menu_select_and_post(0, 1);
        return 1;
    case MR_KEY_RELEASE:
        return 0;
    default:
        return 0;
    }
}
