//
//  WebContextAgent.swift
//  MacAssistant
//

import Foundation
import AppKit

final class WebContextAgent {
    static let shared = WebContextAgent()

    private let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    struct WebContextAttachment {
        let augmentedInput: String
        let notice: String
        let sourceURL: URL
    }

    private init() {}

    func hasLinkRequest(for text: String, images: [String]) -> Bool {
        guard images.isEmpty else {
            return false
        }
        return classifyRequest(from: text) != nil
    }

    func attachmentIfNeeded(
        for text: String,
        images: [String],
        preferClawTools: Bool
    ) async -> WebContextAttachment? {
        guard images.isEmpty,
              let request = classifyRequest(from: text) else {
            return nil
        }

        if preferClawTools {
            switch request {
            case .webPage(let url):
                return buildClawToolAttachment(
                    url: url,
                    originalText: text,
                    typeDescription: "网页文档"
                )
            case .githubRepo(let url, let owner, let repo):
                return buildClawToolGitHubAttachment(
                    url: url,
                    owner: owner,
                    repo: repo,
                    originalText: text
                )
            }
        }

        do {
            switch request {
            case .webPage(let url):
                let document = try await fetchDocument(from: url)
                return buildWebPageAttachment(document: document, url: url, originalText: text)
            case .githubRepo(let url, let owner, let repo):
                let document = try await fetchDocument(from: url)
                return buildGitHubAttachment(
                    document: document,
                    url: url,
                    owner: owner,
                    repo: repo,
                    originalText: text
                )
            }
        } catch {
            return WebContextAttachment(
                augmentedInput: text,
                notice: "已识别到链接，但本地预取失败，已直接继续交给 Claw 处理。",
                sourceURL: request.url
            )
        }
    }

