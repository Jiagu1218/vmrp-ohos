#!/bin/bash
# ============================================================================
# test_cookie_submrp.sh — 自动化测试 cookie 启动/退出子 mrp
#
# 用法:
#   bash scripts/test_cookie_submrp.sh             # 用默认连接的设备
#   HDC="hdc.exe -t 192.168.2.2:34277" bash scripts/test_cookie_submrp.sh
#
# 测试流程:
#   dsm_gm → 冒泡(第3项,2次下) → OK进子页面 → OK启动应用
#   → 等10秒网络失败 → 菜单(左软) → 文件管理(按键5) → 等3秒
#   → 上键 → 大富翁4(OK) → 等5秒子mrp启动
#   → 等3秒 → 左软 → 左键 → OK(退出子mrp) → 等3秒 → 抓日志验证返回cookie
# ============================================================================

HDC="${HDC:-hdc}"

# 虚拟按键坐标（来自 UI 树分析，1316x2832 屏幕）
DOWN_X=380;  DOWN_Y=2590      # ▼ 下键
UP_X=380;    UP_Y=2200        # ▲ 上键
OK_X=380;    OK_Y=2400        # OK 键
LSOFT_X=130; LSOFT_Y=2220     # 左软键
KEY5_X=1015; KEY5_Y=2330      # 数字键5
LEFT_X=200;  LEFT_Y=2400      # ◀ 左键

click() { $HDC shell "uitest uiInput click $1 $2" 2>/dev/null; sleep 0.15; }
wait_s() { sleep "$1"; }

echo "============================================"
echo "  cookie 子mrp 启动/退出 自动化测试"
echo "============================================"

# --- 重启 ---
echo ">>> 重启应用"
$HDC shell "aa force-stop com.example.vmrpohos" 2>/dev/null || true
$HDC shell "hilog -r" 2>/dev/null || true
wait_s 1
$HDC shell "aa start -a EntryAbility -b com.example.vmrpohos"
wait_s 4
echo "    dsm_gm 已加载"

# --- 进入冒泡(第1项): 直接OK ---
echo ">>> OK → 冒泡"
click $OK_X $OK_Y

# --- 启动应用(第1项): OK ---
echo ">>> OK → 启动应用(cookie)"
click $OK_X $OK_Y

# --- 等网络失败 ---
echo ">>> 等待15秒网络失败..."
wait_s 15

# --- 菜单: 左软 ---
echo ">>> 左软 → 菜单"
click $LSOFT_X $LSOFT_Y

# --- 文件管理: 按键5 ---
echo ">>> 按键5 → 文件管理"
click $KEY5_X $KEY5_Y
wait_s 3

# --- 选大富翁4(最后一项): 上 → OK ---
echo ">>> 上 → OK → 大富翁4"
click $UP_X $UP_Y
click $OK_X $OK_Y

# --- 等子mrp启动 ---
echo ">>> 等待5秒子mrp启动..."
wait_s 5

echo "--- 子mrp启动日志 ---"
$HDC shell "hilog -x" 2>&1 | strings | grep "vmrp_core" | \
    grep -i "RESTART_READBACK\|ARM102\|dofile" | tail -10

# --- 退出子mrp: 等3秒 → 左软 → 左 → OK ---
echo ">>> 退出子mrp: 左软 → 左 → OK"
wait_s 3
click $LSOFT_X $LSOFT_Y
click $LEFT_X $LEFT_Y
click $OK_X $OK_Y
wait_s 3

echo "--- 退出后日志 ---"
$HDC shell "hilog -x" 2>&1 | strings | grep "vmrp_core" | \
    grep -i "RESTART_READBACK\|dofile" | tail -10

echo ""
echo "============================================"
echo "  检查日志中 RESTART_READBACK 的 old_pack："
echo "    'cookie.mrp' → 返回 cookie ✓"
echo "    'dsm_gm.mrp' → 返回 dsm_gm ✗"
echo "  dofile('start.mr') 两次 = dsm_gm (错)"
echo "  dofile 后有 cookie 的 ARM ext 加载 = 返回 cookie ✓"
echo "============================================"
