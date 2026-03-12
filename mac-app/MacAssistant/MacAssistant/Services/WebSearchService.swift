//
//  WebSearchService.swift
//  MacAssistant
//

import Foundation

final class WebSearchService {
    static let shared = WebSearchService()

    private let session: URLSession

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    func searchSummary(for rawQuery: String) async throws -> String {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            throw WebSearchError.emptyQuery
        }

        if shouldUseGitHubSearch(for: query) {
            return try await githubSummary(for: query)
        }

        return try await duckDuckGoSummary(for: query)
    }
}

private extension WebSearchService {
    struct GitHubSearchResponse: Decodable {
        let items: [GitHubRepository]
    }

    struct GitHubRepository: Decodable {
        let fullName: String
        let htmlURL: String
        let description: String?
        let stargazersCount: Int
        let updatedAt: Date

        private enum CodingKeys: String, CodingKey {
            case fullName = "full_name"
            case htmlURL = "html_url"
            case description
            case stargazersCount = "stargazers_count"
            case updatedAt = "updated_at"
        }
    }

    struct DuckDuckGoResponse: Decodable {
        let abstractText: String
        let abstractURL: String
        let relatedTopics: [DuckDuckGoTopic]

        private enum CodingKeys: String, CodingKey {
            case abstractText = "AbstractText"
            case abstractURL = "AbstractURL"
            case relatedTopics = "RelatedTopics"
        }
    }

    struct DuckDuckGoTopic: Decodable {
        let text: String?
        let firstURL: String?
        let topics: [DuckDuckGoTopic]?

        private enum CodingKeys: String, CodingKey {
            case text = "Text"
            case firstURL = "FirstURL"
            case topics = "Topics"
        }
    }

    struct SearchHit {
        let title: String
        let url: String
        let snippet: String
    }

    enum WebSearchError: LocalizedError {
        case emptyQuery
        case noResults(query: String)

        var errorDescription: String? {
            switch self {
            case .emptyQuery:
                return "缺少搜索关键词。"
            case .noResults(let query):
                return "这次没有拿到“\(query)”的可展示搜索结果。"
            }
        }
    }

    func shouldUseGitHubSearch(for query: String) -> Bool {
        let lowercased = query.lowercased()
        return lowercased.contains("github")
            || lowercased.contains("repo")
            || query.contains("仓库")
            || query.contains("代码库")
            || lowercased.contains("mcp")
    }

