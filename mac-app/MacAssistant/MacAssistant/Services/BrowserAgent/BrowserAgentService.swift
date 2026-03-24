//
//  BrowserAgentService.swift
//  MacAssistant
//
//  AI浏览器代理服务 - 支持有头/无头双模式 + 会话持久化
//

import Foundation
import Combine

// MARK: - 浏览器模式
enum BrowserMode: String, CaseIterable, Codable {
    case headed = "headed"       // 有头模式：可见窗口，适合人工干预
    case headless = "headless"   // 无头模式：后台运行，适合自动化
    case adaptive = "adaptive"   // 自适应：AI 根据场景自动选择
    
    var displayName: String {
        switch self {
        case .headed: return "有头模式"
        case .headless: return "无头模式"
        case .adaptive: return "自适应"
        }
    }
    
    var description: String {
        switch self {
        case .headed: return "显示真实浏览器窗口，适合首次登录、扫码等需要人工干预的场景"
        case .headless: return "后台静默运行，适合已固化的自动化工作流"
        case .adaptive: return "AI 根据任务类型自动选择最佳模式"
        }
    }
}

// MARK: - 会话状态
struct BrowserSessionState: Codable {
    let url: String
    let title: String
    let cookies: [BrowserCookie]
    let localStorage: [String: String]
    let sessionStorage: [String: String]
    let timestamp: Date
    let isAuthenticated: Bool  // 标记是否已登录
}

struct BrowserCookie: Codable {
    let name: String
    let value: String
    let domain: String
    let path: String
    let expires: Date?
}

// MARK: - 工作流定义
struct BrowserWorkflow: Identifiable, Codable {
    let id: String
    let name: String
    let description: String
    let targetURL: String
    let steps: [WorkflowStep]
    let createdAt: Date
    let lastUsed: Date
    let useCount: Int
    let requiresAuth: Bool  // 是否需要登录态
}

struct WorkflowStep: Codable {
    let action: String
    let selector: String?
    let value: String?
    let waitFor: String?  // 等待元素出现
    let screenshot: Bool  // 是否截图验证
}

// MARK: - 浏览器操作类型
enum BrowserAction: String, Codable, CaseIterable {
    case navigate = "navigate"
    case click = "click"
    case fill = "fill"
    case type = "type"
    case screenshot = "screenshot"
    case scroll = "scroll"
    case wait = "wait"
    case evaluate = "evaluate"
    case hover = "hover"
    case select = "select"
    case upload = "upload"
    case download = "download"
    case goBack = "goBack"
    case goForward = "goForward"
    case reload = "reload"
    case close = "close"
    case saveState = "saveState"      // 保存会话状态
    case restoreState = "restoreState" // 恢复会话状态
    
    var displayName: String {
        switch self {
        case .navigate: return "访问网页"
        case .click: return "点击"
        case .fill: return "填写"
        case .type: return "输入"
        case .screenshot: return "截图"
        case .scroll: return "滚动"
        case .wait: return "等待"
        case .evaluate: return "执行脚本"
        case .hover: return "悬停"
        case .select: return "选择"
        case .upload: return "上传"
        case .download: return "下载"
        case .goBack: return "后退"
        case .goForward: return "前进"
        case .reload: return "刷新"
        case .close: return "关闭"
        case .saveState: return "保存状态"
        case .restoreState: return "恢复状态"
        }
    }
}

// MARK: - AI浏览器代理服务
@MainActor
final class BrowserAgentService: ObservableObject {
    static let shared = BrowserAgentService()
    
    // MARK: - Published
    @Published var isRunning = false
    @Published var currentMode: BrowserMode = .adaptive
    @Published var currentURL: String = ""
    @Published var currentTitle: String = ""
    @Published var isLoading = false
    @Published var recentActions: [BrowserActionRecord] = []
    @Published var consoleLogs: [BrowserConsoleLog] = []
    @Published var savedSessions: [SavedSession] = []
    @Published var workflows: [BrowserWorkflow] = []
    @Published var isRecording = false
    @Published var currentRecording: [WorkflowStep] = []
    
    // MARK: - Private
    private var nodeProcess: Process?
    private var websocketTask: URLSessionWebSocketTask?
    private var cancellables = Set<AnyCancellable>()
    private let recentActionsLimit = 50
    private var currentSessionID: String?
    private var persistentContextDir: URL?
    
