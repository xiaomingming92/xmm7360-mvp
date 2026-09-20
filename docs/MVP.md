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
| 看触发时的现场快照 | `journalctl -t fibocom-l850-snap -n 40`（每次触发恢复前自动记一段） |
| 手动来一轮 | `sudo /usr/local/bin/fibocom-l850-ctl on`（或面板开关 / 菜单头右侧的圆钮「重新连接」） |
| 强制跳过软重试 | `sudo /usr/local/bin/fibocom-l850-ctl on --hard`（怀疑驱动错误态时；watcher 命中内核错误事件会自动这么调） |
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

## 八、分级恢复 + 取证快照（2026-09-20 晚补强）

### 起因：一次"符合设计"但完全不可接受的恢复

| 时刻 | 事件 | 判断 |
|---|---|---|
| 18:06:51 | 开机首轮 bring-up 45s 超时失败 | 设计内，但 45 秒白扔 |
| 18:07:42 → 18:07:46 | 第 2 次 **4 秒**成功 | ✅ |
| 20:26:22 | 内核 `bad status feedb007` + `Failed to ship coalesced frame`（各 1 条） | 事件被 watcher 同秒捕获 ✅ |
| 20:27:08–20:28:13 | 4 次软重试**全部**撞 `[Errno 16] Device or resource busy: '/dev/xmm0/rpc'` | ❌ 白费 ~2 分钟 |
| 20:30–20:57:40 | 14 次触发 / 29 次 bring-up / 6 次"成功"才收敛；其间**内核一条 xmm 日志都没有** | ❌ 抖了 31 分钟 |

### 两条根因（都在驱动里，改不动的地方）

1. **驱动错误态是粘滞的**：`xmm7360_poll()` 见 `bar2[BAR2_STATUS] != 0x600df00d`
   就 `xmm->error = -ENODEV`；全驱动的 RPC 读写都直接返回这个 errno，
   而 `error` 只有 `xmm7360_dev_init()`（= 重新 probe）才清零，
   驱动里那个 `init_work` 从来没被 `schedule_work` 过 → **不会自愈**。
2. **背压之后没人唤醒**：我们的丢帧补丁 `netif_stop_queue()` 之后，唤醒只在
   `xmm7360_net_poll()`（RX 路径）；设备已 error → 没有 RX → 队列永远停着。
   表现就是"IPv4 在、ping 死、内核不吭声"。`xmm7360_net_xmit()` 在 TD ring 满时同理，
   而且驱动没有 `ndo_tx_timeout`（没有 TX 看门狗）。

### 补强内容

| 补强 | 做法 |
|---|---|
| 分级恢复 | watcher 命中 `Failed to ship` / `bad status` / `unknown modem status` / `crashed` → `ctl on --hard`：写 `/run/fibocom-l850-force-hard`（时间戳，120 秒内有效）→ ensure **跳过**注定失败的软重试，直接硬恢复 + 一次 bring-up；ensure 跑到一半收到标记也会立刻转硬恢复 |
| 不打断正在跑的 ensure | `ctl on --hard` 先把标记落盘再判断"ensure 正在跑"，所以正在跑的 ensure 也能读到（软重试不会再白跑） |
| 标记不误伤 | 链路本来就健康（ping 通）时 `ctl on` 直接删标记；ensure 消费即删，且只认 120 秒内的 |
| RPC 占用取证 | 每次 bring-up 的输出留档到 `/run/fibocom-l850-up.log`；撞 `Device or resource busy` 时把 `/dev/xmm0/rpc` 的持有者打进 journal |
| 每次尝试留现场 | 失败行现在带 `addr=… 默认路由=… 会话进程=…`，一眼区分"陈旧地址"与"真会话" |
| 触发前快照 | `snapshot()` 写 `fibocom-l850-snap`：内核尾、`Failed to ship` 计数、rpc 持有者、地址/路由/会话进程/链路。**故意不查 Status**（Status 会打开 rpc，可能把紧接着的 bring-up 顶成 EBUSY） |
| 开机首轮 | 开机后 300 秒内的第一次超时 45 → 90 秒（冷启动实测第 1 次必然超时、第 2 次 4 秒就成）；事件驱动的恢复仍保持 45 秒快速失败 |

### 还没做（要等取证）

- **驱动自愈**：`bad status` 时不只标记 error，而是限次重初始化（`init_work` 那段惰性代码可以派上用场）；
- **TX 看门狗**：`ndo_tx_timeout` + `watchdog_timeo`，队列停住且 `qp_can_write()` 为真时唤醒；
- 这两条都要重编模块 + 重载（会让 4G 断一次），所以等下一次复现、快照把机制钉死后再动。

## 九、三轮演练实测（2026-09-20 22:47 / 22:50 / 22:54）

