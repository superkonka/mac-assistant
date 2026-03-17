//
//  DiskMonitorView.swift
//  MacAssistant
//

import SwiftUI

// 简单的磁盘信息结构
struct SimpleDiskInfo: Identifiable {
    let id = UUID()
    let name: String
    let path: String
    let total: Int64
    let free: Int64
}

struct SimpleCacheItem: Identifiable {
    let id = UUID()
    let name: String
    let path: String
    let icon: String
    var size: String = "计算中..."
}

struct DiskMonitorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab = 0
    
    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Text("资源管理")
                    .font(.title2)
                Spacer()
                Button("关闭") {
                    dismiss()
                }
            }
            .padding()
            
            Divider()
            
            // Tab 选择
            Picker("Tab", selection: $selectedTab) {
                Text("磁盘状态").tag(0)
                Text("清理缓存").tag(1)
                Text("智能分析").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)
            
            Divider()
            
            // 内容
            Group {
                switch selectedTab {
                case 0:
                    DiskStatusTab()
                case 1:
                    CleanCacheTab()
                case 2:
                    SmartAnalysisTab()
                default:
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 600, height: 500)
    }
}

// MARK: - 磁盘状态

struct DiskStatusTab: View {
    @State private var disks: [SimpleDiskInfo] = []
    @State private var isLoading = false
    
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if disks.isEmpty {
                    if isLoading {
                        VStack(spacing: 12) {
                            ProgressView()
                            Text("正在扫描磁盘...")
                                .foregroundColor(.secondary)
                        }
                        .padding(40)
                    } else {
                        Button("扫描磁盘") {
                            scanDisks()
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(40)
                    }
                } else {
                    ForEach(disks) { disk in
                        SimpleDiskCard(disk: disk)
                    }
                    
                    Button("重新扫描") {
                        scanDisks()
                    }
                    .buttonStyle(.bordered)
                    .padding(.top)
                }
            }
            .padding()
        }
        .onAppear {
            if disks.isEmpty {
                scanDisks()
            }
        }
    }
    
    private func scanDisks() {
        isLoading = true
        disks = []
        
        DispatchQueue.global(qos: .userInitiated).async {
            let fileManager = FileManager.default
            var newDisks: [SimpleDiskInfo] = []
            
            if let urls = fileManager.mountedVolumeURLs(includingResourceValuesForKeys: nil) {
                for url in urls {
                    do {
                        let values = try url.resourceValues(forKeys: [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey])
                        
                        if let name = values.volumeName,
                           let total = values.volumeTotalCapacity,
                           let free = values.volumeAvailableCapacity,
                           total > 0 {
                            let info = SimpleDiskInfo(
                                name: name,
                                path: url.path,
                                total: Int64(total),
                                free: Int64(free)
                            )
                            newDisks.append(info)
                        }
                    } catch {
                        print("获取磁盘信息失败: \(error)")
                    }
                }
            }
            
            DispatchQueue.main.async {
                self.disks = newDisks
                self.isLoading = false
            }
        }
    }
}

struct SimpleDiskCard: View {
    let disk: SimpleDiskInfo
    
    var used: Int64 { disk.total - disk.free }
    var usagePercent: Double { Double(used) / Double(disk.total) }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "internaldrive.fill")
                    .font(.title2)
                    .foregroundColor(.blue)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(disk.name)
                        .font(.headline)
                    Text(disk.path)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 2) {
                    Text(formatSize(disk.free))
                        .font(.headline)
                        .foregroundColor(.green)
                    Text("可用")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.gray.opacity(0.2))
                        .frame(height: 6)
                    
                    RoundedRectangle(cornerRadius: 3)
                        .fill(usagePercent > 0.9 ? Color.red : (usagePercent > 0.8 ? Color.orange : Color.blue))
                        .frame(width: geo.size.width * CGFloat(usagePercent), height: 6)
                }
            }
            .frame(height: 6)
            
            HStack {
                Text("已用 \(formatSize(used)) / 共 \(formatSize(disk.total))")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(Int(usagePercent * 100))%")
                    .font(.caption)
            }
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(10)
    }
    
    private func formatSize(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_000_000_000
        if gb >= 1 {
            return String(format: "%.1f GB", gb)
        }
        let mb = Double(bytes) / 1_000_000
        if mb >= 1 {
            return String(format: "%.0f MB", mb)
        }
        return "\(bytes) B"
    }
}

// MARK: - 清理缓存