    func backgroundResearchSummary(for text: String, images: [String]) async throws -> String? {
        guard images.isEmpty,
              let request = classifyRequest(from: text) else {
            return nil
        }

        switch request {
        case .webPage(let url):
            let document = try await fetchDocument(from: url)
            return summarizeWebDocument(document, url: url)
        case .githubRepo(let url, let owner, let repo):
            let document = try await fetchDocument(from: url)
            return summarizeGitHubDocument(document, url: url, owner: owner, repo: repo)
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

    private func buildWebPageAttachment(document: WebDocument, url: URL, originalText: String) -> WebContextAttachment {
        var lines: [String] = [
            "下面是当前请求附带的网页上下文，请结合这些信息继续处理，不要把摘录原样复读当作最终答案。",
            "",
            "[网页上下文]",
            "链接: \(url.absoluteString)",
            "类型: 网页文档",
            "标题: \(document.title)",
            "来源: \(url.host ?? url.absoluteString)"
        ]

        if let description = document.description, !description.isEmpty {
            lines.append("简介: \(description)")
        }

        if !document.bodyPreview.isEmpty {
            lines.append("摘录:")
            lines.append(document.bodyPreview)
        }

        if shouldSuggestDocCrawl(for: originalText) {
            lines.append("提示: 用户可能还希望扩展到更多文档/API 页面，必要时可继续使用 Claw skills 进行文档抓取、索引或 GitHub/MCP 能力分析。")
        }

        lines.append("[/网页上下文]")
        lines.append("")
        lines.append("用户原始请求：")
        lines.append(originalText)

        return WebContextAttachment(
            augmentedInput: lines.joined(separator: "\n"),
            notice: "已读取链接上下文，继续交给 Claw 处理。",
            sourceURL: url
        )
    }

    private func buildGitHubAttachment(
        document: WebDocument,
        url: URL,
        owner: String,
        repo: String,
        originalText: String
    ) -> WebContextAttachment {
        let normalized = originalText.lowercased()
        let repoSlug = "\(owner)/\(repo)"

        var lines: [String] = [
            "下面是当前请求附带的 GitHub 仓库上下文，请继续结合 Claw skills / MCP 能力处理，不要把仓库页摘要直接当作最终答复。",
            "",
            "[GitHub 仓库上下文]",
            "仓库: \(repoSlug)",
            "链接: \(url.absoluteString)",
            "标题: \(document.title)"
        ]

        if let description = document.description, !description.isEmpty {
            lines.append("简介: \(description)")
        }

        lines.append("判断: 这是源码仓库地址，不是服务健康检查地址。仅凭仓库 URL，不能说明“服务已经部署起来了”。")

        if normalized.contains("部署") || normalized.contains("deploy") || normalized.contains("服务") {
            lines.append("检查建议:")
            lines.append("1. 本地或远端 MCP 进程是否启动")
            lines.append("2. 是否完成 GitHub token / OAuth 配置")
            lines.append("3. OpenClaw / mcporter 是否注册到了这个 MCP server")
            lines.append("4. 工具列表是否能被 runtime 看到并成功调用")
        }

        if !document.bodyPreview.isEmpty {
            lines.append("页面摘录:")
            lines.append(document.bodyPreview)
        }

        lines.append("[/GitHub 仓库上下文]")
        lines.append("")
        lines.append("用户原始请求：")
        lines.append(originalText)

        return WebContextAttachment(
            augmentedInput: lines.joined(separator: "\n"),
            notice: "已读取 GitHub 链接上下文，继续交给 Claw 处理。",
            sourceURL: url
        )
    }

    private func buildClawToolAttachment(
        url: URL,
        originalText: String,
        typeDescription: String
    ) -> WebContextAttachment {
        let lines = [
            "下面这个请求包含明确的链接，请优先通过 OpenClaw 工具链处理，不要只根据用户贴出来的 URL 或应用本地预取内容直接猜答案。",
            "",
            "[链接处理要求]",
            "链接: \(url.absoluteString)",
            "类型: \(typeDescription)",
            "执行要求:",
            "1. 优先使用 `web_fetch` 读取目标页面。",
            "2. 如果页面依赖动态渲染、登录态或复杂交互，再考虑 `browser` 工具。",
            "3. 如果相关 skills / MCP 服务能帮助扩展分析，允许继续调用。",
            "4. 最终答复应给出结论和下一步建议，而不是只回显网页摘录。",
            "[/链接处理要求]",
            "",
            "用户原始请求：",
            originalText
        ]

        return WebContextAttachment(
            augmentedInput: lines.joined(separator: "\n"),
            notice: "已识别到链接，优先交给 Claw tools 继续处理。",
            sourceURL: url
        )
    }

    private func buildClawToolGitHubAttachment(
        url: URL,
        owner: String,
        repo: String,
        originalText: String
    ) -> WebContextAttachment {
        let lines = [
            "下面这个请求包含 GitHub 仓库链接，请优先通过 OpenClaw 工具链处理，不要只根据仓库首页摘要直接回答。",
            "",
            "[GitHub 链接处理要求]",
            "仓库: \(owner)/\(repo)",
            "链接: \(url.absoluteString)",
            "执行要求:",
            "1. 先把它当作源码/配置仓库，而不是部署状态页面。",
            "2. 优先读取 README、目录结构、MCP/skills 相关配置，再判断是否有助于扩展当前能力。",
            "3. 如果需要，继续结合已安装 skills / MCP 服务做后续分析。",
            "[/GitHub 链接处理要求]",
            "",
            "用户原始请求：",
            originalText
        ]

        return WebContextAttachment(
            augmentedInput: lines.joined(separator: "\n"),
            notice: "已识别到 GitHub 链接，优先交给 Claw tools 继续处理。",
            sourceURL: url
        )
    }

    private func shouldSuggestDocCrawl(for text: String) -> Bool {
        let normalized = text.lowercased()
        let keywords = ["扩展", "更多", "学习", "crawl", "抓取", "索引", "文档站", "api页面", "api 页面"]
        return keywords.contains(where: { normalized.contains($0) })
    }

    private func summarizeWebDocument(_ document: WebDocument, url: URL) -> String {
        var lines = [
            "链接抓取完成：\(url.absoluteString)",
            "标题：\(document.title)"
        ]

        if let description = document.description, !description.isEmpty {
            lines.append("简介：\(description)")
        }

        if !document.bodyPreview.isEmpty {
            lines.append("摘要：\(String(document.bodyPreview.prefix(320)))")
        }

        return lines.joined(separator: "\n")
    }

    private func summarizeGitHubDocument(
        _ document: WebDocument,
        url: URL,
        owner: String,
        repo: String
    ) -> String {
        var lines = [
            "GitHub 抓取完成：\(owner)/\(repo)",
            "链接：\(url.absoluteString)",
            "标题：\(document.title)"
        ]

        if let description = document.description, !description.isEmpty {
            lines.append("简介：\(description)")
        }

        if !document.bodyPreview.isEmpty {
            lines.append("摘要：\(String(document.bodyPreview.prefix(320)))")
        }

        return lines.joined(separator: "\n")
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
