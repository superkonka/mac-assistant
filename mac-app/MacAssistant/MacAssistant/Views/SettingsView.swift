//
//  SettingsView.swift
//  设置面板
//

import SwiftUI

struct SettingsView: View {
    @AppStorage("backendURL") private var backendURL = "http://127.0.0.1:8765"
    @AppStorage("shortcutEnabled") private var shortcutEnabled = true
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    
    var body: some View {
        TabView {
            // 通用设置
            GeneralSettingsView(
                backendURL: $backendURL,
                shortcutEnabled: $shortcutEnabled,
                launchAtLogin: $launchAtLogin
            )
            .tabItem {
                Label("通用", systemImage: "gear")
            }
            
            // 快捷键设置
            ShortcutSettingsView()
                .tabItem {
                    Label("快捷键", systemImage: "keyboard")
                }
            
            // 关于
            AboutView()
                .tabItem {
                    Label("关于", systemImage: "info.circle")
                }
        }
        .frame(width: 500, height: 400)
        .padding()
    }
}

// MARK: - 通用设置

struct GeneralSettingsView: View {
    @Binding var backendURL: String
    @Binding var shortcutEnabled: Bool
    @Binding var launchAtLogin: Bool
    
    var body: some View {
        Form {
            Section(header: Text("服务配置")) {
                HStack {
                    Text("后端地址:")
                    TextField("http://127.0.0.1:8765", text: $backendURL)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                }
                
                Button("测试连接") {
                    testConnection()
                }
            }
            
            Section(header: Text("启动选项")) {
                Toggle("登录时启动", isOn: $launchAtLogin)
                Toggle("启用全局快捷键", isOn: $shortcutEnabled)
            }
            
            Section(header: Text("数据")) {
                Button("清空历史记录") {
                    UserDefaults.standard.removeObject(forKey: "chat_history")
                }
                .foregroundColor(.red)
            }
        }
    }
    
    func testConnection() {
        // 测试连接逻辑
    }
}

// MARK: - 快捷键设置

struct ShortcutSettingsView: View {
    var body: some View {
        Form {
            Section(header: Text("全局快捷键")) {
                ShortcutRow(
                    title: "打开面板",
                    shortcut: "⌘ ⇧ Space"
                )
                
                ShortcutRow(
                    title: "截图询问",
                    shortcut: "⌘ ⇧ 1"
                )
                
                ShortcutRow(
                    title: "剪贴板询问",
                    shortcut: "⌘ ⇧ V"
                )
            }
            
            Text("快捷键可以在系统偏好设置中修改")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

struct ShortcutRow: View {
    let title: String
    let shortcut: String
    
    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(shortcut)
                .font(.system(.body, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(4)
        }
    }
}

// MARK: - 关于

struct AboutView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "bubble.left.fill")
                .font(.system(size: 64))
                .foregroundColor(.blue)
            
            Text("Mac Assistant")
                .font(.title)
                .bold()
            
            Text("Version 1.0.0")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            Text("基于 OpenClaw + Kimi CLI 的 Mac 智能助手")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            Divider()
            
            HStack(spacing: 20) {
                Link("GitHub", destination: URL(string: "https://github.com/superkonka")!)
                Link("文档", destination: URL(string: "https://github.com/superkonka/mac-assistant")!)
            }
        }
        .padding()
    }
}
