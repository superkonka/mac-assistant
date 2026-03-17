//
//  DiskManager.swift
//  MacAssistant
//
//  磁盘空间管理和自动清理服务
//

import Foundation
import Combine

/// 磁盘使用信息
struct DiskUsageInfo: Identifiable, Equatable {
    let id = UUID()
    let path: String
    let name: String
    let totalSize: Int64
    let usedSize: Int64
    let freeSize: Int64
    let usagePercentage: Double
    let isExternal: Bool
    
    var totalSizeGB: Double { Double(totalSize) / 1_000_000_000 }
    var usedSizeGB: Double { Double(usedSize) / 1_000_000_000 }
    var freeSizeGB: Double { Double(freeSize) / 1_000_000_000 }
    
    var isLowSpace: Bool { usagePercentage > 85 }
    var isCritical: Bool { usagePercentage > 95 }
    
    var formattedUsage: String {
        String(format: "%.1f GB / %.1f GB (%.0f%%)", usedSizeGB, totalSizeGB, usagePercentage)
    }
}

/// 可清理项目
struct CleanableItem: Identifiable, Equatable {
    var id = UUID()
    let name: String
    let path: String
    let icon: String
    let description: String
    var size: Int64?
    var isCleaning: Bool = false
    var lastCleaned: Date?
    
    var sizeGB: Double? { size.map { Double($0) / 1_000_000_000 } }
    
    var formattedSize: String {
        guard let sizeGB = sizeGB else { return "计算中..." }
        return String(format: "%.2f GB", sizeGB)
    }
}

/// 磁盘管理器
@MainActor
class DiskManager: ObservableObject {
    static let shared = DiskManager()
    
    @Published private(set) var disks: [DiskUsageInfo] = []
    @Published private(set) var cleanableItems: [CleanableItem] = []
    @Published private(set) var isScanning = false
    @Published private(set) var lastScanTime: Date?
    
    private var monitoringTask: Task<Void, Never>?
    private let scanInterval: TimeInterval = 60 // 每分钟检查一次
    
    private init() {
        setupCleanableItems()
    }
    
    // MARK: - 监控
    
