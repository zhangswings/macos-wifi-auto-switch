#!/bin/bash
#
# WiFi Auto-Switch
# 基于 locus313/macos-wireless-autoswitch (MIT) 改造：
#   - 当有线网"已连接且网络联通"时，自动关闭 WiFi
#   - 当断开有线网，或有线网不可达时，自动打开 WiFi
# 性能优先：launchd WatchPaths 事件驱动（网络变化才跑，无常驻进程、无高频轮询），
#           辅以 StartInterval 低频复检覆盖"链路在但外网断了"的边界。
#
# 要求：macOS 14+，Bash 4+，以当前用户身份运行（无需 sudo）
# 触发：由 LaunchAgent 自动调用，也可手动 `bash wifi-auto-switch.sh` 测试
#

set -uo pipefail

# ---- 配置 ----
SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME

# 支持的有线网卡类型（按 networkserviceorder 的 Hardware Port 名匹配）
readonly SUPPORTED_ADAPTERS="Ethernet|LAN|Thunderbolt|AX88179A"

# 可达性探测目标（优先国内公共 DNS，按需修改）
readonly REACHABILITY_HOSTS=("223.5.5.5" "119.29.29.29")
readonly PING_TIMEOUT=2
# 判定"关 WiFi"前的重试次数与间隔（应对刚插线 DHCP/路由未就绪）
readonly REACH_ATTEMPTS=2
readonly REACH_RETRY_GAP=2

# 防止 launchd 因 WatchPaths 连续触发而重启过快
readonly LOOP_PREVENTION_DELAY=10

# 设为 1 可只打印决策、不真正开关 WiFi（用于验证逻辑）
DRY_RUN="${DRY_RUN:-0}"

# 全局变量
INTERFACES=""
WIFIINTERFACES=""

#
# 写日志（同时进系统日志）
#
log_message() {
    local message="$1"
    logger "${SCRIPT_NAME}: ${message}" 2>/dev/null
    echo "${SCRIPT_NAME}: ${message}"
}

#
# 获取所有有线网卡设备名（按 hardware port 类型匹配，排除 bridge）
#
get_wired_interfaces() {
    /usr/sbin/networksetup -listnetworkserviceorder 2>/dev/null | \
        grep "Hardware Port" | \
        grep -E "${SUPPORTED_ADAPTERS}" | \
        awk -F ": " '{print $3}' | \
        sed 's/)//g' | \
        grep -v "bridge"
}

#
# 获取所有 WiFi 接口名
#
get_wifi_interfaces() {
    /usr/sbin/networksetup -listallhardwareports 2>/dev/null | \
        awk '/^Hardware Port: Wi-Fi$/{getline; print $2}'
}

#
# 取某接口的可用 IP（排除回环与 169.254 自分配）
# 返回：IP 字符串，无则返回空
#
get_interface_ip() {
    local interface="$1"
    ifconfig "$interface" 2>/dev/null | \
        grep -E 'inet [0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | \
        grep -E -v '127\.0\.0\.1|169\.254\.' | \
        awk 'NR==1{print $2; exit}'
}

#
# 取指定有线网卡的默认网关 IP（用于网关级探测）
#
get_wired_gateway() {
    local interface="$1"
    netstat -rn 2>/dev/null | awk -v i="$interface" '$1=="default" && $NF==i {print $2; exit}'
}

#
# 返回首个"有有效 IP"的有线接口 IP，否则空
#
get_first_wired_ip() {
    [[ -z "$INTERFACES" ]] && return 1
    local interface ip
    while IFS= read -r interface; do
        [[ -z "$interface" ]] && continue
        ip=$(get_interface_ip "$interface")
        if [[ -n "$ip" ]]; then
            echo "$ip"
            return 0
        fi
    done <<< "$INTERFACES"
    return 1
}

#
# 遍历所有有线网卡：任一"有有效 IP 且可达"即视为应关 WiFi
# 输出：首个可达有线网卡的 IP；无则返回空，退出码 1
# （多网卡正确性：避免"第一块不通但第二块通"被误判为无可达有线）
#
wired_any_reachable() {
    [[ -z "$INTERFACES" ]] && return 1
    local interface ip
    while IFS= read -r interface; do
        [[ -z "$interface" ]] && continue
        ip=$(get_interface_ip "$interface")
        [[ -z "$ip" ]] && continue
        if check_reachable "$interface" "$ip"; then
            echo "$ip"
            return 0
        fi
    done <<< "$INTERFACES"
    return 1
}

