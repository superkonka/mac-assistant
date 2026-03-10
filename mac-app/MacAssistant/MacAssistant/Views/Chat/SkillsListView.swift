//
//  SkillsListView.swift
//  MacAssistant
//

import SwiftUI

struct SkillsListView: View {
    private enum Panel: String, CaseIterable, Identifiable {
        case builtIn = "内置"
        case marketplace = "市场"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .builtIn:
                return "sparkles"
            case .marketplace:
                return "shippingbox"
            }
        }
    }

    @ObservedObject private var registry = AISkillRegistry.shared
    @ObservedObject private var orchestrator = AgentOrchestrator.shared
    @StateObject private var marketplace = ClawHubMarketplaceService.shared

    @State private var selectedPanel: Panel = .builtIn
    @State private var selectedCategory: SkillCategory? = nil
    @State private var builtInSearchText = ""
    @State private var marketplaceSearchText = ""
    @State private var hoveredSkill: AISkill? = nil
    @State private var hasLoadedMarketplace = false

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            if selectedPanel == .builtIn {
                builtInContent
            } else {
                marketplaceContent
            }
        }
        .frame(width: 760, height: 540)
        .background(AppColors.controlBackground)
        .task {
            guard !hasLoadedMarketplace else { return }
            hasLoadedMarketplace = true
            await marketplace.refreshInstalledSkills()
            await marketplace.refreshAuthState()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Skills")
                .font(.system(size: 18, weight: .semibold, design: .rounded))

            panelPicker

            Spacer()

            searchField

            if selectedPanel == .marketplace {
                Button {
                    Task {
                        await marketplace.refreshAll(query: marketplaceSearchText)
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help("刷新市场与安装状态")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var panelPicker: some View {
        HStack(spacing: 6) {
            ForEach(Panel.allCases) { panel in
                Button {
                    selectedPanel = panel
                    if panel == .marketplace {
                        Task {
                            await marketplace.refreshInstalledSkills()
                            await marketplace.refreshAuthState()
                            if marketplace.remoteSkills.isEmpty {
                                await marketplace.loadCatalog(query: marketplaceSearchText)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: panel.icon)
                            .font(.system(size: 11, weight: .semibold))
                        Text(panel.rawValue)
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                        Capsule(style: .continuous)
                            .fill(selectedPanel == panel ? Color.blue.opacity(0.14) : Color.secondary.opacity(0.08))
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(selectedPanel == panel ? Color.blue.opacity(0.28) : Color.clear, lineWidth: 1)
                    )
                    .foregroundColor(selectedPanel == panel ? .blue : .primary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            if selectedPanel == .builtIn {
                TextField("搜索内置技能...", text: $builtInSearchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
            } else {
                TextField("搜索 ClawHub 或输入已知 slug...", text: $marketplaceSearchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .onSubmit {
                        Task {
                            await marketplace.loadCatalog(query: marketplaceSearchText)
                        }
                    }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(NSColor.textBackgroundColor))
        .cornerRadius(8)
        .frame(width: selectedPanel == .builtIn ? 220 : 280)
    }

    private var builtInContent: some View {
        VStack(spacing: 0) {
            categoryTabs
            Divider()
            builtInGrid
        }
    }

    private var categoryTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                CategoryTab(
                    title: "全部",
                    icon: "square.grid.2x2",
                    isSelected: selectedCategory == nil,
                    count: registry.skills.count
                ) {
                    selectedCategory = nil
                }

                ForEach(SkillCategory.allCases, id: \.self) { category in
                    CategoryTab(
                        title: category.rawValue,
                        icon: category.icon,
                        isSelected: selectedCategory == category,
                        count: registry.skills(in: category).count
                    ) {
                        selectedCategory = category
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private var builtInGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150, maximum: 180), spacing: 12)],
                spacing: 12
            ) {
                ForEach(filteredBuiltInSkills) { skill in
                    AISkillCard(
                        skill: skill,
                        isAvailable: registry.isAvailable(skill),
                        isHovered: hoveredSkill == skill
                    )
                    .onHover { isHovered in
                        hoveredSkill = isHovered ? skill : nil
                    }
                    .onTapGesture {
                        executeSkill(skill)
                    }
                }
            }
            .padding(16)
        }
    }

    private var marketplaceContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                authBanner

                if let notice = marketplace.lastNotice, !notice.isEmpty {
                    MarketplaceNoticeCard(
                        title: "市场状态",
                        icon: "info.circle",
                        accent: .blue,
                        message: notice
                    )
                }

                if !marketplace.installedSkills.isEmpty || marketplace.isRefreshingInstalled {
                    installedSection
                }

                remoteSection
            }
            .padding(16)
        }
        .task(id: selectedPanel == .marketplace ? marketplaceSearchText : "") {
            guard selectedPanel == .marketplace else { return }
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await marketplace.loadCatalog(query: marketplaceSearchText)
        }
    }

    private var authBanner: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("ClawHub Marketplace")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))

                    Text(authDescription)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 16)

                Text(marketplace.authState.badgeText)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(authAccentColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule(style: .continuous)
                            .fill(authAccentColor.opacity(0.12))
                    )
            }

            HStack(spacing: 8) {
                Button("浏览器登录") {
                    Task {
                        await marketplace.launchLogin()
                    }
                }
                .buttonStyle(.borderedProminent)

                if case .loggedIn = marketplace.authState {
                    Button("退出登录") {
                        Task {
                            await marketplace.logout()
                        }
                    }
                    .buttonStyle(.bordered)
                }

                if let installCandidateSlug {
                    Button("安装 \(installCandidateSlug)") {
                        Task {
                            await marketplace.install(slug: installCandidateSlug)
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(marketplace.isMutating(slug: installCandidateSlug))
                }

                Spacer(minLength: 8)

                Text("安装目标：OpenClaw wrapper 的 `workspace/skills`")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(authAccentColor.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(authAccentColor.opacity(0.16), lineWidth: 1)
        )
    }

    private var installedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(
                title: "已安装 Skills",
                icon: "checkmark.seal",
                count: marketplace.installedSkills.count
            )

            if marketplace.isRefreshingInstalled && marketplace.installedSkills.isEmpty {
                MarketplaceLoadingCard(text: "正在读取已安装 Skills...")
            } else {
                VStack(spacing: 10) {
                    ForEach(marketplace.installedSkills) { skill in
                        InstalledMarketplaceSkillCard(
                            skill: skill,
                            isMutating: marketplace.isMutating(slug: skill.slug),
                            onUpdate: {
                                Task {
                                    await marketplace.update(slug: skill.slug)
                                }
                            },
                            onUninstall: {
                                Task {
                                    await marketplace.uninstall(slug: skill.slug)
                                }
                            }
                        )
                    }
                }
            }
        }
    }

    private var remoteSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(
                title: "Marketplace",
                icon: "globe.americas",
                count: marketplace.remoteSkills.count
            )

            switch marketplace.catalogState {
            case .idle:
                MarketplaceEmptyState(
                    icon: "shippingbox",
                    title: "市场还没加载",
                    message: "切到市场页后，这里会展示可安装的 ClawHub Skills。"
                )

            case .loading:
                MarketplaceLoadingCard(text: "正在获取市场列表...")

            case .needsLogin:
                MarketplaceEmptyState(
                    icon: "person.crop.circle.badge.exclamationmark",
                    title: "登录后再浏览完整市场",
                    message: "公共查询容易撞限流。登录 ClawHub 后，可以搜索、浏览和安装更多 Skills。"
                )

            case .rateLimited:
                MarketplaceNoticeCard(
                    title: "公共查询已限流",
                    icon: "bolt.horizontal.circle",
                    accent: .orange,
                    message: "当前公共配额已经耗尽。先登录 ClawHub，再刷新市场。"
                )

            case .failed(let message):
                MarketplaceNoticeCard(
                    title: "市场读取失败",
                    icon: "exclamationmark.triangle",
                    accent: .orange,
                    message: message
                )

            case .empty:
                MarketplaceEmptyState(
                    icon: "magnifyingglass",
                    title: "没有匹配的 Skill",
                    message: installCandidateSlug == nil
                        ? "换个关键词试试，或者直接输入已知 slug。"
                        : "没搜到结果，但你可以直接按 slug 安装。"
                )

            case .ready:
                VStack(spacing: 10) {
                    ForEach(marketplace.remoteSkills) { skill in
                        MarketplaceSkillCard(
                            skill: skill,
                            isInstalled: installedSlugs.contains(skill.slug),
                            isMutating: marketplace.isMutating(slug: skill.slug),
                            onInstall: {
                                Task {
                                    await marketplace.install(slug: skill.slug)
                                }
                            }
                        )
                    }
                }
            }
        }
    }

    private var authDescription: String {
        switch marketplace.authState {
        case .unknown:
            return "正在检查 ClawHub 登录状态。"
        case .loggedOut:
            return "当前未登录。未登录时可以尝试直接按 slug 安装，但浏览市场很容易被公共限流拦住。"
        case .loggedIn(let handle):
            if let handle, !handle.isEmpty {
                return "已连接到 ClawHub 账号 @\(handle)。你现在可以浏览、安装和更新外部 Skills。"
            }
            return "已连接到 ClawHub。你现在可以浏览、安装和更新外部 Skills。"
        case .rateLimited:
            return "当前公共查询已限流。登录后刷新一次，就能恢复市场浏览。"
        case .failed(let message):
            return "读取 ClawHub 状态时出了问题：\(message)"
        }
    }

    private var authAccentColor: Color {
        switch marketplace.authState {
        case .loggedIn:
            return .green
        case .rateLimited:
            return .orange
        case .failed:
            return .orange
        case .unknown:
            return .secondary
        case .loggedOut:
            return .blue
        }
    }

    private var installCandidateSlug: String? {
        let trimmed = marketplaceSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_.")
        let isSlugLike = trimmed.unicodeScalars.allSatisfy { allowed.contains($0) }
        return isSlugLike ? trimmed : nil
    }

    private var installedSlugs: Set<String> {
        Set(marketplace.installedSkills.map(\.slug))
    }

    private var filteredBuiltInSkills: [AISkill] {
        var skills = selectedCategory.map { registry.skills(in: $0) } ?? registry.skills
        let keyword = builtInSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !keyword.isEmpty {
            skills = skills.filter {
                $0.name.localizedCaseInsensitiveContains(keyword) ||
                $0.description.localizedCaseInsensitiveContains(keyword)
            }
        }
        return skills
    }

    private func executeSkill(_ skill: AISkill) {
        let context = MacAssistant.SkillContext(
            currentAgent: orchestrator.currentAgent,
            runner: CommandRunner.shared
        )

        Task {
            let result = await registry.execute(skill, context: context)

            await MainActor.run {
                handleResult(result, for: skill)
            }
        }
    }

    private func handleResult(_ result: SkillResult, for skill: AISkill) {
        switch result {
        case .success(let message):
            print("✅ \(skill.name): \(message)")

        case .requiresInput(let prompt):
            let message = MacAssistant.ChatMessage(
                id: UUID(),
                role: .assistant,
                content: "🎯 **\(skill.name)**\n\n\(prompt)",
                timestamp: Date()
            )
            CommandRunner.shared.messages.append(message)

        case .requiresAgentCreation(let gap):
            NotificationCenter.default.post(
                name: NSNotification.Name("ShowCapabilityDiscovery"),
                object: gap
            )

        case .error(let message):
            print("❌ \(skill.name) 失败: \(message)")
        }
    }

    private func sectionTitle(title: String, icon: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)

            Text(title)
                .font(.system(size: 13, weight: .semibold))

            Text("\(count)")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.12))
                .cornerRadius(999)
        }
    }
}

