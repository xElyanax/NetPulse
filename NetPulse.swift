import SwiftUI
import Charts
import Foundation
import Darwin
import AppKit

// MARK: - Data Models

enum AppSortMode: String, CaseIterable, Identifiable {
    case total = "Total Today"
    case liveSpeed = "Live Speed"
    var id: String { rawValue }
}

struct AppUsageItem: Identifiable, Codable, Equatable {
    var id: String { name }
    let name: String
    var rxBytes: UInt64
    var txBytes: UInt64
    var currentRxSpeed: UInt64 = 0
    var currentTxSpeed: UInt64 = 0
    var totalBytes: UInt64 { rxBytes + txBytes }
    var currentSpeed: UInt64 { currentRxSpeed + currentTxSpeed }

    var iconName: String {
        let lower = name.lowercased()
        if lower.contains("safari") { return "safari.fill" }
        if lower.contains("chrome") { return "globe" }
        if lower.contains("firefox") { return "flame.fill" }
        if lower.contains("edge") { return "network" }
        if lower.contains("arc") || lower.contains("brave") { return "globe.americas.fill" }
        if lower.contains("telegram") { return "paperplane.fill" }
        if lower.contains("whatsapp") { return "phone.fill" }
        if lower.contains("signal") { return "lock.message.fill" }
        if lower.contains("discord") { return "bubble.left.and.bubble.right.fill" }
        if lower.contains("slack") { return "number" }
        if lower.contains("spotify") || lower.contains("music") { return "music.note" }
        if lower.contains("vs code") || lower.contains("code") || lower.contains("cursor") { return "chevron.left.forwardslash.chevron.right" }
        if lower.contains("xcode") { return "hammer.fill" }
        if lower.contains("antigravity") { return "cpu.fill" }
        if lower.contains("terminal") { return "terminal.fill" }
        if lower.contains("vpn") || lower.contains("tunnel") { return "lock.shield.fill" }
        if lower.contains("system") { return "apple.logo" }
        if lower.contains("zoom") { return "video.fill" }
        if lower.contains("cloud") || lower.contains("dropbox") || lower.contains("onedrive") { return "icloud.fill" }
        if lower.contains("adobe") { return "paintbrush.fill" }
        return "app.dashed"
    }

    var iconColor: Color {
        let lower = name.lowercased()
        if lower.contains("safari") { return .blue }
        if lower.contains("chrome") { return .red }
        if lower.contains("firefox") { return .orange }
        if lower.contains("edge") { return .teal }
        if lower.contains("telegram") { return .cyan }
        if lower.contains("whatsapp") { return .green }
        if lower.contains("discord") { return .indigo }
        if lower.contains("slack") { return .purple }
        if lower.contains("spotify") { return .green }
        if lower.contains("music") { return .pink }
        if lower.contains("vs code") { return .blue }
        if lower.contains("xcode") { return .blue }
        if lower.contains("antigravity") { return .purple }
        if lower.contains("terminal") { return .green }
        if lower.contains("vpn") { return .mint }
        if lower.contains("system") { return .gray }
        if lower.contains("zoom") { return .blue }
        return .accentColor
    }
}

struct ByteCounters: Codable {
    var rx: UInt64 = 0
    var tx: UInt64 = 0
    var total: UInt64 { rx + tx }
}

struct DayRecord: Codable {
    var dateKey: String                    // "yyyy-MM-dd"
    var internet: ByteCounters
    var vpn: ByteCounters
    var hourly: [String: ByteCounters]     // keys: "00", "01", ... "23"
    var appUsage: [String: ByteCounters]?  // "Google Chrome": { rx, tx }
}

struct TrafficDatabase: Codable {
    var days: [String: DayRecord]
}

struct MinuteSpeedPoint: Identifiable, Equatable {
    let id = UUID()
    let index: Int
    let rxSpeed: Double
    let txSpeed: Double
    var totalSpeed: Double { rxSpeed + txSpeed }
}

struct ChartBarPoint: Identifiable, Equatable {
    let id = UUID()
    let index: Int
    let label: String
    let rx: Double
    let tx: Double
    var total: Double { rx + tx }
}

enum TimeScope: String, CaseIterable, Identifiable {
    case minute = "Minute"
    case hourly = "Hourly"
    case daily = "Daily"
    case weekly = "Weekly"
    case monthly = "Monthly"

    var id: String { rawValue }

    var titleEnglish: String {
        switch self {
        case .minute: return "Live (60s)"
        case .hourly: return "Past 24 Hours"
        case .daily: return "Past 14 Days"
        case .weekly: return "Past 8 Weeks"
        case .monthly: return "Past 6 Months"
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
    case all = "All"
    case download = "Download"
    case upload = "Upload"

    var id: String { rawValue }
}

enum ActiveTab: String, CaseIterable, Identifiable {
    case charts = "Charts"
    case apps = "Apps"
    case overview = "Overview"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .charts: return "chart.xyaxis.line"
        case .apps: return "app.badge.checkmark"
        case .overview: return "gauge.with.needle.fill"
        }
    }
}

// MARK: - Core Engine

@MainActor
final class NetworkMonitor: ObservableObject {
    @Published var activeTab: ActiveTab = .charts
    @Published var selectedScope: TimeScope = .minute {
        didSet {
            hoveredBarPoint = nil
            hoveredMinutePoint = nil
            refreshChartData()
        }
    }
    @Published var selectedFilter: ChartFilter = .all
    @Published var appSortMode: AppSortMode = .total {
        didSet { resortTopApps() }
    }

    @Published var speedRX: UInt64 = 0
    @Published var speedTX: UInt64 = 0
    @Published var isVPNActive: Bool = false

    @Published var todayInternet = ByteCounters()
    @Published var todayVPN = ByteCounters()

    @Published var minutePoints: [MinuteSpeedPoint] = []
    @Published var chartPoints: [ChartBarPoint] = []

    // Hover Inspection States
    @Published var hoveredMinutePoint: MinuteSpeedPoint? = nil
    @Published var hoveredBarPoint: ChartBarPoint? = nil

    @Published var summaryDownload: String = "0 B"
    @Published var summaryUpload: String = "0 B"
    @Published var summaryTotal: String = "0 B"
    @Published var summaryPeak: String = "0 B"

    // Real App Traffic Records
    @Published var topApps: [AppUsageItem] = []
    private var appCumulativeUsage: [String: ByteCounters] = [:]
    private var appLiveSpeeds: [String: (rx: UInt64, tx: UInt64)] = [:]
    private var previousNettopRaw: [String: (rx: UInt64, tx: UInt64)] = [:]

    private var database = TrafficDatabase(days: [:])
    private var previousSnapshot: [String: ByteCounters] = [:]
    private var timer: Timer?
    private var processTimer: Timer?
    private var tickCounter: Int = 0

