import Cocoa
import SwiftUI

let APP  = (NSHomeDirectory() + "/Library/Application Support/Tizi")
let SCRIPT = APP + "/采集.py"
let CHECK  = APP + "/体检.sh"
let DOC = APP + "/出问题怎么办.md"
let LOG = "/tmp/xray-local.log"

// —— 你的服务器信息：全部来自 config.json，源码里不含任何真实地址 ——
let CONF_PATH = APP + "/config.json"
let CONF: [String: Any] = {
    if let d = try? Data(contentsOf: URL(fileURLWithPath: CONF_PATH)),
       let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] { return j }
    return [:]
}()
let HOST: String = (CONF["host"] as? String) ?? "CHANGE_ME"
let SSH_USER: String = (CONF["sshUser"] as? String) ?? "root"
let SPORT: Int = {
    if let n = CONF["sshPort"] as? Int { return n }
    if let t = CONF["sshPort"] as? String, let n = Int(t) { return n }
    return 22
}()

@discardableResult
func sh(_ c: String) -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/bash"); p.arguments = ["-c", c]
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    do { try p.run() } catch { return "" }
    let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}
func shAsync(_ c: String, _ done: @escaping (String) -> Void) {
    DispatchQueue.global().async { let o = sh(c); DispatchQueue.main.async { done(o) } }
}

struct Pt: Identifiable { let id = UUID(); let label: String; let value: Double }
struct Site: Codable, Identifiable { var id: String { h }; var h: String; var n: Int; var last_seen: String }
struct CheckRecord: Codable, Identifiable {
    var id: String { t }
    var t: String
    var rows: [[String]]
}

struct Proc: Codable, Identifiable { var id: String { p }; var p: String; var n: Int }
struct AppTraffic: Codable, Identifiable { var id: String { p }; var p: String; var kb: Double }
struct Route: Codable, Identifiable { var id: String { p }; var p: String; var proxy: Int; var direct: Int; var hosts: [String]? }
struct UsageItem: Codable, Identifiable { var id: String { p }; var p: String; var gb: Double }
struct Snap: Codable {
    var proxy_on: Bool; var xray: Bool; var latency: Int; var loss: Double
    var today: Double; var month: Double; var conns: Int
    var daily: [D]; var hourly: [H]
    var cpu: Double; var mem_used: Int; var mem_total: Int; var disk: Int
    var load: String; var uptime: String
    var ssh_fail: Int; var probes: Int; var banned: Int; var last: String
    var speed_up: Double; var speed_down: Double
    var sites: [Site]
    var procs: [Proc]
    var conn_apps: [Proc]
    var routes: [Route]
    var apps: [AppTraffic]
    var fw_app: String
    var fw_stun: Bool
    struct D: Codable { var d: String; var gb: Double }
    struct H: Codable { var h: String; var gb: Double }
}

// MARK: 颜色
let cBg    = Color(red: 0.038, green: 0.038, blue: 0.046)
let cBg2   = Color(red: 0.082, green: 0.082, blue: 0.098)
let cCard  = Color.white.opacity(0.042)
let cLine  = Color.white.opacity(0.075)
let cText  = Color(red: 0.96, green: 0.96, blue: 0.97)
let cMuted = Color(red: 0.55, green: 0.55, blue: 0.58)
let cGreen = Color(red: 0.24, green: 0.86, blue: 0.52)
let cYellow = Color(red: 1.0, green: 0.78, blue: 0.22)
let cRed   = Color(red: 1.0, green: 0.37, blue: 0.34)
let cBad   = cRed
let cBlue  = Color(red: 0.45, green: 0.78, blue: 1.0)
func lvl(_ v: Double, _ w: Double, _ b: Double) -> Color { v >= b ? cRed : (v >= w ? cYellow : cGreen) }

// MARK: 状态
final class AppState: ObservableObject {
    @Published var on = false
    @Published var xray = false
    @Published var latency = -1
    @Published var loss: Double = 0
    @Published var today: Double = 0
    @Published var month: Double = 0
    @Published var conns = 0
    @Published var cpu: Double = 0
    @Published var disk = 0
    @Published var memUsed = 0
    @Published var memTotal = 0
    @Published var load = "-"
    @Published var uptime = "-"
    @Published var sshFail = 0
    @Published var probes = 0
    @Published var banned = 0
    @Published var lastLog = ""
    @Published var up: Double = 0
    @Published var down: Double = 0
    @Published var daily: [Pt] = []
    @Published var hourly: [Pt] = []
    @Published var sites: [Site] = []
    @Published var procs: [Proc] = []
    @Published var connApps: [Proc] = []
    @Published var routes: [Route] = []
    @Published var usage24: [String: Double] = [:]
    @Published var autoNames: [String: String] = [:]
    @Published var restrictIP = ""      // 非空表示"只允许该 IP 登录"
    @Published var restrictBusy = false   // 进程名 → App 本地化名字（自动）
    @Published var apps: [AppTraffic] = []
    @Published var usage: [UsageItem] = []
    @Published var usageDays = 1
    @Published var fwApp = "-"
    @Published var fwStun = false
    @Published var rules: [String] = []
    @Published var busy = false
    @Published var lastUpdate = "—"
    @Published var detail: String? = nil
    @Published var detailTitle = ""
    @Published var detailText = "加载中…"
    @Published var checkRows: [(String, String, String)] = []
    @Published var checking = false

    @AppStorage("quota") var quota: Double = 1000
    @AppStorage("dailyWarn") var dailyWarn: Double = 10
    @AppStorage("connWarn") var connWarn: Double = 100
    @AppStorage("expire") var expire = ""
    @AppStorage("planGB") var planGB: Double = 1000
    @AppStorage("usedBase") var usedBase: Double = 0      // 装软件前已经用掉的
    @AppStorage("planStart") var planStart = "2026-11-01"
    @AppStorage("planDays") var planDays: Int = 30

