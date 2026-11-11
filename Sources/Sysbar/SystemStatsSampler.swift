// Adapted from oMLX (https://github.com/jundot/omlx), apps/omlx-mac/Sources/
// Menubar/SystemStatsSampler.swift — Apache License 2.0. Changes: standalone
// history buffers (no MenubarMetricsStore), extra histories for the
// animated status-bar icon (total CPU, memory, GPU memory), disk usage and
// disk / memory (page-in/out) I/O rates.
//
// Host-level stats behind the menubar's System Stats submenu. Everything
// here is public API only: Mach per-CPU tick counters (E/P cluster split
// via hw.perflevel sysctls), the IOKit accelerator performance dictionary
// for GPU utilization and in-use memory, vm_statistics64 for the memory
// breakdown, getloadavg, and kern.boottime. Power draw, core frequencies,
// and die temperature would need private frameworks and are intentionally
// out of scope; ProcessInfo's thermal state stands in for temperature.
//
// In Sysbar the sampler runs continuously (the status icon animates), at the
// interval chosen in the menu. CPU usage comes
// from deltas of cumulative tick counters, so the first tick after a long
// gap still yields a valid average over that window.

import AppKit
import Darwin.Mach
import IOKit

/// The host metrics the menubar can surface, in display order.
enum SystemStatKind: String, CaseIterable, Hashable, Sendable {
    case cpu
    case gpu
    case memory
    case disk
    case network

    var tag: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .memory: return "MEM"
        case .disk: return "DISK"
        case .network: return "NET"
        }
    }
}

struct SystemStatsSnapshot: Sendable {
    struct Memory: Sendable {
        var totalBytes: UInt64 = 0
        var wiredBytes: UInt64 = 0
        var activeBytes: UInt64 = 0
        /// "App memory" as Activity Monitor / iStat report it:
        /// active + inactive + speculative − purgeable − file-backed.
        var appBytes: UInt64 = 0
        var swapUsedBytes: UInt64 = 0
        var compressedBytes: UInt64 = 0
        /// Derived as total − (wired + active + compressed) so the four
        /// legend rows always sum to the machine total.
        var freeBytes: UInt64 = 0
        /// Cumulative page-in / page-out byte counters (for I/O rates).
        var pageinBytes: UInt64 = 0
        var pageoutBytes: UInt64 = 0
        var usedBytes: UInt64 { appBytes + wiredBytes + compressedBytes }
        var usedFraction: Double {
            totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0
        }
    }

    /// Bytes per second.
    struct IORate: Sendable {
        var read: Double
        var write: Double
    }

    struct Disk: Sendable {
        var name: String
        var totalBytes: UInt64
        var freeBytes: UInt64
        var usedBytes: UInt64 { totalBytes > freeBytes ? totalBytes - freeBytes : 0 }
        var usedFraction: Double {
            totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0
        }
    }

    /// Fractions 0...1; nil while a reading is unavailable.
    var eCoreUsage: Double?
    var pCoreUsage: Double?
    /// All-core average, for the single-bar CPU menubar item.
    var cpuTotalUsage: Double?
    var gpuUsage: Double?
    var gpuMemoryInUseBytes: UInt64?
    var memory = Memory()
    var loadAverages: [Double] = []
    var uptimeSeconds: TimeInterval = 0
    var thermalState: ProcessInfo.ThermalState = .nominal

    var eHistory: [Double] = []
    var pHistory: [Double] = []
    var gpuHistory: [Double] = []
    var cpuHistory: [Double] = []
    var memoryHistory: [Double] = []
    var gpuMemoryHistory: [Double] = []

    var disk: Disk?
    /// Disk read/write throughput (all block-storage drivers).
    var diskIO: IORate?
    /// Memory page-ins (read) / page-outs (write).
    var memoryIO: IORate?
    var diskReadHistory: [Double] = []
    var diskWriteHistory: [Double] = []
    var memoryInHistory: [Double] = []
    var memoryOutHistory: [Double] = []

    /// Network throughput: read = download, write = upload (bytes/s).
    var networkIO: IORate?
    var networkInHistory: [Double] = []
    var networkOutHistory: [Double] = []
    var networkInterface: String?
    var networkAddress: String?

