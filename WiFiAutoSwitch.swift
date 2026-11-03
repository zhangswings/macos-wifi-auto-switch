import SwiftUI
import AppKit

struct Status {
    var wifi = "?"
    var wiredIp = ""
    var wiredIface = ""
    var reachable = "?"
    var wiredIfaces = ""
    var serviceLoaded = false
}

func shell(_ command: String) -> String {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/bash")
    proc.arguments = ["-c", command]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = pipe
    try? proc.run()
    proc.waitUntilExit()
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
}

func shellStatus(_ command: String) -> Int32 {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/bash")
    proc.arguments = ["-c", command]
    proc.standardOutput = Pipe()
    proc.standardError = Pipe()
    do {
        try proc.run()
        proc.waitUntilExit()
        return proc.terminationStatus
    } catch {
        return -1
    }
}

let SCRIPT = (Bundle.main.url(forResource: "wifi-auto-switch", withExtension: "sh")?.path ?? "")
let AGENT_LABEL = "com.user.wifiautoswitch"
let LOGIN_LABEL = "com.user.wifiautoswitch-login"
let HOME = NSHomeDirectory()
let AGENT_PLIST = (HOME as NSString).appendingPathComponent("Library/LaunchAgents/com.user.wifiautoswitch.plist")
let LOGIN_PLIST = (HOME as NSString).appendingPathComponent("Library/LaunchAgents/com.user.wifiautoswitch-login.plist")
let SCRIPT_DST = (HOME as NSString).appendingPathComponent("Library/Application Support/WiFiAutoSwitch/wifi-auto-switch.sh")
let UID = shell("id -u").trimmingCharacters(in: .whitespacesAndNewlines)

func enableService(watchdog: Bool) -> String {
    let fm = FileManager.default
    let dstDir = (SCRIPT_DST as NSString).deletingLastPathComponent
    do {
        try fm.createDirectory(atPath: dstDir, withIntermediateDirectories: true)
        if fm.fileExists(atPath: SCRIPT_DST) { try fm.removeItem(atPath: SCRIPT_DST) }
        try fm.copyItem(atPath: SCRIPT, toPath: SCRIPT_DST)
    } catch {
        return "安装脚本失败：\(error.localizedDescription)"
    }
    guard let plistSrc = Bundle.main.url(forResource: "com.user.wifiautoswitch", withExtension: "plist") else {
        return "找不到后台配置"
    }
    let plist = NSMutableDictionary(contentsOf: plistSrc) ?? [:]
    plist["ProgramArguments"] = ["/bin/bash", SCRIPT_DST]
    plist["StandardOutPath"] = (HOME as NSString).appendingPathComponent("Library/Logs/wifiautoswitch.log")
    plist["StandardErrorPath"] = (HOME as NSString).appendingPathComponent("Library/Logs/wifiautoswitch.err.log")
    if watchdog {
        plist["StartInterval"] = 120
    } else {
        plist.removeObject(forKey: "StartInterval")
    }
    guard plist.write(to: URL(fileURLWithPath: AGENT_PLIST), atomically: true) else {
        return "写入后台配置失败"
    }
    _ = shellStatus("launchctl bootout gui/\(UID)/\(AGENT_LABEL) >/dev/null 2>&1 || true")
    guard shellStatus("launchctl bootstrap gui/\(UID) \"\(AGENT_PLIST)\"") == 0 else {
        return "启动后台服务失败"
    }
    return "后台服务已启用"
}

func disableService() -> String {
    _ = shellStatus("launchctl bootout gui/\(UID)/\(AGENT_LABEL) >/dev/null 2>&1 || true")
    try? FileManager.default.removeItem(atPath: AGENT_PLIST)
    return "后台服务已停用"
}

func isServiceEnabled() -> Bool {
    guard FileManager.default.fileExists(atPath: AGENT_PLIST) else { return false }
    return shell("launchctl list | grep -c '\(AGENT_LABEL)'").trimmingCharacters(in: .whitespacesAndNewlines) == "1"
}

func setLogin(_ on: Bool) {
    if on {
        let dict: [String: Any] = [
            "Label": LOGIN_LABEL,
            "ProgramArguments": ["/usr/bin/open", "-a", "WiFi 自动切换"],
            "RunAtLoad": true
        ]
        (dict as NSDictionary).write(to: URL(fileURLWithPath: LOGIN_PLIST), atomically: true)
        _ = shell("launchctl bootstrap gui/\(UID) \(LOGIN_PLIST)")
    } else {
        _ = shell("launchctl bootout gui/\(UID)/\(LOGIN_LABEL)")
        try? FileManager.default.removeItem(atPath: LOGIN_PLIST)
    }
}

