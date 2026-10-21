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
    case minute = "Live", hourly = "Hourly", daily = "Daily", weekly = "Weekly", monthly = "Monthly"
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
    case charts = "Charts", apps = "Apps", overview = "Overview"
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

// MARK: - Reusable UI pieces

enum Theme {
    static let rx = Color.cyan
    static let tx = Color.purple
}

extension View {
    func glassCard(radius: CGFloat = 14) -> some View {
        self
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.8))
    }
}

struct PillBar<Item: Hashable>: View {
    let items: [Item]
    @Binding var selection: Item
    let title: (Item) -> String
    var icon: ((Item) -> String)? = nil
    var fontSize: CGFloat = 11

    var body: some View {
        HStack(spacing: 3) {
            ForEach(items, id: \.self) { item in
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { selection = item }
                } label: {
                    HStack(spacing: 4) {
                        if let icon = icon {
                            Image(systemName: icon(item)).font(.system(size: fontSize - 2, weight: .semibold))
                        }
                        Text(title(item)).font(.system(size: fontSize, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background {
                        if selection == item {
                            Capsule()
                                .fill(LinearGradient(colors: [.blue, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
                                .shadow(color: Color.blue.opacity(0.4), radius: 4, y: 1)
                        }
                    }
                    .foregroundStyle(selection == item ? Color.white : Color.secondary)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2.5)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 0.8))
    }
}

struct PulsingDot: View {
    let color: Color

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.5) / 1.5
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .overlay(
                    Circle()
                        .stroke(color.opacity(max(0, 0.8 - phase * 0.8)), lineWidth: 1.2)
                        .scaleEffect(1.0 + CGFloat(phase) * 1.6)
                )
                .shadow(color: color.opacity(0.8), radius: 3)
        }
    }
}

// MARK: - Dashboard

struct DashboardView: View {
    @ObservedObject var monitor: NetworkMonitor

    var body: some View {
        ZStack {
            GeometryReader { geo in
                Circle().fill(Color.blue.opacity(0.12)).frame(width: 220, height: 220)
                    .blur(radius: 60).offset(x: -40, y: -40)
                Circle().fill(Color.purple.opacity(0.10)).frame(width: 200, height: 200)
                    .blur(radius: 50).offset(x: geo.size.width - 130, y: 150)
            }
            .allowsHitTesting(false)

            VStack(spacing: 12) {
                HeaderView(monitor: monitor)

                PillBar(items: ActiveTab.allCases, selection: $monitor.activeTab,
                        title: { $0.rawValue }, icon: { $0.icon }, fontSize: 12)

                Group {
                    switch monitor.activeTab {
                    case .charts: ChartsTabView(monitor: monitor)
                    case .apps: AppsTabView(monitor: monitor)
                    case .overview: OverviewTabView(monitor: monitor)
                    }
                }

                Divider().opacity(0.6)
                FooterView(monitor: monitor)
            }
            .padding(14)
        }
        .frame(width: 440)
        .background(.ultraThinMaterial)
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

struct AppHeaderLogo: View {
    private var logoImage: NSImage? {
        if let url = Bundle.main.url(forResource: "AppLogo", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        let devPath = "/Users/elyananasiri/NetPulseProject/assets/logo.png"
        if FileManager.default.fileExists(atPath: devPath),
           let img = NSImage(contentsOfFile: devPath) {
            return img
        }
        return nil
    }

    var body: some View {
        if let img = logoImage {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.8)
                )
                .shadow(color: Color.blue.opacity(0.35), radius: 4, y: 1)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(LinearGradient(colors: [Color.blue.opacity(0.3), Color.purple.opacity(0.2)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 34, height: 34)
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.blue.opacity(0.4), lineWidth: 1))
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(LinearGradient(colors: [.cyan, .blue], startPoint: .top, endPoint: .bottom))
            }
        }
    }
}

struct HeaderView: View {
    @ObservedObject var monitor: NetworkMonitor

    var body: some View {
        HStack(spacing: 10) {
            AppHeaderLogo()

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("NetPulse").font(.system(size: 15, weight: .bold, design: .rounded))
                    Text("PRO")
                        .font(.system(size: 9, weight: .heavy, design: .rounded))
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .background(LinearGradient(colors: [Color.blue.opacity(0.3), Color.purple.opacity(0.3)],
                                                   startPoint: .leading, endPoint: .trailing), in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.blue.opacity(0.5), lineWidth: 0.8))
                }
                Text("Live network & traffic monitor")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 7) {
                PulsingDot(color: monitor.vpnActive ? .green : .cyan)
                Text(monitor.vpnActive ? "VPN · \(monitor.vpnName ?? "tunnel")" : "Direct")
                    .font(.system(size: 10, weight: .medium))
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.8))
        }
    }
}

