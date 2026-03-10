//
//  EnvironmentScanner.swift
//  环境扫描器
//

import Foundation
import AppKit

// MARK: - 数据结构

struct EnvironmentData {
    let cpuUsage: Double
    let memoryPressure: MemoryPressure
    let freeDiskSpaceGB: Double
    
    enum MemoryPressure: String, Codable {
        case normal = "正常"
        case warning = "警告"
        case critical = "紧急"
    }
}

struct ContextData {
    let activeApps: [String]
    let systemStatus: String
    let recentActivities: [String]
    let clipboardContent: String
    let recentFiles: [String]
}

// MARK: - 环境扫描器

class EnvironmentScanner {
    
    func scan() -> EnvironmentData {
        return EnvironmentData(
            cpuUsage: getCPUUsage(),
            memoryPressure: getMemoryPressure(),
            freeDiskSpaceGB: getFreeDiskSpace()
        )
    }
    
    private func getCPUUsage() -> Double {
        var usage = 0.0
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        
        let kerr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        
        if kerr == KERN_SUCCESS {
            let total = info.cpu_ticks.0 + info.cpu_ticks.1 + info.cpu_ticks.2
            let idle = info.cpu_ticks.3
            if total > 0 {
                usage = Double(total - idle) / Double(total) * 100.0
            }
        }
        
        return usage
    }
    
    private func getMemoryPressure() -> EnvironmentData.MemoryPressure {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        
        let kerr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        
        if kerr == KERN_SUCCESS {
            let free = Double(stats.free_count) * Double(vm_page_size) / 1024.0 / 1024.0 / 1024.0
            if free < 0.5 {
                return .critical
            } else if free < 2.0 {
                return .warning
            }
        }
        
        return .normal
    }
    
    private func getFreeDiskSpace() -> Double {
        do {
            let attrs = try FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
            if let free = attrs[.systemFreeSize] as? NSNumber {
                return Double(free.int64Value) / 1024.0 / 1024.0 / 1024.0
            }
        } catch {}
        return 0
    }
}

// MARK: - 上下文分析器

class ContextAnalyzer {
    
    func gatherContext(history: [ChatMessage], environment: EnvironmentData) -> ContextData {
        return ContextData(
            activeApps: getActiveApps(),
            systemStatus: getSystemStatus(environment),
            recentActivities: getRecentActivities(),
            clipboardContent: getClipboardContent(),
            recentFiles: getRecentFiles()
        )
    }
    
    private func getActiveApps() -> [String] {
        let apps = NSWorkspace.shared.runningApplications
        return apps
            .filter { $0.activationPolicy == .regular }
            .compactMap { $0.localizedName }
            .filter { !$0.contains("Mac Assistant") }
    }
    
    private func getSystemStatus(_ env: EnvironmentData) -> String {
        var status = "CPU: \(Int(env.cpuUsage))%"
        status += ", 内存: \(env.memoryPressure == .normal ? "正常" : env.memoryPressure == .warning ? "警告" : "紧急")"
        status += ", 磁盘: \(String(format: "%.1f", env.freeDiskSpaceGB))GB"
        return status
    }
    
    private func getRecentActivities() -> [String] {
        var activities: [String] = []
        
        // 检查最近下载
        let downloads = FileManager.default.enumerator(at: URL(fileURLWithPath: NSHomeDirectory() + "/Downloads"),
                                                       includingPropertiesForKeys: [.creationDateKey])
        if let recentFile = downloads?.nextObject() as? URL {
            activities.append("最近下载: \(recentFile.lastPathComponent)")
        }
        
        return activities
    }
    
    private func getClipboardContent() -> String {
        return NSPasteboard.general.string(forType: .string) ?? ""
    }
    
    private func getRecentFiles() -> [String] {
        return []
    }
}
