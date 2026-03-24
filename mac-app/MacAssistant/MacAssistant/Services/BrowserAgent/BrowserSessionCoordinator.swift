//
//  BrowserSessionCoordinator.swift
//  MacAssistant
//

import Foundation

@MainActor
final class BrowserSessionCoordinator {
    static let shared = BrowserSessionCoordinator()

    private let store = BrowserSessionStore.shared
    private let browser = SimpleBrowserAgent.shared

    private init() {}

    func startSession(url: String, originalInput: String) async -> [ChatMessage] {
        LogInfo("开始浏览器会话 - URL: \(url), 原始输入: \(originalInput)")
        browser.start()
        let session = store.createSession(currentURL: url)
        LogDebug("创建会话成功 - ID: \(session.id)")
        store.setStatus(.navigating, for: session.id)
        store.setLastUserGoal(originalInput, for: session.id)

        LogInfo("开始导航到: \(url)")
        let navigateResult = await browser.navigateWithResult(to: url)
        guard navigateResult.success else {
            LogError("导航失败: \(url), 错误: \(navigateResult.errorMessage ?? "未知错误")")
            store.setStatus(.failed, for: session.id)
            store.appendAction(summary: "打开页面失败", succeeded: false, for: session.id)
            
            // 构建友好的错误提示
            var errorContent = "我尝试打开网页失败了。"
            if let errorMessage = navigateResult.errorMessage {
                if errorMessage.contains("自动化") || errorMessage.contains("授权") {
                    errorContent = """
                    我尝试打开网页失败了。
                    
                    ⚠️ \(errorMessage)
                    
                    请按以下步骤授权：
                    1. 打开「系统设置」→「隐私与安全性」→「自动化」
                    2. 找到 MacAssistant，确保 Safari 开关为开启状态
                    3. 重新尝试打开网页
                    """
                } else {
                    errorContent = "我尝试打开网页失败了：\(errorMessage)"
                }
            }
            
            return [assistantMessage(errorContent)]
        }
        LogInfo("导航成功: \(url)")

        LogInfo("开始抓取页面快照...")
        let snapshot = await browser.captureSnapshot()
        if let snapshot {
            LogInfo("快照抓取成功 - 标题: \(snapshot.title), URL: \(snapshot.url), pageKind: \(snapshot.pageKind)")
            store.setSnapshot(snapshot, for: session.id)
            let newStatus: BrowserSessionStatus = (snapshot.authState == .needsLogin || snapshot.authState == .needsScan) ? .blockedByAuth : .waitingUser
            store.setStatus(newStatus, for: session.id)
            store.appendAction(summary: "打开 \(snapshot.url)", succeeded: true, for: session.id)
            LogInfo("会话状态更新为: \(newStatus)")
            return [makeFollowUpMessage(for: session.id, snapshot: snapshot, prefix: "我已经打开当前网页。")]
        }

        LogWarning("快照抓取失败，但导航已成功")
        store.setStatus(.waitingUser, for: session.id)
        store.appendAction(summary: "打开 \(url)", succeeded: true, for: session.id)
        return [
            assistantMessage(
                """
                我已经打开网页，但暂时还没拿到页面摘要。
                你可以直接告诉我要继续做什么，例如“看看当前页面”或“继续登录”。
                """,
                images: messageImages(for: session.latestSnapshot),
                metadata: [
                    BrowserConversationMetadataKeys.pendingSessionID: session.id,
                    BrowserConversationMetadataKeys.pageURL: url,
                    BrowserConversationMetadataKeys.promptKind: "next_step"
                ]
            )
        ]
    }

