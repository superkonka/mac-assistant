//
//  MemorySettings.swift
//  MacAssistant
//
//  Phase 6: Memory System Configuration Management
//

import Foundation
import SwiftUI
import Combine

// MARK: - Memory Settings

/// 记忆系统设置管理器
@MainActor
class MemorySettings: ObservableObject {
    
    static let shared = MemorySettings()
    
    // MARK: - Published Properties
    
    /// 当前启用的阶段
    @Published var currentPhase: MemoryPhase {
        didSet { saveToUserDefaults() }
    }
    
    /// 各层功能开关
    @Published var enableL0Storage: Bool {
        didSet { saveToUserDefaults() }
    }
    @Published var enableL1Filter: Bool {
        didSet { saveToUserDefaults() }
    }
    @Published var enableL2Distill: Bool {
        didSet { saveToUserDefaults() }
    }
    @Published var enableNewRetrieval: Bool {
        didSet { saveToUserDefaults() }
    }
    @Published var enableFullIntegration: Bool {
        didSet { saveToUserDefaults() }
    }
    
    /// 存储后端配置
    @Published var l0Backend: StorageBackend {
        didSet { saveToUserDefaults() }
    }
    @Published var l1Backend: StorageBackend {
        didSet { saveToUserDefaults() }
    }
    @Published var l2Backend: StorageBackend {
        didSet { saveToUserDefaults() }
    }
    
    /// 嵌入服务配置
    @Published var embeddingProvider: EmbeddingProvider {
        didSet { 
            saveToUserDefaults()
            Task { await updateEmbeddingService() }
        }
    }
    @Published var embeddingModel: String {
        didSet { saveToUserDefaults() }
    }
    @Published var openAIAPIKey: String {
        didSet { saveToUserDefaults() }
    }
    
    /// 注入配置
    @Published var injectionEnabled: Bool {
        didSet { saveToUserDefaults() }
    }
    @Published var injectionPosition: InjectionPosition {
        didSet { saveToUserDefaults() }
    }
    @Published var injectionFormat: InjectionFormat {
        didSet { saveToUserDefaults() }
    }
    @Published var contextBudget: Int {
        didSet { saveToUserDefaults() }
    }
    
    /// L1 蒸馏配置
    @Published var l1MinImportance: ImportanceScore {
        didSet { saveToUserDefaults() }
    }
    @Published var l1AsyncDistillation: Bool {
        didSet { saveToUserDefaults() }
    }
    
    /// L2 蒸馏配置
    @Published var l2MinConceptConfidence: Double {
        didSet { saveToUserDefaults() }
    }
    @Published var l2BatchSize: Int {
        didSet { saveToUserDefaults() }
    }
    
    /// 保留策略
    @Published var l0RetentionDays: Int {
        didSet { saveToUserDefaults() }
    }
    @Published var l1RetentionDays: Int {
        didSet { saveToUserDefaults() }
    }
    @Published var l2RetentionDays: Int {
        didSet { saveToUserDefaults() }
    }
    
    // MARK: - Private Properties
    
    private let userDefaults = UserDefaults.standard
    private let settingsKey = "com.macassistant.memory.settings"
    
    // MARK: - Initialization
    
    private init() {
        // 从 UserDefaults 加载或创建默认配置
        let defaults = Self.defaultSettings
        
        self.currentPhase = defaults.currentPhase
        self.enableL0Storage = defaults.enableL0Storage
        self.enableL1Filter = defaults.enableL1Filter
        self.enableL2Distill = defaults.enableL2Distill
        self.enableNewRetrieval = defaults.enableNewRetrieval
        self.enableFullIntegration = defaults.enableFullIntegration
        
        self.l0Backend = defaults.l0Backend
        self.l1Backend = defaults.l1Backend
        self.l2Backend = defaults.l2Backend
        
        self.embeddingProvider = defaults.embeddingProvider
        self.embeddingModel = defaults.embeddingModel
        self.openAIAPIKey = defaults.openAIAPIKey
        
        self.injectionEnabled = defaults.injectionEnabled
        self.injectionPosition = defaults.injectionPosition
        self.injectionFormat = defaults.injectionFormat
        self.contextBudget = defaults.contextBudget
        
        self.l1MinImportance = defaults.l1MinImportance
        self.l1AsyncDistillation = defaults.l1AsyncDistillation
        
        self.l2MinConceptConfidence = defaults.l2MinConceptConfidence
        self.l2BatchSize = defaults.l2BatchSize
        
        self.l0RetentionDays = defaults.l0RetentionDays
        self.l1RetentionDays = defaults.l1RetentionDays
        self.l2RetentionDays = defaults.l2RetentionDays
        
        // 从 UserDefaults 加载保存的设置
        loadFromUserDefaults()
    }
    
