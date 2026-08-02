/*
 * native_menu_state.c —— 平台菜单(mr_menuCreate/SetItem/Show)的 OHOS 状态管理。
 *
 * OHOS 移植参考 editCreate 的架构:vmrp 侧只存菜单数据 + active 标记,
 * 不做任何渲染;真正的菜单 UI 由前端 ArkTS 用原生 List 组件渲染。
 * 渲染线程检测到 menu active 后通过 threadsafe function 通知前端,
 * 前端弹出原生菜单 Dialog,用户选择/取消后回调 submitMenu/cancelMenu,
 * 由 skyengine_api 投递 MR_MENU_SELECT(4)/MR_MENU_RETURN(5) 事件给应用。
 *
 * 本文件是纯状态管理,无渲染依赖,放在 vmrp 树外(ohos_src/)通过
 * target_sources 注入 skyengine-shared,不污染上游子模块源码。
 */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/* MR_SUCCESS/MR_FAILED/MR_IGNORE 与 mrporting.h 一致,此处自带避免头文件依赖 */
#define NMS_SUCCESS 0
#define NMS_FAILED  (-1)
#define NMS_IGNORE  1

#define NMS_MAX_ITEMS 64
#define NMS_ITEM_MAX  256  /* 每项 UTF-8 最大字节数(UCS2-BE 128 字符) */
#define NMS_TITLE_MAX 512  /* 标题 UTF-8 最大字节数 */

typedef struct {
    int active;
    int pending_show;  /* menuShow 被调用但延迟激活(在 event 内部调时) */
    int32_t handle;       /* 递增句柄,>0 有效 */
    char *title_utf8;     /* UCS2-BE 转成的 UTF-8 标题 */
    int item_count;       /* 已添加的菜单项数(menuSetItem 累积) */
    int num_declared;     /* menuCreate 声明的项数(用于校验/前端显示) */
    char items_utf8[NMS_MAX_ITEMS][NMS_ITEM_MAX]; /* 各菜单项 UTF-8 */
} NativeMenu;

static NativeMenu nms;
static int32_t nms_handle_gen = 0;

/* 当 menu 事件(event 4/5)正在执行时置 1。aex_t065(menuShow)检测此标志,
 * 若在 event 内部则延迟 active(只设 pending_show),避免 menuShow 在 event
 * 执行上下文里破坏 timer owner 导致画面卡住。 */
int native_menu_in_event = 0;

/* ---------------- UCS2-BE → UTF-8 转换 ---------------- */

/*
 * 将单个 UCS2-BE 码点(bmp 平面)追加为 UTF-8 字节到 out。
 * 返回写入的字节数。buf_end 指向 out 缓冲区末尾(不可写位置)。
 * SkyEngine menu 的 title/items 是 UCS2 大端(网络字节序),多数为
 * BMP 平面的中文/ASCII,代理对(>0xFFFF)在 mr_menu 场景不会出现。
 */
static int nms_ucs2_code_to_utf8(uint32_t cp, char *out, char *buf_end) {
    if (cp < 0x80) {
        if (out + 1 > buf_end) return 0;
        out[0] = (char)cp;
        return 1;
    } else if (cp < 0x800) {
        if (out + 2 > buf_end) return 0;
        out[0] = (char)(0xC0 | (cp >> 6));
        out[1] = (char)(0x80 | (cp & 0x3F));
        return 2;
    } else {
        if (out + 3 > buf_end) return 0;
        out[0] = (char)(0xE0 | (cp >> 12));
        out[1] = (char)(0x80 | ((cp >> 6) & 0x3F));
        out[2] = (char)(0x80 | (cp & 0x3F));
        return 3;
    }
}

/*
 * UCS2-BE 字节流 → 新分配的 UTF-8 字符串(NUL 结尾)。
 * 返回 malloc 的指针,调用方负责 free;失败返回 NULL。
 * 输入 ucs2be 为 NUL(UCS2 双字节 0x0000)结尾的原始字节流。
 */
