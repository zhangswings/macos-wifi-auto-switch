# macOS WiFi 自动切换（菜单栏应用）

> 插上有线网且**网络联通**时自动关闭 WiFi；断开有线，或**有线网络不通**时自动打开 WiFi。
> 主打**零性能负担**：纯事件驱动，无常驻进程、无轮询。附带一个原生菜单栏 GUI，可手动开关并查看状态。

---

## 功能特性

- **自动互斥**：有线连且通 → 关 WiFi；断线 / 不通 → 开 WiFi。
- **可达性判定**：不只看"网卡 up / 有 IP"，而是真正探测外网，且探测**绑定到有线网卡本身**（`ping -S <有线源IP>`），避免"有线没网却误关 WiFi 导致彻底断网"。
- **多网卡**：遍历所有有线网卡，任一可达即关 WiFi。
- **网关级探测**：先 ping 有线网关快速判定，失败即提前报"不通"，省去公网超时等待。
- **插线确认**：2 次 × 2s 重试，避免刚插线 DHCP/路由未就绪时误关。
- **低频复检（watchdog）**：每 120s 一次单 ping，兜底"链路在但外网断了"的场景；可一键关闭变纯事件驱动。
- **零感知开销**：launchd `WatchPaths` 监听网络配置变化才触发，稳态 CPU ≈ 0。
- **菜单栏 GUI**：顶栏 WiFi 图标一键开关、看状态、启用/停用后台守护、登录启动、看日志；手动关 WiFi 带防断网确认。
- **无需 sudo**：以当前用户身份运行，后台守护用用户级 LaunchAgent。

---

## 工作原理

```
网络配置变化 (WatchPaths: /Library/Preferences/SystemConfiguration)
        │
        ▼
wifi-auto-switch.sh
        ├─ 枚举有线网卡 (Ethernet/LAN/Thunderbolt/AX88179A)
        ├─ 取首个"有有效 IP（排除 169.254 自分配）"的网卡
        ├─ 网关预检：ping 有线网关（源 IP 绑定）
        ├─ 公网探测：ping 223.5.5.5 / 119.29.29.29（源 IP 绑定，2 次重试）
        │
        ├─ 有可达有线 ──► networksetup -setairportpower off
        └─ 否则       ──► networksetup -setairportpower on
                          （仅在 WiFi 状态需变化时执行）
```

- **事件驱动**：`WatchPaths` 让 launchd 仅在系统网络配置目录变化时拉起脚本，**平时没有任何进程常驻、不轮询**。
- **watchdog**：`StartInterval 120` 作为补充，覆盖"链路在但外网断"的边界（可在 GUI 关闭）。
- **状态变更才执行**：`set_wifi` 先读当前电源态，仅在不一致时调用 `networksetup`，不刷屏也不空耗。

### 与开源方案的关系

本项目**不是从零造轮子**，而是站在成熟方案肩上的适配：

