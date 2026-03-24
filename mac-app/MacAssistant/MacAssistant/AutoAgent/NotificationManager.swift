//
//  NotificationManager.swift
//  通知管理器
//

import SwiftUI
import UserNotifications

@MainActor
class NotificationManager: ObservableObject {
    static let shared = NotificationManager()
    
    @Published var inAppNotifications: [AgentNotification] = []
    private let notificationCenter = UNUserNotificationCenter.current()
    
    private init() {}
    
    func showInApp(_ notification: AgentNotification) {
        inAppNotifications.append(notification)
        
        // 3秒后自动移除
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.inAppNotifications.removeAll { $0.id == notification.id }
        }
    }
    
    func dismiss(_ id: UUID) {
        inAppNotifications.removeAll { $0.id == id }
    }
    
    /// 发送本地通知
    func send(title: String, body: String, priority: Priority = .medium) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = priority == .critical ? .defaultCritical : .default
        
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        
        do {
            try await notificationCenter.add(request)
            LogInfo("[NotificationManager] 通知已发送: \(title)")
        } catch {
            LogError("[NotificationManager] 通知发送失败: \(error)")
        }
    }
}
