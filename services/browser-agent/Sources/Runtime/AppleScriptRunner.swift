//
//  AppleScriptRunner.swift
//  AppleScript 执行器
//

import Foundation

/// AppleScript 执行器
public actor AppleScriptRunner {
    
    /// 执行 AppleScript
    public func execute(_ script: String, timeout: TimeInterval = 30) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                var errorInfo: NSDictionary?
                
                guard let appleScript = NSAppleScript(source: script) else {
                    continuation.resume(throwing: BrowserError(
                        code: .internalError,
                        message: "无法创建 AppleScript"
                    ))
                    return
                }
                
                let result = appleScript.executeAndReturnError(&errorInfo)
                
                if let error = errorInfo {
                    let errorNumber = error["NSAppleScriptErrorNumber"] as? Int ?? -1
                    let errorMessage = error["NSAppleScriptErrorMessage"] as? String ?? "未知错误"
                    
                    let browserError: BrowserError
                    if errorNumber == -1743 {
                        browserError = BrowserError(
                            code: .permissionNotGranted,
                            message: "需要授权才能控制 Safari: \(errorMessage)"
                        )
                    } else {
                        browserError = BrowserError(
                            code: .scriptExecutionFailed,
                            message: "AppleScript 错误 (\(errorNumber)): \(errorMessage)"
                        )
                    }
                    continuation.resume(throwing: browserError)
                    return
                }
                
                continuation.resume(returning: result?.stringValue ?? "")
            }
        }
    }
}
