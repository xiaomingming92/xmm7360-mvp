#!/usr/bin/env bash
# 卸载 xmm7360-pci，恢复内核 iosm 驱动与之前的自愈脚本。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VER="2024.02.24-codex1"
BACKUP=/root/xmm-switch-backup

[[ $EUID -eq 0 ]] || { echo "需要 root：sudo $0" >&2; exit 1; }
log() { printf '\033[1m==>\033[0m %s\n' "$*"; }

log "停用 xmm7360 相关单元与脚本"
systemctl disable --now xmm7360-resume.service xmm7360-boot.service 2>/dev/null || true
rm -f /etc/systemd/system/xmm7360-resume.service \
      /etc/systemd/system/xmm7360-boot.service \
      /usr/local/bin/xmm-up /usr/local/bin/xmm-resume /usr/local/bin/lte \
      /etc/xmm7360.ini \
      /etc/udev/rules.d/99-xmm7360-mm-ignore.rules \
      /etc/modules-load.d/xmm7360.conf

log "删除 NetworkManager 里由脚本创建的 xmm7360 连接"
nmcli con delete xmm7360 2>/dev/null || true

log "卸载 DKMS 模块"
modprobe -r xmm7360 2>/dev/null || true
dkms remove "xmm7360-pci/$VER" --all 2>/dev/null || true

log "恢复 iosm 驱动加载"
rm -f /etc/modprobe.d/xmm7360-blacklist-iosm.conf
update-initramfs -u >/dev/null
modprobe iosm 2>/dev/null || true

log "恢复之前的自愈脚本（如果有备份）"
for f in "$BACKUP"/*; do
  [ -e "$f" ] || continue
  case "$(basename "$f")" in
    *.service) install -m 644 "$f" /etc/systemd/system/ ;;
    *.rules)   install -m 644 "$f" /etc/udev/rules.d/ ;;
  esac
done
systemctl daemon-reload
udevadm control --reload-rules
systemctl enable --now ModemManager 2>/dev/null || true
systemctl reload NetworkManager 2>/dev/null || true

log "完成。检查：lsmod | grep -E 'iosm|xmm7360' ; journalctl -k -b | grep -i -E 'iosm|xmm' | tail"
