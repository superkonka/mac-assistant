//
//  ResourceAnalyzer.swift
//  MacAssistant
//
//  智能资源分析和优化建议服务
//

import Foundation

/// 文件类型分类
enum FileCategory: String, CaseIterable, Identifiable {
    case documents = "文档"
    case images = "图片"
    case videos = "视频"
    case audio = "音频"
    case development = "开发"
    case cache = "缓存"
    case archives = "压缩包"
    case other = "其他"
    
    var id: String { rawValue }
    
    var icon: String {
        switch self {
        case .documents: return "doc.text"
        case .images: return "photo"
        case .videos: return "video"
        case .audio: return "music.note"
        case .development: return "hammer"
        case .cache: return "archivebox"
        case .archives: return "doc.zipper"
        case .other: return "doc"
        }
    }
    
    var color: String {
        switch self {
        case .documents: return "007AFF"
        case .images: return "34C759"
        case .videos: return "FF2D55"
        case .audio: return "5856D6"
        case .development: return "FF9500"
        case .cache: return "8E8E93"
        case .archives: return "AF52DE"
        case .other: return "C7C7CC"
        }
    }
}

/// 文件类型统计
struct FileCategoryStat: Identifiable {
    let id = UUID()
    let category: FileCategory
    let size: Int64
    let count: Int
    let topPaths: [String]
    
    var sizeGB: Double { Double(size) / 1_000_000_000 }
}

/// 大文件信息
struct LargeFileInfo: Identifiable, Equatable {
    let id = UUID()
    let path: String
    let name: String
    let size: Int64
    let modificationDate: Date
    let isDirectory: Bool
    
    var sizeGB: Double { Double(size) / 1_000_000_000 }
    var sizeMB: Double { Double(size) / 1_000_000 }
    
    var formattedSize: String {
        if sizeGB >= 1 {
            return String(format: "%.2f GB", sizeGB)
        } else {
            return String(format: "%.1f MB", sizeMB)
        }
    }
    
    var parentDirectory: String {
        (path as NSString).deletingLastPathComponent
    }
    
    static func == (lhs: LargeFileInfo, rhs: LargeFileInfo) -> Bool {
        lhs.id == rhs.id
    }
}

/// 迁移建议
struct MigrationSuggestion: Identifiable {
    let id = UUID()
    let title: String
    let description: String
    let sourcePath: String
    let targetPath: String?
    let estimatedSize: Int64
    let priority: MigrationPriority
    let category: FileCategory
    
    var estimatedSizeGB: Double { Double(estimatedSize) / 1_000_000_000 }
}

enum MigrationPriority: Int, Comparable {
    case low = 0
    case medium = 1
    case high = 2
    case urgent = 3
    
    static func < (lhs: MigrationPriority, rhs: MigrationPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
    
    var description: String {
        switch self {
        case .low: return "建议"
        case .medium: return "推荐"
        case .high: return "强烈建议"
        case .urgent: return "紧急"
        }
    }
    
    var color: String {
        switch self {
        case .low: return "34C759"
        case .medium: return "007AFF"
        case .high: return "FF9500"
        case .urgent: return "FF3B30"
        }
    }
}

/// 资源分析结果
struct ResourceAnalysisResult {
    let scanTime: Date
    let totalScannedSize: Int64
    let categories: [FileCategoryStat]
    let largeFiles: [LargeFileInfo]
    let suggestions: [MigrationSuggestion]
    
    var totalScannedGB: Double { Double(totalScannedSize) / 1_000_000_000 }
}

/// 资源分析器
@MainActor
class ResourceAnalyzer: ObservableObject {
    static let shared = ResourceAnalyzer()
    
    @Published private(set) var analysisResult: ResourceAnalysisResult?
    @Published private(set) var isAnalyzing = false
    @Published private(set) var analysisProgress: Double = 0
    @Published private(set) var currentScanningPath: String = ""
    
    private var scanTask: Task<Void, Never>?
    private let fileManager = FileManager.default
    
    private init() {}
    
    // MARK: - 分析控制
    
    func startAnalysis() {
        cancelAnalysis()
        
        scanTask = Task {
            await MainActor.run {
                isAnalyzing = true
                analysisProgress = 0
            }
            
            let result = await performAnalysis()
            
            if !Task.isCancelled {
                await MainActor.run {
                    analysisResult = result
                    isAnalyzing = false
                    analysisProgress = 1.0
                }
            }
        }
    }
    
    func cancelAnalysis() {
        scanTask?.cancel()
        scanTask = nil
        isAnalyzing = false
        analysisProgress = 0
        currentScanningPath = ""
    }
    
    // MARK: - 执行分析
    
