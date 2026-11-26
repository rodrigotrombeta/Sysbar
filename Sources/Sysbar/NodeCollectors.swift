// The rest of node_exporter's metrics that macOS can provide without root,
// read when Prometheus scrapes (nothing is sampled while the exporter is
// off). Names, labels and units follow node_exporter on Linux, so the panels
// of "Node Exporter Full" fill in. What macOS doesn't have (slab, huge pages,
// systemd, softnet, conntrack, pressure stall…) or hides from apps (TCP
// statistics read as zeros even in `netstat -s`) is left out instead of
// being reported as a made-up zero.

import Darwin
import Foundation
import IOKit

enum NodeCollectors {

    // MARK: Disks

    struct Disk {
        var readBytes: UInt64 = 0, writtenBytes: UInt64 = 0
        var reads: UInt64 = 0, writes: UInt64 = 0
        /// Time spent in reads / writes, nanoseconds (summed over requests).
        var readTimeNs: UInt64 = 0, writeTimeNs: UInt64 = 0
        var readErrors: UInt64 = 0, writeErrors: UInt64 = 0
    }

    /// Totals over every IOBlockStorageDriver (the registry's "Statistics").
    static func disks() -> Disk? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"),
                                           &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var d = Disk(), found = false
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let s = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] else { continue }
            func v(_ key: String) -> UInt64 { (s[key] as? NSNumber)?.uint64Value ?? 0 }
            d.readBytes &+= v("Bytes (Read)"); d.writtenBytes &+= v("Bytes (Write)")
            d.reads &+= v("Operations (Read)"); d.writes &+= v("Operations (Write)")
            d.readTimeNs &+= v("Total Time (Read)"); d.writeTimeNs &+= v("Total Time (Write)")
            d.readErrors &+= v("Errors (Read)"); d.writeErrors &+= v("Errors (Write)")
            found = true
        }
        return found ? d : nil
    }

    // MARK: Memory (vm_statistics64)

    struct VM {
        var page: UInt64 = 0
        var active: UInt64 = 0, inactive: UInt64 = 0, speculative: UInt64 = 0, wired: UInt64 = 0
        var anonymous: UInt64 = 0, fileBacked: UInt64 = 0, purgeable: UInt64 = 0
        var pageins: UInt64 = 0, pageouts: UInt64 = 0, faults: UInt64 = 0, cowFaults: UInt64 = 0
        var swapins: UInt64 = 0, swapouts: UInt64 = 0
        var compressions: UInt64 = 0, decompressions: UInt64 = 0
    }

    static func vm() -> VM? {
        var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        var s = vm_statistics64_data_t()
        let r = withUnsafeMutablePointer(to: &s) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &size)
            }
        }
        var pageSize: vm_size_t = 0
        guard r == KERN_SUCCESS, host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { return nil }
        return VM(page: UInt64(pageSize),
                  active: UInt64(s.active_count), inactive: UInt64(s.inactive_count),
                  speculative: UInt64(s.speculative_count), wired: UInt64(s.wire_count),
                  anonymous: UInt64(s.internal_page_count), fileBacked: UInt64(s.external_page_count),
                  purgeable: UInt64(s.purgeable_count),
                  pageins: s.pageins, pageouts: s.pageouts, faults: s.faults, cowFaults: s.cow_faults,
                  swapins: s.swapins, swapouts: s.swapouts,
                  compressions: s.compressions, decompressions: s.decompressions)
    }

    // MARK: Processes, threads, file descriptors

    /// Every task and thread on the system (the processor set's load info
    /// counts them all, root's included, without needing root).
    static func tasksAndThreads() -> (tasks: Int, threads: Int)? {
        var pset: processor_set_name_t = 0
        guard processor_set_default(mach_host_self(), &pset) == KERN_SUCCESS else { return nil }
        defer { mach_port_deallocate(mach_task_self_, pset) }
        var info = processor_set_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<processor_set_load_info>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                processor_set_statistics(pset, PROCESSOR_SET_LOAD_INFO, $0, &count)
            }
        }
        return r == KERN_SUCCESS ? (Int(info.task_count), Int(info.thread_count)) : nil
    }

    static func sysctlInt(_ name: String) -> Int? {
        var v: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &v, &size, nil, 0) == 0 ? Int(v) : nil
    }

    static func sysctlStruct<T>(_ name: String, _ value: T) -> T? {
        var v = value
        var size = MemoryLayout<T>.size
        return sysctlbyname(name, &v, &size, nil, 0) == 0 ? v : nil
    }

    // MARK: Filesystems

    struct Filesystem {
        var mountpoint: String, device: String, fstype: String
        var size: UInt64, free: UInt64, avail: UInt64, files: UInt64, filesFree: UInt64
        var readOnly: Bool
    }

    /// Local volumes a user would see: the startup disk and anything under
    /// /Volumes (skips the hidden system volumes, snapshots and disk images'
    /// internals that macOS marks "don't browse").
    static func filesystems() -> [Filesystem] {
        var list: UnsafeMutablePointer<statfs>?
        let n = getmntinfo(&list, MNT_NOWAIT)
        guard n > 0, let list else { return [] }
        var out: [Filesystem] = []
        for i in 0..<Int(n) {
            let f = list[i]
            let flags = Int32(bitPattern: f.f_flags)
            guard flags & MNT_LOCAL != 0, flags & MNT_DONTBROWSE == 0 else { continue }
            let path = withUnsafeBytes(of: f.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            guard path == "/" || path.hasPrefix("/Volumes/") else { continue }
            let dev = withUnsafeBytes(of: f.f_mntfromname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let type = withUnsafeBytes(of: f.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let b = UInt64(f.f_bsize)
            // "/" is the sealed, read-only system volume; what the user
            // writes to is the Data volume beside it.
            var readOnly = flags & MNT_RDONLY != 0
            var data = statfs()
            if path == "/", statfs("/System/Volumes/Data", &data) == 0 {
                readOnly = Int32(bitPattern: data.f_flags) & MNT_RDONLY != 0
            }
            out.append(Filesystem(mountpoint: path, device: dev, fstype: type,
                                  size: f.f_blocks * b, free: f.f_bfree * b, avail: f.f_bavail * b,
                                  files: f.f_files, filesFree: f.f_ffree,
                                  readOnly: readOnly))
        }
        return out
    }

    // MARK: Network interfaces (64-bit counters)

    struct Interface {
        var name: String
        var rxBytes: UInt64, txBytes: UInt64, rxPackets: UInt64, txPackets: UInt64
        var rxErrors: UInt64, txErrors: UInt64, rxDrops: UInt64, txDrops: UInt64
        var rxMulticast: UInt64, txMulticast: UInt64, collisions: UInt64
        var mtu: UInt32, baudRate: UInt64, up: Bool, running: Bool
    }

    /// Interfaces that are up and have carried traffic (macOS keeps a dozen
    /// idle ones: anpi, ap, llw, nan, unused utuns…). NET_RT_IFLIST2 gives
    /// 64-bit counters; getifaddrs' wrap at 4 GB.
    static func interfaces() -> [Interface] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buffer, &len, nil, 0) == 0 else { return [] }
        var out: [Interface] = []
        buffer.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= len {
                let header = base.advanced(by: offset).loadUnaligned(as: if_msghdr.self)
                guard header.ifm_msglen > 0 else { break }
                defer { offset += Int(header.ifm_msglen) }
                guard Int32(header.ifm_type) == RTM_IFINFO2,
                      offset + MemoryLayout<if_msghdr2>.size <= len else { continue }
                let h = base.advanced(by: offset).loadUnaligned(as: if_msghdr2.self)
                let d = h.ifm_data
                let flags = h.ifm_flags
                guard flags & IFF_UP != 0, d.ifi_ipackets + d.ifi_opackets > 0 else { continue }
                var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
                guard if_indextoname(UInt32(h.ifm_index), &name) != nil else { continue }
                out.append(Interface(
                    name: String(cString: name),
                    rxBytes: d.ifi_ibytes, txBytes: d.ifi_obytes,
                    rxPackets: d.ifi_ipackets, txPackets: d.ifi_opackets,
                    rxErrors: d.ifi_ierrors, txErrors: d.ifi_oerrors,
                    rxDrops: d.ifi_iqdrops, txDrops: UInt64(max(0, h.ifm_snd_drops)),
                    rxMulticast: d.ifi_imcasts, txMulticast: d.ifi_omcasts, collisions: d.ifi_collisions,
                    mtu: d.ifi_mtu, baudRate: d.ifi_baudrate,
                    up: true, running: flags & IFF_RUNNING != 0))
            }
        }
        return out
    }

    // MARK: Clock discipline (ntp_adjtime, read-only)

    /// struct timex from <sys/timex.h>, which Swift doesn't import.
    struct Timex {
        var modes: UInt32 = 0
        var offset = 0, freq = 0, maxerror = 0, esterror = 0
        var status: Int32 = 0
        var constant = 0, precision = 0, tolerance = 0
        var ppsfreq = 0, jitter = 0
        var shift: Int32 = 0
        var stabil = 0, jitcnt = 0, calcnt = 0, errcnt = 0, stbcnt = 0
    }

    static let staUnsync: Int32 = 0x0040
    static let staNano: Int32 = 0x2000

    /// modes = 0 only reads the kernel's clock state; it changes nothing.
    static func timex() -> Timex? {
        var t = Timex()
        return sysbar_ntp_adjtime(&t) >= 0 ? t : nil
    }
}

