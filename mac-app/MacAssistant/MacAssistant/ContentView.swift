//
//  ContentView.swift
//  主界面
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var backend: BackendService
    @State private var messageText = ""
    @State private var scrollProxy: ScrollViewProxy? = nil
    @FocusState private var isInputFocused: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            // 顶部工具栏
            toolbar
            
            Divider()
            
            // 消息列表
            messagesList
            
            Divider()
            
            // 输入区域
            inputArea
        }
        .frame(width: 400, height: 600)
        .onAppear {
            backend.loadHistory()
            isInputFocused = true
        }
    }
    
    // MARK: - Toolbar
    
    var toolbar: some View {
        HStack {
            // 连接状态
            HStack(spacing: 4) {
                Circle()
                    .fill(backend.isConnected ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(backend.isConnected ? "已连接" : "未连接")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            // 快捷操作按钮
            Button(action: { backend.takeScreenshot() }) {
                Image(systemName: "camera")
            }
            .buttonStyle(PlainButtonStyle())
            .help("截图")
            
            Button(action: { backend.clearHistory() }) {
                Image(systemName: "trash")
            }
            .buttonStyle(PlainButtonStyle())
            .help("清空历史")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(NSColor.windowBackgroundColor))
    }
    
    // MARK: - Messages List
    
    var messagesList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(backend.messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                    
                    if backend.isLoading {
                        LoadingIndicator()
                            .id("loading")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .onChange(of: backend.messages) { _ in
                scrollToBottom(proxy: proxy)
            }
            .onAppear {
                self.scrollProxy = proxy
                scrollToBottom(proxy: proxy)
            }
        }
    }
    
    func scrollToBottom(proxy: ScrollViewProxy) {
        if let lastId = backend.messages.last?.id {
            withAnimation {
                proxy.scrollTo(lastId, anchor: .bottom)
            }
        }
    }
    
    // MARK: - Input Area
    
    var inputArea: some View {
        VStack(spacing: 8) {
            // 快捷指令栏
            HStack(spacing: 8) {
                QuickActionButton(icon: "scissors", text: "解释代码") {
                    insertQuickCommand("解释这段代码：")
                }
                
                QuickActionButton(icon: "doc.text", text: "总结") {
                    insertQuickCommand("总结以下内容：")
                }
                
                QuickActionButton(icon: "character.cursor.ibeam", text: "润色") {
                    insertQuickCommand("润色这段文字：")
                }
                
                QuickActionButton(icon: "globe", text: "翻译") {
                    insertQuickCommand("翻译成中文：")
                }
            }
            
            // 输入框
            HStack(spacing: 8) {
                TextEditor(text: $messageText)
                    .font(.body)
                    .frame(height: 60)
                    .focused($isInputFocused)
                    .onSubmit {
                        sendMessage()
                    }
                
                VStack(spacing: 4) {
                    Button(action: sendMessage) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                            .foregroundColor(messageText.isEmpty ? .gray : .blue)
                    }
                    .disabled(messageText.isEmpty || backend.isLoading)
                    .buttonStyle(PlainButtonStyle())
                    
                    Button(action: { backend.takeScreenshotAndAsk() }) {
                        Image(systemName: "camera.fill")
                            .font(.caption)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor))
    }
    
    func sendMessage() {
        guard !messageText.isEmpty else { return }
        let text = messageText
        messageText = ""
        
        Task {
            await backend.sendMessage(text)
        }
    }
    
    func insertQuickCommand(_ command: String) {
        messageText = command + messageText
        isInputFocused = true
    }
}

// MARK: - Message Bubble

struct MessageBubble: View {
    let message: ChatMessage
    
    var body: some View {
        HStack {
            if message.role == .user {
                Spacer()
            }
            
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                Text(message.content)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(message.role == .user ? Color.blue.opacity(0.1) : Color.gray.opacity(0.1))
                    .cornerRadius(12)
                    .foregroundColor(.primary)
                
                if let timestamp = message.timestamp {
                    Text(formatTime(timestamp))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            
            if message.role == .assistant {
                Spacer()
            }
        }
    }
    
    func formatTime(_ isoString: String) -> String {
        // 简化显示时间
        return isoString
    }
}

// MARK: - Loading Indicator

struct LoadingIndicator: View {
    @State private var isAnimating = false
    
    var body: some View {
        HStack {
            Spacer()
            HStack(spacing: 4) {
                ForEach(0..<3) { i in
                    Circle()
                        .fill(Color.gray)
                        .frame(width: 6, height: 6)
                        .opacity(isAnimating ? 1 : 0.3)
                        .animation(
                            Animation.easeInOut(duration: 0.5)
                                .repeatForever()
                                .delay(Double(i) * 0.2),
                            value: isAnimating
                        )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.gray.opacity(0.1))
            .cornerRadius(12)
            Spacer()
        }
        .onAppear {
            isAnimating = true
        }
    }
}

// MARK: - Quick Action Button

struct QuickActionButton: View {
    let icon: String
    let text: String
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption)
                Text(text)
                    .font(.caption)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.blue.opacity(0.1))
            .foregroundColor(.blue)
            .cornerRadius(6)
        }
        .buttonStyle(PlainButtonStyle())
    }
}