    // MARK: - Default Settings
    
    static var defaultSettings: MemorySettingsData {
        MemorySettingsData(
            currentPhase: .integration,
            enableL0Storage: true,
            enableL1Filter: true,
            enableL2Distill: true,
            enableNewRetrieval: true,
            enableFullIntegration: false,
            l0Backend: .inMemory,
            l1Backend: .inMemory,
            l2Backend: .inMemory,
            embeddingProvider: .local,
            embeddingModel: "text-embedding-3-small",
            openAIAPIKey: "",
            injectionEnabled: true,
            injectionPosition: .afterSystem,
            injectionFormat: .structured,
            contextBudget: 2000,
            l1MinImportance: .normal,
            l1AsyncDistillation: true,
            l2MinConceptConfidence: 0.7,
            l2BatchSize: 10,
            l0RetentionDays: 30,
            l1RetentionDays: 90,
            l2RetentionDays: 365
        )
    }
    
    // MARK: - Persistence
    
    private func saveToUserDefaults() {
        let data = MemorySettingsData(
            currentPhase: currentPhase,
            enableL0Storage: enableL0Storage,
            enableL1Filter: enableL1Filter,
            enableL2Distill: enableL2Distill,
            enableNewRetrieval: enableNewRetrieval,
            enableFullIntegration: enableFullIntegration,
            l0Backend: l0Backend,
            l1Backend: l1Backend,
            l2Backend: l2Backend,
            embeddingProvider: embeddingProvider,
            embeddingModel: embeddingModel,
            openAIAPIKey: openAIAPIKey,
            injectionEnabled: injectionEnabled,
            injectionPosition: injectionPosition,
            injectionFormat: injectionFormat,
            contextBudget: contextBudget,
            l1MinImportance: l1MinImportance,
            l1AsyncDistillation: l1AsyncDistillation,
            l2MinConceptConfidence: l2MinConceptConfidence,
            l2BatchSize: l2BatchSize,
            l0RetentionDays: l0RetentionDays,
            l1RetentionDays: l1RetentionDays,
            l2RetentionDays: l2RetentionDays
        )
        
        if let encoded = try? JSONEncoder().encode(data) {
            userDefaults.set(encoded, forKey: settingsKey)
        }
    }
    
    private func loadFromUserDefaults() {
        guard let data = userDefaults.data(forKey: settingsKey),
              let settings = try? JSONDecoder().decode(MemorySettingsData.self, from: data) else {
            return
        }
        
        self.currentPhase = settings.currentPhase
        self.enableL0Storage = settings.enableL0Storage
        self.enableL1Filter = settings.enableL1Filter
        self.enableL2Distill = settings.enableL2Distill
        self.enableNewRetrieval = settings.enableNewRetrieval
        self.enableFullIntegration = settings.enableFullIntegration
        
        self.l0Backend = settings.l0Backend
        self.l1Backend = settings.l1Backend
        self.l2Backend = settings.l2Backend
        
        self.embeddingProvider = settings.embeddingProvider
        self.embeddingModel = settings.embeddingModel
        self.openAIAPIKey = settings.openAIAPIKey
        
        self.injectionEnabled = settings.injectionEnabled
        self.injectionPosition = settings.injectionPosition
        self.injectionFormat = settings.injectionFormat
        self.contextBudget = settings.contextBudget
        
        self.l1MinImportance = settings.l1MinImportance
        self.l1AsyncDistillation = settings.l1AsyncDistillation
        
        self.l2MinConceptConfidence = settings.l2MinConceptConfidence
        self.l2BatchSize = settings.l2BatchSize
        
        self.l0RetentionDays = settings.l0RetentionDays
        self.l1RetentionDays = settings.l1RetentionDays
        self.l2RetentionDays = settings.l2RetentionDays
    }
    
