/*
 * native_text_widget.c —— 通用平台文本框/对话框实现。
 *
 * 功能:全屏只读文本窗口 + 标题栏 + 正文滚动 + 底部软键栏,
 * 支持触屏(拖拽滚动/滚动条点击翻页/软键 hit-test)和键盘。
 * 可通过 NativeWidgetTheme 配置视觉风格(现代/经典)。
 *
 * 触屏:filter_event 接收 p1 作为 y 坐标(p0=x),由
 * skyengine_runtime_event 统一传入,无需全局变量。
 */
#include "./include/native_text_widget.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "./include/bridge.h"
#include "./include/file_lib.h"
#include "./include/native_modal_menu.h"
#include "./include/types.h"
#include "./include/skyengine.h"

/* 布局常量 */
#define TW_MARGIN_X 10
#define TW_TITLE_Y  10
#define TW_CHAR_H   16
#define TW_LINE_H   20
#define TW_BODY_Y   (TW_TITLE_Y + TW_CHAR_H + 10)
#define TW_SOFTBAR_H 28
#define TW_LABEL_MARGIN_X 8
#define TW_SB_WIDTH  8
#define TW_SB_MARGIN 4
#define TW_SB_RADIUS 4

#define TW_FONT_BYTES_PER_CHAR 32

/* ---- 主题 ---- */

const NativeWidgetTheme TW_THEME_MODERN = {
    .color_text         = 0xFFFF,  /* 白色正文 */
    .color_title        = 0xFFFF,  /* 白色标题 */
    .color_bar_bg       = 0x18C3,  /* 灰蓝(渐变起始色) */
    .color_separator    = 0x39E7,  /* 浅灰分隔线 */
    .color_sb_track     = 0x0842,
    .color_sb_thumb     = 0xB5B6,
    .color_highlight_bg = 0x2A69,  /* 选中项蓝 */
    .title_centered     = 1,
    .title_bold         = 1,
    .show_scrollbar     = 1,
};

const NativeWidgetTheme TW_THEME_CLASSIC = {
    .color_text         = 0x07E0,
    .color_title        = 0x07E0,
    .color_bar_bg       = 0x0000,
    .color_separator    = 0x07E0,
    .color_sb_track     = 0x0000,
    .color_sb_thumb     = 0x07E0,
    .color_highlight_bg = 0x001F,
    .title_centered     = 0,
    .title_bold         = 0,
    .show_scrollbar     = 0,
};

static NativeWidgetTheme tw_theme = {
    0xFFFF, 0xFFFF, 0x18C3, 0x39E7, 0x0842, 0xB5B6, 0x2A69, 1, 1, 1
};

void native_text_widget_set_theme(const NativeWidgetTheme *theme) {
    if (theme != NULL) {
        tw_theme = *theme;
    } else {
        tw_theme = TW_THEME_MODERN;
    }
}

const NativeWidgetTheme *native_text_widget_get_theme(void) {
    return &tw_theme;
}

typedef struct {
    int active;
    int32_t handle;
    int32_t type;
    uint16_t *title;
    uint16_t *text;
    int scroll;
    int line_count;
} TextWidget;

static TextWidget tw;
static int32_t tw_handle_gen = 0;
static int32_t tw_captured_key = -1;

static uint16_t *tw_mirror = NULL;
static int tw_mirror_w = 0;
static int tw_mirror_h = 0;
static int tw_mirror_valid = 0;

static int tw_presenting = 0;
static int tw_transition_depth = 0;
static int tw_restore_pending = 0;

static int32_t tw_font_fd = 0;

static int tw_font_open(void) {
    if (tw_font_fd > 0) return 1;
    tw_font_fd = my_open("mythroad/system/gb16.uc2", MR_FILE_RDONLY);
    return tw_font_fd > 0;
}

static int tw_char_width(uint16_t ch) {
    return ch < 128 ? 8 : 16;
}