private struct CategoryTab: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                Text(title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                Text("\(count)")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.15))
                    .cornerRadius(8)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? Color.blue.opacity(0.15) : Color.clear)
            .foregroundColor(isSelected ? .blue : .primary)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.blue.opacity(0.3) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct AISkillCard: View {
    let skill: AISkill
    let isAvailable: Bool
    let isHovered: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(skill.emoji)
                    .font(.system(size: 28))

                Spacer()

                if let shortcut = skill.shortcut {
                    Text(shortcut)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(4)
                }
            }

            Text(skill.name)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(isAvailable ? .primary : .secondary)
                .lineLimit(1)

            Text(skill.description)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            HStack {
                if !isAvailable {
                    HStack(spacing: 2) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 8))
                        Text("需创建 Agent")
                            .font(.system(size: 9))
                    }
                    .foregroundColor(.orange)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(4)
                }

                Spacer()

                HStack(spacing: 2) {
                    Image(systemName: skill.category.icon)
                        .font(.system(size: 8))
                    Text(skill.category.rawValue)
                        .font(.system(size: 9))
                }
                .foregroundColor(categoryColor)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(categoryColor.opacity(0.1))
                .cornerRadius(4)
            }
        }
        .padding(12)
        .frame(height: 120)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isHovered ? Color.blue.opacity(0.05) : AppColors.controlBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    isHovered ? Color.blue.opacity(0.3) :
                    isAvailable ? Color.gray.opacity(0.2) : Color.orange.opacity(0.3),
                    lineWidth: isHovered ? 2 : 1
                )
        )
        .opacity(isAvailable ? 1.0 : 0.74)
    }

    private var categoryColor: Color {
        switch skill.category {
        case .productivity: return .yellow
        case .analysis: return .blue
        case .creation: return .mint
        case .system: return .gray
        case .agent: return .green
        }
    }
}

