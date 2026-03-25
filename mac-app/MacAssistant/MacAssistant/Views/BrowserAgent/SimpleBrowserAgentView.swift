//
//  SimpleBrowserAgentView.swift
//  MacAssistant
//
//  简化的浏览器代理界面
//

import SwiftUI

struct SimpleBrowserAgentView: View {
    @StateObject private var agent = SimpleBrowserAgent.shared
    @StateObject private var sessionStore = BrowserSessionStore.shared
    @State private var urlInput = ""
    @State private var browserInstruction = ""
    @State private var messageContact = ""
    @State private var messageContent = ""
    @State private var showingWhatsAppPanel = false
    @State private var latestAssistantNote = ""
    @State private var permissionStatus: (authorized: Bool, error: String?, needsRestart: Bool) = (false, nil, false)
    @State private var isCheckingPermission = false
    @Environment(\.dismiss) private var dismiss
    @State private var hasCheckedPermission = false
    
    var body: some View {
        VStack(spacing: 0) {
            // 工具栏
            toolbar
            
            // 权限警告条
            if !isCheckingPermission {
                if !permissionStatus.authorized {
                    permissionWarningBanner
                } else if permissionStatus.needsRestart {
                    restartRequiredBanner
                }
            }
            
            Divider()
            
            if agent.isRunning {
                // 主内容
                ScrollView {
                    VStack(spacing: 20) {
                        sessionOverviewSection
                        
                        Divider()
                        
                        // 快速导航
                        quickNavigationSection
                        
                        Divider()
                        
                        // WhatsApp 自动化
                        whatsAppSection
                        
                        Divider()
                        
                        // 操作日志
                        actionLogSection
                    }
                    .padding()
                }
            } else {
                notRunningView
            }
        }
        .frame(minWidth: 500, minHeight: 400)
        .background(Color(.windowBackgroundColor))
        .onAppear {
            if !hasCheckedPermission {
                hasCheckedPermission = true
                checkPermission()
            }
        }
    }
    
    // MARK: - 子视图
    