    /// 本月真实已用 = 服务器统计 + 你手填的基数
    var monthTotal: Double { month + usedBase }
    /// 到期日（按购买日 + 月数自动算）
    var expireAuto: String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        guard let d = f.date(from: planStart) else { return expire }
        let n = Calendar.current.date(byAdding: .day, value: planDays, to: d) ?? d
        return f.string(from: n)
    }
    @AppStorage("mode") var mode = "smart"

    var expireDays: Int {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        guard let d = f.date(from: expire) else { return -1 }
        return Calendar.current.dateComponents([.day], from: Date(), to: d).day ?? -1
    }
    var speed: Double { max(up, down) }

    struct Issue { let text: String; let kind: String?; let bad: Bool }

    var issues: [Issue] {
        var a: [Issue] = []
        if today > 30 { a.append(.init(text: "今日流量 \(Int(today)) GB，已超红线", kind: "today", bad: true)) }
        else if today > dailyWarn { a.append(.init(text: "今日流量偏高（\(Int(today)) GB）", kind: "today", bad: false)) }
        if month > 500 { a.append(.init(text: "本月流量已超红线", kind: "month", bad: true)) }
        else if month > 200 { a.append(.init(text: "本月流量偏高", kind: "month", bad: false)) }
        if conns > 300 { a.append(.init(text: "连接数 \(conns)，异常偏高", kind: "conns", bad: true)) }
        else if conns > 100 { a.append(.init(text: "连接数偏高（\(conns)）", kind: "conns", bad: false)) }
        if probes > 50 { a.append(.init(text: "今天被探测 \(probes) 次", kind: "probes", bad: probes > 200)) }
        if sshFail > 200 { a.append(.init(text: "SSH 被猜密码 \(sshFail) 次", kind: "sshfail", bad: true)) }
        if cpu > 80 { a.append(.init(text: "服务器 CPU \(Int(cpu))%", kind: "cpu", bad: true)) }
        if disk > 90 { a.append(.init(text: "服务器磁盘 \(disk)%", kind: "disk", bad: true)) }
        if latency > 800 || loss > 5 { a.append(.init(text: "网络质量差（\(latency)ms / \(Int(loss))%丢包）", kind: nil, bad: true)) }
        if expireDays >= 0 && expireDays < 7 { a.append(.init(text: "服务器 \(expireDays) 天后到期", kind: nil, bad: true)) }
        return a
    }
    var score: Int {
        var s = 100.0
        if today > 30 { s -= 15 } else if today > dailyWarn { s -= 7 }
        if month > 500 { s -= 15 } else if month > 200 { s -= 7 }
        if conns > 300 { s -= 10 } else if conns > 100 { s -= 5 }
        if probes > 200 { s -= 20 } else if probes > 50 { s -= 10 } else if probes > 10 { s -= 4 }
        if sshFail > 500 { s -= 10 } else if sshFail > 100 { s -= 5 }
        if cpu > 80 { s -= 5 }
        if disk > 90 { s -= 5 }
        if latency > 800 || loss > 5 { s -= 5 }
        if expireDays >= 0 && expireDays < 7 { s -= 10 }
        return max(0, Int(s.rounded()))
    }
    var scoreColor: Color { score >= 95 ? cGreen : (score >= 80 ? cGreen : (score >= 60 ? cYellow : cRed)) }
    var scoreText: String { score >= 95 ? "状态极佳" : (score >= 80 ? "状态良好" : (score >= 60 ? "有点状况" : "有风险")) }
    var perfect: Bool { score == 100 }

    func refresh(retry: Int = 0) {
        guard !busy else { return }
        busy = true
        shAsync("/usr/bin/python3 '\(SCRIPT)'") { out in
            self.busy = false
            guard let d = out.data(using: .utf8),
                  let s = try? JSONDecoder().decode(Snap.self, from: d),
                  s.today >= 0 else {
                self.busy = false
                if retry < 2 { DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.refresh(retry: retry + 1) } }
                return
            }
            self.on = s.proxy_on; self.xray = s.xray
            self.latency = s.latency; self.loss = s.loss
            self.today = s.today; self.month = s.month; self.conns = s.conns
            self.cpu = s.cpu; self.disk = s.disk; self.memUsed = s.mem_used; self.memTotal = s.mem_total
            self.load = s.load; self.uptime = s.uptime
            self.sshFail = s.ssh_fail; self.probes = s.probes; self.banned = s.banned; self.lastLog = s.last
            self.up = s.speed_up; self.down = s.speed_down
            self.daily = s.daily.map { Pt(label: $0.d, value: $0.gb) }
            self.hourly = s.hourly.map { Pt(label: $0.h, value: $0.gb) }
            self.sites = s.sites
            self.procs = s.procs
            self.connApps = s.conn_apps
            self.routes = s.routes
            self.loadUsage24()
            if self.autoNames.isEmpty { self.loadAppNames() }
            if self.restrictIP.isEmpty { self.loadRestrict() }
            self.apps = s.apps
            self.fwApp = s.fw_app
            self.fwStun = s.fw_stun
            self.loadRules()
            let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
            self.lastUpdate = f.string(from: Date())
        }
    }

    func setMode(_ m: String) {
        mode = m
        shAsync("bash '\(APP)/应用规则.sh' \(m)") { _ in self.refresh() }
    }

    func toggle() {
        let target = on ? "direct" : (mode == "direct" ? "smart" : mode)
        on = (target != "direct")      // 立刻变色，不等脚本
        mode = target
        shAsync("bash '\(APP)/应用规则.sh' \(target)") { _ in self.refresh() }
    }

    @Published var history: [CheckRecord] = []
    @AppStorage("historyDays") var historyDays = 30

    func loadHistory() {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: APP + "/体检历史.json")),
              let arr = try? JSONDecoder().decode([CheckRecord].self, from: d) else { history = []; return }
        history = arr
    }
    func saveCheck(_ rows: [(String, String, String)]) {
        var arr = (try? JSONDecoder().decode([CheckRecord].self,
                  from: (try? Data(contentsOf: URL(fileURLWithPath: APP + "/体检历史.json"))) ?? Data())) ?? []
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"
        arr.insert(CheckRecord(t: f.string(from: Date()), rows: rows.map { [$0.0, $0.1, $0.2] }), at: 0)
        let cutoff = Calendar.current.date(byAdding: .day, value: -historyDays, to: Date()) ?? Date()
        let f2 = DateFormatter(); f2.dateFormat = "yyyy-MM-dd HH:mm"
        arr = arr.filter { r in (f2.date(from: r.t) ?? Date()) >= cutoff }
        history = arr
        if let data = try? JSONEncoder().encode(arr) { try? data.write(to: URL(fileURLWithPath: APP + "/体检历史.json")) }
    }

    func runCheck() {
        guard !checking else { return }
        checking = true; checkRows = []
        shAsync("bash '\(CHECK)'") { out in
            self.checking = false
            self.checkRows = out.split(separator: "\n").compactMap { line in
                let p = line.split(separator: "|", maxSplits: 2).map(String.init)
                return p.count == 3 ? (p[0], p[1], p[2]) : nil
            }
            if !self.checkRows.isEmpty { self.saveCheck(self.checkRows) }
            self.refresh()
        }
    }

    /// 扫描当前运行中的 App，把可执行文件名映射到它在 Finder 里显示的名字（自动，无需手写表）
    func loadAppNames() {
        DispatchQueue.global().async {
            var map: [String: String] = [:]
            let out = sh("lsappinfo list 2>/dev/null | grep 'executable path=' | sed 's/.*executable path=\"//;s/\"$//'")
            for path in out.split(separator: "\n") {
                let p = String(path)
                let base = (p as NSString).lastPathComponent
                guard !base.isEmpty, map[base] == nil else { continue }
                let contents = URL(fileURLWithPath: p).deletingLastPathComponent().deletingLastPathComponent()
                let info = contents.appendingPathComponent("Info.plist").path
                if let dict = NSDictionary(contentsOfFile: info) {
                    let name = (dict["CFBundleDisplayName"] as? String)
                        ?? (dict["CFBundleName"] as? String)
                        ?? base
                    map[base] = name
                }
            }
            DispatchQueue.main.async { self.autoNames = map }
        }
    }

    func loadRestrict() {
        shAsync("bash '\(APP)/限制来源.sh' status") { out in
            let t = out.trimmingCharacters(in: .whitespacesAndNewlines)
            self.restrictIP = t.hasPrefix("on|") ? String(t.dropFirst(3)) : ""
        }
    }

    func setRestrict(_ on: Bool) {
        restrictBusy = true
        shAsync("bash '\(APP)/限制来源.sh' \(on ? "enable" : "disable")") { out in
            self.restrictBusy = false
            self.loadRestrict()
        }
    }

    func updateRestrictIP() { setRestrict(true) }

    func loadUsage24() {
        shAsync("/usr/bin/python3 '\(APP)/流量账本.py' query 1") { out in
            guard let d = out.data(using: .utf8),
                  let arr = try? JSONDecoder().decode([UsageItem].self, from: d) else { return }
            self.usage24 = Dictionary(uniqueKeysWithValues: arr.map { ($0.p, $0.gb) })
        }
    }

    func loadUsage(_ days: Int) {
        usageDays = days
        shAsync("/usr/bin/python3 '\(APP)/流量账本.py' query \(days)") { out in
            guard let d = out.data(using: .utf8),
                  let arr = try? JSONDecoder().decode([UsageItem].self, from: d) else { self.usage = []; return }
            self.usage = arr.filter { $0.gb > 0 }
        }
    }

    func loadRules() {
        let t = (try? String(contentsOfFile: APP + "/规则.txt", encoding: .utf8)) ?? ""
        rules = t.split(separator: "\n").map(String.init).filter { $0.contains("|") }
            .filter { $0.hasPrefix("direct|") || $0.hasPrefix("proxy|") }
    }
    func ruleKind(_ host: String) -> String {
        for r in rules {
            let p = r.split(separator: "|", maxSplits: 1).map(String.init)
            if p.count == 2 && p[1] == host { return p[0] }
        }
        return "smart"
    }
    func setRule(_ host: String, _ kind: String) {
        // 立刻更新界面，不等脚本
        rules = rules.filter { r in
            let p = r.split(separator: "|", maxSplits: 1).map(String.init)
            return !(p.count == 2 && p[1] == host)
        }
        if kind != "smart" { rules.append("\(kind)|\(host)") }
        objectWillChange.send()
        shAsync("bash '\(APP)/加规则.sh' \(kind) '\(host)'") { _ in }
    }
    func directRules() -> [String] {
        rules.filter { $0.hasPrefix("direct|") }.map { String($0.dropFirst(7)) }
    }
    func isDirect(_ host: String) -> Bool {
        for line in rules where line.hasPrefix("direct|") {
            let r = String(line.dropFirst(7))
            if r == host { return true }
            if r.hasPrefix("*.") && host.hasSuffix(String(r.dropFirst(1))) { return true }
            if r.hasSuffix("*") && host.hasPrefix(String(r.dropLast())) { return true }
        }
        return false
    }
    func appName(_ host: String) -> String? {
        let map: [(String, String)] = [
            ("binance", "币安"), ("bnbstatic", "币安"), ("bscdnweb", "币安"), ("bin.bnbstatic", "币安 App"),
            ("okx", "OKX"), ("oklink", "OKX"),
            ("qianwen", "通义千问"), ("aliyun", "阿里云"),
            ("mcs.zijieapi", "抖音"), ("zijieapi", "抖音"), ("doubao", "豆包"), ("bytedance", "抖音"), ("toutiao", "今日头条"),
            ("apple.com", "Apple 服务"), ("icloud", "Apple 服务"),
            ("google", "Google"), ("youtube", "YouTube"), ("github", "GitHub"),
            ("openai", "ChatGPT"), ("telegram", "Telegram"), ("wechat", "微信"),
            ("tencent", "腾讯"), ("qq.com", "腾讯"),
            ("cloudfront", "CDN"), ("akamai", "CDN")
        ]
        let h = host.lowercased()
        for (k, v) in map where h.contains(k) { return v }
        return nil
    }

    func makeDirect(_ host: String) {
        shAsync("bash '\(APP)/加规则.sh' direct '\(host)'") { _ in self.refresh() }
    }

    func reloadRules() { objectWillChange.send() }

    var detailCache: [String: (String, Date)] = [:]

    func fetch(_ kind: String, _ done: @escaping (String) -> Void) {
        if let (t, ts) = detailCache[kind], Date().timeIntervalSince(ts) < 30 {
            done(t); return
        }
        let map: [String: String] = [
            "probes":  "journalctl -u xray --since today --no-pager | grep 'invalid connection' | tail -30",
            "sshfail": "journalctl -u ssh --since today --no-pager | grep 'Failed password' | tail -30",
            "banned":  "fail2ban-client status sshd",
            "last":    "tail -10 /var/log/dsh-logins.log",
            "conns":   "ss -tn state established '( sport = :443 )' | head -40",
            "today":   "vnstat -h | tail -28",
            "month":   "vnstat -d | tail -30",
            "cpu":     "ps aux --sort=-%cpu | head -12",
            "disk":    "du -sh /var/log 2>/dev/null; df -h",
            "fw":      "ufw status verbose",
            "sites":   "tail -120 /var/log/xray/access.log",
            "uptime":  "uptime; systemctl status xray --no-pager | head -12"
        ]
        guard let c = map[kind] else { done("暂无详情"); return }
        shAsync("ssh -o BatchMode=yes -o ConnectTimeout=6 -p \(SPORT) \(SSH_USER)@\(HOST) \"\(c)\"") { t in
            let v = t.isEmpty ? "（没有记录）" : t
            self.detailCache[kind] = (v, Date())
            done(v)
        }
    }

    func openDetail(_ kind: String, _ title: String) {
        detail = kind; detailTitle = title; detailText = "加载中…"
        let map: [String: String] = [
            "probes":  "journalctl -u xray --since today --no-pager | grep 'invalid connection' | tail -30",
            "sshfail": "journalctl -u ssh --since today --no-pager | grep 'Failed password' | tail -30",
            "banned":  "fail2ban-client status sshd",
            "last":    "tail -10 /var/log/dsh-logins.log",
            "conns":   "ss -tn state established '( sport = :443 )' | head -40",
            "today":   "vnstat -h | tail -28",
            "month":   "vnstat -d | tail -30",
            "cpu":     "ps aux --sort=-%cpu | head -12",
            "disk":    "du -sh /var/log 2>/dev/null; df -h",
            "fw":      "ufw status verbose",
            "sites":   "tail -120 /var/log/xray/access.log",
            "uptime":  "uptime; systemctl status xray --no-pager | head -12"
        ]
        guard let c = map[kind] else { detailText = "暂无详情"; return }
        shAsync("ssh -o BatchMode=yes -o ConnectTimeout=6 -p \(SPORT) \(SSH_USER)@\(HOST) \"\(c)\"") { t in
            self.detailText = t.isEmpty ? "（没有记录）" : t
        }
    }
}

// MARK: 组件
struct Card<C: View>: View {
    let c: C
    init(@ViewBuilder _ b: () -> C) { c = b() }
    var body: some View {
        c.padding(15)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 13).fill(cCard))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(cLine, lineWidth: 1))
    }
}
struct Lab: View { let t: String; var body: some View {
    Text(t).font(.system(size: 11, weight: .medium)).foregroundColor(cMuted).tracking(0.4)
} }
struct Bar2: View { let r: Double; let c: Color; var body: some View {
    GeometryReader { g in ZStack(alignment: .leading) {
        RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.09))
        RoundedRectangle(cornerRadius: 3).fill(c).frame(width: max(4, g.size.width * min(1, max(0, r))))
    } }.frame(height: 6)
} }

struct Chart: View {
    let pts: [Pt]; let color: Color
    var kind: Int = 0   // 0=小时 1=天
    var dense: Bool = false
    var showAxis: Bool = true
    @State private var hoverX: CGFloat? = nil

    var body: some View {
        GeometryReader { g in
            let gutter: CGFloat = showAxis ? 42 : 0
            let w = max(10, g.size.width - gutter), h = g.size.height - 14
            let mx = max(0.001, pts.map { $0.value }.max() ?? 1)
            let n = max(1, pts.count - 1)
            let xy = pts.enumerated().map { i, p in
                CGPoint(x: gutter + w * CGFloat(i) / CGFloat(n),
                        y: h - h * CGFloat(min(1, p.value / mx)) * 0.86 + 2)
            }
            ZStack(alignment: .topLeading) {
                if pts.count < 3 {
                    VStack(spacing: 5) {
                        Text("数据还不够").font(.system(size: 12)).foregroundColor(cMuted)
                        Text("用满一天后这里会出现曲线").font(.system(size: 10)).foregroundColor(cMuted.opacity(0.65))
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if xy.count > 1 {
                    // 左侧刻度（不压在曲线上）
                    if showAxis {
                        Text(String(format: "%.2f", mx)).font(.system(size: 8.5))
                            .foregroundColor(cMuted).position(x: gutter / 2, y: 10)
                        Text(String(format: "%.2f", mx / 2)).font(.system(size: 8.5))
                            .foregroundColor(cMuted.opacity(0.75)).position(x: gutter / 2, y: h / 2)
                        Text("0").font(.system(size: 8.5)).foregroundColor(cMuted.opacity(0.6))
                            .position(x: gutter / 2, y: h - 2)
                    }
                    Path { p in
                        p.move(to: CGPoint(x: gutter, y: h)); xy.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: g.size.width, y: h)); p.closeSubpath()
                    }.fill(LinearGradient(colors: [color.opacity(0.30), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    Path { p in p.move(to: xy[0]); xy.dropFirst().forEach { p.addLine(to: $0) } }
                        .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    // 底部时间轴
                    let ticks = dense ? 5 : 3
                    ForEach(0..<ticks, id: \.self) { t in
                        let idx = Int(round(Double(t) * Double(pts.count - 1) / Double(ticks - 1)))
                        let x = gutter + w * CGFloat(t) / CGFloat(ticks - 1)
                        Text(pts[max(0, min(pts.count - 1, idx))].label)
                            .font(.system(size: 8)).foregroundColor(cMuted.opacity(0.7))
                            .position(x: min(max(16, x), g.size.width - 16), y: g.size.height - 3)
                    }
                    if let hx = hoverX {
                        let rel = max(0, min(w, hx - gutter))
                        let idx = min(xy.count - 1, max(0, Int((rel / max(1, w) * CGFloat(xy.count - 1)).rounded())))
                        let pt = xy[idx]
                        Path { p in p.move(to: CGPoint(x: pt.x, y: 0)); p.addLine(to: CGPoint(x: pt.x, y: h)) }
                            .stroke(Color.white.opacity(0.25), style: StrokeStyle(lineWidth: 1))
                        Circle().fill(Color.white).frame(width: 5, height: 5).position(pt)
                        VStack(spacing: 1) {
                            Text(hoverLabel(idx)).font(.system(size: 8.5)).foregroundColor(cMuted)
                            Text(String(format: "%.2f GB", pts[idx].value)).font(.system(size: 10, weight: .semibold)).foregroundColor(cText)
                        }
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.17)))
                        .position(x: min(max(56, hx), g.size.width - 56),
                                  y: max(22, min(h - 22, pt.y - 12)))
                    }
                }
            }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(let p): hoverX = p.x
            case .ended: hoverX = nil
            }
        }
    }

    func hoverLabel(_ i: Int) -> String {
        let raw = pts[i].label
        if kind == 0 {
            if let h = Int(raw) { return String(format: "%02d:00 ~ %02d:00", h, (h + 1) % 24) }
            return raw
        }
        return raw + " 全天"
    }
}

