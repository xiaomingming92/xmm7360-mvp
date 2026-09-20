#!/usr/bin/env bash
# Part of xmm7360-mvp. SPDX-License-Identifier: GPL-2.0-only
# 菜单里加「网络模式：自动 / 仅 4G / 仅 3G」所需的三件套：
#   1) /usr/local/bin/fibocom-l850-rat      —— 发 AT+WS46 切制式（root）
#   2) /usr/local/bin/fibocom-l850-daemon   —— D-Bus 后端新增 SetNetworkMode（polkit 门禁）
#   3) /usr/share/polkit-1/actions/org.fibocom.l850.policy —— 新增 set-mode 动作
#   4) 扩展菜单新增「网络模式」子菜单
# 说明：本固件 AT+WS46=? 只给 (22,28,31)，**不支持仅 4G**；点了"仅 4G"会明确报错
#       （等 AT+XACT 取值确认后再实现，见 fibocom-l850-rat 里的注释）。
# 用法：sudo ./install-rat-switch.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UUID=fibocom-l850-lte@michaelruck.github.io
LOGIN_USER="${SUDO_USER:-xmm}"
USER_HOME="$(getent passwd "$LOGIN_USER" | cut -d: -f6)"
DEST="$USER_HOME/.local/share/gnome-shell/extensions/$UUID"
DBUS_ADDR="unix:path=/run/user/$(id -u "$LOGIN_USER")/bus"

[[ $EUID -eq 0 ]] || { echo "需要 root：sudo $0" >&2; exit 1; }
log() { printf '\033[1m==>\033[0m %s\n' "$*"; }

log "1/4 安装 helper（fibocom-l850-rat）"
install -m 755 "$ROOT/files/usr/local/bin/fibocom-l850-rat" /usr/local/bin/fibocom-l850-rat

log "2/4 更新 D-Bus 后端（新增 SetNetworkMode）"
install -m 755 "$ROOT/files/usr/local/bin/fibocom-l850-daemon" /usr/local/bin/fibocom-l850-daemon
systemctl restart fibocom-l850-daemon.service
sleep 1
systemctl is-active fibocom-l850-daemon.service

log "3/4 更新 polkit 策略（新增 set-mode 动作）"
install -D -m 644 "$ROOT/files/usr/share/polkit-1/actions/org.fibocom.l850.policy" \
        /usr/share/polkit-1/actions/org.fibocom.l850.policy

log "4/4 更新扩展菜单（网络模式子菜单）"
if [[ -f "$DEST/extension.js" ]]; then
    cp -a "$DEST/extension.js" "$DEST/extension.js.bak-$(date +%Y%m%d-%H%M%S)"
    install -o "$LOGIN_USER" -g "$(id -gn "$LOGIN_USER")" -m 644 \
        "$ROOT/files/gnome-extension/$UUID/extension.js" "$DEST/extension.js"
    sudo -u "$LOGIN_USER" DBUS_SESSION_BUS_ADDRESS="$DBUS_ADDR" gnome-extensions disable "$UUID" 2>/dev/null || true
    sleep 1
    sudo -u "$LOGIN_USER" DBUS_SESSION_BUS_ADDRESS="$DBUS_ADDR" gnome-extensions enable "$UUID" 2>/dev/null || true
fi

cat <<'EOF'

完成。验证：
  # 后端方法在不在（会返回错误信息，说明方法存在）
  busctl --system introspect org.fibocom.l850 /org/fibocom/l850 org.fibocom.l850 | grep -i NetworkMode
  # 直接命令行切（会弹 polkit 认证）
  sudo /usr/local/bin/fibocom-l850-rat 3g      # 仅 3G
  sudo /usr/local/bin/fibocom-l850-rat auto    # 自动（2G/3G/4G，4G 优先）
  cat /sys/class/net/wwan0/operstate >/dev/null; ip -4 addr show wwan0

菜单里「网络模式」三项：自动（2G/3G/4G）/ 仅 4G（LTE）/ 仅 3G（UMTS）。
其中"仅 4G"暂时会报错——本固件 AT+WS46 不支持 E-UTRAN only，需要 AT+XACT（待确认）。
EOF
