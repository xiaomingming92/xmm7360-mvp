#!/usr/bin/env bash
# 在 xmm7360-pci 驱动之上，安装社区 GUI 层：fibocom-l850-gnome-lte
#   https://github.com/michaelruck/fibocom-l850-gnome-lte
#   （systemd 开机服务 + D-Bus 后端 + polkit + GNOME 扩展：快速设置里的 "Mobile Data" 开关）
#
# 相比上游只有三处必要改动：
#   1) 扩展 metadata 增加 GNOME 50 —— 本机 Shell 是 50.1，上游只声明 45–48；
#      （已确认 GNOME 50 里 quickSettings.js / extensions/extension.js 资源仍在）
#   2) /etc/fibocom-l850-lte/modem.conf 填联通 APN / DNS；
#   3) 新增 fibocom-l850-resume.service（上游没有挂起钩子，靠 ctl 的自愈能力补上）。
# 另外顺手移除我们临时搭的那层（NM 连接 xmm7360 + xmm7360-boot/resume 单元），避免两边抢 wwan0。
set -euo pipefail

# 仓库自身位置（clone 到哪都行）；GNOME 层会把 $DRIVER_DIR 记进 modem.conf 的 XMM7360_DIR，
# 所以 clone **别删**（部署后的 xmm-up / 上游脚本要靠它找 rpc/open_xdatachannel.py）。
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 上游 GUI 层：默认找 <repo>/vendor/fibocom-gnome-lte，也可以用 UPSTREAM=/path 指定
UPSTREAM="${UPSTREAM:-$ROOT/vendor/fibocom-gnome-lte}"
DRIVER_DIR="${DRIVER_DIR:-$ROOT/src}"
UUID=fibocom-l850-lte@michaelruck.github.io
LOGIN_USER="${SUDO_USER:-xmm}"
APN="${APN:-3gnet}"
DNS="${DNS:-221.6.4.66 223.5.5.5}"
METRIC="${METRIC:-1000}"

[[ $EUID -eq 0 ]] || { echo "需要 root：sudo $0" >&2; exit 1; }
[[ -x "$UPSTREAM/install.sh" ]] || {
  echo "缺少 $UPSTREAM/install.sh（上游 GUI 层）" >&2
  echo "先 clone：git clone https://github.com/michaelruck/fibocom-l850-gnome-lte \"$UPSTREAM\"" >&2
  echo "或用 UPSTREAM=/已有路径 sudo -E $0" >&2
  exit 1
}
[[ -f "$DRIVER_DIR/rpc/open_xdatachannel.py" ]] || { echo "缺少驱动源码 $DRIVER_DIR" >&2; exit 1; }

log() { printf '\033[1m==>\033[0m %s\n' "$*"; }

log "1/5 移除临时层（NM 连接 xmm7360 / xmm7360-boot.service / xmm7360-resume.service / 旧 udev 规则）"
nmcli con delete xmm7360 2>/dev/null || true
systemctl disable --now xmm7360-boot.service xmm7360-resume.service 2>/dev/null || true
rm -f /etc/systemd/system/xmm7360-boot.service \
      /etc/systemd/system/xmm7360-resume.service \
      /etc/udev/rules.d/99-xmm7360-mm-ignore.rules
systemctl daemon-reload
udevadm control --reload-rules 2>/dev/null || true

log "2/5 给 GNOME 扩展补上 Shell 50 声明"
sed -i -E 's/"shell-version": \[[^]]*\]/"shell-version": ["45", "46", "47", "48", "49", "50"]/' \
    "$UPSTREAM/gnome-extension/$UUID/metadata.json"
grep -n 'shell-version' "$UPSTREAM/gnome-extension/$UUID/metadata.json"

log "3/5 安装上游（用打了内核 7.0 补丁的驱动源码；模块已由 DKMS 装好，故不再 --build）"
"$UPSTREAM/install.sh" --xmm7360-dir "$DRIVER_DIR"

log "4/5 写 APN / DNS / METRIC"
CONF=/etc/fibocom-l850-lte/modem.conf
sed -i -E "s|^APN=.*|APN=${APN}|" "$CONF"
sed -i -E "s|^DNS=.*|DNS=\"${DNS}\"|" "$CONF"
sed -i -E "s|^METRIC=.*|METRIC=${METRIC}|" "$CONF"
sed -i -E "s|^XMM7360_DIR=.*|XMM7360_DIR=${DRIVER_DIR}|" "$CONF"
grep -E '^(APN|DNS|METRIC|XMM7360_DIR)=' "$CONF"

log "5/5 挂起恢复单元 + 启用扩展"
install -D -m 644 "$ROOT/files/etc/systemd/system/fibocom-l850-resume.service" \
        /etc/systemd/system/fibocom-l850-resume.service
systemctl daemon-reload
systemctl enable fibocom-l850-resume.service >/dev/null

# 首次 bring-up：先保证是"干净"的 RPC 会话。
# xmm7360 的 RPC 初始化每次模块加载只接受一次（上游文档明确写了）：
# 如果模组此前已经被初始化过（例如反复手工试过），直接再跑会卡在等响应上。
log "重载 xmm7360 模块，确保 RPC 会话是干净的"
systemctl stop fibocom-l850-up.service 2>/dev/null || true
modprobe -r xmm7360 2>/dev/null || true
sleep 2
modprobe xmm7360 2>/dev/null || true
sleep 4

systemctl start fibocom-l850-up.service --no-block 2>/dev/null \
  || log "bring-up 启动失败，看 journalctl -u fibocom-l850-up -n 30"
log "bring-up 已在后台跑（Type=oneshot，正常 30–60 秒），不再阻塞终端"
sudo -u "$LOGIN_USER" \
     DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u "$LOGIN_USER")/bus" \
     gnome-extensions enable "$UUID" 2>/dev/null \
  || log "扩展启用失败很正常（Wayland 下新扩展要重载 Shell）——重新登录后在扩展应用里打开"

cat <<EOF

完成。接下来：
  1) 注销并重新登录（Wayland 下新装的扩展必须重载 Shell），快速设置面板里会出现 "Mobile Data"；
  2) 没出现的话：gnome-extensions list | grep fibocom，再到"扩展"应用里打开它；
  3) 验证：
       sudo systemctl status fibocom-l850-up.service --no-pager | head -12
       fibocom-l850-status
       ip -4 addr show wwan0 ; ip route | grep wwan0
       curl -s --noproxy '*' --interface wwan0 -o /dev/null -w '%{http_code}\\n' http://www.baidu.com
       mmcli -L          # 应为 "No modems were found"（udev 规则把 MM 挡在门外）
EOF