static int tw_font_glyph(uint16_t ch, uint16_t rows[TW_CHAR_H]) {
    uint8_t buf[TW_FONT_BYTES_PER_CHAR];
    if (my_seek(tw_font_fd, (int32_t)ch * TW_FONT_BYTES_PER_CHAR, 0) < 0) return 0;
    if (my_read(tw_font_fd, buf, TW_FONT_BYTES_PER_CHAR) != TW_FONT_BYTES_PER_CHAR) return 0;
    for (int iy = 0; iy < TW_CHAR_H; iy++) {
        rows[iy] = (uint16_t)((buf[iy * 2] << 8) | buf[iy * 2 + 1]);
    }
    return 1;
}

static uint16_t *tw_ucs2be_dup(const char *s) {
    const uint8_t *p = (const uint8_t *)s;
    size_t n = 0;
    if (p != NULL) {
        while (((uint16_t)(p[n * 2] << 8) | p[n * 2 + 1]) != 0) n++;
    }
    uint16_t *out = (uint16_t *)malloc((n + 1) * sizeof(uint16_t));
    if (out == NULL) return NULL;
    for (size_t i = 0; i < n; i++) {
        out[i] = (uint16_t)((p[i * 2] << 8) | p[i * 2 + 1]);
    }
    out[n] = 0;
    return out;
}

static void tw_draw_char(uint16_t *page, int pw, int ph, uint16_t ch, int x, int y, uint16_t color) {
    uint16_t rows[TW_CHAR_H];
    if (!tw_font_glyph(ch, rows)) return;
    int w = tw_char_width(ch);
    for (int iy = 0; iy < TW_CHAR_H; iy++) {
        int py = y + iy;
        if (py < 0 || py >= ph) continue;
        for (int ix = 0; ix < w; ix++) {
            int px = x + ix;
            if (px < 0 || px >= pw) continue;
            if (rows[iy] & (uint16_t)(1u << (15 - ix))) {
                page[(size_t)py * (size_t)pw + (size_t)px] = color;
            }
        }
    }
}

static void tw_draw_char_bold(uint16_t *page, int pw, int ph, uint16_t ch, int x, int y, uint16_t color) {
    tw_draw_char(page, pw, ph, ch, x, y, color);
    tw_draw_char(page, pw, ph, ch, x + 1, y, color);
}

static int tw_draw_string(uint16_t *page, int pw, int ph, const uint16_t *s, int x, int y, uint16_t color) {
    for (; *s != 0; s++) {
        tw_draw_char(page, pw, ph, *s, x, y, color);
        x += tw_char_width(*s);
    }
    return x;
}

static int tw_draw_string_bold(uint16_t *page, int pw, int ph, const uint16_t *s, int x, int y, uint16_t color) {
    for (; *s != 0; s++) {
        tw_draw_char_bold(page, pw, ph, *s, x, y, color);
        x += tw_char_width(*s) + 1;
    }
    return x;
}

static int tw_string_width(const uint16_t *s) {
    int w = 0;
    for (; *s != 0; s++) w += tw_char_width(*s);
    return w;
}

static int tw_string_width_bold(const uint16_t *s) {
    int w = 0;
    for (; *s != 0; s++) w += tw_char_width(*s) + 1;
    return w;
}

static void tw_fill_rect(uint16_t *page, int pw, int ph,
                         int x, int y, int w, int h, uint16_t color) {
    int x_end = x + w; if (x_end > pw) x_end = pw;
    int y_end = y + h; if (y_end > ph) y_end = ph;
    if (x < 0) x = 0; if (y < 0) y = 0;
    for (int yy = y; yy < y_end; yy++)
        for (int xx = x; xx < x_end; xx++)
            page[(size_t)yy * (size_t)pw + (size_t)xx] = color;
}

/* RGB565 颜色暗化(k=0~7,0=原色,7=最暗),用于渐变结束色 */
static uint16_t tw_darken(uint16_t c, int k) {
    if (k <= 0) return c;
    if (k > 7) k = 7;
    int r5 = (c >> 11) & 0x1F, g6 = (c >> 5) & 0x3F, b5 = c & 0x1F;
    r5 = (r5 * (8 - k)) >> 3;
    g6 = (g6 * (8 - k)) >> 3;
    b5 = (b5 * (8 - k)) >> 3;
    return (uint16_t)((r5 << 11) | (g6 << 5) | b5);
}