    init() {
        minutePoints = (0..<60).map { i in
            MinuteSpeedPoint(index: i, rxSpeed: 0, txSpeed: 0)
        }

        loadDatabase()
        previousSnapshot = Self.captureSnapshot()
        refreshChartData()

        // 1-second system interface tick
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }

        // 2-second per-process nettop sampling
        processTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { await self?.updateProcessStats() }
        }
        Task { await updateProcessStats() }
    }

    var menuBarTitle: String {
        if speedRX > 1024 || speedTX > 1024 {
            return "↓\(Self.formatCompact(speedRX))/s  ↑\(Self.formatCompact(speedTX))/s"
        } else {
            return Self.formatCompact(todayInternet.total)
        }
    }

    // MARK: - Tick Loop
    private func tick() {
        checkDayRollover()
        let current = Self.captureSnapshot()

        var deltaPhys = ByteCounters()
        var deltaTunnel = ByteCounters()

        for (name, count) in current {
            guard let old = previousSnapshot[name] else { continue }
            guard count.rx >= old.rx, count.tx >= old.tx else { continue }

            let rx = count.rx - old.rx
            let tx = count.tx - old.tx

            if name == "en0" || name.hasPrefix("en") {
                deltaPhys.rx += rx
                deltaPhys.tx += tx
            } else if name.hasPrefix("utun") {
                deltaTunnel.rx += rx
                deltaTunnel.tx += tx
            }
        }

        previousSnapshot = current
        speedRX = deltaPhys.rx
        speedTX = deltaPhys.tx
        isVPNActive = (deltaTunnel.rx + deltaTunnel.tx) > 0

        // Sliding 60-point window
        var newMinutes = minutePoints
        if newMinutes.count >= 60 {
            newMinutes.removeFirst()
        }
        newMinutes.append(
            MinuteSpeedPoint(
                index: 59,
                rxSpeed: Double(deltaPhys.rx),
                txSpeed: Double(deltaPhys.tx)
            )
        )
        for i in 0..<newMinutes.count {
            newMinutes[i] = MinuteSpeedPoint(
                index: i,
                rxSpeed: newMinutes[i].rxSpeed,
                txSpeed: newMinutes[i].txSpeed
            )
        }
        minutePoints = newMinutes

        // Accumulate today
        todayInternet.rx += deltaPhys.rx
        todayInternet.tx += deltaPhys.tx
        todayVPN.rx += deltaTunnel.rx
        todayVPN.tx += deltaTunnel.tx

        // Accumulate hourly
        let currentDayKey = Self.currentDateKey()
        let currentHourKey = Self.currentHourKey()
        var dayRecord = database.days[currentDayKey] ?? DayRecord(
            dateKey: currentDayKey,
            internet: ByteCounters(),
            vpn: ByteCounters(),
            hourly: [:],
            appUsage: [:]
        )
        dayRecord.internet = todayInternet
        dayRecord.vpn = todayVPN

        var hourCounters = dayRecord.hourly[currentHourKey] ?? ByteCounters()
        hourCounters.rx += deltaPhys.rx
        hourCounters.tx += deltaPhys.tx
        dayRecord.hourly[currentHourKey] = hourCounters
        dayRecord.appUsage = appCumulativeUsage
        database.days[currentDayKey] = dayRecord

        tickCounter += 1
        if tickCounter % 10 == 0 {
            saveDatabase()
        }

        if selectedScope == .minute || selectedScope == .hourly {
            refreshChartData()
        }
    }

    // MARK: - Process Traffic Tracking Engine
    private func updateProcessStats() async {
        let rawSnapshot = await Task.detached(priority: .utility) {
            return Self.runNettopSample()
        }.value

        guard !rawSnapshot.isEmpty else { return }

        // If this is the very first sample and cumulative usage is empty, initialize baseline
        if previousNettopRaw.isEmpty {
            previousNettopRaw = rawSnapshot
            if appCumulativeUsage.isEmpty {
                for (proc, counts) in rawSnapshot {
                    let cname = Self.cleanAppName(proc)
                    var curr = appCumulativeUsage[cname] ?? ByteCounters()
                    curr.rx += counts.rx
                    curr.tx += counts.tx
                    appCumulativeUsage[cname] = curr
                }
            }
            resortTopApps()
            return
        }

        // Calculate deltas across raw processes
        var currentIntervalSpeeds: [String: (rx: UInt64, tx: UInt64)] = [:]

        for (proc, currentCounts) in rawSnapshot {
            let prevCounts = previousNettopRaw[proc] ?? (rx: 0, tx: 0)

            // Delta computation: if connection reset or PID restarted, treat current as new delta
            let drx = currentCounts.rx >= prevCounts.rx ? (currentCounts.rx - prevCounts.rx) : currentCounts.rx
            let dtx = currentCounts.tx >= prevCounts.tx ? (currentCounts.tx - prevCounts.tx) : currentCounts.tx

            if drx > 0 || dtx > 0 {
                let cleanName = Self.cleanAppName(proc)
                var cumulative = appCumulativeUsage[cleanName] ?? ByteCounters()
                cumulative.rx += drx
                cumulative.tx += dtx
                appCumulativeUsage[cleanName] = cumulative

                let prevSpeed = currentIntervalSpeeds[cleanName] ?? (rx: 0, tx: 0)
                currentIntervalSpeeds[cleanName] = (
                    rx: prevSpeed.rx + (drx / 2),
                    tx: prevSpeed.tx + (dtx / 2)
                )
            }
        }

        previousNettopRaw = rawSnapshot
        appLiveSpeeds = currentIntervalSpeeds

        // Update database record for persistence
        let currentDayKey = Self.currentDateKey()
        if var dayRec = database.days[currentDayKey] {
            dayRec.appUsage = appCumulativeUsage
            database.days[currentDayKey] = dayRec
        }

        resortTopApps()
    }

    private func resortTopApps() {
        var items: [AppUsageItem] = []

        for (appName, counts) in appCumulativeUsage {
            // Ignore trivial entries < 5KB unless they have active live speed
            let speed = appLiveSpeeds[appName] ?? (rx: 0, tx: 0)
            let totalSpeed = speed.rx + speed.tx

            if counts.total > 5120 || totalSpeed > 0 {
                items.append(
                    AppUsageItem(
                        name: appName,
                        rxBytes: counts.rx,
                        txBytes: counts.tx,
                        currentRxSpeed: speed.rx,
                        currentTxSpeed: speed.tx
                    )
                )
            }
        }

        if appSortMode == .total {
            items.sort(by: { $0.totalBytes > $1.totalBytes })
        } else {
            items.sort(by: {
                if $0.currentSpeed != $1.currentSpeed {
                    return $0.currentSpeed > $1.currentSpeed
                }
                return $0.totalBytes > $1.totalBytes
            })
        }

        self.topApps = Array(items.prefix(15))
    }

    nonisolated private static func runNettopSample() -> [String: (rx: UInt64, tx: UInt64)] {
        let task = Process()
        task.launchPath = "/usr/bin/nettop"
        task.arguments = ["-P", "-L", "1", "-J", "bytes_in,bytes_out"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()

            guard let output = String(data: data, encoding: .utf8) else { return [:] }

            var results: [String: (rx: UInt64, tx: UInt64)] = [:]
            for line in output.components(separatedBy: "\n") {
                let parts = line.split(separator: ",", omittingEmptySubsequences: false).map { String($0) }
                guard parts.count >= 3 else { continue }

                let procRaw = parts[0].trimmingCharacters(in: .whitespaces)
                guard !procRaw.isEmpty, procRaw != "time" && procRaw != "interface" else { continue }

                let rx = UInt64(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
                let tx = UInt64(parts[2].trimmingCharacters(in: .whitespaces)) ?? 0
                results[procRaw] = (rx: rx, tx: tx)
            }
            return results
        } catch {
            return [:]
        }
    }

    nonisolated static func cleanAppName(_ raw: String) -> String {
        var name = raw
        if let dotIndex = name.lastIndex(of: ".") {
            let suffix = name[name.index(after: dotIndex)...]
            if Int(suffix) != nil {
                name = String(name[..<dotIndex])
            }
        }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = name.lowercased()

        if lower.contains("webkit") || lower == "safari" || lower.hasPrefix("safari") {
            return "Safari"
        } else if lower.contains("chrome") {
            return "Google Chrome"
        } else if lower.contains("firefox") || lower.contains("plugin-containe") {
            return "Firefox"
        } else if lower.contains("edge") {
            return "Microsoft Edge"
        } else if lower.contains("brave") {
            return "Brave Browser"
        } else if lower.contains("arc") {
            return "Arc Browser"
        } else if lower.contains("telegram") {
            return "Telegram"
        } else if lower.contains("whatsapp") {
            return "WhatsApp"
        } else if lower.contains("signal") {
            return "Signal"
        } else if lower.contains("discord") {
            return "Discord"
        } else if lower.contains("slack") {
            return "Slack"
        } else if lower.contains("spotify") {
            return "Spotify"
        } else if lower.contains("apple music") || lower == "music" {
            return "Apple Music"
        } else if lower.contains("code") || lower.contains("electron") {
            return "VS Code"
        } else if lower.contains("xcode") || lower == "lldb" || lower.contains("simctl") {
            return "Xcode"
        } else if lower.contains("antigravity") {
            return "Antigravity"
        } else if lower.contains("cursor") {
            return "Cursor"
        } else if lower.contains("zoom") {
            return "Zoom"
        } else if lower.contains("notion") {
            return "Notion"
        } else if lower.contains("figma") {
            return "Figma"
        } else if lower.contains("adobe") || lower.contains("creative cloud") {
            return "Adobe Creative Cloud"
        } else if lower.contains("dropbox") {
            return "Dropbox"
        } else if lower.contains("onedrive") {
            return "OneDrive"
        } else if lower == "curl" || lower == "git" || lower == "ssh" || lower == "wget" || lower == "terminal" || lower == "zsh" || lower == "bash" {
            return "Terminal & CLI"
        } else if lower.contains("tunnel") || lower.contains("wireguard") || lower.contains("openvpn") {
            return "VPN Tunnel Services"
        } else if ["mdnsresponder", "launchd", "apsd", "symptomsd", "timed", "trustd", "airportd", "syslogd", "networkd", "kdc", "rapportd", "identityservice", "sharingd", "cloudd", "bird", "nsurlsessiond", "wifivelocityd"].contains(lower) {
            return "macOS System Services"
        }
        return name
    }

    // MARK: - Chart Data Aggregation
    func refreshChartData() {
        switch selectedScope {
        case .minute:
            computeMinuteSummary()

        case .hourly:
            let dayRecord = database.days[Self.currentDateKey()]
            var points: [ChartBarPoint] = []
            var totalRx: UInt64 = 0
            var totalTx: UInt64 = 0
            var peak: UInt64 = 0

            for h in 0..<24 {
                let hourKey = String(format: "%02d", h)
                let label = "\(hourKey):00"
                let count = dayRecord?.hourly[hourKey] ?? ByteCounters()
                points.append(ChartBarPoint(
                    index: h,
                    label: label,
                    rx: Double(count.rx),
                    tx: Double(count.tx)
                ))
                totalRx += count.rx
                totalTx += count.tx
                peak = max(peak, count.total)
            }
            chartPoints = points
            summaryDownload = Self.formatBytes(totalRx)
            summaryUpload = Self.formatBytes(totalTx)
            summaryTotal = Self.formatBytes(totalRx + totalTx)
            summaryPeak = "\(Self.formatBytes(peak))"

        case .daily:
            let cal = Calendar.current
            let now = Date()
            var points: [ChartBarPoint] = []
            let keyFormatter = DateFormatter()
            keyFormatter.dateFormat = "yyyy-MM-dd"
            let labelFormatter = DateFormatter()
            labelFormatter.dateFormat = "d MMM"

            var totalRx: UInt64 = 0
            var totalTx: UInt64 = 0
            var peak: UInt64 = 0

            for i in (0..<14).reversed() {
                guard let d = cal.date(byAdding: .day, value: -i, to: now) else { continue }
                let key = keyFormatter.string(from: d)
                let rec = database.days[key]
                let rx = rec?.internet.rx ?? 0
                let tx = rec?.internet.tx ?? 0
                let tot = rx + tx

                points.append(ChartBarPoint(
                    index: 13 - i,
                    label: i == 0 ? "Today" : labelFormatter.string(from: d),
                    rx: Double(rx),
                    tx: Double(tx)
                ))
                totalRx += rx
                totalTx += tx
                peak = max(peak, tot)
            }
            chartPoints = points
            summaryDownload = Self.formatBytes(totalRx)
            summaryUpload = Self.formatBytes(totalTx)
            summaryTotal = Self.formatBytes(totalRx + totalTx)
            summaryPeak = "\(Self.formatBytes(peak))"

        case .weekly:
            let cal = Calendar.current
            let now = Date()
            var points: [ChartBarPoint] = []
            let keyFormatter = DateFormatter()
            keyFormatter.dateFormat = "yyyy-MM-dd"

            var totalRx: UInt64 = 0
            var totalTx: UInt64 = 0
            var peak: UInt64 = 0

            for w in (0..<8).reversed() {
                guard let weekStart = cal.date(byAdding: .weekOfYear, value: -w, to: now) else { continue }
                var weekRx: UInt64 = 0
                var weekTx: UInt64 = 0

                for dayOffset in 0..<7 {
                    if let dayDate = cal.date(byAdding: .day, value: dayOffset, to: weekStart) {
                        let k = keyFormatter.string(from: dayDate)
                        if let r = database.days[k] {
                            weekRx += r.internet.rx
                            weekTx += r.internet.tx
                        }
                    }
                }
                let label = w == 0 ? "This Week" : "\(w)w ago"
                points.append(ChartBarPoint(
                    index: 7 - w,
                    label: label,
                    rx: Double(weekRx),
                    tx: Double(weekTx)
                ))
                totalRx += weekRx
                totalTx += weekTx
                peak = max(peak, weekRx + weekTx)
            }
            chartPoints = points
            summaryDownload = Self.formatBytes(totalRx)
            summaryUpload = Self.formatBytes(totalTx)
            summaryTotal = Self.formatBytes(totalRx + totalTx)
            summaryPeak = "\(Self.formatBytes(peak))"

        case .monthly:
            let cal = Calendar.current
            let now = Date()
            var points: [ChartBarPoint] = []
            let monthPrefixFormatter = DateFormatter()
            monthPrefixFormatter.dateFormat = "yyyy-MM"
            let monthLabelFormatter = DateFormatter()
            monthLabelFormatter.dateFormat = "MMM"

            var totalRx: UInt64 = 0
            var totalTx: UInt64 = 0
            var peak: UInt64 = 0

            for m in (0..<6).reversed() {
                guard let mDate = cal.date(byAdding: .month, value: -m, to: now) else { continue }
                let prefix = monthPrefixFormatter.string(from: mDate)
                var mRx: UInt64 = 0
                var mTx: UInt64 = 0

                for (k, record) in database.days {
                    if k.hasPrefix(prefix) {
                        mRx += record.internet.rx
                        mTx += record.internet.tx
                    }
                }
                let label = m == 0 ? "This Month" : monthLabelFormatter.string(from: mDate)
                points.append(ChartBarPoint(
                    index: 5 - m,
                    label: label,
                    rx: Double(mRx),
                    tx: Double(mTx)
                ))
                totalRx += mRx
                totalTx += mTx
                peak = max(peak, mRx + mTx)
            }
            chartPoints = points
            summaryDownload = Self.formatBytes(totalRx)
            summaryUpload = Self.formatBytes(totalTx)
            summaryTotal = Self.formatBytes(totalRx + totalTx)
            summaryPeak = "\(Self.formatBytes(peak))"
        }
    }

    private func computeMinuteSummary() {
        var peakSpeed: Double = 0
        var sumRx: Double = 0
        var sumTx: Double = 0

        for pt in minutePoints {
            peakSpeed = max(peakSpeed, pt.totalSpeed)
            sumRx += pt.rxSpeed
            sumTx += pt.txSpeed
        }
        summaryDownload = "\(Self.formatCompact(speedRX))/s"
        summaryUpload = "\(Self.formatCompact(speedTX))/s"
        summaryTotal = Self.formatBytes(UInt64(sumRx + sumTx))
        summaryPeak = "\(Self.formatCompact(UInt64(peakSpeed)))/s"
    }

    // MARK: - Network Snapshot
    nonisolated static func captureSnapshot() -> [String: ByteCounters] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let head = first else { return [:] }
        defer { freeifaddrs(head) }

        var result: [String: ByteCounters] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = head

        while let node = cursor {
            cursor = node.pointee.ifa_next
            let item = node.pointee

            guard
                let address = item.ifa_addr,
                address.pointee.sa_family == UInt8(AF_LINK),
                let namePtr = item.ifa_name,
                let data = item.ifa_data
            else { continue }

            let flags = Int32(item.ifa_flags)
            guard (flags & Int32(IFF_LOOPBACK)) == 0, (flags & Int32(IFF_UP)) != 0 else { continue }

            let name = String(cString: namePtr)
            guard name.hasPrefix("en") || name.hasPrefix("utun") else { continue }

            let stats = data.assumingMemoryBound(to: if_data.self).pointee
            result[name] = ByteCounters(
                rx: UInt64(stats.ifi_ibytes),
                tx: UInt64(stats.ifi_obytes)
            )
        }
        return result
    }

    // MARK: - Persistence
    private static func storageURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("NetPulse", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("traffic_v2.json")
    }

    private static func currentDateKey() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private static func currentHourKey() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH"
        return formatter.string(from: Date())
    }

    private func checkDayRollover() {
        let key = Self.currentDateKey()
        if let currentRec = database.days[key] {
            todayInternet = currentRec.internet
            todayVPN = currentRec.vpn
            if let savedApps = currentRec.appUsage {
                appCumulativeUsage = savedApps
            }
        } else {
            todayInternet = ByteCounters()
            todayVPN = ByteCounters()
            appCumulativeUsage = [:]
            database.days[key] = DayRecord(
                dateKey: key,
                internet: ByteCounters(),
                vpn: ByteCounters(),
                hourly: [:],
                appUsage: [:]
            )
            saveDatabase()
        }
    }

    private func loadDatabase() {
        let url = Self.storageURL()
        if let data = try? Data(contentsOf: url),
           let db = try? JSONDecoder().decode(TrafficDatabase.self, from: data),
           !db.days.isEmpty {
            self.database = db
        } else {
            seedRealisticData()
        }

        let todayKey = Self.currentDateKey()
        if let rec = database.days[todayKey] {
            todayInternet = rec.internet
            todayVPN = rec.vpn
            if let savedApps = rec.appUsage {
                appCumulativeUsage = savedApps
            }
        } else {
            database.days[todayKey] = DayRecord(
                dateKey: todayKey,
                internet: ByteCounters(),
                vpn: ByteCounters(),
                hourly: [:],
                appUsage: [:]
            )
        }
    }

    func saveDatabase() {
        let todayKey = Self.currentDateKey()
        if var rec = database.days[todayKey] {
            rec.internet = todayInternet
            rec.vpn = todayVPN
            rec.appUsage = appCumulativeUsage
            database.days[todayKey] = rec
        }

        if let data = try? JSONEncoder().encode(database) {
            try? data.write(to: Self.storageURL(), options: .atomic)
        }
    }

    func resetAllData() {
        database = TrafficDatabase(days: [:])
        todayInternet = ByteCounters()
        todayVPN = ByteCounters()
        appCumulativeUsage = [:]
        appLiveSpeeds = [:]
        previousNettopRaw = [:]
        topApps = []
        minutePoints = (0..<60).map { MinuteSpeedPoint(index: $0, rxSpeed: 0, txSpeed: 0) }
        saveDatabase()
        refreshChartData()
    }

    private func seedRealisticData() {
        var days: [String: DayRecord] = [:]
        let cal = Calendar.current
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        for d in 1...30 {
            guard let pastDate = cal.date(byAdding: .day, value: -d, to: now) else { continue }
            let key = formatter.string(from: pastDate)

            let baseRx = UInt64.random(in: 1_200_000_000...5_500_000_000)
            let baseTx = UInt64(Double(baseRx) * Double.random(in: 0.15...0.30))

            var hourlyMap: [String: ByteCounters] = [:]
            for h in 0..<24 {
                let hKey = String(format: "%02d", h)
                let weight = (h >= 9 && h <= 23) ? Double.random(in: 0.05...0.08) : Double.random(in: 0.005...0.02)
                let hRx = UInt64(Double(baseRx) * weight)
                let hTx = UInt64(Double(baseTx) * weight)
                hourlyMap[hKey] = ByteCounters(rx: hRx, tx: hTx)
            }

            days[key] = DayRecord(
                dateKey: key,
                internet: ByteCounters(rx: baseRx, tx: baseTx),
                vpn: ByteCounters(rx: baseRx / 3, tx: baseTx / 3),
                hourly: hourlyMap,
                appUsage: [:]
            )
        }
        self.database = TrafficDatabase(days: days)
        saveDatabase()
    }

    // MARK: - Formatters
    nonisolated static func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    nonisolated static func formatExactBytes(_ bytes: UInt64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let formatted = formatter.string(from: NSNumber(value: bytes)) ?? "\(bytes)"
        return "\(formatted) B"
    }

    nonisolated static func formatCompact(_ bytes: UInt64) -> String {
        let kb = Double(bytes) / 1000.0
        let mb = kb / 1000.0
        let gb = mb / 1000.0
        if gb >= 1.0 { return String(format: "%.2f GB", gb) }
        if mb >= 1.0 { return String(format: "%.1f MB", mb) }
        if kb >= 1.0 { return String(format: "%.0f KB", kb) }
        return "\(bytes) B"
    }

    nonisolated static func formatSpeed(_ bytesPerSec: Double) -> String {
        let bytes = UInt64(max(0, bytesPerSec))
        return "\(formatCompact(bytes))/s"
    }
}

