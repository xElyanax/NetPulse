import SwiftUI
import Charts
import Foundation
import Darwin
import AppKit
import ServiceManagement

// MARK: - Formatting (cached formatters, locale-independent storage keys)

enum Fmt {
    private static func make(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = format
        return f
    }
    private static let dayF = make("yyyy-MM-dd")
    private static let hourF = make("HH")
    private static let monthF = make("yyyy-MM")
    private static let hourLabelF = make("HH:00")
    private static let dayLabelF: DateFormatter = {
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("dMMM"); return f
    }()
    private static let monthLabelF: DateFormatter = {
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("MMM"); return f
    }()

    static func dayKey(_ d: Date) -> String { dayF.string(from: d) }
    static func hourKey(_ d: Date) -> String { hourF.string(from: d) }
    static func monthKey(_ d: Date) -> String { monthF.string(from: d) }
    static func hourLabel(_ d: Date) -> String { hourLabelF.string(from: d) }
    static func dayLabel(_ d: Date) -> String { dayLabelF.string(from: d) }
    static func monthLabel(_ d: Date) -> String { monthLabelF.string(from: d) }

    static func bytes(_ n: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(max(0, n)), countStyle: .file)
    }
    static func bytes(_ n: UInt64) -> String { bytes(Double(n)) }

    /// Input is bytes/second. Output follows the "useBits" user setting.
    static func speed(_ bytesPerSec: Double) -> String {
        let bits = UserDefaults.standard.bool(forKey: "useBits")
        var x = max(0, bytesPerSec) * (bits ? 8 : 1)
        let units = bits ? ["bps", "Kbps", "Mbps", "Gbps"] : ["B/s", "KB/s", "MB/s", "GB/s"]
        var i = 0
        while x >= 1000 && i < units.count - 1 { x /= 1000; i += 1 }
        if i == 0 { return String(format: "%.0f %@", x, units[0]) }
        return String(format: x >= 100 ? "%.0f %@" : "%.1f %@", x, units[i])
    }
}

// MARK: - Data Models

struct ByteCounters: Codable, Equatable {
    var rx: UInt64 = 0
    var tx: UInt64 = 0
    var total: UInt64 { rx + tx }
    mutating func add(_ o: ByteCounters) { rx += o.rx; tx += o.tx }
}

struct DayRecord: Codable {
    var dateKey: String
    var internet: ByteCounters
    var vpn: ByteCounters
    var hourly: [String: ByteCounters]   // "00"..."23"
}

struct TrafficDatabase: Codable {
    var days: [String: DayRecord]
}

struct SpeedSample: Identifiable, Equatable {
    let id: Int              // monotonically increasing -> stable identity for Swift Charts
    let time: Date
    let rx: Double           // bytes / second
    let tx: Double
    let rxBytes: UInt64      // raw delta for this tick
    let txBytes: UInt64
    var total: Double { rx + tx }
}

struct BarPoint: Identifiable, Equatable {
    let id: Int
    let label: String
    let rx: Double
    let tx: Double
    var total: Double { rx + tx }
}

struct ScopeSummary {
    var rx: Double = 0
    var tx: Double = 0
    var total: Double = 0
    var peak: Double = 0
}

struct Insights {
    var vsYesterday: Double?
    var weekAverage: UInt64 = 0
    var busiestHour: String?
    var busiestBytes: UInt64 = 0
}

struct AppUsageItem: Identifiable {
    let id: String
    let name: String
    let pid: Int32
    let rxRate: Double
    let txRate: Double
    let rxSession: UInt64
    let txSession: UInt64

    var rateTotal: Double { rxRate + txRate }
    var sessionTotal: UInt64 { rxSession + txSession }

    var icon: NSImage? { NSRunningApplication(processIdentifier: pid)?.icon }

    var symbol: String {
        let l = name.lowercased()
        if l.contains("safari") || l.contains("chrome") || l.contains("firefox") || l.contains("edge") || l.contains("arc") { return "globe" }
        if l.contains("telegram") || l.contains("whatsapp") || l.contains("signal") { return "paperplane.fill" }
        if l.contains("code") || l.contains("xcode") || l.contains("terminal") || l.contains("zsh") { return "terminal.fill" }
        if l.contains("spotify") || l.contains("music") { return "music.note" }
        if l.contains("mail") { return "envelope.fill" }
        if l.contains("slack") || l.contains("discord") { return "bubble.left.and.bubble.right.fill" }
        if l.contains("cloud") || l.contains("drive") || l.contains("dropbox") { return "icloud.fill" }
        if l.contains("git") { return "arrow.triangle.branch" }
        return "app.dashed"
    }
}