struct FlowPipe: View {
    let active: Bool; let speed: Double
    @State private var t: CGFloat = 0
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05))
                if active {
                    ForEach(0..<3, id: \.self) { i in
                        Circle().fill(i == 1 ? cGreen : Color.white)
                            .frame(width: 6, height: 6)
                            .opacity(0.95 - Double(i) * 0.22)
                            .shadow(color: (i == 1 ? cGreen : .white).opacity(0.9), radius: 5)
                            .offset(x: (g.size.width - 10) * ((t + CGFloat(i) * 0.33).truncatingRemainder(dividingBy: 1)))
                    }
                }
            }
        }
        .frame(height: 12)
        .onAppear {
            withAnimation(.linear(duration: speed > 1 ? 1.1 : 3.2).repeatForever(autoreverses: false)) { t = 1 }
        }
    }
}

struct Sidebar: View {
    @Binding var page: Int
    @Binding var collapsed: Bool
    @State private var hoverIdx = -1
    let items: [(String, String)] = [("◎","总览"),("⛨","安全检查"),("◫","流量"),("◍","服务器"),("≡","分流规则"),("⌘","设置")]
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 9) {
                if !collapsed {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(LinearGradient(colors: [.white, Color(white: 0.6)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 22, height: 22)
                    Text("梯子").font(.system(size: 14, weight: .semibold)).foregroundColor(cText)
                    Spacer(minLength: 0)
                }
                Button(action: { withAnimation(.easeInOut(duration: 0.16)) { collapsed.toggle() } }) {
                    Text(collapsed ? "»" : "«")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(cMuted)
                        .frame(width: 30, height: 30)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
                }.buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, alignment: collapsed ? .center : .leading)
            .padding(.horizontal, collapsed ? 0 : 8)
            .padding(.top, 4).padding(.bottom, 12)

            ForEach(0..<items.count, id: \.self) { i in
                Button(action: { page = i }) {
                    HStack(spacing: 10) {
                        Text(items[i].0).font(.system(size: 14)).frame(width: 20)
                        if !collapsed { Text(items[i].1).font(.system(size: 13.5, weight: page == i ? .semibold : .regular)) }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, collapsed ? 6 : 10)
                    .padding(.vertical, 13)
                    .frame(maxWidth: .infinity, alignment: collapsed ? .center : .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(page == i ? Color.white.opacity(0.10)
                                                : (hoverIdx == i ? Color.white.opacity(0.05) : .clear)))
                    .foregroundColor(page == i ? cText : cMuted)
                    .scaleEffect(hoverIdx == i ? 1.03 : 1, anchor: .leading)
                    .animation(.easeOut(duration: 0.12), value: hoverIdx)
                    .contentShape(Rectangle())
                    .onHover { inside in hoverIdx = inside ? i : (hoverIdx == i ? -1 : hoverIdx) }
                }.buttonStyle(.plain)
            }
            Spacer()
            if !collapsed {
                VStack(alignment: .leading, spacing: 3) {
                    Text("v1.8").font(.system(size: 10)).foregroundColor(cMuted.opacity(0.75))
                    Text(HOST).font(.system(size: 10)).foregroundColor(cMuted.opacity(0.75))
                }.padding(.horizontal, 10)
            }
        }
        .padding(.vertical, 14).padding(.horizontal, 6)
        .frame(width: collapsed ? 64 : 186)
        .background(Color.white.opacity(0.022))
        .onReceive(SwipeBus.shared.$dir) { d in
            if d > 0 { withAnimation(.easeInOut(duration: 0.16)) { collapsed = false } }
            if d < 0 { withAnimation(.easeInOut(duration: 0.16)) { collapsed = true } }
        }
        .gesture(
            DragGesture(minimumDistance: 25)
                .onEnded { v in
                    if v.translation.width < -40 && !collapsed { withAnimation(.easeInOut(duration: 0.16)) { collapsed = true } }
                    if v.translation.width > 40 && collapsed { withAnimation(.easeInOut(duration: 0.16)) { collapsed = false } }
                }
        )
        .overlay(Rectangle().fill(cLine).frame(width: 1), alignment: .trailing)
    }
}

struct Drawer: View {
    @ObservedObject var s: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(s.detailTitle).font(.system(size: 14, weight: .semibold)).foregroundColor(cText)
                Spacer()
                Button(action: { withAnimation(.easeOut(duration: 0.16)) { s.detail = nil } }) {
                    Text("✕").font(.system(size: 13)).foregroundColor(cMuted)
                        .frame(width: 26, height: 26)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.07)))
                }.buttonStyle(.plain)
            }
            Divider().overlay(cLine)
            ScrollView {
                Text(s.detailText)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Color(white: 0.84))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(15)
        .frame(width: 360)
        .background(Color(red: 0.085, green: 0.085, blue: 0.10))
        .overlay(Rectangle().fill(cLine).frame(width: 1), alignment: .leading)
    }
}

// MARK: 总览
struct Overview: View {
    @ObservedObject var s: AppState
    @State private var mode = 0
    @State private var sortMode = 0
    @State private var showServerMenu = false
    @State private var pendingAction: String? = nil

