#!/usr/bin/env bash
# Part of xmm7360-mvp. SPDX-License-Identifier: GPL-2.0-only
# 用社区 xmm7360-pci 驱动替换内核自带的 iosm（ThinkPad A285 / Fibocom L850-GL / Intel XMM7360）
#
#   sudo ./install.sh              # 默认 APN=3gnet（联通）
#   APN=3gnet DNS=221.6.4.66 sudo -E ./install.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$ROOT/src"
VER="2024.02.24-codex1"          # 源码版本 + 本机为内核 7.0 打的兼容补丁
APN="${APN:-3gnet}"
DNS="${DNS:-221.6.4.66}"
DEV=0000:05:00.0
BACKUP=/root/xmm-switch-backup

[[ $EUID -eq 0 ]] || { echo "需要 root：sudo $0" >&2; exit 1; }
[[ -f "$SRC/xmm7360.c" ]] || { echo "找不到源码：$SRC" >&2; exit 1; }

log() { printf '\033[1m==>\033[0m %s\n' "$*"; }

# ------------------------------------------------------------------ 1) 依赖
log "安装依赖（dkms / pyroute2 / configargparse / python3-dbus）"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq dkms python3-pyroute2 python3-configargparse python3-dbus

# ------------------------------------------------- 2) 把旧的 iosm 方案挪走
log "停用旧的 iosm 方案（避免和新驱动抢设备）"
install -d "$BACKUP"
systemctl disable --now wwan-autofix-resume.service 2>/dev/null || true
for f in /etc/systemd/system/wwan-autofix.service \
         /etc/systemd/system/wwan-autofix-resume.service \
         /etc/udev/rules.d/79-wwan-autofix.rules; do
  [ -e "$f" ] && mv "$f" "$BACKUP/$(basename "$f")"
done
systemctl daemon-reload
udevadm control --reload-rules

# ------------------------------------- 3) 解绑 iosm、禁用它、复位模组
log "解绑 iosm + 禁止其自动加载"
systemctl stop ModemManager 2>/dev/null || true
if [ -e "/sys/bus/pci/drivers/iosm/$DEV" ]; then
  echo "$DEV" > /sys/bus/pci/drivers/iosm/unbind
fi
printf 'blacklist iosm\n' > /etc/modprobe.d/xmm7360-blacklist-iosm.conf
modprobe -r iosm 2>/dev/null || true
update-initramfs -u >/dev/null

if [ -w "/sys/bus/pci/devices/$DEV/reset" ]; then
  log "ACPI _RST 复位模组（清掉 iosm 留下的 wedge）"
  echo 1 > "/sys/bus/pci/devices/$DEV/reset" || true
  sleep 2
fi

# --------------------------------------------------- 4) DKMS 安装模块
log "DKMS 安装 xmm7360-pci/$VER"
install -d "/usr/src/xmm7360-pci-$VER"
( cd "$SRC" && find . -type f -print0 | while IFS= read -r -d '' f; do
    install -D -m 644 "$f" "/usr/src/xmm7360-pci-$VER/${f#./}"
  done )
sed "s/COMMIT_ID_VERSION/$VER/g" "$SRC/dkms.tmpl.conf" > "/usr/src/xmm7360-pci-$VER/dkms.conf"
dkms remove "xmm7360-pci/$VER" --all 2>/dev/null || true
dkms install --force "xmm7360-pci/$VER"

# ------------------------------------------------------- 5) 加载并确认
log "加载 xmm7360 并等待 /dev/ttyXMM*"
modprobe xmm7360 || true
ok=0
for i in $(seq 1 10); do
  ls /dev/ttyXMM* >/dev/null 2>&1 && { ok=1; break; }
  sleep 1
done
if [ "$ok" -ne 1 ]; then
  log "没等到 ttyXMM* → 再复位一次 PCI 设备后重试"
  modprobe -r xmm7360 2>/dev/null || true
  echo 1 > "/sys/bus/pci/devices/$DEV/remove" 2>/dev/null || true
  sleep 3
  echo 1 > /sys/bus/pci/rescan 2>/dev/null || true
  sleep 5
  modprobe xmm7360 || true
  for i in $(seq 1 10); do
    ls /dev/ttyXMM* >/dev/null 2>&1 && { ok=1; break; }
    sleep 1
  done
fi
[ "$ok" -eq 1 ] && log "模块就绪：$(ls /dev/ttyXMM* | tr '\n' ' ')" \
                || log "警告：仍未出现 /dev/ttyXMM*，看 dmesg | tail 与 dkms status"

# ------------------- 6) 开机自加载 + 只让 MM 别碰 ttyXMM（wwan0 交给 NM）
log "配置开机自加载与 ModemManager 避让（wwan0 由 NetworkManager 正常接管）"
install -D -m 644 "$ROOT/files/etc/modules-load.d/xmm7360.conf"     /etc/modules-load.d/xmm7360.conf
install -D -m 644 "$ROOT/files/etc/udev/rules.d/99-xmm7360-mm-ignore.rules" /etc/udev/rules.d/
udevadm control --reload-rules
systemctl reload NetworkManager 2>/dev/null || true

# --------------------------------------- 7) 连接脚本 + 挂起恢复
log "安装配置与辅助脚本（APN=$APN）"
install -D -m 644 "$ROOT/files/etc/xmm7360.ini" /etc/xmm7360.ini
sed -i "s|^apn=.*|apn=$APN|" /etc/xmm7360.ini
# 记下源码位置：部署后的 /usr/local/bin/xmm-up 靠它找 rpc/open_xdatachannel.py
grep -q '^SRC=' /etc/xmm7360.ini || printf '\nSRC=%s\n' "$SRC" >> /etc/xmm7360.ini
sed -i "s|^SRC=.*|SRC=$SRC|" /etc/xmm7360.ini
install -D -m 755 "$ROOT/files/usr/local/bin/xmm-up"     /usr/local/bin/xmm-up
install -D -m 755 "$ROOT/files/usr/local/bin/xmm-resume" /usr/local/bin/xmm-resume
install -D -m 644 "$ROOT/files/etc/systemd/system/xmm7360-resume.service" /etc/systemd/system/
install -D -m 644 "$ROOT/files/etc/systemd/system/xmm7360-boot.service"   /etc/systemd/system/
ln -sf "$SRC/scripts/lte.sh" /usr/local/bin/lte
systemctl daemon-reload
systemctl enable xmm7360-resume.service >/dev/null
systemctl enable xmm7360-boot.service   >/dev/null

# ------------------------------------------- 8) 首次拉起数据通道
log "首次拉起数据通道"
for attempt in 1 2 3; do
  XMM7360_DNS="$DNS" /usr/local/bin/xmm-up && break
  log "第 $attempt 次拉起失败，5 秒后重试"
  sleep 5
done

cat <<EOF

完成。日常用法：
  拉起/重连： sudo /usr/local/bin/xmm-up     （或 sudo lte up）
  看连接   ： nmcli con show --active | grep xmm7360 ; nmcli dev status
  看状态   ： ip -4 addr show wwan0 ; ip route ; journalctl -t xmm-up -n 20
  挂起后   ： 自动（xmm7360-resume.service），也可手动 sudo /usr/local/bin/xmm-resume
  回滚     ： sudo $ROOT/uninstall.sh
EOF
