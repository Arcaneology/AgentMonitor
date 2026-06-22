import Darwin
import Foundation

protocol ProcessCollecting: Sendable {
    func collect(pid: Int32) -> MonitoredProcess?
}

struct DarwinProcessCollector: ProcessCollecting {
    private let ownerUID: UInt32

    init(ownerUID: UInt32) {
        self.ownerUID = ownerUID
    }

    func collect(pid: Int32) -> MonitoredProcess? {
        guard
            let bsdInfo = bsdInfo(for: pid),
            bsdInfo.pbi_uid == ownerUID
        else {
            return nil
        }

        let startTime = Date(
            timeIntervalSince1970: TimeInterval(bsdInfo.pbi_start_tvsec)
                + TimeInterval(bsdInfo.pbi_start_tvusec) / 1_000_000
        )

        return MonitoredProcess(
            id: ProcessIdentity(pid: pid, startTime: startTime),
            ownerUID: bsdInfo.pbi_uid,
            executablePath: executablePath(for: pid, bsdInfo: bsdInfo),
            arguments: [],
            workingDirectory: workingDirectory(for: pid),
            memoryBytes: memoryUsage(for: pid)
        )
    }

    private func bsdInfo(for pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.size
        let actualSize = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, Int32(expectedSize))
        }
        return actualSize == expectedSize ? info : nil
    }

    private func executablePath(for pid: Int32, bsdInfo: proc_bsdinfo) -> String {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = buffer.withUnsafeMutableBytes {
            proc_pidpath(pid, $0.baseAddress, UInt32($0.count))
        }
        if length > 0 {
            let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            return String(decoding: bytes, as: UTF8.self)
        }

        var name = bsdInfo.pbi_name
        let nameCapacity = MemoryLayout.size(ofValue: name)
        return withUnsafePointer(to: &name) {
            $0.withMemoryRebound(to: CChar.self, capacity: nameCapacity) {
                String(cString: $0)
            }
        }
    }

    private func workingDirectory(for pid: Int32) -> URL? {
        var info = proc_vnodepathinfo()
        let expectedSize = MemoryLayout<proc_vnodepathinfo>.size
        let actualSize = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, $0, Int32(expectedSize))
        }
        guard actualSize == expectedSize else { return nil }

        var path = info.pvi_cdir.vip_path
        let pathCapacity = MemoryLayout.size(ofValue: path)
        let value = withUnsafePointer(to: &path) {
            $0.withMemoryRebound(to: CChar.self, capacity: pathCapacity) {
                String(cString: $0)
            }
        }
        return value.isEmpty ? nil : URL(fileURLWithPath: value, isDirectory: true)
    }

    private func memoryUsage(for pid: Int32) -> UInt64 {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard result == 0 else { return 0 }
        return info.ri_phys_footprint > 0 ? info.ri_phys_footprint : info.ri_resident_size
    }
}