    func continueSession(sessionID: String, userInput: String) async -> [ChatMessage] {
        LogInfo("继续浏览器会话 - ID: \(sessionID), 用户输入: \(userInput)")
        guard let session = store.session(id: sessionID) else {
            LogWarning("尝试继续不存在的会话: \(sessionID)")
            return [
                assistantMessage("当前没有可继续的网页会话。你可以先告诉我要打开哪个网页。")
            ]
        }
        LogDebug("找到会话 - 当前状态: \(session.status), URL: \(session.currentURL)")

        store.activateSession(sessionID)
        store.setLastUserGoal(userInput, for: sessionID)

        let normalized = RequestPlanningHeuristics.normalized(userInput)
        if let pendingAction = session.pendingAction {
            if RequestPlanningHeuristics.acceptanceDecision(from: normalized) == true ||
                RequestPlanningHeuristics.shouldTreatAsResumeCommand(normalized) ||
                normalized == "继续" {
                return await executePendingAction(pendingAction, sessionID: sessionID)
            }

            if RequestPlanningHeuristics.acceptanceDecision(from: normalized) == false {
                store.clearPendingState(for: sessionID)
                return [
                    assistantMessage(
                        "已取消这次网页操作确认。你可以告诉我要改做什么。",
                        images: messageImages(for: session.latestSnapshot),
                        metadata: nextStepMetadata(for: sessionID, snapshot: session.latestSnapshot)
                    )
                ]
            }
        }

        if shouldDescribeCurrentPage(userInput) || normalized == "继续" || session.status == .blockedByAuth {
            return await refreshAndDescribe(sessionID: sessionID, prefix: "我刷新了一下当前页面状态。")
        }

        if let whatsAppMessages = await handleWhatsAppIntent(userInput, session: session) {
            return whatsAppMessages
        }

        if let missingValuePrompt = missingValuePrompt(for: userInput) {
            store.setStatus(.waitingUser, for: sessionID)
            return [
                assistantMessage(
                    missingValuePrompt,
                    images: messageImages(for: session.latestSnapshot),
                    metadata: nextStepMetadata(for: sessionID, snapshot: session.latestSnapshot)
                )
            ]
        }

        if let pendingAction = plannedPendingAction(for: userInput) {
            store.setPendingAction(pendingAction, for: sessionID)
            store.setStatus(.waitingUser, for: sessionID)
            return [
                assistantMessage(
                    pendingAction.confirmationMessage,
                    images: messageImages(for: session.latestSnapshot),
                    metadata: confirmationMetadata(for: sessionID, snapshot: session.latestSnapshot)
                )
            ]
        }

        let snapshot: BrowserPageSnapshot?
        if let existingSnapshot = session.latestSnapshot {
            snapshot = existingSnapshot
        } else {
            snapshot = await browser.captureSnapshot()
        }
        if let snapshot {
            store.setSnapshot(snapshot, for: sessionID)
        }

        return [
            assistantMessage(
                """
                我已经接管当前网页，但这一步还不够具体。
                你可以直接说“看看当前页面”、“输入账号 xxx@example.com”或“点击登录”。
                """,
                images: messageImages(for: snapshot),
                metadata: nextStepMetadata(for: sessionID, snapshot: snapshot)
            )
        ]
    }

    @discardableResult
    func cancelPendingFlow(sessionID: String?) -> String? {
        LogInfo("取消浏览器挂起流程 - sessionID: \(sessionID ?? "nil")")
        guard let sessionID else { return nil }
        guard let session = store.session(id: sessionID) else {
            LogWarning("尝试取消不存在的会话: \(sessionID)")
            return nil
        }

        store.clearPendingState(for: sessionID)
        if session.status == .blockedByAuth {
            store.setStatus(.idle, for: sessionID)
            return "网页等待状态"
        }
        if session.pendingAction != nil {
            return "网页操作确认"
        }
        return nil
    }