enum TimeScope: String, CaseIterable, Identifiable {
    case minute = "Live", hourly = "24h", daily = "14d", weekly = "8w", monthly = "6m"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .minute: return "Live · last 60 seconds"
        case .hourly: return "Past 24 hours"
        case .daily: return "Past 14 days"
        case .weekly: return "Past 8 weeks"
        case .monthly: return "Past 6 months"
        }
    }
    var icon: String {
        switch self {
        case .minute: return "bolt.fill"
        case .hourly: return "clock.fill"
        case .daily: return "calendar"
        case .weekly: return "calendar.badge.clock"
        case .monthly: return "chart.bar.fill"
        }
    }
}

enum ChartFilter: String, CaseIterable, Identifiable {
    case all = "All", download = "Download", upload = "Upload"
    var id: String { rawValue }
}

enum ActiveTab: String, CaseIterable, Identifiable {
    case charts = "Traffic", apps = "Apps", overview = "Today"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .charts: return "chart.xyaxis.line"
        case .apps: return "app.badge.checkmark"
        case .overview: return "gauge.with.needle.fill"
        }
    }
}

enum AppMode: String, CaseIterable, Identifiable {
    case live = "Now", session = "Session"
    var id: String { rawValue }
}

// MARK: - Core Engine

@MainActor
final class NetworkMonitor: ObservableObject {
    // UI state
    @Published var activeTab: ActiveTab = .charts
    @Published var confirmReset = false
    @Published var selectedScope: TimeScope = .minute {
        didSet { endHover(); hoveredBarID = nil; refreshChartData() }
    }
    @Published var selectedFilter: ChartFilter = .all
    @Published var appMode: AppMode = .live { didSet { rebuildApps() } }

    // Live data
    @Published private(set) var speedRX: Double = 0
    @Published private(set) var speedTX: Double = 0
    @Published private(set) var vpnActive = false
    @Published private(set) var vpnName: String?
    @Published private(set) var todayInternet = ByteCounters()
    @Published private(set) var todayVPN = ByteCounters()
    @Published private(set) var samples: [SpeedSample] = []
    @Published private(set) var bars: [BarPoint] = []
    @Published private(set) var summary = ScopeSummary()
    @Published private(set) var topApps: [AppUsageItem] = []
    @Published private(set) var appsLoaded = false

    // Hover (inspection) state
    @Published var hoveredSampleID: Int?
    @Published var hoveredBarID: Int?
    @Published private(set) var frozenSamples: [SpeedSample]?

