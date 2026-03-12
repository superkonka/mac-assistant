//
//  DetectedSkillSuggestionCardView.swift
//  MacAssistant
//

import SwiftUI

struct DetectedSkillSuggestionCardView: View {
    let suggestion: DetectedSkillSuggestion
    var onAction: ((DetectedSkillSuggestionAction) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            requestPreview
            actionButtons
            footer
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.yellow.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.yellow.opacity(0.22), lineWidth: 1)
        )
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.orange)

                Text("检测到 \(suggestion.skill.name) 意图")
                    .font(.system(size: 13, weight: .semibold))

                Spacer()
            }

            HStack(spacing: 6) {
                suggestionTag("独立处理")
                suggestionTag("不影响主会话")
                suggestionTag(suggestion.sourceLabel)
            }
        }
    }

    private var requestPreview: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("原始请求")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)

            Text("“\(suggestion.input)”")
                .font(.system(size: 12))
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.white.opacity(0.72))
                )
        }
    }

    private var actionButtons: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button("这次执行") {
                    onAction?(.runOnce)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button("忽略这次") {
                    onAction?(.dismissOnce)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            HStack(spacing: 8) {
                Button("以后自动执行") {
                    onAction?(.alwaysAutoRun)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("以后不再建议") {
                    onAction?(.neverSuggest)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var footer: some View {
        Text("这些选择只影响自然猜测触发的 Skill。你可以在 Skills > 设置 里统一修改默认策略。")
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func suggestionTag(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(Color.black.opacity(0.04))
            )
    }
}
