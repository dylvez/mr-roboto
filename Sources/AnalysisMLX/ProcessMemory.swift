import Darwin
import Foundation
import MLX

/// Process-level memory readings for benchmarks and tests.
public enum ProcessMemory {
    /// Current resident set size in bytes (mach `task_info` basic info).
    public static func residentBytes() -> UInt64 { basicInfo()?.resident_size ?? 0 }

    /// Peak resident set size since process start, in bytes.
    public static func peakResidentBytes() -> UInt64 { basicInfo()?.resident_size_max ?? 0 }

    /// Resident and peak-resident in one read. Two separate calls can disagree — the process can
    /// grow between them, making "current" exceed a "peak" sampled earlier — so anything comparing
    /// the two must use this.
    public static func snapshot() -> (resident: UInt64, peak: UInt64)? {
        basicInfo().map { ($0.resident_size, $0.resident_size_max) }
    }

    /// Peak MLX allocation (active + cache high-water mark) since process start, in bytes.
    public static func mlxPeakBytes() -> Int { Memory.peakMemory }

    private static func basicInfo() -> mach_task_basic_info? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        // `task_self_trap()` rather than the `mach_task_self_` global, which Swift 6 rejects as shared mutable state.
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { raw in
                task_info(task_self_trap(), task_flavor_t(MACH_TASK_BASIC_INFO), raw, &count)
            }
        }
        return kr == KERN_SUCCESS ? info : nil
    }
}
