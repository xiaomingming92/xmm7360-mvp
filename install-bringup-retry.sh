#!/usr/bin/env bash
# 给 Fibocom bring-up 加"重试 + 静置 + 模块重载"（解决 RPC 卡在 UtaMsSmsInit、
# 面板 0 信号、wwan0 拿不到 IPv4 的问题）。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ $EUID -eq 0 ]] || { echo "需要 root：sudo $0" >&2; exit 1; }
log() { printf '\033[1m==>\033[0m %s\n' "$*"; }

log "1/4 安装包装脚本"
install -D -m 755 "$ROOT/files/usr/local/bin/fibocom-l850-up-retry" /usr/local/bin/fibocom-l850-up-retry

log "2/4 安装 drop-in（把 ExecStart 换成包装脚本；原来的超时/限流不动）"
install -D -m 644 \
    "$ROOT/files/etc/systemd/system/fibocom-l850-up.service.d/20-retry.conf" \
    /etc/systemd/system/fibocom-l850-up.service.d/20-retry.conf
systemctl daemon-reload

log "3/4 清掉当前卡住的 bring-up（它占着 /dev/xmm0/rpc）"
systemctl stop fibocom-l850-up.service 2>/dev/null || true
pkill -f open_xdatachannel.py 2>/dev/null || true
sleep 2

log "4/4 用新包装脚本后台重跑（会静置 30s，最多 3 轮；用 --no-block 不阻塞终端）"
systemctl reset-failed fibocom-l850-up.service 2>/dev/null || true
systemctl start --no-block fibocom-l850-up.service

# timer 也同步成"开机 3 分钟后"（初始化太早会把模组 RPC 会话弄成半死状态）
install -D -m 644 "$ROOT/files/etc/systemd/system/fibocom-l850-up.timer" \
        /etc/systemd/system/fibocom-l850-up.timer
systemctl daemon-reload
systemctl restart fibocom-l850-up.timer 2>/dev/null || true

cat <<'EOF'

完成。观察（正常需要 1~3 分钟，期间它会自己重试）：
  journalctl -t fibocom-l850-retry -f
  ip -4 addr show wwan0                    # 出现 inet 10.x.x.x/32 就是成功
  busctl --system call org.fibocom.l850 /org/fibocom/l850 org.fibocom.l850 Status
  curl -s --noproxy '*' --interface wwan0 -o /dev/null -w '%{http_code}\n' http://www.baidu.com

如果 3 轮都没成功：关机（完全断电）→ 开机，让开机时那一次 bring-up 自己跑完
（现在它已经有静置 + 重试，不会再被掐死）。
EOF
