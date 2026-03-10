//
//  IntelligentInputView.swift
//  MacAssistant
//
//  智能输入框 - 支持 @Agent 和 /Skill 触发器
//

import SwiftUI
import Combine
import AppKit

struct IntelligentInputView: View {
    @Binding var text: String
    @StateObject private var intelligence = ConversationIntelligence.shared
    @StateObject private var orchestrator = AgentOrchestrator.shared
    @StateObject private var skillRegistry = AISkillRegistry.shared
    
    let onSend: (String) -> Void
    let onTakeScreenshot: () -> Void
    let onShowSkills: () -> Void
    
    @State private var showSuggestions = false
    @State private var suggestionFrame: CGRect = .zero
    @State private var isFocused = false
    
    var body: some View {
        ZStack(alignment: .bottom) {
            // 输入区域
            inputArea
            
            // 建议下拉列表
            if showSuggestions && !intelligence.suggestions.isEmpty {
                suggestionsPopup
                    .offset(y: -suggestionFrame.height - 8)
            }
        }
    }
    
    // MARK: - 子视图
    
    private var inputArea: some View {
        HStack(spacing: 8) {
            // 左侧功能按钮
            HStack(spacing: 4) {
                // Skills 按钮
                Button(action: onShowSkills) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(PlainButtonStyle())
                .help("Skills (/)")
                
                // 截图按钮
                Button(action: onTakeScreenshot) {
                    Image(systemName: "camera")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(PlainButtonStyle())
                .help("截图 (⌘⇧5)")
            }
            
            // 智能输入框
            ZStack(alignment: .topLeading) {
                ChatInputTextView(
                    text: $text,
                    isFocused: $isFocused,
                    onSend: onSend
                )
                    .frame(height: min(max(36, textHeight), 120))
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(8)
                    .onChange(of: text) { newValue in
                        handleTextChange(newValue)
                    }
                
                // 提示文字（当输入框为空时）
                if text.isEmpty {
                    Text("输入 @ 选择 Agent，/ 使用 Skill...")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
            }
            
            // 发送按钮
            Button(action: { onSend(text) }) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(canSend ? .blue : .gray.opacity(0.4))
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(!canSend)
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor))
        .background(
            GeometryReader { geo in
                Color.clear.onAppear {
                    suggestionFrame = geo.frame(in: .global)
                }
            }
        )
    }
    
    private var suggestionsPopup: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(intelligence.suggestions.enumerated()), id: \.element.id) { index, suggestion in
                SuggestionRow(
                    suggestion: suggestion,
                    isSelected: false,
                    onSelect: {
                        applySuggestion(suggestion)
                    }
                )
                .background(index % 2 == 0 ? Color.clear : Color.black.opacity(0.02))
            }
        }
        .frame(maxWidth: 300)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: -4)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.gray.opacity(0.2), lineWidth: 1)
        )
    }
    
    // MARK: - 处理方法
    
    private func handleTextChange(_ newValue: String) {
        // 获取建议
        let suggestions = intelligence.getSuggestions(for: newValue)
        
        withAnimation(.easeInOut(duration: 0.15)) {
            intelligence.suggestions = suggestions
            showSuggestions = !suggestions.isEmpty
        }
    }
    
    private func applySuggestion(_ suggestion: ConversationSuggestion) {
        switch suggestion.action {
        case .useAgent(let agent):
            // 替换 @xxx 为正确的 Agent 名称
            text = replaceMention(in: text, with: agent.name)
            orchestrator.switchToAgent(agent)
            
        case .useSkill(let skill):
            // 替换 /xxx 为正确的 Skill 命令
            text = replaceCommand(in: text, with: skill.name)
        }
        
        showSuggestions = false
        isFocused = true
    }
    
    private func replaceMention(in text: String, with agentName: String) -> String {
        // 找到 @ 后面的内容并替换
        if let atRange = text.range(of: "@") {
            let afterAt = String(text[atRange.upperBound...])
            // 找到空格或结束位置
            if let spaceRange = afterAt.range(of: " ") {
                return text.replacingCharacters(in: atRange.lowerBound..<text.index(atRange.upperBound, offsetBy: spaceRange.lowerBound.utf16Offset(in: afterAt)), with: "@\(agentName) ")
            } else {
                return "@\(agentName) "
            }
        }
        return text
    }
    
    private func replaceCommand(in text: String, with skillName: String) -> String {
        // 找到 / 后面的内容并替换
        if let slashRange = text.range(of: "/") {
            let afterSlash = String(text[slashRange.upperBound...])
            if let spaceRange = afterSlash.range(of: " ") {
                return text.replacingCharacters(in: slashRange.lowerBound..<text.index(slashRange.upperBound, offsetBy: spaceRange.lowerBound.utf16Offset(in: afterSlash)), with: "/\(skillName) ")
            } else {
                return "/\(skillName) "
            }
        }
        return text
    }
    
    // MARK: - 计算属性
    
    private var textHeight: CGFloat {
        let font = NSFont.systemFont(ofSize: 14)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let size = (text as NSString).boundingRect(
            with: CGSize(width: 400, height: CGFloat.infinity),
            options: [.usesLineFragmentOrigin],
            attributes: attributes
        )
        return size.height + 20
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct ChatInputTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool

    let onSend: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let textView = ComposerTextView()
        textView.delegate = context.coordinator
        textView.onSend = { [weak textView] in
            onSend(textView?.string ?? text)
        }
        textView.font = .systemFont(ofSize: 14)
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.textContainerInset = NSSize(width: 8, height: 10)
        textView.textColor = .labelColor

        if let textContainer = textView.textContainer {
            textContainer.widthTracksTextView = true
            textContainer.containerSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? ComposerTextView else { return }

        if textView.string != text {
            textView.string = text
        }

        textView.onSend = { [weak textView] in
            onSend(textView?.string ?? text)
        }

        if isFocused, scrollView.window?.firstResponder !== textView {
            scrollView.window?.makeFirstResponder(textView)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatInputTextView

        init(_ parent: ChatInputTextView) {
            self.parent = parent
        }

        func textDidBeginEditing(_ notification: Notification) {
            parent.isFocused = true
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.isFocused = false
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let updated = textView.string
            if parent.text != updated {
                parent.text = updated
            }
        }
    }
}

final class ComposerTextView: NSTextView {
    var onSend: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isReturnKey = event.keyCode == 36 || event.keyCode == 76
        let hasOnlyPlainReturnModifiers = modifiers.intersection([.shift, .control, .option, .command]).isEmpty

        if isReturnKey, hasOnlyPlainReturnModifiers, !hasMarkedText() {
            onSend?()
            return
        }

        super.keyDown(with: event)
    }
}