#
# 通过有线源 IP 探测外网可达性（绑定源地址，确保走有线链路）
# 参数：$1 有线接口 IP；返回 0=可达，1=不可达
#
check_reachable() {
    local iface="$1" src_ip="$2"
    local attempt host gw

    # 网关级预检：网关可达时可快速确认链路，但失败不能直接判定断网。
    # 一些企业网络会过滤 ICMP；最终仍用绑定到有线源 IP 的探测确认。
    gw=$(get_wired_gateway "$iface")
    if [[ -n "$gw" ]] && /sbin/ping -b "$iface" -S "$src_ip" -c 1 -t 2 "$gw" >/dev/null 2>&1; then
        :
    fi

    for ((attempt=1; attempt<=REACH_ATTEMPTS; attempt++)); do
        # 优先：绑定有线源 IP 探测（不走 WiFi 通道，避免误判）
        for host in "${REACHABILITY_HOSTS[@]}"; do
            if /sbin/ping -b "$iface" -S "$src_ip" -c 1 -t "$PING_TIMEOUT" "$host" >/dev/null 2>&1; then
                return 0
            fi
        done
        # 未到最后一次则短暂停顿再确认（应对刚插线 DHCP/路由未就绪）
        [[ $attempt -lt $REACH_ATTEMPTS ]] && sleep "$REACH_RETRY_GAP"
    done

    # 不做不绑定源地址的降级探测：那可能实际走 Wi-Fi，导致误关 Wi-Fi。
    return 1
}

#
# 读取某 WiFi 接口当前电源状态（on/off）
#
get_wifi_power() {
    local iface="$1"
    /usr/sbin/networksetup -getairportpower "$iface" 2>/dev/null | awk '{print tolower($NF)}'
}

#
# 设置 WiFi 电源状态（仅状态变化时才真正执行）
# 参数：$1 期望状态 "on" / "off"
#
set_wifi() {
    local desired="$1" iface cur
    [[ -z "$WIFIINTERFACES" ]] && { log_message "未找到 WiFi 接口，跳过"; return 0; }

    if [[ "$desired" != "on" && "$desired" != "off" ]]; then
        log_message "ERROR: 非法 WiFi 状态 '$desired'"
        return 1
    fi

    while IFS= read -r iface; do
        [[ -z "$iface" ]] && continue
        cur=$(get_wifi_power "$iface")
        if [[ "$cur" == "$desired" ]]; then
            continue
        fi
        if [[ "$DRY_RUN" == "1" ]]; then
            log_message "DRY_RUN: 将 WiFi -> $desired (iface $iface, 当前 $cur)"
            continue
        fi
        if /usr/sbin/networksetup -setairportpower "$iface" "$desired" 2>/dev/null; then
            log_message "WiFi -> $desired (iface $iface)"
        else
            log_message "WARN: 设置 WiFi $desired 失败 (iface $iface)"
        fi
    done <<< "$WIFIINTERFACES"
}

#
# 主逻辑
#
main() {
    INTERFACES=$(get_wired_interfaces) || INTERFACES=""
    WIFIINTERFACES=$(get_wifi_interfaces) || WIFIINTERFACES=""

    local wired_ip probe_ip
    wired_ip=$(wired_any_reachable) || wired_ip=""

    if [[ -n "$wired_ip" ]]; then
        set_wifi "off"
        log_message "决策: 存在可达有线 ($wired_ip) -> WiFi 关"
    else
        set_wifi "on"
        probe_ip=$(get_first_wired_ip) || probe_ip=""
        if [[ -n "$probe_ip" ]]; then
            log_message "决策: 有线在但不可达 ($probe_ip) -> WiFi 开"
        else
            log_message "决策: 无有线连接 -> WiFi 开"
        fi
    fi

    # 防止 launchd 重启循环
    sleep "$LOOP_PREVENTION_DELAY"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        status)
            # 供 GUI 查询：输出 key=value 状态行
            INTERFACES=$(get_wired_interfaces) || INTERFACES=""
            WIFIINTERFACES=$(get_wifi_interfaces) || WIFIINTERFACES=""
            wifi_now=$(get_wifi_power "$(echo "$WIFIINTERFACES" | head -1)")
            wired_iface=""; wired_ip=""; reachable="no"
            while IFS= read -r interface; do
                [[ -z "$interface" ]] && continue
                ip=$(get_interface_ip "$interface")
                if [[ -n "$ip" ]]; then wired_iface="$interface"; wired_ip="$ip"; break; fi
            done <<< "$INTERFACES"
            [[ -n "$wired_ip" ]] && check_reachable "$wired_iface" "$wired_ip" && reachable="yes"
            echo "wifi=${wifi_now:-?}"
            echo "wired_ip=${wired_ip}"
            echo "wired_iface=${wired_iface}"
            echo "reachable=${reachable}"
            echo "wired_ifaces=${INTERFACES}"
            ;;
        on|off)
            # 手动设置 WiFi（供 GUI 按钮）
            WIFIINTERFACES=$(get_wifi_interfaces) || WIFIINTERFACES=""
            set_wifi "$1"
            ;;
        *)
            main "$@"
            ;;
    esac
fi
