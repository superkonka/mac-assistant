//
//  ShortcutMonitor.swift
//  全局快捷键监控
//

import Foundation
import AppKit
import Carbon

class ShortcutMonitor {
    private var eventHandler: EventHandlerRef?
    private var shortcuts: [(key: Int, modifiers: Int, action: () -> Void)] = []
    
    init() {
        registerEventHandler()
    }
    
    deinit {
        unregisterEventHandler()
    }
    
    func registerShortcut(key: Int, modifiers: Int, action: @escaping () -> Void) {
        shortcuts.append((key: key, modifiers: modifiers, action: action))
    }
    
    private func registerEventHandler() {
        // 使用 NSEvent 监控全局快捷键
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyEvent(event)
        }
    }
    
    private func unregisterEventHandler() {
        // 清理
    }
    
    private func handleKeyEvent(_ event: NSEvent) {
        let keyCode = Int(event.keyCode)
        let modifierFlags = event.modifierFlags
        
        var modifiers = 0
        if modifierFlags.contains(.command) { modifiers |= Int(cmdKey) }
        if modifierFlags.contains(.shift) { modifiers |= Int(shiftKey) }
        if modifierFlags.contains(.option) { modifiers |= Int(optionKey) }
        if modifierFlags.contains(.control) { modifiers |= Int(controlKey) }
        
        for shortcut in shortcuts {
            if keyCode == shortcut.key && modifiers == shortcut.modifiers {
                DispatchQueue.main.async {
                    shortcut.action()
                }
            }
        }
    }
}

// MARK: - 键码定义

extension Int {
    static let space = 49
    static let one = 18
    static let v = 9
    static let c = 8
}
