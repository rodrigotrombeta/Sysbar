// "Detailed" disk usage for the Disk pie chart, computed on demand: APFS
// volume sizes (instant), purgeable space (instant) and the size of
// /Applications (a folder scan, a few seconds). The rest of the used space
// is the user's files and everything else on the Data volume. The home
// folder isn't scanned: that would trigger macOS privacy prompts for
// Desktop, Documents, Downloads and other apps' data.

import Foundation

struct DiskBreakdown: Sendable {
    var total: UInt64
    /// macOS itself: the sealed System volume plus Preboot and helper volumes.
    var system: UInt64
    /// Swap files (the VM volume).
    var swap: UInt64
    var applications: UInt64
    /// Space macOS can free on its own (caches, iCloud copies, snapshots).
    var purgeable: UInt64
    /// Truly free space (without purgeable).
    var free: UInt64
    var measuredAt: Date
    var duration: TimeInterval

    /// Used space not in the categories above: your files, other apps' data…
    var other: UInt64 {
        let known = system + swap + applications + purgeable + free
        return total > known ? total - known : 0
    }

    static func measure() -> DiskBreakdown? {
        let start = Date()
        let root = URL(fileURLWithPath: "/")
        guard let values = try? root.resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ]), let total = values.volumeTotalCapacity, total > 0 else { return nil }
        let available = UInt64(max(0, values.volumeAvailableCapacity ?? 0))
        let important = UInt64(max(0, values.volumeAvailableCapacityForImportantUsage ?? Int64(available)))

        let systemVolumes = ["/", "/System/Volumes/Preboot", "/System/Volumes/Update",
                             "/System/Volumes/xarts", "/System/Volumes/iSCPreboot",
                             "/System/Volumes/Hardware"]
        let system = systemVolumes.compactMap(volumeSpaceUsed).reduce(0, +)
        let swap = volumeSpaceUsed("/System/Volumes/VM") ?? 0
        let applications = folderSize(URL(fileURLWithPath: "/Applications"))

        return DiskBreakdown(
            total: UInt64(total), system: system, swap: swap, applications: applications,
            purgeable: important > available ? important - available : 0,
            free: available, measuredAt: Date(), duration: Date().timeIntervalSince(start))
    }

    /// Space used by one APFS volume (ATTR_VOL_SPACEUSED).
    private static func volumeSpaceUsed(_ path: String) -> UInt64? {
        var attrs = attrlist(bitmapcount: u_short(ATTR_BIT_MAP_COUNT), reserved: 0, commonattr: 0,
                             volattr: attrgroup_t(ATTR_VOL_INFO) | attrgroup_t(ATTR_VOL_SPACEUSED),
                             dirattr: 0, fileattr: 0, forkattr: 0)
        var buffer = [UInt8](repeating: 0, count: 64)
        guard getattrlist(path, &attrs, &buffer, buffer.count, 0) == 0 else { return nil }
        // Layout: UInt32 length, then the UInt64 value.
        return buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt64.self) }
    }

    /// Allocated size of everything under `url` (hard links counted once).
    private static func folderSize(_ url: URL) -> UInt64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey, .linkCountKey, .fileResourceIdentifierKey]
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys,
                                                          options: [], errorHandler: { _, _ in true })
        else { return 0 }
        var total: UInt64 = 0
        var seenLinks = Set<String>()
        for case let file as URL in walker {
            guard let v = try? file.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            if (v.linkCount ?? 1) > 1, let id = v.fileResourceIdentifier {
                guard seenLinks.insert(String(describing: id)).inserted else { continue }
            }
            total += UInt64(v.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
