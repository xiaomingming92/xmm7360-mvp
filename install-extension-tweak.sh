#!/usr/bin/env bash
# 用本目录里的补丁版 extension.js 覆盖 GNOME 扩展（改布局：QuickToggle → QuickMenuToggle）。
# 会先备份成 extension.js.bak-<时间戳>，随时可回滚。
# 注意：必须以**普通用户**运行（gnome-extensions 需要会话 D-Bus）。
set -euo pipefail

SRC=/home/xmm/ai/xmm7360-driver/files/gnome-extension/fibocom-l850-lte@michaelruck.github.io/extension.js
DEST="$HOME/.local/share/gnome-shell/extensions/fibocom-l850-lte@michaelruck.github.io"
UUID=fibocom-l850-lte@michaelruck.github.io

if [[ $EUID -eq 0 ]]; then
  echo "请以普通用户运行（不要 sudo）：gnome-extensions 需要你的会话 D-Bus" >&2
  exit 1
fi
[[ -f "$DEST/extension.js" ]] || { echo "找不到已安装的扩展：$DEST" >&2; exit 1; }
[[ -f "$SRC" ]] || { echo "找不到补丁文件：$SRC" >&2; exit 1; }

bak="$DEST/extension.js.bak-$(date +%Y%m%d-%H%M%S)"
cp -a "$DEST/extension.js" "$bak"
install -m 644 "$SRC" "$DEST/extension.js"
echo "已备份原文件到：$bak"

gnome-extensions disable "$UUID" 2>/dev/null || true
sleep 1
gnome-extensions enable "$UUID" 2>/dev/null || true
sleep 2
gnome-extensions info "$UUID" | grep -E "Enabled|State" || true

cat <<EOF

完成。看效果：
  1) 打开快速设置面板（右上角），Mobile Data 磁贴现在应当和 蓝牙/性能模式 一样带 ">" 箭头，
     点主体开关数据、点箭头打开菜单（刷新状态 / APN / 扩展设置）；
  2) 若界面没变化：ESM 模块有缓存，注销重登一次即可；
  3) 若磁贴消失或报错：
       journalctl --user -b -o cat /usr/bin/gnome-shell | grep -i fibocom | tail -20
     回滚：
       cp "$bak" "$DEST/extension.js"
       gnome-extensions disable $UUID; gnome-extensions enable $UUID
EOF