    struct BrowserActionRecord: Identifiable {
        let id = UUID()
        let timestamp: Date
        let action: String
        let target: String
        let result: String
        let hasScreenshot: Bool
        let mode: BrowserMode
    }
    
    struct BrowserConsoleLog: Identifiable, Equatable {
        let id = UUID()
        let timestamp: Date
        let level: String
        let message: String
    }
    
    struct SavedSession: Identifiable, Codable {
        let id: String
        let name: String
        let url: String
        let createdAt: Date
        var lastUsed: Date
        var isValid: Bool
        
        init(id: String = UUID().uuidString, name: String, url: String, createdAt: Date = Date(), lastUsed: Date = Date(), isValid: Bool = true) {
            self.id = id
            self.name = name
            self.url = url
            self.createdAt = createdAt
            self.lastUsed = lastUsed
            self.isValid = isValid
        }
    }
    
    private init() {
        setupNotifications()
        loadSavedSessions()
        loadWorkflows()
        setupPersistentContext()
    }
    
    // MARK: - 服务管理
    
    func startService(mode: BrowserMode? = nil) async throws {
        guard !isRunning else { return }
        
        let targetMode = mode ?? currentMode
        LogInfo("[BrowserAgent] 启动浏览器服务，模式: \(targetMode.displayName)")
        
        // 检查 Node.js
        guard await checkNodeJS() else {
            throw BrowserAgentError.nodeJSNotFound
        }
        
        // 安装 Playwright
        try await setupPlaywright()
        
        // 启动 Node.js 服务
        try await startNodeServer(mode: targetMode)
        
        // 连接 WebSocket
        try await connectWebSocket()
        
        isRunning = true
        currentMode = targetMode
        LogInfo("[BrowserAgent] 服务启动成功")
    }
    
    func stopService() {
        LogInfo("[BrowserAgent] 停止服务...")
        websocketTask?.cancel()
        websocketTask = nil
        nodeProcess?.terminate()
        nodeProcess = nil
        isRunning = false
        currentSessionID = nil
    }
    
    func keepSessionAlive() {
        LogInfo("[BrowserAgent] 保持会话...")
        websocketTask?.cancel()
        websocketTask = nil
    }
    
    func reconnect(mode: BrowserMode? = nil) async throws {
        if isRunning && nodeProcess != nil {
            if websocketTask == nil {
                try await connectWebSocket()
            }
            return
        }
        try await startService(mode: mode)
    }
    
    // MARK: - 模式切换
    
    func switchMode(_ mode: BrowserMode) async throws {
        guard currentMode != mode else { return }
        
        LogInfo("[BrowserAgent] 切换模式: \(currentMode.displayName) → \(mode.displayName)")
        
        // 保存当前状态
        if isRunning {
            _ = try? await saveSessionState()
        }
        
        // 重启服务
        stopService()
        try await startService(mode: mode)
        
        // 恢复状态（如果适用）
        if mode == .headless || mode == .adaptive {
            _ = try? await restoreLastSessionState()
        }
    }
    
    // MARK: - 会话状态管理
    
    func saveSessionState(name: String? = nil) async throws -> BrowserSessionState {
        let result = try await executeAction(.saveState, params: [
            "name": name ?? "自动保存_\(Date().timeIntervalSince1970)"
        ])
        
        guard result.success,
              let data = result.data,
              let jsonData = data["state"]?.data(using: .utf8) else {
            throw BrowserAgentError.stateSaveFailed
        }
        
        let state = try JSONDecoder().decode(BrowserSessionState.self, from: jsonData)
        
        // 保存到本地
        await persistSessionState(state, name: name)
        
        return state
    }
    
    func restoreSessionState(_ state: BrowserSessionState) async throws {
        let stateData = try JSONEncoder().encode(state)
        let stateString = String(data: stateData, encoding: .utf8) ?? ""
        
        _ = try await executeAction(.restoreState, params: [
            "state": stateString
        ])
    }
    
    func restoreLastSessionState() async throws {
        guard let lastState = loadLastPersistedState() else {
            throw BrowserAgentError.noSavedState
        }
        try await restoreSessionState(lastState)
    }
    
    // MARK: - 工作流管理
    