| 来源 | 角色 | 许可证 |
|---|---|---|
| [locus313/macos-wireless-autoswitch](https://github.com/locus313/macos-wireless-autoswitch) | 脚本核心逻辑基础（事件驱动、WatchPaths、多网卡、IP 校验） | MIT |
| Linux NetworkManager 官方 `70-wifi-wired-exclusive.sh` + CachyOS 论坛 `99-wifi-auto-toggle.sh` | 设计参照（可达性判定、插线确认、watchdog） | — |

**相比原 macos-wireless-autoswitch 的改造点**：

1. **加"网络联通"判定**：原版只看"有有效 IP"。现增加绑定有线源 IP 的 ping 探测（公网 + 网关），仅"连且通"才关 WiFi。
2. **多网卡正确性**：原版取第一块有 IP 的网卡判定；现改为**遍历所有有线网卡，任一可达即关**，避免"第一块不通但第二块通"被误判。
3. **插线后短等待确认**：加 2 次 × 2s 重试，对应 Linux 的"等 10s 确认才关"。
4. **网关级探测**：新增有线网关预检，快速否定判定。
5. **GUI 外壳**：新增原生 SwiftUI 菜单栏应用，把命令行能力变成可点的小软件。
6. **watchdog 可关**：原版固定 120s 复检，现可在 GUI 一键切换为纯事件驱动。
7. **防断网确认**：GUI 的手动关 WiFi，在无可达有线时弹确认框。

> 设计上与 Linux NetworkManager 方案**逻辑完全相通**（同一套互斥心智模型、同一套可达性门槛、同一套事件驱动思路），只是 OS 事件源不同（NM dispatcher vs launchd WatchPaths）。

---

## 系统要求

- macOS 14+（launchd `WatchPaths` 行为与 SwiftUI `MenuBarExtra` 需要）
- 当前登录用户（无需管理员 / sudo）
- 构建 GUI 时才需要 Xcode Command Line Tools（`xcode-select --install`）

---

## 安装

### 方式 A：用自带 GUI（推荐，最简单）

1. 构建并安装应用：`./build.sh --install`（生成 `~/Applications/WiFi 自动切换.app`）。
2. 打开应用（顶栏出现 WiFi 图标）→ 点开面板 → **启用** 后台自动切换。
3. 之后插拔网线即可自动互斥，顶栏随时可手动查看/开关。

### 方式 B：仅用脚本 + 手动 launchctl（不用 GUI）

```bash
# 1. 放好脚本与 plist
mkdir -p ~/Library/Application\ Support/WiFiAutoSwitch
cp wifi-auto-switch.sh ~/Library/Application\ Support/WiFiAutoSwitch/
cp com.user.wifiautoswitch.plist ~/Library/LaunchAgents/

# 2. 让 plist 指向脚本真实路径（如需）
#    sed -i '' 's#/bin/bash#/bin/bash ~/Library/Application\\ Support/WiFiAutoSwitch/wifi-auto-switch.sh#' \
#       ~/Library/LaunchAgents/com.user.wifiautoswitch.plist

# 3. 加载守护进程（用户级，无需 sudo）
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.user.wifiautoswitch.plist
```

> 说明：GUI 应用的"启用"按钮会自动完成上面的复制 + 改写路径 + bootstrap，无需手动。

---

## 构建 GUI 应用

仓库提供 `build.sh` 一键打包；等价于手动执行：

```bash
xcrun swiftc -O -parse-as-library -framework SwiftUI -framework AppKit \
    -o WiFiAutoSwitch WiFiAutoSwitch.swift
# 再把二进制、wifi-auto-switch.sh、com.user.wifiautoswitch.plist 与 Info.plist
# 组装进 WiFi\ 自动切换.app/Contents/{MacOS,Resources}/
```

`build.sh` 会直接生成 `./build/WiFi 自动切换.app`，加 `--install` 额外装到 `~/Applications`。

---

## 使用说明（GUI）

- **顶栏 WiFi 图标**：点击展开控制面板（菜单栏常驻，无 Dock 图标）。
- **当前状态**：WiFi 开关、有线网卡、有线 IP、网络联通、后台守护是否运行。
- **后台自动切换**：`启用` / `停用`（安装/卸载 LaunchAgent 守护进程）。
- **周期复检（断网兜底）**：开关。`关` 时生成的 plist **不带 `StartInterval`**，变为纯事件驱动。
- **手动控制 WiFi**：
  - `立即开启`：永远安全，直接开。
  - `立即关闭`：当**当前有可达有线**时直接关；当**无可达到有线**时弹确认框"关闭会断网"，需二次确认。
- **登录时启动本应用**：开关，写入 `~/Library/LaunchAgents/com.user.wifiautoswitch-login.plist`。
- **查看日志**：打开 `~/Library/Logs/wifiautoswitch.log`（脚本运行记录）。
- **退出**：面板底部按钮。

---

## 配置项

编辑 `wifi-auto-switch.sh` 顶部常量即可：

| 变量 | 默认 | 说明 |
|---|---|---|
| `REACHABILITY_HOSTS` | `("223.5.5.5" "119.29.29.29")` | 可达性探测目标（国内公共 DNS） |
| `PING_TIMEOUT` | `2` | 单次 ping 超时（秒） |
| `REACH_ATTEMPTS` | `2` | 关 WiFi 前重试次数 |
| `REACH_RETRY_GAP` | `2` | 重试间隔（秒） |
| `SUPPORTED_ADAPTERS` | `"Ethernet|LAN|Thunderbolt|AX88179A"` | 视为有线的硬件端口类型 |
| `LOOP_PREVENTION_DELAY` | `10` | 末尾 sleep，防 launchd 重启循环 |

---

## 卸载

在 GUI 中：**停用** 后台守护 + 关闭"登录时启动"，然后拖走 `~/Applications/WiFi 自动切换.app` 即可。

或手动：

```bash
launchctl bootout gui/$(id -u)/com.user.wifiautoswitch
launchctl bootout gui/$(id -u)/com.user.wifiautoswitch-login
rm -f ~/Library/LaunchAgents/com.user.wifiautoswitch.plist \
      ~/Library/LaunchAgents/com.user.wifiautoswitch-login.plist
rm -rf ~/Library/Application\ Support/WiFiAutoSwitch \
       ~/Library/Logs/wifiautoswitch.log \
       ~/Library/Logs/wifiautoswitch.err.log
rm -rf ~/Applications/WiFi\ 自动切换.app
```

---

## 常见问题

**Q：WiFi 和有线会同时开吗？**
A：有可达有线时脚本会把 WiFi 关掉；断线/不通时再开。二者互斥。

**Q：我手动关掉 WiFi 后，会自动重新打开吗？**
A：会——只要没有可达有线（符合"断线/不通 → 开 WiFi"的需求）。若要纯手动控制，先到 GUI 里**停用**后台守护。

**Q：插上来的瞬间 WiFi 没立刻关？**
A：脚本有 2×2s 重试确认，且依赖系统网络配置变化事件触发；插线后通常几秒内完成。

**Q：公司网络禁 ICMP（ping 不通）但能上网，会误判吗？**
A：会。此时请把 `REACHABILITY_HOSTS` 改为一个可达的 TCP 探测目标，或改用 `curl` 探测（见脚本 `check_reachable` 注释扩展）。

**Q：需要 sudo 吗？**
A：不需要，全部以当前用户身份运行。

---

## 许可证与致谢

- 许可证：**MIT**（见 [LICENSE](LICENSE)）。
- 核心逻辑改自 [locus313/macos-wireless-autoswitch](https://github.com/locus313/macos-wireless-autoswitch)（MIT）。
- 设计参照 Linux NetworkManager 官方 `70-wifi-wired-exclusive.sh` 与 CachyOS 论坛 `99-wifi-auto-toggle.sh` 的思路（可达性判定、插线确认、watchdog）。
