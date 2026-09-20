# xmm7360-mvp — Fibocom L850-GL / Intel XMM7360 的 4G 自愈栈（ThinkPad A285）

> 社区驱动 xmm7360-pci 的可复现部署 + **事件优先、探针兜底的恢复链**（见 [docs/MVP.md](docs/MVP.md)）
> + GNOME 快速设置面板。本机环境：ThinkPad A285 / Ubuntu / 内核 7.0 / GNOME 50。

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
git clone https://github.com/xiaomingming92/xmm7360-mvp.git
cd xmm7360-mvp

sudo ./install.sh                                    # 默认 APN=3gnet（联通）
# 想换 APN / DNS：
APN=3gnet DNS=221.6.4.66 sudo -E ./install.sh
```

所有安装脚本都用**自身所在目录**定位仓库，clone 到哪都行；但 **clone 目录别删** ——
GNOME 层会把 `<repo>/src` 的绝对路径记进 `/etc/fibocom-l850-lte/modem.conf` 的
`XMM7360_DIR=`，部署后的 bring-up 要靠它找 `rpc/open_xdatachannel.py`。

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

### 2026-09-20 11:10 实测（xmm7360-pci 路径 + 社区 GUI 层）✅

bring-up 卡在 `RPC executing UtaMsSmsInit` 时，按上游
[issue #186](https://github.com/xmm7360/xmm7360-pci/issues/186) 的做法
**不重载模块、把 bring-up 连跑几次**后成功：

```
wwan0            inet 10.100.37.123/32
ip route         default dev wwan0 proto static metric 1000
Status (D-Bus)   {"state":"connected","rsrp_dbm":-98,"earfcn":1650,"rat":"LTE",
                  "mcc":460,"mnc":1,"operator":"460/01","bars":2}
curl --interface wwan0 http://www.baidu.com → 200
```

这条规律已写进 ensure 脚本 `files/usr/local/bin/fibocom-l850-up-retry`：
判成功 = wwan0 有 IPv4；先在同一模块加载下重试 3 次（#186），仍失败才重载模块再来一轮。
成功时 bring-up 进程会自行退出、释放 `/dev/xmm0/rpc`，面板才读得到信号（否则报 busy → 0 格）。

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
git clone https://github.com/michaelruck/fibocom-l850-gnome-lte vendor/fibocom-gnome-lte
sudo ./install-gnome-layer.sh
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
| 彻底卸载/回滚 iosm | `sudo ./uninstall.sh`（在仓库目录里） |

## 已知限制（来自驱动本身）

- **没有电源管理**：挂起后模组掉线，必须重新配置 —— 这就是 `xmm7360-resume.service` 的作用；
- **FCC 锁每次开机都会重新锁上，且必须先解锁才能初始化**（2026-09-20 实测定位）：
  上游 `open_xdatachannel.py` 把 `do_fcc_unlock()` 放在 `UtaMsSmsInit…SimOpenReq` **之后**，
  而模组处于 FCC 锁定状态时**不应答这些初始化命令** → 表现就是"卡在 `UtaMsSmsInit`、
  一直不注册、开机后要等很久（其实是等下一次重试）"。
  产物里的 `open_xdatachannel.py` 已把 FCC 解锁**提到初始化序列最前面**（这才是真正的解）；
  另外 `rpc.py::do_fcc_unlock()` 也改为依次尝试两个 key（上游 issue #240 提到工厂重置的
  模组要用全零 hash；本机实测硬编码 `3df8c719` 仍然有效，全零作为兜底）。
  日志判断：`FCC lock: state 0 mode 2` = 锁着（需要解锁）；`state 1` = 已解锁。
- **重刷模组固件后要补一件事**（2026-09-20 实测，刷国际版后卡了两小时的第二条原因）：
  2. **网络模式偏好会被重置成 `AT+WS46=28`（只有 2G+3G）**：国内 2G/3G 多地已关，
     于是"有 SIM、`AT+CSQ: 99,99` 无信号、`AT+COPS: 2` 搜索中、注册不上"。
     用 `sudo /usr/local/bin/fibocom-l850-rat auto`（或面板 菜单→网络模式→自动）改回
     `AT+WS46=31`（2G+3G+4G）即可；ensure 在连续失败时也会自动纠一次。
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

## 许可证与来源（尊重原创）

本仓库是**多许可**的：**每个文件头部的 SPDX 标识优先**，其余自写部分适用根目录
[LICENSE](LICENSE)（GPL-2.0 全文）。

| 范围 | 许可 | 来源 |
|---|---|---|
| 自写的安装/自愈脚本（`install*.sh`、`uninstall.sh`、`probe-at.sh`、`fibocom-l850-{up-retry,selfheal}`、`xmm-up`、`xmm-resume`）、`docs/`、README | `GPL-2.0-only` | 本机（xmm + Codex），刻意与驱动同许可 |
| `src/`（xmm7360-pci 驱动源码 + 本机兼容/TX 补丁） | `GPL-2.0 OR BSD-3-Clause`（双许可，二选一） | 上游 [xmm7360/xmm7360-pci](https://github.com/xmm7360/xmm7360-pci)，作者 **James Wah**（© 2020 genua GmbH / James Wah）。注意：上游没有 LICENSE 文件，`src/xmm7360.c` 头部是唯一许可声明，同目录 `rpc/`、`scripts/` 未写许可头——本仓库按"同项目、同双许可"理解，有异议以上游为准 |
| `files/usr/local/bin/fibocom-l850-{ctl,daemon,rat,status,watch}`、`files/gnome-extension/`、polkit 策略 | `GPL-3.0-or-later`（沿用上游，**不可改成 GPL-2.0**） | 上游 [michaelruck/fibocom-l850-gnome-lte](https://github.com/michaelruck/fibocom-l850-gnome-lte)，作者 **Michael Ruck**（GPL-3.0） |

两点说明：

- 根许可为什么是 GPL-2.0 而不是 MIT：本仓库主体是内核驱动及其部署脚本，
  与 `src/` 保持一致，避免"根 MIT + 内部 GPL"这种容易误导人的组合；
- GPL-2.0 与 GPL-3.0 的部分是**独立程序**（脚本调用命令、不链接进内核模块），
  同仓库分发不构成许可冲突；改动上游文件时请保留其原有许可头。

### 上游项目与我们的改动

| 上游 | 我们做了什么 |
|---|---|
| [xmm7360/xmm7360-pci](https://github.com/xmm7360/xmm7360-pci) | 内核 7.0 两处 API 兼容补丁、TX 丢帧背压补丁、FCC 解锁提到初始化最前（`open_xdatachannel.py`）、rpc FCC key 兜底 |
| [michaelruck/fibocom-l850-gnome-lte](https://github.com/michaelruck/fibocom-l850-gnome-lte) | GNOME 50 支持、面板文案对齐 GNOME、菜单头「重新连接」圆钮、ensure 重试/分级恢复/卡死看门狗、事件守护 MVP |

<!-- SPDX-License-Identifier: GPL-2.0-only -->