    // Settings (persisted)
    @Published var useBits: Bool { didSet { UserDefaults.standard.set(useBits, forKey: "useBits") } }
    @Published var menuBarShowsSpeed: Bool { didSet { UserDefaults.standard.set(menuBarShowsSpeed, forKey: "menuBarShowsSpeed") } }
    @Published var dailyCapGB: Double { didSet { UserDefaults.standard.set(dailyCapGB, forKey: "dailyCapGB") } }
    @Published var launchAtLogin: Bool {
        didSet {
            do {
                if launchAtLogin { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch { NSLog("NetPulse: launch-at-login failed: \(error)") }
        }
    }

    var popoverVisible = true

    private var database = TrafficDatabase(days: [:])
    private var previous: [String: ByteCounters] = [:]
    private var lastTickUptime = ProcessInfo.processInfo.systemUptime
    private var nextSampleID = 60
    private var tickCounter = 0
    private var timer: Timer?
    private var appTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    // per-app bookkeeping
    private var appLive: [String: (pid: Int32, rx: Double, tx: Double)] = [:]
    private var appSession: [String: ByteCounters] = [:]
    private var appPIDs: [String: Int32] = [:]
    private var lastPollCumulative: [String: ProcCounter] = [:]

    init() {
        let d = UserDefaults.standard
        useBits = d.bool(forKey: "useBits")
        menuBarShowsSpeed = d.object(forKey: "menuBarShowsSpeed") as? Bool ?? true
        dailyCapGB = d.double(forKey: "dailyCapGB")
        launchAtLogin = SMAppService.mainApp.status == .enabled

        let start = Date()
        samples = (0..<60).map { i in
            SpeedSample(id: i, time: start.addingTimeInterval(Double(i - 59)), rx: 0, tx: 0, rxBytes: 0, txBytes: 0)
        }

        purgeLegacySampleData()
        loadDatabase()
        previous = Self.captureCounters()
        lastTickUptime = ProcessInfo.processInfo.systemUptime
        refreshChartData()

        // .common mode: keeps firing while the menu-bar window is open / being interacted with.
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t

        let nc = NSWorkspace.shared.notificationCenter
        observers.append(nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.saveDatabase() }
        })
        observers.append(nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.resetBaseline() }
        })

        appTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.popoverVisible && self.activeTab == .apps { await self.pollApps() }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    // MARK: Menu bar

    var menuBarTitle: String {
        if menuBarShowsSpeed { return "↓ \(Fmt.speed(speedRX))  ↑ \(Fmt.speed(speedTX))" }
        return Fmt.bytes(todayInternet.total)
    }

    // MARK: Tick loop

    private func resetBaseline() {
        previous = Self.captureCounters()
        lastTickUptime = ProcessInfo.processInfo.systemUptime
    }

    private func tick() {
        let uptime = ProcessInfo.processInfo.systemUptime
        let elapsed = max(0.25, uptime - lastTickUptime)
        lastTickUptime = uptime

        let counters = Self.captureCounters()
        let tunnels = Self.tunnelInterfaces()

        var phys = ByteCounters()
        var tun = ByteCounters()
        for (name, c) in counters {
            // Counters are 64-bit now; a decrease means the interface was reset -> skip one tick.
            guard let old = previous[name], c.rx >= old.rx, c.tx >= old.tx else { continue }
            let d = ByteCounters(rx: c.rx - old.rx, tx: c.tx - old.tx)
            if name.hasPrefix("en") { phys.add(d) }
            else if tunnels.contains(name) { tun.add(d) }
        }
        previous = counters

        let now = Date()
        let sample = SpeedSample(
            id: nextSampleID, time: now,
            rx: Double(phys.rx) / elapsed, tx: Double(phys.tx) / elapsed,
            rxBytes: phys.rx, txBytes: phys.tx
        )
        nextSampleID += 1
        samples.append(sample)
        if samples.count > 60 { samples.removeFirst(samples.count - 60) }

        speedRX = sample.rx
        speedTX = sample.tx
        vpnActive = !tunnels.isEmpty
        vpnName = tunnels.sorted().first

        // Persist into the database (single source of truth)
        let dayKey = Fmt.dayKey(now)
        var rec = database.days[dayKey] ?? DayRecord(dateKey: dayKey, internet: ByteCounters(), vpn: ByteCounters(), hourly: [:])
        rec.internet.add(phys)
        rec.vpn.add(tun)
        if phys.total > 0 {
            let hk = Fmt.hourKey(now)
            var h = rec.hourly[hk] ?? ByteCounters()
            h.add(phys)
            rec.hourly[hk] = h
        }
        database.days[dayKey] = rec
        todayInternet = rec.internet
        todayVPN = rec.vpn

        tickCounter += 1
        if tickCounter % 30 == 0 { saveDatabase() }

        if popoverVisible {
            if selectedScope == .minute { summary = minuteSummary() }
            else if tickCounter % 5 == 0 { refreshChartData() }
        }
    }

    // MARK: Hover

    var displaySamples: [SpeedSample] { frozenSamples ?? samples }
    var hoveredSample: SpeedSample? { displaySamples.first { $0.id == hoveredSampleID } }
    var hoveredBar: BarPoint? { bars.first { $0.id == hoveredBarID } }

    func hover(sampleNear date: Date) {
        if frozenSamples == nil { frozenSamples = samples }   // freeze scrolling while inspecting
        let best = displaySamples.min { abs($0.time.timeIntervalSince(date)) < abs($1.time.timeIntervalSince(date)) }
        hoveredSampleID = best?.id
    }

    func endHover() {
        hoveredSampleID = nil
        frozenSamples = nil
    }

    // MARK: Chart aggregation

    private func minuteSummary() -> ScopeSummary {
        let bytes = samples.reduce(0.0) { $0 + Double($1.rxBytes + $1.txBytes) }
        return ScopeSummary(rx: speedRX, tx: speedTX, total: bytes, peak: samples.map(\.total).max() ?? 0)
    }

    private func setBars(_ pts: [BarPoint]) {
        bars = pts
        let rx = pts.reduce(0) { $0 + $1.rx }
        let tx = pts.reduce(0) { $0 + $1.tx }
        summary = ScopeSummary(rx: rx, tx: tx, total: rx + tx, peak: pts.map(\.total).max() ?? 0)
    }

    func refreshChartData() {
        let cal = Calendar.current
        let now = Date()
        switch selectedScope {
        case .minute:
            summary = minuteSummary()

        case .hourly:
            setBars((0..<24).reversed().map { back in
                let d = now.addingTimeInterval(-Double(back) * 3600)
                let c = database.days[Fmt.dayKey(d)]?.hourly[Fmt.hourKey(d)] ?? ByteCounters()
                return BarPoint(id: 23 - back, label: back == 0 ? "Now" : Fmt.hourLabel(d), rx: Double(c.rx), tx: Double(c.tx))
            })

        case .daily:
            setBars((0..<14).reversed().map { back in
                let d = cal.date(byAdding: .day, value: -back, to: now) ?? now
                let c = database.days[Fmt.dayKey(d)]?.internet ?? ByteCounters()
                return BarPoint(id: 13 - back, label: back == 0 ? "Today" : Fmt.dayLabel(d), rx: Double(c.rx), tx: Double(c.tx))
            })

        case .weekly:
            // Rolling 7-day windows ending today (w = 0 is the last 7 days).
            setBars((0..<8).reversed().map { w in
                var sum = ByteCounters()
                for off in 0..<7 {
                    if let d = cal.date(byAdding: .day, value: -(w * 7 + off), to: now),
                       let r = database.days[Fmt.dayKey(d)] { sum.add(r.internet) }
                }
                return BarPoint(id: 7 - w, label: w == 0 ? "Last 7d" : "\(w)w ago", rx: Double(sum.rx), tx: Double(sum.tx))
            })

        case .monthly:
            var perMonth: [String: ByteCounters] = [:]
            for (k, r) in database.days { perMonth[String(k.prefix(7)), default: ByteCounters()].add(r.internet) }
            setBars((0..<6).reversed().map { m in
                let d = cal.date(byAdding: .month, value: -m, to: now) ?? now
                let c = perMonth[Fmt.monthKey(d)] ?? ByteCounters()
                return BarPoint(id: 5 - m, label: m == 0 ? "This month" : Fmt.monthLabel(d), rx: Double(c.rx), tx: Double(c.tx))
            })
        }
    }

    func insights() -> Insights {
        let cal = Calendar.current
        let now = Date()
        let hk = Fmt.hourKey(now)
        let todayHourly = database.days[Fmt.dayKey(now)]?.hourly ?? [:]

        var out = Insights()
        if let y = cal.date(byAdding: .day, value: -1, to: now), let rec = database.days[Fmt.dayKey(y)] {
            let ySame = rec.hourly.filter { $0.key <= hk }.values.reduce(0) { $0 + $1.total }
            if ySame > 0 {
                let t = Double(todayHourly.values.reduce(0) { $0 + $1.total })
                out.vsYesterday = (t - Double(ySame)) / Double(ySame) * 100
            }
        }
        var sum: UInt64 = 0, n: UInt64 = 0
        for i in 1...7 {
            if let d = cal.date(byAdding: .day, value: -i, to: now),
               let r = database.days[Fmt.dayKey(d)], r.internet.total > 0 { sum += r.internet.total; n += 1 }
        }
        out.weekAverage = n > 0 ? sum / n : 0
        if let top = todayHourly.max(by: { $0.value.total < $1.value.total }), top.value.total > 0 {
            out.busiestHour = "\(top.key):00"
            out.busiestBytes = top.value.total
        }
        return out
    }

    // MARK: Per-app traffic (nettop, off the main thread)

    struct ProcCounter { let name: String; let pid: Int32; let rx: UInt64; let tx: UInt64 }

    private func pollApps() async {
        let blocks = await Task.detached(priority: .utility) { Self.nettopSnapshots() }.value
        guard blocks.count >= 2 else { return }
        let first = blocks[blocks.count - 2]
        let last = blocks[blocks.count - 1]

        var live: [String: (pid: Int32, rx: Double, tx: Double)] = [:]
        for (key, cur) in last {
            appPIDs[cur.name] = cur.pid
            // Rate: delta between the two samples inside this poll (~1 s apart).
            if let old = first[key], cur.rx >= old.rx, cur.tx >= old.tx, (cur.rx - old.rx) + (cur.tx - old.tx) > 0 {
                var e = live[cur.name] ?? (pid: cur.pid, rx: 0, tx: 0)
                e.rx += Double(cur.rx - old.rx)
                e.tx += Double(cur.tx - old.tx)
                live[cur.name] = e
            }
            // Session: delta against the previous poll's cumulative counters (gap-safe).
            let base = lastPollCumulative[key] ?? first[key]
            if let b = base, cur.rx >= b.rx, cur.tx >= b.tx {
                appSession[cur.name, default: ByteCounters()].add(ByteCounters(rx: cur.rx - b.rx, tx: cur.tx - b.tx))
            }
        }
        lastPollCumulative = last
        appLive = live
        appsLoaded = true
        rebuildApps()
    }

    private func rebuildApps() {
        var names = Set(appSession.keys)
        names.formUnion(appLive.keys)
        var items: [AppUsageItem] = names.map { n in
            let l = appLive[n]
            let s = appSession[n] ?? ByteCounters()
            return AppUsageItem(id: n, name: n, pid: l?.pid ?? appPIDs[n] ?? 0,
                                rxRate: l?.rx ?? 0, txRate: l?.tx ?? 0, rxSession: s.rx, txSession: s.tx)
        }
        switch appMode {
        case .live:
            items = items.filter { $0.rateTotal > 0 }.sorted { $0.rateTotal > $1.rateTotal }
        case .session:
            items = items.filter { $0.sessionTotal > 0 }.sorted { $0.sessionTotal > $1.sessionTotal }
        }
        topApps = Array(items.prefix(12))
    }

    nonisolated static func nettopSnapshots() -> [[String: ProcCounter]] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        // two samples 1s apart; external interfaces only (no loopback noise)
        task.arguments = ["-P", "-L", "2", "-s", "1", "-t", "external", "-n", "-J", "bytes_in,bytes_out"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return parseNettop(text)
    }

    /// Header-driven parser: every header line (contains "bytes_in") starts a new sample block.
    nonisolated static func parseNettop(_ text: String) -> [[String: ProcCounter]] {
        var blocks: [[String: ProcCounter]] = []
        var current: [String: ProcCounter]?
        var nameIdx = 0, inIdx = 1, outIdx = 2

        for line in text.split(separator: "\n") {
            let cols = line.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }

            if cols.contains("bytes_in") {
                if let c = current { blocks.append(c) }
                current = [:]
                inIdx = cols.firstIndex(of: "bytes_in") ?? 1
                outIdx = cols.firstIndex(of: "bytes_out") ?? (inIdx + 1)
                nameIdx = cols.firstIndex(of: "") ?? 0
                continue
            }
            guard current != nil, nameIdx < cols.count, cols.count > max(inIdx, outIdx) else { continue }
            let proc = cols[nameIdx]
            guard !proc.isEmpty,
                  let rx = UInt64(cols[inIdx]), let tx = UInt64(cols[outIdx]) else { continue }

            var name = proc
            var pid: Int32 = 0
            if let dot = proc.lastIndex(of: "."), let p = Int32(proc[proc.index(after: dot)...]) {
                name = String(proc[..<dot]); pid = p
            }
            current?["\(name).\(pid)"] = ProcCounter(name: name, pid: pid, rx: rx, tx: tx)
        }
        if let c = current { blocks.append(c) }
        return blocks
    }

    // MARK: Network counters (64-bit via sysctl NET_RT_IFLIST2)

    nonisolated static func captureCounters() -> [String: ByteCounters] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &len, nil, 0) == 0, len > 0 else { return [:] }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, UInt32(mib.count), &buf, &len, nil, 0) == 0 else { return [:] }

        var result: [String: ByteCounters] = [:]
        buf.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= len {
                let hdr = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let msgLen = Int(hdr.ifm_msglen)
                if msgLen <= 0 { break }
                if Int32(hdr.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= len {
                    let h2 = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    let flags = Int32(h2.ifm_flags)
                    if (flags & Int32(IFF_UP)) != 0, (flags & Int32(IFF_LOOPBACK)) == 0 {
                        var nameBuf = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                        if if_indextoname(UInt32(h2.ifm_index), &nameBuf) != nil {
                            let name = String(cString: nameBuf)
                            if name.hasPrefix("en") || name.hasPrefix("utun") {
                                result[name] = ByteCounters(rx: h2.ifm_data.ifi_ibytes, tx: h2.ifm_data.ifi_obytes)
                            }
                        }
                    }
                }
                offset += msgLen
            }
        }
        return result
    }

    /// utun interfaces that carry an IPv4 address = real VPN tunnels.
    /// (Link-local-only utuns used by the OS, e.g. Private Relay helpers, are ignored.)
    nonisolated static func tunnelInterfaces() -> Set<String> {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let head = first else { return [] }
        defer { freeifaddrs(head) }
        var names = Set<String>()
        var cursor: UnsafeMutablePointer<ifaddrs>? = head
        while let node = cursor {
            cursor = node.pointee.ifa_next
            guard let addr = node.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET),
                  let namePtr = node.pointee.ifa_name,
                  (Int32(node.pointee.ifa_flags) & Int32(IFF_UP)) != 0 else { continue }
            let name = String(cString: namePtr)
            if name.hasPrefix("utun") { names.insert(name) }
        }
        return names
    }

    // MARK: Persistence

    private static func supportDir() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("NetPulse", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private static func storageURL() -> URL { supportDir().appendingPathComponent("traffic_v3.json") }

    /// Old builds seeded 30 days of random numbers into traffic_v2.json. Remove it.
    private func purgeLegacySampleData() {
        try? FileManager.default.removeItem(at: Self.supportDir().appendingPathComponent("traffic_v2.json"))
    }

    private func loadDatabase() {
        if let data = try? Data(contentsOf: Self.storageURL()),
           let db = try? JSONDecoder().decode(TrafficDatabase.self, from: data) {
            database = db
        }
        // keep ~13 months
        if let cutoff = Calendar.current.date(byAdding: .day, value: -400, to: Date()) {
            let ck = Fmt.dayKey(cutoff)
            database.days = database.days.filter { $0.key >= ck }
        }
        if let rec = database.days[Fmt.dayKey(Date())] {
            todayInternet = rec.internet
            todayVPN = rec.vpn
        }
    }

    func saveDatabase() {
        if let data = try? JSONEncoder().encode(database) {
            try? data.write(to: Self.storageURL(), options: .atomic)
        }
    }

    func resetAllData() {
        database = TrafficDatabase(days: [:])
        todayInternet = ByteCounters()
        todayVPN = ByteCounters()
        appSession = [:]
        saveDatabase()
        refreshChartData()
        rebuildApps()
    }
}