    private func refreshAndDescribe(sessionID: String, prefix: String) async -> [ChatMessage] {
        LogInfo("刷新并描述页面 - sessionID: \(sessionID)")
        if let snapshot = await browser.captureSnapshot() {
            LogInfo("刷新快照成功 - 标题: \(snapshot.title)")
            store.setSnapshot(snapshot, for: sessionID)
            let newStatus: BrowserSessionStatus = (snapshot.authState == .needsLogin || snapshot.authState == .needsScan) ? .blockedByAuth : .waitingUser
            store.setStatus(newStatus, for: sessionID)
            return [makeFollowUpMessage(for: sessionID, snapshot: snapshot, prefix: prefix)]
        }

        LogWarning("刷新快照失败")
        store.setStatus(.waitingUser, for: sessionID)
        return [
            assistantMessage(
                "我没能成功读取当前页面内容。你可以确认浏览器页面仍在前台，然后让我再试一次。",
                images: messageImages(for: store.session(id: sessionID)?.latestSnapshot),
                metadata: nextStepMetadata(for: sessionID, snapshot: store.session(id: sessionID)?.latestSnapshot)
            )
        ]
    }

    private func executePendingAction(_ action: BrowserPendingAction, sessionID: String) async -> [ChatMessage] {
        LogInfo("执行挂起动作 - type: \(action.actionType), sessionID: \(sessionID)")
        store.setStatus(.executing, for: sessionID)

        let succeeded: Bool
        switch action.actionType {
        case "fill":
            LogDebug("执行 fill 动作")
            succeeded = await executeFillAction(action)
        case "click":
            LogDebug("执行 click 动作")
            succeeded = await executeClickAction(action)
        default:
            LogWarning("未知的动作类型: \(action.actionType)")
            succeeded = false
        }
        LogInfo("挂起动作执行结果: \(succeeded ? "成功" : "失败")")

        store.appendAction(summary: action.summary, succeeded: succeeded, for: sessionID)
        store.setPendingAction(nil, for: sessionID)

        if succeeded {
            LogInfo("动作执行成功，刷新页面描述")
            return await refreshAndDescribe(
                sessionID: sessionID,
                prefix: "这一步已经执行完成。"
            )
        }

        LogError("动作执行失败，设置会话状态为 failed")
        store.setStatus(.failed, for: sessionID)
        return [
            assistantMessage(
                """
                我没能完成这一步网页操作。
                你可以让我先重新看看当前页面，或者告诉我更具体的目标。
                """,
                images: messageImages(for: store.session(id: sessionID)?.latestSnapshot),
                metadata: nextStepMetadata(for: sessionID, snapshot: store.session(id: sessionID)?.latestSnapshot)
            )
        ]
    }

    private func executeFillAction(_ action: BrowserPendingAction) async -> Bool {
        LogDebug("执行 fill 动作 - selector: \(action.selector ?? "nil"), value: \(action.value ?? "nil")")
        guard let selector = action.selector, let value = action.value else {
            LogError("fill 动作缺少 selector 或 value")
            return false
        }

        let selectorLiteral = jsStringLiteral(selector)
        let valueLiteral = jsStringLiteral(value)
        let script = """
        (() => { const el = document.querySelector(\(selectorLiteral)); if (!el) return "NOT_FOUND"; el.focus(); if ("value" in el) { el.value = \(valueLiteral); el.dispatchEvent(new Event("input", { bubbles: true })); el.dispatchEvent(new Event("change", { bubbles: true })); return "FILLED"; } if (el.isContentEditable) { el.textContent = \(valueLiteral); el.dispatchEvent(new Event("input", { bubbles: true })); return "FILLED"; } return "UNSUPPORTED"; })()
        """

        let result = await browser.executeJavaScript(script)
        let success = result?.contains("FILLED") == true
        LogDebug("fill 动作结果: \(success), 返回值: \(result ?? "nil")")
        return success
    }

    private func executeClickAction(_ action: BrowserPendingAction) async -> Bool {
        LogDebug("执行 click 动作 - buttonText: \(action.buttonText ?? "nil")")
        guard let buttonText = action.buttonText else {
            LogError("click 动作缺少 buttonText")
            return false
        }

        let alternatives = buttonText
            .split(separator: "|")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        let alternativesLiteral = jsArrayLiteral(alternatives)
        let script = """
        (() => { const wantedTexts = \(alternativesLiteral); const candidates = Array.from(document.querySelectorAll("button, a, input[type='submit'], input[type='button'], [role='button']")); const hit = candidates.find((el) => { const text = (el.innerText || el.value || el.getAttribute("aria-label") || "").trim().toLowerCase(); return wantedTexts.some((wanted) => text === wanted || (wanted.length > 1 && text.includes(wanted))); }); if (!hit) return "NOT_FOUND"; hit.click(); return "CLICKED"; })()
        """

        let result = await browser.executeJavaScript(script)
        let success = result?.contains("CLICKED") == true
        LogDebug("click 动作结果: \(success), 返回值: \(result ?? "nil")")
        return success
    }

