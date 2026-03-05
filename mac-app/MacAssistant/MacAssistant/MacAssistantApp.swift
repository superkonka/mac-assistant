//
//  MacAssistantApp.swift
//  Mac 菜单栏 AI 助手
//

import SwiftUI
import Combine

@main
struct MacAssistantApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var backendService: BackendService!
    var shortcutMonitor: ShortcutMonitor!
    
    private var cancellables = Set<AnyCancellable>()
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 隐藏 Dock 图标
        NSApp.setActivationPolicy(.accessory)
        
        // 初始化服务
        backendService = BackendService()
        shortcutMonitor = ShortcutMonitor()
        
        // 监听连接状态变化
        backendService.$isConnected
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusIcon()
            }
            .store(in: &cancellables)
        
        backendService.$connectionError
            .receive(on: RunLoop.main)
            .sink { [weak self] error in
                if let error = error {
                    self?.showConnectionError(error)
                }
            }
            .store(in: &cancellables)
        
        // 设置菜单栏
        setupStatusBar()
        
        // 设置悬浮窗
        setupPopover()
        
        // 注册快捷键
        setupShortcuts()
        
        // 连接 WebSocket
        backendService.connectWebSocket()
        
        print("✅ Mac Assistant 启动完成")
    }
    
    func setupStatusBar() {
        statusItem = NSStatusBar.shared.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem.button {
            button.action = #selector(togglePopover)
            button.target = self
            updateStatusIcon()
        }
        
        // 右键菜单
        let menu = NSMenu()
        
        // 连接状态
        let statusItem = NSMenuItem(title: "检查连接状态...", action: #selector(checkStatus), keyEquivalent: "")
        menu.addItem(statusItem)
        menu.addItem(NSMenuItem.separator())
        
        menu.addItem(NSMenuItem(title: "打开面板", action: #selector(togglePopover), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "截图询问", action: #selector(screenshotAsk), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "剪贴板询问", action: #selector(clipboardAsk), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "重启后台服务", action: #selector(restartBackend), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "设置", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q"))
        
        statusItem.menu = menu
    }
    
    func setupPopover() {
        popover = NSPopover()
        popover.contentSize = NSSize(width: 400, height: 600)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: ContentView()
                .environmentObject(backendService)
        )
    }
    
    func setupShortcuts() {
        // 主快捷键：⌘⇧Space 打开面板
        shortcutMonitor.registerShortcut(
            key: Int(kVK_Space),
            modifiers: [.command, .shift]
        ) { [weak self] in
            self?.togglePopover()
        }
        
        // 截图快捷键：⌘⇧1
        shortcutMonitor.registerShortcut(
            key: Int(kVK_ANSI_1),
            modifiers: [.command, .shift]
        ) { [weak self] in
            self?.screenshotAsk()
        }
        
        // 剪贴板快捷键：⌘⇧V
        shortcutMonitor.registerShortcut(
            key: Int(kVK_ANSI_V),
            modifiers: [.command, .shift]
        ) { [weak self] in
            self?.clipboardAsk()
        }
    }
    
    func updateStatusIcon() {
        DispatchQueue.main.async { [weak self] in
            guard let button = self?.statusItem.button else { return }
            
            let isConnected = self?.backendService.isConnected ?? false
            
            if isConnected {
                // 已连接：绿色气泡
                button.image = NSImage(systemSymbolName: "bubble.left.fill", accessibilityDescription: "AI Assistant")
                button.contentTintColor = .systemGreen
            } else {
                // 未连接：灰色或红色气泡
                button.image = NSImage(systemSymbolName: "bubble.left", accessibilityDescription: "AI Assistant Offline")
                button.contentTintColor = .systemRed
            }
        }
    }
    
    func showConnectionError(_ error: String) {
        // 显示系统通知
        let notification = NSUserNotification()
        notification.title = "Mac Assistant"
        notification.informativeText = error
        notification.soundName = NSUserNotificationDefaultSoundName
        NSUserNotificationCenter.default.deliver(notification)
    }
    
    // MARK: - Actions
    
    @objc func togglePopover() {
        if let button = statusItem.button {
            if popover.isShown {
                popover.performClose(nil)
            } else {
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
    
    @objc func screenshotAsk() {
        Task {
            await backendService.takeScreenshotAndAsk()
            // 自动打开面板显示结果
            await MainActor.run {
                if !self.popover.isShown {
                    self.togglePopover()
                }
            }
        }
    }
    
    @objc func clipboardAsk() {
        Task {
            await backendService.askAboutClipboard()
            await MainActor.run {
                if !self.popover.isShown {
                    self.togglePopover()
                }
            }
        }
    }
    
    @objc func checkStatus() {
        Task {
            _ = await backendService.checkHealth()
        }
    }
    
    @objc func restartBackend() {
        // 执行重启脚本
        let task = Process()
        task.launchPath = "/bin/bash"
        task.arguments = ["-c", "cd $HOME/code/mac-assistant/daemon && ./service-manager.sh restart"]
        task.launch()
        
        showConnectionError("正在重启后台服务...")
    }
    
    @objc func openSettings() {
        NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @objc func quit() {
        // 清理
        backendService.stopHealthCheck()
        backendService.disconnectWebSocket()
        NSApp.terminate(nil)
    }
}

// MARK: - 键码定义

let kVK_Space: Int = 0x31
let kVK_ANSI_1: Int = 0x12
let kVK_ANSI_V: Int = 0x09
