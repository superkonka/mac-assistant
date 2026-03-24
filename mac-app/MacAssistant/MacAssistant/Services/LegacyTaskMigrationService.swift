//
//  LegacyTaskMigrationService.swift
//  MacAssistant
//
//  旧任务迁移入口 - 仅负责将旧任务存储数据导入统一任务系统
//

import Foundation

@MainActor
final class LegacyTaskMigrationService {
    static let shared = LegacyTaskMigrationService()
    private let unifiedTaskManager = UnifiedTaskManager.shared
    private let legacyStorageKey = "task_manager_tasks"
    private let legacyMigrationKey = "task_manager_legacy_migration_v1"
    
    private init() {
        migrateStoredTasksIfNeeded()
    }

    private func migrateStoredTasksIfNeeded() {
        guard let data = UserDefaults.standard.data(forKey: legacyStorageKey) else {
            return
        }

        do {
            let legacyTasks = try TaskMigrationHelper.decodeLegacyTaskRecords(from: data)
            guard !legacyTasks.isEmpty else {
                clearLegacyStorage()
                return
            }

            let fingerprint = legacyTasks
                .sorted { $0.id < $1.id }
                .map { "\($0.id):\($0.updatedAt.timeIntervalSince1970)" }
                .joined(separator: "|")

            guard UserDefaults.standard.string(forKey: legacyMigrationKey) != fingerprint else {
                clearLegacyStorage()
                return
            }

            for task in legacyTasks {
                let migrated = TaskMigrationHelper.migrateLegacyTaskRecord(task)
                unifiedTaskManager.importLegacyTask(migrated)
            }

            UserDefaults.standard.set(fingerprint, forKey: legacyMigrationKey)
            clearLegacyStorage()
            LogInfo("[LegacyTaskMigrationService] 已迁移旧任务数据: \(legacyTasks.count)")
        } catch {
            LogError("[LegacyTaskMigrationService] 迁移旧任务失败: \(error)")
        }
    }

    private func clearLegacyStorage() {
        UserDefaults.standard.removeObject(forKey: legacyStorageKey)
    }
}