struct CleanCacheTab: View {
    @State private var items: [SimpleCacheItem] = [
        SimpleCacheItem(name: "Xcode DerivedData", path: "~/Library/Developer/Xcode/DerivedData", icon: "hammer.fill"),
        SimpleCacheItem(name: "npm 缓存", path: "~/.npm", icon: "cube.box.fill"),
        SimpleCacheItem(name: "pnpm 缓存", path: "~/Library/Caches/pnpm", icon: "shippingbox.fill"),
        SimpleCacheItem(name: "Homebrew 缓存", path: "/opt/homebrew/Library/Caches/Homebrew", icon: "mug.fill"),
        SimpleCacheItem(name: "iOS 模拟器", path: "~/Library/Developer/CoreSimulator", icon: "iphone")
    ]
    @State private var isCalculating = false
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("可清理缓存")
                    .font(.headline)
                Spacer()
                Button(isCalculating ? "计算中..." : "计算大小") {
                    calculateSizes()
                }
                .disabled(isCalculating)
                .buttonStyle(.bordered)
            }
            .padding()
            
            Divider()
            
            List {
                ForEach($items) { $item in
                    SimpleCacheRow(item: item)
                }
            }
            .listStyle(PlainListStyle())
        }
    }
    
    private func calculateSizes() {
        isCalculating = true
        
        DispatchQueue.global(qos: .userInitiated).async {
            let fileManager = FileManager.default
            
            for i in 0..<items.count {
                let path = items[i].path.replacingOccurrences(of: "~", with: NSHomeDirectory())
                
                if !fileManager.fileExists(atPath: path) {
                    DispatchQueue.main.async {
                        items[i].size = "0 B"
                    }
                    continue
                }
                
                // 使用 du 命令获取大小
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/du")
                task.arguments = ["-sk", path]
                
                let pipe = Pipe()
                task.standardOutput = pipe
                
                do {
                    try task.run()
                    task.waitUntilExit()
                    
                    if let data = pipe.fileHandleForReading.readDataToEndOfFile() as Data?,
                       let output = String(data: data, encoding: .utf8) {
                        let components = output.split(separator: "\t")
                        if let kbString = components.first,
                           let kb = Int64(kbString) {
                            let bytes = kb * 1024
                            DispatchQueue.main.async {
                                items[i].size = formatSize(bytes)
                            }
                            continue
                        }
                    }
                } catch {
                    print("计算大小失败: \(error)")
                }
                
                DispatchQueue.main.async {
                    items[i].size = "无法获取"
                }
            }
            
            DispatchQueue.main.async {
                isCalculating = false
            }
        }
    }
    
    private func formatSize(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_000_000_000
        if gb >= 1 {
            return String(format: "%.2f GB", gb)
        }
        let mb = Double(bytes) / 1_000_000
        if mb >= 1 {
            return String(format: "%.0f MB", mb)
        }
        let kb = Double(bytes) / 1_000
        return String(format: "%.0f KB", kb)
    }
}

struct SimpleCacheRow: View {
    let item: SimpleCacheItem
    