/* RGB565 两色线性插值,t=0~256 */
static uint16_t tw_lerp565(uint16_t c1, uint16_t c2, int t) {
    if (t <= 0) return c1;
    if (t >= 256) return c2;
    int r = ((c1 >> 11) & 0x1F) * (256 - t) + ((c2 >> 11) & 0x1F) * t;
    int g = ((c1 >> 5) & 0x3F) * (256 - t) + ((c2 >> 5) & 0x3F) * t;
    int b = (c1 & 0x1F) * (256 - t) + (c2 & 0x1F) * t;
    return (uint16_t)((r >> 8) << 11 | (g >> 8) << 5 | (b >> 8));
}

/* 垂直渐变填充矩形(从上到下 c1→c2) */
static void tw_fill_rect_vgradient(uint16_t *page, int pw, int ph,
                                   int x, int y, int w, int h,
                                   uint16_t c1, uint16_t c2) {
    int x_end = x + w; if (x_end > pw) x_end = pw;
    int y_end = y + h; if (y_end > ph) y_end = ph;
    if (x < 0) x = 0; if (y < 0) y = 0;
    int real_h = y_end - y;
    for (int yy = y; yy < y_end; yy++) {
        int t = real_h > 1 ? ((yy - y) * 256) / (real_h - 1) : 0;
        uint16_t c = tw_lerp565(c1, c2, t);
        for (int xx = x; xx < x_end; xx++)
            page[(size_t)yy * (size_t)pw + (size_t)xx] = c;
    }
}

static void tw_fill_rounded_rect(uint16_t *page, int pw, int ph,
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
            page[(size_t)yy * (size_t)pw + (size_t)xx] = color;
        }
    }
}

/* 公开接口(供 native_modal_menu 复用)——使用当前主题文字色 */
int native_text_widget_draw_string(uint16_t *page, int pw, int ph,
                                    const uint16_t *s, int x, int y) {
    if (!tw_font_open()) return -1;
    return tw_draw_string(page, pw, ph, s, x, y, tw_theme.color_text);
}
/* 带颜色的绘制版本(供选中项反白等场景) */
int native_text_widget_draw_string_color(uint16_t *page, int pw, int ph,
                                         const uint16_t *s, int x, int y,
                                         uint16_t color) {
    if (!tw_font_open()) return -1;
    return tw_draw_string(page, pw, ph, s, x, y, color);
}

int native_text_widget_string_width(const uint16_t *s) {
    if (!tw_font_open()) return 0;
    return tw_string_width(s);
}

int native_text_widget_char_width(uint16_t ch) {
    return tw_char_width(ch);
}

int native_text_widget_draw_string_bold(uint16_t *page, int pw, int ph,
                                         const uint16_t *s, int x, int y) {
    if (!tw_font_open()) return -1;
    return tw_draw_string_bold(page, pw, ph, s, x, y, tw_theme.color_text);
}

int native_text_widget_string_width_bold(const uint16_t *s) {
    if (!tw_font_open()) return 0;
    return tw_string_width_bold(s);
}

typedef void (*tw_line_char_fn)(void *ctx, uint16_t ch, int line, int x);

static int tw_layout_body(const uint16_t *s, int pw, tw_line_char_fn fn, void *ctx) {
    int line = 0;
    int x = TW_MARGIN_X;
    for (; *s != 0; s++) {
        uint16_t ch = *s;
        if (ch == '\r') continue;
        if (ch == '\n') { line++; x = TW_MARGIN_X; continue; }
        int w = tw_char_width(ch);
        if (x + w > pw - TW_MARGIN_X) { line++; x = TW_MARGIN_X; }
        if (fn != NULL) fn(ctx, ch, line, x);
        x += w;
    }
    return line + 1;
}