    private func handleWhatsAppIntent(
        _ input: String,
        session: BrowserSession
    ) async -> [ChatMessage]? {
        LogDebug("检查 WhatsApp 意图 - 输入: \(input)")
        guard isWhatsAppSession(session) else {
            LogDebug("非 WhatsApp 会话，跳过")
            return nil
        }
        LogInfo("检测到 WhatsApp 会话，处理意图")

        let normalized = RequestPlanningHeuristics.normalized(input)
        let snapshot = session.latestSnapshot

        if let sendRequest = extractWhatsAppSendRequest(from: input) {
            LogInfo("提取到 WhatsApp 发送消息请求 - 联系人: \(sendRequest.contact), 消息长度: \(sendRequest.message.count)")
            let result = await browser.executeWhatsAppTask(
                .sendMessage(contact: sendRequest.contact, message: sendRequest.message)
            )
            LogInfo("WhatsApp 发送消息任务结果: \(result)")
            return [assistantMessage(
                formatWhatsAppTaskResult(
                    result,
                    successPrefix: "我已经尝试通过 WhatsApp 发送消息。",
                    failurePrefix: "我尝试通过 WhatsApp 发送消息失败了。"
                ),
                images: messageImages(for: snapshot),
                metadata: nextStepMetadata(for: session.id, snapshot: snapshot)
            )]
        }

        if let contact = extractWhatsAppSearchContact(from: input) {
            LogInfo("提取到 WhatsApp 搜索联系人请求 - 联系人: \(contact)")
            let result = await browser.executeWhatsAppTask(.searchContact(name: contact))
            LogInfo("WhatsApp 搜索联系人任务结果: \(result)")
            return [assistantMessage(
                formatWhatsAppTaskResult(
                    result,
                    successPrefix: "我已经在 WhatsApp 里搜索联系人了。",
                    failurePrefix: "我在 WhatsApp 里搜索联系人失败了。"
                ),
                images: messageImages(for: snapshot),
                metadata: nextStepMetadata(for: session.id, snapshot: snapshot)
            )]
        }

        let unreadMarkers = ["未读消息", "获取未读", "读取未读", "查看未读", "看看未读", "拉取未读"]
        if unreadMarkers.contains(where: { normalized.contains($0) }) {
            LogInfo("处理 WhatsApp 未读消息请求")
            let result = await browser.executeWhatsAppTask(.getUnreadMessages)
            let content: String
            switch result {
            case .success(let message):
                let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    content = "我已经检查过 WhatsApp，目前没有识别到未读消息。"
                } else {
                    content = """
                    我已经读取了 WhatsApp 未读概览：
                    \(trimmed)

                    如果你要继续，我可以搜索某个联系人，或者按“发送消息给 张三 你好”的格式帮你发送。
                    """
                }
            case .failed(let error):
                content = "我尝试读取 WhatsApp 未读消息失败了：\(error)"
            }

            return [assistantMessage(
                content,
                images: messageImages(for: snapshot),
                metadata: nextStepMetadata(for: session.id, snapshot: snapshot)
            )]
        }

        let handoffMarkers = ["接管", "托管", "扮演", "现在接受", "自动回复", "代聊", "客服"]
        if handoffMarkers.contains(where: { normalized.contains($0) }) {
            store.setLastUserGoal(input, for: session.id)
            return [assistantMessage(
                """
                我已经记住这条 WhatsApp 托管目标了。

                当前版本还不会自动后台轮询并自主回复，但可以继续帮你操作当前 WhatsApp 页面。你现在可以直接说：
                • 读取未读消息
                • 搜索联系人 张三
                • 发送消息给 张三 你好
                """,
                images: messageImages(for: snapshot),
                metadata: nextStepMetadata(for: session.id, snapshot: snapshot)
            )]
        }

