//
//  BrowserPageAnalyzer.swift
//  MacAssistant
//

import Foundation

struct BrowserPageAnalysis {
    let summary: String
    let nextSuggestions: [String]
}

enum BrowserPageAnalyzer {
    static func classify(
        title: String,
        url: String,
        textExcerpt: String,
        actionableElements: [BrowserElementCandidate]
    ) -> (pageKind: BrowserPageKind, authState: BrowserAuthState) {
        let combined = [title, url, textExcerpt]
            .joined(separator: "\n")
            .lowercased()

        let labels = actionableElements.map(\.label).joined(separator: " ").lowercased()

        let authState: BrowserAuthState
        if combined.contains("二维码") || combined.contains("扫码") {
            authState = .needsScan
        } else if combined.contains("login") || combined.contains("sign in") ||
                    combined.contains("登录") || combined.contains("授权") ||
                    labels.contains("登录") || labels.contains("sign in") {
            authState = .needsLogin
        } else {
            authState = .ready
        }

        let pageKind: BrowserPageKind
        if authState == .needsLogin || authState == .needsScan {
            pageKind = .login
        } else if combined.contains("checkout") || combined.contains("支付") || combined.contains("结算") {
            pageKind = .checkout
        } else if combined.contains("search") || combined.contains("搜索") {
            pageKind = .search
        } else if combined.contains("dashboard") || combined.contains("控制台") || combined.contains("概览") {
            pageKind = .dashboard
        } else if labels.contains("提交") || labels.contains("保存") ||
                    combined.contains("表单") || combined.contains("form") {
            pageKind = .form
        } else if combined.contains("whatsapp") ||
                    combined.contains("message") ||
                    combined.contains("聊天") ||
                    combined.contains("会话") {
            pageKind = .chat
        } else if textExcerpt.count > 600 {
            pageKind = .article
        } else if actionableElements.count >= 6 {
            pageKind = .list
        } else {
            pageKind = .unknown
        }

        return (pageKind, authState)
    }

    static func analyze(_ snapshot: BrowserPageSnapshot) -> BrowserPageAnalysis {
        let summary: String
        switch snapshot.pageKind {
        case .login:
            switch snapshot.authState {
            case .needsScan:
                summary = "我识别到这是需要扫码或授权确认的登录页。"
            case .needsLogin:
                summary = "我识别到这是登录页，页面上已经出现账号/授权相关入口。"
            default:
                summary = "我识别到这是登录相关页面。"
            }
        case .search:
            summary = "我识别到这是一个搜索或检索页面。"
        case .dashboard:
            summary = "我识别到这是一个控制台或概览页面。"
        case .form:
            summary = "我识别到这是一个表单页，可以继续填写或提交。"
        case .checkout:
            summary = "我识别到这是一个结算或支付相关页面。"
        case .chat:
            summary = "我识别到这是一个聊天或消息页面。"
        case .article:
            summary = "我识别到这是一个内容页，可以继续提取重点或定位操作入口。"
        case .list:
            summary = "我识别到这是一个列表页，可以继续筛选、点击或查看详情。"
        case .unknown:
            summary = "页面已经打开，但当前只识别到基础结构，还需要你告诉我下一步目标。"
        }

        var nextSuggestions: [String] = []
        switch snapshot.authState {
        case .needsScan:
            nextSuggestions.append("先手动完成扫码或授权，完成后回复“继续”")
        case .needsLogin:
            nextSuggestions.append("让我先查看当前页面")
            nextSuggestions.append("告诉我要填写哪一项")
        case .ready, .unknown:
            nextSuggestions.append("让我看看当前页面")
        }

        if snapshot.pageKind == .form || snapshot.pageKind == .login {
            nextSuggestions.append("告诉我要输入账号、点击哪个按钮，或先不要提交")
        }
        if snapshot.pageKind == .list || snapshot.pageKind == .search {
            nextSuggestions.append("告诉我要点哪个结果或继续筛选")
        }

        return BrowserPageAnalysis(
            summary: summary,
            nextSuggestions: Array(nextSuggestions.prefix(3))
        )
    }
}
