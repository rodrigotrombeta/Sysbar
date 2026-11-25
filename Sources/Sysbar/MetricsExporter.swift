// Prometheus endpoint: GET /metrics returns what Sysbar measures, in the
// Prometheus text format, for Grafana (or any Prometheus) to scrape.
//
// Metrics node_exporter also has keep node_exporter's names, so its
// dashboards work with this Mac; the rest are sysbar_*. Off by default, and
// it only listens on this Mac (127.0.0.1) or its Tailscale address, never on
// every interface: the endpoint has no authentication.

import Foundation
import Network

@MainActor
final class MetricsExporter {
    static let shared = MetricsExporter()

    /// An IPv4 address of this Mac the endpoint can listen on.
    struct Address: Hashable {
        enum Kind { case loopback, tailscale, vpn, local }
        /// Saved choice: "localhost", "tailscale" (whatever its address or
        /// utun name), or "if:<interface>" for a VPN / local interface.
        let key: String
        let interface: String
        let ip: String
        let kind: Kind

        var title: String {
            switch kind {
            case .loopback: return tr("This Mac only", "Só este Mac") + " (127.0.0.1)"
            case .tailscale: return "Tailscale · \(ip)"
            case .vpn: return "VPN · \(ip) (\(interface))"
            case .local: return tr("Local network", "Rede local") + " · \(ip) (\(interface))"
            }
        }
    }

    /// What the server is doing, for Settings.
    private(set) var status = ""
    var onStatusChange: () -> Void = {}

    private weak var model: AppModel?
    private var listener: NWListener?
    private var running: (host: String, port: UInt16)?
    private let queue = DispatchQueue(label: "local.sysbar.metrics")

    func attach(_ model: AppModel) { self.model = model }

