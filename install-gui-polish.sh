#!/usr/bin/env bash
# 面板文案对齐 GNOME + 让磁贴的"重新连接"真的能重连。
#   1) 扩展文案改用 GNOME 自己的术语（zh_CN 译文取自 gnome-shell / gnome-control-center）：
#      Mobile Network→移动网络、Connected→已连接、Disconnected→已断开、
#      Connect→连接、Disconnect→断开连接、Turn Off→关闭、Settings→设置、APN→APN
#   2) operators.csv 补 46001 → 中国联通（磁贴副标题显示运营商名，像 GNOME 那样）
#   3) ctl 判据改为"必须有 IPv4"，"on" 交给 ensure 服务后台重试（#186 策略）
# 用法：sudo ./install-gui-polish.sh
set -euo pipefail

ROOT=/home/xmm/ai/xmm7360-driver
UUID=fibocom-l850-lte@michaelruck.github.io
LOGIN_USER="${SUDO_USER:-xmm}"
USER_HOME="$(getent passwd "$LOGIN_USER" | cut -d: -f6)"
DEST="$USER_HOME/.local/share/gnome-shell/extensions/$UUID"
DBUS_ADDR="unix:path=/run/user/$(id -u "$LOGIN_USER")/bus"

[[ $EUID -eq 0 ]] || { echo "需要 root：sudo $0" >&2; exit 1; }
log() { printf '\033[1m==>\033[0m %s\n' "$*"; }

log "1/4 更新扩展文案（移动网络 / 已连接 / 已断开 / 设置 …）"
[[ -f "$DEST/extension.js" ]] || { echo "扩展未安装：$DEST" >&2; exit 1; }
cp -a "$DEST/extension.js" "$DEST/extension.js.bak-$(date +%Y%m%d-%H%M%S)"
install -o "$LOGIN_USER" -g "$(id -gn "$LOGIN_USER")" -m 644 \
    "$ROOT/files/gnome-extension/$UUID/extension.js" "$DEST/extension.js"

log "2/4 补运营商名映射（46001 → 中国联通）"
CSV=/etc/fibocom-l850-lte/operators.csv
if [ -f "$CSV" ] && ! grep -q '^46001,' "$CSV"; then
    printf '46001,中国联通\n' >> "$CSV"
fi
grep -n '^46001,' "$CSV" || true

log "3/4 更新 ctl（判据=有 IPv4；on 交给 ensure 后台重试）"
install -m 755 "$ROOT/files/usr/local/bin/fibocom-l850-ctl" /usr/local/bin/fibocom-l850-ctl

log "4/4 重载扩展"
sudo -u "$LOGIN_USER" DBUS_SESSION_BUS_ADDRESS="$DBUS_ADDR" \
     gnome-extensions disable "$UUID" 2>/dev/null || true
sleep 1
sudo -u "$LOGIN_USER" DBUS_SESSION_BUS_ADDRESS="$DBUS_ADDR" \
     gnome-extensions enable "$UUID" 2>/dev/null || true
sleep 2
sudo -u "$LOGIN_USER" DBUS_SESSION_BUS_ADDRESS="$DBUS_ADDR" \
     gnome-extensions info "$UUID" 2>/dev/null | grep -E "Enabled|State" || true

cat <<'EOF'

完成。面板文案现在是 GNOME 的术语：
  磁贴标题  移动网络（未连接时显示 已关闭 / 已断开 / 模组未就绪）
  连接后副标题  中国联通 · LTE · -9x dBm
  菜单      重新连接 / APN：3gnet / 设置…

提示：Wayland 下扩展的 JS 有模块缓存；如果面板文案没变，注销重登一次即可。
回滚扩展：cp <扩展目录>/extension.js.bak-<时间戳> <扩展目录>/extension.js 后 disable/enable。
EOF