// MARK: - 建议行

struct SuggestionRow: View {
    let suggestion: ConversationSuggestion
    let isSelected: Bool
    let onSelect: () -> Void
    
    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                // 图标
                Text(suggestion.icon)
                    .font(.system(size: 20))
                    .frame(width: 28)
                
                // 标题和描述
                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(suggestion.isAvailable ? .primary : .secondary)
                    
                    Text(suggestion.subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                
                Spacer()
                
                // 类型标签
                HStack(spacing: 2) {
                    Image(systemName: suggestion.type == .agent ? "person.fill" : "bolt.fill")
                        .font(.system(size: 8))
                    Text(suggestion.type == .agent ? "Agent" : "Skill")
                        .font(.system(size: 9))
                }
                .foregroundColor(suggestion.type == .agent ? .blue : .orange)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(
                    (suggestion.type == .agent ? Color.blue : Color.orange)
                        .opacity(0.1)
                )
                .cornerRadius(4)
                
                // 不可用指示
                if !suggestion.isAvailable {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .background(isSelected ? Color.blue.opacity(0.1) : Color.clear)
    }
}

// MARK: - 预览

#Preview {
    IntelligentInputView(
        text: .constant(""),
        onSend: { _ in },
        onTakeScreenshot: {},
        onShowSkills: {}
    )
    .frame(width: 500)
}