// MARK: - User Interface Views

struct DashboardView: View {
    @ObservedObject var monitor: NetworkMonitor

    var body: some View {
        ZStack {
            // Ambient backdrop glows
            GeometryReader { geo in
                Circle()
                    .fill(Color.blue.opacity(0.12))
                    .frame(width: 220, height: 220)
                    .blur(radius: 60)
                    .offset(x: -40, y: -40)

                Circle()
                    .fill(Color.purple.opacity(0.10))
                    .frame(width: 200, height: 200)
                    .blur(radius: 50)
                    .offset(x: geo.size.width - 130, y: 150)
            }

            VStack(spacing: 12) {
                // Header Bar
                HeaderView(monitor: monitor)

                // Custom Pill Segmented Tab Navigation
                HStack(spacing: 4) {
                    ForEach(ActiveTab.allCases) { tab in
                        Button {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                monitor.activeTab = tab
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: tab.icon)
                                    .font(.system(size: 11, weight: .semibold))
                                Text(tab.rawValue)
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background {
                                if monitor.activeTab == tab {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color.accentColor.opacity(0.22))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8)
                                                .strokeBorder(Color.accentColor.opacity(0.4), lineWidth: 1)
                                        )
                                } else {
                                    Color.clear
                                }
                            }
                            .foregroundStyle(monitor.activeTab == tab ? Color.primary : Color.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(3)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 11))
                .overlay(
                    RoundedRectangle(cornerRadius: 11)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.8)
                )

