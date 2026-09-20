#!/usr/bin/env bash
# Part of xmm7360-mvp. SPDX-License-Identifier: GPL-2.0-only
# 让上游的 fibocom-l850-up.service 不再影响启动：
#   1) 改用 timer（OnBootSec=15s）触发 —— bring-up 完全脱离启动关键路径；
#   2) 给服务加 TimeoutStartSec=120 —— 万一卡死，systemd 2 分钟后收掉它；
#   3) 限制重启风暴。
# 逻辑、脚本、面板开关都不变，只是"什么时候、以什么方式"被拉起。
set -euo pipefail

# 仓库自身位置（clone 到哪都行）
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ $EUID -eq 0 ]] || { echo "需要 root：sudo $0" >&2; exit 1; }

log() { printf '\033[1m==>\033[0m %s\n' "$*"; }

log "1/3 安装 timer（开机 15 秒后后台触发）"
install -D -m 644 "$ROOT/files/etc/systemd/system/fibocom-l850-up.timer" \
        /etc/systemd/system/fibocom-l850-up.timer

log "2/3 给 up.service 加超时 + 重启限流（drop-in，不改上游文件）"
install -D -m 644 \
    "$ROOT/files/etc/systemd/system/fibocom-l850-up.service.d/10-no-boot-block.conf" \
    /etc/systemd/system/fibocom-l850-up.service.d/10-no-boot-block.conf
systemctl daemon-reload

log "3/3 取消 up.service 的开机依赖，改为 timer"
systemctl disable fibocom-l850-up.service >/dev/null 2>&1 || true
systemctl enable --now fibocom-l850-up.timer
systemctl list-timers fibocom-l850-up.timer --no-pager | head -3

cat <<'EOF'

完成。现在的行为：
  - 开机时 multi-user/graphical target 不再等这个 bring-up：15 秒后由 timer 在后台拉起；
  - 万一它卡死：120 秒后 systemd 收掉，启动与桌面不受影响；
  - 面板开关（Mobile Data）与命令行不变：
      sudo systemctl start fibocom-l850-up.service     # 手动重跑
      sudo /usr/local/bin/fibocom-l850-ctl on|off|status
      systemctl status fibocom-l850-up.service

回滚（恢复上游原样）：
  sudo systemctl disable --now fibocom-l850-up.timer
  sudo systemctl enable fibocom-l850-up.service
  sudo rm -f /etc/systemd/system/fibocom-l850-up.service.d/10-no-boot-block.conf
  sudo rm -f /etc/systemd/system/fibocom-l850-up.timer
  sudo systemctl daemon-reload
EOF
