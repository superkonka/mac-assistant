//
//  CLIMarqueeView.swift
//  CLI 进度和原始输出展示
//

import SwiftUI

struct CLIMarqueeView: View {
    @StateObject private var progressManager = CLIProgressManager.shared
    @State private var isExpanded = false
    
    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            headerBar
            
            if progressManager.isActive || !progressManager.steps.isEmpty {
                if isExpanded {
                    // 展开模式：显示完整终端输出
                    expandedTerminalView
                } else {
                    // 收起模式：简单进度条
                    collapsedProgressBar
                }
            }
        }
        .background(AppColors.inputBackground)
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
        )
        .padding(.horizontal, 8)
        .padding(.top, 4)
    }
    
    // MARK: - 标题栏
    private var headerBar: some View {
        HStack(spacing: 8) {
            if progressManager.isActive {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 16, height: 16)
            }
            
            Text(progressManager.isActive ? "AI 正在工作..." : "工作流")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
            
            Spacer()
            
            if progressManager.isActive {
                Text("\(progressManager.steps.count)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.gray.opacity(0.15))
                    .cornerRadius(4)
            }
            
            Button(action: { isExpanded.toggle() }) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(PlainButtonStyle())
            
            if !progressManager.isActive && !progressManager.steps.isEmpty {
                Button(action: { progressManager.clear() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(AppColors.controlBackground)
    }
    
    // MARK: - 收起模式：简单进度条
    private var collapsedProgressBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(progressManager.steps) { step in
                    HStack(spacing: 4) {
                        Text(step.type.icon)
                            .font(.system(size: 10))
                        Text(step.title)
                            .font(.system(size: 10))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(hex: step.type.color).opacity(0.15))
                    )
                    .foregroundColor(Color(hex: step.type.color))
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
        .frame(height: 32)
    }
    
    // MARK: - 展开模式：完整终端视图
    private var expandedTerminalView: some View {
        VStack(spacing: 0) {
            // 步骤列表
            stepsList
            
            Divider()
            
            // 原始输出（终端风格）
            rawOutputView
        }
        .frame(height: 250)
    }
    
    // MARK: - 步骤列表
    private var stepsList: some View {
        ScrollViewReader { proxy in
            List(progressManager.steps) { step in
                StepRow(step: step)
                    .id(step.id)
            }
            .listStyle(.plain)
            .frame(height: 100)
            .onChange(of: progressManager.steps.count) { _ in
                if let last = progressManager.steps.last {
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }
    
    // MARK: - 原始输出（终端风格）
    private var rawOutputView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("原始输出")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                if progressManager.isActive {
                    Text("接收中...")
                        .font(.caption2)
                        .foregroundColor(.blue)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.05))
            
            ScrollViewReader { proxy in
                ScrollView {
                    Text(progressManager.rawOutput)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .id("rawOutputBottom")
                }
                .onChange(of: progressManager.rawOutput) { _ in
                    withAnimation {
                        proxy.scrollTo("rawOutputBottom", anchor: .bottom)
                    }
                }
            }
            .background(Color(NSColor.textBackgroundColor))
        }
        .frame(height: 130)
    }
}

// MARK: - 步骤行

struct StepRow: View {
    let step: CLIStep
    @StateObject private var progressManager = CLIProgressManager.shared
    
    var body: some View {
        HStack(spacing: 8) {
            Text(step.type.icon)
                .font(.system(size: 12))
            
            Text(step.title)
                .font(.system(size: 11))
            
            if let detail = step.detail, !detail.isEmpty {
                Text("- \(detail)")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            
            Spacer()
            
            Text(step.timestamp, style: .time)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 颜色扩展

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default: (a, r, g, b) = (1, 1, 1, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