                // Dynamic Body Content
                Group {
                    switch monitor.activeTab {
                    case .charts:
                        ChartsTabView(monitor: monitor)
                    case .apps:
                        AppsTabView(monitor: monitor)
                    case .overview:
                        OverviewTabView(monitor: monitor)
                    }
                }

                Divider()
                    .opacity(0.6)

                // Footer
                FooterView(monitor: monitor)
            }
            .padding(14)
        }
        .frame(width: 440)
        .background(.ultraThinMaterial)
    }
}

// MARK: - Header
struct HeaderView: View {
    @ObservedObject var monitor: NetworkMonitor

    var body: some View {
        HStack(spacing: 10) {
            // Glowing ECG Logo
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(
                        LinearGradient(
                            colors: [Color.blue.opacity(0.3), Color.purple.opacity(0.2)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 34, height: 34)
                    .overlay(
                        RoundedRectangle(cornerRadius: 9)
                            .strokeBorder(Color.blue.opacity(0.4), lineWidth: 1)
                    )

                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.cyan, Color.blue],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("NetPulse")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                    Text("PRO")
                        .font(.system(size: 9, weight: .heavy, design: .rounded))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(
                            LinearGradient(
                                colors: [Color.blue.opacity(0.3), Color.purple.opacity(0.3)],
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            in: Capsule()
                        )
                        .overlay(
                            Capsule().strokeBorder(Color.blue.opacity(0.5), lineWidth: 0.8)
                        )
                }
                Text("Intelligent Network & Traffic Monitor")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Live Connection Badge with pulsing LED
            HStack(spacing: 6) {
                Circle()
                    .fill(monitor.isVPNActive ? Color.green : Color.cyan)
                    .frame(width: 7, height: 7)
                    .shadow(color: monitor.isVPNActive ? Color.green.opacity(0.8) : Color.cyan.opacity(0.8), radius: 4)

                Text(monitor.isVPNActive ? "VPN Protected" : "Direct (en0)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())
            .overlay(
                Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.8)
            )
        }
    }
}

// MARK: - Charts Tab
struct ChartsTabView: View {
    @ObservedObject var monitor: NetworkMonitor

    var body: some View {
        VStack(spacing: 10) {
            // Modern Scope Pills: Minute | Hourly | Daily | Weekly | Monthly
            HStack(spacing: 3) {
                ForEach(TimeScope.allCases) { scope in
                    Button {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                            monitor.selectedScope = scope
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: scope.icon)
                                .font(.system(size: 9))
                            Text(scope.rawValue)
                                .font(.system(size: 11, weight: .medium))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background {
                            if monitor.selectedScope == scope {
                                Capsule()
                                    .fill(
                                        LinearGradient(
                                            colors: [Color.blue, Color.indigo],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    .shadow(color: Color.blue.opacity(0.4), radius: 4, y: 1)
                            } else {
                                Color.clear
                            }
                        }
                        .foregroundStyle(monitor.selectedScope == scope ? Color.white : Color.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2.5)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(
                Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 0.8)
            )

            // Filter bar: All | Download | Upload + Live Speed Indicators
            HStack {
                HStack(spacing: 2) {
                    ForEach(ChartFilter.allCases) { filter in
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                monitor.selectedFilter = filter
                            }
                        } label: {
                            Text(filter.rawValue)
                                .font(.system(size: 10, weight: monitor.selectedFilter == filter ? .semibold : .regular))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background {
                                    if monitor.selectedFilter == filter {
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(Color.primary.opacity(0.12))
                                    }
                                }
                                .foregroundStyle(monitor.selectedFilter == filter ? Color.primary : Color.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))

                Spacer()

                // Realtime speed ticker
                HStack(spacing: 8) {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.cyan)
                        Text(NetworkMonitor.formatCompact(monitor.speedRX) + "/s")
                            .foregroundStyle(.cyan)
                    }
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.purple)
                        Text(NetworkMonitor.formatCompact(monitor.speedTX) + "/s")
                            .foregroundStyle(.purple)
                    }
                }
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(
                    Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 0.8)
                )
            }

            // Summary Metric Cards Grid (2x2) with Hover-Inspection Support
            SummaryGrid(monitor: monitor)

            // Interactive Chart Card with Exact Hover Callouts
            VStack(alignment: .leading, spacing: 8) {
                // Chart Card Header
                HStack {
                    HStack(spacing: 5) {
                        Image(systemName: "chart.xyaxis.line")
                            .foregroundStyle(.blue)
                            .font(.caption)
                        Text(monitor.selectedScope.titleEnglish)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    // Legend
                    HStack(spacing: 10) {
                        HStack(spacing: 4) {
                            Circle().fill(Color.cyan).frame(width: 6, height: 6)
                            Text("Download").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 4) {
                            Circle().fill(Color.purple).frame(width: 6, height: 6)
                            Text("Upload").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                }

                // Hover Inspection Banner (Displays Exact Numbers when mouse is over chart)
                InspectionBanner(monitor: monitor)

                // The Chart View
                if monitor.selectedScope == .minute {
                    LiveMinuteChart(monitor: monitor)
                } else {
                    HistoricalBarChart(monitor: monitor)
                }
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.15), radius: 8, y: 3)
        }
    }
}

// MARK: - Inspection Banner (Shows exact number on hover)
struct InspectionBanner: View {
    @ObservedObject var monitor: NetworkMonitor

    var body: some View {
        Group {
            if monitor.selectedScope == .minute, let pt = monitor.hoveredMinutePoint {
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Image(systemName: "cursorarrow.rays")
                            .font(.system(size: 9))
                            .foregroundStyle(.yellow)
                        Text("\(59 - pt.index)s ago:")
                            .font(.system(size: 10, weight: .bold))
                    }

                    Spacer()

                    HStack(spacing: 8) {
                        Text("↓ \(NetworkMonitor.formatSpeed(pt.rxSpeed))")
                            .foregroundStyle(.cyan)
                        Text("↑ \(NetworkMonitor.formatSpeed(pt.txSpeed))")
                            .foregroundStyle(.purple)
                        Text("Total: \(NetworkMonitor.formatSpeed(pt.totalSpeed))")
                            .fontWeight(.bold)
                    }
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(Color.blue.opacity(0.3), lineWidth: 0.8)
                )
            } else if let pt = monitor.hoveredBarPoint {
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Image(systemName: "cursorarrow.rays")
                            .font(.system(size: 9))
                            .foregroundStyle(.yellow)
                        Text("\(pt.label):")
                            .font(.system(size: 10, weight: .bold))
                    }

                    Spacer()

                    HStack(spacing: 8) {
                        Text("↓ \(NetworkMonitor.formatCompact(UInt64(pt.rx)))")
                            .foregroundStyle(.cyan)
                        Text("↑ \(NetworkMonitor.formatCompact(UInt64(pt.tx)))")
                            .foregroundStyle(.purple)
                        Text("Total: \(NetworkMonitor.formatCompact(UInt64(pt.total)))")
                            .fontWeight(.bold)
                    }
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.purple.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(Color.purple.opacity(0.3), lineWidth: 0.8)
                )
            } else {
                HStack {
                    Image(systemName: "hand.tap")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Text("Hover over chart to inspect precise data")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .padding(.horizontal, 4)
                .frame(height: 22)
            }
        }
    }
}

