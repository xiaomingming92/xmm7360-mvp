# XMM7360 开源驱动（xmm7360-pci）替换方案

ThinkPad A285 的 Fibocom L850-GL（Intel XMM7360，PCI `8086:7360`）在内核自带 `iosm`
驱动下问题很多：S3 唤醒卡死（`PORT open refused, phase A-ROM/A-CD_READY`）、
bearer 只给出 `10.x/0` + 无网关导致 NetworkManager 装不上默认路由（"卡认得到、网出不去"）。

本目录改用社区驱动 **[xmm7360/xmm7360-pci](https://github.com/xmm7360/xmm7360-pci)**：
它自己接管 PCI 设备、直接开一条原生 IP 数据通道，不用 ModemManager/MBIM。

## 内容

```
xmm7360-driver/
├── install.sh / uninstall.sh     ← 装 / 回滚
├── files/                        ← 要落盘到系统的配置文件（镜像 /etc、/usr/local/bin）
└── src/                          ← 驱动源码（2024-02-24 快照 + 本机内核 7.0 的两处兼容补丁）
```

## 本机对源码做的改动（否则内核 7.0 编不过）

| 位置 | 改动 |
|---|---|
| `xmm7360.c: xmm7360_net_setup()` | `hrtimer_init()` 在新内核已被移除 → 改用 `hrtimer_setup(&xn->deadline, xmm7360_net_deadline_cb, CLOCK_MONOTONIC, HRTIMER_MODE_REL)`（用 `LINUX_VERSION_CODE` 包住，旧内核仍走原路径） |
| `xmm7360.c: xmm7360_tty_write()` | `tty_operations.write` 原型改为 `ssize_t (*)(struct tty_struct *, const u8 *, size_t)` → 同步改签名（同样按版本号包住） |

## 装

```bash
sudo /home/xmm/ai/xmm7360-driver/install.sh          # 默认 APN=3gnet（联通）
# 想换 APN / DNS：
APN=3gnet DNS=221.6.4.66 sudo -E /home/xmm/ai/xmm7360-driver/install.sh
```

安装脚本做的事：

1. `apt install dkms python3-pyroute2 python3-configargparse python3-dbus`；
2. 把旧的 iosm 方案（`wwan-autofix*` 单元、`79-wwan-autofix.rules`）移到 `/root/xmm-switch-backup/` 停用；
3. `iosm` 解绑 + `blacklist iosm` + 重建 initramfs（`ModemManager` 保持运行，只是让它别 probe `ttyXMM*`）；
4. ACPI `_RST` 复位模组（清掉 iosm 留下的 wedge），`dkms install xmm7360-pci/2024.02.24-codex1`；
5. `modprobe xmm7360`，等 `/dev/ttyXMM*`（失败会自动再复位 PCI 设备重试一次）；
6. 落盘配置：`/etc/xmm7360.ini`（APN）、`/usr/local/bin/xmm-up`、`xmm-resume`、
   `xmm7360-boot.service`（开机拉起）、`xmm7360-resume.service`（挂起恢复）、
   `lte` 命令软链、`ttyXMM*` 的 MM 避让规则；
7. 首次拉起数据通道（`xmm-up`）。

## 验证

```bash
ls /dev/ttyXMM*                 # ttyXMM0 ttyXMM1 ...
lspci -k -s 05:00.0            # Kernel driver in use: xmm7360
ip -4 addr show wwan0          # 应有运营商分配的 IPv4
ip route                       # 应有 default ... dev wwan0 metric 700
nmcli con show --active | grep xmm7360    # NetworkManager 连接（GNOME 网络面板里能看见）
curl -s --noproxy '*' --interface wwan0 -o /dev/null -w '%{http_code}\n' http://www.baidu.com
journalctl -t xmm-up -n 20
```

## 本机验证记录（2026-09-20 09:07，联通 LTE）

```
$ nmcli con show --active | grep xmm7360
xmm7360  45606672-ee8c-458e-b5c2-bec64ad447f3  generic  wwan0

$ nmcli -f GENERAL.STATE,IP4.ADDRESS,IP4.GATEWAY,IP4.DNS con show xmm7360
GENERAL.STATE:  已激活
IP4.ADDRESS[1]: 10.100.205.156/32
IP4.GATEWAY:    10.100.205.156
IP4.DNS[1]:     221.6.4.66

$ ip route
default via 10.100.205.156 dev wwan0 proto static metric 950
10.100.205.156 dev wwan0 proto static scope link metric 950
default via 192.168.1.1 dev wlp2s0 proto dhcp src 192.168.1.114 metric 600

$ curl -s --noproxy '*' --interface wwan0 -o /dev/null -w '%{http_code}\n' http://www.baidu.com
200
```

注意 metric：`/etc/xmm7360.ini` 的 `metric=700` 只作用于脚本自己加的那条路由；
经 NM 激活后实际生效的是 NM 侧的 `ipv4.route-metric`（默认按设备类型算出来是 950），
所以默认还是走 wifi（600）。**想优先走 4G**：

```bash
sudo nmcli con mod xmm7360 ipv4.route-metric 500
sudo nmcli con up xmm7360
```

## 日常用法

| 场景 | 命令 |
|---|---|
| 手动拉起/重连 | `sudo /usr/local/bin/xmm-up` |
| 挂起/合盖恢复后 | 自动（`xmm7360-resume.service`），也可 `sudo /usr/local/bin/xmm-resume` |
| 换 APN | 编辑 `/etc/xmm7360.ini` 的 `apn=`，再 `sudo /usr/local/bin/xmm-up` |
| 临时断开 | `sudo ip link set wwan0 down` |
| 彻底卸载/回滚 iosm | `sudo /home/xmm/ai/xmm7360-driver/uninstall.sh` |

## 已知限制（来自驱动本身）

- **没有电源管理**：挂起后模组掉线，必须重新配置 —— 这就是 `xmm7360-resume.service` 的作用；
- **GUI 联动方式**：驱动不走 ModemManager，而是由 `open_xdatachannel.py`（`dbus=True`）通过
  D-Bus 在 NetworkManager 里建/更新一条名为 `xmm7360` 的连接（`type=generic`、`interface-name=wwan0`、
  manual 地址 /32 + 网关 + 运营商 DNS），再把设备设为 Managed 并 `ActivateConnection`。
  所以 **GNOME 的网络菜单 / nmcli 里能正常看到并管理这条连接**；GNOME 设置里那个
  "移动宽带"面板本身是 ModemManager 专用的，看不到 MM 条目是正常的（不代表没有 GUI 联动）；
- **内核升级**：靠 DKMS 自动重编；Secure Boot 开启时需要给模块签名（见上游 `INSTALLING.md`）。
- 驱动源码较老（2024-02），上游已停更；本目录内 `src/` 是带本机兼容补丁的可用快照，
  以后内核再变 API 时盯着 `dkms status` / `make` 的编译报错即可。
