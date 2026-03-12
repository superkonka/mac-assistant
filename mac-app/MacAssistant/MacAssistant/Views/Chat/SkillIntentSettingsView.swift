//
//  SkillIntentSettingsView.swift
//  MacAssistant
//

import SwiftUI

struct SkillIntentSettingsView: View {
    @ObservedObject private var preferences = UserPreferenceStore.shared

    private let detectableSkills = AISkill.allCases.filter(\.supportsIntentDetection)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PlannerConsoleView()
                summaryCard
                globalToggle

                VStack(alignment: .leading, spacing: 12) {
                    Text("自然意图策略")
                        .font(.system(size: 15, weight: .semibold))

                    ForEach(detectableSkills) { skill in
                        skillRow(for: skill)
                    }
                }
            }
            .padding(16)
        }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("猜测到的 Skill 不再直接插入主会话")
                .font(.system(size: 15, weight: .semibold))

            Text("开启后，系统会把猜测到的网络搜索、翻译、总结这类能力拆成独立任务卡处理。你可以选择每次都问、自动执行，或者不再建议。")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.blue.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.blue.opacity(0.2), lineWidth: 1)
        )
    }

    private var globalToggle: some View {
        Toggle(isOn: Binding(
            get: { !preferences.disableNaturalIntentDetection },
            set: { preferences.disableNaturalIntentDetection = !$0 }
        )) {
            VStack(alignment: .leading, spacing: 4) {
                Text("启用自然意图检测")
                    .font(.system(size: 13, weight: .semibold))
                Text("关闭后，只保留显式 `/skill` 命令和手动入口。")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .toggleStyle(.switch)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.03))
        )
    }

    private func skillRow(for skill: AISkill) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(skill.emoji)
                    Text(skill.name)
                        .font(.system(size: 13, weight: .semibold))
                }

                Text(skill.description)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                Text(preferences.detectionPreference(for: skill).subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Spacer(minLength: 12)

            Picker(
                "策略",
                selection: Binding(
                    get: { preferences.detectionPreference(for: skill) },
                    set: { preferences.setDetectionPreference($0, for: skill) }
                )
            ) {
                ForEach(SkillDetectionPreference.allCases) { preference in
                    Text(preference.title).tag(preference)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 140)
            .disabled(preferences.disableNaturalIntentDetection)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
        )
    }
}
