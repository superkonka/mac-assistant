//
//  PortScanner.swift
//  MacAssistant
//
//  端口扫描器
//

import Foundation

// MARK: - 端口扫描结果
struct PortScanResult {
    let port: Int
    let isOpen: Bool
    let responseTimeMs: Int?
    let serviceType: DiscoveredServiceType
    let processInfo: PortProcessInfo?
}

struct PortProcessInfo {
    let pid: Int
    let name: String
    let path: String?
    let user: String?
}

// MARK: - 端口扫描器
actor PortScanner {
    
    // MARK: - 扫描指定端口
    func scanPort(_ port: Int, timeout: TimeInterval = 2) async -> PortScanResult {
        let startTime = Date()
        
        // 使用 nc 命令检查端口
        let task = Process()
        task.launchPath = "/usr/bin/nc"
        task.arguments = ["-z", "-G", String(Int(timeout)), "127.0.0.1", String(port)]
        
        return await withCheckedContinuation { continuation in
            task.terminationHandler = { [weak self] process in
                let responseTime = Int(Date().timeIntervalSince(startTime) * 1000)
                
                if process.terminationStatus == 0 {
                    // 端口开放，获取进程信息（在 Task 中执行以支持 async）
                    Task {
                        let processInfo = await self?.getPortProcessInfo(for: port)
                        let serviceType = await self?.identifyServiceType(port: port, processName: processInfo?.name) ?? .unknown
                        
                        continuation.resume(returning: PortScanResult(
                            port: port,
                            isOpen: true,
                            responseTimeMs: responseTime,
                            serviceType: serviceType,
                            processInfo: processInfo
                        ))
                    }
                } else {
                    continuation.resume(returning: PortScanResult(
                        port: port,
                        isOpen: false,
                        responseTimeMs: nil,
                        serviceType: .unknown,
                        processInfo: nil
                    ))
                }
            }
            
            do {
                try task.run()
            } catch {
                continuation.resume(returning: PortScanResult(
                    port: port,
                    isOpen: false,
                    responseTimeMs: nil,
                    serviceType: .unknown,
                    processInfo: nil
                ))
            }
        }
    }
    
    // MARK: - 批量扫描端口
    func scanPorts(
        range: ClosedRange<Int>,
        config: PortScanConfig = .default,
        progressHandler: ((Int, Int) -> Void)? = nil
    ) async -> [PortScanResult] {
        var results: [PortScanResult] = []
        let total = range.count
        var completed = 0
        
        // 使用任务组进行并发扫描
        await withTaskGroup(of: PortScanResult.self) { group in
            // 限制并发数
            let semaphore = AsyncSemaphore(value: config.concurrency)
            
            for port in range {
                await group.addTask {
                    await semaphore.wait()
                    defer { Task { await semaphore.signal() } }
                    
                    let result = await self.scanPort(port, timeout: config.timeout)
                    
                    completed += 1
                    if completed % 10 == 0 {
                        progressHandler?(completed, total)
                    }
                    
                    return result
                }
            }
            
            // 收集结果
            for await result in group {
                if result.isOpen {
                    results.append(result)
                }
            }
        }
        
        progressHandler?(total, total)
        return results
    }
    
    // MARK: - 快速扫描已知服务端口
    func scanKnownServicePorts() async -> [PortScanResult] {
        let knownPorts = Array(CommonServicePorts.mapping.keys)
        
        return await withTaskGroup(of: PortScanResult.self) { group in
            for port in knownPorts {
                group.addTask {
                    await self.scanPort(port, timeout: 1)
                }
            }
            
            var results: [PortScanResult] = []
            for await result in group {
                if result.isOpen {
                    results.append(result)
                }
            }
            return results
        }
    }
    
    // MARK: - 获取端口对应的进程信息
    private func getPortProcessInfo(for port: Int) -> PortProcessInfo? {
        // 使用 lsof 查找占用端口的进程
        let task = Process()
        task.launchPath = "/usr/sbin/lsof"
        task.arguments = ["-i", ":\(port)", "-n", "-P", "-F", "pcnPu"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        
        do {
            try task.run()
            task.waitUntilExit()
            
            guard task.terminationStatus == 0 else { return nil }
            
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return parseLsofOutput(output)
        } catch {
            LogError("[PortScanner] 获取进程信息失败: \(error)")
            return nil
        }
    }
    
    // MARK: - 解析 lsof 输出
    private func parseLsofOutput(_ output: String) -> PortProcessInfo? {
        var pid: Int?
        var name: String?
        var path: String?
        var user: String?
        
        let lines = output.components(separatedBy: .newlines)
        
        for line in lines {
            if line.hasPrefix("p") {
                pid = Int(line.dropFirst())
            } else if line.hasPrefix("c") {
                name = String(line.dropFirst())
            } else if line.hasPrefix("n") {
                // 地址信息，可能包含路径
                let value = String(line.dropFirst())
                if value.contains("->") {
                    // 网络连接，忽略
                } else {
                    path = value
                }
            } else if line.hasPrefix("u") {
                user = String(line.dropFirst())
            }
        }
        
        guard let pid = pid, let name = name else { return nil }
        
        return PortProcessInfo(
            pid: pid,
            name: name,
            path: path,
            user: user
        )
    }
    
    // MARK: - 识别服务类型
    private func identifyServiceType(port: Int, processName: String?) -> DiscoveredServiceType {
        // 1. 根据端口识别
        if let type = CommonServicePorts.mapping[port] {
            return type
        }
        
        // 2. 根据进程名识别
        guard let processName = processName?.lowercased() else {
            return .unknown
        }
        
        if processName.contains("mcp") || processName.contains("claude") {
            return .mcpServer
        } else if processName.contains("mysql") || processName.contains("postgres") || processName.contains("mongo") {
            return .database
        } else if processName.contains("redis") || processName.contains("memcached") {
            return .cacheServer
        } else if processName.contains("node") || processName.contains("python") || processName.contains("java") {
            // 可能是开发服务器
            return .developmentTool
        }
        
        return .unknown
    }
    
    // MARK: - 测试端口是否可外部访问
    func testExternalAccessibility(port: Int, localIP: String) async -> Bool {
        let task = Process()
        task.launchPath = "/usr/bin/nc"
        task.arguments = ["-z", "-G", "2", localIP, String(port)]
        
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
}

// MARK: - 异步信号量（控制并发）
actor AsyncSemaphore {
    private var value: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    
    init(value: Int) {
        self.value = value
    }
    
    func wait() async {
        if value > 0 {
            value -= 1
            return
        }
        
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
    
    func signal() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume()
        } else {
            value += 1
        }
    }
}