typedef struct {
    uint16_t *page;
    int pw, ph;
    int first_line;
    int max_lines;
} TwRenderCtx;

static void tw_render_body_char(void *vctx, uint16_t ch, int line, int x) {
    TwRenderCtx *ctx = (TwRenderCtx *)vctx;
    int vis = line - ctx->first_line;
    if (vis < 0 || vis >= ctx->max_lines) return;
    tw_draw_char(ctx->page, ctx->pw, ctx->ph, ch, x, TW_BODY_Y + vis * TW_LINE_H, tw_theme.color_text);
}

static int tw_visible_lines(int ph) {
    int body_h = (ph - TW_SOFTBAR_H) - TW_BODY_Y;
    return body_h > 0 ? body_h / TW_LINE_H : 0;
}

/* 渲染:主题驱动外观(标题栏+居中粗体+滚动条+底栏) */
static void tw_render_and_present(void) {
    int pw = skyengine_display_width();
    int ph = skyengine_display_height();
    uint16_t *page = (uint16_t *)calloc((size_t)pw * (size_t)ph, sizeof(uint16_t));
    if (page == NULL) return;

    /* 标题栏背景(垂直渐变:bar_bg → darken(bar_bg,3)) */
    int title_bar_h = TW_TITLE_Y + TW_CHAR_H + 6;
    tw_fill_rect_vgradient(page, pw, ph, 0, 0, pw, title_bar_h,
                           tw_theme.color_bar_bg, tw_darken(tw_theme.color_bar_bg, 3));

    /* 标题:居中/左对齐 + 普通/粗体 */
    int title_x = TW_MARGIN_X;
    if (tw_theme.title_bold) {
        int title_w = tw_string_width_bold(tw.title);
        if (tw_theme.title_centered) title_x = (pw - title_w) / 2;
        if (title_x < 0) title_x = 0;
        tw_draw_string_bold(page, pw, ph, tw.title, title_x, TW_TITLE_Y, tw_theme.color_title);
    } else {
        int title_w = tw_string_width(tw.title);
        if (tw_theme.title_centered) title_x = (pw - title_w) / 2;
        if (title_x < 0) title_x = 0;
        tw_draw_string(page, pw, ph, tw.title, title_x, TW_TITLE_Y, tw_theme.color_title);
    }

    /* 标题下方分隔线 */
    int sep_y = title_bar_h;
    if (sep_y >= 0 && sep_y < ph) {
        for (int x = 0; x < pw; x++) page[(size_t)sep_y * (size_t)pw + (size_t)x] = tw_theme.color_separator;
    }

    /* 正文(带滚动) */
    int vis_lines = tw_visible_lines(ph);
    TwRenderCtx ctx = {page, pw, ph, tw.scroll, vis_lines};
    tw.line_count = tw_layout_body(tw.text, pw, tw_render_body_char, &ctx);

    /* 滚动条(主题启用+内容溢出时) */
    if (tw_theme.show_scrollbar && tw.line_count > vis_lines && vis_lines > 0) {
        int sb_x = pw - TW_SB_WIDTH - TW_SB_MARGIN;
        int sb_track_y = TW_BODY_Y + 2;
        int sb_track_h = (ph - TW_SOFTBAR_H) - TW_BODY_Y - 4;
        tw_fill_rounded_rect(page, pw, ph, sb_x, sb_track_y,
                             TW_SB_WIDTH, sb_track_h,
                             TW_SB_WIDTH / 2, tw_theme.color_sb_track);
        int thumb_h = sb_track_h * vis_lines / tw.line_count;
        if (thumb_h < TW_SB_WIDTH * 2) thumb_h = TW_SB_WIDTH * 2;
        int max_scroll = tw.line_count - vis_lines;
        int thumb_y = sb_track_y + (tw.scroll * (sb_track_h - thumb_h)) / max_scroll;
        tw_fill_rounded_rect(page, pw, ph, sb_x, thumb_y,
                             TW_SB_WIDTH, thumb_h,
                             TW_SB_RADIUS, tw_theme.color_sb_thumb);
    }

    /* 底部软键栏(渐变:darken → bar_bg,底部更亮) */
    int bar_y = ph - TW_SOFTBAR_H;
    tw_fill_rect_vgradient(page, pw, ph, 0, bar_y, pw, TW_SOFTBAR_H,
                           tw_darken(tw_theme.color_bar_bg, 3), tw_theme.color_bar_bg);
    static const uint16_t label_ok[] = {0x786E, 0x5B9A, 0};
    static const uint16_t label_cancel[] = {0x53D6, 0x6D88, 0};
    int label_y = bar_y + (TW_SOFTBAR_H - TW_CHAR_H) / 2;
    if (tw.type == MR_DIALOG_OK || tw.type == MR_DIALOG_OK_CANCEL) {
        tw_draw_string(page, pw, ph, label_ok, TW_LABEL_MARGIN_X, label_y, tw_theme.color_text);
    }
    if (tw.type == MR_DIALOG_OK_CANCEL || tw.type == MR_DIALOG_CANCEL) {
        tw_draw_string(page, pw, ph, label_cancel,
                       pw - tw_string_width(label_cancel) - TW_LABEL_MARGIN_X, label_y, tw_theme.color_text);
    }

    tw_presenting = 1;
    guiDrawBitmap(page, 0, 0, pw, ph);
    tw_presenting = 0;
    free(page);
}