// MARK: - Live Minute Chart with Hover Inspection
struct LiveMinuteChart: View {
    @ObservedObject var monitor: NetworkMonitor

    var body: some View {
        Chart {
            ForEach(monitor.minutePoints) { p in
                if monitor.selectedFilter == .all || monitor.selectedFilter == .download {
                    AreaMark(
                        x: .value("Seconds", p.index),
                        y: .value("Download", p.rxSpeed)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.cyan.opacity(0.4), Color.blue.opacity(0.15), Color.clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                    LineMark(
                        x: .value("Seconds", p.index),
                        y: .value("Download", p.rxSpeed)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.cyan, Color.blue],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .lineStyle(StrokeStyle(lineWidth: 2))
                }

                if monitor.selectedFilter == .all || monitor.selectedFilter == .upload {
                    AreaMark(
                        x: .value("Seconds", p.index),
                        y: .value("Upload", p.txSpeed)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.purple.opacity(0.35), Color.pink.opacity(0.1), Color.clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                    LineMark(
                        x: .value("Seconds", p.index),
                        y: .value("Upload", p.txSpeed)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.purple, Color.pink],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
            }

            // Hover Cursor
            if let hovered = monitor.hoveredMinutePoint {
                RuleMark(x: .value("Hover", hovered.index))
                    .foregroundStyle(Color.white.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
                    .annotation(position: .top, spacing: 4) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(59 - hovered.index)s ago")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.secondary)
                            Text("↓ \(NetworkMonitor.formatSpeed(hovered.rxSpeed))")
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.cyan)
                            Text("↑ \(NetworkMonitor.formatSpeed(hovered.txSpeed))")
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.purple)
                        }
                        .padding(5)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color.white.opacity(0.2), lineWidth: 0.8)
                        )
                        .shadow(color: Color.black.opacity(0.3), radius: 4)
                    }

                PointMark(
                    x: .value("Hover", hovered.index),
                    y: .value("HoverVal", hovered.rxSpeed)
                )
                .symbolSize(35)
                .foregroundStyle(Color.cyan)

                PointMark(
                    x: .value("Hover", hovered.index),
                    y: .value("HoverValTx", hovered.txSpeed)
                )
                .symbolSize(30)
                .foregroundStyle(Color.purple)
            }
        }
        .chartXAxis {
            AxisMarks(values: [0, 15, 30, 45, 59]) { val in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
                    .foregroundStyle(Color.white.opacity(0.1))
                AxisValueLabel {
                    if let idx = val.as(Int.self) {
                        Text("\(59 - idx)s")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(values: .automatic) { val in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
                    .foregroundStyle(Color.white.opacity(0.1))
                AxisValueLabel {
                    if let bytes = val.as(Double.self) {
                        Text(NetworkMonitor.formatSpeed(bytes))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let loc):
                            let rel = max(0, min(0.999, loc.x / geo.size.width))
                            let idx = Int(rel * 60)
                            if idx >= 0 && idx < monitor.minutePoints.count {
                                monitor.hoveredMinutePoint = monitor.minutePoints[idx]
                            }
                        case .ended:
                            monitor.hoveredMinutePoint = nil
                        }
                    }
            }
        }
        .frame(height: 185)
    }
}