    // MARK: - Updates
    
    private func updateEmbeddingService() async {
        let service: EmbeddingService
        
        switch embeddingProvider {
        case .openAI:
            guard !openAIAPIKey.isEmpty else {
                LogWarning("[MemorySettings] OpenAI API Key is empty, falling back to local")
                service = LocalEmbeddingService()
                break
            }
            service = OpenAIEmbeddingService(apiKey: openAIAPIKey, model: embeddingModel)
            
        case .local:
            service = LocalEmbeddingService()
            
        case .custom:
            // 自定义嵌入服务
            service = LocalEmbeddingService()
        }
        
        await EmbeddingServiceFactory.setShared(service)
        LogInfo("[MemorySettings] Embedding service updated to \(embeddingProvider.rawValue)")
    }
    
    // MARK: - Public Methods
    
    /// 重置为默认设置
    func resetToDefaults() {
        let defaults = Self.defaultSettings
        
        currentPhase = defaults.currentPhase
        enableL0Storage = defaults.enableL0Storage
        enableL1Filter = defaults.enableL1Filter
        enableL2Distill = defaults.enableL2Distill
        enableNewRetrieval = defaults.enableNewRetrieval
        enableFullIntegration = defaults.enableFullIntegration
        
        l0Backend = defaults.l0Backend
        l1Backend = defaults.l1Backend
        l2Backend = defaults.l2Backend
        
        embeddingProvider = defaults.embeddingProvider
        embeddingModel = defaults.embeddingModel
        openAIAPIKey = defaults.openAIAPIKey
        
        injectionEnabled = defaults.injectionEnabled
        injectionPosition = defaults.injectionPosition
        injectionFormat = defaults.injectionFormat
        contextBudget = defaults.contextBudget
        
        l1MinImportance = defaults.l1MinImportance
        l1AsyncDistillation = defaults.l1AsyncDistillation
        
        l2MinConceptConfidence = defaults.l2MinConceptConfidence
        l2BatchSize = defaults.l2BatchSize
        
        l0RetentionDays = defaults.l0RetentionDays
        l1RetentionDays = defaults.l1RetentionDays
        l2RetentionDays = defaults.l2RetentionDays
        
        saveToUserDefaults()
    }
    
    /// 导出设置为 JSON
    func exportSettings() -> String? {
        let data = MemorySettingsData(
            currentPhase: currentPhase,
            enableL0Storage: enableL0Storage,
            enableL1Filter: enableL1Filter,
            enableL2Distill: enableL2Distill,
            enableNewRetrieval: enableNewRetrieval,
            enableFullIntegration: enableFullIntegration,
            l0Backend: l0Backend,
            l1Backend: l1Backend,
            l2Backend: l2Backend,
            embeddingProvider: embeddingProvider,
            embeddingModel: embeddingModel,
            openAIAPIKey: "***", // 不导出 API Key
            injectionEnabled: injectionEnabled,
            injectionPosition: injectionPosition,
            injectionFormat: injectionFormat,
            contextBudget: contextBudget,
            l1MinImportance: l1MinImportance,
            l1AsyncDistillation: l1AsyncDistillation,
            l2MinConceptConfidence: l2MinConceptConfidence,
            l2BatchSize: l2BatchSize,
            l0RetentionDays: l0RetentionDays,
            l1RetentionDays: l1RetentionDays,
            l2RetentionDays: l2RetentionDays
        )
        
        guard let encoded = try? JSONEncoder().encode(data) else { return nil }
        return String(data: encoded, encoding: .utf8)
    }
    