        return nil
    }

    private func shouldDescribeCurrentPage(_ input: String) -> Bool {
        let normalized = RequestPlanningHeuristics.normalized(input)
        let keywords = [
            "看看当前页面", "看看这个页面", "看看页面", "当前页面", "这个页面",
            "识别一下页面", "识别页面", "页面上有什么", "浏览器里现在是什么",
            "网页上现在是什么", "帮我看看"
        ]
        return keywords.contains(where: { normalized.contains($0) })
    }

    private func missingValuePrompt(for input: String) -> String? {
        let normalized = RequestPlanningHeuristics.normalized(input)
        if normalized.contains("账号") || normalized.contains("用户名") || normalized.contains("邮箱") {
            if extractAccountValue(from: input) == nil {
                return "你要我填写账号的话，请直接把账号值也告诉我，例如“输入账号 foo@example.com”。我不会自动提交。"
            }
        }
        return nil
    }

    private func plannedPendingAction(for input: String) -> BrowserPendingAction? {
        let normalized = RequestPlanningHeuristics.normalized(input)

        if normalized.contains("账号") || normalized.contains("用户名") || normalized.contains("邮箱") {
            if let value = extractAccountValue(from: input) {
                return BrowserPendingAction(
                    actionType: "fill",
                    selector: "input[type='email'], input[name='login'], input[name='username'], input[type='text']",
                    value: value,
                    buttonText: nil,
                    summary: "填写账号",
                    confirmationMessage: "我准备在账号输入框填写 `\(value)`，填写后不会自动提交。请回复“继续”确认。"
                )
            }
        }

        if normalized.contains("点击登录") || normalized == "登录" || normalized.contains("登录按钮") {
            return BrowserPendingAction(
                actionType: "click",
                selector: nil,
                value: nil,
                buttonText: "登录|sign in|log in",
                summary: "点击登录",
                confirmationMessage: "我准备点击“登录”按钮。这可能会提交当前表单。请回复“继续”确认。"
            )
        }

        if normalized.contains("提交") {
            return BrowserPendingAction(
                actionType: "click",
                selector: nil,
                value: nil,
                buttonText: "提交",
                summary: "点击提交",
                confirmationMessage: "我准备点击“提交”按钮。这可能会提交当前内容。请回复“继续”确认。"
            )
        }

        return nil
    }

    private func extractAccountValue(from input: String) -> String? {
        let patterns = [
            #"(?:(?:账号|用户名|邮箱)\s*[:：]?\s*)([^\s]+)"#,
            #"(?:输入|填写)\s*([^\s]+)\s*(?:到|进).*(?:账号|用户名|邮箱)"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(
                    in: input,
                    options: [],
                    range: NSRange(location: 0, length: input.utf16.count)
                  ),
                  let valueRange = Range(match.range(at: 1), in: input) else {
                continue
            }

            let value = String(input[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                return value
            }
        }

        return nil
    }

    private func isWhatsAppSession(_ session: BrowserSession) -> Bool {
        guard let snapshot = session.latestSnapshot else { return false }
        let combined = "\(snapshot.title) \(snapshot.url) \(snapshot.textExcerpt)".lowercased()
        return combined.contains("whatsapp")
    }

    private func extractWhatsAppSendRequest(from input: String) -> (contact: String, message: String)? {
        let patterns = [
            #"(?:(?:发送消息给|发消息给|发送给|回复给|回复)\s*)([^\s，,：:]+)\s+(.+)"#,
            #"(?:(?:给)\s*)([^\s，,：:]+)\s*(?:发送消息|回复)\s+(.+)"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(
                    in: input,
                    options: [],
                    range: NSRange(location: 0, length: input.utf16.count)
                  ),
                  let contactRange = Range(match.range(at: 1), in: input),
                  let messageRange = Range(match.range(at: 2), in: input) else {
                continue
            }

            let contact = String(input[contactRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            let message = String(input[messageRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !contact.isEmpty && !message.isEmpty {
                return (contact, message)
            }
        }

        return nil
    }

    private func extractWhatsAppSearchContact(from input: String) -> String? {
        let patterns = [
            #"(?:(?:搜索联系人|查找联系人|找联系人)\s*)([^\s，,：:]+)"#,
            #"(?:(?:搜索|查找)\s*)([^\s，,：:]+)"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(
                    in: input,
                    options: [],
                    range: NSRange(location: 0, length: input.utf16.count)
                  ),
                  let contactRange = Range(match.range(at: 1), in: input) else {
                continue
            }

            let contact = String(input[contactRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !contact.isEmpty {
                return contact
            }
        }

        return nil
    }

    private func formatWhatsAppTaskResult(
        _ result: TaskResult,
        successPrefix: String,
        failurePrefix: String
    ) -> String {
        switch result {
        case .success(let message):
            return "\(successPrefix)\n\(message)"
        case .failed(let error):
            return "\(failurePrefix)\n\(error)"
        }
    }

    private func makeFollowUpMessage(
        for sessionID: String,
        snapshot: BrowserPageSnapshot,
        prefix: String
    ) -> ChatMessage {
        let analysis = BrowserPageAnalyzer.analyze(snapshot)
        let suggestions = analysis.nextSuggestions.map { "• \($0)" }.joined(separator: "\n")
        let snippet = snapshot.textExcerpt
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(180)

        let content = """
        \(prefix)

        \(analysis.summary)
        标题：\(snapshot.title.isEmpty ? "未识别标题" : snapshot.title)
        地址：\(snapshot.url)

        页面摘要：\(snippet.isEmpty ? "暂未抓到可读正文。" : String(snippet))

        你现在可以：
        \(suggestions.isEmpty ? "• 直接告诉我要继续做什么" : suggestions)
        """

        return assistantMessage(
            content,
            images: messageImages(for: snapshot),
            metadata: nextStepMetadata(for: sessionID, snapshot: snapshot)
        )
    }

    private func nextStepMetadata(
        for sessionID: String,
        snapshot: BrowserPageSnapshot?
    ) -> [String: String] {
        var metadata: [String: String] = [
            BrowserConversationMetadataKeys.pendingSessionID: sessionID,
            BrowserConversationMetadataKeys.promptKind: "next_step"
        ]
        if let snapshot {
            metadata[BrowserConversationMetadataKeys.pageKind] = snapshot.pageKind.rawValue
            metadata[BrowserConversationMetadataKeys.pageURL] = snapshot.url
        }
        return metadata
    }

    private func confirmationMetadata(
        for sessionID: String,
        snapshot: BrowserPageSnapshot?
    ) -> [String: String] {
        var metadata = nextStepMetadata(for: sessionID, snapshot: snapshot)
        metadata[BrowserConversationMetadataKeys.promptKind] = "confirmation"
        metadata[BrowserConversationMetadataKeys.requiresConfirmation] = "true"
        return metadata
    }

    private func assistantMessage(
        _ content: String,
        images: [String]? = nil,
        metadata: [String: String]? = nil
    ) -> ChatMessage {
        ChatMessage(
            id: UUID(),
            role: .assistant,
            content: content,
            timestamp: Date(),
            images: images,
            metadata: metadata
        )
    }

    private func messageImages(for snapshot: BrowserPageSnapshot?) -> [String]? {
        guard let screenshotPath = snapshot?.screenshotPath,
              FileManager.default.fileExists(atPath: screenshotPath) else {
            return nil
        }
        return [screenshotPath]
    }

    private func jsStringLiteral(_ string: String) -> String {
        let escaped = string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "")
        return "\"\(escaped)\""
    }

    private func jsArrayLiteral(_ values: [String]) -> String {
        "[\(values.map(jsStringLiteral).joined(separator: ", "))]"
    }
}