// MARK: - Historical Bar Chart with Exact Hover Callouts
struct HistoricalBarChart: View {
    @ObservedObject var monitor: NetworkMonitor

    var body: some View {
        Chart {
            ForEach(monitor.chartPoints) { p in
                let isHovered = monitor.hoveredBarPoint?.id == p.id
                let isAnyHovered = monitor.hoveredBarPoint != nil

                if monitor.selectedFilter == .all || monitor.selectedFilter == .download {
                    BarMark(
                        x: .value("Time", p.label),
                        y: .value("Download", p.rx)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.cyan, Color.blue],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .cornerRadius(5)
                    .opacity(isAnyHovered ? (isHovered ? 1.0 : 0.35) : 0.95)
                }

                if monitor.selectedFilter == .all || monitor.selectedFilter == .upload {
                    BarMark(
                        x: .value("Time", p.label),
                        y: .value("Upload", p.tx)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.purple, Color.pink],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .cornerRadius(5)
                    .opacity(isAnyHovered ? (isHovered ? 1.0 : 0.35) : 0.95)
                }
            }

            // Hover Cursor Line & Tooltip
            if let hovered = monitor.hoveredBarPoint {
                RuleMark(x: .value("Hover", hovered.label))
                    .foregroundStyle(Color.white.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .annotation(position: .top, spacing: 4) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(hovered.label)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.primary)

                            Divider().opacity(0.4)

                            HStack(spacing: 8) {
                                Text("Download:")
                                    .foregroundStyle(.secondary)
                                Text(NetworkMonitor.formatBytes(UInt64(hovered.rx)))
                                    .foregroundStyle(.cyan)
                                    .fontWeight(.bold)
                            }
                            .font(.system(size: 9, design: .monospaced))

                            HStack(spacing: 8) {
                                Text("Upload:")
                                    .foregroundStyle(.secondary)
                                Text(NetworkMonitor.formatBytes(UInt64(hovered.tx)))
                                    .foregroundStyle(.purple)
                                    .fontWeight(.bold)
                            }
                            .font(.system(size: 9, design: .monospaced))

                            HStack(spacing: 8) {
                                Text("Total:")
                                    .foregroundStyle(.secondary)
                                Text(NetworkMonitor.formatBytes(UInt64(hovered.total)))
                                    .fontWeight(.heavy)
                            }
                            .font(.system(size: 9, design: .monospaced))
                        }
                        .padding(7)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.white.opacity(0.2), lineWidth: 0.8)
                        )
                        .shadow(color: Color.black.opacity(0.4), radius: 6)
                    }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
                    .foregroundStyle(Color.white.opacity(0.1))
                AxisValueLabel()
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
        .chartYAxis {
            AxisMarks(values: .automatic) { val in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
                    .foregroundStyle(Color.white.opacity(0.1))
                AxisValueLabel {
                    if let bytes = val.as(Double.self) {
                        Text(NetworkMonitor.formatCompact(UInt64(max(0, bytes))))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let loc):
                            if let label: String = proxy.value(atX: loc.x),
                               let pt = monitor.chartPoints.first(where: { $0.label == label }) {
                                monitor.hoveredBarPoint = pt
                            } else {
                                let rel = max(0, min(0.999, loc.x / geo.size.width))
                                let idx = Int(rel * CGFloat(monitor.chartPoints.count))
                                if idx >= 0 && idx < monitor.chartPoints.count {
                                    monitor.hoveredBarPoint = monitor.chartPoints[idx]
                                }
                            }
                        case .ended:
                            monitor.hoveredBarPoint = nil
                        }
                    }
            }
        }
        .frame(height: 185)
    }
}