// MARK: - Design system (minimal: one accent, system typography, hairlines)

enum Theme {
    static let rx = Color.accentColor
    static let tx = Color.gray
}

extension Font {
    static func num(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight).monospacedDigit()
    }
}

struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .medium))
            .tracking(0.7)
            .foregroundStyle(.secondary)
    }
}

// MARK: - Dashboard

struct DashboardView: View {
    @ObservedObject var monitor: NetworkMonitor

    var body: some View {
        VStack(spacing: 14) {
            HeaderView(monitor: monitor)

            Picker("", selection: $monitor.activeTab) {
                ForEach(ActiveTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Group {
                switch monitor.activeTab {
                case .charts: ChartsTabView(monitor: monitor)
                case .apps: AppsTabView(monitor: monitor)
                case .overview: TodayTabView(monitor: monitor)
                }
            }
            .frame(minHeight: 285, alignment: .top)

            Divider()
            FooterView(monitor: monitor)
        }
        .padding(16)
        .frame(width: 340)
        .onAppear {
            monitor.popoverVisible = true
            monitor.refreshChartData()
        }
        .onDisappear {
            monitor.popoverVisible = false
            monitor.endHover()
            monitor.saveDatabase()
        }
    }
}

struct HeaderView: View {
    @ObservedObject var monitor: NetworkMonitor

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            readout("Download", Fmt.speed(monitor.speedRX), .primary)
            readout("Upload", Fmt.speed(monitor.speedTX), .secondary)
            Spacer(minLength: 0)
            if monitor.vpnActive {
                Text("VPN")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.7)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.8))
            }
        }
    }

    private func readout(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Caption(title)
            Text(value)
                .font(.num(20, .medium))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(width: 125, alignment: .leading)
    }
}

