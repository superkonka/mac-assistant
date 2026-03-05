//
//  ContentView.swift
//  主界面 - 集成语音输入
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var backend: BackendService
    @StateObject private var speechRecognizer = SpeechRecognizer()
    
    @State private var messageText = ""
    @State private var scrollProxy: ScrollViewProxy? = nil
    @State private var showRecordingPanel = false
    @FocusState private var isInputFocused: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            // 顶部工具栏（带连接状态）
            toolbar
            
            // 连接状态警告
            if let error = backend.connectionError, !backend.isConnected {
                connectionAlert(error)
            }
            
            Divider()
            
            // 消息列表
            messagesList
            
            Divider()
            
            // 录音状态面板
            if showRecordingPanel {
                RecordingIndicator(
                    transcript: speechRecognizer.transcript,
                    onCancel: {
                        speechRecognizer.stopRecording()
                        showRecordingPanel = false
                    },
                    onConfirm: {
                        speechRecognizer.stopRecording()
                        if !speechRecognizer.transcript.isEmpty {
                            messageText = speechRecognizer.transcript
                            sendMessage()
                        }
                        showRecordingPanel = false
                    }
                )
                .padding(.horizontal)
                .padding(.bottom, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            
            // 输入区域
            inputArea
        }
        .frame(width: 400, height: 600)
        .onAppear {
            backend.loadHistory()
            isInputFocused = true
            
            // 设置语音识别回调
            speechRecognizer.onResult = { text in
                messageText = text
            }
        }
        .onChange(of: speechRecognizer.isRecording) { isRecording in
            withAnimation {
                showRecordingPanel = isRecording
            }
        }
    }
    
    // MARK: - Toolbar
    
    var toolbar: some View {
        HStack(spacing: 12) {
            // 连接状态指示器
            HStack(spacing: 6) {
                Circle()
                    .fill(backend.isConnected ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                
                Text(backend.isConnected ? "已连接" : "未连接")
                    .font(.caption)
                    .foregroundColor(backend.isConnected ? .green : .red)
            }
            
            Spacer()
            
            // 快捷操作按钮
            Button(action: { backend.takeScreenshot() }) {
                Image(systemName: "camera")
                    .foregroundColor(backend.isConnected ? .primary : .gray)
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(!backend.isConnected)
            .help("截图")
            
            Button(action: { backend.clearHistory() }) {
                Image(systemName: "trash")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(PlainButtonStyle())
            .help("清空历史")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(NSColor.windowBackgroundColor))
    }
    
    // MARK: - 连接状态警告
    
    func connectionAlert(_ error: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            
            Text(error)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(2)
            
            Spacer()
            
            Button("重试") {
                Task {
                    _ = await backend.checkHealth()
                }
            }
            .font(.caption)
            .buttonStyle(LinkButtonStyle())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.1))
    }
    
    // MARK: - Messages List
    
    var messagesList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    // 欢迎消息
                    if backend.messages.isEmpty {
                        welcomeView
                    }
                    
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
            .onChange(of: backend.messages.count) { _ in
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
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(lastId, anchor: .bottom)
            }
        }
    }
    
    // MARK: - Welcome View
    
    var welcomeView: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 48))
                .foregroundColor(.blue.opacity(0.6))
            
            Text("Mac Assistant")
                .font(.title2)
                .bold()
            
            VStack(spacing: 8) {
                Text("快捷键")
                    .font(.headline)
                    .foregroundColor(.secondary)
                
                HStack(spacing: 16) {
                    ShortcutBadge(key: "⌘⇧Space", desc: "打开")
                    ShortcutBadge(key: "⌘⇧1", desc: "截图")
                    ShortcutBadge(key: "⌘⇧V", desc: "剪贴板")
                }
                
                Text("🎙️ 点击麦克风按钮使用语音输入")
                    .font(.callout)
                    .foregroundColor(.blue)
                    .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 300)
        .padding()
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
            
            // 输入框 + 语音按钮
            HStack(spacing: 8) {
                TextEditor(text: $messageText)
                    .font(.body)
                    .frame(height: 60)
                    .focused($isInputFocused)
                    .overlay(
                        Group {
                            if messageText.isEmpty && !showRecordingPanel {
                                Text("输入消息或点击麦克风...")
                                    .foregroundColor(.gray)
                                    .padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                        },
                        alignment: .leading
                    )
                
                VStack(spacing: 8) {
                    // 语音输入按钮
                    VoiceInputButton(speechRecognizer: speechRecognizer) { text in
                        messageText = text
                        // 自动发送
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            if !messageText.isEmpty {
                                sendMessage()
                            }
                        }
                    }
                    
                    // 发送按钮
                    Button(action: sendMessage) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                            .foregroundColor(canSend ? .blue : .gray)
                    }
                    .disabled(!canSend)
                    .buttonStyle(PlainButtonStyle())
                    
                    // 截图按钮
                    Button(action: { backend.takeScreenshotAndAsk() }) {
                        Image(systemName: "camera.fill")
                            .font(.caption)
                            .foregroundColor(backend.isConnected ? .primary : .gray)
                    }
                    .disabled(!backend.isConnected)
                    .buttonStyle(PlainButtonStyle())
                }
            }
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor))
    }
    
    var canSend: Bool {
        !messageText.isEmpty && backend.isConnected && !backend.isLoading && !speechRecognizer.isRecording
    }
    
    func sendMessage() {
        guard canSend else { return }
        let text = messageText
        messageText = ""
        isInputFocused = true
        
        Task {
            await backend.sendMessage(text)
        }
    }
    
    func insertQuickCommand(_ command: String) {
        messageText = command
        isInputFocused = true
    }
}

// MARK: - Shortcut Badge

struct ShortcutBadge: View {
    let key: String
    let desc: String
    
    var body: some View {
        VStack(spacing: 4) {
            Text(key)
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.semibold)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.gray.opacity(0.15))
                .cornerRadius(6)
            
            Text(desc)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Message Bubble (保持不变)

struct MessageBubble: View {
    let message: ChatMessage
    
    var body: some View {
        HStack {
            if message.role == .user {
                Spacer()
            }
            
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 2) {
                Text(message.content)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        message.role == .user 
                            ? Color.blue.opacity(0.15)
                            : Color.gray.opacity(0.15)
                    )
                    .foregroundColor(.primary)
                    .cornerRadius(12)
                
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
    
    func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - Loading Indicator (保持不变)

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
                                .delay(Double(i) * 0.15),
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

// MARK: - Quick Action Button (保持不变)

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