// MARK: - Charts tab

struct ChartsTabView: View {
    @ObservedObject var monitor: NetworkMonitor

    var body: some View {
        VStack(spacing: 10) {
            PillBar(items: TimeScope.allCases, selection: $monitor.selectedScope,
                    title: { $0.rawValue }, icon: { $0.icon })

            HStack {
                PillBar(items: ChartFilter.allCases, selection: $monitor.selectedFilter,
                        title: { $0.rawValue }, fontSize: 10)
                    .frame(width: 200)
                Spacer()
                HStack(spacing: 8) {
                    Label(Fmt.speed(monitor.speedRX), systemImage: "arrow.down").foregroundStyle(Theme.rx)
                    Label(Fmt.speed(monitor.speedTX), systemImage: "arrow.up").foregroundStyle(Theme.tx)
                }
                .labelStyle(CompactLabelStyle())
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 0.8))
            }

            SummaryGrid(monitor: monitor)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    HStack(spacing: 5) {
                        Image(systemName: "chart.xyaxis.line").foregroundStyle(.blue).font(.caption)
                        Text(monitor.selectedScope.title)
                            .font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    HStack(spacing: 10) {
                        HStack(spacing: 4) { Circle().fill(Theme.rx).frame(width: 6, height: 6)
                            Text("Download").font(.system(size: 10)).foregroundStyle(.secondary) }
                        HStack(spacing: 4) { Circle().fill(Theme.tx).frame(width: 6, height: 6)
                            Text("Upload").font(.system(size: 10)).foregroundStyle(.secondary) }
                    }
                }

                InspectionBanner(monitor: monitor)

                if monitor.selectedScope == .minute {
                    LiveChart(monitor: monitor)
                } else {
                    HistoricalBarChart(monitor: monitor)
                }
            }
            .padding(12)
            .glassCard()
            .shadow(color: Color.black.opacity(0.15), radius: 8, y: 3)
        }
    }
}

struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.font(.system(size: 9, weight: .bold))
            configuration.title
        }
    }
}

struct InspectionBanner: View {
    @ObservedObject var monitor: NetworkMonitor

    var body: some View {
        Group {
            if monitor.selectedScope == .minute, let s = monitor.hoveredSample {
                row(title: "\(max(0, Int((monitor.displaySamples.last?.time ?? s.time).timeIntervalSince(s.time).rounded())))s ago",
                    rx: Fmt.speed(s.rx), tx: Fmt.speed(s.tx), total: Fmt.speed(s.total), tint: .blue)
            } else if monitor.selectedScope != .minute, let b = monitor.hoveredBar {
                row(title: b.label, rx: Fmt.bytes(b.rx), tx: Fmt.bytes(b.tx), total: Fmt.bytes(b.total), tint: .purple)
            } else {
                HStack(spacing: 5) {
                    Image(systemName: "cursorarrow.motionlines").font(.system(size: 9)).foregroundStyle(.secondary)
                    Text("Hover over the chart to inspect exact values")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                    Spacer()
                }
                .padding(.horizontal, 4).frame(height: 22)
            }
        }
    }