private struct InstalledMarketplaceSkillCard: View {
    let skill: ClawHubMarketplaceService.InstalledSkill
    let isMutating: Bool
    let onUpdate: () -> Void
    let onUninstall: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(skill.displayName)
                            .font(.system(size: 14, weight: .semibold))
                        Text(skill.slug)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.secondary.opacity(0.1))
                            .cornerRadius(999)
                    }

                    Text(skill.summary)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)

                    Text(skill.statusSummary)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(skill.status?.eligible == true ? .green : .orange)
                }

                Spacer(minLength: 12)

                VStack(alignment: .trailing, spacing: 8) {
                    if let version = skill.version, !version.isEmpty {
                        Text(version)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(.primary.opacity(0.78))
                    }

                    HStack(spacing: 8) {
                        Button(action: onUpdate) {
                            if isMutating {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Text("更新")
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(isMutating)

                        Button(role: .destructive, action: onUninstall) {
                            Text("卸载")
                        }
                        .buttonStyle(.bordered)
                        .disabled(isMutating)
                    }
                }
            }

            HStack(spacing: 8) {
                if let registry = skill.registry, !registry.isEmpty {
                    MarketplaceTag(text: registry, accent: .gray)
                }

                MarketplaceTag(
                    text: skill.status?.eligible == true ? "已就绪" : "需补条件",
                    accent: skill.status?.eligible == true ? .green : .orange
                )
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(NSColor.textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.gray.opacity(0.12), lineWidth: 1)
        )
    }
}