static char *nms_ucs2be_to_utf8_dup(const char *ucs2be) {
    if (!ucs2be) return NULL;
    /* 最坏情况:每个 UCS2 码点 → 3 字节 UTF-8 */
    size_t max_chars = 0;
    const uint8_t *p = (const uint8_t *)ucs2be;
    while (((uint16_t)(p[max_chars * 2] << 8) | p[max_chars * 2 + 1]) != 0) {
        max_chars++;
        if (max_chars > 1024) break; /* 安全上限,防止缺 NUL 的脏数据 */
    }
    char *out = (char *)malloc(max_chars * 3 + 1);
    if (!out) return NULL;
    char *cur = out;
    char *end = out + max_chars * 3;
    for (size_t i = 0; i < max_chars; i++) {
        uint32_t cp = (uint32_t)((p[i * 2] << 8) | p[i * 2 + 1]);
        cur += nms_ucs2_code_to_utf8(cp, cur, end);
    }
    *cur = '\0';
    return out;
}

/* ---------------- 生命周期 ---------------- */

static void nms_free_content(void) {
    free(nms.title_utf8);
    nms.title_utf8 = NULL;
    nms.item_count = 0;
    nms.num_declared = 0;
}

int32_t native_menu_create(const char *title_ucs2be, int16_t num) {
    if (num < 0 || num > NMS_MAX_ITEMS) return NMS_FAILED;
    char *title = nms_ucs2be_to_utf8_dup(title_ucs2be);
    if (!title && title_ucs2be) return NMS_FAILED;
    /* 重复创建视为替换(menuCreate 通常只调一次,但防御性处理) */
    if (nms.active || nms.title_utf8) {
        nms_free_content();
    }
    nms.title_utf8 = title;
    nms.num_declared = num;
    nms.item_count = 0;
    nms.active = 0; /* menuShow 时才置 active */
    nms.handle = ++nms_handle_gen > 0 ? nms_handle_gen : (nms_handle_gen = 1);
    return nms.handle;
}

int32_t native_menu_set_item(int32_t menu, const char *text_ucs2be, int32_t index) {
    if (menu != nms.handle || !nms.title_utf8) return NMS_FAILED;
    /* index 是应用指定的项序号(0-based),可能乱序填充;按 index 存,允许空洞 */
    if (index < 0 || index >= NMS_MAX_ITEMS) return NMS_FAILED;
    char *item = nms_ucs2be_to_utf8_dup(text_ucs2be);
    if (!item && text_ucs2be) return NMS_FAILED;
    /* 记录已填充项数(取 max(index+1, 当前)) */
    if (index + 1 > nms.item_count) nms.item_count = index + 1;
    if (item) {
        strncpy(nms.items_utf8[index], item, NMS_ITEM_MAX - 1);
        nms.items_utf8[index][NMS_ITEM_MAX - 1] = '\0';
        free(item);
    } else {
        nms.items_utf8[index][0] = '\0';
    }
    return NMS_SUCCESS;
}

int32_t native_menu_show(int32_t menu) {
    if (menu != nms.handle || !nms.title_utf8) return NMS_FAILED;
    if (native_menu_in_event) {
        /* 在 event 执行内部(如二级菜单):延迟激活,等 event 返回后由
         * native_menu_flush_pending 在正常上下文激活。 */
        nms.pending_show = 1;
    } else {
        nms.active = 1;
    }
    return NMS_SUCCESS;
}

/* event 返回后调用:激活延迟的 menuShow。在 worker 正常循环上下文执行。 */
void native_menu_flush_pending(void) {
    if (nms.pending_show) {
        nms.pending_show = 0;
        nms.active = 1;
    }
}

int32_t native_menu_release(int32_t menu) {
    if (menu != nms.handle) return NMS_IGNORE;
    nms.active = 0;
    nms_free_content();
    return NMS_IGNORE; /* 与原生 dsm.c mr_menuRelease 一致 */
}

int32_t native_menu_refresh(int32_t menu) {
    /* menuRefresh 用于刷新菜单内容;OHOS 前端每次打开都读最新数据,无需特殊处理 */
    if (menu != nms.handle) return NMS_IGNORE;
    return NMS_IGNORE;
}

void native_menu_reset(void) {
    nms.active = 0;
    nms.pending_show = 0;
    nms_free_content();
}

/* ---------------- 状态查询(供 skyengine_api 导出给前端) ---------------- */

int native_menu_is_active(void) {
    return nms.active && nms.title_utf8 != NULL;
}

const char *native_menu_get_title(void) {
    return nms.title_utf8 ? nms.title_utf8 : "";
}

int native_menu_get_item_count(void) {
    return nms.item_count;
}

const char *native_menu_get_item(int index) {
    if (index < 0 || index >= nms.item_count) return "";
    return nms.items_utf8[index];
}