    func startMonitoring() {
        stopMonitoring()
        
        monitoringTask = Task { [weak self] in
            // 立即扫描一次
            await self?.scanAll()
            
            // 定时循环
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(self?.scanInterval ?? 60) * 1_000_000_000)
                if Task.isCancelled { break }
                await self?.scanAll()
            }
        }
    }
    
    func stopMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = nil
    }
    
    // MARK: - 扫描
    
    func scanAll() async {
        isScanning = true
        defer { 
            isScanning = false
            lastScanTime = Date()
        }
        
        await scanDisks()
        await scanCleanableItems()
    }
    
    private func scanDisks() async {
        var newDisks: [DiskUsageInfo] = []
        
        // 获取所有挂载的卷
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeIsRemovableKey
        ]
        
        if let urls = fileManager.mountedVolumeURLs(includingResourceValuesForKeys: keys) {
            for url in urls {
                do {
                    let values = try url.resourceValues(forKeys: Set(keys))
                    
                    guard let total = values.volumeTotalCapacity,
                          let available = values.volumeAvailableCapacity else {
                        continue
                    }
                    
                    let used = total - available
                    let percentage = Double(used) / Double(total) * 100
                    // 通过路径判断是否为外置磁盘
                    let isExternal = url.path.contains("/Volumes/") || (values.volumeIsRemovable ?? false)
                    
                    let info = DiskUsageInfo(
                        path: url.path,
                        name: values.volumeName ?? url.lastPathComponent,
                        totalSize: Int64(total),
                        usedSize: Int64(used),
                        freeSize: Int64(available),
                        usagePercentage: percentage,
                        isExternal: isExternal
                    )
                    
                    newDisks.append(info)
                } catch {
                    LogWarning("获取磁盘信息失败: \(url.path), error: \(error)")
                }
            }
        }
        
        // 按使用百分比排序（高的在前）
        disks = newDisks.sorted { $0.usagePercentage > $1.usagePercentage }
    }
    
    private func scanCleanableItems() async {
        var updatedItems = cleanableItems
        
        for i in updatedItems.indices {
            let item = updatedItems[i]
            let size = await calculateSize(for: item.path)
            updatedItems[i] = CleanableItem(
                id: item.id,
                name: item.name,
                path: item.path,
                icon: item.icon,
                description: item.description,
                size: size,
                isCleaning: item.isCleaning,
                lastCleaned: item.lastCleaned
            )
        }
        
        cleanableItems = updatedItems
    }
    
    private func calculateSize(for path: String) async -> Int64? {
        let fileManager = FileManager.default
        
        guard fileManager.fileExists(atPath: path) else {
            return nil
        }
        
        let url = URL(fileURLWithPath: path)
        
        // 使用 du 命令获取大小
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        task.arguments = ["-sk", url.path]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        
        do {
            try task.run()
            task.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8),
               let sizeStr = output.split(separator: "\t").first,
               let sizeKB = Int64(sizeStr) {
                return sizeKB * 1024 // 转换为字节
            }
        } catch {
            LogWarning("计算大小失败: \(path), error: \(error)")
        }
        
        return nil
    }
    
    // MARK: - 清理
    
    func cleanItem(at index: Int) async -> Bool {
        guard index < cleanableItems.count else { return false }
        
        var item = cleanableItems[index]
        item.isCleaning = true
        cleanableItems[index] = item
        
        let success = await performCleaning(for: item)
        
        // 更新状态
        var updatedItem = cleanableItems[index]
        updatedItem.isCleaning = false
        if success {
            updatedItem.lastCleaned = Date()
            updatedItem.size = 0
        }
        cleanableItems[index] = updatedItem
        
        // 重新扫描磁盘
        await scanDisks()
        
        return success
    }
    
    func cleanAllCaches() async -> Bool {
        var allSuccess = true
        
        for index in cleanableItems.indices {
            guard cleanableItems[index].size ?? 0 > 0 else { continue }
            
            let success = await cleanItem(at: index)
            if !success {
                allSuccess = false
            }
        }
        
        return allSuccess
    }
    
    private func performCleaning(for item: CleanableItem) async -> Bool {
        let fileManager = FileManager.default
        
        switch item.name {
        case "Xcode DerivedData":
            return await cleanXcodeDerivedData()
        case "npm 缓存":
            return await cleanNPMCache()
        case "pnpm 缓存":
            return await cleanPnpmCache()
        case "Homebrew 缓存":
            return await cleanHomebrewCache()
        case "模拟器镜像":
            return await cleanSimulatorImages()
        default:
            // 通用清理：删除目录内容
            return await cleanDirectory(at: item.path)
        }
    }
    
    private func cleanXcodeDerivedData() async -> Bool {
        let path = "~/Library/Developer/Xcode/DerivedData"
        return await cleanDirectory(at: path)
    }
    
    private func cleanNPMCache() async -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["npm", "cache", "clean", "--force"]
        return await runTask(task)
    }
    
    private func cleanPnpmCache() async -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["pnpm", "store", "prune"]
        return await runTask(task)
    }
    
    private func cleanHomebrewCache() async -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/brew")
        task.arguments = ["cleanup"]
        return await runTask(task)
    }
    
    private func cleanSimulatorImages() async -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        task.arguments = ["simctl", "delete", "unavailable"]
        return await runTask(task)
    }
    
    private func cleanDirectory(at path: String) async -> Bool {
        let expandedPath = NSString(string: path).expandingTildeInPath
        let fileManager = FileManager.default
        
        do {
            let contents = try fileManager.contentsOfDirectory(atPath: expandedPath)
            for item in contents {
                let itemPath = (expandedPath as NSString).appendingPathComponent(item)
                try fileManager.removeItem(atPath: itemPath)
            }
            return true
        } catch {
            LogError("清理目录失败: \(path), error: \(error)")
            return false
        }
    }
    
    private func runTask(_ task: Process) async -> Bool {
        return await withCheckedContinuation { continuation in
            task.terminationHandler = { process in
                continuation.resume(returning: process.terminationStatus == 0)
            }
            
            do {
                try task.run()
            } catch {
                continuation.resume(returning: false)
            }
        }
    }
    
    // MARK: - 初始化
    
    private func setupCleanableItems() {
        cleanableItems = [
            CleanableItem(
                name: "Xcode DerivedData",
                path: "~/Library/Developer/Xcode/DerivedData",
                icon: "hammer.fill",
                description: "Xcode 编译缓存，可安全清理"
            ),
            CleanableItem(
                name: "npm 缓存",
                path: "~/.npm",
                icon: "cube.box.fill",
                description: "npm 包缓存"
            ),
            CleanableItem(
                name: "pnpm 缓存",
                path: "~/Library/Caches/pnpm",
                icon: "cube.box.fill",
                description: "pnpm 包缓存"
            ),
            CleanableItem(
                name: "Homebrew 缓存",
                path: "/opt/homebrew/Library/Caches/Homebrew",
                icon: "mug.fill",
                description: "Homebrew 下载缓存"
            ),
            CleanableItem(
                name: "模拟器镜像",
                path: "~/Library/Developer/CoreSimulator",
                icon: "iphone",
                description: "iOS 模拟器数据"
            ),
            CleanableItem(
                name: "Kimi 会话缓存",
                path: "~/.kimi/sessions",
                icon: "bubble.left.fill",
                description: "Kimi CLI 历史会话"
            )
        ]
    }
    
    // MARK: - 便捷方法
    
    /// 获取内置磁盘信息
    var internalDisk: DiskUsageInfo? {
        disks.first { !$0.isExternal && $0.path == "/System/Volumes/Data" }
    }
    
    /// 获取外置磁盘列表
    var externalDisks: [DiskUsageInfo] {
        disks.filter { $0.isExternal }
    }
    
    /// 是否需要警告
    var shouldShowWarning: Bool {
        internalDisk?.isLowSpace ?? false
    }
    
    /// 总可清理大小
    var totalCleanableSize: Int64 {
        cleanableItems.compactMap { $0.size }.reduce(0, +)
    }
}