    private func performAnalysis() async -> ResourceAnalysisResult {
        let startTime = Date()
        
        // 分析用户目录下的主要文件夹
        let homeDir = NSHomeDirectory()
        let pathsToScan = [
            "\(homeDir)/Documents",
            "\(homeDir)/Downloads",
            "\(homeDir)/Desktop",
            "\(homeDir)/Pictures",
            "\(homeDir)/Movies",
            "\(homeDir)/Music",
            "\(homeDir)/Library/Developer",
        ]
        
        var allFiles: [LargeFileInfo] = []
        var categorySizes: [FileCategory: (size: Int64, count: Int, paths: [String])] = [:]
        var totalSize: Int64 = 0
        
        let totalPaths = pathsToScan.count
        
        for (index, path) in pathsToScan.enumerated() {
            guard !Task.isCancelled else { break }
            
            await MainActor.run {
                currentScanningPath = path
                analysisProgress = Double(index) / Double(totalPaths)
            }
            
            let (files, size) = await scanPath(path, categorySizes: &categorySizes)
            allFiles.append(contentsOf: files)
            totalSize += size
        }
        
        // 生成分类统计
        let categories = FileCategory.allCases.compactMap { category -> FileCategoryStat? in
            guard let data = categorySizes[category] else { return nil }
            return FileCategoryStat(
                category: category,
                size: data.size,
                count: data.count,
                topPaths: Array(data.paths.prefix(5))
            )
        }.sorted { $0.size > $1.size }
        
        // 找出大文件（按大小排序，取前50）
        let largeFiles = Array(allFiles.sorted { $0.size > $1.size }.prefix(50))
        
        // 生成迁移建议
        let suggestions = generateSuggestions(categories: categories, largeFiles: largeFiles)
        
        return ResourceAnalysisResult(
            scanTime: startTime,
            totalScannedSize: totalSize,
            categories: categories,
            largeFiles: largeFiles,
            suggestions: suggestions
        )
    }
    
    private func scanPath(_ path: String, categorySizes: inout [FileCategory: (size: Int64, count: Int, paths: [String])]) async -> ([LargeFileInfo], Int64) {
        var files: [LargeFileInfo] = []
        var totalSize: Int64 = 0
        
        guard fileManager.fileExists(atPath: path) else {
            return (files, totalSize)
        }
        
        let url = URL(fileURLWithPath: path)
        
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return (files, totalSize)
        }
        
        while let fileURL = enumerator.nextObject() as? URL {
            guard !Task.isCancelled else { break }
            
            do {
                let resourceValues = try fileURL.resourceValues(forKeys: [
                    .fileSizeKey,
                    .contentModificationDateKey,
                    .isDirectoryKey
                ])
                
                let size = Int64(resourceValues.fileSize ?? 0)
                let isDirectory = resourceValues.isDirectory ?? false
                
                // 只记录大于 10MB 的文件或目录
                guard size > 10_000_000 || isDirectory else { continue }
                
                let info = LargeFileInfo(
                    path: fileURL.path,
                    name: fileURL.lastPathComponent,
                    size: size,
                    modificationDate: resourceValues.contentModificationDate ?? Date(),
                    isDirectory: isDirectory
                )
                
                files.append(info)
                totalSize += size
                
                // 更新分类统计
                let category = categorizeFile(fileURL)
                var data = categorySizes[category] ?? (size: 0, count: 0, paths: [])
                data.size += size
                data.count += 1
                if !data.paths.contains(fileURL.path) {
                    data.paths.append(fileURL.path)
                }
                categorySizes[category] = data
                
            } catch {
                continue
            }
        }
        
        return (files, totalSize)
    }
    
    private func categorizeFile(_ url: URL) -> FileCategory {
        let path = url.path.lowercased()
        let ext = url.pathExtension.lowercased()
        
        // 开发相关
        let devExtensions = ["xcodeproj", "xcworkspace", "git", "build", "deriveddata", "node_modules"]
        let devPaths = ["developer", "xcode", "android", "gradle", "npm"]
        if devExtensions.contains(ext) || devPaths.contains(where: path.contains) {
            return .development
        }
        
        // 视频
        let videoExtensions = ["mp4", "mov", "avi", "mkv", "wmv", "flv", "webm", "m4v"]
        if videoExtensions.contains(ext) || path.contains("movies") {
            return .videos
        }
        
        // 图片
        let imageExtensions = ["jpg", "jpeg", "png", "gif", "bmp", "tiff", "webp", "heic", "raw"]
        if imageExtensions.contains(ext) || path.contains("pictures") || path.contains("photos") {
            return .images
        }
        
        // 音频
        let audioExtensions = ["mp3", "aac", "wav", "flac", "m4a", "ogg", "wma"]
        if audioExtensions.contains(ext) || path.contains("music") {
            return .audio
        }
        
        // 文档
        let docExtensions = ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "rtf", "pages", "numbers", "keynote"]
        if docExtensions.contains(ext) || path.contains("documents") {
            return .documents
        }
        
