//
//  SettingsView.swift
//  设置面板 - 带后台服务控制
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
            
            // 服务管理
            ServiceManagementView()
                .tabItem {
                    Label("服务", systemImage: "server.rack")
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
}

// MARK: - 服务管理

struct ServiceManagementView: View {
    @State private var isServiceRunning = false
    @State private var isLoading = false
    @State private var logContent = ""
    
    var body: some View {
        VStack(spacing: 16) {
            // 服务状态
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("后台服务")
                        .font(.headline)
                    Text(isServiceRunning ? "运行中" : "已停止")
                        .font(.caption)
                        .foregroundColor(isServiceRunning ? .green : .red)
                }
                
                Spacer()
                
                // 状态指示灯
                Circle()
                    .fill(isServiceRunning ? Color.green : Color.red)
                    .frame(width: 10, height: 10)
            }
            
            Divider()
            
            // 控制按钮
            HStack(spacing: 12) {
                Button(action: startService) {
                    Label("启动", systemImage: "play.fill")
                }
                .disabled(isServiceRunning || isLoading)
                
                Button(action: stopService) {
                    Label("停止", systemImage: "stop.fill")
                }
                .disabled(!isServiceRunning || isLoading)
                .buttonStyle(BorderlessButtonStyle())
                
                Button(action: restartService) {
                    Label("重启", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading)
                .buttonStyle(BorderlessButtonStyle())
                
                Spacer()
                
                Button(action: checkStatus) {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading)
                .buttonStyle(LinkButtonStyle())
            }
            
            Divider()
            
            // 日志预览
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("服务日志")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    Button("查看完整日志") {
                        openLogsInFinder()
                    }
                    .font(.caption)
                    .buttonStyle(LinkButtonStyle())
                }
                
                ScrollView {
                    Text(logContent.isEmpty ? "暂无日志" : logContent)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 100)
                .padding(8)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(6)
            }
            
            Spacer()
        }
        .padding()
        .onAppear {
            checkStatus()
        }
    }
    
    func checkStatus() {
        // 检查服务状态
        let task = Process()
        task.launchPath = "/bin/bash"
        task.arguments = ["-c", "cd $HOME/code/mac-assistant/daemon && ./service-manager.sh status"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.launch()
        task.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        
        isServiceRunning = output.contains("运行中") || output.contains("PID")
        
        // 读取日志
        readLogs()
    }
    
    func startService() {
        isLoading = true
        DispatchQueue.global().async {
            let task = Process()
            task.launchPath = "/bin/bash"
            task.arguments = ["-c", "cd $HOME/code/mac-assistant/daemon && ./service-manager.sh start"]
            task.launch()
            task.waitUntilExit()
            
            DispatchQueue.main.async {
                isLoading = false
                checkStatus()
            }
        }
    }
    
    func stopService() {
        isLoading = true
        DispatchQueue.global().async {
            let task = Process()
            task.launchPath = "/bin/bash"
            task.arguments = ["-c", "cd $HOME/code/mac-assistant/daemon && ./service-manager.sh stop"]
            task.launch()
            task.waitUntilExit()
            
            DispatchQueue.main.async {
                isLoading = false
                checkStatus()
            }
        }
    }
    
    func restartService() {
        isLoading = true
        DispatchQueue.global().async {
            let task = Process()
            task.launchPath = "/bin/bash"
            task.arguments = ["-c", "cd $HOME/code/mac-assistant/daemon && ./service-manager.sh restart"]
            task.launch()
            task.waitUntilExit()
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                isLoading = false
                checkStatus()
            }
        }
    }
    
    func readLogs() {
        let logPath = "\(NSHomeDirectory())/code/mac-assistant/daemon/backend.log"
        if let content = try? String(contentsOfFile: logPath, encoding: .utf8) {
            // 只显示最后 20 行
            let lines = content.components(separatedBy: "\n").suffix(20)
            logContent = lines.joined(separator: "\n")
        }
    }
    
    func openLogsInFinder() {
        let logPath = "\(NSHomeDirectory())/code/mac-assistant/daemon"
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: logPath)
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
            
            Section(header: Text("说明")) {
                Text("快捷键可以在系统偏好设置 > 键盘 > 快捷键中修改")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
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
            
            Text("基于 OpenClaw + Kimi CLI 的 Mac 智能助手\n本地运行，安全可靠")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            Divider()
            
            HStack(spacing: 20) {
                Link("GitHub", destination: URL(string: "https://github.com/superkonka/mac-assistant")!)
                Link("文档", destination: URL(string: "https://github.com/superkonka/mac-assistant/blob/main/README.md")!)
            }
        }
        .padding()
    }
}