    /// 从 JSON 导入设置
    func importSettings(from json: String) -> Bool {
        guard let data = json.data(using: .utf8),
              let settings = try? JSONDecoder().decode(MemorySettingsData.self, from: data) else {
            return false
        }
        
        currentPhase = settings.currentPhase
        enableL0Storage = settings.enableL0Storage
        enableL1Filter = settings.enableL1Filter
        enableL2Distill = settings.enableL2Distill
        enableNewRetrieval = settings.enableNewRetrieval
        enableFullIntegration = settings.enableFullIntegration
        
        l0Backend = settings.l0Backend
        l1Backend = settings.l1Backend
        l2Backend = settings.l2Backend
        
        embeddingProvider = settings.embeddingProvider
        embeddingModel = settings.embeddingModel
        // 不导入 API Key
        
        injectionEnabled = settings.injectionEnabled
        injectionPosition = settings.injectionPosition
        injectionFormat = settings.injectionFormat
        contextBudget = settings.contextBudget
        
        l1MinImportance = settings.l1MinImportance
        l1AsyncDistillation = settings.l1AsyncDistillation
        
        l2MinConceptConfidence = settings.l2MinConceptConfidence
        l2BatchSize = settings.l2BatchSize
        
        l0RetentionDays = settings.l0RetentionDays
        l1RetentionDays = settings.l1RetentionDays
        l2RetentionDays = settings.l2RetentionDays
        
        saveToUserDefaults()
        return true
    }
    
    /// 创建 PromptInjectionConfig
    func createInjectionConfig() -> PromptInjectionConfig {
        PromptInjectionConfig(
            enabled: injectionEnabled,
            l2TokenAllocation: Int(Double(contextBudget) * 0.4),
            l1TokenAllocation: Int(Double(contextBudget) * 0.4),
            l0TokenAllocation: Int(Double(contextBudget) * 0.2),
            injectionPosition: injectionPosition,
            format: injectionFormat,
            includeConfidence: true,
            includeCitations: true,
            relevanceThreshold: 0.6
        )
    }
    
    /// 更新 FeatureFlags
    func syncToFeatureFlags() {
        MemoryFeatureFlags.currentPhase = currentPhase
        MemoryFeatureFlags.enableL0Storage = enableL0Storage
        MemoryFeatureFlags.enableL1Filter = enableL1Filter
        MemoryFeatureFlags.enableL2Distill = enableL2Distill
        MemoryFeatureFlags.enableNewRetrieval = enableNewRetrieval
        MemoryFeatureFlags.enableFullIntegration = enableFullIntegration
        MemoryFeatureFlags.asyncDistillation = l1AsyncDistillation
        MemoryFeatureFlags.l0RetentionDays = l0RetentionDays
    }
}

// MARK: - Settings Data Model

struct MemorySettingsData {
    var currentPhase: MemoryPhase
    var enableL0Storage: Bool
    var enableL1Filter: Bool
    var enableL2Distill: Bool
    var enableNewRetrieval: Bool
    var enableFullIntegration: Bool
    var l0Backend: StorageBackend
    var l1Backend: StorageBackend
    var l2Backend: StorageBackend
    var embeddingProvider: EmbeddingProvider
    var embeddingModel: String
    var openAIAPIKey: String
    var injectionEnabled: Bool
    var injectionPosition: InjectionPosition
    var injectionFormat: InjectionFormat
    var contextBudget: Int
    var l1MinImportance: ImportanceScore
    var l1AsyncDistillation: Bool
    var l2MinConceptConfidence: Double
    var l2BatchSize: Int
    var l0RetentionDays: Int
    var l1RetentionDays: Int
    var l2RetentionDays: Int
}

