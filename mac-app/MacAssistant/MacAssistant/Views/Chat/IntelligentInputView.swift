//
//  IntelligentInputView.swift
//  MacAssistant
//
//  智能输入框 - 支持 @Agent 和 /Skill 触发器
//

import SwiftUI
import Combine
import AppKit

@_exported import struct SwiftUI.Color

struct IntelligentInputView: View {
    @Binding var text: String
    @StateObject private var intelligence = ConversationIntelligence.shared
    @StateObject private var orchestrator = AgentOrchestrator.shared

    let onSend: (String) -> Void
    let onTakeScreenshot: () -> Void
    let onShowSkills: () -> Void

    @State private var showSuggestions = false
    @State private var suggestionFrame: CGRect = .zero
    @FocusState private var isInputFocused: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            inputArea

            if showSuggestions && !intelligence.suggestions.isEmpty {
                suggestionsPopup
                    .offset(y: -suggestionFrame.height - 8)
            }
        }
    }

    private var inputArea: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Button(action: onShowSkills) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Skills (/)")

                Button(action: onTakeScreenshot) {
                    Image(systemName: "camera")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("截图 (⌘⇧5)")
            }

            ZStack(alignment: .topLeading) {
                AdaptiveComposerField(
                    text: $text,
                    isFocused: $isInputFocused,
                    height: composerHeight,
                    onTextChange: handleTextChange,
                    onSubmit: sendCurrentText
                )

                if text.isEmpty {
                    Text("输入 @ 选择 Agent，/ 使用 Skill...")
                        .font(.system(size: 14))
                        .foregroundColor(AppColors.inputPlaceholder)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
            }

            Button(action: sendCurrentText) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(canSend ? .blue : .gray.opacity(0.4))
            }
            .buttonStyle(.plain)
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

    private func handleTextChange(_ newValue: String) {
        let suggestions = intelligence.getSuggestions(for: newValue)

        withAnimation(.easeInOut(duration: 0.15)) {
            intelligence.suggestions = suggestions
            showSuggestions = !suggestions.isEmpty
        }
    }

    private func applySuggestion(_ suggestion: ConversationSuggestion) {
        switch suggestion.action {
        case .useAgent(let agent):
            text = replaceMention(in: text, with: agent.name)
            orchestrator.switchToAgent(agent)

        case .useSkill(let skill):
            text = replaceCommand(in: text, with: skill.name)
        }

        showSuggestions = false
        isInputFocused = true
    }

    private func replaceMention(in text: String, with agentName: String) -> String {
        if let atRange = text.range(of: "@") {
            let afterAt = String(text[atRange.upperBound...])
            if let spaceRange = afterAt.range(of: " ") {
                let endIndex = text.index(atRange.upperBound, offsetBy: spaceRange.lowerBound.utf16Offset(in: afterAt))
                return text.replacingCharacters(in: atRange.lowerBound..<endIndex, with: "@\(agentName) ")
            } else {
                return "@\(agentName) "
            }
        }
        return text
    }

    private func replaceCommand(in text: String, with skillName: String) -> String {
        if let slashRange = text.range(of: "/") {
            let afterSlash = String(text[slashRange.upperBound...])
            if let spaceRange = afterSlash.range(of: " ") {
                let endIndex = text.index(slashRange.upperBound, offsetBy: spaceRange.lowerBound.utf16Offset(in: afterSlash))
                return text.replacingCharacters(in: slashRange.lowerBound..<endIndex, with: "/\(skillName) ")
            } else {
                return "/\(skillName) "
            }
        }
        return text
    }

    private func sendCurrentText() {
        guard canSend else { return }
        showSuggestions = false
        onSend(text)
    }

    private var textHeight: CGFloat {
        let font = NSFont.systemFont(ofSize: 14)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let size = (text as NSString).boundingRect(
            with: CGSize(width: 420, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin],
            attributes: attributes
        )
        return size.height + 20
    }

    private var composerHeight: CGFloat {
        min(max(40, textHeight), 120)
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private struct AdaptiveComposerField: View {
    @Binding var text: String
    @FocusState.Binding var isFocused: Bool

    let height: CGFloat
    let onTextChange: (String) -> Void
    let onSubmit: () -> Void

    var body: some View {
        Group {
            if #available(macOS 15.0, *) {
                modernField
            } else {
                legacyField
            }
        }
    }

    @available(macOS 15.0, *)
    private var modernField: some View {
        TextField("", text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .foregroundStyle(AppColors.inputText)
            .lineLimit(1...5)
            .focused($isFocused)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(height: height)
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
            .onChange(of: text) { newValue in
                onTextChange(newValue)
            }
            .onSubmit {
                onSubmit()
            }
    }

    private var legacyField: some View {
        TextEditor(text: $text)
            .font(.system(size: 14))
            .foregroundColor(NSColor.textColor.swiftUIColor)
            .scrollContentBackground(.hidden)
            .focused($isFocused)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(height: height)
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
            .onChange(of: text) { newValue in
                onTextChange(newValue)
            }
    }
}

private extension NSColor {
    var swiftUIColor: Color {
        Color(self)
    }
}

struct SuggestionRow: View {
    let suggestion: ConversationSuggestion
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Text(suggestion.icon)
                    .font(.system(size: 20))
                    .frame(width: 28)

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
        .buttonStyle(.plain)
        .background(isSelected ? Color.blue.opacity(0.1) : Color.clear)
    }
}

#Preview {
    IntelligentInputView(
        text: .constant(""),
        onSend: { _ in },
        onTakeScreenshot: {},
        onShowSkills: {}
    )
    .frame(width: 500)
}
