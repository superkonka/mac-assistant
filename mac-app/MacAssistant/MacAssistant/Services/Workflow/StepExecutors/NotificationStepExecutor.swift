//
//  NotificationStepExecutor.swift
//  MacAssistant
//
//  通知步骤执行器 - 发送本地通知
//

import Foundation
import UserNotifications

@MainActor
final class NotificationStepExecutor: StepExecutor {
    static let shared = NotificationStepExecutor()
    
    let supportedKinds: [WorkflowStepKind] = [.notification]
    
    private init() {}
    
    func isAvailable() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus == .authorized
    }
    
    func cancel(runID: String) {
        // 通知无法取消
    }
    
    func execute(_ step: WorkflowStepDef, context: WorkflowContext) async -> StepExecutionResult {
        LogInfo("[NotificationStepExecutor] 发送通知: \(step.name)")
        
        let content = UNMutableNotificationContent()
        content.title = step.name
        content.body = step.description
        content.sound = .default
        
        let request = UNNotificationRequest(
            identifier: "workflow-\(context.runID)-\(step.id)",
            content: content,
            trigger: nil
        )
        
        do {
            try await UNUserNotificationCenter.current().add(request)
            return .success(output: ["notified": "true"])
        } catch {
            return .failure(error: StepExecutionError(
                code: "NOTIFICATION_FAILED",
                message: error.localizedDescription,
                isRetryable: true
            ))
        }
    }
}