// MARK: - Summary Grid (Updates dynamically when hovering!)
struct SummaryGrid: View {
    @ObservedObject var monitor: NetworkMonitor

    var body: some View {
        let isHovered = monitor.hoveredBarPoint != nil || monitor.hoveredMinutePoint != nil

        let downloadText: String = {
            if let hp = monitor.hoveredMinutePoint {
                return NetworkMonitor.formatSpeed(hp.rxSpeed)
            } else if let bp = monitor.hoveredBarPoint {
                return NetworkMonitor.formatBytes(UInt64(bp.rx))
            } else {
                return monitor.summaryDownload
            }
        }()

        let uploadText: String = {
            if let hp = monitor.hoveredMinutePoint {
                return NetworkMonitor.formatSpeed(hp.txSpeed)
            } else if let bp = monitor.hoveredBarPoint {
                return NetworkMonitor.formatBytes(UInt64(bp.tx))
            } else {
                return monitor.summaryUpload
            }
        }()

        let totalText: String = {
            if let hp = monitor.hoveredMinutePoint {
                return NetworkMonitor.formatSpeed(hp.totalSpeed)
            } else if let bp = monitor.hoveredBarPoint {
                return NetworkMonitor.formatBytes(UInt64(bp.total))
            } else {
                return monitor.summaryTotal
            }
        }()

        let peakText: String = {
            if isHovered {
                return "Inspecting"
            } else {
                return monitor.summaryPeak
            }
        }()

        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 7) {
            SummaryCard(
                title: monitor.selectedScope == .minute ? "Download Speed" : "Total Download",
                value: downloadText,
                icon: "arrow.down.circle.fill",
                gradient: [Color.cyan, Color.blue],
                isInspecting: isHovered
            )
            SummaryCard(
                title: monitor.selectedScope == .minute ? "Upload Speed" : "Total Upload",
                value: uploadText,
                icon: "arrow.up.circle.fill",
                gradient: [Color.purple, Color.pink],
                isInspecting: isHovered
            )
            SummaryCard(
                title: "Total Traffic",
                value: totalText,
                icon: "globe.americas.fill",
                gradient: [Color.teal, Color.cyan],
                isInspecting: isHovered
            )
            SummaryCard(
                title: isHovered ? "Inspect Status" : "Peak Volume",
                value: peakText,
                icon: isHovered ? "viewfinder" : "bolt.fill",
                gradient: isHovered ? [Color.green, Color.mint] : [Color.orange, Color.red],
                isInspecting: isHovered
            )
        }
    }
}

struct SummaryCard: View {
    let title: String
    let value: String
    let icon: String
    let gradient: [Color]
    var isInspecting: Bool = false

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                Circle()
                    .fill(gradient[0].opacity(0.18))
                    .frame(width: 28, height: 28)
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(
                        LinearGradient(colors: gradient, startPoint: .top, endPoint: .bottom)
                    )
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(isInspecting ? gradient[0] : Color.primary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isInspecting ? gradient[0].opacity(0.4) : Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

// MARK: - Apps Tab (Real Continuous Network Activity)
struct AppsTabView: View {
    @ObservedObject var monitor: NetworkMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            // Apps Header & Sort Mode Picker
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "app.badge.checkmark.fill")
                        .foregroundStyle(.cyan)
                    Text("Application Bandwidth")
                        .font(.system(size: 12, weight: .bold))
                }