        // 压缩包
        let archiveExtensions = ["zip", "rar", "7z", "tar", "gz", "bz2", "dmg", "pkg"]
        if archiveExtensions.contains(ext) {
            return .archives
        }
        
        // 缓存
        let cachePaths = ["cache", "caches", "temp", "tmp", "logs"]
        if cachePaths.contains(where: path.contains) {
            return .cache
        }
        
        return .other
    }
    
    // MARK: - 生成建议
    
    private func generateSuggestions(categories: [FileCategoryStat], largeFiles: [LargeFileInfo]) -> [MigrationSuggestion] {
        var suggestions: [MigrationSuggestion] = []
        
        // 1. 开发文件迁移建议
        if let devCategory = categories.first(where: { $0.category == .development }), devCategory.sizeGB > 5 {
            suggestions.append(MigrationSuggestion(
                title: "迁移 Xcode DerivedData",
                description: "Xcode 编译缓存占用 \(String(format: "%.1f", devCategory.sizeGB)) GB，可以迁移到外置磁盘并在 Xcode 中重新设置路径",
                sourcePath: "~/Library/Developer/Xcode/DerivedData",
                targetPath: "/Volumes/External/Xcode/DerivedData",
                estimatedSize: devCategory.size,
                priority: devCategory.sizeGB > 20 ? .high : .medium,
                category: .development
            ))
        }
        
        // 2. 视频文件建议
        if let videoCategory = categories.first(where: { $0.category == .videos }), videoCategory.sizeGB > 10 {
            suggestions.append(MigrationSuggestion(
                title: "迁移视频文件",
                description: "视频文件占用 \(String(format: "%.1f", videoCategory.sizeGB)) GB，建议迁移到外置磁盘节省空间",
                sourcePath: "~/Movies",
                targetPath: "/Volumes/External/Movies",
                estimatedSize: videoCategory.size,
                priority: videoCategory.sizeGB > 50 ? .high : .medium,
                category: .videos
            ))
        }
        
        // 3. 大文件归档建议
        let oldLargeFiles = largeFiles.filter {
            $0.modificationDate < Date().addingTimeInterval(-30 * 24 * 60 * 60) && // 30天未修改
            $0.sizeGB > 1
        }
        
        if !oldLargeFiles.isEmpty {
            let totalSize = oldLargeFiles.reduce(0) { $0 + $1.size }
            suggestions.append(MigrationSuggestion(
                title: "归档长期未使用的大文件",
                description: "发现 \(oldLargeFiles.count) 个超过30天未访问的大文件，总计 \(String(format: "%.1f", Double(totalSize) / 1_000_000_000)) GB",
                sourcePath: "多个位置",
                targetPath: "/Volumes/External/Archive",
                estimatedSize: totalSize,
                priority: .medium,
                category: .other
            ))
        }
        
        // 4. 缓存清理建议
        if let cacheCategory = categories.first(where: { $0.category == .cache }), cacheCategory.sizeGB > 2 {
            suggestions.append(MigrationSuggestion(
                title: "清理应用缓存",
                description: "应用缓存占用 \(String(format: "%.1f", cacheCategory.sizeGB)) GB，可以安全清理",
                sourcePath: "~/Library/Caches",
                targetPath: nil,
                estimatedSize: cacheCategory.size,
                priority: .low,
                category: .cache
            ))
        }
        
        // 5. 下载文件夹建议
        let downloadsPath = "\(NSHomeDirectory())/Downloads"
        if let downloadSize = try? fileManager.attributesOfItem(atPath: downloadsPath)[.size] as? Int64,
           Double(downloadSize) / 1_000_000_000 > 5 {
            suggestions.append(MigrationSuggestion(
                title: "整理下载文件夹",
                description: "Downloads 文件夹占用 \(String(format: "%.1f", Double(downloadSize) / 1_000_000_000)) GB，建议清理或迁移旧文件",
                sourcePath: "~/Downloads",
                targetPath: nil,
                estimatedSize: downloadSize,
                priority: .medium,
                category: .other
            ))
        }
        
        return suggestions.sorted { $0.priority > $1.priority }
    }
    
    // MARK: - 便捷方法
    
    /// 获取指定分类的建议
    func suggestions(for category: FileCategory) -> [MigrationSuggestion] {
        analysisResult?.suggestions.filter { $0.category == category } ?? []
    }
    
    /// 获取紧急建议
    var urgentSuggestions: [MigrationSuggestion] {
        analysisResult?.suggestions.filter { $0.priority == .urgent || $0.priority == .high } ?? []
    }
    
    /// 总可优化空间
    var totalOptimizableSize: Int64 {
        analysisResult?.suggestions.reduce(0) { $0 + $1.estimatedSize } ?? 0
    }
}