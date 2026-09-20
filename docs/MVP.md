# MVP：事件优先 + 低频探针兜底的 4G 自愈架构

> 2026-09-20 定稿；命名来自用户（"我称之为 MVP"）。
> 适用：ThinkPad A285 / Fibocom L850-GL（Intel XMM7360）+ 社区 xmm7360-pci 驱动。

## 一、为什么需要它（当天踩到的真实故障）

| 故障 | 表现 | 没有自愈时的代价 |
|---|---|---|
| 刷固件后 FCC 重新上锁 | 卡在 `UtaMsSmsInit`、注册不上 | 两小时摸索 |
| 刷固件后制式重置为 `WS46=28` | 有 SIM、`CSQ 99` 无信号 | 一直连不上 |
| 驱动 TX 丢帧雪崩（`Failed to ship coalesced frame` ×16547） | 链路/IP 都在、上行已死（陈旧地址） | 会话死透，只能手动救 |
| 会话进程退出后 IP 残留 | `Status: connected` 但 `curl 000` | 面板"假在线" |

共同点：**故障发生时没有可靠事件**，而"事件"是恢复速度的唯一决定因素。

## 二、架构

```
事件源（订阅）                                       去抖 5s        动作（统一阶梯）
① 内核日志 journalctl -k -f ─┐
   xmm7360.*Failed to ship   │
   /rror/timeout/refused/…   │
② netlink ip monitor         ├─────►  fibocom-l850-watch ──►  fibocom-l850-ctl on
   link/route/address(wwan0) │                                  │
③ 面板 D-Bus / 开机 timer /  │                                  ▼
   命令行 ctl（用户与启动）  ┘                     诊断 → 软恢复 → 硬恢复 → 复核
④ 探针 每 120s ping ─────────►（沉默故障兜底）
```

### 恢复阶梯（`fibocom-l850-ctl on` + `fibocom-l850-up-retry`）

1. **诊断**：链路 up + 有 IPv4 + ping 得通（目标取 `modem.conf` 第一个 DNS）。
   只判 IPv4 会被"陈旧地址"骗过（当天踩过，表现为"点了没反应"）。
2. **软恢复**：重启 `fibocom-l850-up.service`；ensure 按 #186 策略在同一模块加载下重试，
   单次超时递增 45/60/120/180s，早期快速失败、快速重试。
3. **硬恢复**：连续失败 → 重载 `xmm7360` 驱动模块 → 再来一轮（清掉 TX 环/驱动坏状态）。
4. **纠偏**：连续失败时自动 `fibocom-l850-rat auto`（把被刷固件重置成 28 的 `WS46` 纠回 31）。
5. **复核**：每次"成功"都要求拿到 IPv4 **且 ping 通**，否则继续重试。

## 三、为什么不做纯 pub/sub

1. **驱动没有"数据会话健康"事件**：xmm7360-pci 只暴露 netdev + tty，没有健康上报；
2. **存在沉默故障**：链路/地址/路由都没变，但上行已死 —— 只能靠 ping 探针发现；
3. **模组 RPC 的事件流**（`UtaMsNetCellInfoIndCb` 等）只在持有 RPC 通道的进程里可见，
   而数据会话建立后那个进程会退出；做常驻监听要与会话抢通道，风险大于收益。

所以形态是：**事件负责"快"，探针负责"不漏"**。

## 四、当天演练数据

| 时刻 | 日志 | 说明 |
|---|---|---|
| 16:45–17:21（每 5 min） | `wwan0 已有 IPv4，无需动作` | 旧版 ensure 被陈旧地址骗过 |
| 17:22:00 | `第 1/3 轮 · 第 1/4 次：跑 bring-up（超时 45s…）` | 新版真判据生效 |
| 17:22:05 | `成功：wwan0 已有 IPv4 且 ping 221.6.4.66 通` | **5 秒恢复** |
| 之后 | `Status: bars 3, rsrp -92 dBm, LTE, 中国联通` | 面板 10s 内自动变信号格 |