@_silgen_name("ntp_adjtime")
private func sysbar_ntp_adjtime(_ t: UnsafeMutablePointer<NodeCollectors.Timex>) -> Int32

// MARK: - Rendering

extension MetricsExporter {
    /// node_exporter-named metrics beyond the basics in render().
    func renderNodeCollectors(into out: inout MetricsText, snapshot s: SystemStatsSnapshot) {
        var durations: [(String, Double)] = []
        func timed(_ collector: String, _ body: () -> Void) {
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            durations.append((collector, Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9))
        }

        timed("diskstats") {
            guard let d = NodeCollectors.disks() else { return }
            let l = ["device": "all"]
            out.counter("node_disk_read_bytes_total", "Bytes read from all disks.", [(l, Double(d.readBytes))])
            out.counter("node_disk_written_bytes_total", "Bytes written to all disks.", [(l, Double(d.writtenBytes))])
            out.counter("node_disk_reads_completed_total", "Reads completed.", [(l, Double(d.reads))])
            out.counter("node_disk_writes_completed_total", "Writes completed.", [(l, Double(d.writes))])
            out.counter("node_disk_read_time_seconds_total", "Time spent reading.", [(l, Double(d.readTimeNs) / 1e9)])
            out.counter("node_disk_write_time_seconds_total", "Time spent writing.", [(l, Double(d.writeTimeNs) / 1e9)])
            // Busy time: macOS only sums the time of each request, which can
            // exceed wall time when requests overlap. That sum is exactly the
            // "weighted" counter; the busy one is capped at wall time per
            // scrape so utilization stays within 0-100 %.
            let busy = d.readTimeNs &+ d.writeTimeNs
            let now = DispatchTime.now().uptimeNanoseconds
            if let last = diskBusy, busy >= last.busyNs, now > last.wallNs {
                diskBusy = (busy, now, last.total + Double(min(busy - last.busyNs, now - last.wallNs)) / 1e9)
            } else {
                diskBusy = (busy, now, diskBusy?.total ?? 0)
            }
            out.counter("node_disk_io_time_seconds_total", "Time the disks were busy (capped at wall time).",
                        [(l, diskBusy?.total ?? 0)])
            out.counter("node_disk_io_time_weighted_seconds_total", "Time spent on all requests (sum of their durations).",
                        [(l, Double(busy) / 1e9)])
            out.counter("node_disk_read_errors_total", "Read errors.", [(l, Double(d.readErrors))])
            out.counter("node_disk_write_errors_total", "Write errors.", [(l, Double(d.writeErrors))])
        }

        timed("meminfo") {
            guard let v = NodeCollectors.vm() else { return }
            let p = Double(v.page)
            out.gauge("node_memory_Active_bytes", "Active memory (Linux name).", [([:], Double(v.active) * p)])
            out.gauge("node_memory_Inactive_bytes", "Inactive + speculative memory (Linux name).",
                      [([:], Double(v.inactive + v.speculative) * p)])
            out.gauge("node_memory_AnonPages_bytes", "Anonymous memory: macOS internal pages (Linux name).",
                      [([:], Double(v.anonymous) * p)])
            out.gauge("node_memory_Mapped_bytes", "File-backed memory: macOS external pages (Linux name).",
                      [([:], Double(v.fileBacked) * p)])
            out.gauge("node_memory_Unevictable_bytes", "Wired memory, which can't be paged out (Linux name).",
                      [([:], Double(v.wired) * p)])
            out.gauge("node_memory_purgeable_bytes", "Purgeable memory.", [([:], Double(v.purgeable) * p)])
            // Terms of the "Memory Stack" panel's formula that don't exist on
            // macOS; without them the whole formula has no result.
            for name in ["Slab", "PageTables", "SwapCached", "HardwareCorrupted"] {
                out.gauge("node_memory_\(name)_bytes", "Not on macOS, always 0 (Linux name).", [([:], 0)])
            }
            out.counter("node_vmstat_pgpgin", "KiB paged in from disk.", [([:], Double(v.pageins) * p / 1024)])
            out.counter("node_vmstat_pgpgout", "KiB paged out to disk.", [([:], Double(v.pageouts) * p / 1024)])
            out.counter("node_vmstat_pswpin", "Pages swapped in.", [([:], Double(v.swapins))])
            out.counter("node_vmstat_pswpout", "Pages swapped out.", [([:], Double(v.swapouts))])
            out.counter("node_vmstat_pgfault", "Page faults.", [([:], Double(v.faults))])
            out.counter("node_vmstat_pgmajfault", "Page faults that read from disk (pageins).", [([:], Double(v.pageins))])
            out.counter("sysbar_vmstat_cow_faults_total", "Copy-on-write faults.", [([:], Double(v.cowFaults))])
            out.counter("sysbar_vmstat_compressions_total", "Pages compressed.", [([:], Double(v.compressions))])
            out.counter("sysbar_vmstat_decompressions_total", "Pages decompressed.", [([:], Double(v.decompressions))])
        }

        timed("processes") {
            if let t = NodeCollectors.tasksAndThreads() {
                out.gauge("node_processes_pids", "Number of processes.", [([:], Double(t.tasks))])
                out.gauge("node_processes_threads", "Number of threads.", [([:], Double(t.threads))])
            }
            if let v = NodeCollectors.sysctlInt("kern.maxproc") {
                out.gauge("node_processes_max_processes", "Process limit (kern.maxproc).", [([:], Double(v))])
            }
            if let v = NodeCollectors.sysctlInt("kern.num_threads") {
                out.gauge("node_processes_max_threads", "Thread limit (kern.num_threads).", [([:], Double(v))])
            }
        }

        timed("filefd") {
            if let v = NodeCollectors.sysctlInt("kern.num_files") {
                out.gauge("node_filefd_allocated", "Open files.", [([:], Double(v))])
            }
            if let v = NodeCollectors.sysctlInt("kern.maxfiles") {
                out.gauge("node_filefd_maximum", "Open files limit.", [([:], Double(v))])
            }
        }

        timed("filesystem") {
            let list = NodeCollectors.filesystems()
            guard !list.isEmpty else { return }
            // "/" keeps the startup volume's name and Finder's free space
            // (which counts purgeable space), as before.
            func labels(_ f: NodeCollectors.Filesystem) -> [String: String] {
                ["mountpoint": f.mountpoint, "fstype": f.fstype,
                 "device": f.mountpoint == "/" ? (s.disk?.name ?? f.device) : f.device]
            }
            out.gauge("node_filesystem_size_bytes", "Volume size.", list.map {
                (labels($0), $0.mountpoint == "/" ? Double(s.disk?.totalBytes ?? $0.size) : Double($0.size))
            })
            out.gauge("node_filesystem_avail_bytes", "Space available.", list.map {
                (labels($0), $0.mountpoint == "/" ? Double(s.disk?.freeBytes ?? $0.avail) : Double($0.avail))
            })
            out.gauge("node_filesystem_free_bytes", "Free space.", list.map { (labels($0), Double($0.free)) })
            out.gauge("node_filesystem_files", "File nodes.", list.map { (labels($0), Double($0.files)) })
            out.gauge("node_filesystem_files_free", "Free file nodes.", list.map { (labels($0), Double($0.filesFree)) })
            out.gauge("node_filesystem_readonly", "1 if mounted read-only.", list.map { (labels($0), $0.readOnly ? 1 : 0) })
            out.gauge("node_filesystem_device_error", "1 if the volume couldn't be read.", list.map { (labels($0), 0) })
        }

        timed("netdev") {
            let list = NodeCollectors.interfaces()
            guard !list.isEmpty else { return }
            func rows(_ value: (NodeCollectors.Interface) -> Double) -> [([String: String], Double)] {
                list.map { (["device": $0.name], value($0)) }
            }
            out.counter("node_network_receive_bytes_total", "Bytes received.", rows { Double($0.rxBytes) })
            out.counter("node_network_transmit_bytes_total", "Bytes sent.", rows { Double($0.txBytes) })
            out.counter("node_network_receive_packets_total", "Packets received.", rows { Double($0.rxPackets) })
            out.counter("node_network_transmit_packets_total", "Packets sent.", rows { Double($0.txPackets) })
            out.counter("node_network_receive_errs_total", "Receive errors.", rows { Double($0.rxErrors) })
            out.counter("node_network_transmit_errs_total", "Transmit errors.", rows { Double($0.txErrors) })
            out.counter("node_network_receive_drop_total", "Packets dropped on receive.", rows { Double($0.rxDrops) })
            out.counter("node_network_transmit_drop_total", "Packets dropped on send.", rows { Double($0.txDrops) })
            out.counter("node_network_receive_multicast_total", "Multicast packets received.", rows { Double($0.rxMulticast) })
            out.counter("node_network_transmit_multicast_total", "Multicast packets sent.", rows { Double($0.txMulticast) })
            out.counter("node_network_transmit_colls_total", "Collisions.", rows { Double($0.collisions) })
            out.gauge("node_network_mtu_bytes", "MTU.", rows { Double($0.mtu) })
            out.gauge("node_network_speed_bytes", "Link speed, bytes per second.",
                      list.filter { $0.baudRate > 0 }.map { (["device": $0.name], Double($0.baudRate) / 8) })
            out.gauge("node_network_up", "1 if the interface is up.", rows { $0.up ? 1 : 0 })
            out.gauge("node_network_carrier", "1 if the interface is running.", rows { $0.running ? 1 : 0 })
        }

        timed("netstat") {
            if let v = NodeCollectors.sysctlInt("net.inet.ip.forwarding") {
                out.gauge("node_netstat_Ip_Forwarding", "1 if IP forwarding is on.", [([:], Double(v))])
            }
            if let u = NodeCollectors.sysctlStruct("net.inet.udp.stats", udpstat()) {
                let bad = UInt64(u.udps_hdrops) + UInt64(u.udps_badsum) + UInt64(u.udps_badlen)
                let undelivered = bad + UInt64(u.udps_noport) + UInt64(u.udps_noportbcast) + UInt64(u.udps_fullsock)
                let received = UInt64(u.udps_ipackets)
                out.counter("node_netstat_Udp_InDatagrams", "UDP datagrams delivered.",
                            [([:], Double(received > undelivered ? received - undelivered : 0))])
                out.counter("node_netstat_Udp_OutDatagrams", "UDP datagrams sent.", [([:], Double(u.udps_opackets))])
                out.counter("node_netstat_Udp_InErrors", "UDP datagrams with errors.", [([:], Double(bad))])
                out.counter("node_netstat_Udp_NoPorts", "UDP datagrams to a port nobody listens on.",
                            [([:], Double(UInt64(u.udps_noport) + UInt64(u.udps_noportbcast)))])
                out.counter("node_netstat_Udp_RcvbufErrors", "UDP datagrams dropped, socket buffer full.",
                            [([:], Double(u.udps_fullsock))])
            }
            if let i = NodeCollectors.sysctlStruct("net.inet.icmp.stats", icmpstat()) {
                let inMsgs = withUnsafeBytes(of: i.icps_inhist) { $0.bindMemory(to: UInt32.self).reduce(0) { $0 + UInt64($1) } }
                let outMsgs = withUnsafeBytes(of: i.icps_outhist) { $0.bindMemory(to: UInt32.self).reduce(0) { $0 + UInt64($1) } }
                let errors = UInt64(i.icps_badcode) + UInt64(i.icps_tooshort) + UInt64(i.icps_checksum) + UInt64(i.icps_badlen)
                out.counter("node_netstat_Icmp_InMsgs", "ICMP messages received.", [([:], Double(inMsgs))])
                out.counter("node_netstat_Icmp_OutMsgs", "ICMP messages sent.", [([:], Double(outMsgs))])
                out.counter("node_netstat_Icmp_InErrors", "ICMP messages received with errors.", [([:], Double(errors))])
            }
        }

        timed("timex") {
            guard let t = NodeCollectors.timex() else { return }
            let unit = t.status & NodeCollectors.staNano != 0 ? 1e9 : 1e6
            out.gauge("node_timex_offset_seconds", "Time offset to the reference clock.", [([:], Double(t.offset) / unit)])
            out.gauge("node_timex_frequency_adjustment_ratio", "Local clock frequency adjustment.",
                      [([:], 1 + Double(t.freq) / 65536 / 1e6)])
            out.gauge("node_timex_maxerror_seconds", "Maximum error.", [([:], Double(t.maxerror) / 1e6)])
            out.gauge("node_timex_estimated_error_seconds", "Estimated error.", [([:], Double(t.esterror) / 1e6)])
            out.gauge("node_timex_status", "Clock status flags.", [([:], Double(t.status))])
            out.gauge("node_timex_sync_status", "1 if the clock is synchronized.",
                      [([:], t.status & NodeCollectors.staUnsync == 0 ? 1 : 0)])
            out.gauge("node_timex_loop_time_constant", "Phase-locked loop time constant.", [([:], Double(t.constant))])
            out.gauge("node_timex_tolerance_ppm", "Clock frequency tolerance, ppm.", [([:], Double(t.tolerance) / 65536)])
        }

        timed("hwmon") {
            guard s.sensors != nil else { return }
            out.gauge("node_hwmon_chip_names", "Hardware monitor chips.", [(["chip": "smc", "chip_name": "apple_smc"], 1)])
        }

        timed("power_supply") {
            guard let b = s.battery else { return }
            out.gauge("node_power_supply_online", "1 if the power supply is connected.",
                      [(["power_supply": "AC"], b.externalConnected ? 1 : 0)])
        }

        renderProcessMetrics(into: &out)

        out.gauge("node_scrape_collector_duration_seconds", "How long each collector took.",
                  durations.map { (["collector": $0.0], $0.1) })
        out.gauge("node_scrape_collector_success", "1 if the collector succeeded.",
                  durations.map { (["collector": $0.0], 1) })
    }
}

