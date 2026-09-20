#!/usr/bin/env bash
# 装上"每 10 分钟自检 + 不通就重跑 ensure"的定时器，并同步新版 ensure（更大重试预算）。
# 用法：sudo ./install-selfheal-timer.sh
set -euo pipefail
ROOT=/home/xmm/ai/xmm7360-driver
[[ $EUID -eq 0 ]] || { echo "需要 root：sudo $0" >&2; exit 1; }
log() { printf '\033[1m==>\033[0m %s\n' "$*"; }

log "1/3 安装新版 ensure（3 轮 × 4 次，判据=有 IPv4）与自检脚本"
install -m 755 "$ROOT/files/usr/local/bin/fibocom-l850-up-retry" /usr/local/bin/fibocom-l850-up-retry
install -m 755 "$ROOT/files/usr/local/bin/fibocom-l850-selfheal" /usr/local/bin/fibocom-l850-selfheal

log "2/3 安装 timer/service"
install -m 644 "$ROOT/files/etc/systemd/system/fibocom-l850-selfheal.service" /etc/systemd/system/
install -m 644 "$ROOT/files/etc/systemd/system/fibocom-l850-selfheal.timer"   /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now fibocom-l850-selfheal.timer >/dev/null

log "3/3 状态"
systemctl list-timers 'fibocom-l850-*' --no-pager | head -5
cat <<'EOF'

完成。现在的自愈链：
  开机 3 分钟 → fibocom-l850-up.timer → fibocom-l850-up.service（ensure：3 轮 × 4 次）
  每 10 分钟 → fibocom-l850-selfheal.timer → 检查「链路+IPv4+ping」，不通且 ensure 空闲就重跑 ensure
  面板「重新连接」/开关 → 同样判据 → 必要时重跑 ensure

手动立刻来一轮： sudo systemctl restart fibocom-l850-up.service
看进度        ： journalctl -t fibocom-l850-retry -f
EOF
