//
//  SpeechRecognizer.swift
//  语音识别服务 - 使用 macOS SFSpeechRecognizer
//

import Foundation
import Speech
import AVFoundation

class SpeechRecognizer: ObservableObject {
    @Published var isRecording = false
    @Published var transcript = ""
    @Published var recognitionError: String?
    
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    
    var onResult: ((String) -> Void)?
    var onError: ((String) -> Void)?
    
    init() {
        // 使用中文识别，如果不可用则回退到英文
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
        if speechRecognizer == nil {
            speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        }
        
        speechRecognizer?.delegate = self
    }
    
    // MARK: - 权限检查
    
    func requestAuthorization() async -> Bool {
        // 请求麦克风权限
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if micStatus == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if !granted {
                await MainActor.run {
                    self.recognitionError = "需要麦克风权限才能使用语音输入"
                }
                return false
            }
        } else if micStatus == .denied {
            await MainActor.run {
                self.recognitionError = "请在系统设置中开启麦克风权限"
            }
            return false
        }
        
        // 请求语音识别权限
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        if speechStatus == .notDetermined {
            await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume()
                }
            }
        }
        
        let finalStatus = SFSpeechRecognizer.authorizationStatus()
        if finalStatus != .authorized {
            await MainActor.run {
                self.recognitionError = "需要语音识别权限"
            }
            return false
        }
        
        return true
    }
    
    // MARK: - 开始录音
    
    func startRecording() async {
        // 检查权限
        let authorized = await requestAuthorization()
        guard authorized else { return }
        
        // 停止之前的任务
        await stopRecording()
        
        await MainActor.run {
            self.transcript = ""
            self.recognitionError = nil
            self.isRecording = true
        }
        
        do {
            // 配置音频会话
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            
            // 创建识别请求
            recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
            
            guard let recognitionRequest = recognitionRequest else {
                throw NSError(domain: "SpeechRecognizer", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法创建识别请求"])
            }
            
            recognitionRequest.shouldReportPartialResults = true
            recognitionRequest.requiresOnDeviceRecognition = false // 允许云端识别，更准确
            
            // 开始识别任务
            recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
                guard let self = self else { return }
                
                if let error = error {
                    DispatchQueue.main.async {
                        self.handleError(error)
                    }
                    return
                }
                
                guard let result = result else { return }
                
                let text = result.bestTranscription.formattedString
                DispatchQueue.main.async {
                    self.transcript = text
                    
                    // 如果识别完成，回调结果
                    if result.isFinal {
                        self.onResult?(text)
                        self.stopRecording()
                    }
                }
            }
            
            // 配置音频输入
            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)
            
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
                self?.recognitionRequest?.append(buffer)
            }
            
            audioEngine.prepare()
            try audioEngine.start()
            
        } catch {
            await MainActor.run {
                self.recognitionError = "启动录音失败: \(error.localizedDescription)"
                self.isRecording = false
            }
        }
    }
    
    // MARK: - 停止录音
    
    func stopRecording() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        
        recognitionTask?.cancel()
        recognitionTask = nil
        
        // 关闭音频会话
        try? AVAudioSession.sharedInstance().setActive(false)
        
        DispatchQueue.main.async {
            self.isRecording = false
        }
    }
    
    // MARK: - 错误处理
    
    private func handleError(_ error: Error) {
        let nsError = error as NSError
        var message = ""
        
        switch nsError.code {
        case 1:
            message = "语音识别被取消"
        case 2:
            message = "语音识别不可用"
        case 3:
            message = "无法访问麦克风"
        case 4:
            message = "无法连接到语音识别服务"
        case 5:
            message = "未获得语音识别权限"
        case 7:
            message = "未获得麦克风权限"
        default:
            message = "语音识别错误: \(error.localizedDescription)"
        }
        
        recognitionError = message
        onError?(message)
        isRecording = false
    }
}

// MARK: - SFSpeechRecognizerDelegate

extension SpeechRecognizer: SFSpeechRecognizerDelegate {
    func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        if !available {
            DispatchQueue.main.async {
                self.recognitionError = "语音识别服务当前不可用"
                self.stopRecording()
            }
        }
    }
}