    /// Starts, restarts or stops the server to match the settings.
    func apply() {
        guard Settings.metricsExport else {
            stop()
            setStatus("")
            return
        }
        let key = Settings.metricsListen
        guard let host = Self.addresses().first(where: { $0.key == key })?.ip else {
            stop()
            setStatus(key == "tailscale"
                      ? tr("Tailscale isn't connected on this Mac.", "O Tailscale não está conectado neste Mac.")
                      : tr("\(key.replacingOccurrences(of: "if:", with: "")) isn't connected.",
                           "\(key.replacingOccurrences(of: "if:", with: "")) não está conectada."))
            return
        }
        let port = UInt16(clamping: Settings.metricsPort)
        if let running, running == (host, port), listener != nil { return }
        stop()
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            params.requiredLocalEndpoint = .hostPort(host: .init(host), port: .init(rawValue: port)!)
            let listener = try NWListener(using: params)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.serve(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.setStatus("http://\(host):\(port)/metrics")
                    case .failed(let error):
                        self.setStatus(tr("Can't listen on port \(port): ", "Não foi possível usar a porta \(port): ")
                                       + error.localizedDescription)
                        self.stop()
                    default: break
                    }
                }
            }
            listener.start(queue: queue)
            self.listener = listener
            running = (host, port)
        } catch {
            setStatus(error.localizedDescription)
        }
    }

    private func stop() {
        listener?.cancel()
        listener = nil
        running = nil
    }

    private func setStatus(_ text: String) {
        guard text != status else { return }
        status = text
        onStatusChange()
    }

    // MARK: HTTP

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
                let line = request.split(separator: "\r\n", maxSplits: 1).first ?? ""
                let parts = line.split(separator: " ")
                let path = parts.count > 1 ? parts[1] : ""
                let response: Data
                if parts.first == "GET", path == "/metrics" || path.hasPrefix("/metrics?") {
                    response = Self.http(200, "OK", type: "text/plain; version=0.0.4; charset=utf-8", body: self.render())
                } else if parts.first == "GET", path == "/" {
                    response = Self.http(200, "OK", type: "text/html; charset=utf-8",
                                         body: "<html><body><a href=\"/metrics\">Sysbar metrics</a></body></html>\n")
                } else {
                    response = Self.http(404, "Not Found", type: "text/plain", body: "Not found\n")
                }
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    private static func http(_ code: Int, _ reason: String, type: String, body: String) -> Data {
        let bytes = Data(body.utf8)
        let head = "HTTP/1.1 \(code) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + bytes
    }

    // MARK: Metrics

    /// The exposition text, built from the latest sample.
    func render() -> String {
        var out = MetricsText()
        guard let model else { return "" }
        let s = model.snapshot

        out.gauge("sysbar_info", "Sysbar build information.",
                  [(["version": UpdateChecker.currentVersion], 1)])

        // node_exporter-compatible.
        let ticksPerSecond = Double(max(1, sysconf(Int32(_SC_CLK_TCK))))
        var cpu: [([String: String], Double)] = []
        for (i, t) in s.cpuTicks.enumerated() {
            let idle = t.total >= t.busy ? t.total - t.busy : 0
            cpu.append((["cpu": "\(i)", "mode": "user"], Double(t.user) / ticksPerSecond))
            cpu.append((["cpu": "\(i)", "mode": "system"], Double(t.system) / ticksPerSecond))
            cpu.append((["cpu": "\(i)", "mode": "idle"], Double(idle) / ticksPerSecond))
        }
        out.counter("node_cpu_seconds_total", "Seconds the CPUs spent in each mode.", cpu)

        let m = s.memory
        out.gauge("node_memory_total_bytes", "Physical memory.", [([:], Double(m.totalBytes))])
        out.gauge("node_memory_wired_bytes", "Wired memory.", [([:], Double(m.wiredBytes))])
        out.gauge("node_memory_active_bytes", "Active memory.", [([:], Double(m.activeBytes))])
        out.gauge("node_memory_compressed_bytes", "Compressed memory.", [([:], Double(m.compressedBytes))])
        out.gauge("node_memory_free_bytes", "Free memory.", [([:], Double(m.freeBytes))])
        out.gauge("node_memory_swap_used_bytes", "Swap used.", [([:], Double(m.swapUsedBytes))])
        out.gauge("node_memory_swap_total_bytes", "Swap size.", [([:], Double(m.swapTotalBytes))])

        // The same memory under the Linux names the usual Grafana dashboards
        // ("Node Exporter Full") query. Used = app + wired + compressed, as
        // in Activity Monitor; what's neither used nor free (file cache,
        // inactive pages) counts as cache, so the dashboards' "RAM used"
        // (total − free − cache) matches Sysbar's.
        let total = Double(m.totalBytes), used = Double(m.usedBytes), free = Double(m.freeBytes)
        let cache = max(0, total - used - free)
        out.gauge("node_memory_MemTotal_bytes", "Physical memory (Linux name).", [([:], total)])
        out.gauge("node_memory_MemFree_bytes", "Free memory (Linux name).", [([:], free)])
        out.gauge("node_memory_MemAvailable_bytes", "Memory available: total − used (Linux name).",
                  [([:], max(0, total - used))])
        out.gauge("node_memory_Cached_bytes", "Cached / inactive memory (Linux name).", [([:], cache)])
        out.gauge("node_memory_Buffers_bytes", "Always 0 on macOS (Linux name).", [([:], 0)])
        out.gauge("node_memory_SReclaimable_bytes", "Always 0 on macOS (Linux name).", [([:], 0)])
        out.gauge("node_memory_SwapTotal_bytes", "Swap size (Linux name).", [([:], Double(m.swapTotalBytes))])
        out.gauge("node_memory_SwapFree_bytes", "Swap free (Linux name).",
                  [([:], Double(m.swapTotalBytes > m.swapUsedBytes ? m.swapTotalBytes - m.swapUsedBytes : 0))])

        if s.loadAverages.count == 3 {
            out.gauge("node_load1", "1-minute load average.", [([:], s.loadAverages[0])])
            out.gauge("node_load5", "5-minute load average.", [([:], s.loadAverages[1])])
            out.gauge("node_load15", "15-minute load average.", [([:], s.loadAverages[2])])
        }
        out.gauge("node_time_seconds", "Current time, Unix seconds.", [([:], Date().timeIntervalSince1970)])
        out.gauge("node_boot_time_seconds", "Boot time, Unix seconds.",
                  [([:], (Date().timeIntervalSince1970 - s.uptimeSeconds).rounded())])

        out.counter("node_disk_read_bytes_total", "Bytes read from all disks.",
                    [(["device": "all"], Double(s.diskTotalRead))])
        out.counter("node_disk_written_bytes_total", "Bytes written to all disks.",
                    [(["device": "all"], Double(s.diskTotalWritten))])

        if let iface = s.networkInterface {
            out.counter("node_network_receive_bytes_total", "Bytes received.",
                        [(["device": iface], Double(s.networkRxBytes))])
            out.counter("node_network_transmit_bytes_total", "Bytes sent.",
                        [(["device": iface], Double(s.networkTxBytes))])
        }

        if let d = s.disk {
            let labels = ["mountpoint": "/", "device": d.name, "fstype": "apfs"]
            out.gauge("node_filesystem_size_bytes", "Volume size.", [(labels, Double(d.totalBytes))])
            out.gauge("node_filesystem_avail_bytes", "Space available.", [(labels, Double(d.freeBytes))])
        }

        // Sysbar-only.
        var usage: [([String: String], Double)] = []
        if let v = s.cpuTotalUsage { usage.append((["cluster": "all"], v)) }
        if let v = s.eCoreUsage { usage.append((["cluster": "efficiency"], v)) }
        if let v = s.pCoreUsage { usage.append((["cluster": "performance"], v)) }
        out.gauge("sysbar_cpu_usage_ratio", "CPU usage, 0-1 (all cores, E-cores, P-cores).", usage)
        out.gauge("sysbar_cpu_core_usage_ratio", "Usage per core, 0-1.",
                  s.coreUsage.enumerated().map { i, v in
                      (["core": i < s.eCoreCount ? "E\(i + 1)" : "P\(i - s.eCoreCount + 1)"], v)
                  })
        if let v = s.gpuUsage { out.gauge("sysbar_gpu_usage_ratio", "GPU usage, 0-1.", [([:], v)]) }
        if let v = s.gpuMemoryInUseBytes {
            out.gauge("sysbar_gpu_memory_in_use_bytes", "Memory in use by the GPU.", [([:], Double(v))])
        }
        out.gauge("sysbar_memory_app_bytes", "App memory (as in Activity Monitor).", [([:], Double(m.appBytes))])
        out.gauge("sysbar_memory_used_bytes", "Used memory: app + wired + compressed.", [([:], Double(m.usedBytes))])
        out.gauge("sysbar_memory_pressure_level", "Memory pressure: 1 normal, 2 warning, 4 critical.",
                  [([:], Double(s.memoryPressure))])
        out.gauge("sysbar_thermal_state", "Thermal state: 0 nominal, 1 fair, 2 serious, 3 critical.",
                  [([:], Double(s.thermalState.rawValue))])
        if let io = s.networkIO {
            out.gauge("sysbar_network_bytes_per_second", "Network throughput.",
                      [(["direction": "receive"], io.read), (["direction": "transmit"], io.write)])
        }
        if let io = s.diskIO {
            out.gauge("sysbar_disk_bytes_per_second", "Disk throughput.",
                      [(["direction": "read"], io.read), (["direction": "write"], io.write)])
        }

        if let b = s.battery {
            out.gauge("sysbar_battery_charge_ratio", "Battery charge, 0-1.", [([:], b.level)])
            out.gauge("sysbar_battery_charging", "1 while charging.", [([:], b.isCharging ? 1 : 0)])
            out.gauge("sysbar_battery_external_power", "1 on the power adapter.", [([:], b.externalConnected ? 1 : 0)])
            if let v = b.health { out.gauge("sysbar_battery_health_ratio", "Max capacity vs design, 0-1.", [([:], v)]) }
            if let v = b.cycleCount { out.gauge("sysbar_battery_cycles", "Charge cycles.", [([:], Double(v))]) }
            if let v = b.temperature { out.gauge("sysbar_battery_temperature_celsius", "Battery temperature.", [([:], v)]) }
            if let v = b.batteryWatts { out.gauge("sysbar_battery_power_watts", "Battery power.", [([:], v)]) }
            if let v = b.adapterInWatts { out.gauge("sysbar_adapter_power_watts", "Power from the adapter.", [([:], v)]) }
            if let m = b.minutesToEmpty {
                out.gauge("sysbar_battery_time_to_empty_seconds", "Estimated time left on battery.", [([:], Double(m * 60))])
            }
            if let m = b.minutesToFull {
                out.gauge("sysbar_battery_time_to_full_seconds", "Estimated time to full.", [([:], Double(m * 60))])
            }
        }

        if let sn = s.sensors {
            // node_exporter's hwmon names, so hardware dashboards pick them up.
            out.gauge("node_hwmon_temp_celsius", "SMC temperature sensors.",
                      sn.temperatures.map { (["chip": "smc", "sensor": $0.name, "key": $0.key, "group": $0.group.rawValue], $0.value) })
            var summary: [([String: String], Double)] = []
            for g in SensorReading.Group.allCases {
                if let v = sn.average(g) { summary.append((["group": g.rawValue, "stat": "average"], v)) }
                if let v = sn.hottest(g) { summary.append((["group": g.rawValue, "stat": "max"], v)) }
            }
            out.gauge("sysbar_temperature_celsius", "Temperature per sensor group (average and hottest).", summary)
            var power: [([String: String], Double)] = []
            if let v = sn.systemPower { power.append((["source": "system"], v)) }
            if let v = sn.dcInPower { power.append((["source": "dc_in"], v)) }
            if let v = sn.batteryPower { power.append((["source": "battery"], v)) }
            out.gauge("sysbar_power_watts", "Power from the SMC.", power)
            var volts: [([String: String], Double)] = []
            if let v = sn.dcInVoltage { volts.append((["rail": "dc_in"], v)) }
            if let v = sn.rail12V { volts.append((["rail": "12v"], v)) }
            out.gauge("sysbar_voltage_volts", "Voltages from the SMC.", volts)
            if let v = sn.dcInCurrent { out.gauge("sysbar_current_amps", "DC In current.", [(["rail": "dc_in"], v)]) }
        }

        var limits: [([String: String], Double)] = []
        var resets: [([String: String], Double)] = []
        for usage in s.claudeAccounts {
            let account = ClaudeUsageStore.displayName(usage)
            for (window, w) in [("5h", usage.fiveHour), ("7d", usage.sevenDay)] {
                guard let w else { continue }
                limits.append((["account": account, "window": window], w.percent))
                resets.append((["account": account, "window": window], w.resetsAt.timeIntervalSince1970))
            }
        }
        out.gauge("sysbar_claude_limit_used_percent", "Claude Code limit used, 0-100.", limits)
        out.gauge("sysbar_claude_limit_resets_at_seconds", "When the limit resets, Unix seconds.", resets)

        let p = model.processes
        out.gauge("sysbar_process_memory_bytes", "Memory of the top processes by memory.",
                  p.topMemory.prefix(10).map { (["name": $0.name, "pid": "\($0.pid)"], Double($0.memoryBytes)) })
        out.gauge("sysbar_process_cpu_ratio", "CPU of the top processes by CPU (1 = one core).",
                  p.topCPU.prefix(10).map { (["name": $0.name, "pid": "\($0.pid)"], $0.cpu) })
        return out.text
    }

    // MARK: Addresses

    /// This Mac's IPv4 addresses on interfaces that are up: loopback first,
    /// then Tailscale (100.64.0.0/10), VPN tunnels (utun, ipsec, ppp, tun,
    /// wg) and local networks.
    nonisolated static func addresses() -> [Address] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var found: [Address] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, let addr = entry.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let text = "\(ip >> 24).\((ip >> 16) & 0xFF).\((ip >> 8) & 0xFF).\(ip & 0xFF)"
            let address: Address
            if flags & IFF_LOOPBACK != 0 {
                guard text == "127.0.0.1" else { continue }
                address = Address(key: "localhost", interface: name, ip: text, kind: .loopback)
            } else if ip & 0xFFC0_0000 == 0x6440_0000 {
                // 100.64.0.0/10: Tailscale's (and Headscale's) range.
                address = Address(key: "tailscale", interface: name, ip: text, kind: .tailscale)
            } else if ["utun", "ipsec", "ppp", "tun", "wg"].contains(where: name.hasPrefix) {
                address = Address(key: "if:\(name)", interface: name, ip: text, kind: .vpn)
            } else if ip >> 16 == 0xA9FE {
                continue  // 169.254.x.x: no network configured
            } else {
                address = Address(key: "if:\(name)", interface: name, ip: text, kind: .local)
            }
            guard !found.contains(where: { $0.key == address.key }) else { continue }
            found.append(address)
        }
        let order: [Address.Kind] = [.loopback, .tailscale, .vpn, .local]
        return found.sorted { order.firstIndex(of: $0.kind)! < order.firstIndex(of: $1.kind)! }
    }
}

/// Builds Prometheus text exposition (one HELP/TYPE block per metric).
private struct MetricsText {
    private(set) var text = ""

    mutating func gauge(_ name: String, _ help: String, _ samples: [([String: String], Double)]) {
        add(name, help, "gauge", samples)
    }

    mutating func counter(_ name: String, _ help: String, _ samples: [([String: String], Double)]) {
        add(name, help, "counter", samples)
    }

    private mutating func add(_ name: String, _ help: String, _ type: String, _ samples: [([String: String], Double)]) {
        let real = samples.filter { $0.1.isFinite }
        guard !real.isEmpty else { return }
        text += "# HELP \(name) \(help)\n# TYPE \(name) \(type)\n"
        for (labels, value) in real {
            let l = labels.sorted { $0.key < $1.key }
                .map { "\($0.key)=\"\(Self.escape($0.value))\"" }
                .joined(separator: ",")
            text += l.isEmpty ? name : "\(name){\(l)}"
            text += " \(Self.format(value))\n"
        }
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private static func format(_ v: Double) -> String {
        v == v.rounded() && abs(v) < 1e15 ? String(Int64(v)) : String(v)
    }
}