func isLoginEnabled() -> Bool {
    FileManager.default.fileExists(atPath: LOGIN_PLIST)
}

func readStatus() -> Status {
    var s = Status()
    let out = shell("bash \"\(SCRIPT)\" status 2>/dev/null")
    for line in out.split(separator: "\n") {
        let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { continue }
        let key = parts[0], val = parts[1]
        switch key {
        case "wifi": s.wifi = val
        case "wired_ip": s.wiredIp = val
        case "wired_iface": s.wiredIface = val
        case "reachable": s.reachable = val
        case "wired_ifaces":
            s.wiredIfaces = val.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        default: break
        }
    }
    s.serviceLoaded = isServiceEnabled()
    return s
}

struct ContentView: View {
    @State private var status = Status()
    @State private var msg = ""
    @State private var watchdogOn = true
    @State private var loginOn = false
    @State private var showCloseAlert = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("WiFi 自动切换").font(.headline)
            Text("有线连且通 → 关 WiFi；断线/不通 → 开 WiFi").font(.caption).foregroundStyle(.secondary)

            GroupBox("当前状态") {
                VStack(alignment: .leading, spacing: 5) {
                    row("WiFi", status.wifi)
                    row("有线网卡", status.wiredIfaces.isEmpty ? "无" : status.wiredIfaces)
                    row("有线 IP", status.wiredIp.isEmpty ? "—" : status.wiredIp)
                    row("网络联通", status.reachable)
                    row("后台自动切换", status.serviceLoaded ? "运行中" : "已停用")
                }
            }

            GroupBox("后台自动切换（守护进程）") {
                HStack(spacing: 10) {
                    Button("启用") { doAction { enableService(watchdog: watchdogOn) } }
                    Button("停用") { doAction { disableService() } }
                }
                Toggle("周期复检（断网兜底）", isOn: $watchdogOn)
                    .controlSize(.small)
            }

            GroupBox("手动控制 WiFi（立即生效）") {
                HStack(spacing: 10) {
                    Button("立即开启") { doAction { _ = shell("bash \"\(SCRIPT)\" on"); return "WiFi 已开启" } }
                    Button("立即关闭") {
                        if status.reachable == "yes" {
                            doAction { _ = shell("bash \"\(SCRIPT)\" off"); return "WiFi 已关闭" }
                        } else {
                            showCloseAlert = true
                        }
                    }
                }
                .alert("确认关闭 WiFi？", isPresented: $showCloseAlert) {
                    Button("仍要关闭", role: .destructive) {
                        doAction { _ = shell("bash \"\(SCRIPT)\" off"); return "WiFi 已关闭" }
                    }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("当前没有可达的有线网络，关闭 WiFi 会断开你的网络连接。")
                }
            }

            GroupBox("开机与登录") {
                Toggle("登录时启动本应用", isOn: $loginOn)
                    .controlSize(.small)
                    .onChange(of: loginOn) { _, _ in
                        setLogin(loginOn)
                        msg = loginOn ? "已设登录启动" : "已取消登录启动"
                    }
            }

            HStack(spacing: 10) {
                Button("刷新") { status = readStatus(); msg = "已刷新" }
                Button("查看日志") { _ = shell("open ~/Library/Logs/wifiautoswitch.log") }
                Spacer()
                Button("退出") { NSApplication.shared.terminate(nil) }
            }

            if !msg.isEmpty {
                Text(msg).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(18)
        .frame(width: 360, height: 480)
        .onAppear {
            status = readStatus()
            loginOn = isLoginEnabled()
        }
    }

    func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k)
            Spacer()
            Text(v).foregroundStyle(.secondary)
        }
    }

    func doAction(_ action: @escaping () -> String) {
        msg = "处理中…"
        DispatchQueue.global(qos: .utility).async {
            let result = action()
            let nextStatus = readStatus()
            DispatchQueue.main.async {
                status = nextStatus
                msg = result
            }
        }
    }
}

@main
struct WiFiAutoSwitchApp: App {
    var body: some Scene {
        MenuBarExtra("WiFi 自动切换", systemImage: "wifi") {
            ContentView()
        }
        .menuBarExtraStyle(.window)
    }
}