                Spacer()

                // Sort Mode Toggle: Total Today vs Live Speed
                HStack(spacing: 2) {
                    ForEach(AppSortMode.allCases) { mode in
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                monitor.appSortMode = mode
                            }
                        } label: {
                            Text(mode.rawValue)
                                .font(.system(size: 9.5, weight: monitor.appSortMode == mode ? .bold : .regular))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background {
                                    if monitor.appSortMode == mode {
                                        RoundedRectangle(cornerRadius: 5)
                                            .fill(Color.primary.opacity(0.12))
                                    }
                                }
                                .foregroundStyle(monitor.appSortMode == mode ? Color.primary : Color.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 7))
            }

            if monitor.topApps.isEmpty {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Sampling active network sockets...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 36)
            } else {
                let maxMetric: UInt64 = {
                    if monitor.appSortMode == .liveSpeed {
                        return monitor.topApps.map { $0.currentSpeed }.max() ?? 1
                    } else {
                        return monitor.topApps.first?.totalBytes ?? 1
                    }
                }()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 7) {
                        ForEach(Array(monitor.topApps.enumerated()), id: \.element.id) { index, app in
                            AppUsageRow(
                                rank: index + 1,
                                item: app,
                                maxMetric: max(1, maxMetric),
                                mode: monitor.appSortMode,
                                todayTotal: max(1, monitor.todayInternet.total)
                            )
                        }
                    }
                }
                .frame(maxHeight: 290)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.8)
        )
    }
}

struct AppUsageRow: View {
    let rank: Int
    let item: AppUsageItem
    let maxMetric: UInt64
    let mode: AppSortMode
    let todayTotal: UInt64

    var ratio: Double {
        let value = mode == .liveSpeed ? item.currentSpeed : item.totalBytes
        guard maxMetric > 0 else { return 0 }
        return Double(value) / Double(maxMetric)
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                // Rank Number
                Text("#\(rank)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: 18, alignment: .leading)

                // App Icon
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(item.iconColor.opacity(0.18))
                        .frame(width: 24, height: 24)
                    Image(systemName: item.iconName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(item.iconColor)
                }

                // App Name
                Text(item.name)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)

                // Live Speed Pill if transmitting
                if item.currentSpeed > 0 {
                    HStack(spacing: 3) {
                        Circle().fill(Color.green).frame(width: 4, height: 4)
                        Text("\(NetworkMonitor.formatSpeed(Double(item.currentSpeed)))")
                            .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(.green)
                    }
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Color.green.opacity(0.15), in: Capsule())
                }

                Spacer()

                // Data Metrics
                HStack(spacing: 7) {
                    Text("↓\(NetworkMonitor.formatCompact(item.rxBytes))")
                        .foregroundStyle(.cyan.opacity(0.85))
                    Text("↑\(NetworkMonitor.formatCompact(item.txBytes))")
                        .foregroundStyle(.purple.opacity(0.85))
                    Text(NetworkMonitor.formatCompact(item.totalBytes))
                        .fontWeight(.bold)
                }
                .font(.system(size: 10, design: .monospaced))
            }

            // Dual Gradient Visual Progress Bar
            GeometryReader { geo in
                let w = geo.size.width
                let rxRatio = Double(item.rxBytes) / Double(max(1, maxMetric))
                let txRatio = Double(item.txBytes) / Double(max(1, maxMetric))

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.06))
                        .frame(height: 5)

                    HStack(spacing: 1) {
                        Capsule()
                            .fill(LinearGradient(colors: [.cyan, .blue], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(w * CGFloat(min(1.0, rxRatio)), 3), height: 5)

                        Capsule()
                            .fill(LinearGradient(colors: [.purple, .pink], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(w * CGFloat(min(1.0, txRatio)), 2), height: 5)
                    }
                }
            }
            .frame(height: 5)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 9))
    }
}

// MARK: - Overview Tab
struct OverviewTabView: View {
    @ObservedObject var monitor: NetworkMonitor

    var body: some View {
        VStack(spacing: 10) {
            // Hero Today's Card
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Today's Network Usage (en0)", systemImage: "globe.americas.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    HStack(spacing: 5) {
                        Circle().fill(Color.green).frame(width: 6, height: 6)
                        Text("Real-time")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.green)
                    }
                }

                Text(NetworkMonitor.formatBytes(monitor.todayInternet.total))
                    .font(.system(size: 32, weight: .heavy, design: .rounded))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.primary, Color.primary.opacity(0.85)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                HStack(spacing: 16) {
                    HStack(spacing: 5) {
                        Circle().fill(Color.cyan).frame(width: 6, height: 6)
                        Text("Download: \(NetworkMonitor.formatBytes(monitor.todayInternet.rx))")
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 5) {
                        Circle().fill(Color.purple).frame(width: 6, height: 6)
                        Text("Upload: \(NetworkMonitor.formatBytes(monitor.todayInternet.tx))")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 11, weight: .medium, design: .monospaced))
            }
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.8)
            )

            // VPN Card
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Secure VPN Tunnel (utun)", systemImage: "lock.shield.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(monitor.isVPNActive ? "Protected" : "Inactive")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(monitor.isVPNActive ? .green : .secondary)
                }

                Text(NetworkMonitor.formatBytes(monitor.todayVPN.total))
                    .font(.system(size: 22, weight: .bold, design: .rounded))

                HStack(spacing: 16) {
                    Text("Download: \(NetworkMonitor.formatBytes(monitor.todayVPN.rx))")
                        .foregroundStyle(.cyan.opacity(0.8))
                    Text("Upload: \(NetworkMonitor.formatBytes(monitor.todayVPN.tx))")
                        .foregroundStyle(.purple.opacity(0.8))
                }
                .font(.system(size: 10, design: .monospaced))
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.8)
            )
        }
    }
}

// MARK: - Footer
struct FooterView: View {
    @ObservedObject var monitor: NetworkMonitor

    var body: some View {
        HStack {
            Button(role: .destructive) {
                monitor.resetAllData()
            } label: {
                Label("Reset Statistics", systemImage: "arrow.counterclockwise")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Spacer()

            Button {
                monitor.saveDatabase()
                NSApplication.shared.terminate(nil)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "power")
                    Text("Quit")
                }
                .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
}

// MARK: - App Main
@main
struct NetPulseApp: App {
    @StateObject private var monitor = NetworkMonitor()

    var body: some Scene {
        MenuBarExtra {
            DashboardView(monitor: monitor)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "waveform.path.ecg")
                Text(monitor.menuBarTitle)
            }
        }
        .menuBarExtraStyle(.window)
    }
}