演练手法：往内核日志注入一条 `xmm7360 ... Failed to ship coalesced frame`（watcher 无法
区分真假），必要时先 `ip addr flush dev wwan0` 把链路弄成真不健康。

| 轮次 | 做法 | 结果 | 钓出的问题 |
|---|---|---|---|
| ① 22:47 | 只注入假错误（链路健康） | 事件捕获✅ 分级 hard✅ 快照✅，但**恢复没跑** | `ctl` 决策没进 journal（黑盒）；"链路健康就删标记"会让紧随其后的真掉线退回慢路径 |
| ② 22:50 | 清地址 + 注入 | 硬恢复启动了但**被腰斩** | `fibocom-l850-rat` 里的 `systemctl restart ensure` 把正在跑的 ensure 自己 SIGTERM 掉 → `modprobe` 一步没执行 |
| ③ 22:54 | 同 ②，带修复 | 完整走完：`收到硬恢复请求` → `硬恢复：重载模块` → `模块已重载（内核确认：modem is ready）` → `硬恢复后第 1 次 bring-up` → 成功，curl 200 | 首条 RPC 静默卡死时白等满 180 秒超时（第 6 个坑） |
| ④ 23:02 | 同 ②③，装上看门狗 | `bring-up 输出停滞 45s（疑似 #186）→ 杀掉重跑` ×2 → 第 3 次 7 秒成功，curl 200 | 无需再修：链闭环 |

### 三轮共钓出 6 个坑（全部已修）

| # | 坑 | 证据 | 修法 |
|---|---|---|---|
| 1 | `ctl` 的判断被 watcher 丢弃 | 22:47 之后 journal 里只有"触发恢复"，没有任何"为什么不动作" | `ctl` 关键决策改走 `logger -t fibocom-l850-ctl` |
| 2 | 去抖会吃掉硬事件 | 22:50:31 `硬事件落在去抖窗口内` 之前，硬提示曾被静默丢弃 | 硬事件即便在去抖窗口内也**必须落标记** |
| 3 | "链路此刻健康就删标记"太激进 | 22:47 注入后链路还通 → 标记被删 | `ctl` 健康时不动作但**保留**标记；由 ensure 确认健康时才消费 |
| 4 | 硬恢复被自己腰斩 | 22:50:43 `Main process exited, code=killed, status=15/TERM`；内核无 `modem is ready` | `rat` 新增 `NORESTART=1` + "已有 ensure 在跑别重启"两个例外；三处会 restart ensure 的脚本（ctl/rat/selfheal）都有防自杀守卫 |
| 5 | 以为重载了、其实没有 | 只有 22:50 那次内核无 `modem is ready` | `hard_recover` 在 modprobe 前后各查一次 `modem is ready`，成败都记一行 |
| 6 | 卡死时白等满超时 | 22:55:33 发完第一条 RPC 后**静默 2 分钟**；而成功的 bring-up 只要 3~20 秒 | `run_bringup` 加"卡死看门狗"：输出连续 45 秒不增长 → 判定 #186 卡死 → 杀掉重跑 |

### 数字对照

| 指标 | 白天那场风暴（20:26–20:57） | 第三轮演练（22:54–23:00） | 第四轮演练（23:02–23:04，装看门狗后） |
|---|---|---|---|
| 触发恢复 | 14 次 | 3 次 | 3 次 |
| bring-up 次数 | 29 次 | 6 次（第 3 次 3 秒成功） | 3 次（第 3 次 7 秒成功） |
| 恢复耗时 | 31 分 18 秒 | 5 分 54 秒 | **2 分 28 秒** |
| 需要人工 | 否 | 否 | 否 |

看门狗阈值定 30 秒的依据：成功的 bring-up 是"1~2 秒内把 25 条 RPC 一口气喷完"
（实测 23:04:47 那一秒），随后几秒拿到 IPv4，**全程输出连续、3~20 秒结束**；
卡死则是"第一条 RPC 发出去后彻底静默"（实测 22:55:33 起 2 分钟零输出）。
所以静默 30 秒足以确诊，不必等满 45/60/120/180 秒。

### 仍然待做（等下一次真实复现的快照）

- 驱动侧：`bad status` 限次重初始化 + `ndo_tx_timeout` TX 看门狗（要重编模块 + 重载）；
- 阶梯侧（可选）：既然"成功只要几秒、卡死就是静默"，可以把 `run_bringup` 成功后的
  重试改成"静默即杀 + 立刻重跑"，让每轮成本稳定在 ~45 秒；
- 观察项：为什么有时要连跑 3 次 bring-up 才能成（真实故障里也出现过），
  快照里的 `会话进程 / rpc持有者 / 地址` 三行能帮上忙。

<!-- SPDX-License-Identifier: GPL-2.0-only -->