    private var toolbar: some View {
        HStack(spacing: 12) {
            // 启动开关
            Toggle(isOn: .init(
                get: { agent.isRunning },
                set: { newValue in
                    if newValue {
                        agent.start()
                    } else {
                        agent.stop()
                    }
                }
            )) {
                HStack(spacing: 4) {
                    Image(systemName: agent.isRunning ? "globe" : "globe.badge.chevron.backward")
                    Text(agent.isRunning ? "运行中" : "已停止")
                        .font(.system(size: 12))
                }
            }
            .toggleStyle(.switch)
            
            Divider().frame(height: 20)
            
            if agent.isRunning {
                // URL 输入
                HStack(spacing: 6) {
                    Image(systemName: "globe")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    TextField("输入网址...", text: $urlInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .onSubmit { navigateToURL() }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                
                Button { navigateToURL() } label: {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 16))
                }
                .buttonStyle(.borderless)
                .disabled(urlInput.isEmpty)
                
                Divider().frame(height: 20)
                
                // 浏览器指示
                HStack(spacing: 4) {
                    Image(systemName: browserIcon)
                        .font(.system(size: 12))
                    Text(agent.browserName)
                        .font(.system(size: 11))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.blue.opacity(0.1))
                .foregroundColor(.blue)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

                if let activeSession = sessionStore.activeSession {
                    HStack(spacing: 4) {
                        Image(systemName: "rectangle.and.text.magnifyingglass")
                            .font(.system(size: 12))
                        Text(activeSession.statusLabel)
                            .font(.system(size: 11, weight: .medium))
                        Text(activeSession.id)
                            .font(.system(size: 10, design: .monospaced))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.green.opacity(0.1))
                    .foregroundColor(.green)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
            }
            
            Spacer()
            
            // 权限状态指示
            HStack(spacing: 6) {
                if isCheckingPermission {
                    ProgressView()
                        .controlSize(.small)
                    Text("检查权限...")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else if permissionStatus.needsRestart {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .foregroundColor(.blue)
                        .font(.system(size: 12))
                    Text("需重启")
                        .font(.system(size: 11))
                        .foregroundColor(.blue)
                } else if permissionStatus.authorized {
                    Image(systemName: "checkmark.shield.fill")
                        .foregroundColor(.green)
                        .font(.system(size: 12))
                    Text("已授权")
                        .font(.system(size: 11))
                        .foregroundColor(.green)
                } else {
                    Image(systemName: "exclamationmark.shield.fill")
                        .foregroundColor(.orange)
                        .font(.system(size: 12))
                    Text("需要授权")
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .onTapGesture {
                if !permissionStatus.authorized {
                    openPermissionSettings()
                } else if permissionStatus.needsRestart {
                    restartApp()
                }
            }
            
            // 帮助按钮
            Button {
                showHelp()
            } label: {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 14))
            }
            .buttonStyle(.borderless)
        }
        .padding()
    }

    private var sessionOverviewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("当前网页会话")
                    .font(.system(size: 13, weight: .semibold))

                Spacer()

                if let activeSession = sessionStore.activeSession {
                    Button {
                        captureBrowserScreenshot()
                    } label: {
                        Label("截图", systemImage: "camera")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        refreshCurrentPage()
                    } label: {
                        Label("刷新识别", systemImage: "arrow.clockwise")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        cancelPendingBrowserFlow(activeSession.id)
                    } label: {
                        Label("取消挂起", systemImage: "xmark.circle")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if let activeSession = sessionStore.activeSession {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        statusChip(activeSession.statusLabel, color: statusColor(for: activeSession.status))

                        if let snapshot = activeSession.latestSnapshot {
                            statusChip(snapshot.pageKind.displayName, color: .blue)
                            statusChip(snapshot.authState.displayName, color: authColor(for: snapshot.authState))
                        }
                    }

                    if let snapshot = activeSession.latestSnapshot {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(snapshot.title.isEmpty ? "未识别标题" : snapshot.title)
                                .font(.system(size: 14, weight: .medium))
                            Text(snapshot.url)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)

                            Text(BrowserPageAnalyzer.analyze(snapshot).summary)
                                .font(.system(size: 12))
                                .foregroundStyle(.primary)

                            if !snapshot.textExcerpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text(snapshot.textExcerpt.trimmingCharacters(in: .whitespacesAndNewlines))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(4)
                            }

                            if !snapshot.actionableElements.isEmpty {
                                FlowTagList(
                                    items: Array(snapshot.actionableElements
                                        .map { $0.label.trimmingCharacters(in: .whitespacesAndNewlines) }
                                        .filter { !$0.isEmpty }
                                        .prefix(8))
                                )
                            }
                        }
                    } else {
                        Text("当前已有浏览器会话，但还没有拿到页面摘要。可以点“刷新识别”，或者在对话里说“看看当前页面”。")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }

                    if let lastUserGoal = activeSession.lastUserGoal, !lastUserGoal.isEmpty {
                        infoCard(
                            title: "最近目标",
                            content: lastUserGoal,
                            tint: Color.orange.opacity(0.12)
                        )
                    }

                    if let pendingAction = activeSession.pendingAction {
                        infoCard(
                            title: "待确认操作",
                            content: pendingAction.confirmationMessage,
                            tint: Color.yellow.opacity(0.16)
                        )
                    }

                    if !latestAssistantNote.isEmpty {
                        infoCard(
                            title: "AI 反馈",
                            content: latestAssistantNote,
                            tint: Color.indigo.opacity(0.10)
                        )
                    }

                    HStack(spacing: 8) {
                        TextField("例如：看看当前页面 / 输入账号 foo@example.com / 点击登录", text: $browserInstruction)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { sendBrowserInstruction() }

                        Button {
                            sendBrowserInstruction()
                        } label: {
                            Label("发送", systemImage: "arrow.up.circle.fill")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(browserInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(14)
                .background(Color.secondary.opacity(0.06) as Color)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke((Color.secondary.opacity(0.14) as Color), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("当前没有活动网页会话。")
                        .font(.system(size: 13, weight: .medium))
                    Text("你可以在这里打开网址，或者直接在对话里输入“打开 https://example.com”。打开后，主对话就能继续识别页面并确认下一步。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }
    
    private var quickNavigationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("快速导航")
                .font(.system(size: 13, weight: .semibold))
            
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], spacing: 8) {
                QuickNavButton(title: "WhatsApp", icon: "message.circle.fill", color: .green) {
                    startSession(url: "https://web.whatsapp.com", originalInput: "打开 WhatsApp")
                }
                
                QuickNavButton(title: "Google", icon: "magnifyingglass.circle.fill", color: .blue) {
                    startSession(url: "https://www.google.com", originalInput: "打开 Google")
                }
                
                QuickNavButton(title: "GitHub", icon: "terminal.fill", color: .purple) {
                    startSession(url: "https://github.com", originalInput: "打开 GitHub")
                }
                
                QuickNavButton(title: "Gmail", icon: "envelope.fill", color: .red) {
                    startSession(url: "https://mail.google.com", originalInput: "打开 Gmail")
                }
            }
        }
    }
    
    private var whatsAppSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("WhatsApp 自动化")
                    .font(.system(size: 13, weight: .semibold))
                
                Spacer()
                
                Button {
                    startSession(url: "https://web.whatsapp.com", originalInput: "打开 WhatsApp")
                } label: {
                    Label("打开 WhatsApp", systemImage: "arrow.up.right.square")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            
            if showingWhatsAppPanel {
                VStack(spacing: 12) {
                    // 发送消息
                    VStack(alignment: .leading, spacing: 8) {
                        Text("发送消息")
                            .font(.system(size: 12, weight: .medium))
                        
                        HStack(spacing: 8) {
                            TextField("联系人", text: $messageContact)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 120)
                            
                            TextField("消息内容", text: $messageContent)
                                .textFieldStyle(.roundedBorder)
                            
                            Button {
                                Task {
                                    let result = await agent.executeWhatsAppTask(
                                        .sendMessage(contact: messageContact, message: messageContent)
                                    )
                                    handleTaskResult(result)
                                }
                            } label: {
                                Image(systemName: "paperplane.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(messageContact.isEmpty || messageContent.isEmpty)
                        }
                    }
                    
                    // 快捷操作
                    HStack(spacing: 8) {
                        Button {
                            Task {
                                let result = await agent.executeWhatsAppTask(.getUnreadMessages)
                                handleTaskResult(result)
                            }
                        } label: {
                            Label("获取未读", systemImage: "bell.badge")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        
                        Spacer()
                    }
                }
                .padding(12)
                .background(Color.green.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.green.opacity(0.2), lineWidth: 1)
                )
                .cornerRadius(8)
            }
        }
    }
    
    private var actionLogSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("操作日志")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(agent.recentActions.count) 条记录")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            
            List(agent.recentActions) { action in
                HStack(spacing: 8) {
                    Image(systemName: statusIcon(for: action.status))
                        .font(.system(size: 10))
                        .foregroundColor(statusColor(for: action.status))
                    
                    Text(action.type.rawValue)
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 50, alignment: .leading)
                    
                    Text(action.description)
                        .font(.system(size: 11))
                        .lineLimit(1)
                    
                    Spacer()
                    
                    Text(timeString(from: action.timestamp))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.plain)
            .frame(height: 150)
        }
    }
    
