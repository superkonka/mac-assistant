//
//  BrowserAgentView.swift
//  SwiftUI 浏览器视图组件
//

import SwiftUI

/// 浏览器服务视图
public struct BrowserAgentView: View {
    @StateObject private var viewModel = BrowserAgentViewModel()
    
    public init() {}
    
    public var body: some View {
        VStack(spacing: 0) {
            // 权限状态栏
            if !viewModel.permissionGranted {
                PermissionBanner(viewModel: viewModel)
            }
            
            // 主内容
            if viewModel.isLoading {
                ProgressView("加载中...")
                    .frame(maxHeight: .infinity)
            } else if let session = viewModel.currentSession {
                BrowserSessionView(session: session, viewModel: viewModel)
            } else {
                EmptyStateView(viewModel: viewModel)
            }
        }
        .frame(minWidth: 600, minHeight: 400)
        .task {
            await viewModel.checkPermission()
        }
    }
}

// MARK: - 子视图

struct PermissionBanner: View {
    @ObservedObject var viewModel: BrowserAgentViewModel
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundColor(.orange)
                .font(.system(size: 20))
            
            VStack(alignment: .leading, spacing: 4) {
                Text("需要 Safari 权限")
                    .font(.system(size: 13, weight: .semibold))
                Text("请在系统设置中授权 MacAssistant 控制 Safari")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            Button {
                viewModel.openPermissionSettings()
            } label: {
                Text("前往授权")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            
            Button {
                Task { await viewModel.checkPermission() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
        }
        .padding()
        .background(Color.orange.opacity(0.1))
    }
}

struct EmptyStateView: View {
    @ObservedObject var viewModel: BrowserAgentViewModel
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "globe")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            
            Text("浏览器自动化")
                .font(.system(size: 16, weight: .semibold))
            
            Text("连接到浏览器服务后，可以自动化控制 Safari 或 Chrome")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            
            Button {
                Task { await viewModel.startSession() }
            } label: {
                Label("启动浏览器会话", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.permissionGranted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct BrowserSessionView: View {
    let session: BrowserSessionInfo
    @ObservedObject var viewModel: BrowserAgentViewModel
    
    var body: some View {
        VStack(spacing: 0) {
            // 工具栏
            HStack {
                Text("会话: \(session.id.prefix(8))...")
                    .font(.system(size: 11, design: .monospaced))
                
                Spacer()
                
                Button {
                    Task { await viewModel.endSession() }
                } label: {
                    Label("结束", systemImage: "stop.fill")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding()
            
            Divider()
            
            // 内容区域
            if let snapshot = session.lastSnapshot {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(snapshot.title)
                            .font(.system(size: 14, weight: .semibold))
                        
                        Text(snapshot.url)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                        
                        Text(snapshot.textExcerpt)
                            .font(.system(size: 12))
                            .lineLimit(5)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ContentUnavailableView("等待页面数据", systemImage: "safari")
            }
        }
    }
}

// MARK: - 视图模型

@MainActor
class BrowserAgentViewModel: ObservableObject {
    @Published var permissionGranted = false
    @Published var isLoading = false
    @Published var currentSession: BrowserSessionInfo?
    
    private let client = BrowserAgentClient()
    
    func checkPermission() async {
        client.connect()
        do {
            let status = try await client.checkPermission()
            permissionGranted = status.authorized
        } catch {
            permissionGranted = false
        }
    }
    
    func startSession() async {
        isLoading = true
        defer { isLoading = false }
        
        do {
            let sessionId = try await client.startSession(config: SessionConfig())
            currentSession = BrowserSessionInfo(id: sessionId)
        } catch {
            print("启动会话失败: \(error)")
        }
    }
    
    func endSession() async {
        guard let session = currentSession else { return }
        
        do {
            try await client.endSession(sessionId: session.id)
            currentSession = nil
        } catch {
            print("结束会话失败: \(error)")
        }
    }
    
    func openPermissionSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
        NSWorkspace.shared.open(url)
    }
}

struct BrowserSessionInfo {
    let id: String
    var lastSnapshot: PageSnapshot?
}