// MARK: - Traffic tab

struct ChartsTabView: View {
    @ObservedObject var monitor: NetworkMonitor

    var body: some View {
        VStack(spacing: 10) {
            Picker("", selection: $monitor.selectedScope) {
                ForEach(TimeScope.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            ChartHeaderRow(monitor: monitor)

            if monitor.selectedScope == .minute {
                LiveChart(monitor: monitor)
                HStack {
                    Text("60s ago"); Spacer(); Text("now")
                }
                .font(.system(size: 9)).foregroundStyle(.tertiary)
            } else {
                HistoricalBarChart(monitor: monitor)
            }

            Divider().padding(.top, 2)
            SummaryRow(monitor: monitor)
        }
    }
}

struct ChartHeaderRow: View {
    @ObservedObject var monitor: NetworkMonitor

    private var hover: (title: String, rx: String, tx: String)? {
        if monitor.selectedScope == .minute, let s = monitor.hoveredSample {
            let last = monitor.displaySamples.last?.time ?? s.time
            let ago = max(0, Int(last.timeIntervalSince(s.time).rounded()))
            return (ago == 0 ? "now" : "\(ago)s ago", Fmt.speed(s.rx), Fmt.speed(s.tx))
        }
        if monitor.selectedScope != .minute, let b = monitor.hoveredBar {
            return (b.label, Fmt.bytes(b.rx), Fmt.bytes(b.tx))
        }
        return nil
    }

    var body: some View {
        HStack(spacing: 12) {
            if let h = hover {
                Text(h.title).fontWeight(.medium)
                Spacer()
                Text("↓ \(h.rx)").foregroundStyle(Theme.rx)
                Text("↑ \(h.tx)").foregroundStyle(.secondary)
            } else {
                Text(monitor.selectedScope.title).foregroundStyle(.secondary)
                Spacer()
                legend("Download", color: Theme.rx, filter: .download)
                legend("Upload", color: Theme.tx, filter: .upload)
            }
        }
        .font(.num(10))
        .frame(height: 16)
    }

    private func legend(_ name: String, color: Color, filter: ChartFilter) -> some View {
        let dimmed = monitor.selectedFilter != .all && monitor.selectedFilter != filter
        return Button {
            monitor.selectedFilter = (monitor.selectedFilter == filter) ? .all : filter
        } label: {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(name)
            }
            .opacity(dimmed ? 0.35 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Click to show only \(name.lowercased())")
    }
}

struct LiveChart: View {
    @ObservedObject var monitor: NetworkMonitor

    var body: some View {
        let data = monitor.displaySamples
        let end = data.last?.time ?? Date()
        let start = end.addingTimeInterval(-59)
        let peak = data.map { max($0.rx, $0.tx) }.max() ?? 0
        let ymax = max(peak * 1.25, 20_000)
        let showDL = monitor.selectedFilter != .upload
        let showUL = monitor.selectedFilter != .download

        Chart {
            ForEach(data) { p in
                if showDL {
                    AreaMark(x: .value("Time", p.time), y: .value("Speed", p.rx),
                             series: .value("Series", "Download"), stacking: .unstacked)
                        .interpolationMethod(.monotone)
                        .foregroundStyle(Theme.rx.opacity(0.10))
                    LineMark(x: .value("Time", p.time), y: .value("Speed", p.rx),
                             series: .value("Series", "Download"))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(Theme.rx)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                }
                if showUL {
                    LineMark(x: .value("Time", p.time), y: .value("Speed", p.tx),
                             series: .value("Series", "Upload"))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(Theme.tx)
                        .lineStyle(StrokeStyle(lineWidth: 1, lineJoin: .round))
                }
            }

            if let h = monitor.hoveredSample {
                RuleMark(x: .value("Hover", h.time))
                    .foregroundStyle(Color.primary.opacity(0.25))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                if showDL {
                    PointMark(x: .value("Hover", h.time), y: .value("Speed", h.rx))
                        .symbolSize(26).foregroundStyle(Theme.rx)
                }
                if showUL {
                    PointMark(x: .value("Hover", h.time), y: .value("Speed", h.tx))
                        .symbolSize(20).foregroundStyle(Theme.tx)
                }
            }
        }
        .chartXScale(domain: start...end)
        .chartYScale(domain: 0...ymax)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { v in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.primary.opacity(0.08))
                AxisValueLabel {
                    if let b = v.as(Double.self) {
                        Text(Fmt.speed(b)).font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(Color.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let loc):
                            let x = loc.x - geo[proxy.plotAreaFrame].origin.x
                            if let date: Date = proxy.value(atX: x) { monitor.hover(sampleNear: date) }
                        case .ended:
                            monitor.endHover()
                        }
                    }
            }
        }
        .frame(height: 140)
    }
}

struct HistoricalBarChart: View {
    @ObservedObject var monitor: NetworkMonitor

