//
//  PermissionManager.swift
//  权限管理器
//

import Foundation

/// 权限管理器
public actor PermissionManager {
    
    /// 检查浏览器控制权限
    public func checkPermission(for browser: BrowserType) async -> PermissionStatus {
        let script = """
        tell application "\(browser == .chrome ? "Google Chrome" : "Safari")"
            return name
        end tell
        """
        
        var errorInfo: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            _ = appleScript.executeAndReturnError(&errorInfo)
            
            if let error = errorInfo {
                let errorNumber = error["NSAppleScriptErrorNumber"] as? Int ?? -1
                if errorNumber == -1743 {
                    return PermissionStatus(
                        authorized: false,
                        browserType: browser,
                        canControlBrowser: false,
                        canCaptureScreen: false
                    )
                }
            }
        }
        
        return PermissionStatus(
            authorized: true,
            browserType: browser,
            canControlBrowser: true,
            canCaptureScreen: true
        )
    }
    
    /// 请求权限（引导用户到系统设置）
    public func requestPermissionGuide() -> String {
        return """
        需要授权 MacAssistant 控制 Safari。
        
        请按以下步骤操作：
        1. 打开「系统设置」→「隐私与安全性」→「自动化」
        2. 找到 MacAssistant，开启 Safari 开关
        3. 返回应用重新尝试
        """
    }
}
