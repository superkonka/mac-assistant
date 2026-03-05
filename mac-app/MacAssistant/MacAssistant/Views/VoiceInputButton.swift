//
//  VoiceInputButton.swift
//  语音输入按钮 + 录音动画
//

import SwiftUI

struct VoiceInputButton: View {
    @ObservedObject var speechRecognizer: SpeechRecognizer
    let onResult: (String) -> Void
    
    @State private var showPermissionAlert = false
    @State private var pulseAnimation = false
    
    var body: some View {
        Button(action: toggleRecording) {
            ZStack {
                // 脉冲动画（录音时）
                if speechRecognizer.isRecording {
                    Circle()
                        .fill(Color.red.opacity(0.3))
                        .frame(width: 50, height: 50)
                        .scaleEffect(pulseAnimation ? 1.5 : 1.0)
                        .opacity(pulseAnimation ? 0 : 1)
                        .animation(
                            Animation.easeOut(duration: 1.0)
                                .repeatForever(autoreverses: false),
                            value: pulseAnimation
                        )
                    
                    Circle()
                        .fill(Color.red.opacity(0.2))
                        .frame(width: 50, height: 50)
                        .scaleEffect(pulseAnimation ? 1.8 : 1.0)
                        .opacity(pulseAnimation ? 0 : 0.5)
                        .animation(
                            Animation.easeOut(duration: 1.0)
                                .repeatForever(autoreverses: false)
                                .delay(0.3),
                            value: pulseAnimation
                        )
                }
                
                // 主按钮
                Circle()
                    .fill(speechRecognizer.isRecording ? Color.red : Color.blue.opacity(0.1))
                    .frame(width: 36, height: 36)
                
                Image(systemName: speechRecognizer.isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(speechRecognizer.isRecording ? .white : .blue)
            }
        }
        .buttonStyle(PlainButtonStyle())
        .help(speechRecognizer.isRecording ? "点击停止录音" : "点击开始语音输入")
        .onChange(of: speechRecognizer.isRecording) { isRecording in
            if isRecording {
                pulseAnimation = true
            } else {
                pulseAnimation = false
            }
        }
        .alert("需要权限", isPresented: $showPermissionAlert) {
            Button("去设置") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("请在系统设置中允许 Mac Assistant 访问麦克风和语音识别")
        }
    }
    
    func toggleRecording() {
        if speechRecognizer.isRecording {
            // 停止录音
            speechRecognizer.stopRecording()
            
            // 如果有结果，回调
            if !speechRecognizer.transcript.isEmpty {
                onResult(speechRecognizer.transcript)
            }
        } else {
            // 开始录音
            Task {
                // 设置回调
                speechRecognizer.onResult = { text in
                    DispatchQueue.main.async {
                        onResult(text)
                    }
                }
                
                speechRecognizer.onError = { error in
                    DispatchQueue.main.async {
                        if error.contains("权限") {
                            showPermissionAlert = true
                        }
                    }
                }
                
                await speechRecognizer.startRecording()
            }
        }
    }
}

// MARK: - 录音状态指示器

struct RecordingIndicator: View {
    let transcript: String
    let onCancel: () -> Void
    let onConfirm: () -> Void
    
    @State private var waveAnimation = false
    
    var body: some View {
        VStack(spacing: 12) {
            // 波形动画
            HStack(spacing: 4) {
                ForEach(0..<5) { i in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.red)
                        .frame(width: 4, height: waveAnimation ? 20 : 8)
                        .animation(
                            Animation.easeInOut(duration: 0.3)
                                .repeatForever(autoreverses: true)
                                .delay(Double(i) * 0.1),
                            value: waveAnimation
                        )
                }
            }
            .frame(height: 30)
            
            // 转录文字
            if !transcript.isEmpty {
                Text(transcript)
                    .font(.callout)
                    .foregroundColor(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            } else {
                Text("正在聆听...")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
            
            // 控制按钮
            HStack(spacing: 20) {
                Button("取消") {
                    onCancel()
                }
                .buttonStyle(BorderlessButtonStyle())
                
                Button("完成") {
                    onConfirm()
                }
                .buttonStyle(BorderedButtonStyle())
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor))
                .shadow(radius: 4)
        )
        .onAppear {
            waveAnimation = true
        }
    }
}