// MARK: - The exporter's own process

extension MetricsExporter {
    /// The process_* metrics every Prometheus client library exports about
    /// itself; "Node Exporter Full" charts them (memory, CPU, open files).
    func renderProcessMetrics(into out: inout MetricsText) {
        let pid = getpid()
        var task = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        if proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, size) == size {
            var timebase = mach_timebase_info_data_t()
            mach_timebase_info(&timebase)
            let ns = Double(task.pti_total_user + task.pti_total_system) * Double(timebase.numer) / Double(timebase.denom)
            out.counter("process_cpu_seconds_total", "Total user and system CPU time spent in seconds.", [([:], ns / 1e9)])
            out.gauge("process_resident_memory_bytes", "Resident memory size in bytes.", [([:], Double(task.pti_resident_size))])
            out.gauge("process_virtual_memory_bytes", "Virtual memory size in bytes.", [([:], Double(task.pti_virtual_size))])
        }
        let fdBytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        if fdBytes > 0 {
            var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(fdBytes) / MemoryLayout<proc_fdinfo>.stride)
            let used = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, fdBytes)
            if used >= 0 {
                out.gauge("process_open_fds", "Number of open file descriptors.",
                          [([:], Double(Int(used) / MemoryLayout<proc_fdinfo>.stride))])
            }
        }
        var limit = rlimit()
        if getrlimit(RLIMIT_NOFILE, &limit) == 0 {
            out.gauge("process_max_fds", "Maximum number of open file descriptors.", [([:], Double(limit.rlim_cur))])
        }
        if getrlimit(RLIMIT_AS, &limit) == 0 {
            out.gauge("process_virtual_memory_max_bytes", "Maximum amount of virtual memory available in bytes.",
                      [([:], Double(limit.rlim_cur))])
        }
        var info = kinfo_proc()
        var infoSize = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        if sysctl(&mib, 4, &info, &infoSize, nil, 0) == 0 {
            let start = info.kp_proc.p_starttime
            out.gauge("process_start_time_seconds", "Start time of the process since unix epoch in seconds.",
                      [([:], Double(start.tv_sec) + Double(start.tv_usec) / 1e6)])
        }
    }
}
