import Darwin
import Foundation
import IOKit

struct D200XMetricsSnapshot: Equatable, Sendable {
    var cpu: Double?
    var memory: Double?
    var gpu: Double?

    var isComplete: Bool {
        [cpu, memory, gpu].allSatisfy { $0.map { $0.isFinite && (0...100).contains($0) } ?? false }
    }
}

@MainActor
final class D200XHostMetrics {
    private var previousCPU: [UInt32]?

    func sample() -> D200XMetricsSnapshot {
        let host = mach_host_self()
        guard host != MACH_PORT_NULL else { return D200XMetricsSnapshot(gpu: gpuUsage()) }
        defer { mach_port_deallocate(mach_task_self_, host) }
        return D200XMetricsSnapshot(cpu: cpuUsage(host: host), memory: memoryUsage(host: host), gpu: gpuUsage())
    }

    static func cpuPercentage(previous: [UInt32]?, current: [UInt32]) -> Double? {
        guard let previous, previous.count == 4, current.count == 4 else { return nil }
        let deltas = zip(current, previous).map { $0 &- $1 }
        let total = deltas.reduce(UInt64(0)) { $0 + UInt64($1) }
        guard total > 0, deltas.allSatisfy({ $0 < UInt32.max / 2 }) else { return nil }
        return 100 * (1 - Double(deltas[Int(CPU_STATE_IDLE)]) / Double(total))
    }

    private func cpuUsage(host: host_t) -> Double? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { previousCPU = nil; return nil }
        let ticks = [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3]
        defer { previousCPU = ticks }
        return Self.cpuPercentage(previous: previousCPU, current: ticks)
    }

    private func memoryUsage(host: host_t) -> Double? {
        var info = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        var pageSize: vm_size_t = 0
        guard result == KERN_SUCCESS, host_page_size(host, &pageSize) == KERN_SUCCESS,
              pageSize > 0, ProcessInfo.processInfo.physicalMemory > 0 else { return nil }
        let pages = UInt64(info.active_count) + UInt64(info.wire_count) + UInt64(info.compressor_page_count)
        let value = Double(pages) * Double(pageSize) / Double(ProcessInfo.processInfo.physicalMemory) * 100
        return value.isFinite && (0...100).contains(value) ? value : nil
    }

    private func gpuUsage() -> Double? {
        #if arch(arm64)
        let serviceName = "IOGPU"
        #elseif arch(x86_64)
        let serviceName = "IOAccelerator"
        #else
        return nil
        #endif
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(serviceName))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let property = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
              let statistics = property as? [String: Any],
              let number = statistics["Device Utilization %"] as? NSNumber,
              CFGetTypeID(number) == CFNumberGetTypeID() else { return nil }
        let value = number.doubleValue
        return value.isFinite && (0...100).contains(value) ? value : nil
    }
}