    var body: some View {
        VStack(spacing: 12) {
            topbar
            HStack(spacing: 12) {
                scoreCard.frame(maxWidth: .infinity)
                chartCard.frame(maxWidth: .infinity)
            }.frame(height: 198)
            HStack(spacing: 12) {
                securityCard
                serverCard
                watchCard
            }.frame(height: 226)
            HStack(spacing: 12) {
                proxySitesCard
                directCard
            }.frame(height: 236)
            Spacer(minLength: 0)
        }
        .alert("确定要执行吗？", isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } })) {
                Button("取消", role: .cancel) { pendingAction = nil }
                Button("确定", role: .destructive) {
                    if let a = pendingAction {
                        _ = sh("ssh -o BatchMode=yes -o ConnectTimeout=6 -p \(SPORT) \(SSH_USER)@\(HOST) '\(a)' >/dev/null 2>&1 &")
                    }
                    pendingAction = nil
                }
            } message: {
                Text(pendingAction == "reboot" ? "服务器会重启，约 1 分钟恢复" : "服务器会关机，需要到面板手动开机")
            }
    }

    var topbar: some View {
        HStack(spacing: 9) {
            Circle().fill(s.on ? (s.xray ? cGreen : cRed) : cMuted)
                .frame(width: 9, height: 9)
                .shadow(color: (s.on ? cGreen : cMuted).opacity(0.9), radius: 5)
            Text(s.on ? "已连接 · 洛杉矶" : "未连接 · 直连")
                .font(.system(size: 14.5, weight: .semibold)).foregroundColor(cText)
            pillClickable("节点", "NovixLink-Reality", s.on ? cGreen : cMuted)

            pillClickable("本月已用", String(format: "%.2f / %d GB", s.monthTotal, Int(s.quota)), s.month > s.quota * 0.8 ? cRed : cText)
            pill("到期", s.expireDays < 0 ? "未设置" : "还剩 \(s.expireDays) 天", s.expireDays <= 7 ? cRed : cMuted)


            Spacer()
            modeGroup
            Button(action: { s.refresh() }) {
                HStack(spacing: 4) {
                    Text(s.busy ? "⟳" : "↻").font(.system(size: 11))
                    Text(s.lastUpdate).font(.system(size: 10))
                }
                .foregroundColor(s.busy ? cGreen : cMuted)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05)))
            }.buttonStyle(.plain).padding(.leading, 4)
        }
    }
    @State private var expandedPill: String? = nil

    func pillClickable(_ k: String, _ v: String, _ c: Color) -> some View {
        pill(k, v, c)
            .onTapGesture { expandedPill = (expandedPill == k) ? nil : k }
            .popover(isPresented: Binding(get: { expandedPill == k }, set: { if !$0 { expandedPill = nil } })) {
                Text(v).font(.system(size: 12)).padding(10)
            }
    }

    func pill(_ k: String, _ v: String, _ c: Color) -> some View {
        HStack(spacing: 4) {
            Text(k).foregroundColor(cMuted)
            Text(v).foregroundColor(c).bold()
        }
        .font(.system(size: 11))
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Capsule().fill(Color.white.opacity(0.055)))
        .overlay(Capsule().stroke(cLine, lineWidth: 1))
    }
    var isCustom: Bool { !s.rules.isEmpty }

    var modeGroup: some View {
        HStack(spacing: 0) {
            mchip("智能", "smart")
            Rectangle().fill(cLine).frame(width: 1, height: 14)
            mchip("全局", "global")
            Rectangle().fill(cLine).frame(width: 1, height: 14)
            mchip("直连", "direct")
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.055)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(cLine, lineWidth: 1))
    }
    func mchip(_ t: String, _ key: String) -> some View {
        let active = (key == "custom") ? false : (s.mode == key)
        return Button(action: { if key != "custom" { s.setMode(key) } }) {
            Text(t).font(.system(size: 10, weight: active ? .semibold : .regular))
                .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6).fill(active ? Color.white.opacity(0.16) : .clear))
                .foregroundColor(active ? cText : cMuted)
        }.buttonStyle(.plain)
    }

    var scoreCard: some View {
        Card {
            HStack(spacing: 18) {
                ZStack {
                    Circle().stroke(Color.white.opacity(0.07), lineWidth: 8)
                    Circle().trim(from: 0, to: CGFloat(s.score) / 100)
                        .stroke(s.scoreColor, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 3) {
                        Text("\(s.score)").font(.system(size: 38, weight: .bold)).foregroundColor(cText)
                        Text("安全分").font(.system(size: 10)).foregroundColor(cMuted)
                    }
                }.frame(width: 118, height: 118)

                VStack(alignment: .leading, spacing: 7) {
                    Text(s.scoreText).font(.system(size: 17, weight: .bold)).foregroundColor(s.scoreColor)
                    if s.perfect {
                        Text("满分！继续保持 👍").font(.system(size: 12)).foregroundColor(cGreen)
                        Text("今天的用量、连接数、安全状态全都在安全线内。").font(.system(size: 10.5)).foregroundColor(cMuted)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(0..<min(3, s.issues.count), id: \.self) { i in
                                IssueRow(issue: s.issues[i], s: s)
                            }
                        }
                    }
                    Spacer(minLength: 2)
                    Button(action: { s.toggle() }) {
                        HStack(spacing: 6) {
                            Text(s.on ? "⏻" : "▶").font(.system(size: 13))
                            Text(s.on ? "断开连接" : "立即连接").font(.system(size: 13, weight: .bold))
                        }
                        .frame(maxWidth: .infinity).frame(height: 38)
                        .background(RoundedRectangle(cornerRadius: 9).fill(s.on ? cGreen : cBlue))
                        .foregroundColor(s.on ? Color(red: 0.02, green: 0.12, blue: 0.05) : Color(red: 0.02, green: 0.10, blue: 0.17))
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    var chartCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Lab(t: mode == 0 ? "最近 24 小时" : "最近 7 天")
                    Spacer()
                    seg("24时", 0); seg("7天", 1)
                }
                Chart(pts: mode == 0 ? s.hourly : s.daily,
                      color: s.on ? cGreen.opacity(0.95) : cText.opacity(0.85),
                      kind: mode == 0 ? 0 : 1, dense: false)
                    .frame(height: 92)
                FlowPipe(active: s.on && s.xray, speed: s.speed)
                HStack(spacing: 16) {
                    kpi(String(format: "%.2f", s.today), "今日 GB")
                    kpi(fmtSpeed(s.up, "↑"), "上传", color: cGreen)
                    kpi(fmtSpeed(s.down, "↓"), "下载", color: cBlue)
                    kpi(s.latency > 0 ? "\(s.latency)" : "—", "延迟 ms")
                }
            }
        }
    }
    func fmtSpeed(_ mbps: Double, _ arrow: String) -> String {
        let kbs = mbps * 125
        return kbs >= 1024 ? String(format: "%@%.1f MB/s", arrow, kbs / 1024)
                           : String(format: "%@%.0f KB/s", arrow, kbs)
    }

    func kpi(_ v: String, _ t: String, color: Color = cText) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(v).font(.system(size: 16, weight: .bold)).foregroundColor(color)
            Text(t).font(.system(size: 9)).foregroundColor(cMuted)
        }
    }
    func seg(_ t: String, _ i: Int) -> some View {
        Text(t).font(.system(size: 10.5))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(mode == i ? Color.white.opacity(0.15) : .clear))
            .foregroundColor(mode == i ? cText : cMuted)
            .onTapGesture { mode = i }
    }

    let rowH: CGFloat = 34

    var securityCard: some View {
        Card {
            VStack(spacing: 0) {
                HStack { Lab(t: "安全"); Spacer(); Text("点一行看详情").font(.system(size: 9.5)).foregroundColor(cMuted.opacity(0.7)) }
                    .frame(height: 20)
                Spacer(minLength: 0)
                VStack(spacing: 0) {
                    DetailRow(label: "陌生探测", value: "\(s.probes) 次", kind: "probes", color: s.probes > 50 ? cRed : cText, s: s)
                    DetailRow(label: "SSH 爆破", value: "\(s.sshFail) 次", kind: "sshfail", color: s.sshFail > 200 ? cYellow : cText, s: s)
                    DetailRow(label: "已封禁 IP", value: "\(s.banned) 个", kind: "banned", color: cText, s: s)
                    DetailRow(label: "防火墙", value: "3 道全开 ✓", kind: "fw", color: cGreen, s: s)
                    DetailRow(label: "最近登录", value: s.lastLog.isEmpty ? "还没有记录" : s.lastLog, kind: "last", color: cText, s: s)
                }
                Spacer(minLength: 0)
            }
        }
    }

    var serverCard: some View {
        Card {
            VStack(spacing: 0) {
                HStack(spacing: 2) {
                    Text("服务器").font(.system(size: 11, weight: .medium)).foregroundColor(cMuted)
                    Button(action: { showServerMenu.toggle() }) {
                        HStack(spacing: 2) {
                            Text("（" + (s.xray ? "运行中" : "离线") + "）").font(.system(size: 11, weight: .semibold))
                                .foregroundColor(s.xray ? cGreen : cRed)
                            Text("▾").font(.system(size: 8)).foregroundColor(cMuted)
                        }
                    }.buttonStyle(.plain)
                    .popover(isPresented: $showServerMenu) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("服务器操作").font(.system(size: 12, weight: .semibold))
                            Divider()
                            Button("🔄 重启服务器") { showServerMenu = false; pendingAction = "reboot" }
                            Button("⏻ 关机") { showServerMenu = false; pendingAction = "poweroff" }
                            Button("▶ 开机（需到面板）") { showServerMenu = false }
                        }.padding(12).frame(width: 170)
                    }
                    Spacer()
                    Text(s.uptime).font(.system(size: 9.5)).foregroundColor(cMuted.opacity(0.7))
                }.frame(height: 20)
                Spacer(minLength: 0)
                VStack(spacing: 0) {
                    DetailRow(label: "CPU", value: String(format: "%.1f%%", s.cpu), kind: "cpu", color: s.cpu > 80 ? cRed : cText, s: s)
                    DetailRow(label: "内存", value: "\(s.memUsed)/\(s.memTotal) MB", kind: nil, color: cText, s: s)
                    DetailRow(label: "磁盘", value: "\(s.disk)%", kind: "disk", color: s.disk > 90 ? cRed : cText, s: s)
                    DetailRow(label: "负载", value: s.load, kind: nil, color: cText, s: s)
                    DetailRow(label: "连接", value: "\(s.conns) 条", kind: "conns", color: cText, s: s)
                }
                Spacer(minLength: 0)
            }
        }
    }

    var watchCard: some View {
        Card {
            VStack(spacing: 0) {
                HStack { Lab(t: "重点观察"); Spacer(); Text("红线").font(.system(size: 9.5)).foregroundColor(cMuted.opacity(0.7)) }
                    .frame(height: 20)
                Spacer(minLength: 0)
                watchRow("今日流量", String(format: "%.2f / %d GB", s.today, Int(s.dailyWarn)), s.today / (s.dailyWarn * 3), "today")
                watchRow("连接数", "\(s.conns) / \(Int(s.connWarn * 3))", Double(s.conns) / (s.connWarn * 3), "conns")
                watchRow("本月流量", String(format: "%.1f / %d GB", s.monthTotal, Int(s.quota)), s.monthTotal / max(1, s.quota), "month")
                watchRow("实时速度", String(format: "%.1f Mbps", s.speed), min(1, s.speed / 50), nil)
                watchRow("延迟/丢包", String(format: "%d ms · %.0f%%", s.latency, s.loss), min(1, Double(max(0, s.latency)) / 800), nil)
                Spacer(minLength: 0)
            }
        }
    }

    func watchRow(_ k: String, _ v: String, _ r: Double, _ click: String?) -> some View {
        VStack(spacing: 3) {
            DetailRow(label: k, value: v, kind: click, color: cText, s: s)
            Bar2(r: r, c: lvl(r, 0.34, 0.67))
        }
        .frame(height: rowH)
    }

    struct AppRow: Identifiable { var id: String { p }; let p: String; let kb: Double; let conns: Int; let gb: Double }

    var sortPicker: some View {
        HStack(spacing: 0) {
            sortBtn("连接", 1); sortBtn("流量", 2)
        }
        .padding(1)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.06)))
    }
    func sortBtn(_ t: String, _ i: Int) -> some View {
        Button(action: { sortMode = i }) {
            Text(t).font(.system(size: 9, weight: sortMode == i ? .semibold : .regular))
                .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5).fill(sortMode == i ? Color.white.opacity(0.18) : .clear))
                .foregroundColor(sortMode == i ? cText : cMuted)
        }.buttonStyle(.plain)
    }

    var whitelistedSites: [Site] {
        s.sites.filter { st in
            s.rules.contains { line in
                line.hasPrefix("proxy|") && {
                    let h = String(line.dropFirst(6))
                    if h.hasPrefix("*.") { return st.h.hasSuffix(String(h.dropFirst(1))) }
                    return st.h == h || st.h.hasSuffix("." + h)
                }()
            }
        }.sorted { $0.n > $1.n }
    }

    var speedMap: [String: Double] {
        Dictionary(uniqueKeysWithValues: s.apps.map { ($0.p, $0.kb) })
    }

    var proxyApps: [AppRow] {
        let sp = speedMap
        return s.routes.filter { $0.proxy > 0 }
            .map { AppRow(p: $0.p, kb: sp[$0.p] ?? 0, conns: $0.proxy, gb: s.usage24[$0.p] ?? 0) }
            .sorted { sortMode == 2 ? $0.gb > $1.gb : $0.conns > $1.conns }
    }

    var directApps: [AppRow] {
        let sp = speedMap
        return s.routes.filter { $0.direct > 0 && isUserApp($0.p) }
            .map { AppRow(p: $0.p, kb: sp[$0.p] ?? 0, conns: $0.direct, gb: s.usage24[$0.p] ?? 0) }
            .sorted { sortMode == 2 ? $0.gb > $1.gb : $0.conns > $1.conns }
    }

    var proxySitesCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Lab(t: "经过系统代理的程序")
                    sortPicker
                    Spacer()
                    Text("\(proxyApps.count) 个").font(.system(size: 9.5)).foregroundColor(cMuted.opacity(0.8))
                }
                if proxyApps.isEmpty {
                    Text("现在没有程序在使用系统代理").font(.system(size: 11)).foregroundColor(cMuted)
                } else {
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(spacing: 5) {
                            ForEach(proxyApps) { a in
                                appRow(a, tint: cGreen, tag: "代理", extra: fmtStat(a),
                                       suffix: siteSuffix(a.p))
                            }
                        }
                    }
                }
                Text("注：只有白名单域名会真的去洛杉矶；白名单外由 Xray 判定为直连，不占服务器流量").font(.system(size: 9)).foregroundColor(cMuted.opacity(0.6))
                Spacer(minLength: 0)
            }
        }
    }

    var directCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Lab(t: "完全没经过代理的程序")
                    sortPicker
                    Spacer()
                    Text("\(directApps.count) 个").font(.system(size: 9.5)).foregroundColor(cMuted.opacity(0.8))
                }
                if directApps.isEmpty {
                    Text("暂时没发现（都经过代理了，或没有流量）").font(.system(size: 11)).foregroundColor(cMuted)
                } else {
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(spacing: 5) {
                            ForEach(directApps) { a in
                                appRow(a, tint: cBlue, tag: "直连",
                                       extra: fmtStat(a))
                            }
                        }
                    }
                }
                Text("这些程序不经过系统代理（自己实现网络层，或没设代理）").font(.system(size: 9)).foregroundColor(cMuted.opacity(0.6))
                Spacer(minLength: 0)
            }
        }
    }

    /// 右面板只显示"用户级 App"：排除浏览器、系统后台、系统组件
    func isUserApp(_ p: String) -> Bool {
        let low = p.lowercased()
        let ban = ["safari", "chrome", "webkit", "firefox", "edge", "webcontent", "networking",
                   "com.apple", "rapportd", "mdnsresponder", "apsd", "controlcenter", "sharingd",
                   "cloudd", "bird", "nsurlsessiond", "trustd", "syspolicyd", "xray", "ssh", "python3",
                   "amplibraryagent", "weathermenu", "agent", "daemon", "service"]
        return !ban.contains { low.contains($0) }
    }

    func siteSuffix(_ p: String) -> String {
        guard let hs = s.routes.first(where: { $0.p == p })?.hosts, !hs.isEmpty else { return "" }
        let names = Array(Set(hs.map { prettyHost($0) })).sorted()
        return names.prefix(2).joined(separator: " / ")
    }

    func fmtStat(_ a: AppRow) -> String {
        let vol = a.gb >= 1 ? String(format: "%.2f GB", a.gb) : String(format: "%.0f MB", a.gb * 1024)
        return String(format: "%d 次 · %.0f KB/s · %@", a.conns, a.kb, vol)
    }

    func prettyName(_ p: String) -> String {
        var n = p
        if let auto = s.autoNames[n] { return auto }
        // 系统网页进程 → Safari
        if n.contains("com.apple.WebKit") || n.contains("com.apple.Safari") { return "Safari" }
        if n.hasPrefix("com.apple.") { return "系统服务" }
        // 各种 Helper 合并回主程序
        for cut in [" Helper", " for Testing Helpe", "-Helper"] {
            if let r = n.range(of: cut) { n = String(n[..<r.lowerBound]) }
        }
        if n.contains("Google Chrome") { return "Chrome" }
        if n.contains("DeepSeek") { return "DeepSeek（我）" }
        if n.contains("Edge") { return "Edge" }
        if n.contains("Firefox") { return "Firefox" }
        if n.contains("TradingView") || n.hasPrefix("TradingVi") { return "TradingView" }
        if n.contains("AiCoin") || n.hasPrefix("AiCoin") { return "AiCoin" }
        let cn: [String: String] = [
            "Qianwen": "千问", "Doubao": "豆包", "WeChat": "微信", "Weixin": "微信",
            "Telegram": "Telegram", "Spotify": "Spotify", "Steam": "Steam",
            "Adobe Desktop Service": "Adobe", "node": "Node 开发工具", "adb": "adb（手机调试）"
        ]
        if let v = cn[n] { return v }
        switch n {
        case "python3": return "梯子（后台采集）"
        case "ssh": return "梯子（连服务器）"
        case "curl": return "curl（命令行）"
        case "": return "未知程序"
        default: return n
        }
    }

    /// 把一长串域名变成看得懂的名字
    func prettyHost(_ h: String) -> String {
        let low = h.lowercased()
        let brands: [(String, String)] = [
            ("youtube", "YouTube"), ("googlevideo", "YouTube 视频流"), ("ytimg", "YouTube 图片"),
            ("googleusercontent", "Google 账号"), ("googleapis", "Google 接口"), ("gstatic", "Google 静态"),
            ("google", "Google"),
            ("twimg", "X 图片"), ("twitter", "X（推特）"), ("x.com", "X（推特）"),
            ("binance", "币安"), ("bnbstatic", "币安图片"), ("okx", "OKX"),
            ("tradingview", "TradingView"), ("aicoin", "AiCoin"),
            ("apple", "Apple"), ("icloud", "iCloud"),
            ("qq.com", "腾讯"), ("weixin", "微信"), ("douyin", "抖音"), ("zijieapi", "抖音"),
            ("doubao", "豆包"), ("qianwen", "通义千问")
        ]
        for (k, v) in brands where low.contains(k) { return v }
        // 兜底：取最后两段（example.com）
        let parts = low.split(separator: ".")
        if parts.count >= 2 { return parts.suffix(2).joined(separator: ".") }
        return h
    }

    func appRow(_ a: AppRow, tint: Color, tag: String, extra: String, suffix: String? = nil) -> some View {
        HStack(spacing: 8) {
            Circle().fill(tint).frame(width: 6, height: 6)
            HStack(spacing: 0) {
                Text(prettyName(a.p)).font(.system(size: 11.5)).foregroundColor(cText).lineLimit(1)
                if let sfx = suffix, !sfx.isEmpty {
                    Text(" · " + sfx).font(.system(size: 11.5)).foregroundColor(cBlue.opacity(0.95)).lineLimit(1)
                }
            }
            Spacer()
            Text(extra).font(.system(size: 9.5)).foregroundColor(cMuted)
            Text(tag).font(.system(size: 8.5, weight: .semibold))
                .padding(.horizontal, 5).padding(.vertical, 1.5)
                .background(Capsule().fill(tint.opacity(0.18))).foregroundColor(tint)
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.03)))
    }

    
    var sortedRules: [String] {
        let list = s.directRules()
        func used(_ r: String) -> Int {
            let pat = r.replacingOccurrences(of: "*.", with: "")
            return s.sites.filter { $0.h.hasSuffix(pat) }.map { $0.n }.reduce(0, +)
        }
        switch sortMode {
        case 0: return list.sorted { used($0) > used($1) }
        case 1: return list.sorted { used($0) > used($1) }
        default: return list.sorted()
        }
    }
}

