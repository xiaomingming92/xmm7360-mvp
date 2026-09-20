#!/bin/bash
# 往 XMM7360 的 AT 口发命令并打印回复 —— 用于探测制式/频段相关命令是否支持。
# 默认只发**查询类**命令（不会改动任何设置）。
#
# 用法：
#   sudo ./probe-at.sh                        # 用默认的几条查询
#   sudo ./probe-at.sh "AT+WS46?" "ATI"       # 只发指定的命令
#
# 说明：/dev/ttyXMM* 属 root:dialout（0660），所以需要 root 或者把用户加进 dialout：
#   sudo usermod -aG dialout xmm   （加完要重新登录）
set -u

PORT=${PORT:-/dev/ttyXMM1}

if [[ $EUID -ne 0 ]] && ! id -nG | tr ' ' '\n' | grep -qx dialout; then
    echo "需要 root，或把用户加进 dialout 组：sudo usermod -aG dialout $USER" >&2
    exit 1
fi
[ -e "$PORT" ] || { echo "找不到 $PORT（模组驱动没加载？）" >&2; exit 1; }

CMDS=("$@")
if [ ${#CMDS[@]} -eq 0 ]; then
    CMDS=(
        "AT"            # 基本连通性
        "ATI"           # 型号/固件
        "AT+WS46=?"     # 支持哪些网络模式组合（3GPP 27.007）
        "AT+WS46?"      # 当前网络模式
        "AT+XACT=?"     # Intel 私有：支持哪些接入技术
        "AT+COPS?"      # 当前注册的运营商/制式
        "AT+CEREG?"     # LTE 注册状态
    )
fi

stty -F "$PORT" raw -echo 2>/dev/null
echo "== 端口 $PORT（每条约 2 秒）"
for c in "${CMDS[@]}"; do
    printf '\n### %s\n' "$c"
    exec 3<>"$PORT"
    printf '%s\r' "$c" >&3
    timeout 2 cat <&3
    exec 3<&-
done
echo