    private var notRunningView: some View {
        VStack(spacing: 16) {
            Image(systemName: "globe")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            
            Text("浏览器代理服务未启动")
                .font(.system(size: 16, weight: .semibold))
            
            Text("启动服务后，AI 将能够控制 Safari 或 Chrome 浏览器执行网页操作")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            
            Button { agent.start() } label: {
                Label("启动服务", systemImage: "power")
            }
            .buttonStyle(.borderedProminent)
            
            if !permissionStatus.authorized {
                Divider()
                    .padding(.vertical, 8)
                
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("需要系统权限")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.orange)
                }
                
                Button {
                    openPermissionSettings()
                } label: {
                    Label("前往授权", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - 权限相关
    
    private var permissionWarningBanner: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundColor(.orange)
                    .font(.system(size: 24))
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("需要手动授权 Safari 权限")
                        .font(.system(size: 14, weight: .semibold))
                    Text("macOS 15 需要您在系统设置中手动添加权限")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Button {
                    checkPermission()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14))
                }
                .buttonStyle(.borderless)
                .help("重新检查权限")
            }
            
            Divider()
            
            // 手动授权指引
            VStack(alignment: .leading, spacing: 10) {
                Text("请按以下步骤操作：")
                    .font(.system(size: 12, weight: .semibold))
                
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 8) {
                        Text("1")
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: 20, height: 20)
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .clipShape(Circle())
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("打开「系统设置」→「隐私与安全性」→「自动化」")
                                .font(.system(size: 12))
                            Text("如果列表中没有 MacAssistant，请点击 + 号手动添加")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    HStack(alignment: .top, spacing: 8) {
                        Text("2")
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: 20, height: 20)
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .clipShape(Circle())
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("找到 MacAssistant，展开后开启 Safari 开关")
                                .font(.system(size: 12))
                        }
                    }
                    
                    HStack(alignment: .top, spacing: 8) {
                        Text("3")
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: 20, height: 20)
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .clipShape(Circle())
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("返回本应用，关闭浏览器视图后重新打开")
                                .font(.system(size: 12))
                        }
                    }
                }
                
                Button {
                    openPermissionSettings()
                } label: {
                    HStack {
                        Image(systemName: "arrow.up.forward.app")
                        Text("打开系统设置")
                            .font(.system(size: 12, weight: .medium))
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(Color.orange.opacity(0.08))
        .overlay(
            Rectangle()
                .fill(Color.orange.opacity(0.3))
                .frame(height: 1),
            alignment: .bottom
        )
    }
    
    private var restartRequiredBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.clockwise.circle.fill")
                .foregroundColor(.blue)
                .font(.system(size: 16))
            
            VStack(alignment: .leading, spacing: 2) {
                Text("权限已变更，需要重启应用")
                    .font(.system(size: 12, weight: .semibold))
                Text("您已授权 MacAssistant 控制 Safari，请重启应用使权限生效")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            Button {
                restartApp()
            } label: {
                Text("立即重启")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.blue.opacity(0.1))
        .overlay(
            Rectangle()
                .fill(Color.blue.opacity(0.3))
                .frame(height: 1),
            alignment: .bottom
        )
    }
    
    private func checkPermission() {
        LogInfo("[BrowserView] 开始检查权限...")
        isCheckingPermission = true
        Task {
            LogInfo("[BrowserView] 调用 agent.checkAppleScriptAuthorization()...")
            let result = await agent.checkAppleScriptAuthorization()
            LogInfo("[BrowserView] 权限检查结果: authorized=\(result.authorized), error=\(result.error ?? "nil"), needsRestart=\(result.needsRestart)")
            await MainActor.run {
                permissionStatus = result
                isCheckingPermission = false
                LogInfo("[BrowserView] 权限状态已更新")
            }
        }
    }
    
    private func openPermissionSettings() {
        // 打开系统设置的隐私与安全性-自动化页面
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
        NSWorkspace.shared.open(url)
    }
    
    private func restartApp() {
        // 重启应用
        let url = URL(fileURLWithPath: Bundle.main.bundlePath)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if error == nil {
                // 退出当前实例
                NSApplication.shared.terminate(nil)
            }
        }
    }
    
    // MARK: - 辅助方法
    
    private func navigateToURL() {
        guard !urlInput.isEmpty else { return }
        var url = urlInput
        if !url.hasPrefix("http") { url = "https://" + url }
        startSession(url: url, originalInput: "打开 \(url)")
        urlInput = ""
    }

    private func startSession(url: String, originalInput: String) {
        Task { @MainActor in
            // 先检查权限
            let authCheck = await agent.checkAppleScriptAuthorization()
            
            // 检查是否需要重启
            if authCheck.needsRestart {
                latestAssistantNote = """
                ✅ 权限已授予，但需要重启应用
                
                您已成功授权 MacAssistant 控制 Safari，但需要重启应用才能生效。
                
                请点击上方的「需重启」按钮，或关闭后重新打开应用。
                """
                // 更新权限状态显示
                permissionStatus = authCheck
                return
            }
            
            // 如果权限不足，仍然尝试执行（这会触发系统授权对话框）
            // 但先显示提示信息
            if !authCheck.authorized {
                latestAssistantNote = """
                ⏳ 正在请求权限...
                
                系统应该已弹出授权对话框，请点击「允许」以授权 MacAssistant 控制 Safari。
                
                如果没有看到对话框，请检查屏幕右上角是否有被隐藏的弹窗。
                """
            }
            
            // 无论权限状态如何，都尝试执行（首次会触发系统弹窗）
            let messages = await BrowserSessionCoordinator.shared.startSession(
                url: url,
                originalInput: originalInput
            )
            latestAssistantNote = messages.last?.content ?? ""
            
            // 执行后重新检查权限状态
            await checkPermission()
            
            if url.contains("whatsapp") {
                showingWhatsAppPanel = true
            }
        }
    }

    private func refreshCurrentPage() {
        guard let activeSession = sessionStore.activeSession else { return }
        Task { @MainActor in
            let messages = await BrowserSessionCoordinator.shared.continueSession(
                sessionID: activeSession.id,
                userInput: "看看当前页面"
            )
            latestAssistantNote = messages.last?.content ?? ""
        }
    }

    private func captureBrowserScreenshot() {
        Task { @MainActor in
            guard let activeSession = sessionStore.activeSession else {
                latestAssistantNote = "当前没有活动网页会话，无法更新网页截图。"
                return
            }

            guard let screenshotPath = await agent.captureScreenshotFilePath() else {
                latestAssistantNote = "浏览器截图失败，请确认浏览器窗口在前台且已授予屏幕录制权限。"
                return
            }

            sessionStore.setScreenshotPath(screenshotPath, for: activeSession.id)
            latestAssistantNote = "浏览器截图已保存到：\(screenshotPath)"
        }
    }

    private func cancelPendingBrowserFlow(_ sessionID: String) {
        let label = BrowserSessionCoordinator.shared.cancelPendingFlow(sessionID: sessionID)
        latestAssistantNote = label == nil ? "当前网页会话没有挂起操作。" : "已取消\(label ?? "网页挂起流程")。"
    }

    private func sendBrowserInstruction() {
        let input = browserInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, let activeSession = sessionStore.activeSession else { return }
        Task { @MainActor in
            let messages = await BrowserSessionCoordinator.shared.continueSession(
                sessionID: activeSession.id,
                userInput: input
            )
            latestAssistantNote = messages.last?.content ?? ""
            browserInstruction = ""
        }
    }
    
    private func handleTaskResult(_ result: TaskResult) {
        // 处理任务结果
        switch result {
        case .success(let message):
            latestAssistantNote = message
        case .failed(let error):
            latestAssistantNote = error
        }
    }
    
    private func showHelp() {
        // 显示帮助信息
        let alert = NSAlert()
        alert.messageText = "浏览器代理使用说明"
        alert.informativeText = """
        1. 首次使用需要授权：
           - 系统设置 → 隐私与安全性 → 自动化
           - 确保 MacAssistant 的 Safari 开关已开启
        
        2. 启动服务后，系统会自动检测您的默认浏览器（Safari 或 Chrome）
        
        3. 使用快速导航按钮或输入网址来打开网页
        
        4. 对于 WhatsApp 自动化：
           - 点击"打开 WhatsApp"打开网页版
           - 在浏览器中完成扫码登录
           - 然后可以使用发送消息功能
        
        5. 所有操作都会记录在日志中
        
        注意：如果提示权限不足，请点击"前往授权"按钮
        """
        alert.alertStyle = .informational
        alert.runModal()
    }
    
    private var browserIcon: String {
        agent.browserName.contains("Chrome") ? "chrome" : "safari"
    }

    private func statusChip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.12))
            .foregroundColor(color)
            .clipShape(Capsule())
    }

    private func infoCard(title: String, content: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
            Text(content)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func statusColor(for status: BrowserSessionStatus) -> Color {
        switch status {
        case .idle, .completed:
            return .green
        case .navigating, .executing:
            return .blue
        case .waitingUser, .blockedByAuth:
            return .orange
        case .failed:
            return .red
        }
    }

    private func authColor(for authState: BrowserAuthState) -> Color {
        switch authState {
        case .ready:
            return .green
        case .needsLogin, .needsScan:
            return .orange
        case .unknown:
            return .secondary
        }
    }
    
    private func statusIcon(for status: SimpleBrowserAgent.BrowserAction.ActionStatus) -> String {
        switch status {
        case .success: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .pending: return "hourglass"
        }
    }
    
    private func statusColor(for status: SimpleBrowserAgent.BrowserAction.ActionStatus) -> Color {
        switch status {
        case .success: return .green
        case .failed: return .red
        case .pending: return .orange
        }
    }
    
    private func timeString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}