struct IssueRow: View {
    let issue: AppState.Issue
    @ObservedObject var s: AppState
    @State private var show = false
    @State private var text = "加载中…"
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(issue.bad ? cRed : cYellow).frame(width: 5, height: 5)
            Text(issue.text).font(.system(size: 11)).foregroundColor(issue.bad ? cRed : cYellow)
            if issue.kind != nil { Text("›").font(.system(size: 11)).foregroundColor(cMuted) }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard let k = issue.kind else { return }
            text = "加载中…"; show = true
            s.fetch(k) { t in text = t }
        }
        .popover(isPresented: $show) {
            VStack(alignment: .leading, spacing: 6) {
                Text(issue.text).font(.system(size: 12, weight: .semibold))
                Divider()
                ScrollView {
                    Text(text).font(.system(size: 9.5, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(12).frame(width: 400, height: 260)
        }
    }
}

struct DetailButton: View {
    let label: String
    let kind: String
    @ObservedObject var s: AppState
    @State private var show = false
    @State private var text = "加载中…"
    var body: some View {
        Button(action: { text = "加载中…"; show = true; s.fetch(kind) { text = $0 } }) {
            Text("详情 ›").font(.system(size: 10)).foregroundColor(cBlue)
        }.buttonStyle(.plain)
        .popover(isPresented: $show) {
            VStack(alignment: .leading, spacing: 6) {
                Text(label).font(.system(size: 12, weight: .semibold))
                Divider()
                ScrollView {
                    Text(text).font(.system(size: 9.5, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(12).frame(width: 400, height: 260)
        }
    }
}

// MARK: 点击处弹小框的行
struct DetailRow: View {
    let label: String
    let value: String
    let kind: String?
    let color: Color
    @ObservedObject var s: AppState
    var rowHeight: CGFloat = 34
    @State private var show = false
    @State private var text = "加载中…"

    var body: some View {
        HStack {
            Text(label).font(.system(size: 12)).foregroundColor(cMuted)
            Spacer()
            Text(value + (kind == nil ? "" : " ›")).font(.system(size: 12.5, weight: .medium)).foregroundColor(color)
        }
        .frame(height: rowHeight)
        .contentShape(Rectangle())
        .onTapGesture {
            guard kind != nil else { return }
            text = "加载中…"; show = true
            s.fetch(kind!) { t in text = t }
        }
        .popover(isPresented: $show) {
            VStack(alignment: .leading, spacing: 6) {
                Text(label).font(.system(size: 12, weight: .semibold))
                Divider()
                ScrollView {
                    Text(text).font(.system(size: 9.5, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(12).frame(width: 420, height: 280)
        }
    }
}

struct HistoryRow: View {
    let rec: CheckRecord
    @State private var show = false
    var body: some View {
        HStack(spacing: 8) {
            Text(rec.t).font(.system(size: 10.5)).foregroundColor(cText)
            Spacer()
            let ok = rec.rows.filter { $0[0] == "OK" }.count
            let warn = rec.rows.filter { $0[0] == "WARN" }.count
            let bad = rec.rows.filter { $0[0] == "BAD" }.count
            Text("✅\(ok)").font(.system(size: 9.5)).foregroundColor(cGreen)
            Text("⚠️\(warn)").font(.system(size: 9.5)).foregroundColor(cYellow)
            Text("❌\(bad)").font(.system(size: 9.5)).foregroundColor(cBad)
            Text("查看 ›").font(.system(size: 9.5)).foregroundColor(cBlue)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.03)))
        .contentShape(Rectangle())
        .onTapGesture { show = true }
        .popover(isPresented: $show) {
            VStack(alignment: .leading, spacing: 6) {
                Text("体检结果 · \(rec.t)").font(.system(size: 12, weight: .semibold))
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(rec.rows.enumerated()), id: \.offset) { _, r in
                            HStack(alignment: .top, spacing: 6) {
                                Text(r[0] == "OK" ? "✅" : (r[0] == "WARN" ? "⚠️" : "❌")).font(.system(size: 11))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(r[1]).font(.system(size: 11.5, weight: .medium)).foregroundColor(cText)
                                    Text(r[2]).font(.system(size: 10.5)).foregroundColor(Color(white: 0.78))
                                }
                                Spacer()
                            }
                        }
                    }
                }
            }
            .padding(14)
            .frame(width: 620, height: 420)
            .background(Color(red: 0.10, green: 0.10, blue: 0.12))
            .preferredColorScheme(.dark)
        }
    }
}

// MARK: 共用行
struct SiteRow: View {
    let app: String?
    let host: String
    let count: Int
    let eff: String        // "代理" / "直连"
    let kind: String       // smart/proxy/direct
    let onSet: (String) -> Void
    let onOpen: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            if let a = app {
                Text(a).font(.system(size: 9.5, weight: .semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(cBlue.opacity(0.18))).foregroundColor(cBlue)
            }
            Text(host).font(.system(size: 11.5)).foregroundColor(cText)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            Text("\(count) 次").font(.system(size: 9.5)).foregroundColor(cMuted)
            Text(eff).font(.system(size: 8.5, weight: .semibold))
                .padding(.horizontal, 5).padding(.vertical, 1.5)
                .background(Capsule().fill((eff == "直连" ? cGreen : cBlue).opacity(0.18)))
                .foregroundColor(eff == "直连" ? cGreen : cBlue)
            triSwitch
        }
        .padding(.horizontal, 8).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(hover ? Color.white.opacity(0.075) : Color.white.opacity(0.028)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(hover ? cLine : Color.clear, lineWidth: 1))
        .scaleEffect(hover ? 1.012 : 1)
        .animation(.easeOut(duration: 0.12), value: hover)
        .onHover { hover = $0 }
        .onTapGesture { onOpen() }
    }

    var triSwitch: some View {
        HStack(spacing: 0) {
            b("智能", "smart"); b("代理", "proxy"); b("直连", "direct")
        }
        .padding(1)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.06)))
    }
    func b(_ t: String, _ key: String) -> some View {
        Button(action: { onSet(key) }) {
            Text(t).font(.system(size: 9, weight: kind == key ? .semibold : .regular))
                .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 6).padding(.vertical, 2.5)
                .background(RoundedRectangle(cornerRadius: 5).fill(kind == key ? Color.white.opacity(0.18) : .clear))
                .foregroundColor(kind == key ? cText : cMuted)
        }.buttonStyle(.plain)
    }
}

