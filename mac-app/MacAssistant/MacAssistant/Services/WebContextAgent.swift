//
//  WebContextAgent.swift
//  MacAssistant
//

import Foundation
import AppKit

final class WebContextAgent {
    static let shared = WebContextAgent()

    private let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    private init() {}

    func responseIfNeeded(for text: String, images: [String]) async -> String? {
        guard images.isEmpty,
              let request = classifyRequest(from: text) else {
            return nil
        }

        do {
            switch request {
            case .webPage(let url):
                let document = try await fetchDocument(from: url)
                return buildWebPageResponse(document: document, url: url, originalText: text)
            case .githubRepo(let url, let owner, let repo):
                let document = try await fetchDocument(from: url)
                return buildGitHubResponse(
                    document: document,
                    url: url,
                    owner: owner,
                    repo: repo,
                    originalText: text
                )
            }
        } catch {
            return """
            我刚刚尝试直接读取这个链接，但本地抓取没有成功。

            链接：\(request.url.absoluteString)
            原因：\(error.localizedDescription)

            这类请求不应该再绕到通用对话链路里。更稳的做法是先把“网页读取 / 仓库解析”走本地能力，再决定是否需要把内容交给后续 Agent 继续处理。
            """
        }
    }

    private func classifyRequest(from text: String) -> RequestKind? {
        let urls = extractURLs(from: text)
        guard let url = urls.first else { return nil }

        let normalized = text.lowercased()
        let urlKeywords = [
            "http://", "https://", "网页", "页面", "文档", "链接", "网站", "url",
            "读取", "读这个", "分析", "看看", "学习", "repo", "仓库", "github",
            "mcp", "部署", "deploy", "服务"
        ]

        guard urlKeywords.contains(where: { normalized.contains($0) }) else {
            return nil
        }

        if let repoInfo = parseGitHubRepo(url) {
            return .githubRepo(url: url, owner: repoInfo.owner, repo: repoInfo.repo)
        }

        return .webPage(url)
    }