    func githubSummary(for rawQuery: String) async throws -> String {
        let query = normalizedGitHubQuery(from: rawQuery)
        var components = URLComponents(string: "https://api.github.com/search/repositories")
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "sort", value: "stars"),
            URLQueryItem(name: "order", value: "desc"),
            URLQueryItem(name: "per_page", value: "5")
        ]

        guard let url = components?.url else {
            throw WebSearchError.noResults(query: rawQuery)
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MacAssistant/1.0", forHTTPHeaderField: "User-Agent")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let (data, response) = try await session.data(for: request)
        try validateHTTP(response)

        let payload = try decoder.decode(GitHubSearchResponse.self, from: data)
        let repositories = Array(payload.items.prefix(5))

        guard !repositories.isEmpty else {
            throw WebSearchError.noResults(query: rawQuery)
        }

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short

        let lines = repositories.enumerated().map { index, repo in
            let summary = repo.description?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                ?? "未提供仓库描述。"
            let updated = formatter.localizedString(for: repo.updatedAt, relativeTo: Date())
            return """
            \(index + 1). **\(repo.fullName)**
            \(summary)
            ⭐ \(repo.stargazersCount) · 更新 \(updated)
            \(repo.htmlURL)
            """
        }

        return """
        🔎 GitHub 搜索结果：\(rawQuery)

        \(lines.joined(separator: "\n\n"))

        如果你要，我可以继续帮你按“适合本地 Mac 部署”“偏网页抓取”“偏 GitHub 自动化”再筛一轮。
        """
    }

    func duckDuckGoSummary(for rawQuery: String) async throws -> String {
        if let apiSummary = try await duckDuckGoInstantAnswerSummary(for: rawQuery) {
            return apiSummary
        }

        let hits = try await duckDuckGoHTMLSearch(query: rawQuery)
        guard !hits.isEmpty else {
            throw WebSearchError.noResults(query: rawQuery)
        }

        let lines = hits.enumerated().map { index, hit in
            """
            \(index + 1). **\(hit.title)**
            \(hit.snippet)
            \(hit.url)
            """
        }

        return """
        🔎 网络搜索结果：\(rawQuery)

        \(lines.joined(separator: "\n\n"))
        """
    }

    func duckDuckGoInstantAnswerSummary(for rawQuery: String) async throws -> String? {
        var components = URLComponents(string: "https://api.duckduckgo.com/")
        components?.queryItems = [
            URLQueryItem(name: "q", value: rawQuery),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "no_redirect", value: "1"),
            URLQueryItem(name: "no_html", value: "1"),
            URLQueryItem(name: "skip_disambig", value: "1")
        ]

        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.setValue("MacAssistant/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        try validateHTTP(response)

        let payload = try JSONDecoder().decode(DuckDuckGoResponse.self, from: data)

        if let abstract = payload.abstractText.nonEmpty {
            var body = "🔎 网络搜索结果：\(rawQuery)\n\n\(abstract)"
            if let url = payload.abstractURL.nonEmpty {
                body += "\n\n来源：\(url)"
            }
            return body
        }

        let topics = flatten(topics: payload.relatedTopics)
        guard !topics.isEmpty else { return nil }

        let lines = topics.prefix(5).enumerated().map { index, topic in
            """
            \(index + 1). **\(topic.title)**
            \(topic.snippet)
            \(topic.url)
            """
        }

        return """
        🔎 网络搜索结果：\(rawQuery)

        \(lines.joined(separator: "\n\n"))
        """
    }

    func duckDuckGoHTMLSearch(query: String) async throws -> [SearchHit] {
        var components = URLComponents(string: "https://html.duckduckgo.com/html/")
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components?.url else {
            throw WebSearchError.noResults(query: query)
        }

        var request = URLRequest(url: url)
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("MacAssistant/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        try validateHTTP(response)

        guard let html = String(data: data, encoding: .utf8) else {
            throw WebSearchError.noResults(query: query)
        }

        return parseDuckDuckGoHTML(html).prefix(5).map { $0 }
    }

    func parseDuckDuckGoHTML(_ html: String) -> [SearchHit] {
        let pattern = #"<a[^>]*class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }

        let nsrange = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = regex.matches(in: html, options: [], range: nsrange)

        return matches.compactMap { match in
            guard
                let urlRange = Range(match.range(at: 1), in: html),
                let titleRange = Range(match.range(at: 2), in: html)
            else {
                return nil
            }

            let url = decodeHTML(String(html[urlRange])).nonEmpty
            let title = stripHTMLTags(from: decodeHTML(String(html[titleRange]))).nonEmpty

            guard let url, let title else { return nil }

            return SearchHit(title: title, url: url, snippet: "打开链接查看完整内容。")
        }
    }

    func normalizedGitHubQuery(from rawQuery: String) -> String {
        let lowercased = rawQuery.lowercased()
        if lowercased.contains("mcp") && (rawQuery.contains("服务") || lowercased.contains("server")) {
            return "mcp server"
        }

        let stripped = rawQuery
            .replacingOccurrences(of: "你能搜索到", with: "")
            .replacingOccurrences(of: "帮我搜索", with: "")
            .replacingOccurrences(of: "帮我查", with: "")
            .replacingOccurrences(of: "查一下", with: "")
            .replacingOccurrences(of: "搜索", with: "")
            .replacingOccurrences(of: "GitHub 上", with: "")
            .replacingOccurrences(of: "github 上", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return stripped.isEmpty ? rawQuery : stripped
    }

    func flatten(topics: [DuckDuckGoTopic]) -> [SearchHit] {
        var hits: [SearchHit] = []

        for topic in topics {
            if let text = topic.text?.nonEmpty,
               let url = topic.firstURL?.nonEmpty {
                hits.append(SearchHit(
                    title: text.components(separatedBy: " - ").first ?? text,
                    url: url,
                    snippet: text
                ))
            }

            if let nested = topic.topics {
                hits.append(contentsOf: flatten(topics: nested))
            }
        }

        return hits
    }

    func validateHTTP(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw URLError(.badServerResponse)
        }
    }

    func stripHTMLTags(from value: String) -> String {
        value.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func decodeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }
}

private extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let value = self?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}

private extension String {
    var nonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