// MARK: 安全检查页
struct SecurityPage: View {
    @ObservedObject var s: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("安全检查").font(.system(size: 17, weight: .semibold)).foregroundColor(cText)
                Spacer()
                Button(action: { s.runCheck() }) {
                    HStack(spacing: 6) {
                        Text(s.checking ? "⏳" : "🩺")
                        Text(s.checking ? "正在体检…" : "一键体检").font(.system(size: 12.5, weight: .semibold))
                    }
                    .padding(.horizontal, 16).frame(height: 34)
                    .background(RoundedRectangle(cornerRadius: 9).fill(cGreen))
                    .foregroundColor(Color(red: 0.02, green: 0.12, blue: 0.05))
                }.buttonStyle(.plain)
            }
            .onAppear { s.fetch("probes") { _ in }; s.fetch("sshfail") { _ in } }
            if s.checkRows.isEmpty {
                Card {
                    VStack(spacing: 10) {
                        Text("点右上角「一键体检」，我会逐项检查 17 个点位").font(.system(size: 12)).foregroundColor(cMuted)
                        Text("包括：本机内核、系统代理、隧道出口、国内直连、服务器服务、443 端口、防火墙、SSH 密码登录、防暴破、伪装验证、磁盘、内存、今日流量、探测次数、到期时间、WebRTC 防护、配置备份")
                            .font(.system(size: 10.5)).foregroundColor(cMuted.opacity(0.7))
                            .multilineTextAlignment(.center).lineSpacing(3)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                Card {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(0..<s.checkRows.count, id: \.self) { i in
                                let r = s.checkRows[i]
                                HStack(alignment: .top, spacing: 9) {
                                    Text(r.0 == "OK" ? "✅" : (r.0 == "WARN" ? "⚠️" : "❌")).font(.system(size: 12))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(r.1).font(.system(size: 12, weight: .medium)).foregroundColor(cText)
                                        Text(r.2).font(.system(size: 10.5)).foregroundColor(cMuted)
                                    }
                                    Spacer()
                                }
                                .padding(.vertical, 6)
                                Divider().overlay(cLine.opacity(0.5))
                            }
                        }
                    }
                }
            }
            if !s.history.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Lab(t: "历史体检（最近 \(s.historyDays) 天）")
                            Spacer()
                            Text("共 \(s.history.count) 次").font(.system(size: 9.5)).foregroundColor(cMuted.opacity(0.8))
                        }
                        ScrollView(.vertical, showsIndicators: true) {
                            VStack(spacing: 4) {
                                ForEach(s.history) { rec in
                                    HistoryRow(rec: rec)
                                }
                            }
                        }.frame(maxHeight: 90)
                    }
                }.frame(height: 130)
            }
            HStack(spacing: 12) {
                quickCard("本机", [("内核", s.xray ? "运行中" : "已停止"), ("代理", s.on ? "已开启" : "已关闭"), ("端口", "10808")])
                quickCard("服务器", [("Xray", "运行中"), ("SSH", "仅密钥"), ("防火墙", "已启用")])
                quickCard("三道防火墙", [("服务器 ufw", "已启用 · 仅 443/\(SPORT)"), ("Mac 应用防火墙", s.fwApp == "enabled" ? "已开启" : "未开启"), ("Mac 防泄漏规则", s.fwStun ? "已安装" : "未安装")])
            }.frame(height: 150)
        }
    }
    func quickCard(_ t: String, _ rows: [(String, String)]) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 7) {
                Lab(t: t)
                ForEach(0..<rows.count, id: \.self) { i in
                    HStack {
                        Text(rows[i].0).font(.system(size: 11.5)).foregroundColor(cMuted)
                        Spacer()
                        Text(rows[i].1).font(.system(size: 11.5, weight: .medium)).foregroundColor(cText)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: 流量页
struct TrafficPage: View {
    @ObservedObject var s: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("流量").font(.system(size: 17, weight: .semibold)).foregroundColor(cText)
                Spacer()
                Text("每 15 秒自动刷新").font(.system(size: 10)).foregroundColor(cMuted.opacity(0.7))
            }
            // 顶部四个数字
            HStack(spacing: 12) {
                numCard("今日用量", String(format: "%.2f", s.today), "GB",
                        s.today / (s.dailyWarn * 3), "超 \(Int(s.dailyWarn * 3)) GB 有风险")
                numCard("本月用量", String(format: "%.2f", s.month), "GB",
                        s.month / max(1, s.quota), "套餐 \(Int(s.quota)) GB")
                numCard("实时速度", String(format: "%.1f", s.up), "Mbps ↑",
                        min(1, s.up / 50), String(format: "下行 %.1f Mbps", s.down))
                numCard("当前连接", "\(s.conns)", "个",
                        Double(s.conns) / 300, "超 300 需留意")
            }.frame(height: 110)

            HStack(spacing: 12) {
                VStack(spacing: 12) {
                    chartCard("最近 24 小时（每小时）", s.hourly, cGreen)
                    chartCard("最近 7 天（每天）", s.daily, cBlue)
                }
                VStack(spacing: 12) {
                    usageCard
                    rankCard("当前连接数排行", s.connApps.filter { $0.p != "xray" }
                        .map { ($0.p, "\($0.n) 条") })
                }
                .frame(width: 300)
            }
            .frame(maxHeight: .infinity)
        }
    }

    func numCard(_ t: String, _ v: String, _ u: String, _ r: Double, _ foot: String) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 5) {
                Lab(t: t)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(v).font(.system(size: 24, weight: .bold)).foregroundColor(cText)
                    Text(u).font(.system(size: 10)).foregroundColor(cMuted)
                }
                Bar2(r: r, c: lvl(r, 0.34, 0.67))
                Text(foot).font(.system(size: 9.5)).foregroundColor(cMuted.opacity(0.75))
                Spacer(minLength: 0)
            }
        }
    }

    func chartCard(_ title: String, _ pts: [Pt], _ color: Color) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Lab(t: title)
                    Spacer()
                    if let mx = pts.map({ $0.value }).max(), mx > 0 {
                        Text(String(format: "峰值 %.2f GB", mx)).font(.system(size: 9.5)).foregroundColor(cMuted)
                    }
                }
                Chart(pts: pts, color: color, kind: title.contains("天") ? 1 : 0, dense: true)
                    .frame(maxHeight: .infinity)
            }
        }
    }

    var usageCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Lab(t: "程序流量排行")
                HStack(spacing: 0) {
                    uBtn("24时", 1)
                    uBtn("3天", 3)
                    uBtn("7天", 7)
                    uBtn("1月", 30)
                }
                .padding(2)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.06)))
                usageList
            }
        }
        .onAppear { s.loadUsage(s.usageDays) }
    }

    @ViewBuilder
    var usageList: some View {
        if s.usage.isEmpty {
            Text("还在累计中（每分钟记一次）").font(.system(size: 10)).foregroundColor(cMuted)
        } else {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 3) {
                    ForEach(Array(s.usage.prefix(12).enumerated()), id: \.offset) { pair in
                        usageRow(pair.offset, pair.element)
                    }
                }
            }
        }
    }

    func usageRow(_ i: Int, _ a: UsageItem) -> some View {
        HStack(spacing: 7) {
            Text("\(i + 1)")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(i < 3 ? cBlue : cMuted.opacity(0.7))
                .frame(width: 13)
            Text(a.p).font(.system(size: 10.5)).foregroundColor(cText)
                .lineLimit(1).truncationMode(.middle)
            Spacer()
            Text(a.gb >= 1 ? String(format: "%.2f GB", a.gb) : String(format: "%.0f MB", a.gb * 1024))
                .font(.system(size: 9.5)).foregroundColor(cMuted)
        }
        .padding(.vertical, 2)
    }

    func uBtn(_ t: String, _ d: Int) -> some View {
        Button(action: { s.loadUsage(d) }) {
            Text(t).font(.system(size: 9.5, weight: s.usageDays == d ? .semibold : .regular))
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5).fill(s.usageDays == d ? Color.white.opacity(0.18) : .clear))
                .foregroundColor(s.usageDays == d ? cText : cMuted)
        }.buttonStyle(.plain)
    }

    func rankCard(_ title: String, _ items: [(String, String)]) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack { Lab(t: title); Spacer() }
                if items.isEmpty {
                    Text("暂无数据").font(.system(size: 11)).foregroundColor(cMuted)
                } else {
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(spacing: 3) {
                            ForEach(Array(items.prefix(12).enumerated()), id: \.offset) { i, it in
                                HStack(spacing: 7) {
                                    Text("\(i + 1)").font(.system(size: 9, weight: .bold))
                                        .foregroundColor(i < 3 ? cBlue : cMuted.opacity(0.7)).frame(width: 13)
                                    Text(it.0).font(.system(size: 10.5)).foregroundColor(cText)
                                        .lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Text(it.1).font(.system(size: 9.5)).foregroundColor(cMuted)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: 服务器页
struct ServerPage: View {
    @ObservedObject var s: AppState
    @State private var confirmAction: String? = nil
    @State private var copied = false

    func rowKV(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.system(size: 11.5)).foregroundColor(cMuted)
            Spacer()
            Text(v).font(.system(size: 11.5, weight: .medium)).foregroundColor(cText)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("服务器").font(.system(size: 17, weight: .semibold)).foregroundColor(cText)
            HStack(spacing: 12) {
                metric("CPU", String(format: "%.1f", s.cpu), "%", "cpu", s.cpu / 100)
                metric("内存", "\(s.memUsed)", "MB", "cpu", Double(s.memUsed) / Double(max(1, s.memTotal)))
                metric("磁盘", "\(s.disk)", "%", "disk", Double(s.disk) / 100)
            }.frame(height: 130)
            HStack(spacing: 10) {
                serverBtn("🔄 重启服务器", cYellow) { confirmAction = "reboot" }
                serverBtn("⏻ 关机", cRed) { confirmAction = "poweroff" }
                Text("关机后需到面板「开机」才能恢复").font(.system(size: 10)).foregroundColor(cMuted)
                Spacer()
            }.frame(height: 34)
            HStack(spacing: 12) {
                infoCard("运行状态", [("负载", s.load), ("已运行", s.uptime), ("延迟", "\(s.latency) ms"), ("丢包", String(format: "%.0f%%", s.loss))])
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Lab(t: "网络")
                        Button(action: {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(HOST, forType: .string)
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                        }) {
                            HStack {
                                Text("出口 IP").font(.system(size: 11.5)).foregroundColor(cMuted)
                                Spacer()
                                Text(copied ? "已复制 ✓" : HOST + "  ⧉")
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundColor(copied ? cGreen : cText)
                            }
                        }.buttonStyle(.plain)
                        rowKV("端口", "443")
                        rowKV("上行", String(format: "%.1f Mbps", s.up))
                        rowKV("下行", String(format: "%.1f Mbps", s.down))
                        Spacer(minLength: 0)
                    }
                }
                infoCard("服务", [("Xray", "运行中"), ("防火墙", "已启用"), ("SSH", "仅密钥"), ("到期", s.expire)])
            }
            .frame(maxHeight: .infinity)
        }
    }
    func serverBtn(_ t: String, _ c: Color, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Text(t).font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 12).frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(c.opacity(0.16)))
                .foregroundColor(c)
        }.buttonStyle(.plain)
    }

    func metric(_ t: String, _ v: String, _ u: String, _ kind: String, _ r: Double) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Lab(t: t)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(v).font(.system(size: 28, weight: .bold)).foregroundColor(cText)
                    Text(u).font(.system(size: 11)).foregroundColor(cMuted)
                }
                Bar2(r: r, c: lvl(r, 0.7, 0.9))
                Spacer(minLength: 0)
                DetailButton(label: t, kind: kind, s: s)
            }
        }
    }
    func infoCard(_ t: String, _ rows: [(String, String)]) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Lab(t: t)
                ForEach(0..<rows.count, id: \.self) { i in
                    HStack {
                        Text(rows[i].0).font(.system(size: 11.5)).foregroundColor(cMuted)
                        Spacer()
                        Text(rows[i].1).font(.system(size: 11.5, weight: .medium)).foregroundColor(cText)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: 分流规则页
struct RulesPage: View {
    @ObservedObject var s: AppState
    @State private var lines: [String] = []
    @State private var newHost = ""
    @State private var newKind = 0
    @State private var recs: [String] = []
    @State private var showPicker = false
    @State private var showRecs = false
    @State private var appName = ""
    @State private var pendingAddAll: [String] = []
    @State private var lookupResult: [String] = []
    @State private var pendingAdd: (String, String)? = nil
    @State private var pendingDel: (String, String)? = nil
    let RFILE = APP + "/规则.txt"

    var directList: [String] { lines.filter { $0.hasPrefix("direct|") }.map { String($0.dropFirst(7)) } }
    var proxyList: [String] { lines.filter { $0.hasPrefix("proxy|") }.map { String($0.dropFirst(6)) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("分流规则").font(.system(size: 17, weight: .semibold)).foregroundColor(cText)
                Spacer()
                Button(action: { genRecs(); showRecs = true }) {
                    Text("✨ 自动推荐").font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 7).fill(cBlue.opacity(0.18)))
                        .foregroundColor(cBlue)
                }.buttonStyle(.plain)
                Text("共 \(directList.count) 直连 / \(proxyList.count) 代理").font(.system(size: 10.5)).foregroundColor(cMuted)
            }

            if !lookupResult.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Lab(t: "查到的域名（点一条加入，或上面点“全部加入”）")
                            Spacer()
                            Button(action: { lookupResult = [] }) {
                                Text("关闭").font(.system(size: 9.5)).foregroundColor(cMuted)
                            }.buttonStyle(.plain)
                        }
                        ScrollView(.vertical, showsIndicators: true) {
                            VStack(spacing: 3) {
                                ForEach(lookupResult, id: \.self) { h in
                                    HStack {
                                        Text(h).font(.system(size: 10.5)).foregroundColor(cText)
                                        Spacer()
                                        Button("加入代理") { pendingAdd = ("proxy", h) }
                                            .buttonStyle(.plain).font(.system(size: 9.5)).foregroundColor(cGreen)
                                    }
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.03)))
                                }
                            }
                        }
                    }
                }.frame(height: 150)
            }
            Card {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Lab(t: "走代理白名单（只有这里列出的才走代理）")
                        Spacer()
                        Text("\(proxyList.count) 条").font(.system(size: 9.5)).foregroundColor(cMuted.opacity(0.8))
                    }
                    Text("其余所有网站和 App 默认全部直连").font(.system(size: 9.5)).foregroundColor(cMuted.opacity(0.7))
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(spacing: 4) {
                            ForEach(proxyList, id: \.self) { h in
                                HStack(spacing: 7) {
                                    Text(h).font(.system(size: 11)).foregroundColor(cText).lineLimit(1)
                                    Spacer()
                                    Button(action: { pendingDel = ("proxy", h) }) {
                                        Text("✕").font(.system(size: 9.5)).foregroundColor(cMuted).padding(4)
                                    }.buttonStyle(.plain)
                                }
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.03)))
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
            HStack(spacing: 8) {
                appLookup
                Button(action: { showPicker = true }) {
                    HStack(spacing: 5) {
                        Text("＋ 选择域名添加").font(.system(size: 11.5, weight: .semibold))
                    }
                    .padding(.horizontal, 14).frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 7).fill(cGreen.opacity(0.9)))
                    .foregroundColor(Color(red: 0.02, green: 0.12, blue: 0.05))
                }.buttonStyle(.plain)
                Spacer()
                Text("点 ✕ 删除、添加都会二次确认").font(.system(size: 9.5)).foregroundColor(cMuted.opacity(0.7))
            }
        }
        .onAppear { load() }
        .overlay(
            Group {
                if showRecs {
                    ZStack {
                        Color.black.opacity(0.45).onTapGesture { showRecs = false }
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("自动推荐").font(.system(size: 13, weight: .semibold)).foregroundColor(cText)
                                Spacer()
                                Button(action: { showRecs = false }) {
                                    Text("✕").font(.system(size: 12)).foregroundColor(cMuted)
                                        .frame(width: 24, height: 24)
                                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08)))
                                }.buttonStyle(.plain)
                            }
                            Text("最近在走代理、但看起来像国内站的域名（点一行加入直连）")
                                .font(.system(size: 10)).foregroundColor(cMuted)
                            ScrollView(.vertical, showsIndicators: true) {
                                VStack(spacing: 4) {
                                    ForEach(recs, id: \.self) { h in
                                        Button(action: { addDirect(h); recs.removeAll { $0 == h } }) {
                                            HStack {
                                                Text(h).font(.system(size: 11)).foregroundColor(cText)
                                                Spacer()
                                                Text("+ 直连").font(.system(size: 9.5)).foregroundColor(cGreen)
                                            }
                                            .padding(.horizontal, 9).padding(.vertical, 7)
                                            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.05)))
                                        }.buttonStyle(.plain)
                                    }
                                }
                            }
                            Button(action: { showRecs = false }) {
                                Text("关闭").font(.system(size: 11))
                                    .frame(maxWidth: .infinity).padding(.vertical, 6)
                                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.08)))
                                    .foregroundColor(cText)
                            }.buttonStyle(.plain)
                        }
                        .padding(14)
                        .frame(width: 460, height: 380)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Color(red: 0.11, green: 0.11, blue: 0.13)))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(cLine, lineWidth: 1))
                        .shadow(color: .black.opacity(0.5), radius: 24, y: 8)
                    }
                }
            }
        )
        .sheet(isPresented: $showPicker) {
            VStack(alignment: .leading, spacing: 8) {
                Text("选择要添加的域名").font(.system(size: 13, weight: .semibold))
                HStack(spacing: 8) {
                    TextField("手动输入域名，例如 example.com", text: $newHost)
                        .textFieldStyle(.roundedBorder)
                    Button("直连") { if !newHost.isEmpty { pendingAdd = ("direct", newHost); newHost = ""; showPicker = false } }
                        .buttonStyle(.plain).foregroundColor(cGreen)
                    Button("代理") { if !newHost.isEmpty { pendingAdd = ("proxy", newHost); newHost = ""; showPicker = false } }
                        .buttonStyle(.plain).foregroundColor(cBlue)
                }
                Text("下面是最近经过代理的网站／App").font(.system(size: 10)).foregroundColor(cMuted)
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(pickerList, id: \.self) { h in
                            HStack(spacing: 8) {
                                Text(h).font(.system(size: 11)).lineLimit(1)
                                Spacer()
                                Button("直连") { pendingAdd = ("direct", h); showPicker = false }
                                    .buttonStyle(.plain).foregroundColor(cGreen)
                                Button("代理") { pendingAdd = ("proxy", h); showPicker = false }
                                    .buttonStyle(.plain).foregroundColor(cBlue)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.04)))
                        }
                    }
                }
                Button("取消") { showPicker = false }.buttonStyle(.plain).foregroundColor(cMuted)
            }
            .padding(16).frame(width: 420, height: 360)
        }
        .alert("确认添加？", isPresented: Binding(get: { pendingAdd != nil }, set: { if !$0 { pendingAdd = nil } })) {
            Button("取消", role: .cancel) { pendingAdd = nil }
            Button("确定") {
                if let (k, h) = pendingAdd {
                    _ = sh("bash '\(APP)/加规则.sh' \(k) '\(h)'")
                    load(); s.refresh()
                }
                pendingAdd = nil
            }
        } message: {
            Text(pendingAdd.map { "\($0.1) → \($0.0 == "direct" ? "走直连" : "走代理")" } ?? "")
        }
        .alert("确认全部加入代理？", isPresented: Binding(get: { !pendingAddAll.isEmpty }, set: { if !$0 { pendingAddAll = [] } })) {
            Button("取消", role: .cancel) { pendingAddAll = [] }
            Button("确定") {
                for h in pendingAddAll { _ = sh("bash '\(APP)/加规则.sh' proxy '\(h)'") }
                pendingAddAll = []; load(); s.refresh()
            }
        } message: {
            Text("共 \(pendingAddAll.count) 个域名会加入代理白名单")
        }
        .alert("确认删除这条规则？", isPresented: Binding(get: { pendingDel != nil }, set: { if !$0 { pendingDel = nil } })) {
            Button("取消", role: .cancel) { pendingDel = nil }
            Button("删除", role: .destructive) {
                if let (k, h) = pendingDel {
                    _ = sh("sed -i '' '/^\(k)|\(h)$/d' '\(RFILE)'")
                    _ = sh("bash '\(APP)/应用规则.sh' smart")
                    load(); s.refresh()
                }
                pendingDel = nil
            }
        }
    }

    var appLookup: some View {
        HStack(spacing: 6) {
            TextField("输入程序名，如 汽水音乐", text: $appName)
                .textFieldStyle(.roundedBorder).frame(width: 170)
            Button(action: { lookupApp() }) {
                Text("查域名").font(.system(size: 10.5, weight: .semibold))
                    .padding(.horizontal, 10).frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 6).fill(cBlue.opacity(0.18)))
                    .foregroundColor(cBlue)
            }.buttonStyle(.plain)
            if !lookupResult.isEmpty {
                Text("查到 \(lookupResult.count) 个").font(.system(size: 9.5)).foregroundColor(cMuted)
                Button(action: { pendingAddAll = lookupResult }) {
                    Text("全部加入代理").font(.system(size: 9.5, weight: .semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5).fill(cGreen.opacity(0.2)))
                        .foregroundColor(cGreen)
                }.buttonStyle(.plain)
            }
        }
    }

    func lookupApp() {
        let name = appName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        var found: [String] = []
        if let map = try? String(contentsOfFile: APP + "/软件域名.txt", encoding: .utf8) {
            for line in map.split(separator: "\n") where !line.hasPrefix("#") {
                let parts = line.split(separator: "|", maxSplits: 1).map(String.init)
                if parts.count == 2 && parts[0].contains(name) {
                    found += parts[1].split(separator: ",").map { String($0) }
                }
            }
        }
        lookupResult = Array(Set(found))
    }

    var pickerList: [String] {
        var set = Set(s.sites.map { $0.h })
        for a in s.apps where a.kb > 1 { set.insert("（App）" + a.p) }
        return Array(set).sorted()
    }

    func ruleList(_ title: String, _ items: [String], _ kind: String) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack { Lab(t: title); Spacer(); Text("\(items.count) 条").font(.system(size: 9.5)).foregroundColor(cMuted.opacity(0.8)) }
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: 4) {
                        ForEach(items, id: \.self) { h in
                            HStack(spacing: 7) {
                                Text(h).font(.system(size: 11)).foregroundColor(cText).lineLimit(1)
                                Spacer()
                                Button(action: { pendingDel = (kind, h) }) {
                                    Text("✕").font(.system(size: 9.5)).foregroundColor(cMuted)
                                        .padding(4)
                                }.buttonStyle(.plain)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.03)))
                        }
                    }
                }
            }
        }
    }

    func load() {
        let t = (try? String(contentsOfFile: RFILE, encoding: .utf8)) ?? ""
        lines = t.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("#") && $0.contains("|") }
    }
    func addRule() {
        let h = newHost.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty else { return }
        _ = sh("bash '\(APP)/加规则.sh' \(newKind == 0 ? "direct" : "proxy") '\(h)'")
        newHost = ""; load(); s.refresh()
    }
    func addDirect(_ h: String) {
        _ = sh("bash '\(APP)/加规则.sh' direct '\(h)'")
        load(); s.refresh()
    }
    func remove(_ kind: String, _ h: String) {
        _ = sh("sed -i '' '/^\(kind)|\(h)$/d' '\(RFILE)'")
        _ = sh("bash '\(APP)/应用规则.sh' smart")
        load(); s.refresh()
    }
    func genRecs() {
        // 最近走代理、但看起来像国内的域名
        let cn = ["zijie", "doubao", "qianwen", "bytedance", "aliyun", "taobao", "jd", "bilibili",
                  "xiaohongshu", "weibo", "163.com", "qq.com", "baidu", "xiaomi", "netease"]
        var out: [String] = []
        for st in s.sites where !s.isDirect(st.h) {
            let low = st.h.lowercased()
            if cn.contains(where: { low.contains($0) }) { out.append(st.h) }
        }
        recs = Array(Set(out)).prefix(8).map { $0 }
        if recs.isEmpty { recs = ["（暂时没有可推荐的域名）"] }
    }
}

