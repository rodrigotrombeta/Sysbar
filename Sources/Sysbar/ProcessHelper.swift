// "Show all processes": without root, processes of other users (e.g.
// WindowServer, root daemons) can't be read. On request, Sysbar starts a copy
// of itself as root (`--process-helper`) through the standard macOS
// administrator password prompt. The helper only answers sample requests:
// Sysbar writes one byte to a request FIFO when a panel showing processes
// needs a sample, the helper replies with one JSON line on a data FIFO. It
// reads nothing else, and exits when Sysbar closes the FIFOs (stop or quit).
// Nothing is remembered: the next launch asks again.

import AppKit
import Darwin

// MARK: - Sysbar side

@MainActor
final class ProcessHelperClient {
    enum State: Equatable { case off, starting, on, failed(String) }

    private(set) var state: State = .off {
        didSet { onStateChange(state) }
    }
    var onStateChange: (State) -> Void = { _ in }

    private var requestFD: Int32 = -1
    private var dataFD: Int32 = -1
    private var directory: URL?
    private var pending = Data()
    private let queue = DispatchQueue(label: "sysbar.process-helper")
    private var inFlight = false

    var isOn: Bool { state == .on }

    /// Asks for the admin password and starts the root helper.
    func start() {
        guard state == .off || isFailed else { return }
        state = .starting
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sysbar-helper-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        let request = dir.appendingPathComponent("request").path
        let data = dir.appendingPathComponent("data").path
        guard mkfifo(request, 0o600) == 0, mkfifo(data, 0o600) == 0,
              let binary = Bundle.main.executablePath else {
            try? FileManager.default.removeItem(at: dir)
            state = .failed("mkfifo")
            return
        }
        directory = dir

        let command = "\(quoted(binary)) --process-helper \(quoted(request)) \(quoted(data)) >/dev/null 2>&1 &"
        let prompt = tr("Sysbar wants to read the memory and CPU use of all processes, including other users'.",
                        "O Sysbar quer ler o uso de memória e CPU de todos os processos, inclusive de outros usuários.")
        let source = "do shell script \(appleScriptString(command)) with prompt \(appleScriptString(prompt)) with administrator privileges"

        queue.async { [weak self] in
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            if let error {
                let cancelled = (error[NSAppleScript.errorNumber] as? Int) == -128
                DispatchQueue.main.async {
                    self?.cleanUp()
                    self?.state = cancelled ? .off : .failed(error[NSAppleScript.errorMessage] as? String ?? "")
                }
                return
            }
            // Same order as the helper: request (write end), then data (read end).
            let req = Self.openWithTimeout(request, flags: O_WRONLY)
            let dat = req >= 0 ? open(data, O_RDONLY) : -1
            DispatchQueue.main.async {
                guard let self else { return }
                if req >= 0, dat >= 0 {
                    self.requestFD = req
                    self.dataFD = dat
                    self.state = .on
                } else {
                    if req >= 0 { close(req) }
                    self.cleanUp()
                    self.state = .failed(tr("The helper didn't start.", "O auxiliar não iniciou."))
                }
            }
        }
    }

    /// Closes the FIFOs; the helper exits.
    func stop() {
        cleanUp()
        state = .off
    }

    /// Requests one sample; `completion` runs on the main thread (nil if the
    /// helper is gone, which also turns it off).
    func sample(_ completion: @escaping (ProcessSnapshot?) -> Void) {
        guard isOn, !inFlight else { return }
        inFlight = true
        let req = requestFD, dat = dataFD
        let buffered = pending
        queue.async { [weak self] in
            var buffer = buffered
            var byte: UInt8 = 1
            var line: Data?
            if write(req, &byte, 1) == 1 {
                line = Self.readLine(dat, buffer: &buffer)
            }
            let snapshot = line.flatMap { try? JSONDecoder().decode(ProcessSnapshot.self, from: $0) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight = false
                self.pending = buffer
                if line == nil {
                    self.cleanUp()
                    self.state = .failed(tr("The helper stopped.", "O auxiliar parou."))
                }
                completion(snapshot)
            }
        }
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    private func cleanUp() {
        if requestFD >= 0 { close(requestFD) }
        if dataFD >= 0 { close(dataFD) }
        requestFD = -1
        dataFD = -1
        pending = Data()
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }

    /// One newline-terminated line, waiting at most 3 s.
    nonisolated private static func readLine(_ fd: Int32, buffer: inout Data) -> Data? {
        let deadline = Date().addingTimeInterval(3)
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer = Data(buffer[buffer.index(after: newline)...])
                return Data(line)
            }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let remaining = Int32(max(0, deadline.timeIntervalSinceNow) * 1000)
            guard remaining > 0, poll(&pfd, 1, remaining) > 0 else { return nil }
            var chunk = [UInt8](repeating: 0, count: 16384)
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else { return nil }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }

    /// Opens a FIFO's write end, waiting up to 15 s for the reader.
    nonisolated private static func openWithTimeout(_ path: String, flags: Int32) -> Int32 {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            let fd = open(path, flags | O_NONBLOCK)
            if fd >= 0 {
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
                return fd
            }
            guard errno == ENXIO else { return -1 }
            usleep(100_000)
        }
        return -1
    }

    private func quoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private func appleScriptString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

// MARK: - Root side

@MainActor
enum ProcessHelper {
    /// `Sysbar --process-helper <request fifo> <data fifo>`, run as root.
    static func run(request: String, data: String) -> Never {
        signal(SIGPIPE, SIG_IGN)
        let req = openFIFO(request, flags: O_RDONLY)
        let out = openFIFO(data, flags: O_WRONLY)
        let sampler = ProcessSampler()
        let ownPID = getpid()
        _ = sampler.sample()
        var byte: UInt8 = 0
        // One sample per request byte; EOF = Sysbar stopped or quit.
        while read(req, &byte, 1) == 1 {
            var snapshot = sampler.sample()
            snapshot.topMemory.removeAll { $0.pid == ownPID }
            snapshot.topCPU.removeAll { $0.pid == ownPID }
            guard var line = try? JSONEncoder().encode(snapshot) else { continue }
            line.append(0x0A)
            let ok = line.withUnsafeBytes { raw -> Bool in
                var offset = 0
                while offset < raw.count {
                    let n = write(out, raw.baseAddress! + offset, raw.count - offset)
                    if n <= 0 { return false }
                    offset += n
                }
                return true
            }
            if !ok { break }
        }
        exit(0)
    }

    /// Opens only an existing FIFO (no symlinks, no regular files).
    private static func openFIFO(_ path: String, flags: Int32) -> Int32 {
        let fd = open(path, flags | O_NOFOLLOW)
        var info = stat()
        guard fd >= 0, fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFIFO else { exit(1) }
        return fd
    }
}