private struct FlowTagList: View {
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("页面可操作元素")
                .font(.system(size: 11, weight: .semibold))

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 6)], spacing: 6) {
                ForEach(items, id: \.self) { item in
                    Text(item)
                        .font(.system(size: 10))
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
        }
    }
}

private extension BrowserSession {
    var statusLabel: String {
        switch status {
        case .idle:
            return "空闲"
        case .navigating:
            return "打开中"
        case .waitingUser:
            return "等待指令"
        case .executing:
            return "执行中"
        case .blockedByAuth:
            return "等待登录"
        case .completed:
            return "已完成"
        case .failed:
            return "失败"
        }
    }
}

private extension BrowserPageKind {
    var displayName: String {
        switch self {
        case .login:
            return "登录页"
        case .dashboard:
            return "控制台"
        case .search:
            return "搜索页"
        case .form:
            return "表单页"
        case .article:
            return "内容页"
        case .list:
            return "列表页"
        case .checkout:
            return "结算页"
        case .chat:
            return "聊天页"
        case .unknown:
            return "未识别"
        }
    }
}

private extension BrowserAuthState {
    var displayName: String {
        switch self {
        case .unknown:
            return "状态未知"
        case .needsLogin:
            return "需要登录"
        case .needsScan:
            return "需要扫码"
        case .ready:
            return "可继续操作"
        }
    }
}

// MARK: - 辅助组件

struct QuickNavButton: View {
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundColor(color)
                Text(title)
                    .font(.system(size: 11))
                    .foregroundColor(.primary)
            }
            .frame(width: 80, height: 60)
            .background(color.opacity(0.1))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(color.opacity(0.3), lineWidth: 1)
            )
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }
}

// BrowserAction 已经在 SimpleBrowserAgent 中实现了 Identifiable 协议

struct SimpleBrowserAgentView_Previews: PreviewProvider {
    static var previews: some View {
        SimpleBrowserAgentView()
            .frame(width: 600, height: 500)
    }
}
