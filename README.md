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

> 上面这段验证记录来自**临时方案**：我当时用 `open_xdatachannel.py -c xmm7360.ini`
> （`dbus=True`）让 NetworkManager 管了一条 generic 连接。它证明驱动+连通性没问题，
> 但 GNOME 面板里看不到它（NM 的 generic 设备没有对应 UI 分类）。**这套已经被下面的
> 社区 GUI 层取代**，`install-gnome-layer.sh` 会把 NM 连接和临时单元一并清掉。

## GUI 层（社区方案，当前生效）

社区的"正常 GUI 联动"是 [michaelruck/fibocom-l850-gnome-lte](https://github.com/michaelruck/fibocom-l850-gnome-lte)
（上游 issue #246 推荐）：开机服务 + D-Bus 后端 + polkit + **GNOME Shell 扩展**
——快速设置里一个 **"Mobile Data"** 开关，带运营商/RAT/信号 dBm，APN 在扩展偏好里改。

安装（本目录只做三处必要改动，见脚本注释）：

```bash
sudo /home/xmm/ai/xmm7360-driver/install-gnome-layer.sh
```

它做的事：清掉临时层（NM 连接 / 临时的 boot+resume 单元 / 旧 udev 规则）→
给扩展开 GNOME 50（上游只声明 45–48）→ 装上游（指向本目录打了内核 7.0 补丁的源码）→
写 `APN=3gnet` / DNS → 装挂起恢复单元（调上游 `fibocom-l850-ctl on`）→ 重载模块后 bring-up。

## 日常用法（当前）

| 场景 | 命令 |
|---|---|
| 面板开关 | GNOME 快速设置里的 **Mobile Data**（扩展 `fibocom-l850-lte@michaelruck.github.io`） |
| 命令行开关 | `sudo /usr/local/bin/fibocom-l850-ctl on\|off\|status` |
| 信号/运营商/RAT | `fibocom-l850-status` |
| 看 bring-up 日志 | `journalctl -u fibocom-l850-up.service -b -n 40` |
| 换 APN | 改 `/etc/fibocom-l850-lte/modem.conf` 的 `APN=`，或扩展偏好里改；改完 `sudo systemctl restart fibocom-l850-up.service` |
| 挂起/合盖恢复 | 自动（`fibocom-l850-resume.service` → `fibocom-l850-ctl on`） |
| 彻底卸载/回滚 iosm | `sudo /home/xmm/ai/xmm7360-driver/uninstall.sh` |

## 已知限制（来自驱动本身）

- **没有电源管理**：挂起后模组掉线，必须重新配置 —— 这就是 `xmm7360-resume.service` 的作用；
- **不要用 ACPI `_RST` 当恢复手段**（2026-09-20 实测教训）：在模组已经被初始化过之后执行
  `echo 1 > /sys/bus/pci/devices/0000:05:00.0/reset`，会让它停在
  `modem still booting, waiting...` → `unknown modem status: 0xffffffff`，
  驱动 probe 直接 `failed with error -22`，连 `wwan0`/`ttyXMM*` 都不会出现。
  这台机器的可靠恢复是**重启、最好是关机（完全断电）再开机**：开机时模组刚上电、
  状态干净，`fibocom-l850-up.service` 能正常把它拉起来。
  需要重来一次数据会话时，优先用 `sudo /usr/local/bin/fibocom-l850-ctl on`
  （上游自带"重载模块 + 重连"自愈），或直接重启；
- **ModemManager 在这硬件上没有可用路径**（社区文档结论）：XMM7360 不暴露 MBIM/QMI 控制口，
  `iosm` 下 AT 口在 RPC 初始化前是哑的，MM 抓到的只有"幻影移动开关"（不能上网）。
  所以 GUI 由上面的 GNOME 扩展提供，udev 规则把 MM 明确挡开（`mmcli -L` 应为空）；
- **内核升级**：靠 DKMS 自动重编；Secure Boot 开启时需要给模块签名（见上游 `INSTALLING.md`）。
- 驱动源码较老（2024-02），上游已停更；本目录内 `src/` 是带本机兼容补丁的可用快照，
  以后内核再变 API 时盯着 `dkms status` / `make` 的编译报错即可。