/* ---- 镜像(capture_frame / restore / transition / present) ---- */

int native_text_widget_capture_frame(const uint16_t *bmp, int32_t x, int32_t y,
                                     int32_t w, int32_t h, int32_t stride,
                                     int32_t sx, int32_t sy) {
    if (tw_presenting) return 0;
    if (bmp == NULL || stride <= 0 || w <= 0 || h <= 0) return 0;
    int dw = skyengine_display_width();
    int dh = skyengine_display_height();
    if (tw_mirror == NULL || tw_mirror_w != dw || tw_mirror_h != dh) {
        free(tw_mirror);
        tw_mirror = (uint16_t *)calloc((size_t)dw * (size_t)dh, sizeof(uint16_t));
        tw_mirror_w = dw; tw_mirror_h = dh; tw_mirror_valid = 0;
        if (tw_mirror == NULL) return 0;
    }
    for (int32_t j = 0; j < h; j++) {
        int32_t yy = y + j, syy = sy + j;
        if (yy < 0 || yy >= dh || syy < 0) continue;
        for (int32_t i = 0; i < w; i++) {
            int32_t xx = x + i, sxx = sx + i;
            if (xx < 0 || xx >= dw || sxx < 0 || sxx >= stride) continue;
            tw_mirror[(size_t)yy * (size_t)dw + (size_t)xx] =
                bmp[(size_t)syy * (size_t)stride + (size_t)sxx];
        }
    }
    tw_mirror_valid = 1;
    return tw.active || native_modal_menu_active() || tw_transition_depth > 0;
}

static void tw_restore_guest_frame_now(void) {
    if (!tw_mirror_valid || tw_mirror == NULL) return;
    if (tw_mirror_w != skyengine_display_width() || tw_mirror_h != skyengine_display_height()) return;
    tw_presenting = 1;
    guiDrawBitmap(tw_mirror, 0, 0, tw_mirror_w, tw_mirror_h);
    tw_presenting = 0;
}

void native_text_widget_restore_guest_frame(void) {
    if (tw_transition_depth > 0) { tw_restore_pending = 1; return; }
    tw_restore_guest_frame_now();
}

void native_text_widget_transition_begin(void) { tw_transition_depth++; }
void native_text_widget_transition_end(void) {
    if (tw_transition_depth <= 0) return;
    tw_transition_depth--;
    if (tw_transition_depth != 0 || !tw_restore_pending) return;
    tw_restore_pending = 0;
    if (!tw.active && !native_modal_menu_active()) tw_restore_guest_frame_now();
}