private struct MarketplaceSkillCard: View {
    let skill: ClawHubMarketplaceService.RemoteSkill
    let isInstalled: Bool
    let isMutating: Bool
    let onInstall: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(skill.displayName)
                        .font(.system(size: 14, weight: .semibold))
                    Text(skill.slug)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(999)
                }

                if let summary = skill.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    if let version = skill.version, !version.isEmpty {
                        MarketplaceTag(text: version, accent: .blue)
                    }
                    if let stars = skill.stars {
                        MarketplaceTag(text: "★ \(stars)", accent: .yellow)
                    }
                    if let downloads = skill.downloads {
                        MarketplaceTag(text: "↓ \(downloads)", accent: .mint)
                    }
                    ForEach(Array(skill.tags.prefix(3)), id: \.self) { tag in
                        MarketplaceTag(text: tag, accent: .gray)
                    }
                }
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 10) {
                if let updatedAt = skill.updatedAt {
                    Text(updatedAt.formatted(date: .abbreviated, time: .omitted))
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                }

                if isInstalled {
                    Text("已安装")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.green)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.green.opacity(0.12))
                        .cornerRadius(999)
                } else {
                    Button(action: onInstall) {
                        if isMutating {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("安装")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isMutating)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(NSColor.textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.gray.opacity(0.12), lineWidth: 1)
        )
    }
}

private struct MarketplaceTag: View {
    let text: String
    let accent: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundColor(.primary.opacity(0.82))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(accent.opacity(0.12))
            .cornerRadius(999)
    }
}

private struct MarketplaceLoadingCard: View {
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.secondary.opacity(0.06))
        )
    }
}

private struct MarketplaceNoticeCard: View {
    let title: String
    let icon: String
    let accent: Color
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundColor(accent)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
            }

            Text(message)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(accent.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(accent.opacity(0.14), lineWidth: 1)
        )
    }
}

private struct MarketplaceEmptyState: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 26))
                .foregroundColor(.secondary.opacity(0.9))

            Text(title)
                .font(.system(size: 14, weight: .semibold))

            Text(message)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.secondary.opacity(0.06))
        )
    }
}

#Preview {
    SkillsListView()
}