// Manual Codable implementation to handle InjectionPosition/Format
extension MemorySettingsData: Codable {
    enum CodingKeys: String, CodingKey {
        case currentPhase, enableL0Storage, enableL1Filter, enableL2Distill
        case enableNewRetrieval, enableFullIntegration
        case l0Backend, l1Backend, l2Backend
        case embeddingProvider, embeddingModel, openAIAPIKey
        case injectionEnabled, injectionPosition, injectionFormat
        case contextBudget, l1MinImportance, l1AsyncDistillation
        case l2MinConceptConfidence, l2BatchSize
        case l0RetentionDays, l1RetentionDays, l2RetentionDays
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(currentPhase.rawValue, forKey: .currentPhase)
        try container.encode(enableL0Storage, forKey: .enableL0Storage)
        try container.encode(enableL1Filter, forKey: .enableL1Filter)
        try container.encode(enableL2Distill, forKey: .enableL2Distill)
        try container.encode(enableNewRetrieval, forKey: .enableNewRetrieval)
        try container.encode(enableFullIntegration, forKey: .enableFullIntegration)
        try container.encode(l0Backend.rawValue, forKey: .l0Backend)
        try container.encode(l1Backend.rawValue, forKey: .l1Backend)
        try container.encode(l2Backend.rawValue, forKey: .l2Backend)
        try container.encode(embeddingProvider, forKey: .embeddingProvider)
        try container.encode(embeddingModel, forKey: .embeddingModel)
        try container.encode(openAIAPIKey, forKey: .openAIAPIKey)
        try container.encode(injectionEnabled, forKey: .injectionEnabled)
        try container.encode(injectionPosition.rawValue, forKey: .injectionPosition)
        try container.encode(injectionFormat.rawValue, forKey: .injectionFormat)
        try container.encode(contextBudget, forKey: .contextBudget)
        try container.encode(l1MinImportance, forKey: .l1MinImportance)
        try container.encode(l1AsyncDistillation, forKey: .l1AsyncDistillation)
        try container.encode(l2MinConceptConfidence, forKey: .l2MinConceptConfidence)
        try container.encode(l2BatchSize, forKey: .l2BatchSize)
        try container.encode(l0RetentionDays, forKey: .l0RetentionDays)
        try container.encode(l1RetentionDays, forKey: .l1RetentionDays)
        try container.encode(l2RetentionDays, forKey: .l2RetentionDays)
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let phaseRaw = try container.decode(String.self, forKey: .currentPhase)
        currentPhase = MemoryPhase(rawValue: phaseRaw) ?? .integration
        enableL0Storage = try container.decode(Bool.self, forKey: .enableL0Storage)
        enableL1Filter = try container.decode(Bool.self, forKey: .enableL1Filter)
        enableL2Distill = try container.decode(Bool.self, forKey: .enableL2Distill)
        enableNewRetrieval = try container.decode(Bool.self, forKey: .enableNewRetrieval)
        enableFullIntegration = try container.decode(Bool.self, forKey: .enableFullIntegration)
        let l0Raw = try container.decode(String.self, forKey: .l0Backend)
        l0Backend = StorageBackend(rawValue: l0Raw) ?? .inMemory
        let l1Raw = try container.decode(String.self, forKey: .l1Backend)
        l1Backend = StorageBackend(rawValue: l1Raw) ?? .inMemory
        let l2Raw = try container.decode(String.self, forKey: .l2Backend)
        l2Backend = StorageBackend(rawValue: l2Raw) ?? .inMemory
        embeddingProvider = try container.decode(EmbeddingProvider.self, forKey: .embeddingProvider)
        embeddingModel = try container.decode(String.self, forKey: .embeddingModel)
        openAIAPIKey = try container.decode(String.self, forKey: .openAIAPIKey)
        injectionEnabled = try container.decode(Bool.self, forKey: .injectionEnabled)
        
        let positionRaw = try container.decode(String.self, forKey: .injectionPosition)
        injectionPosition = InjectionPosition(rawValue: positionRaw) ?? .afterSystem
        
        let formatRaw = try container.decode(String.self, forKey: .injectionFormat)
        injectionFormat = InjectionFormat(rawValue: formatRaw) ?? .structured
        
        contextBudget = try container.decode(Int.self, forKey: .contextBudget)
        l1MinImportance = try container.decode(ImportanceScore.self, forKey: .l1MinImportance)
        l1AsyncDistillation = try container.decode(Bool.self, forKey: .l1AsyncDistillation)
        l2MinConceptConfidence = try container.decode(Double.self, forKey: .l2MinConceptConfidence)
        l2BatchSize = try container.decode(Int.self, forKey: .l2BatchSize)
        l0RetentionDays = try container.decode(Int.self, forKey: .l0RetentionDays)
        l1RetentionDays = try container.decode(Int.self, forKey: .l1RetentionDays)
        l2RetentionDays = try container.decode(Int.self, forKey: .l2RetentionDays)
    }
}

// MARK: - Enums

enum EmbeddingProvider: String, Codable, CaseIterable {
    case openAI = "OpenAI"
    case local = "Local"
    case custom = "Custom"
    
    var description: String {
        switch self {
        case .openAI:
            return "OpenAI (云端，高质量)"
        case .local:
            return "本地模型 (离线，隐私)"
        case .custom:
            return "自定义服务"
        }
    }
}

// InjectionPosition and InjectionFormat are public enums from PromptInjection.swift
// They are automatically available for Codable conformance
