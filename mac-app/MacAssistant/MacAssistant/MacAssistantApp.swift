//
//  MacAssistantApp.swift
//  OpenClaw 版 - OpenClaw + Kimi Bridge v5.0.0
//

import SwiftUI
import AppKit
import UserNotifications

@main
struct MacAssistantApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 600, height: 700)
        
        // 首次启动引导窗口
        Window("欢迎使用", id: "onboarding") {
            OnboardingView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 600, height: 500)
        .windowResizability(.contentSize)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    let commandRunner = CommandRunner.shared
    var window: NSWindow?
    var logWindow: NSWindow?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        LogInfo("🚀 应用启动")
        
        NSApp.setActivationPolicy(.accessory)
        preferCurrentBundleInLaunchServices()
        setupStatusBar()
        setupMainWindow()

        // 检查是否需要首次启动引导
        Task {
            await checkFirstLaunch()
        }
        
        // 启动 AutoAgent 分析
        AutoAgent.shared.requestImmediateAnalysis()
        
        LogInfo("✅ 应用启动完成")
    }
    
    /// 检查首次启动并显示引导
    private func checkFirstLaunch() async {
        let dependencyManager = DependencyManager.shared
        let agentStore = AgentStore.shared
        
        // 检查是否需要引导：没有可用 Agent 或 OpenClaw 未安装
        let needsSetup = await dependencyManager.needsFirstTimeSetup || 
                         await dependencyManager.currentStatus == .notInstalled
        
        if needsSetup {
            LogInfo("🆕 首次启动，显示引导界面")
            
            await MainActor.run {
                // 显示引导窗口
                if let onboardingWindow = NSApp.windows.first(where: { $0.title == "欢迎使用" }) {
                    onboardingWindow.makeKeyAndOrderFront(nil)
                    onboardingWindow.center()
                }
                
                // 隐藏主窗口直到配置完成
                window?.orderOut(nil)
            }
        } else {
            // 正常启动 Gateway
            do {
                _ = try await OpenClawGatewayClient.shared.prepareGateway()
                LogInfo("🦞 OpenClaw gateway wrapper 已就绪")
            } catch {
                LogError("OpenClaw gateway wrapper 启动失败", error: error)
            }
        }
    }
    
    func setupMainWindow() {
        // 监听引导完成通知
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onboardingDidComplete),
            name: NSNotification.Name("OnboardingDidComplete"),
            object: nil
        )
        
        let contentView = ChatView()
        
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window?.title = "Mac Assistant - OpenClaw"
        window?.contentView = NSHostingView(rootView: contentView)
        window?.setFrameAutosaveName("MainWindow")
    }
    
    func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "cpu", accessibilityDescription: "Agent")
            button.action = #selector(toggleWindow)
            button.target = self
        }
        
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "立即分析", action: #selector(analyzeNow), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "截图询问", action: #selector(screenshotAndAsk), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "剪贴板询问", action: #selector(clipboardAndAsk), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "📋 查看日志", action: #selector(showLogViewer), keyEquivalent: "l"))
        menu.addItem(NSMenuItem(title: "📂 打开日志目录", action: #selector(openLogDirectory), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q"))
        
        statusItem.menu = menu
    }
    
    @objc func toggleWindow() {
        if let window = window {
            if window.isVisible {
                window.orderOut(nil)
            } else {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
    
    @objc func analyzeNow() {
        LogInfo("🔄 用户触发立即分析")
        AutoAgent.shared.forceAnalysis()
    }
    
    @objc func screenshotAndAsk() {
        LogInfo("📸 用户触发截图询问")
        commandRunner.handleScreenshot()
        showWindow()
    }
    
    @objc func clipboardAndAsk() {
        LogInfo("📋 用户触发剪贴板询问")
        commandRunner.clipboardAndAsk()
        showWindow()
    }
    
    @objc func showLogViewer() {
        LogInfo("📋 用户打开日志查看器")
        
        if logWindow == nil {
            let logView = LogViewerView()
            
            logWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            logWindow?.title = "日志查看器"
            logWindow?.contentView = NSHostingView(rootView: logView)
            logWindow?.setFrameAutosaveName("LogViewerWindow")
        }
        
        logWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @objc func openLogDirectory() {
        LogInfo("📂 用户打开日志目录")
        let logPath = FileLogger.shared.getLogFilePath()
        let logURL = URL(fileURLWithPath: logPath).deletingLastPathComponent()
        NSWorkspace.shared.open(logURL)
    }
    
    func showWindow() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @objc func quit() {
        LogInfo("👋 应用退出")
        NSApp.terminate(nil)
    }
    
    /// 引导完成，启动 Gateway 和显示主窗口
    @objc func onboardingDidComplete() {
        LogInfo("🎉 引导完成，启动主功能")
        
        Task {
            do {
                _ = try await OpenClawGatewayClient.shared.prepareGateway()
                LogInfo("🦞 OpenClaw gateway wrapper 已就绪")
            } catch {
                LogError("OpenClaw gateway wrapper 启动失败", error: error)
            }
        }
        
        // 显示主窗口
        showWindow()
    }

    private func preferCurrentBundleInLaunchServices() {
        let currentBundleURL = Bundle.main.bundleURL.standardizedFileURL
        let currentPath = currentBundleURL.path

        guard currentPath.contains("/build/latest-src/"),
              let bundleIdentifier = Bundle.main.bundleIdentifier else {
            return
        }

        DispatchQueue.global(qos: .utility).async {
            let appName = currentBundleURL.lastPathComponent
            let query = "kMDItemCFBundleIdentifier == '\(bundleIdentifier)' && kMDItemFSName == '\(appName)'"
            let discoveredPaths = self.runProcess(
                executable: "/usr/bin/mdfind",
                arguments: [query]
            )
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

            let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

            for path in discoveredPaths {
                let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
                guard standardizedPath != currentPath else { continue }
                _ = self.runProcess(executable: lsregister, arguments: ["-u", standardizedPath])
            }

            _ = self.runProcess(executable: lsregister, arguments: ["-f", currentPath])
        }
    }

    @discardableResult
    private func runProcess(executable: String, arguments: [String]) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments

        let outputPipe = Pipe()
        task.standardOutput = outputPipe
        task.standardError = outputPipe

        do {
            try task.run()
            task.waitUntilExit()
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            LogError("LaunchServices 修正失败: \(error.localizedDescription)")
            return ""
        }
    }
}
