#!/usr/bin/env bash
# 应用驱动的本地补丁（TX flush 丢帧后清计数 + 背压 + 限速日志）并重装 DKMS 模块。
# 用法：sudo ./install-driver-patch.sh
set -euo pipefail

ROOT=/home/xmm/ai/xmm7360-driver
VER=2024.02.24-codex1
DEST=/usr/src/xmm7360-pci-$VER

[[ $EUID -eq 0 ]] || { echo "需要 root：sudo $0" >&2; exit 1; }
[[ -d "$DEST" ]] || { echo "找不到 DKMS 源目录 $DEST" >&2; exit 1; }
log() { printf '\033[1m==>\033[0m %s\n' "$*"; }

log "1/4 同步补丁后的源码到 DKMS 目录"
install -m 644 "$ROOT/src/xmm7360.c" "$DEST/xmm7360.c"
install -m 644 "$ROOT/src/Makefile"  "$DEST/Makefile"

log "2/4 重新编译并安装模块（DKMS，强制覆盖）"
dkms build   "xmm7360-pci/$VER" -k "$(uname -r)" --force >/dev/null
dkms install "xmm7360-pci/$VER" -k "$(uname -r)" --force >/dev/null
dkms status "xmm7360-pci/$VER"

log "3/4 卸载旧模块并重新加载（先停 ensure，避免抢 RPC）"
systemctl stop fibocom-l850-up.service 2>/dev/null || true
pkill -f fibocom-l850-up-retry 2>/dev/null || true
pkill -f open_xdatachannel.py 2>/dev/null || true
sleep 2
modprobe -r xmm7360 2>/dev/null || true
modprobe xmm7360
sleep 3

log "4/4 重新拉起 ensure"
systemctl reset-failed fibocom-l850-up.service 2>/dev/null || true
systemctl start --no-block fibocom-l850-up.service
echo
echo "完成。看进度：journalctl -t fibocom-l850-retry -f"
echo "验证丢包是否停止：journalctl -k -b | grep -c 'Failed to ship coalesced'"