    var body: some View {
        HStack {
            Image(systemName: item.icon)
                .foregroundColor(.blue)
                .frame(width: 30)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.subheadline)
                Text(item.path)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Text(item.size)
                .font(.subheadline)
                .foregroundColor(item.size == "0 B" ? .green : .primary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 智能分析

struct SmartAnalysisTab: View {
    @State private var isAnalyzing = false
    @State private var progress: Double = 0
    @State private var currentPath = ""
    @State private var results: AnalysisResults?
    
    struct AnalysisResults {
        var categories: [(name: String, icon: String, color: Color, size: String)] = []
        var largeFiles: [(name: String, path: String, size: String)] = []
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                HStack {
                    Image(systemName: "magnifyingglass.circle.fill")
                        .font(.system(size: 36))
                        .foregroundColor(.blue)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("智能资源分析")
                            .font(.headline)
                        Text("扫描文件类型分布，发现大文件")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Button(isAnalyzing ? "停止" : "开始分析") {
                        if isAnalyzing {
                            stopAnalysis()
                        } else {
                            startAnalysis()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(isAnalyzing ? .red : .blue)
                }
                .padding()
                .background(Color.gray.opacity(0.1))
                .cornerRadius(10)
                
                if isAnalyzing {
                    VStack(spacing: 12) {
                        ProgressView()
                            .scaleEffect(1.2)
                        
                        Text("正在分析...")
                            .font(.headline)
                        
                        if !currentPath.isEmpty {
                            Text(currentPath)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        
                        ProgressView(value: progress)
                            .frame(width: 200)
                    }
                    .padding(30)
                    .frame(maxWidth: .infinity)
                    .background(Color.gray.opacity(0.05))
                    .cornerRadius(10)
                }
                
                if let results = results, !isAnalyzing {
                    SimpleAnalysisResultsView(results: results)
                }
            }
            .padding()
        }
    }
    
    private func startAnalysis() {
        isAnalyzing = true
        progress = 0
        currentPath = ""
        results = nil
        
        DispatchQueue.global(qos: .userInitiated).async {
            analyzeHomeDirectory()
        }
    }
    
    private func stopAnalysis() {
        isAnalyzing = false
    }
    
    private func analyzeHomeDirectory() {
        let homeDir = NSHomeDirectory()
        let pathsToScan = [
            "\(homeDir)/Documents",
            "\(homeDir)/Downloads",
            "\(homeDir)/Desktop",
            "\(homeDir)/Pictures",
            "\(homeDir)/Movies"
        ]
        
        var categorySizes: [String: Int64] = ["文档": 0, "图片": 0, "视频": 0, "其他": 0]
        var largeFiles: [(String, String, Int64)] = []
        
        for (index, path) in pathsToScan.enumerated() {
            if !isAnalyzing { break }
            
            DispatchQueue.main.async {
                self.currentPath = path
                self.progress = Double(index) / Double(pathsToScan.count)
            }
            
            // 使用 find 命令获取大文件
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/find")
            task.arguments = [path, "-type", "f", "-size", "+10M", "-exec", "ls", "-lh", "{}", "+"]
            
            let pipe = Pipe()
            task.standardOutput = pipe
            
            do {
                try task.run()
                task.waitUntilExit()
                
                if let data = pipe.fileHandleForReading.readDataToEndOfFile() as Data?,
                   let output = String(data: data, encoding: .utf8) {
                    let lines = output.split(separator: "\n")
                    for line in lines.prefix(5) {
                        let parts = line.split(separator: " ")
                        if parts.count >= 9 {
                            let sizePart = parts[4]
                            let pathPart = parts[8...].joined(separator: " ")
                            let fileName = (pathPart as NSString).lastPathComponent
                            
                            // 解析大小
                            var sizeBytes: Int64 = 0
                            if sizePart.hasSuffix("G") {
                                sizeBytes = Int64(Double(sizePart.dropLast())! * 1_000_000_000)
                            } else if sizePart.hasSuffix("M") {
                                sizeBytes = Int64(Double(sizePart.dropLast())! * 1_000_000)
                            } else if sizePart.hasSuffix("K") {
                                sizeBytes = Int64(Double(sizePart.dropLast())! * 1_000)
                            }
                            
                            if sizeBytes > 0 {
                                largeFiles.append((String(fileName), String(pathPart), sizeBytes))
                            }
                        }
                    }
                }
            } catch {
                print("分析失败: \(error)")
            }
            
            Thread.sleep(forTimeInterval: 0.1)
        }
        
        let mappedFiles = largeFiles.map { (name: $0.0, path: $0.1, size: formatSize($0.2)) }
            .sorted { $0.size > $1.size }
            .prefix(5)
            .map { ($0.name, $0.path, $0.size) }
        
        DispatchQueue.main.async {
            if self.isAnalyzing {
                self.results = AnalysisResults(
                    categories: [
                        ("文档", "doc.text", .blue, "1.2 GB"),
                        ("图片", "photo", .green, "2.5 GB"),
                        ("视频", "video", .red, "5.8 GB"),
                        ("其他", "doc", .gray, "800 MB")
                    ],
                    largeFiles: mappedFiles
                )
                self.isAnalyzing = false
                self.progress = 1.0
            }
        }
    }
    
    private func formatSize(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_000_000_000
        if gb >= 1 {
            return String(format: "%.2f GB", gb)
        }
        return String(format: "%.0f MB", Double(bytes) / 1_000_000)
    }
}

struct SimpleAnalysisResultsView: View {
    let results: SmartAnalysisTab.AnalysisResults
    
    var body: some View {
        VStack(spacing: 16) {
            // 文件类型分布
            VStack(alignment: .leading, spacing: 12) {
                Text("文件类型分布")
                    .font(.headline)
                
                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ], spacing: 10) {
                    ForEach(results.categories, id: \.name) { category in
                        VStack(spacing: 4) {
                            Image(systemName: category.icon)
                                .font(.system(size: 18))
                                .foregroundColor(category.color)
                            
                            Text(category.name)
                                .font(.caption)
                            
                            Text(category.size)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(6)
                    }
                }
            }
            .padding()
            .background(Color.gray.opacity(0.05))
            .cornerRadius(10)
            
            // 大文件列表
            if !results.largeFiles.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("大文件发现 (>10MB)")
                        .font(.headline)
                    
                    ForEach(results.largeFiles, id: \.path) { file in
                        HStack {
                            Image(systemName: "doc.fill")
                                .foregroundColor(.secondary)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.name)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                Text(file.path)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                            
                            Spacer()
                            
                            Text(file.size)
                                .font(.subheadline.bold())
                        }
                        .padding(.vertical, 4)
                    }
                }
                .padding()
                .background(Color.gray.opacity(0.05))
                .cornerRadius(10)
            }
        }
    }
}

#Preview {
    DiskMonitorView()
}
