//
//  MacAssistantApp.swift
//  MacAssistant
//
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
    
    @Published var isConnected = false
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 隐藏 Dock 图标
        NSApp.setActivationPolicy(.accessory)
        
        // 初始化服务
        backendService = BackendService()
        shortcutMonitor = ShortcutMonitor()
        
        // 设置菜单栏
        setupStatusBar()
        
        // 设置悬浮窗
        setupPopover()
        
        // 注册快捷键
        setupShortcuts()
        
        // 检查后端连接
        checkConnection()
        
        print("✅ Mac Assistant 启动完成")
    }
    
    func setupStatusBar() {
        statusItem = NSStatusBar.shared.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "bubble.left.fill", accessibilityDescription: "AI Assistant")
            button.action = #selector(togglePopover)
            button.target = self
        }
        
        // 右键菜单
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "打开面板", action: #selector(togglePopover), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "截图询问", action: #selector(screenshotAsk), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "剪贴板询问", action: #selector(clipboardAsk), keyEquivalent: ""))
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
        shortcutMonitor.registerShortcut(
            key: .space,
            modifiers: [.command, .shift]
        ) { [weak self] in
            self?.togglePopover()
        }
        
        shortcutMonitor.registerShortcut(
            key: .one,
            modifiers: [.command, .shift]
        ) { [weak self] in
            self?.screenshotAsk()
        }
    }
    
    func checkConnection() {
        Task {
            let connected = await backendService.checkHealth()
            await MainActor.run {
                self.isConnected = connected
                self.updateStatusIcon()
            }
        }
    }
    
    func updateStatusIcon() {
        if let button = statusItem.button {
            let symbolName = isConnected ? "bubble.left.fill" : "bubble.left"
            button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "AI Assistant")
            button.contentTintColor = isConnected ? .systemGreen : .systemRed
        }
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
        }
    }
    
    @objc func clipboardAsk() {
        Task {
            await backendService.askAboutClipboard()
        }
    }
    
    @objc func openSettings() {
        NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @objc func quit() {
        NSApp.terminate(nil)
    }
}