    var body: some View {
        let bars = monitor.bars
        let step = bars.count > 14 ? 4 : (bars.count > 8 ? 3 : 1)
        let tickLabels = bars.filter { $0.id % step == 0 }.map(\.label)
        let isEmpty = bars.allSatisfy { $0.total == 0 }

        Chart {
            ForEach(bars) { p in
                let dim = monitor.hoveredBarID != nil && monitor.hoveredBarID != p.id
                if monitor.selectedFilter != .upload {
                    BarMark(x: .value("Time", p.label), y: .value("Bytes", p.rx))
                        .foregroundStyle(by: .value("Type", "Download"))
                        .opacity(dim ? 0.35 : 1)
                        .cornerRadius(2)
                }
                if monitor.selectedFilter != .download {
                    BarMark(x: .value("Time", p.label), y: .value("Bytes", p.tx))
                        .foregroundStyle(by: .value("Type", "Upload"))
                        .opacity(dim ? 0.35 : 1)
                        .cornerRadius(2)
                }
            }
        }
        .chartForegroundStyleScale(["Download": Theme.rx, "Upload": Theme.tx.opacity(0.55)])
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(values: tickLabels) { _ in
                AxisValueLabel().font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        }
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { v in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.primary.opacity(0.08))
                AxisValueLabel {
                    if let b = v.as(Double.self) {
                        Text(Fmt.bytes(b)).font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(Color.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let loc):
                            let x = loc.x - geo[proxy.plotAreaFrame].origin.x
                            if let label: String = proxy.value(atX: x),
                               let p = monitor.bars.first(where: { $0.label == label }) {
                                monitor.hoveredBarID = p.id
                            }
                        case .ended:
                            monitor.hoveredBarID = nil
                        }
                    }
            }
        }
        .overlay {
            if isEmpty {
                Text("No data yet. History builds up while NetPulse runs.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .frame(height: 140)
    }
}

struct SummaryRow: View {
    @ObservedObject var monitor: NetworkMonitor

    var body: some View {
        let live = monitor.selectedScope == .minute
        let s = monitor.summary

        HStack(alignment: .top, spacing: 0) {
            stat("Download", live ? Fmt.speed(s.rx) : Fmt.bytes(s.rx))
            stat("Upload", live ? Fmt.speed(s.tx) : Fmt.bytes(s.tx))
            stat(live ? "Last 60s" : "Total", Fmt.bytes(s.total))
            stat("Peak", live ? Fmt.speed(s.peak) : Fmt.bytes(s.peak))
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Caption(title)
            Text(value).font(.num(12, .medium)).lineLimit(1).minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Apps tab

struct AppsTabView: View {
    @ObservedObject var monitor: NetworkMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Caption("Top apps")
                Spacer()
                Picker("", selection: $monitor.appMode) {
                    ForEach(AppMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 120)
            }

            if !monitor.appsLoaded {
                placeholder("Sampling…")
            } else if monitor.topApps.isEmpty {
                placeholder(monitor.appMode == .live ? "No app is using the network right now"
                                                     : "Nothing recorded this session yet")
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(monitor.topApps) { app in
                            AppRow(item: app, mode: monitor.appMode)
                            if app.id != monitor.topApps.last?.id { Divider() }
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .frame(maxHeight: 270)
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 200)
    }
}

struct AppRow: View {
    let item: AppUsageItem
    let mode: AppMode

    var body: some View {
        let live = mode == .live
        let rx = live ? Fmt.speed(item.rxRate) : Fmt.bytes(item.rxSession)
        let tx = live ? Fmt.speed(item.txRate) : Fmt.bytes(item.txSession)
        let total = live ? Fmt.speed(item.rateTotal) : Fmt.bytes(item.sessionTotal)

        HStack(spacing: 10) {
            Group {
                if let icon = item.icon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: item.symbol)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(.system(size: 12)).lineLimit(1)
                Text("↓ \(rx)   ↑ \(tx)").font(.num(10)).foregroundStyle(.secondary)
            }
            Spacer()
            Text(total).font(.num(12, .medium))
        }
        .padding(.vertical, 7)
    }
}

// MARK: - Today tab

struct TodayTabView: View {
    @ObservedObject var monitor: NetworkMonitor

    var body: some View {
        let ins = monitor.insights()
        let capBytes = monitor.dailyCapGB * 1_000_000_000

        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Caption("Today")
                Text(Fmt.bytes(monitor.todayInternet.total))
                    .font(.system(size: 34, weight: .light)).monospacedDigit()
                HStack(spacing: 14) {
                    Text("↓ \(Fmt.bytes(monitor.todayInternet.rx))").foregroundStyle(Theme.rx)
                    Text("↑ \(Fmt.bytes(monitor.todayInternet.tx))").foregroundStyle(.secondary)
                }
                .font(.num(11))
            }

            if capBytes > 0 {
                let frac = Double(monitor.todayInternet.total) / capBytes
                VStack(alignment: .leading, spacing: 5) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.08))
                            Capsule().fill(frac >= 1 ? Color.red : Theme.rx)
                                .frame(width: geo.size.width * min(1, frac))
                        }
                    }
                    .frame(height: 3)
                    Text("\(Int(frac * 100))% of \(Int(monitor.dailyCapGB)) GB daily limit")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 0) {
                Divider()
                row("vs yesterday", ins.vsYesterday.map { String(format: "%+.0f%%", $0) } ?? "–")
                Divider()
                row("7-day average", ins.weekAverage > 0 ? Fmt.bytes(ins.weekAverage) : "–")
                Divider()
                row("Busiest hour", ins.busiestHour.map { "\($0) · \(Fmt.bytes(ins.busiestBytes))" } ?? "–")
                Divider()
                row("VPN", monitor.vpnActive ? "On · \(Fmt.bytes(monitor.todayVPN.total))" : "Off")
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.num(12, .medium))
        }
        .font(.system(size: 12))
        .padding(.vertical, 8)
    }
}

