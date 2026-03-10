//
//  AppColors.swift
//  MacAssistant
//
//  统一颜色管理 - 确保跨设备一致性
//

import SwiftUI

/// 应用统一颜色管理
enum AppColors {
    
    // MARK: - 输入框颜色
    
    /// 输入框背景色 - 使用明确的系统颜色
    static var inputBackground: Color {
        Color(NSColor.textBackgroundColor)
    }
    
    /// 输入框文字颜色
    static var inputText: Color {
        Color(NSColor.textColor)
    }
    
    /// 输入框占位符颜色
    static var inputPlaceholder: Color {
        Color(NSColor.placeholderTextColor)
    }
    
    /// 输入框边框颜色
    static var inputBorder: Color {
        Color.gray.opacity(0.4)
    }
    
    /// 输入框焦点边框颜色
    static var inputBorderFocused: Color {
        Color.accentColor.opacity(0.6)
    }
    
    // MARK: - 背景色
    
    /// 主背景色
    static var background: Color {
        Color(NSColor.windowBackgroundColor)
    }
    
    /// 控制背景色
    static var controlBackground: Color {
        Color(NSColor.controlBackgroundColor)
    }
    
    /// 次要背景色
    static var secondaryBackground: Color {
        Color(NSColor.underPageBackgroundColor)
    }
    
    // MARK: - 文字颜色
    
    /// 主文字颜色
    static var primaryText: Color {
        Color(NSColor.label)
    }
    
    /// 次要文字颜色
    static var secondaryText: Color {
        Color(NSColor.secondaryLabelColor)
    }
    
    /// 高对比度文字（确保可读性）
    static var highContrastText: Color {
        Color(NSColor.textColor)
    }
    
    // MARK: - 消息气泡颜色
    
    /// 用户消息背景
    static var userMessageBackground: Color {
        Color.blue.opacity(0.12)
    }
    
    /// AI 消息背景
    static var assistantMessageBackground: Color {
        Color(NSColor.controlBackgroundColor)
    }
    
    /// 消息边框颜色
    static var messageBorder: Color {
        Color.gray.opacity(0.2)
    }
    
    // MARK: - 分隔线颜色
    
    static var divider: Color {
        Color(NSColor.separatorColor)
    }
}

// MARK: - View 扩展

extension View {
    /// 统一输入框样式
    func inputFieldStyle(isFocused: Bool = false) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(AppColors.inputBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        isFocused ? AppColors.inputBorderFocused : AppColors.inputBorder,
                        lineWidth: isFocused ? 1.5 : 1
                    )
            )
    }
}
