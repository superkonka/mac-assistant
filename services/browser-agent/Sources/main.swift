//
//  main.swift
//  BrowserAgent 服务入口
//

import Foundation

// 启动 XPC 服务器
let server = BrowserAgentXPCServer()
server.start()

// 保持运行
RunLoop.main.run()