    private func row(title: String, rx: String, tx: String, total: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 10, weight: .bold))
            Spacer()
            Text("↓ \(rx)").foregroundStyle(Theme.rx)
            Text("↑ \(tx)").foregroundStyle(Theme.tx)
            Text("Σ \(total)").fontWeight(.bold)
        }
        .font(.system(size: 10, weight: .semibold, design: .monospaced))
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(tint.opacity(0.3), lineWidth: 0.8))
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
                        .foregroundStyle(LinearGradient(colors: [Theme.rx.opacity(0.4), Color.blue.opacity(0.12), .clear],
                                                        startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Time", p.time), y: .value("Speed", p.rx),
                             series: .value("Series", "Download"))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(LinearGradient(colors: [Theme.rx, .blue], startPoint: .leading, endPoint: .trailing))
                        .lineStyle(StrokeStyle(lineWidth: 2))
                }
                if showUL {
                    AreaMark(x: .value("Time", p.time), y: .value("Speed", p.tx),
                             series: .value("Series", "Upload"), stacking: .unstacked)
                        .interpolationMethod(.monotone)
                        .foregroundStyle(LinearGradient(colors: [Theme.tx.opacity(0.35), Color.pink.opacity(0.1), .clear],
                                                        startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Time", p.time), y: .value("Speed", p.tx),
                             series: .value("Series", "Upload"))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(LinearGradient(colors: [Theme.tx, .pink], startPoint: .leading, endPoint: .trailing))
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
            }

            if let h = monitor.hoveredSample {
                RuleMark(x: .value("Hover", h.time))
                    .foregroundStyle(Color.white.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
                if showDL {
                    PointMark(x: .value("Hover", h.time), y: .value("Speed", h.rx))
                        .symbolSize(40).foregroundStyle(Theme.rx)
                }
                if showUL {
                    PointMark(x: .value("Hover", h.time), y: .value("Speed", h.tx))
                        .symbolSize(34).foregroundStyle(Theme.tx)
                }
            }
        }
        .chartXScale(domain: start...end)
        .chartYScale(domain: 0...ymax)
        .chartXAxis {
            AxisMarks(values: .stride(by: .second, count: 15)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 2])).foregroundStyle(Color.white.opacity(0.1))
                AxisValueLabel(format: Date.FormatStyle.dateTime.hour().minute().second())
                    .font(.system(size: 9))
            }
        }
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { v in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 2])).foregroundStyle(Color.white.opacity(0.1))
                AxisValueLabel {
                    if let b = v.as(Double.self) {
                        Text(Fmt.speed(b)).font(.system(size: 9)).foregroundStyle(.secondary)
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
        .frame(height: 185)
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
                        .cornerRadius(3)
                }
                if monitor.selectedFilter != .download {
                    BarMark(x: .value("Time", p.label), y: .value("Bytes", p.tx))
                        .foregroundStyle(by: .value("Type", "Upload"))
                        .opacity(dim ? 0.35 : 1)
                        .cornerRadius(3)
                }
            }
        }
        .chartForegroundStyleScale(["Download": Theme.rx, "Upload": Theme.tx])
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(values: tickLabels) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 2])).foregroundStyle(Color.white.opacity(0.1))
                AxisValueLabel().font(.system(size: 9))
            }
        }
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { v in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 2])).foregroundStyle(Color.white.opacity(0.1))
                AxisValueLabel {
                    if let b = v.as(Double.self) {
                        Text(Fmt.bytes(b)).font(.system(size: 9)).foregroundStyle(.secondary)
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
                VStack(spacing: 4) {
                    Image(systemName: "chart.bar.xaxis").font(.system(size: 18)).foregroundStyle(.tertiary)
                    Text("No data yet. History builds up while NetPulse runs.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(height: 185)
    }
}

struct SummaryGrid: View {
    @ObservedObject var monitor: NetworkMonitor

    private var metrics: (dl: String, ul: String, tot: String, peak: String) {
        let live = monitor.selectedScope == .minute
        let s = monitor.summary
        let hs = live ? monitor.hoveredSample : nil
        let hb = live ? nil : monitor.hoveredBar

        if let h = hs {
            return (Fmt.speed(h.rx), Fmt.speed(h.tx), Fmt.speed(h.total), "Inspecting")
        } else if let b = hb {
            return (Fmt.bytes(b.rx), Fmt.bytes(b.tx), Fmt.bytes(b.total), "Inspecting")
        } else if live {
            return (Fmt.speed(s.rx), Fmt.speed(s.tx), Fmt.bytes(s.total), Fmt.speed(s.peak))
        } else {
            return (Fmt.bytes(s.rx), Fmt.bytes(s.tx), Fmt.bytes(s.total), Fmt.bytes(s.peak))
        }
    }

    var body: some View {
        let live = monitor.selectedScope == .minute
        let inspecting = (live ? monitor.hoveredSample : nil) != nil || (live ? nil : monitor.hoveredBar) != nil
        let m = metrics

        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 7) {
            SummaryCard(title: live ? "Download" : "Total download", value: m.dl, icon: "arrow.down.circle.fill",
                        gradient: [Theme.rx, .blue], inspecting: inspecting)
            SummaryCard(title: live ? "Upload" : "Total upload", value: m.ul, icon: "arrow.up.circle.fill",
                        gradient: [Theme.tx, .pink], inspecting: inspecting)
            SummaryCard(title: live ? (inspecting ? "Combined" : "Last 60s") : "Total traffic", value: m.tot,
                        icon: "globe.americas.fill", gradient: [.teal, .cyan], inspecting: inspecting)
            SummaryCard(title: inspecting ? "Mode" : (live ? "Peak speed" : "Busiest period"), value: m.peak,
                        icon: inspecting ? "viewfinder" : "bolt.fill",
                        gradient: inspecting ? [.green, .mint] : [.orange, .red], inspecting: inspecting)
        }
    }
}

struct SummaryCard: View {
    let title: String
    let value: String
    let icon: String
    let gradient: [Color]
    var inspecting = false

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                Circle().fill(gradient[0].opacity(0.18)).frame(width: 28, height: 28)
                Image(systemName: icon).font(.system(size: 13, weight: .bold))
                    .foregroundStyle(LinearGradient(colors: gradient, startPoint: .top, endPoint: .bottom))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 9.5)).foregroundStyle(.secondary)
                Text(value).font(.system(size: 13, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(inspecting ? gradient[0] : Color.primary).lineLimit(1).minimumScaleFactor(0.8)
            }
            Spacer()
        }
        .padding(.horizontal, 9).padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(inspecting ? gradient[0].opacity(0.4) : Color.white.opacity(0.08), lineWidth: 1))
    }
}