    /// GPU in-use memory as a fraction of physical memory (unified memory).
    var gpuMemoryFraction: Double? {
        guard let inUse = gpuMemoryInUseBytes, memory.totalBytes > 0 else { return nil }
        return min(1, Double(inUse) / Double(memory.totalBytes))
    }
}

@MainActor
final class SystemStatsSampler {

    struct CPUTicks: Equatable, Sendable {
        var busy: UInt64
        var total: UInt64
    }

    private var previousTicks: [CPUTicks]?
    private var eHistory: [Double] = []
    private var pHistory: [Double] = []
    private var gpuHistory: [Double] = []
    private var cpuHistory: [Double] = []
    private var memoryHistory: [Double] = []
    private var gpuMemoryHistory: [Double] = []
    private var diskReadHistory: [Double] = []
    private var diskWriteHistory: [Double] = []
    private var memoryInHistory: [Double] = []
    private var memoryOutHistory: [Double] = []
    private var previousDiskBytes: (read: UInt64, write: UInt64, time: TimeInterval)?
    private var previousPageBytes: (pagein: UInt64, pageout: UInt64, time: TimeInterval)?
    private var networkInHistory: [Double] = []
    private var networkOutHistory: [Double] = []
    private var previousNetBytes: (rx: UInt64, tx: UInt64, time: TimeInterval)?
    private var cachedDisk: SystemStatsSnapshot.Disk?
    private var diskReadAt: TimeInterval = -.infinity
    private let eCoreCount = SystemStatsSampler.readECoreCount()

    func sample() -> SystemStatsSnapshot {
        var snapshot = SystemStatsSnapshot()

        if let ticks = Self.readCPUTicks() {
            if let previous = previousTicks,
               let usage = Self.clusterUsage(
                   previous: previous, current: ticks, eCoreCount: eCoreCount
               ) {
                snapshot.eCoreUsage = usage.e
                snapshot.pCoreUsage = usage.p
                snapshot.cpuTotalUsage = usage.total
                Self.appendHistory(&eHistory, usage.e)
                Self.appendHistory(&pHistory, usage.p)
                Self.appendHistory(&cpuHistory, usage.total)
            }
            previousTicks = ticks
        }

        if let gpu = Self.readGPUStatistics() {
            snapshot.gpuUsage = gpu.usage
            snapshot.gpuMemoryInUseBytes = gpu.memoryInUseBytes
            if let usage = gpu.usage {
                Self.appendHistory(&gpuHistory, usage)
            }
        }

        snapshot.memory = Self.readMemory()
        Self.appendHistory(&memoryHistory, snapshot.memory.usedFraction)
        if let gpuMem = snapshot.gpuMemoryFraction {
            Self.appendHistory(&gpuMemoryHistory, gpuMem)
        }
        let now = ProcessInfo.processInfo.systemUptime
        let mem = snapshot.memory
        if let prev = previousPageBytes, now > prev.time,
           mem.pageinBytes >= prev.pagein, mem.pageoutBytes >= prev.pageout {
            let dt = now - prev.time
            let rate = SystemStatsSnapshot.IORate(
                read: Double(mem.pageinBytes - prev.pagein) / dt,
                write: Double(mem.pageoutBytes - prev.pageout) / dt)
            snapshot.memoryIO = rate
            Self.appendHistory(&memoryInHistory, rate.read)
            Self.appendHistory(&memoryOutHistory, rate.write)
        }
        previousPageBytes = (mem.pageinBytes, mem.pageoutBytes, now)

        if let bytes = Self.readDiskBytes() {
            if let prev = previousDiskBytes, now > prev.time,
               bytes.read >= prev.read, bytes.write >= prev.write {
                let dt = now - prev.time
                let rate = SystemStatsSnapshot.IORate(
                    read: Double(bytes.read - prev.read) / dt,
                    write: Double(bytes.write - prev.write) / dt)
                snapshot.diskIO = rate
                Self.appendHistory(&diskReadHistory, rate.read)
                Self.appendHistory(&diskWriteHistory, rate.write)
            }
            previousDiskBytes = (bytes.read, bytes.write, now)
        }

        if let net = Self.readNetwork() {
            snapshot.networkInterface = net.interface
            snapshot.networkAddress = net.address
            // Interface counters are 32-bit and wrap; skip a wrapped tick.
            if let prev = previousNetBytes, now > prev.time,
               net.rx >= prev.rx, net.tx >= prev.tx {
                let dt = now - prev.time
                let rate = SystemStatsSnapshot.IORate(
                    read: Double(net.rx - prev.rx) / dt,
                    write: Double(net.tx - prev.tx) / dt)
                snapshot.networkIO = rate
                Self.appendHistory(&networkInHistory, rate.read)
                Self.appendHistory(&networkOutHistory, rate.write)
            }
            previousNetBytes = (net.rx, net.tx, now)
        }

        // Volume capacity changes slowly; refresh it every 10 s.
        if cachedDisk == nil || now - diskReadAt >= 10 {
            cachedDisk = Self.readDiskUsage() ?? cachedDisk
            diskReadAt = now
        }
        snapshot.disk = cachedDisk

        var loads = [Double](repeating: 0, count: 3)
        if getloadavg(&loads, 3) == 3 {
            snapshot.loadAverages = loads
        }
        snapshot.uptimeSeconds = Self.readUptime()
        snapshot.thermalState = ProcessInfo.processInfo.thermalState

        snapshot.eHistory = eHistory
        snapshot.pHistory = pHistory
        snapshot.gpuHistory = gpuHistory
        snapshot.cpuHistory = cpuHistory
        snapshot.memoryHistory = memoryHistory
        snapshot.gpuMemoryHistory = gpuMemoryHistory
        snapshot.diskReadHistory = diskReadHistory
        snapshot.diskWriteHistory = diskWriteHistory
        snapshot.memoryInHistory = memoryInHistory
        snapshot.memoryOutHistory = memoryOutHistory
        snapshot.networkInHistory = networkInHistory
        snapshot.networkOutHistory = networkOutHistory
        return snapshot
    }

