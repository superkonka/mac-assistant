//
//  ExecutorProtocol.swift
//  MacAssistant
//
//  统一执行器协议 - 所有执行器都遵循此协议
//

import Foundation

/// 执行器协议
protocol Executor {
    var name: String { get }
    var supportedSources: [ExecutionSource] { get }
    
    /// 执行命令，返回统一结果
    func execute(
        command: String,
        context: ExecutionContext,
        onProgress: ((ExecutionResult) -> Void)?
    ) async -> ExecutionResult
    
    /// 检查是否支持该命令
    func canHandle(command: String) -> Bool
}

/// 执行器注册表
@MainActor
final class ExecutorRegistry {
    static let shared = ExecutorRegistry()
    
    private var executors: [ExecutionSource: Executor] = [:]
    
    private init() {}
    
    func register(_ executor: Executor, for source: ExecutionSource) {
        executors[source] = executor
    }
    
    func executor(for source: ExecutionSource) -> Executor? {
        executors[source]
    }
    
    func executor(for command: String) -> Executor? {
        executors.values.first { $0.canHandle(command: command) }
    }
}