void native_text_widget_present_platform_frame(uint16_t *bmp, int32_t w, int32_t h) {
    tw_presenting = 1;
    guiDrawBitmap(bmp, 0, 0, w, h);
    tw_presenting = 0;
}

/* ---- 生命周期 ---- */

static void tw_free_content(void) {
    free(tw.title); free(tw.text);
    tw.title = NULL; tw.text = NULL;
}

void native_text_widget_destroy(void) {
    tw.active = 0; tw.handle = 0; tw.scroll = 0; tw.line_count = 0;
    tw_captured_key = -1; tw_presenting = 0;
    tw_free_content();
    free(tw_mirror); tw_mirror = NULL;
    tw_mirror_w = 0; tw_mirror_h = 0; tw_mirror_valid = 0;
    tw_transition_depth = 0; tw_restore_pending = 0;
    if (tw_font_fd > 0) { my_close(tw_font_fd); tw_font_fd = 0; }
}

int native_text_widget_active(void) { return tw.active; }
int native_text_widget_font_ready(void) { return tw_font_open(); }

int32_t native_text_widget_create(const char *title_ucs2be, const char *text_ucs2be, int32_t type) {
    if (type != MR_DIALOG_OK && type != MR_DIALOG_OK_CANCEL && type != MR_DIALOG_CANCEL) return MR_FAILED;
    if (!tw_font_open()) return MR_FAILED;
    uint16_t *title = tw_ucs2be_dup(title_ucs2be);
    uint16_t *text = tw_ucs2be_dup(text_ucs2be);
    if (title == NULL || text == NULL) { free(title); free(text); return MR_FAILED; }
    if (tw.active) tw_free_content();
    tw.title = title; tw.text = text; tw.type = type;
    tw.scroll = 0; tw.active = 1;
    tw.handle = ++tw_handle_gen > 0 ? tw_handle_gen : (tw_handle_gen = 1);
    tw_render_and_present();
    return tw.handle;
}

int32_t native_text_widget_release(int32_t handle) {
    if (!tw.active || handle != tw.handle) return MR_FAILED;
    tw.active = 0;
    tw_free_content();
    native_text_widget_restore_guest_frame();
    return MR_SUCCESS;
}

int32_t native_text_widget_refresh(int32_t handle, const char *title_ucs2be,
                                   const char *text_ucs2be, int32_t type) {
    if (!tw.active || handle != tw.handle) return MR_FAILED;
    if (type != -1 && type != MR_DIALOG_OK && type != MR_DIALOG_OK_CANCEL && type != MR_DIALOG_CANCEL) return MR_FAILED;
    uint16_t *title = tw_ucs2be_dup(title_ucs2be);
    uint16_t *text = tw_ucs2be_dup(text_ucs2be);
    if (title == NULL || text == NULL) { free(title); free(text); return MR_FAILED; }
    tw_free_content();
    tw.title = title; tw.text = text;
    if (type != -1) tw.type = type;
    tw.scroll = 0;
    tw_render_and_present();
    return MR_SUCCESS;
}

/* 触屏拖拽状态 */
static int tw_drag_active = 0;
static int tw_drag_last_y = 0;

/* ---- 事件(触屏 hit-test + 拖拽滚动 + 键盘) ---- */