    /// Samples kept per series (60 samples ≈ 60 s at the default 1 s tick).
    static let historyLimit = 60

    private static func appendHistory(_ buffer: inout [Double], _ value: Double) {
        buffer.append(value)
        if buffer.count > historyLimit {
            buffer.removeFirst(buffer.count - historyLimit)
        }
    }

    // MARK: - CPU

    /// Logical-CPU count of the efficiency cluster. Apple Silicon enumerates
    /// the E cluster first in Mach's per-CPU arrays; `hw.perflevel1` is the
    /// efficiency level whenever two performance levels exist. 0 (Intel or
    /// unknown) makes every core count as P.
    nonisolated private static func readECoreCount() -> Int {
        var levels: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("hw.nperflevels", &levels, &size, nil, 0) == 0,
              levels >= 2
        else {
            return 0
        }
        var count: Int32 = 0
        size = MemoryLayout<Int32>.size
        guard sysctlbyname("hw.perflevel1.logicalcpu", &count, &size, nil, 0) == 0 else {
            return 0
        }
        return Int(count)
    }

    /// Cumulative busy/total ticks per logical CPU, in kernel enumeration
    /// order (E cluster first on Apple Silicon).
    nonisolated private static func readCPUTicks() -> [CPUTicks]? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &cpuCount,
            &info,
            &infoCount
        )
        guard result == KERN_SUCCESS, let info else { return nil }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(bitPattern: info),
                vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            )
        }

        let stride = Int(CPU_STATE_MAX)
        var ticks: [CPUTicks] = []
        ticks.reserveCapacity(Int(cpuCount))
        for cpu in 0..<Int(cpuCount) {
            let base = cpu * stride
            let user = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
            let system = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
            let nice = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
            let idle = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
            let busy = user &+ system &+ nice
            ticks.append(CPUTicks(busy: busy, total: busy &+ idle))
        }
        return ticks
    }

    /// Average busy fraction per cluster between two tick readings. The
    /// counters are 32-bit in the kernel and wrap; a wrapped or shrunk
    /// counter invalidates that CPU's delta, and a reading with no usable
    /// delta at all yields nil. Exposed for unit tests.
    nonisolated static func clusterUsage(
        previous: [CPUTicks],
        current: [CPUTicks],
        eCoreCount: Int
    ) -> (e: Double, p: Double, total: Double)? {
        guard previous.count == current.count, !current.isEmpty else {
            return nil
        }
        var eBusy = 0.0, eTotal = 0.0
        var pBusy = 0.0, pTotal = 0.0
        for index in current.indices {
            let prev = previous[index]
            let cur = current[index]
            guard cur.total > prev.total, cur.busy >= prev.busy else { continue }
            let busy = Double(cur.busy - prev.busy)
            let total = Double(cur.total - prev.total)
            if index < eCoreCount {
                eBusy += busy
                eTotal += total
            } else {
                pBusy += busy
                pTotal += total
            }
        }
        let allBusy = eBusy + pBusy
        let allTotal = eTotal + pTotal
        guard allTotal > 0 else { return nil }
        return (
            e: eTotal > 0 ? min(1, eBusy / eTotal) : 0,
            p: pTotal > 0 ? min(1, pBusy / pTotal) : 0,
            total: min(1, allBusy / allTotal)
        )
    }

    // MARK: - GPU

    /// Reads the accelerator's PerformanceStatistics dictionary (public
    /// IOKit registry, no entitlements). Apple Silicon exposes one AGX
    /// service conforming to IOAccelerator with "Device Utilization %" and
    /// "In use system memory".
    nonisolated private static func readGPUStatistics()
        -> (usage: Double?, memoryInUseBytes: UInt64?)?
    {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOAccelerator"),
            &iterator
        ) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }

            var propertiesRef: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(
                service, &propertiesRef, kCFAllocatorDefault, 0
            ) == KERN_SUCCESS,
                let properties = propertiesRef?.takeRetainedValue() as? [String: Any],
                let statistics = properties["PerformanceStatistics"] as? [String: Any]
            else {
                continue
            }

            let usage = (statistics["Device Utilization %"] as? NSNumber)
                .map { min(1, max(0, $0.doubleValue / 100)) }
            let memory = (statistics["In use system memory"] as? NSNumber)
                .map { UInt64(truncating: $0) }
            if usage != nil || memory != nil {
                return (usage: usage, memoryInUseBytes: memory)
            }
        }
        return nil
    }

    // MARK: - Memory

    nonisolated private static func readMemory() -> SystemStatsSnapshot.Memory {
        var memory = SystemStatsSnapshot.Memory()
        memory.totalBytes = ProcessInfo.processInfo.physicalMemory

        var size = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        var stats = vm_statistics64_data_t()
        let result = withUnsafeMutablePointer(to: &stats) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &size)
            }
        }
        var pageSize: vm_size_t = 0
        guard result == KERN_SUCCESS,
              host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS
        else {
            return memory
        }

        let page = UInt64(pageSize)
        memory.wiredBytes = UInt64(stats.wire_count) * page
        memory.activeBytes = UInt64(stats.active_count) * page
        let anonymous = Int64(stats.active_count) + Int64(stats.inactive_count)
            + Int64(stats.speculative_count) - Int64(stats.purgeable_count)
            - Int64(stats.external_page_count)
        memory.appBytes = UInt64(max(0, anonymous)) * page
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 {
            memory.swapUsedBytes = swap.xsu_used
        }
        memory.compressedBytes = UInt64(stats.compressor_page_count) * page
        memory.pageinBytes = UInt64(stats.pageins) * page
        memory.pageoutBytes = UInt64(stats.pageouts) * page
        memory.freeBytes = memory.totalBytes > memory.usedBytes
            ? memory.totalBytes - memory.usedBytes
            : 0
        return memory
    }

    // MARK: - Disk

    /// Cumulative bytes read/written, summed over every IOBlockStorageDriver
    /// (public IOKit registry "Statistics" dictionary).
    nonisolated private static func readDiskBytes() -> (read: UInt64, write: UInt64)? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator
        ) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var read: UInt64 = 0
        var write: UInt64 = 0
        var found = false
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            guard let stats = IORegistryEntryCreateCFProperty(
                service, "Statistics" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? [String: Any] else {
                continue
            }
            if let v = stats["Bytes (Read)"] as? NSNumber { read &+= v.uint64Value; found = true }
            if let v = stats["Bytes (Write)"] as? NSNumber { write &+= v.uint64Value; found = true }
        }
        return found ? (read, write) : nil
    }

    /// Capacity of the startup volume ("available" includes purgeable space,
    /// like Finder reports it).
    nonisolated private static func readDiskUsage() -> SystemStatsSnapshot.Disk? {
        let url = URL(fileURLWithPath: "/")
        guard let values = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
            .volumeLocalizedNameKey,
        ]), let total = values.volumeTotalCapacity, total > 0 else {
            return nil
        }
        let free = values.volumeAvailableCapacityForImportantUsage
            ?? Int64(values.volumeAvailableCapacity ?? 0)
        return SystemStatsSnapshot.Disk(
            name: values.volumeLocalizedName ?? "Macintosh HD",
            totalBytes: UInt64(total),
            freeBytes: UInt64(max(0, free))
        )
    }

    // MARK: - Network

    /// Bytes received/sent summed over the physical "en*" interfaces (Wi-Fi,
    /// Ethernet; skips loopback, VPN tunnels and AWDL so traffic isn't
    /// double-counted), plus the first IPv4 address found on them.
    nonisolated private static func readNetwork()
        -> (rx: UInt64, tx: UInt64, interface: String?, address: String?)?
    {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var rx: UInt64 = 0
        var tx: UInt64 = 0
        var found = false
        var interface: String?
        var address: String?
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr else { continue }
            let flags = Int32(ifa.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let name = String(cString: ifa.ifa_name)
            guard name.hasPrefix("en") else { continue }

            if addr.pointee.sa_family == UInt8(AF_LINK),
               let data = ifa.ifa_data?.assumingMemoryBound(to: if_data.self) {
                rx &+= UInt64(data.pointee.ifi_ibytes)
                tx &+= UInt64(data.pointee.ifi_obytes)
                found = true
            } else if addr.pointee.sa_family == UInt8(AF_INET), address == nil {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                               nil, 0, NI_NUMERICHOST) == 0 {
                    address = String(cString: host)
                    interface = name
                }
            }
        }
        return found ? (rx, tx, interface, address) : nil
    }

    // MARK: - Misc readings

    /// Wall-clock uptime from kern.boottime (ProcessInfo.systemUptime stops
    /// while the machine sleeps, which reads oddly next to `uptime`).
    nonisolated private static func readUptime() -> TimeInterval {
        var boottime = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boottime, &size, nil, 0) == 0,
              boottime.tv_sec > 0
        else {
            return ProcessInfo.processInfo.systemUptime
        }
        let booted = TimeInterval(boottime.tv_sec)
        return max(0, Date().timeIntervalSince1970 - booted)
    }

    // MARK: - Formatting (pure, unit-tested)

    /// "8d 18h" / "5h 12m" / "42m"
    nonisolated static func formatUptime(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        let hours = minutes / 60
        let days = hours / 24
        if days >= 1 {
            return "\(days)d \(hours % 24)h"
        }
        if hours >= 1 {
            return "\(hours)h \(minutes % 60)m"
        }
        return "\(max(0, minutes))m"
    }

    /// "3.50 · 2.67 · 2.33"
    nonisolated static func formatLoadAverages(_ loads: [Double]) -> String {
        guard !loads.isEmpty else { return "–" }
        return loads.map { String(format: "%.2f", $0) }.joined(separator: " · ")
    }

    /// "0 B/s" / "512 KB/s" / "1.2 MB/s" (decimal units).
    nonisolated static func formatRate(_ bytesPerSecond: Double?) -> String {
        guard let v = bytesPerSecond, v.isFinite else { return "–" }
        if v >= 1_000_000_000 { return String(format: "%.1f GB/s", v / 1_000_000_000) }
        if v >= 1_000_000 { return String(format: "%.1f MB/s", v / 1_000_000) }
        if v >= 1_000 { return String(format: "%.0f KB/s", v / 1_000) }
        return String(format: "%.0f B/s", v)
    }

    /// "237.29 GB" / "730 MB" — legend-row byte formatting, decimal units
    /// to match how macOS reports memory sizes.
    nonisolated static func formatBytes(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_000_000_000
        if gb >= 1 {
            return String(format: "%.2f GB", gb)
        }
        return String(format: "%.0f MB", Double(bytes) / 1_000_000)
    }
}
