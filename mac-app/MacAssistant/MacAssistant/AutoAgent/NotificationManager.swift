//
//  NotificationManager.swift
//  通知管理器
//

import SwiftUI

class NotificationManager: ObservableObject {
    @Published var inAppNotifications: [AgentNotification] = []
    
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
}
