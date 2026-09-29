#!/bin/bash
# 受控 A/B：把两个构建各拉起一次，在**相同条件**下各测 N 轮，打印对照表。
#
# 为什么需要这个脚本：直接测"当前正在运行的那个实例"会测出 5 倍以上的波动 ——
# 弹窗开着时轮询是 1 秒/次、能耗扫描 2 秒/次，和关着时（5 秒 / 30–60 秒）完全不是一回事。
# 同一份二进制，弹窗开与不开的 CPU 时间能差好几倍，混在一起做前后对比等于没测。
#
# 所以受控条件是：自己拉起、不带任何 UI 参数（弹窗关闭、无窗口）、先静置再测，
# 并且测多轮取最小值与中位数 —— 单轮容易撞上系统活动高峰。
#
# 用法：./ab_energy.sh <A可执行文件> <B可执行文件> [轮数] [每轮秒数]
#   例：./ab_energy.sh /tmp/WattupOld.app/Contents/MacOS/Wattup \
#                      ../../.build/Wattup.app/Contents/MacOS/Wattup 3 60
set -uo pipefail

A="$1"; B="$2"; ROUNDS="${3:-3}"; SECS="${4:-60}"
HERE="$(cd "$(dirname "$0")" && pwd)"
SETTLE=15

measure() {
    local bin="$1" label="$2"
    echo "=============================================================="
    echo "被测：$label"
    echo "      $bin"
    echo "=============================================================="

    "$bin" >/dev/null 2>&1 &
    local pid=$!
    sleep "$SETTLE"   # 静置：让首次采样、能耗基线、SwiftUI 首帧都落定

    local vals=() cpus=() wkups=()
    for i in $(seq 1 "$ROUNDS"); do
        local out
        out=$("$HERE/pid_energy" "$pid" "$SECS" 2>/dev/null)
        # 每轮只取三个关键行，避免刷屏
        local mw cpu wk
        mw=$(echo "$out"   | awk -F'[()]' '/平均/{gsub(/[^0-9.]/,"",$2); print $2}')
        cpu=$(echo "$out"  | awk '/CPU 时间/{gsub(/[^0-9.]/,"",$4); print $4}')
        # pid_energy 的输出形如「唤醒（空闲）  : 28 次  → 0.467 次/秒」，
        # 按空白切分后次数在第 3 列（第 1 列是含中文括号的标签，第 2 列是冒号）
        wk=$(echo "$out"   | awk '/唤醒（空闲）/{print $3}')
        vals+=("$mw"); cpus+=("$cpu"); wkups+=("$wk")
        printf "  第 %d 轮：%8s mW   CPU %9s ms  空闲唤醒 %5s 次/%ss\n" \
               "$i" "$mw" "$cpu" "$wk" "$SECS"
    done

    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null

    # 用 awk 排序取最小值与中位数
    printf '%s\n' "${vals[@]}"  | sort -n | awk -v L="$label" '
        {a[NR]=$1} END{printf "  ── %s 平均功率：最小 %.3f mW / 中位 %.3f mW\n", L, a[1], a[int((NR+1)/2)]}'
    printf '%s\n' "${cpus[@]}"  | sort -n | awk -v L="$label" '
        {a[NR]=$1} END{printf "  ── %s CPU 时间：最小 %.3f ms / 中位 %.3f ms（每 %s 秒窗口）\n", L, a[1], a[int((NR+1)/2)], "'"$SECS"'"}'
    printf '%s\n' "${wkups[@]}" | sort -n | awk -v L="$label" '
        {a[NR]=$1} END{printf "  ── %s 空闲唤醒：最小 %.0f / 中位 %.0f 次（每 %s 秒窗口）\n", L, a[1], a[int((NR+1)/2)], "'"$SECS"'"}'
    echo
}

echo "轮数=$ROUNDS  每轮=$SECS 秒  静置=$SETTLE 秒"
echo
measure "$A" "A 优化前"
measure "$B" "B 优化后"
echo "说明：空闲唤醒次数是菜单栏类工具能耗的关键指标 —— 每次唤醒都要把 CPU 从低功耗态拉出来。"