// MARK: - Apps tab

struct AppsTabView: View {
    @ObservedObject var monitor: NetworkMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                HStack(spacing: 5) {
                    Image(systemName: "flame.fill").foregroundStyle(.orange)
                    Text("Top network apps").font(.system(size: 12, weight: .bold))
                }
                Spacer()
                PillBar(items: AppMode.allCases, selection: $monitor.appMode, title: { $0.rawValue }, fontSize: 10)
                    .frame(width: 130)
            }

            if !monitor.appsLoaded {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Sampling per-app traffic…").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 32)
            } else if monitor.topApps.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "moon.zzz").font(.system(size: 20)).foregroundStyle(.tertiary)
                    Text(monitor.appMode == .live ? "No app is using the network right now"
                                                  : "Nothing recorded this session yet")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 32)
            } else {
                let maxValue = monitor.appMode == .live
                    ? (monitor.topApps.first?.rateTotal ?? 1)
                    : Double(monitor.topApps.first?.sessionTotal ?? 1)
                ScrollView {
                    VStack(spacing: 7) {
                        ForEach(monitor.topApps) { app in
                            AppUsageRow(item: app, mode: monitor.appMode, maxValue: max(maxValue, 1))
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .frame(maxHeight: 300)
            }
        }
        .padding(12)
        .glassCard()
    }
}

struct AppUsageRow: View {
    let item: AppUsageItem
    let mode: AppMode
    let maxValue: Double

    var body: some View {
        let rx = mode == .live ? item.rxRate : Double(item.rxSession)
        let tx = mode == .live ? item.txRate : Double(item.txSession)

        VStack(spacing: 5) {
            HStack(spacing: 8) {
                Group {
                    if let icon = item.icon {
                        Image(nsImage: icon).resizable().frame(width: 22, height: 22)
                    } else {
                        ZStack {
                            RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.18))
                            Image(systemName: item.symbol).font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                        }
                        .frame(width: 22, height: 22)
                    }
                }
                Text(item.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer()
                HStack(spacing: 7) {
                    Text("↓\(mode == .live ? Fmt.speed(rx) : Fmt.bytes(rx))").foregroundStyle(Theme.rx)
                    Text("↑\(mode == .live ? Fmt.speed(tx) : Fmt.bytes(tx))").foregroundStyle(Theme.tx)
                }
                .font(.system(size: 10, design: .monospaced))
            }

            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.06))
                    HStack(spacing: 1) {
                        Capsule().fill(LinearGradient(colors: [.cyan, .blue], startPoint: .leading, endPoint: .trailing))
                            .frame(width: rx > 0 ? max(3, w * CGFloat(rx / maxValue)) : 0)
                        Capsule().fill(LinearGradient(colors: [.purple, .pink], startPoint: .leading, endPoint: .trailing))
                            .frame(width: tx > 0 ? max(2, w * CGFloat(tx / maxValue)) : 0)
                    }
                }
            }
            .frame(height: 5)
            .animation(.easeOut(duration: 0.3), value: rx + tx)
        }
        .padding(.horizontal, 9).padding(.vertical, 7)
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 9))
    }
}

// MARK: - Overview tab

struct OverviewTabView: View {
    @ObservedObject var monitor: NetworkMonitor

