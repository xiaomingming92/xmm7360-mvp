#!/usr/bin/env bash
# Part of xmm7360-mvp. SPDX-License-Identifier: GPL-2.0-only
# 安装 MVP 事件守护：事件优先（内核日志 + netlink）+ 低频探针兜底。
# 同时把原来的 5 分钟自检降频到 30 分钟（避免和守护重复动作）。
# 用法：sudo ./install-mvp.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ $EUID -eq 0 ]] || { echo "需要 root：sudo $0" >&2; exit 1; }
log() { printf '\033[1m==>\033[0m %s\n' "$*"; }

log "1/4 安装守护脚本、状态助手（修正 off 误判）与 ctl（不打断运行中的 ensure）"
install -m 755 "$ROOT/files/usr/local/bin/fibocom-l850-watch" /usr/local/bin/fibocom-l850-watch
install -m 755 "$ROOT/files/usr/local/bin/fibocom-l850-status" /usr/local/bin/fibocom-l850-status
install -m 755 "$ROOT/files/usr/local/bin/fibocom-l850-ctl" /usr/local/bin/fibocom-l850-ctl
install -m 644 "$ROOT/files/etc/systemd/system/fibocom-l850-watch.service" /etc/systemd/system/

log "2/4 自检降频（5min → 30min，探针交给守护做）"
install -m 644 "$ROOT/files/etc/systemd/system/fibocom-l850-selfheal.timer" /etc/systemd/system/

log "3/4 启动"
systemctl daemon-reload
systemctl enable --now fibocom-l850-watch.service >/dev/null
systemctl restart fibocom-l850-selfheal.timer >/dev/null

log "4/4 状态"
systemctl status fibocom-l850-watch.service --no-pager | head -8
journalctl -t fibocom-l850-watch -n 5 --no-pager
cat <<'EOF'

MVP 已上线。事件源：
  ① 内核日志 xmm7360 故障（journalctl -k -f）→ 秒级触发
  ② netlink link/route/address 变化（ip monitor）→ 即时触发
  ③ 面板开关 / 开机 timer / 命令行 ctl → 用户与启动触发
  ④ 每 120 秒 ping 探针 → 兜底"沉默故障"
动作统一走：fibocom-l850-ctl on（诊断 → 软恢复 → 重载模块 → 复核 ping）

看守护日志： journalctl -t fibocom-l850-watch -f
调探针周期： sudo systemctl edit fibocom-l850-watch.service（改 PROBE_INTERVAL）
EOF