// MARK: - Footer

struct FooterView: View {
    @ObservedObject var monitor: NetworkMonitor

    var body: some View {
        HStack(spacing: 14) {
            Button {
                if monitor.confirmReset { monitor.resetAllData(); monitor.confirmReset = false }
                else {
                    monitor.confirmReset = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        monitor.confirmReset = false
                    }
                }
            } label: {
                Text(monitor.confirmReset ? "Tap again to confirm" : "Reset")
            }
            .buttonStyle(.plain)
            .foregroundStyle(monitor.confirmReset ? Color.red : Color.secondary)

            Spacer()

            Menu {
                Toggle("Show speeds in bits", isOn: $monitor.useBits)
                Toggle("Live speed in menu bar", isOn: $monitor.menuBarShowsSpeed)
                Toggle("Launch at login", isOn: $monitor.launchAtLogin)
                Picker("Daily limit", selection: $monitor.dailyCapGB) {
                    Text("No limit").tag(0.0)
                    Text("5 GB").tag(5.0)
                    Text("10 GB").tag(10.0)
                    Text("20 GB").tag(20.0)
                    Text("50 GB").tag(50.0)
                }
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.secondary)

            Button("Quit") {
                monitor.saveDatabase()
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .font(.system(size: 11))
    }
}

// MARK: - App

@main
struct NetPulseApp: App {
    @StateObject private var monitor = NetworkMonitor()

    var body: some Scene {
        MenuBarExtra {
            DashboardView(monitor: monitor)
        } label: {
            Text(monitor.menuBarTitle).monospacedDigit()
        }
        .menuBarExtraStyle(.window)
    }
}