    var body: some View {
        let ins = monitor.insights()
        let capBytes = monitor.dailyCapGB * 1_000_000_000

        VStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Today", systemImage: "globe.americas.fill")
                        .font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                    Spacer()
                    HStack(spacing: 5) {
                        Circle().fill(Color.green).frame(width: 6, height: 6)
                        Text("Real-time").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.green)
                    }
                }
                Text(Fmt.bytes(monitor.todayInternet.total))
                    .font(.system(size: 32, weight: .heavy, design: .rounded)).monospacedDigit()
                HStack(spacing: 16) {
                    HStack(spacing: 5) { Circle().fill(Theme.rx).frame(width: 6, height: 6)
                        Text("↓ \(Fmt.bytes(monitor.todayInternet.rx))") }
                    HStack(spacing: 5) { Circle().fill(Theme.tx).frame(width: 6, height: 6)
                        Text("↑ \(Fmt.bytes(monitor.todayInternet.tx))") }
                }
                .font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)

                if capBytes > 0 {
                    let frac = min(1, Double(monitor.todayInternet.total) / capBytes)
                    VStack(alignment: .leading, spacing: 4) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.primary.opacity(0.08))
                                Capsule()
                                    .fill(LinearGradient(colors: frac > 0.9 ? [.orange, .red] : [.cyan, .blue],
                                                         startPoint: .leading, endPoint: .trailing))
                                    .frame(width: geo.size.width * frac)
                            }
                        }
                        .frame(height: 6)
                        Text("\(Int(frac * 100))% of \(Int(monitor.dailyCapGB)) GB daily limit")
                            .font(.system(size: 9.5)).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(14).glassCard()

            HStack(spacing: 8) {
                InsightTile(icon: ins.vsYesterday.map { $0 >= 0 ? "arrow.up.right" : "arrow.down.right" } ?? "minus",
                            title: "vs yesterday",
                            value: ins.vsYesterday.map { String(format: "%+.0f%%", $0) } ?? "–",
                            tint: (ins.vsYesterday ?? 0) > 0 ? .orange : .green)
                InsightTile(icon: "calendar", title: "7-day avg",
                            value: ins.weekAverage > 0 ? Fmt.bytes(ins.weekAverage) : "–", tint: .blue)
                InsightTile(icon: "clock.fill", title: "Busiest hour",
                            value: ins.busiestHour ?? "–", tint: .purple)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("VPN tunnel", systemImage: "lock.shield.fill")
                        .font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                    Spacer()
                    Text(monitor.vpnActive ? "Connected" : "Not connected")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(monitor.vpnActive ? .green : .secondary)
                }
                Text(Fmt.bytes(monitor.todayVPN.total)).font(.system(size: 20, weight: .bold, design: .rounded))
                HStack(spacing: 16) {
                    Text("↓ \(Fmt.bytes(monitor.todayVPN.rx))").foregroundStyle(Theme.rx.opacity(0.85))
                    Text("↑ \(Fmt.bytes(monitor.todayVPN.tx))").foregroundStyle(Theme.tx.opacity(0.85))
                }
                .font(.system(size: 10, design: .monospaced))
            }
            .padding(12).glassCard()
        }
    }
}

struct InsightTile: View {
    let icon: String
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 9, weight: .bold)).foregroundStyle(tint)
                Text(title).font(.system(size: 9.5)).foregroundStyle(.secondary)
            }
            Text(value).font(.system(size: 14, weight: .bold, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .glassCard(radius: 10)
    }
}

// MARK: - Footer

struct FooterView: View {
    @ObservedObject var monitor: NetworkMonitor
    

    var body: some View {
        HStack(spacing: 10) {
            Button(role: .destructive) {
                if monitor.confirmReset { monitor.resetAllData(); monitor.confirmReset = false }
                else {
                    monitor.confirmReset = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { monitor.confirmReset = false }
                }
            } label: {
                Label(monitor.confirmReset ? "Tap again to confirm" : "Reset", systemImage: "arrow.counterclockwise")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(monitor.confirmReset ? Color.red : Color.secondary)

            Menu {
                Toggle("Show speeds in bits (Mbps)", isOn: $monitor.useBits)
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
                Image(systemName: "gearshape").font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            Spacer()

            Button {
                monitor.saveDatabase()
                NSApplication.shared.terminate(nil)
            } label: {
                HStack(spacing: 4) { Image(systemName: "power"); Text("Quit") }
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
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
            HStack(spacing: 4) {
                Image(systemName: "waveform.path.ecg")
                Text(monitor.menuBarTitle).monospacedDigit()
            }
        }
        .menuBarExtraStyle(.window)
    }
}
