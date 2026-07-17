#!/bin/bash
# ============================================================================
# test_op6120.sh — 自动化测试 op6120.mrp 开屏启动
#
# 用法:
#   bash scripts/test_op6120.sh
#   HDC="hdc.exe -t 192.168.2.2:34277" bash scripts/test_op6120.sh
#
# 前提: 应用已安装并启动,当前在 MRP 文件列表页面。
#
# 测试流程:
#   文件列表 → 按6次上键(倒数第六个=op6120) → OK(进入启动页)
#   → OK(启动应用) → 等待15秒 → 截图验证是否过了开屏
#
# 判定: 截图后人工检查或对比日志确认游戏是否进入主界面
# ============================================================================

HDC="${HDC:-hdc}"

# 虚拟按键坐标（1316x2832 屏幕）
UP_X=380;   UP_Y=2200    # ▲ 上键
OK_X=380;   OK_Y=2400    # OK 键

click() { $HDC shell "uitest uiInput click $1 $2" 2>/dev/null; sleep 0.2; }
wait_s() { sleep "$1"; }

echo "============================================"
echo "  op6120 开屏启动 自动化测试"
echo "============================================"
echo ""

# 清理旧日志
$HDC shell hilog -r 2>/dev/null

echo "[1/5] 按6次上键定位到 op6120（列表倒数第六个）..."
for i in $(seq 1 6); do
    click $UP_X $UP_Y
    echo "  上键 #$i"
done

wait_s 1

echo "[2/5] 按 OK 进入启动页面..."
click $OK_X $OK_Y

wait_s 2

echo "[3/5] 按 OK 启动应用..."
click $OK_X $OK_Y

echo "[4/5] 等待15秒观察开屏..."
wait_s 15

echo "[5/5] 截图保存..."
SHOT_DIR="D:/Downloads/mrpos/vmrp-ohos/screenshot"
mkdir -p "$SHOT_DIR"
TS=$(date +%s)
$HDC shell "snapshot_display -f /data/local/tmp/op6120_${TS}.jpeg" 2>/dev/null
$HDC file recv "/data/local/tmp/op6120_${TS}.jpeg" "$SHOT_DIR/op6120_${TS}.jpeg" 2>/dev/null

echo ""
echo "============================================"
echo "  截图已保存: $SHOT_DIR/op6120_${TS}.png"
echo ""
echo "  抓取 vmrp_core 日志..."
$HDC shell hilog -x 2>/dev/null | grep -i "vmrp_core\|TLDIAG\|timerStart\|void_event\|wrapper probes\|my_socket\|my_connect" | tail -30

echo ""
echo "============================================"
echo "  测试完成。检查截图确认游戏是否过了开屏。"
echo "============================================"