// MARK: 设置页
struct SettingsPage: View {
    @ObservedObject var s: AppState
    @State private var doc = ""
    @State private var showDoc = false
    @State private var showClean = false
    @State private var cleanLines: [(String, String, String)] = []
    @State private var cleanMsg = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("设置").font(.system(size: 17, weight: .semibold)).foregroundColor(cText)
            HStack(spacing: 12) {
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        Lab(t: "套餐管理")
                        HStack {
                            Text("套餐总流量 (GB)").font(.system(size: 12)).foregroundColor(cMuted)
                            Spacer()
                            TextField("", value: $s.planGB, format: .number)
                                .textFieldStyle(.roundedBorder).frame(width: 100)
                                .onChange(of: s.planGB) { s.quota = $0 }
                        }
                        HStack {
                            Text("装软件前已用 (GB)").font(.system(size: 12)).foregroundColor(cMuted)
                            Spacer()
                            TextField("", value: $s.usedBase, format: .number)
                                .textFieldStyle(.roundedBorder).frame(width: 100)
                        }
                        HStack {
                            Text("购买日期").font(.system(size: 12)).foregroundColor(cMuted)
                            Spacer()
                            TextField("2026-11-01", text: $s.planStart)
                                .textFieldStyle(.roundedBorder).frame(width: 120)
                        }
                        HStack {
                            Text("套餐天数").font(.system(size: 12)).foregroundColor(cMuted)
                            Spacer()
                            TextField("", value: $s.planDays, format: .number)
                                .textFieldStyle(.roundedBorder).frame(width: 70)
                            Text("天").font(.system(size: 11)).foregroundColor(cMuted)
                        }
                        HStack(spacing: 0) {
                            mBtn("30", 30); mBtn("31", 31); mBtn("90", 90); mBtn("180", 180); mBtn("365", 365)
                        }
                        .padding(2)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.07)))
                        HStack {
                            Text("到期日（自动算）").font(.system(size: 12)).foregroundColor(cMuted)
                            Spacer()
                            Text(s.expireAuto).font(.system(size: 12, weight: .semibold)).foregroundColor(cGreen)
                        }
                        HStack {
                            Text("本月已用（含基数）").font(.system(size: 12)).foregroundColor(cMuted)
                            Spacer()
                            Text(String(format: "%.2f GB / %.0f GB", s.monthTotal, s.planGB))
                                .font(.system(size: 12, weight: .semibold)).foregroundColor(cText)
                        }
                        HStack {
                            Text("新计费周期开始？").font(.system(size: 12)).foregroundColor(cMuted)
                            Spacer()
                            Button(action: { resetCycle() }) {
                                Text("本月重置").font(.system(size: 11, weight: .semibold))
                                    .padding(.horizontal, 10).padding(.vertical, 4)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(cBlue.opacity(0.18)))
                                    .foregroundColor(cBlue)
                            }.buttonStyle(.plain)
                        }
                        field("今日建议上限 (GB)", value: $s.dailyWarn)
                        HStack {
                            Text("体检记录保留").font(.system(size: 12)).foregroundColor(cMuted)
                            Spacer()
                            HStack(spacing: 0) {
                                dayBtn("1天", 1); dayBtn("3天", 3); dayBtn("7天", 7); dayBtn("30天", 30)
                            }
                            .padding(2)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.07)))
                        }
                        Spacer(minLength: 0)
                    }
                }
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        Lab(t: "快捷操作")
                        Divider().overlay(cLine)
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("只允许本机 IP 登录服务器").font(.system(size: 12)).foregroundColor(cText)
                                Text(s.restrictIP.isEmpty ? "当前：不限制（任何 IP 有钥匙就能登）"
                                                          : "当前已绑定：\(s.restrictIP)")
                                    .font(.system(size: 9.5)).foregroundColor(cMuted)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(get: { !s.restrictIP.isEmpty },
                                                     set: { s.setRestrict($0) }))
                                .labelsHidden().toggleStyle(.switch)
                        }
                        if !s.restrictIP.isEmpty {
                            HStack {
                                Text("换了网络/IP 后需要点一下更新，否则会连不上").font(.system(size: 9.5)).foregroundColor(cYellow.opacity(0.9))
                                Spacer()
                                Button(action: { s.updateRestrictIP() }) {
                                    Text("更新为当前 IP").font(.system(size: 10, weight: .semibold))
                                        .padding(.horizontal, 8).padding(.vertical, 3)
                                        .background(RoundedRectangle(cornerRadius: 6).fill(cBlue.opacity(0.18)))
                                        .foregroundColor(cBlue)
                                }.buttonStyle(.plain)
                            }
                        }
                        act("📖 打开说明书") {
                            if doc.isEmpty { doc = (try? String(contentsOfFile: DOC, encoding: .utf8)) ?? "读不到" }
                            showDoc = true
                        }
                        act("🔄 重新载入内核") {
                            _ = sh("launchctl kickstart -k \"gui/\(getuid())/com.dsh.xray-reality\"")
                            s.refresh()
                        }
                        act("📄 打开运行日志") { NSWorkspace.shared.open(URL(fileURLWithPath: LOG)) }
                        act("🧹 一键清理缓存") { cleanAll() }
                        act("📋 查看可清理项") { loadClean(); showClean = true }
                        act("⏻ 退出 App") { NSApp.terminate(nil) }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .overlay(
            Group {
                if let p = cleanProgress {
                    ZStack {
                        Color.black.opacity(0.55).onTapGesture { cleanProgress = nil }
                        VStack(spacing: 14) {
                            if p < 1.0 {
                                Text("正在清理…").font(.system(size: 14, weight: .semibold)).foregroundColor(cText)
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.10)).frame(width: 240, height: 8)
                                    RoundedRectangle(cornerRadius: 4).fill(cGreen)
                                        .frame(width: 240 * CGFloat(p), height: 8)
                                }
                                Text("\(Int(p * 100))%").font(.system(size: 11)).foregroundColor(cMuted)
                            } else {
                                Text("✅").font(.system(size: 40))
                                Text("清理完成").font(.system(size: 14, weight: .semibold)).foregroundColor(cGreen)
                                Text("点空白处关闭").font(.system(size: 10)).foregroundColor(cMuted)
                            }
                        }
                        .padding(22)
                        .frame(width: 300)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Color(red: 0.13, green: 0.13, blue: 0.15)))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(cLine, lineWidth: 1))
                    }
                }
                if showClean {
                    ZStack {
                        Color.black.opacity(0.45).onTapGesture { showClean = false }
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("清理空间").font(.system(size: 13, weight: .semibold)).foregroundColor(cText)
                                Spacer()
                                Button(action: { showClean = false }) {
                                    Text("✕").font(.system(size: 12)).foregroundColor(cMuted)
                                        .frame(width: 24, height: 24)
                                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08)))
                                }.buttonStyle(.plain)
                            }
                            if !cleanMsg.isEmpty {
                                Text(cleanMsg).font(.system(size: 10.5)).foregroundColor(cGreen)
                            }
                            ScrollView(.vertical, showsIndicators: true) {
                                VStack(spacing: 5) {
                                    ForEach(Array(cleanLines.enumerated()), id: \.offset) { pair in
                                        cleanRow(pair.element)
                                    }
                                }
                            }
                            Text("只清理本 App 自己产生的文件。音乐、照片、其他 App 的数据，一律不碰。")
                                .font(.system(size: 9.5)).foregroundColor(cMuted.opacity(0.8))
                        }
                        .padding(14)
                        .frame(width: 520, height: 420)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Color(red: 0.11, green: 0.11, blue: 0.13)))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(cLine, lineWidth: 1))
                    }
                }
                if showDoc {
                    ZStack {
                        Color.black.opacity(0.5).onTapGesture { showDoc = false }
                        VStack(spacing: 0) {
                            HStack {
                                Text("出问题怎么办").font(.system(size: 14, weight: .semibold)).foregroundColor(.white)
                                Spacer()
                                Button(action: { showDoc = false }) {
                                    Text("关闭").font(.system(size: 12)).padding(.horizontal, 12).padding(.vertical, 5)
                                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.12)))
                                        .foregroundColor(.white)
                                }.buttonStyle(.plain)
                            }.padding(13)
                            Divider().overlay(cLine)
                            ScrollView {
                                Text(doc).font(.system(size: 11.5, design: .monospaced))
                                    .foregroundColor(Color(white: 0.86)).lineSpacing(4)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(15)
                            }
                        }
                        .frame(maxWidth: 720, maxHeight: 480)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Color(red: 0.11, green: 0.11, blue: 0.13)))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(cLine, lineWidth: 1))
                    }
                }
            }
        )
    }
    func loadClean() {
        shAsync("bash '\(APP)/清理.sh' list") { out in
            self.cleanLines = out.split(separator: "\n").compactMap { line in
                let p = line.split(separator: "|", maxSplits: 3).map(String.init)
                return p.count == 4 ? (p[0], p[1], p[2]) : nil
            }
        }
    }
    @State private var cleanProgress: Double? = nil

    func cleanAll() {
        cleanProgress = 0
        withAnimation(.linear(duration: 1.2)) { cleanProgress = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            shAsync("bash '\(APP)/清理.sh' clean appcache; bash '\(APP)/清理.sh' clean shots; bash '\(APP)/清理.sh' clean backups") { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
                    cleanProgress = nil
                    cleanMsg = "已清理：运行缓存、测试截图、60 天前的备份"
                    loadClean()
                }
            }
        }
    }

    func resetCycle() {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        s.usedBase = 0
        s.planStart = f.string(from: Date())
        s.expire = s.expireAuto
    }

    func mBtn(_ t: String, _ v: Int) -> some View {
        Button(action: { s.planDays = v; s.expire = s.expireAuto }) {
            Text(t + " 天").font(.system(size: 10, weight: s.planDays == v ? .semibold : .regular))
                .padding(.horizontal, 6).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 5).fill(s.planDays == v ? Color.white.opacity(0.20) : .clear))
                .foregroundColor(s.planDays == v ? cText : cMuted)
        }.buttonStyle(.plain)
    }

    func dayBtn(_ t: String, _ v: Int) -> some View {
        Button(action: { s.historyDays = v }) {
            Text(t).font(.system(size: 10.5, weight: s.historyDays == v ? .semibold : .regular))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 5).fill(s.historyDays == v ? Color.white.opacity(0.20) : .clear))
                .foregroundColor(s.historyDays == v ? cText : cMuted)
        }.buttonStyle(.plain)
    }

    func cleanRow(_ it: (String, String, String)) -> some View {
        let key = it.0, name = it.1, size = it.2
        let deletable = (key == "appcache" || key == "shots" || key == "backups" || key == "oldchecks")
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 11.5)).foregroundColor(cText)
                Text("\(size) MB").font(.system(size: 9.5)).foregroundColor(cMuted)
            }
            Spacer()
            if deletable {
                Button(action: {
                    _ = sh("bash '\(APP)/清理.sh' clean \(key)")
                    cleanMsg = "已清理：\(name)"
                    loadClean()
                }) {
                    Text("清理").font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 6).fill(cGreen.opacity(0.18)))
                        .foregroundColor(cGreen)
                }.buttonStyle(.plain)
            } else {
                Text("仅统计").font(.system(size: 9.5)).foregroundColor(cMuted.opacity(0.6))
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.04)))
    }

    func field(_ t: String, value: Binding<Double>) -> some View {
        HStack {
            Text(t).font(.system(size: 12)).foregroundColor(cMuted)
            Spacer()
            TextField("", value: value, format: .number).textFieldStyle(.roundedBorder).frame(width: 100)
        }
    }
    func act(_ t: String, _ f: @escaping () -> Void) -> some View {
        Button(action: f) {
            Text(t).font(.system(size: 12)).foregroundColor(cText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
        }.buttonStyle(.plain)
    }
}