int native_text_widget_filter_event(int32_t code, int32_t p0, int32_t p1,
                                    int32_t *dialog_param) {
    if (code == MR_KEY_RELEASE && p0 == tw_captured_key) {
        tw_captured_key = -1;
        return 1;
    }
    if (!tw.active) return 0;

    if (code == MR_MOUSE_DOWN) {
        int y = p1;
        int x = p0;
        int ph = skyengine_display_height();
        int pw = skyengine_display_width();
        int bar_y = ph - TW_SOFTBAR_H;
        if (y >= bar_y) {
            if (x < pw / 2) {
                if (tw.type == MR_DIALOG_OK || tw.type == MR_DIALOG_OK_CANCEL) {
                    *dialog_param = MR_DIALOG_KEY_OK;
                    return 2;
                }
            } else {
                if (tw.type == MR_DIALOG_OK_CANCEL || tw.type == MR_DIALOG_CANCEL) {
                    *dialog_param = MR_DIALOG_KEY_CANCEL;
                    return 2;
                }
            }
        }
        /* 滚动条点击:翻页滚动 */
        int vis = tw_visible_lines(ph);
        if (tw_theme.show_scrollbar && tw.line_count > vis && vis > 0
            && y >= TW_BODY_Y && y < bar_y) {
            int sb_x = pw - TW_SB_WIDTH - TW_SB_MARGIN;
            if (x >= sb_x - TW_SB_MARGIN) {
                int sb_track_y = TW_BODY_Y + 2;
                int sb_track_h = (ph - TW_SOFTBAR_H) - TW_BODY_Y - 4;
                int thumb_h = sb_track_h * vis / tw.line_count;
                if (thumb_h < TW_SB_WIDTH * 2) thumb_h = TW_SB_WIDTH * 2;
                int max_scroll = tw.line_count - vis;
                int thumb_y = sb_track_y + (tw.scroll * (sb_track_h - thumb_h)) / max_scroll;
                if (y < thumb_y) {
                    tw.scroll -= vis;
                    if (tw.scroll < 0) tw.scroll = 0;
                    tw_render_and_present();
                    return 1;
                } else if (y >= thumb_y + thumb_h) {
                    tw.scroll += vis;
                    if (tw.scroll + vis > tw.line_count) tw.scroll = tw.line_count - vis;
                    if (tw.scroll < 0) tw.scroll = 0;
                    tw_render_and_present();
                    return 1;
                }
            }
        }
        /* 记录拖拽起点(正文区域) */
        tw_drag_active = 1;
        tw_drag_last_y = y;
        return 1;
    }
    if (code == MR_MOUSE_MOVE) {
        if (tw_drag_active) {
            int y = p1;
            int dy = tw_drag_last_y - y;
            if (dy >= TW_LINE_H) {
                int steps = dy / TW_LINE_H;
                int vis = tw_visible_lines(skyengine_display_height());
                tw.scroll += steps;
                if (tw.scroll + vis > tw.line_count) tw.scroll = tw.line_count - vis;
                if (tw.scroll < 0) tw.scroll = 0;
                tw_drag_last_y += steps * TW_LINE_H;
                tw_render_and_present();
            } else if (dy <= -TW_LINE_H) {
                int steps = (-dy) / TW_LINE_H;
                tw.scroll -= steps;
                if (tw.scroll < 0) tw.scroll = 0;
                tw_drag_last_y -= steps * TW_LINE_H;
                tw_render_and_present();
            }
        }
        return 1;
    }
    if (code == MR_MOUSE_UP) {
        tw_drag_active = 0;
        return 1;
    }

    switch (code) {
        case MR_KEY_PRESS:
            tw_captured_key = p0;
            break;
        case MR_KEY_RELEASE:
            return 0;
        default:
            return 0;
    }
    switch (p0) {
        case MR_KEY_SOFTLEFT:
            if (tw.type == MR_DIALOG_OK || tw.type == MR_DIALOG_OK_CANCEL) {
                *dialog_param = MR_DIALOG_KEY_OK; return 2;
            }
            return 1;
        case MR_KEY_SOFTRIGHT:
            if (tw.type == MR_DIALOG_OK_CANCEL || tw.type == MR_DIALOG_CANCEL) {
                *dialog_param = MR_DIALOG_KEY_CANCEL; return 2;
            }
            return 1;
        case MR_KEY_UP:
            if (tw.scroll > 0) { tw.scroll--; tw_render_and_present(); }
            return 1;
        case MR_KEY_DOWN: {
            int vis = tw_visible_lines(skyengine_display_height());
            if (tw.scroll + vis < tw.line_count) { tw.scroll++; tw_render_and_present(); }
            return 1;
        }
        default:
            return 1;
    }
}