## 五、调参与运维

| 想要 | 怎么做 |
|---|---|
| 探针更灵敏 | `sudo systemctl edit fibocom-l850-watch.service` → `Environment=PROBE_INTERVAL=60` |
| 事件更"广" | 改 `fibocom-l850-watch` 里的 grep 正则 |
| 看恢复过程 | `journalctl -t fibocom-l850-watch -f` / `journalctl -t fibocom-l850-retry -f` |
| 手动来一轮 | `sudo /usr/local/bin/fibocom-l850-ctl on`（或面板开关 / 菜单头右侧的圆钮「重新连接」） |
| 只想要轮询 | `sudo systemctl disable --now fibocom-l850-watch.service`（其余链路不受影响） |

## 六、历史对照：谁负责哪一层的坑

- **iosm（内核自带）**：坑在"改不动的地方" —— S3 唤醒后模组固件卡死
  （`PORT open refused, phase A-ROM/A-CD_READY`）只能 unbind/rebind 绕；
  NM 还报 `modem IP method unsupported`、不给默认路由。
- **xmm7360-pci（社区）**：坑在"能改但没人改的地方" —— FCC 解锁顺序、
  TX 丢帧雪崩、无电源管理、绕开 MM/NM 所以 GUI 要自己做。
- 结论：**能打补丁的那条路，才配得上 MVP。**

## 七、GNOME 面板集成易错点（都是当天实际踩过的）

| 坑 | 现象 | 正解 |
|---|---|---|
| 判据只看 IPv4 | 会话进程已退出、地址还在 → 面板"假在线"、点重连"没反应" | 判据 = 链路 up **+ 有 IPv4 + ping 通**（`fibocom-l850-ctl` / `-up-retry` / `-status` 同一套） |
| 判据不看 IPv4 | 驱动有地址、curl 返回 000 | `Status` 的 `connected` 必须要求 `wwan0` 上有 IPv4 |
| 限高设错对象 | 菜单超出屏幕、滚不动 | `max-height` 必须设在 `menu.actor`（GNOME 的 `PopupSubMenu._needsScrollbar()` 读的就是它）；设在内容 box 或顶层 `menu` 上都不生效 |
| 顶层菜单没有滚动容器 | 只有子菜单能滚 | 详情行放进 `PopupSubMenuMenuItem`；GNOME 只有 `PopupSubMenu` 自带 `St.ScrollView` |
| 想在菜单头那一行放按钮 | 只能加一整行菜单项 | 落点是 `QuickToggleMenu` 的 `_header` 网格；按钮 `style_class: 'icon-button flat'` + `St.Icon`，图标 `view-refresh-symbolic` |
| `addHeaderSuffix()` 放不到行尾 | 公开 API 把 actor 插在「标题」和 `_headerSpacer` 之间，而 x_expand 的是 spacer → 按钮紧贴标题文字（GNOME 的 Wi-Fi 扫描菊花就是这个位置） | 要行尾就复用同一套内部网格、换个顺序：`标题 \| _headerSpacer（伸缩） \| 按钮`（`_header` / `_headerTitle` / `_headerSpacer` 在 GNOME 46–50 未改名）；拿不到内部字段时退回 `addHeaderSuffix()`，再不行退回菜单行 |
| `addHeaderSuffix` 只能调一次 | 二次调用会先 `remove_child(_headerSpacer)`，spacer 已不在 → 报错 | 表头后缀只挂一个 actor |
| Wayland 下改完没变化 | 注销重登前后一样 | gnome-shell 的 ESM 模块缓存只在新会话建立；改 `extension.js` 必须**注销重登**（disable/enable 不够） |
| 装了两份容易改错 | 改了 repo 里的文件但面板没变 | 源在 `files/gnome-extension/<uuid>/extension.js`，活文件在 `~/.local/share/gnome-shell/extensions/<uuid>/`；用 `install-gui-polish.sh` 同步，别手改活文件 |