// MARK: Root
struct RootView: View {
    @ObservedObject var s: AppState
    @State private var page = 0
    @State private var collapsed = false
    var body: some View {
        HStack(spacing: 0) {
            Sidebar(page: $page, collapsed: $collapsed)
            ZStack(alignment: .trailing) {
                Group {
                    switch page {
                    case 0: Overview(s: s)
                    case 1: SecurityPage(s: s)
                    case 2: TrafficPage(s: s)
                    case 3: ServerPage(s: s)
                    case 4: RulesPage(s: s)
                    default: SettingsPage(s: s)
                    }
                }
                .padding(16)
                if s.detail != nil { Drawer(s: s).transition(.move(edge: .trailing)) }
            }
        }
        .frame(minWidth: 920, maxWidth: .infinity, minHeight: 600, maxHeight: .infinity)
        .background(LinearGradient(colors: [cBg2, cBg], startPoint: .topLeading, endPoint: .bottomTrailing))
        .onAppear { s.refresh(); s.loadHistory() }
    }
}

// MARK: App
final class AppDelegate: NSObject, NSApplicationDelegate {
    var item: NSStatusItem!
    var popover = NSPopover()
    var window: NSWindow?
    let state = AppState()

    func applicationDidFinishLaunching(_ n: Notification) {
        if let i = CommandLine.arguments.firstIndex(of: "--render"), i + 1 < CommandLine.arguments.count {
            let out = CommandLine.arguments[i + 1]
            NSApp.setActivationPolicy(.accessory)
            state.refresh()
            DispatchQueue.main.asyncAfter(deadline: .now() + 18) {
                let r = ImageRenderer(content: RootView(s: self.state).frame(width: 1000, height: 760))
                r.scale = 2
                if let img = r.nsImage, let t = img.tiffRepresentation, let rep = NSBitmapImageRep(data: t),
                   let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: out)); print("rendered")
                }
                NSApp.terminate(nil)
            }
            return
        }
        NSApp.setActivationPolicy(.regular)
        installCrashLog()
        autoSyncIfNeeded()
        buildMenu()
        NSEvent.addLocalMonitorForEvents(matching: [.swipe, .scrollWheel]) { e in
            if e.type == .swipe {
                if e.deltaY < 0 { SwipeBus.shared.fire(1) } else if e.deltaY > 0 { SwipeBus.shared.fire(-1) }
                return e
            }
            // 只在侧栏区域（窗口左侧 200pt 内）响应上下滑
            if let win = e.window, let cv = win.contentView {
                let p = cv.convert(e.locationInWindow, from: nil)
                if p.x <= 200, abs(e.scrollingDeltaY) > 4 {
                    SwipeBus.shared.fire(e.scrollingDeltaY > 0 ? -1 : 1)
                }
            }
            return e
        }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.action = #selector(togglePopover)
        item.button?.target = self
        updateIcon()
        popover.contentViewController = NSHostingController(rootView: RootView(s: state))
        popover.contentSize = NSSize(width: 1000, height: 760)
        popover.behavior = .transient
        openWindow()
        state.refresh()
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in self.updateIcon() }
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in self.state.refresh() }
    }
    func autoSyncIfNeeded() { }

    func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于梯子", action: nil, keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "退出梯子", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }

    func updateIcon() {
        let c: NSColor = !state.on ? .secondaryLabelColor : (state.xray ? .systemGreen : .systemRed)
        let a = NSMutableAttributedString(string: "● ", attributes: [.foregroundColor: c, .font: NSFont.systemFont(ofSize: 12)])
        a.append(NSAttributedString(string: "梯子", attributes: [.foregroundColor: NSColor.labelColor,
                                                                .font: NSFont.systemFont(ofSize: 12, weight: .medium)]))
        item.button?.attributedTitle = a
    }
    func openWindow() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "梯子"; w.titlebarAppearsTransparent = true; w.isMovableByWindowBackground = true
            w.contentMinSize = NSSize(width: 920, height: 600)
            w.contentView = NSHostingView(rootView: RootView(s: state))
            w.isReleasedWhenClosed = false; w.center(); window = w
        }
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); state.refresh()
    }
    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows f: Bool) -> Bool { openWindow(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }
    @objc func togglePopover() {
        if popover.isShown { popover.performClose(nil) }
        else if let b = item.button {
            popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true); state.refresh()
        }
    }
}

final class SwipeBus: ObservableObject {
    static let shared = SwipeBus()
    @Published var dir = 0
    private var last = Date.distantPast
    func fire(_ d: Int) {
        let now = Date()
        if now.timeIntervalSince(last) < 0.5 { return }
        last = now
        dir = d
    }
}

func installCrashLog() {
    NSSetUncaughtExceptionHandler { e in
        let msg = "\(Date()) \(e.name.rawValue): \(e.reason ?? "")\n\(e.callStackSymbols.joined(separator: "\n"))\n"
        try? msg.write(toFile: "/tmp/ladder-crash.log", atomically: true, encoding: .utf8)
    }
    for sig in [SIGSEGV, SIGABRT, SIGILL, SIGFPE] {
        signal(sig) { s in
            let msg = "\(Date()) signal \(s)\n"
            try? msg.write(toFile: "/tmp/ladder-crash.log", atomically: true, encoding: .utf8)
            exit(1)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