    private func extractURLs(from text: String) -> [URL] {
        guard let detector else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, options: [], range: range).compactMap { $0.url }
    }

    private func parseGitHubRepo(_ url: URL) -> (owner: String, repo: String)? {
        guard let host = url.host?.lowercased(),
              host == "github.com" || host == "www.github.com" else {
            return nil
        }

        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count >= 2 else { return nil }

        let owner = components[0]
        let repo = components[1]
        let blocked = Set(["login", "features", "topics", "marketplace", "orgs", "organizations"])
        guard !blocked.contains(owner.lowercased()) else { return nil }
        return (owner, repo)
    }

    private func fetchDocument(from url: URL) async throws -> WebDocument {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("MacAssistant/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebContextError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw WebContextError.httpStatus(httpResponse.statusCode)
        }

        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        let encoding = String.Encoding.utf8
        let rawText = String(data: data, encoding: encoding) ?? String(decoding: data, as: UTF8.self)
        let title = firstMatch(in: rawText, pattern: #"<title[^>]*>\s*(.*?)\s*</title>"#) ?? url.lastPathComponent
        let description = firstMatch(
            in: rawText,
            pattern: #"<meta[^>]+(?:name|property)=["'](?:description|og:description)["'][^>]+content=["'](.*?)["']"#
        )

        let visibleText: String
        if contentType.contains("html") || rawText.contains("<html") {
            visibleText = extractVisibleText(fromHTML: rawText)
        } else if contentType.contains("json"),
                  let json = try? JSONSerialization.jsonObject(with: data),
                  let prettyData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]),
                  let pretty = String(data: prettyData, encoding: .utf8) {
            visibleText = pretty
        } else {
            visibleText = normalizeWhitespace(rawText)
        }

        return WebDocument(
            title: normalizeWhitespace(title),
            description: description.map(normalizeWhitespace),
            bodyPreview: String(visibleText.prefix(1_200)),
            contentType: contentType
        )
    }

    private func extractVisibleText(fromHTML html: String) -> String {
        let data = Data(html.utf8)
        if let attributed = try? NSAttributedString(
            data: data,
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue
            ],
            documentAttributes: nil
        ) {
            let normalized = normalizeWhitespace(attributed.string)
            if !normalized.isEmpty {
                return normalized
            }
        }

        let withoutScripts = html.replacingOccurrences(
            of: #"<script[\s\S]*?</script>|<style[\s\S]*?</style>"#,
            with: " ",
            options: [.regularExpression, .caseInsensitive]
        )
        let withoutTags = withoutScripts.replacingOccurrences(
            of: #"<[^>]+>"#,
            with: " ",
            options: .regularExpression
        )
        return normalizeWhitespace(withoutTags)
    }

    private func buildWebPageResponse(document: WebDocument, url: URL, originalText: String) -> String {
        var lines: [String] = [
            "我已经直接读取了这个网页，不需要再绕到 GitHub MCP 或通用对话长链路。",
            "",
            "**标题**：\(document.title)",
            "**来源**：\(url.host ?? url.absoluteString)"
        ]

        if let description = document.description, !description.isEmpty {
            lines.append("**简介**：\(description)")
        }

        if !document.bodyPreview.isEmpty {
            lines.append("")
            lines.append("**网页摘录**：")
            lines.append(document.bodyPreview)
        }

        if shouldSuggestDocCrawl(for: originalText) {
            lines.append("")
            lines.append("如果你的目标是把这份文档继续扩展到更多 API 页面，更合理的落法是：")
            lines.append("1. 以当前页面作为入口，抓取同站文档链接")
            lines.append("2. 过滤出真正的 API / 示例 / 权限说明页面")
            lines.append("3. 把正文入本地索引或知识库")
            lines.append("4. 再把这份索引接到股票分析 Skill / AutoAgent")
        }

        return lines.joined(separator: "\n")
    }

    private func buildGitHubResponse(
        document: WebDocument,
        url: URL,
        owner: String,
        repo: String,
        originalText: String
    ) -> String {
        let normalized = originalText.lowercased()
        let repoSlug = "\(owner)/\(repo)"

        var lines: [String] = [
            "我已经直接读取了这个 GitHub 仓库页，不需要把这件事交给 OpenClaw 长链路。",
            "",
            "**仓库**：\(repoSlug)",
            "**标题**：\(document.title)"
        ]

        if let description = document.description, !description.isEmpty {
            lines.append("**简介**：\(description)")
        }

        lines.append("")
        lines.append("**判断**：这个链接是源码仓库地址，不是服务健康检查地址。仅凭仓库 URL，不能说明“服务已经部署起来了”。")

        if normalized.contains("部署") || normalized.contains("deploy") || normalized.contains("服务") {
            lines.append("如果你想确认是否真的可用，应该检查的是：")
            lines.append("1. 本地或远端 MCP 进程是否启动")
            lines.append("2. 是否完成 GitHub token / OAuth 配置")
            lines.append("3. OpenClaw / mcporter 是否注册到了这个 MCP server")
            lines.append("4. 工具列表是否能被 runtime 看到并成功调用")
        }

        lines.append("")
        lines.append("如果你的目标是“读取普通网页文档”，这条 GitHub MCP 路径本身也不对。GitHub 仓库/MCP 解决的是 GitHub 平台接入，不是通用网页抓取。")
        lines.append("更合理的是：先直接读取目标网页，再把文档抓取和索引能力做成内置 Skill。")
        lines.append("")
        lines.append("**原始链接**：\(url.absoluteString)")

        return lines.joined(separator: "\n")
    }

    private func shouldSuggestDocCrawl(for text: String) -> Bool {
        let normalized = text.lowercased()
        let keywords = ["扩展", "更多", "学习", "crawl", "抓取", "索引", "文档站", "api页面", "api 页面"]
        return keywords.contains(where: { normalized.contains($0) })
    }

    private func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }

        return String(text[range])
    }

    private func normalizeWhitespace(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension WebContextAgent {
    enum RequestKind {
        case webPage(URL)
        case githubRepo(url: URL, owner: String, repo: String)

        var url: URL {
            switch self {
            case .webPage(let url):
                return url
            case .githubRepo(let url, _, _):
                return url
            }
        }
    }

    struct WebDocument {
        let title: String
        let description: String?
        let bodyPreview: String
        let contentType: String
    }

    enum WebContextError: LocalizedError {
        case invalidResponse
        case httpStatus(Int)

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "没有拿到有效的 HTTP 响应"
            case .httpStatus(let statusCode):
                return "HTTP \(statusCode)"
            }
        }
    }
}