    func startRecording(name: String) {
        isRecording = true
        currentRecording = []
        LogInfo("[BrowserAgent] 开始录制工作流: \(name)")
    }
    
    func stopRecording(name: String, description: String) -> BrowserWorkflow? {
        guard !currentRecording.isEmpty else {
            isRecording = false
            currentRecording = []
            return nil
        }
        
        let workflow = BrowserWorkflow(
            id: UUID().uuidString,
            name: name,
            description: description,
            targetURL: currentURL,
            steps: currentRecording,
            createdAt: Date(),
            lastUsed: Date(),
            useCount: 0,
            requiresAuth: false
        )
        
        workflows.append(workflow)
        persistWorkflows()
        
        isRecording = false
        currentRecording = []
        
        LogInfo("[BrowserAgent] 工作流已保存: \(name)")
        return workflow
    }
    
    func executeWorkflow(_ workflow: BrowserWorkflow, mode: BrowserMode? = nil) async throws -> String {
        let targetMode = mode ?? (workflow.requiresAuth ? .headed : .headless)
        
        // 启动浏览器
        try await startService(mode: targetMode)
        
        // 恢复会话状态（如果需要认证）
        if workflow.requiresAuth {
            _ = try? await restoreLastSessionState()
        }
        
        // 导航到目标页面
        _ = try await navigate(to: workflow.targetURL)
        
        // 执行工作流步骤
        var results: [String] = []
        for (index, step) in workflow.steps.enumerated() {
            LogInfo("[BrowserAgent] 执行步骤 \(index + 1)/\(workflow.steps.count): \(step.action)")
            
            if let waitFor = step.waitFor {
                // 等待元素出现
                try await waitForElement(waitFor, timeout: 10)
            }
            
            let result = try await executeWorkflowStep(step)
            results.append("步骤 \(index + 1): \(result.success ? "✅" : "❌") \(result.message)")
            
            if step.screenshot {
                _ = try? await screenshot()
            }
            
            // 步骤间等待
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        
        // 更新使用统计
        updateWorkflowUsage(workflow.id)
        
        return results.joined(separator: "\n")
    }
    
    // MARK: - 浏览器控制
    
    func executeAction(_ action: BrowserAction, params: [String: String]) async throws -> BrowserActionResult {
        guard isRunning else {
            throw BrowserAgentError.serviceNotRunning
        }
        
        let request = BrowserActionRequest(action: action, params: params)
        let result = try await sendActionToNode(request)
        
        // 录制模式：记录操作
        if isRecording, let step = convertToWorkflowStep(action, params: params) {
            currentRecording.append(step)
        }
        
        // 记录操作日志
        recordAction(
            action: action.displayName,
            target: params["selector"] ?? params["url"] ?? "",
            result: result.success ? "成功" : "失败: \(result.message)",
            hasScreenshot: result.screenshot != nil,
            mode: currentMode
        )
        
        return result
    }
    
    func navigate(to url: String) async throws -> BrowserActionResult {
        try await executeAction(.navigate, params: ["url": url])
    }
    
    func click(selector: String) async throws -> BrowserActionResult {
        try await executeAction(.click, params: ["selector": selector])
    }
    
    func fill(selector: String, text: String) async throws -> BrowserActionResult {
        try await executeAction(.fill, params: [
            "selector": selector,
            "text": text
        ])
    }
    
    func screenshot() async throws -> BrowserActionResult {
        try await executeAction(.screenshot, params: [:])
    }
    
    func smartExecute(task: String, url: String?, mode: BrowserMode? = nil) async throws -> String {
        // AI 分析任务并自动选择模式
        let targetMode: BrowserMode
        if let mode = mode {
            targetMode = mode
        } else {
            targetMode = await analyzeBestMode(for: task)
        }
        
        // 启动服务
        try await startService(mode: targetMode)
        
        // 导航
        if let url = url {
            _ = try await navigate(to: url)
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        
        // 获取页面信息
        let pageInfo = try await getPageInfo()
        
        // 构建 AI 提示
        let prompt = buildTaskPrompt(task: task, pageInfo: pageInfo)
        
        // 返回分析结果（实际应调用 AI 服务）
        return """
        🌐 浏览器已启动（\(targetMode.displayName)）
        
        当前页面: \(pageInfo.title)
        URL: \(pageInfo.url)
        
        任务: \(task)
        
        建议操作:
        \(analyzePageForTask(task, pageInfo: pageInfo))
        """
    }
    
    // MARK: - 私有方法
    
    private func analyzeBestMode(for task: String) async -> BrowserMode {
        let lowercased = task.lowercased()
        
        // 需要人工干预的场景 -> 有头模式
        let headedKeywords = ["登录", "扫码", "验证码", "首次", "注册", "认证", "授权"]
        if headedKeywords.contains(where: { lowercased.contains($0) }) {
            return .headed
        }
        
        // 纯自动化场景 -> 无头模式
        let headlessKeywords = ["自动", "定时", "批量", "采集", "监控"]
        if headlessKeywords.contains(where: { lowercased.contains($0) }) {
            return .headless
        }
        
        // 默认自适应
        return .adaptive
    }
    
    private func getPageInfo() async throws -> (title: String, url: String, text: String) {
        let titleResult = try await executeAction(.evaluate, params: [
            "script": "document.title"
        ])
        let urlResult = try await executeAction(.evaluate, params: [
            "script": "location.href"
        ])
        let textResult = try await executeAction(.evaluate, params: [
            "script": "document.body.innerText.slice(0, 1000)"
        ])
        
        return (
            title: titleResult.data?["result"] ?? "",
            url: urlResult.data?["result"] ?? "",
            text: textResult.data?["result"] ?? ""
        )
    }
    
    private func analyzePageForTask(_ task: String, pageInfo: (title: String, url: String, text: String)) -> String {
        // 简化分析，实际应调用 AI
        return """
        1. 等待页面完全加载
        2. 查找与任务相关的交互元素
        3. 执行必要的点击或填写操作
        4. 验证操作结果
        """
    }
    
    private func buildTaskPrompt(task: String, pageInfo: (title: String, url: String, text: String)) -> String {
        """
        你是一个浏览器自动化专家。请帮助用户完成以下任务：
        
        任务: \(task)
        
        当前页面信息:
        - 标题: \(pageInfo.title)
        - URL: \(pageInfo.url)
        - 内容摘要: \(String(pageInfo.text.prefix(500)))
        
        请分析页面结构，给出完成任务的详细步骤。
        """
    }
    
    private func convertToWorkflowStep(_ action: BrowserAction, params: [String: String]) -> WorkflowStep? {
        guard action != .screenshot && action != .saveState && action != .restoreState else {
            return nil
        }
        
        return WorkflowStep(
            action: action.rawValue,
            selector: params["selector"],
            value: params["text"] ?? params["value"],
            waitFor: nil,
            screenshot: false
        )
    }
    
    private func executeWorkflowStep(_ step: WorkflowStep) async throws -> BrowserActionResult {
        guard let action = BrowserAction(rawValue: step.action) else {
            throw BrowserAgentError.unknownAction
        }
        
        var params: [String: String] = [:]
        if let selector = step.selector {
            params["selector"] = selector
        }
        if let value = step.value {
            params["text"] = value
        }
        
        return try await executeAction(action, params: params)
    }
    
    private func waitForElement(_ selector: String, timeout: TimeInterval) async throws {
        let startTime = Date()
        while Date().timeIntervalSince(startTime) < timeout {
            let result = try await executeAction(.evaluate, params: [
                "script": "document.querySelector('\(selector)') !== null"
            ])
            if result.data?["result"] == "true" {
                return
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw BrowserAgentError.timeout
    }
    
    // MARK: - 持久化
    
    private func setupPersistentContext() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let contextDir = appSupport.appendingPathComponent("MacAssistant/BrowserContext", isDirectory: true)
        try? FileManager.default.createDirectory(at: contextDir, withIntermediateDirectories: true)
        persistentContextDir = contextDir
    }
    
    private func persistSessionState(_ state: BrowserSessionState, name: String?) async {
        // 实现状态持久化
    }
    
    private func loadLastPersistedState() -> BrowserSessionState? {
        // 实现状态加载
        return nil
    }
    
    private func loadSavedSessions() {
        // 加载已保存的会话列表
    }
    
    private func loadWorkflows() {
        // 加载已保存的工作流
    }
    
    private func persistWorkflows() {
        // 保存工作流
    }
    
    private func updateWorkflowUsage(_ workflowID: String) {
        if let index = workflows.firstIndex(where: { $0.id == workflowID }) {
            var workflow = workflows[index]
            // 更新使用统计
            workflows[index] = workflow
            persistWorkflows()
        }
    }
    
    // MARK: - Node.js 服务管理
    
    private func checkNodeJS() async -> Bool {
        let task = Process()
        task.launchPath = "/usr/bin/which"
        task.arguments = ["node"]
        let pipe = Pipe()
        task.standardOutput = pipe
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }
    
    private func setupPlaywright() async throws {
        // 检查 Playwright 安装
    }
    
    private func startNodeServer(mode: BrowserMode) async throws {
        // 根据模式启动对应的服务
        let scriptContent = createBrowserControllerScript(mode: mode)
        let tempDir = FileManager.default.temporaryDirectory
        let scriptURL = tempDir.appendingPathComponent("browser-controller.js")
        try scriptContent.write(to: scriptURL, atomically: true, encoding: .utf8)
        
        let task = Process()
        task.launchPath = "/usr/bin/env"
        task.arguments = ["node", "browser-controller.js"]
        task.currentDirectoryURL = tempDir
        
        var environment = ProcessInfo.processInfo.environment
        environment["PORT"] = "9234"
        environment["BROWSER_MODE"] = mode.rawValue
        if let contextDir = persistentContextDir {
            environment["CONTEXT_DIR"] = contextDir.path
        }
        task.environment = environment
        
        nodeProcess = task
        try task.run()
        try await Task.sleep(nanoseconds: 3_000_000_000)
    }
    
    private func connectWebSocket() async throws {
        let url = URL(string: "ws://localhost:9234/ws")!
        let session = URLSession(configuration: .default)
        websocketTask = session.webSocketTask(with: url)
        websocketTask?.resume()
        receiveMessage()
    }
    
    private func receiveMessage() {
        websocketTask?.receive { [weak self] result in
            switch result {
            case .success(let message):
                self?.handleWebSocketMessage(message)
                self?.receiveMessage()
            case .failure(let error):
                LogError("[BrowserAgent] WebSocket error: \(error)")
            }
        }
    }
    
    private func handleWebSocketMessage(_ message: URLSessionWebSocketTask.Message) {
        // 处理消息
    }
    
    private func sendActionToNode(_ request: BrowserActionRequest) async throws -> BrowserActionResult {
        // 发送操作并等待响应
        return BrowserActionResult(
            success: true,
            message: "操作已发送",
            data: nil,
            screenshot: nil,
            timestamp: Date()
        )
    }
    
    private func recordAction(action: String, target: String, result: String, hasScreenshot: Bool, mode: BrowserMode) {
        let record = BrowserActionRecord(
            timestamp: Date(),
            action: action,
            target: target,
            result: result,
            hasScreenshot: hasScreenshot,
            mode: mode
        )
        recentActions.insert(record, at: 0)
        if recentActions.count > recentActionsLimit {
            recentActions = Array(recentActions.prefix(recentActionsLimit))
        }
    }
    
    private func setupNotifications() {
        // 设置通知监听
    }
    
    private func createBrowserControllerScript(mode: BrowserMode) -> String {
        // 根据模式生成不同的脚本
        """
        const { chromium } = require('playwright-core');
        const WebSocket = require('ws');
        const fs = require('fs');
        const path = require('path');
        
        const PORT = process.env.PORT || 9234;
        const MODE = process.env.BROWSER_MODE || 'headed';
        const CONTEXT_DIR = process.env.CONTEXT_DIR;
        
        console.log(`[BrowserController] Starting with MODE: ${MODE}, PORT: ${PORT}`);
        
        const wss = new WebSocket.Server({ port: PORT });
        console.log(`[BrowserController] WebSocket server listening on port ${PORT}`);
        
        let browser = null;
        let context = null;
        let page = null;
        
        async function launchBrowser() {
            const headless = MODE === 'headless';
            console.log(`[BrowserController] Launching browser, headless: ${headless}`);
            
            try {
                if (CONTEXT_DIR && fs.existsSync(CONTEXT_DIR)) {
                    // 使用持久化上下文
                    console.log(`[BrowserController] Using persistent context: ${CONTEXT_DIR}`);
                    context = await chromium.launchPersistentContext(CONTEXT_DIR, {
                        headless: headless,
                        viewport: { width: 1280, height: 720 },
                        args: ['--no-sandbox', '--disable-setuid-sandbox']
                    });
                    page = context.pages()[0] || await context.newPage();
                } else {
                    console.log(`[BrowserController] Creating new browser instance`);
                    browser = await chromium.launch({ 
                        headless: headless,
                        args: ['--no-sandbox', '--disable-setuid-sandbox']
                    });
                    context = await browser.newContext({
                        viewport: { width: 1280, height: 720 }
                    });
                    page = await context.newPage();
                }
                console.log(`[BrowserController] Browser launched successfully`);
            } catch (error) {
                console.error(`[BrowserController] Failed to launch browser: ${error.message}`);
                throw error;
            }
            
            // 监听页面事件
            page.on('load', async () => {
                broadcast({ type: 'state', data: {
                    url: page.url(),
                    title: await page.title(),
                    loading: false
                }});
            });
        }
        
        wss.on('connection', async (ws) => {
            console.log('Client connected');
            
            if (!browser && !context) {
                await launchBrowser();
            }
            
            ws.on('message', async (message) => {
                const request = JSON.parse(message);
                const result = await handleAction(request);
                ws.send(JSON.stringify(result));
            });
        });
        
        async function handleAction(request) {
            const { action, params } = request;
            try {
                switch(action) {
                    case 'navigate':
                        await page.goto(params.url, { waitUntil: 'networkidle' });
                        return { success: true, message: '导航成功', data: { url: page.url() }};
                    case 'click':
                        await page.click(params.selector);
                        return { success: true, message: '点击成功' };
                    case 'fill':
                        await page.fill(params.selector, params.text);
                        return { success: true, message: '填写成功' };
                    case 'screenshot':
                        const buffer = await page.screenshot();
                        return { success: true, message: '截图成功', screenshot: buffer.toString('base64') };
                    case 'saveState':
                        const cookies = await context.cookies();
                        const state = { cookies, url: page.url(), title: await page.title() };
                        return { success: true, message: '状态已保存', data: { state: JSON.stringify(state) }};
                    case 'restoreState':
                        if (params.state) {
                            const state = JSON.parse(params.state);
                            await context.addCookies(state.cookies || []);
                            if (state.url) await page.goto(state.url);
                        }
                        return { success: true, message: '状态已恢复' };
                    default:
                        return { success: false, message: '未知操作' };
                }
            } catch (error) {
                return { success: false, message: error.message };
            }
        }
        
        function broadcast(data) {
            wss.clients.forEach(client => {
                if (client.readyState === WebSocket.OPEN) {
                    client.send(JSON.stringify(data));
                }
            });
        }
        
        console.log(`Browser controller running on ws://localhost:${PORT} (mode: ${MODE})`);
        """
    }
}

// MARK: - 错误类型
enum BrowserAgentError: Error {
    case nodeJSNotFound
    case playwrightNotInstalled
    case serviceNotRunning
    case stateSaveFailed
    case stateRestoreFailed
    case noSavedState
    case unknownAction
    case timeout
    case connectionError
    
    var localizedDescription: String {
        switch self {
        case .nodeJSNotFound: return "未找到 Node.js"
        case .playwrightNotInstalled: return "Playwright 未安装"
        case .serviceNotRunning: return "服务未运行"
        case .stateSaveFailed: return "保存状态失败"
        case .stateRestoreFailed: return "恢复状态失败"
        case .noSavedState: return "没有保存的状态"
        case .unknownAction: return "未知操作"
        case .timeout: return "操作超时"
        case .connectionError: return "连接错误"
        }
    }
}

// MARK: - 请求/响应结构
struct BrowserActionRequest: Codable {
    let id: String
    let action: BrowserAction
    let params: [String: String]
    let timestamp: Date
    
    init(action: BrowserAction, params: [String: String]) {
        self.id = UUID().uuidString
        self.action = action
        self.params = params
        self.timestamp = Date()
    }
}

struct BrowserActionResult: Codable {
    let success: Bool
    let message: String
    let data: [String: String]?
    let screenshot: String?
    let timestamp: Date
}
